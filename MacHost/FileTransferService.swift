//
//  FileTransferService.swift
//  XDRScreen Mac host
//
//  Host side of the bidirectional file transfer protocol.
//
//  - Receives offers from the iPad, validates them, writes chunks into a
//    hidden temp file in the chosen destination, verifies the SHA-256 carried
//    by `fileEnd`, then renames the temp file to a unique final name.
//  - Sends regular files the user drops or picks: offer -> accept -> 64 KiB
//    chunks (at most four in flight) -> `fileEnd` with the SHA-256.
//  - Keeps one transfer per direction at a time and cancels everything when
//    the session goes away, deleting any unfinished temp file.
//
//  All protocol and file-system state lives on one serial queue; published
//  properties are only mutated on the main thread. Every send goes through
//  `FileTransferSendChannel`, which `ClientSession` implements so a packet can
//  never leave a session that has not authenticated (or has already ended).
//

import AppKit
import Combine
import CryptoKit
import Foundation

// MARK: - Session bridge

/// The controlled path a file transfer uses to write to the wire.
///
/// Implemented by `ClientSession`; the service never touches a `SecureChannel`
/// directly and therefore cannot send from a session that is not authenticated.
protocol FileTransferSendChannel: AnyObject {
    /// True between a successful hello and session teardown.
    var isFileTransferReady: Bool { get }
    func sendFilePacket(_ kind: MessageKind, payload: Data, completion: ((Error?) -> Void)?)
}

// MARK: - UI model

enum FileTransferDirection: String, Equatable {
    case send
    case receive

    var title: String {
        switch self {
        case .send: return "发送"
        case .receive: return "接收"
        }
    }

    var symbolName: String {
        switch self {
        case .send: return "arrow.up.doc"
        case .receive: return "arrow.down.doc"
        }
    }
}

enum FileTransferStatus: Equatable {
    case waiting
    case transferring
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .waiting: return "等待"
        case .transferring: return "传输中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    var isActive: Bool {
        self == .waiting || self == .transferring
    }
}

/// One row in the host window's transfer list.
struct FileTransferItem: Identifiable, Equatable {
    let id: UInt32
    let name: String
    let direction: FileTransferDirection
    let totalBytes: UInt64
    var transferredBytes: UInt64 = 0
    var status: FileTransferStatus = .waiting
    var errorText: String?
    /// Final received file, or the source file for a completed send.
    var localURL: URL?

    var progress: Double {
        // A zero-byte file is complete once received, but a failed row that
        // never had a size (refused directory, symlink, unreadable file) must
        // not render a full bar.
        if totalBytes == 0 {
            return status == .completed ? 1 : 0
        }
        return FileTransfer.progress(transferred: transferredBytes, total: totalBytes)
    }

    var statusText: String {
        switch status {
        case .waiting:
            return direction == .send ? "等待 iPad 接受…" : "准备接收…"
        case .transferring:
            return "传输中 \(Int(progress * 100))%"
        case .completed:
            return "已完成"
        case .failed:
            return errorText ?? "失败"
        case .cancelled:
            return errorText ?? "已取消"
        }
    }
}

// MARK: - Service

final class FileTransferService: ObservableObject {

    static let destinationDefaultsKey = "XDRScreen.host.fileDestination"

    /// `~/Downloads/XDRScreen`.
    static var defaultDestinationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("XDRScreen", isDirectory: true)
    }

    @Published private(set) var items: [FileTransferItem] = []
    @Published private(set) var destinationPath: String
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?

    /// Called on the main thread with a human-readable line for the host log.
    var onLog: ((String) -> Void)?

    // MARK: Queue-confined state

    private let queue = DispatchQueue(label: "com.xdrscreen.host.files", qos: .utility)
    private let fileManager = FileManager.default

    private weak var channel: FileTransferSendChannel?
    private var destinationURL: URL

    private var nextID: UInt32 = 0
    private var records: [UInt32: FileTransferItem] = [:]
    private var order: [UInt32] = []
    private var lastProgressPublish: [UInt32: Date] = [:]

    private var incoming: IncomingTransfer?
    private var outgoing: OutgoingTransfer?
    private var pendingSends: [PendingSend] = []

    private static let maxHistoryItems = 200
    private static let progressPublishInterval: TimeInterval = 0.1

    // MARK: Init

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.destinationDefaultsKey)
        let url = stored.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultDestinationURL
        destinationURL = url
        destinationPath = url.path
    }

    // MARK: Binding

    /// Attaches the service to an authenticated session. A previous binding is
    /// cancelled first, so transfers can never straddle two sessions.
    func bind(to channel: FileTransferSendChannel) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.channel !== channel {
                self.cancelAllOnQueue(message: "会话已更换，传输已取消", notifyPeer: false)
            }
            self.channel = channel
            self.publish {
                self.isConnected = true
                self.lastError = nil
            }
            self.log("文件传输已就绪")
        }
    }

    /// Detaches on session end and cancels every transfer, deleting temp files.
    func unbind() {
        queue.async { [weak self] in
            guard let self else { return }
            self.detachOnQueue(message: "连接已断开")
        }
    }

    /// Detaches only if `channel` is still the bound session. A superseded
    /// session finishing its teardown must not cancel the transfers of the
    /// session that replaced it.
    func unbind(from channel: FileTransferSendChannel) {
        queue.async { [weak self] in
            guard let self, self.channel === channel else { return }
            self.detachOnQueue(message: "连接已断开")
        }
    }

    private func detachOnQueue(message: String) {
        cancelAllOnQueue(message: message, notifyPeer: false)
        channel = nil
        publish { self.isConnected = false }
        log("会话结束，文件传输已解绑")
    }

    /// Synchronous teardown for `applicationWillTerminate`, so unfinished
    /// temp files are deleted before the process exits.
    func shutdownForTermination() {
        queue.sync {
            self.detachOnQueue(message: "应用退出")
        }
    }

    // MARK: Incoming packets

    /// Entry point used by `ClientSession` for kinds 9–14.
    func handle(_ packet: WirePacket) {
        queue.async { [weak self] in
            guard let self, self.channel != nil else { return }
            switch packet.kind {
            case .fileOffer:
                self.handleOffer(packet.payload)
            case .fileAccept:
                self.handleAccept(packet.payload)
            case .fileReject:
                self.handleReject(packet.payload)
            case .fileChunk:
                self.handleChunk(packet.payload)
            case .fileEnd:
                self.handleEnd(packet.payload)
            case .fileCancel:
                self.handleCancel(packet.payload)
            default:
                break
            }
        }
    }

    // MARK: Public actions

    /// Queues one or more regular files for sending. Directories and symbolic
    /// links are refused with a visible failed row rather than silently.
    func sendFiles(at urls: [URL]) {
        guard !urls.isEmpty else { return }
        queue.async { [weak self] in
            self?.enqueueOnQueue(urls)
        }
    }

    /// Cancels the transfer with this UI id, whether it is active or queued.
    func cancelTransfer(id: UInt32) {
        queue.async { [weak self] in
            self?.cancelOnQueue(id)
        }
    }

    /// Shows a completed received file in Finder.
    func revealInFinder(id: UInt32) {
        let item = items.first { $0.id == id }
        guard let url = item?.localURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Presents the destination picker. Main thread only.
    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "选择 iPad 发送文件的保存目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: destinationPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDestination(url)
    }

    /// Persists a new destination after verifying it is (or can become) a
    /// writable directory. Failures leave the previous destination in place.
    func setDestination(_ url: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            let standardized = url.standardizedFileURL
            guard self.prepareDirectory(standardized) else {
                self.reportError("所选目录不可写：\(standardized.path)")
                return
            }
            self.destinationURL = standardized
            UserDefaults.standard.set(standardized.path, forKey: Self.destinationDefaultsKey)
            self.publish {
                self.destinationPath = standardized.path
                self.lastError = nil
            }
            self.log("文件保存目录已设为：\(standardized.path)")
        }
    }

    /// Clears the custom destination and returns to `~/Downloads/XDRScreen`.
    func restoreDefaultDestination() {
        queue.async { [weak self] in
            guard let self else { return }
            let fallback = Self.defaultDestinationURL
            let usable = self.prepareDirectory(fallback)
            self.destinationURL = fallback
            UserDefaults.standard.removeObject(forKey: Self.destinationDefaultsKey)
            self.publish {
                self.destinationPath = fallback.path
                self.lastError = usable ? nil : "无法创建默认保存目录：\(fallback.path)"
            }
            self.log("文件保存目录已恢复默认：\(fallback.path)")
        }
    }

    /// Presents the multi-file send picker. Main thread only.
    func chooseFilesToSend() {
        guard isConnected else {
            publish { self.lastError = "尚未连接 iPad，无法发送文件。" }
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择要发送到 iPad 的文件"
        panel.prompt = "发送"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return }
        sendFiles(at: panel.urls)
    }

    // MARK: - Sending

    private struct PendingSend {
        let localID: UInt32
        let remoteID: UInt32
        let url: URL
        let name: String
        let size: UInt64
    }

    private final class OutgoingTransfer {
        let localID: UInt32
        let remoteID: UInt32
        let url: URL
        let name: String
        let totalBytes: UInt64
        var handle: FileHandle?
        var hasher = SHA256()
        var sentBytes: UInt64 = 0
        var inFlight = 0
        var readEOF = false
        var awaitingAccept = true
        var finishing = false
        var acceptTimeout: DispatchWorkItem?

        init(localID: UInt32, remoteID: UInt32, url: URL, name: String, size: UInt64) {
            self.localID = localID
            self.remoteID = remoteID
            self.url = url
            self.name = name
            self.totalBytes = size
        }
    }

    private func enqueueOnQueue(_ urls: [URL]) {
        guard channel?.isFileTransferReady == true else {
            reportError("尚未连接 iPad，无法发送文件。")
            return
        }
        publish { self.lastError = nil }

        for url in urls {
            let display = FileTransfer.sanitizeFileName(url.lastPathComponent) ?? FileTransfer.fallbackFileName
            switch inspectFile(url) {
            case .failure(let error):
                let id = allocateID()
                addItem(FileTransferItem(id: id,
                                         name: display,
                                         direction: .send,
                                         totalBytes: 0,
                                         status: .failed,
                                         errorText: error.localizedDescription))
                log("无法发送 \(display)：\(error.localizedDescription)")

            case .success(let size):
                let id = allocateID()
                addItem(FileTransferItem(id: id,
                                         name: display,
                                         direction: .send,
                                         totalBytes: size,
                                         status: .waiting))
                pendingSends.append(PendingSend(localID: id,
                                                remoteID: id,
                                                url: url,
                                                name: display,
                                                size: size))
            }
        }
        pumpOutgoing()
    }

    private struct FileInspectionError: Error, LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }

    private func inspectFile(_ url: URL) -> Result<UInt64, FileInspectionError> {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey,
                                                      .isSymbolicLinkKey,
                                                      .fileSizeKey])
        } catch {
            return .failure(FileInspectionError("无法读取文件信息：\(error.localizedDescription)"))
        }
        if values.isSymbolicLink == true {
            return .failure(FileInspectionError("不支持符号链接，请选择链接指向的真实文件。"))
        }
        guard values.isRegularFile == true else {
            return .failure(FileInspectionError("仅支持常规文件，不支持文件夹。"))
        }
        guard let fileSize = values.fileSize, fileSize >= 0 else {
            return .failure(FileInspectionError("无法读取文件大小。"))
        }
        let size = UInt64(fileSize)
        guard size <= FileTransfer.maxFileByteCount else {
            return .failure(FileInspectionError("文件超过 4 GiB 上限。"))
        }
        return .success(size)
    }

    private func pumpOutgoing() {
        guard outgoing == nil,
              !pendingSends.isEmpty,
              let channel,
              channel.isFileTransferReady else { return }

        let next = pendingSends.removeFirst()
        let transfer = OutgoingTransfer(localID: next.localID,
                                        remoteID: next.remoteID,
                                        url: next.url,
                                        name: next.name,
                                        size: next.size)
        outgoing = transfer

        let offer = FileOfferMessage(id: transfer.remoteID,
                                     name: transfer.name,
                                     size: transfer.totalBytes)
        guard let payload = try? WireJSON.encode(offer) else {
            finishOutgoing(localID: transfer.localID,
                           status: .failed,
                           message: "无法编码文件信息。",
                           notifyPeer: false,
                           reason: .io)
            return
        }
        channel.sendFilePacket(.fileOffer, payload: payload) { [weak self, weak transfer] error in
            guard let self, let error, let transfer else { return }
            self.queue.async {
                self.finishOutgoing(localID: transfer.localID,
                                    status: .failed,
                                    message: "发送文件信息失败：\(error.localizedDescription)",
                                    notifyPeer: false,
                                    reason: .io)
            }
        }
        log("已向 iPad 提供文件：\(transfer.name)（\(transfer.totalBytes) 字节）")

        let work = DispatchWorkItem { [weak self] in
            self?.acceptTimedOut(transfer.localID)
        }
        transfer.acceptTimeout = work
        queue.asyncAfter(deadline: .now() + FileTransfer.acceptTimeout, execute: work)
    }

    private func acceptTimedOut(_ localID: UInt32) {
        guard let transfer = outgoing, transfer.localID == localID,
              transfer.awaitingAccept else { return }
        finishOutgoing(localID: localID,
                       status: .cancelled,
                       message: "等待 iPad 接受超时（\(Int(FileTransfer.acceptTimeout)) 秒）",
                       notifyPeer: true,
                       reason: .cancelled)
    }

    private func handleAccept(_ payload: Data) {
        guard let message = try? WireJSON.decode(FileAcceptMessage.self, from: payload),
              let transfer = outgoing,
              transfer.remoteID == message.id,
              transfer.awaitingAccept else { return }

        transfer.acceptTimeout?.cancel()
        transfer.acceptTimeout = nil
        transfer.awaitingAccept = false

        do {
            transfer.handle = try FileHandle(forReadingFrom: transfer.url)
        } catch {
            finishOutgoing(localID: transfer.localID,
                           status: .failed,
                           message: "无法打开文件：\(error.localizedDescription)",
                           notifyPeer: true,
                           reason: .io)
            return
        }
        setStatus(transfer.localID, .transferring, errorText: nil)
        pumpChunks(transfer)
    }

    private func pumpChunks(_ transfer: OutgoingTransfer) {
        guard outgoing === transfer, !transfer.finishing else { return }

        while transfer.inFlight < FileTransfer.maxInFlightChunks, !transfer.readEOF {
            let remaining = transfer.totalBytes - transfer.sentBytes
            if remaining == 0 {
                transfer.readEOF = true
                break
            }
            let wanted = Int(min(UInt64(FileTransfer.chunkByteCount), remaining))
            let piece: Data?
            do {
                piece = try transfer.handle?.read(upToCount: wanted)
            } catch {
                finishOutgoing(localID: transfer.localID,
                               status: .failed,
                               message: "读取文件失败：\(error.localizedDescription)",
                               notifyPeer: true,
                               reason: .io)
                return
            }
            guard let data = piece, !data.isEmpty else {
                // The file shrank after it was offered; the receiver would
                // reject the short stream, so cancel before sending fileEnd.
                finishOutgoing(localID: transfer.localID,
                               status: .failed,
                               message: "文件在发送过程中变小，已取消。",
                               notifyPeer: true,
                               reason: .cancelled)
                return
            }

            let chunk = FileChunk(id: transfer.remoteID,
                                  offset: transfer.sentBytes,
                                  data: data)
            transfer.sentBytes += UInt64(data.count)
            transfer.hasher.update(data: data)
            transfer.inFlight += 1
            updateProgress(transfer.localID, transferred: transfer.sentBytes)

            channel?.sendFilePacket(.fileChunk, payload: chunk.encoded()) { [weak self, weak transfer] error in
                guard let self, let transfer else { return }
                self.queue.async {
                    guard self.outgoing === transfer else { return }
                    transfer.inFlight -= 1
                    if let error {
                        self.finishOutgoing(localID: transfer.localID,
                                            status: .failed,
                                            message: "发送文件数据失败：\(error.localizedDescription)",
                                            notifyPeer: false,
                                            reason: .io)
                        return
                    }
                    self.pumpChunks(transfer)
                }
            }
        }

        if transfer.readEOF, transfer.inFlight == 0 {
            finishOutgoingSend(transfer)
        }
    }

    /// Last chunk acknowledged: announce the whole-file hash.
    private func finishOutgoingSend(_ transfer: OutgoingTransfer) {
        guard outgoing === transfer, !transfer.finishing else { return }
        transfer.finishing = true
        try? transfer.handle?.close()
        transfer.handle = nil

        if transfer.sentBytes != transfer.totalBytes {
            finishOutgoing(localID: transfer.localID,
                           status: .failed,
                           message: "文件大小与发送前不一致，已取消。",
                           notifyPeer: true,
                           reason: .cancelled)
            return
        }

        let digest = FileTransfer.hexString(transfer.hasher.finalize())
        let message = FileEndMessage(id: transfer.remoteID, sha256: digest)
        guard let payload = try? WireJSON.encode(message) else {
            finishOutgoing(localID: transfer.localID,
                           status: .failed,
                           message: "无法编码文件摘要。",
                           notifyPeer: true,
                           reason: .io)
            return
        }
        channel?.sendFilePacket(.fileEnd, payload: payload) { [weak self, weak transfer] error in
            guard let self, let transfer else { return }
            self.queue.async {
                guard self.outgoing === transfer else { return }
                if let error {
                    self.finishOutgoing(localID: transfer.localID,
                                        status: .failed,
                                        message: "发送文件摘要失败：\(error.localizedDescription)",
                                        notifyPeer: false,
                                        reason: .io)
                    return
                }
                self.setStatus(transfer.localID, .completed, errorText: nil, localURL: transfer.url)
                self.updateProgress(transfer.localID, transferred: transfer.totalBytes, force: true)
                self.log("已发送文件：\(transfer.name)")
                self.outgoing = nil
                self.pumpOutgoing()
            }
        }
    }

    private func handleReject(_ payload: Data) {
        guard let message = try? WireJSON.decode(FileRejectMessage.self, from: payload),
              let transfer = outgoing,
              transfer.remoteID == message.id else { return }
        finishOutgoing(localID: transfer.localID,
                       status: .failed,
                       message: Self.description(forRejectReason: message.reason),
                       notifyPeer: false,
                       reason: .cancelled)
    }

    private func finishOutgoing(localID: UInt32,
                                status: FileTransferStatus,
                                message: String?,
                                notifyPeer: Bool,
                                reason: FileTransfer.RejectReason) {
        guard let transfer = outgoing, transfer.localID == localID else { return }
        outgoing = nil
        transfer.acceptTimeout?.cancel()
        transfer.acceptTimeout = nil
        try? transfer.handle?.close()
        transfer.handle = nil

        if notifyPeer, let channel, channel.isFileTransferReady {
            let cancel = FileCancelMessage(id: transfer.remoteID, reason: reason)
            if let data = try? WireJSON.encode(cancel) {
                channel.sendFilePacket(.fileCancel, payload: data, completion: nil)
            }
        }

        setStatus(localID, status, errorText: message)
        if let message { log("发送 \(transfer.name) 失败：\(message)") }
        pumpOutgoing()
    }

    // MARK: - Receiving

    private final class IncomingTransfer {
        let localID: UInt32
        let remoteID: UInt32
        let displayName: String
        let totalBytes: UInt64
        /// Directory chosen when the offer was accepted. The temp file lives
        /// here, so the final rename stays on one volume even if the user
        /// changes the destination while the transfer is running.
        let directory: URL
        let tempURL: URL
        let handle: FileHandle
        var hasher = SHA256()
        var receivedBytes: UInt64 = 0

        init(localID: UInt32,
             remoteID: UInt32,
             displayName: String,
             totalBytes: UInt64,
             directory: URL,
             tempURL: URL,
             handle: FileHandle) {
            self.localID = localID
            self.remoteID = remoteID
            self.displayName = displayName
            self.totalBytes = totalBytes
            self.directory = directory
            self.tempURL = tempURL
            self.handle = handle
        }
    }

    private func handleOffer(_ payload: Data) {
        guard let offer = try? WireJSON.decode(FileOfferMessage.self, from: payload) else {
            log("收到无法解析的文件 offer，已忽略")
            return
        }

        // One transfer per direction: a second offer while receiving is busy.
        if incoming != nil {
            sendReject(id: offer.id, reason: .busy)
            return
        }
        if let reason = FileTransfer.offerRejectionReason(for: offer) {
            sendReject(id: offer.id, reason: reason)
            log("已拒绝文件 \(FileTransfer.sanitizeFileName(offer.name) ?? "?")：\(reason.rawValue)")
            return
        }
        guard let name = FileTransfer.sanitizeFileName(offer.name), !name.isEmpty else {
            sendReject(id: offer.id, reason: .invalidName)
            return
        }
        guard let directory = ensureDestinationOnQueue() else {
            sendReject(id: offer.id, reason: .io)
            return
        }

        let tempURL = directory.appendingPathComponent(".xdrscreen-\(UUID().uuidString).part")
        guard fileManager.createFile(atPath: tempURL.path, contents: nil) else {
            reportError("无法在保存目录创建临时文件：\(directory.path)")
            sendReject(id: offer.id, reason: .io)
            return
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: tempURL)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            reportError("无法写入临时文件：\(error.localizedDescription)")
            sendReject(id: offer.id, reason: .io)
            return
        }

        let localID = allocateID()
        let transfer = IncomingTransfer(localID: localID,
                                        remoteID: offer.id,
                                        displayName: name,
                                        totalBytes: offer.size,
                                        directory: directory,
                                        tempURL: tempURL,
                                        handle: handle)
        incoming = transfer
        addItem(FileTransferItem(id: localID,
                                 name: name,
                                 direction: .receive,
                                 totalBytes: offer.size,
                                 status: .transferring))

        let accept = FileAcceptMessage(id: offer.id)
        if let data = try? WireJSON.encode(accept) {
            send(.fileAccept, data)
        }
        publish { self.lastError = nil }
        log("iPad 正在发送文件：\(name)（\(offer.size) 字节）")
    }

    private func handleChunk(_ payload: Data) {
        guard let transfer = incoming else { return }
        guard let chunk = FileChunk.decode(payload) else {
            abortIncoming(reason: .unsupported,
                          message: "分块格式无效，传输已中止。",
                          notifyPeer: true,
                          status: .failed)
            return
        }
        if let error = FileTransfer.validateChunk(chunk,
                                                  expectedID: transfer.remoteID,
                                                  expectedOffset: transfer.receivedBytes,
                                                  fileSize: transfer.totalBytes) {
            abortIncoming(reason: .unsupported,
                          message: "文件分块校验失败：\(error.localizedDescription)",
                          notifyPeer: true,
                          status: .failed)
            return
        }

        do {
            try transfer.handle.write(contentsOf: chunk.data)
        } catch {
            abortIncoming(reason: .io,
                          message: "写入文件失败：\(error.localizedDescription)",
                          notifyPeer: true,
                          status: .failed)
            return
        }
        transfer.hasher.update(data: chunk.data)
        transfer.receivedBytes += UInt64(chunk.data.count)
        updateProgress(transfer.localID, transferred: transfer.receivedBytes)
    }

    private func handleEnd(_ payload: Data) {
        guard let message = try? WireJSON.decode(FileEndMessage.self, from: payload),
              let transfer = incoming,
              transfer.remoteID == message.id else { return }

        guard transfer.receivedBytes == transfer.totalBytes else {
            abortIncoming(reason: .io,
                          message: "文件大小不符（收到 \(transfer.receivedBytes)，应为 \(transfer.totalBytes) 字节）。",
                          notifyPeer: true,
                          status: .failed)
            return
        }
        let digest = FileTransfer.hexString(transfer.hasher.finalize())
        guard digest == message.sha256.lowercased() else {
            abortIncoming(reason: .io,
                          message: "SHA-256 校验失败，文件可能已损坏。",
                          notifyPeer: true,
                          status: .failed)
            return
        }

        incoming = nil
        do {
            try transfer.handle.close()
        } catch {
            // Closing a read/write handle after successful writes is best
            // effort; the rename below still proves the bytes are on disk.
        }
        let finalURL = availableURL(for: transfer.displayName, in: transfer.directory)
        do {
            try fileManager.moveItem(at: transfer.tempURL, to: finalURL)
        } catch {
            try? fileManager.removeItem(at: transfer.tempURL)
            failItem(transfer.localID, message: "无法保存文件：\(error.localizedDescription)")
            sendCancel(id: transfer.remoteID, reason: .io)
            return
        }

        setStatus(transfer.localID, .completed, errorText: nil, localURL: finalURL)
        updateProgress(transfer.localID, transferred: transfer.totalBytes, force: true)
        publish { self.lastError = nil }
        log("已接收文件：\(finalURL.lastPathComponent)")
    }

    private func handleCancel(_ payload: Data) {
        guard let message = try? WireJSON.decode(FileCancelMessage.self, from: payload) else { return }

        if let transfer = incoming, transfer.remoteID == message.id {
            abortIncoming(reason: .cancelled,
                          message: "iPad 取消了传输。",
                          notifyPeer: false,
                          status: .cancelled)
            return
        }
        if let transfer = outgoing, transfer.remoteID == message.id {
            finishOutgoing(localID: transfer.localID,
                           status: .cancelled,
                           message: "iPad 取消了传输。",
                           notifyPeer: false,
                           reason: .cancelled)
        }
    }

    /// Removes the temp file and finishes the row. Sends `fileCancel` first
    /// (the temp file is already unlinked, so nothing is left behind).
    private func abortIncoming(reason: FileTransfer.RejectReason,
                               message: String,
                               notifyPeer: Bool,
                               status: FileTransferStatus) {
        guard let transfer = incoming else { return }
        incoming = nil
        try? transfer.handle.close()
        try? fileManager.removeItem(at: transfer.tempURL)
        if notifyPeer { sendCancel(id: transfer.remoteID, reason: reason) }
        setStatus(transfer.localID, status, errorText: message)
        log("接收 \(transfer.displayName) 中止：\(message)")
    }

    private func cancelOnQueue(_ localID: UInt32) {
        if let transfer = incoming, transfer.localID == localID {
            abortIncoming(reason: .cancelled,
                          message: "已取消。",
                          notifyPeer: true,
                          status: .cancelled)
            return
        }
        if let transfer = outgoing, transfer.localID == localID {
            finishOutgoing(localID: localID,
                           status: .cancelled,
                           message: "已取消。",
                           notifyPeer: true,
                           reason: .cancelled)
            return
        }
        if let index = pendingSends.firstIndex(where: { $0.localID == localID }) {
            pendingSends.remove(at: index)
            setStatus(localID, .cancelled, errorText: "已取消。")
        }
    }

    /// Session teardown: no peer to notify, delete every unfinished temp file.
    private func cancelAllOnQueue(message: String, notifyPeer: Bool) {
        if let transfer = incoming {
            incoming = nil
            try? transfer.handle.close()
            try? fileManager.removeItem(at: transfer.tempURL)
            if notifyPeer { sendCancel(id: transfer.remoteID, reason: .cancelled) }
            setStatus(transfer.localID, .failed, errorText: message)
            log("接收 \(transfer.displayName) 中止：\(message)")
        }
        if let transfer = outgoing {
            outgoing = nil
            transfer.acceptTimeout?.cancel()
            transfer.acceptTimeout = nil
            try? transfer.handle?.close()
            transfer.handle = nil
            if notifyPeer {
                sendCancel(id: transfer.remoteID, reason: .cancelled)
            }
            setStatus(transfer.localID, .failed, errorText: message)
            log("发送 \(transfer.name) 中止：\(message)")
        }
        for pending in pendingSends {
            setStatus(pending.localID, .cancelled, errorText: message)
        }
        pendingSends.removeAll()
    }

    // MARK: - Destination

    /// Returns a writable destination, creating it when missing. A persistent
    /// custom path that has become unusable falls back to the default **and
    /// reports it**, so the user notices instead of files landing elsewhere
    /// silently.
    private func ensureDestinationOnQueue() -> URL? {
        if prepareDirectory(destinationURL) { return destinationURL }

        let fallback = Self.defaultDestinationURL
        if destinationURL != fallback, prepareDirectory(fallback) {
            destinationURL = fallback
            UserDefaults.standard.removeObject(forKey: Self.destinationDefaultsKey)
            publish { self.destinationPath = fallback.path }
            reportError("原保存目录不可用，已恢复默认目录：\(fallback.path)")
            return fallback
        }
        reportError("保存目录不可用或不可写：\(destinationURL.path)")
        return nil
    }

    private func prepareDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return false }
        } else {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                return false
            }
        }
        return fileManager.isWritableFile(atPath: url.path)
    }

    private func availableURL(for name: String, in directory: URL) -> URL {
        let existing = Set((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
        let unique = FileTransfer.uniqueFileName(name, existing: existing)
        return directory.appendingPathComponent(unique)
    }

    // MARK: - Sending helpers

    @discardableResult
    private func send(_ kind: MessageKind, _ payload: Data) -> Bool {
        guard let channel, channel.isFileTransferReady else { return false }
        channel.sendFilePacket(kind, payload: payload, completion: nil)
        return true
    }

    private func sendReject(id: UInt32, reason: FileTransfer.RejectReason) {
        guard let data = try? WireJSON.encode(FileRejectMessage(id: id, reason: reason)) else { return }
        send(.fileReject, data)
    }

    private func sendCancel(id: UInt32, reason: FileTransfer.RejectReason) {
        guard let data = try? WireJSON.encode(FileCancelMessage(id: id, reason: reason)) else { return }
        send(.fileCancel, data)
    }

    private static func description(forRejectReason raw: String) -> String {
        guard let reason = FileTransfer.RejectReason(rawValue: raw) else {
            return "iPad 拒绝：\(raw)"
        }
        switch reason {
        case .busy: return "iPad 已有传输在进行，请稍后重试。"
        case .tooLarge: return "iPad 拒绝：文件超过大小上限。"
        case .invalidName: return "iPad 拒绝：文件名无效。"
        case .io: return "iPad 无法保存文件。"
        case .cancelled: return "iPad 取消了传输。"
        case .unsupported: return "iPad 不支持该文件。"
        }
    }

    // MARK: - Item bookkeeping

    private func allocateID() -> UInt32 {
        nextID = nextID == UInt32.max ? 1 : nextID + 1
        return nextID
    }

    private func addItem(_ item: FileTransferItem) {
        records[item.id] = item
        order.append(item.id)
        trimHistory()
        publishItems()
    }

    private func setStatus(_ localID: UInt32,
                           _ status: FileTransferStatus,
                           errorText: String?,
                           localURL: URL? = nil) {
        guard var item = records[localID] else { return }
        item.status = status
        item.errorText = errorText
        if let localURL { item.localURL = localURL }
        records[localID] = item
        publishItems()
    }

    private func failItem(_ localID: UInt32, message: String) {
        setStatus(localID, .failed, errorText: message)
        log(message)
    }

    private func updateProgress(_ localID: UInt32, transferred: UInt64, force: Bool = false) {
        guard var item = records[localID] else { return }
        item.transferredBytes = min(transferred, item.totalBytes)
        records[localID] = item

        let now = Date()
        let last = lastProgressPublish[localID] ?? .distantPast
        if force || now.timeIntervalSince(last) >= Self.progressPublishInterval {
            lastProgressPublish[localID] = now
            publishItems()
        }
    }

    private func trimHistory() {
        while order.count > Self.maxHistoryItems {
            guard let index = order.firstIndex(where: { records[$0]?.status.isActive != true }) else {
                return
            }
            let id = order.remove(at: index)
            records.removeValue(forKey: id)
            lastProgressPublish.removeValue(forKey: id)
        }
    }

    private func publishItems() {
        let snapshot = order.compactMap { records[$0] }
        publish { self.items = snapshot }
    }

    // MARK: - Publishing / errors

    private func reportError(_ text: String) {
        publish { self.lastError = text }
        log(text)
    }

    private func log(_ text: String) {
        publish { self.onLog?(text) }
    }

    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
