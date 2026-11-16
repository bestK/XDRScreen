//
//  HostController.swift
//  XDRScreen Mac host
//
//  Bonjour listener, pairing key custody, one-client session lifecycle and the
//  authenticated control/video channel.
//

import Foundation
import Network
import CryptoKit
import Combine
import AppKit
import ApplicationServices
import CoreGraphics
import Security

// MARK: - Pairing key

enum PairingCodec {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func pairingURL(key: String) -> String {
        "xdrscreen://pair?key=\(key)"
    }
}

struct PairingKeyError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "钥匙串错误 \(status)（\(message)）"
    }
}

struct PairingKeyCorruptError: LocalizedError {
    var errorDescription: String? {
        "钥匙串中的配对密钥长度异常，无法使用。请先解锁钥匙串；如问题持续，请在钥匙串访问中删除本应用的配对条目后重启。"
    }
}

enum PairingKeyStore {
    struct Result {
        let data: Data
        let persisted: Bool
        let error: String?
    }

    private static let service = "com.xdrscreen.host.pairing"
    private static let account = "pairing-key-v1"

    /// Loads the 32-byte pairing key from the Keychain, creating and storing a
    /// fresh one only when no item exists yet. Any other Keychain error
    /// (locked keychain, denied ACL, corrupt item, ...) is thrown instead of
    /// silently minting a different key: the iPad already holds the old key and
    /// could never reconnect to this run.
    static func loadOrCreate() throws -> Result {
        if let existing = try loadKey() {
            guard existing.count == 32 else { throw PairingKeyCorruptError() }
            return Result(data: existing, persisted: true, error: nil)
        }

        // Genuinely absent: first launch, or the user removed the item.
        let key = try generateKey()
        do {
            try storeKey(key)
            return Result(data: key, persisted: true, error: nil)
        } catch {
            // Nothing was paired before, so an in-memory key is still usable
            // for this run; the UI reports that it changes on restart.
            return Result(data: key, persisted: false, error: error.localizedDescription)
        }
    }

    private static func loadKey() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PairingKeyError(status: status) }
        guard let data = result as? Data, !data.isEmpty else {
            throw PairingKeyCorruptError()
        }
        return data
    }

    private static func storeKey(_ data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)

        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw PairingKeyError(status: status) }
    }

    private static func generateKey() throws -> Data {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base)
        }
        guard status == errSecSuccess else { throw PairingKeyError(status: status) }
        return bytes
    }
}

// MARK: - Session

protocol ClientSessionDelegate: AnyObject {
    func clientSession(_ session: ClientSession, didUpdateClient name: String)
    func clientSession(_ session: ClientSession, didUpdateStream text: String)
    func clientSession(_ session: ClientSession, didLog text: String)
    func clientSession(_ session: ClientSession, didReportIssue text: String)
    /// A session finished the encrypted handshake and its hello. The host
    /// decides which display to capture (mirror vs. dedicated virtual
    /// display) and only then calls `activate(target:)`.
    func clientSession(_ session: ClientSession, didAuthenticate name: String, request: CaptureRequest)
    /// An authenticated client asked to change the target bitrate. `nil` means
    /// the client handed control back to the host's quality tier.
    func clientSession(_ session: ClientSession, didReceiveManualBitrateMbps mbps: Int?)
    /// One authenticated file transfer packet (kinds 9–14) arrived.
    func clientSession(_ session: ClientSession, didReceiveFileTransfer packet: WirePacket)
    func clientSessionDidEnd(_ session: ClientSession, reason: String)
}

/// One authenticated iPad connection. Owns the capture encoder and the input
/// injector; nothing is sent before a decrypted, parsed hello arrives.
final class ClientSession {

    weak var delegate: ClientSessionDelegate?

    private let channel: SecureChannel
    private let queue: DispatchQueue
    private let input: InputController
    private let hostName: String
    /// HDR capability advertised in the host hello. False when this host is in
    /// dedicated-screen mode: the virtual display is SDR (EDR headroom 1.0).
    private let helloSupportsHDR: Bool
    /// No packet at all for this long after authentication means the client
    /// vanished without closing the socket.
    private let idleTimeout: TimeInterval
    /// Maximum time from accept to the client's hello.
    private let handshakeTimeout: TimeInterval
    /// Quality tier requested by the host UI. Confined to `queue`; applied to
    /// the encoder before streaming and forwarded live after that.
    private var quality: HostQuality
    /// Last explicit target in Mbps, from the host UI or an authenticated
    /// client. `nil` follows the quality tier. Confined to `queue`; used at
    /// activation and forwarded live afterwards. The client's message wins on
    /// arrival (last writer wins), matching the host controller's state.
    private var manualBitrateMbps: Int?

    private lazy var encoder = CaptureEncoder(isCongested: { [weak self] in
        self?.isCongested ?? false
    })

    private let lock = NSLock()

    // `inFlight`, `ended` and `authenticated` are read from the capture and
    // network queues, so they are guarded by `lock`.
    private var ended = false
    private var authenticated = false
    private var inFlight = 0

    // Everything below is confined to `queue`.
    private var sentFormat: StreamFormat?
    private var pendingFormat: StreamFormat?
    private var pendingFrame: EncodedFrame?
    private var formatInFlight = false
    /// Set after a frame was dropped: no dependent P frame may be sent until a
    /// real IDR for the current format arrives.
    private var waitingForIDR = false
    private var lastStatus: (text: String, at: Date)?
    private var warnedAccessibility = false
    private var clientName = "iPad"
    private var streamFPS = 60
    private var captureRequest: CaptureRequest?
    private var pendingTarget: CaptureTarget?
    private var activated = false
    private var lastPacketAt = Date()

    private static let maxInFlightFrames = 3

    init(connection: NWConnection,
         key: SymmetricKey,
         displayID: CGDirectDisplayID,
         hostName: String,
         helloSupportsHDR: Bool,
         quality: HostQuality,
         manualBitrateMbps: Int?,
         idleTimeout: TimeInterval = 15,
         handshakeTimeout: TimeInterval = 10) {
        let queue = DispatchQueue(label: "com.xdrscreen.session", qos: .userInitiated)
        self.queue = queue
        self.channel = SecureChannel(connection: connection, key: key, queue: queue)
        self.input = InputController(displayID: displayID)
        self.hostName = hostName
        self.helloSupportsHDR = helloSupportsHDR
        self.quality = quality
        self.manualBitrateMbps = manualBitrateMbps
        self.idleTimeout = idleTimeout
        self.handshakeTimeout = handshakeTimeout
    }

    // MARK: Lifecycle

    func start() {
        channel.onState = { [weak self] state in
            self?.queue.async { self?.handleState(state) }
        }
        channel.onPacket = { [weak self] packet in
            self?.queue.async { self?.handlePacket(packet) }
        }
        channel.start()
        queue.asyncAfter(deadline: .now() + handshakeTimeout) { [weak self] in
            self?.handshakeDeadline()
        }
        startLivenessWatchdog()
    }

    /// Starts streaming against the display the host selected. Safe to call
    /// from any thread. `target` is the virtual display in dedicated mode or
    /// the main display for mirror mode; input mapping follows it.
    func activate(target: CaptureTarget?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingTarget = target
            self.activateOnQueue()
        }
    }

    /// Thread-safe; used by the host controller when the user changes the
    /// quality tier. The stored value is used by the next `activate` even if
    /// the session is not streaming yet.
    func setQuality(_ quality: HostQuality) {
        queue.async { [weak self] in
            guard let self else { return }
            self.quality = quality
            guard self.activated else { return }
            self.encoder.setQuality(quality)
        }
    }

    /// Thread-safe; used by the host controller for both its own UI choice and
    /// a value reported by the authenticated client. `nil` means "follow the
    /// quality tier". The value is remembered for the next `activate` even if
    /// the session is not streaming yet.
    func setManualBitrate(_ mbps: Int?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.manualBitrateMbps = mbps
            guard self.activated else { return }
            self.encoder.setManualBitrate(mbps.map { $0 * 1_000_000 })
        }
    }

    /// Thread-safe; used by the host controller. `completion` runs on the
    /// session queue after input has been released, the encoder stopped and
    /// the socket closed, so a replacement can safely start streaming after it.
    func close(reason: String, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            self?.endNow(reason: reason)
            completion?()
        }
    }

    func releaseInputNow() {
        input.releaseAllNow()
    }

    var isAuthenticated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return authenticated
    }

    private var isEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    private var isCongested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight >= Self.maxInFlightFrames
    }

    private func endNow(reason: String) {
        lock.lock()
        if ended {
            lock.unlock()
            return
        }
        ended = true
        authenticated = false
        inFlight = 0
        lock.unlock()

        pendingFrame = nil
        pendingFormat = nil
        formatInFlight = false
        waitingForIDR = false
        activated = false
        pendingTarget = nil

        encoder.stop()
        input.releaseAllNow()
        channel.close()
        delegate?.clientSession(self, didLog: "会话结束：\(reason)")
        delegate?.clientSessionDidEnd(self, reason: reason)
    }

    // MARK: Connection state

    private func handleState(_ state: NWConnection.State) {
        guard !isEnded else { return }
        switch state {
        case .ready:
            sendHostHello()
        case .waiting(let error):
            delegate?.clientSession(self, didLog: "连接等待：\(Self.describe(error))")
        case .failed(let error):
            endNow(reason: "连接失败：\(Self.describe(error))")
        case .cancelled:
            endNow(reason: "连接已断开")
        default:
            break
        }
    }

    private func sendHostHello() {
        let capability = DisplayProbe.mainDisplay()
        let fps = min(max(capability.maxFPS, 30), 60)
        #if arch(arm64)
        let hdrCapable = helloSupportsHDR && capability.supportsHDR
        #else
        let hdrCapable = false
        #endif
        let hello = HelloMessage(
            protocolVersion: Wire.protocolVersion,
            width: capability.pixelWidth,
            height: capability.pixelHeight,
            maxFPS: fps,
            supportsHDR: hdrCapable,
            deviceName: hostName
        )
        guard let data = try? JSONEncoder().encode(hello) else { return }
        channel.send(.hello, payload: data, completion: nil)
    }

    private func handshakeDeadline() {
        guard !isEnded, !isAuthenticated else { return }
        sendStatus("未在 \(Int(handshakeTimeout)) 秒内收到客户端 hello，连接将关闭", force: true)
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            // A hello that arrived during the grace period wins: never tear
            // down a session that just finished authenticating.
            guard !self.isEnded, !self.isAuthenticated else { return }
            self.endNow(reason: "握手超时")
        }
    }

    /// Application-level liveness. The client pings every few seconds; a
    /// half-open socket (iPad left Wi-Fi without a FIN) would otherwise keep
    /// the single session slot occupied indefinitely.
    private func startLivenessWatchdog() {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.isEnded else { return }
            if self.isAuthenticated, Date().timeIntervalSince(self.lastPacketAt) > self.idleTimeout {
                self.endNow(reason: "客户端超过 \(Int(self.idleTimeout)) 秒无响应")
                return
            }
            self.startLivenessWatchdog()
        }
    }

    // MARK: Packets

    private func handlePacket(_ packet: WirePacket) {
        guard !isEnded else { return }
        lastPacketAt = Date()
        switch packet.kind {
        case .ping:
            guard isAuthenticated else { return }
            channel.send(.ping, payload: packet.payload, completion: nil)

        case .hello:
            handleHello(packet.payload)

        case .input:
            // Never inject input for a candidate that has not taken over yet.
            guard isAuthenticated, activated else { return }
            guard let message = try? JSONDecoder().decode(InputMessage.self, from: packet.payload) else { return }
            handleInput(message)

        case .requestKeyframe:
            guard isAuthenticated, activated else { return }
            encoder.requestKeyframe()
            delegate?.clientSession(self, didLog: "客户端请求关键帧")

        case .status:
            if let status = try? JSONDecoder().decode(StatusMessage.self, from: packet.payload) {
                delegate?.clientSession(self, didLog: "客户端：\(status.message)")
            }

        case .clientSettings:
            // Only an authenticated session may steer the encoder. Anything
            // malformed or out of range is clamped or ignored, never fatal.
            handleClientSettings(packet.payload)

        case .fileOffer, .fileAccept, .fileReject, .fileChunk, .fileEnd, .fileCancel:
            // File transfer is only legal on a session that proved the pairing
            // key and completed the hello exchange.
            guard isAuthenticated else { return }
            delegate?.clientSession(self, didReceiveFileTransfer: packet)

        case .videoFormat, .videoFrame:
            // Server-to-client kinds; ignore.
            break
        }
    }

    /// Applies a `.clientSettings` payload. The client wins over the host's
    /// current manual value (last writer wins): a non-nil value replaces it,
    /// `nil` hands control back to the selected quality tier.
    private func handleClientSettings(_ payload: Data) {
        guard isAuthenticated else {
            delegate?.clientSession(self, didLog: "未认证的连接发送了客户端设置，已忽略")
            return
        }
        guard let message = try? JSONDecoder().decode(ClientSettingsMessage.self, from: payload) else {
            delegate?.clientSession(self, didLog: "客户端码率设置无法解析，已忽略")
            sendStatus("客户端发送了无法解析的码率设置，已忽略")
            return
        }
        let clamped = message.clampedBitrateMbps
        if let requested = message.bitrateMbps, requested != clamped {
            delegate?.clientSession(self, didLog:
                "客户端请求码率 \(requested) Mbps 超出 4–200 Mbps，已钳制为 \(clamped ?? ClientSettingsMessage.minBitrateMbps) Mbps")
        }

        manualBitrateMbps = clamped
        if activated {
            encoder.setManualBitrate(clamped.map { $0 * 1_000_000 })
        }
        delegate?.clientSession(self, didReceiveManualBitrateMbps: clamped)
    }

    private func handleHello(_ payload: Data) {
        guard !isAuthenticated else { return }
        guard let hello = try? JSONDecoder().decode(HelloMessage.self, from: payload) else {
            sendStatus("配对失败：无法解析 hello 消息", force: true)
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.isEnded, !self.isAuthenticated else { return }
                self.endNow(reason: "hello 无法解析")
            }
            return
        }
        guard hello.protocolVersion == Wire.protocolVersion else {
            sendStatus("协议版本不匹配：客户端 \(hello.protocolVersion)，本机需要 \(Wire.protocolVersion)", force: true)
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.isEnded, !self.isAuthenticated else { return }
                self.endNow(reason: "协议版本不匹配")
            }
            return
        }

        lock.lock()
        authenticated = true
        lock.unlock()

        clientName = hello.deviceName.isEmpty ? "iPad" : hello.deviceName
        streamFPS = min(max(hello.maxFPS, 1), 60)
        lastPacketAt = Date()
        captureRequest = CaptureRequest(
            clientWidth: hello.width,
            clientHeight: hello.height,
            clientMaxFPS: streamFPS,
            clientSupportsHDR: hello.supportsHDR,
            target: nil
        )
        delegate?.clientSession(self, didLog: "已完成加密握手：\(clientName)（\(hello.width)×\(hello.height)，\(hello.maxFPS) fps，HDR \(hello.supportsHDR ? "请求" : "未请求")）")

        // The host owns display selection: mirror mode activates immediately,
        // dedicated mode may first have to create/create-or-reuse the virtual
        // display. A candidate that has not proved its key is never activated.
        if let request = captureRequest {
            delegate?.clientSession(self, didAuthenticate: clientName, request: request)
        }
    }

    private func activateOnQueue() {
        guard !isEnded, isAuthenticated, !activated, let request = captureRequest else { return }
        activated = true
        let target = pendingTarget
        if let target {
            // Map touch coordinates to the display that is actually captured.
            input.setDisplay(target.displayID)
        }
        delegate?.clientSession(self, didUpdateClient: clientName)
        sendStatus("已建立加密会话", force: true)
        encoder.delegate = self
        // Both calls land on the encoder queue in order, so the tier and any
        // manual target are in place before `startInternal` computes the first
        // bitrate budget. A manual value (host UI or a client that connected
        // before the capture target was ready) keeps priority over the tier.
        encoder.setQuality(quality)
        encoder.setManualBitrate(manualBitrateMbps.map { $0 * 1_000_000 })
        encoder.start(request.withTarget(target))
    }

    private func handleInput(_ message: InputMessage) {
        guard AXIsProcessTrusted() else {
            if !warnedAccessibility {
                warnedAccessibility = true
                sendStatus("辅助功能权限未授予：触控与键盘输入已忽略。请在 Mac 上授权后重连。", force: true)
                delegate?.clientSession(self, didReportIssue: "辅助功能权限未授予，iPad 输入无法注入。请在“系统设置 › 隐私与安全性 › 辅助功能”中允许本应用。")
            }
            return
        }
        input.handle(message)
    }

    // MARK: Status

    private func sendStatus(_ text: String, force: Bool = false) {
        let now = Date()
        lock.lock()
        if ended {
            lock.unlock()
            return
        }
        if !force, let lastStatus, lastStatus.text == text, now.timeIntervalSince(lastStatus.at) < 3 {
            lock.unlock()
            return
        }
        lastStatus = (text, now)
        lock.unlock()

        guard let data = try? JSONEncoder().encode(StatusMessage(message: text)) else { return }
        channel.send(.status, payload: data, completion: nil)
    }

    // MARK: Video forwarding
    //
    // Everything below runs on `queue`. Because `SecureChannel.send` preserves
    // call order, originating every send from this one serial queue guarantees
    // that a videoFormat message is always written before any frame that needs
    // its parameter sets.

    /// Called from the capture encoder queue.
    private func emit(_ frame: EncodedFrame) {
        queue.async { [weak self] in
            self?.emitOnQueue(frame)
        }
    }

    private func emitOnQueue(_ frame: EncodedFrame) {
        guard !isEnded else { return }

        // A single sealed packet cannot exceed 16 MiB. Never let one oversized
        // frame tear down the session: drop it and resynchronise on an IDR.
        guard frame.data.count <= VideoPacketLimits.maxFrameDataBytes else {
            waitingForIDR = true
            encoder.requestKeyframe()
            return
        }

        if formatInFlight {
            // Keep at most one frame while a format message is in flight.
            // Prefer a keyframe of the newest format; the previous frames
            // cannot be decoded by the client in any case.
            if frame.format != sentFormat {
                pendingFormat = frame.format
                if pendingFrame?.format != frame.format || (frame.keyframe && pendingFrame?.keyframe == false) {
                    pendingFrame = frame
                }
            } else if pendingFrame == nil || (frame.keyframe && pendingFrame?.keyframe == false) {
                pendingFrame = frame
            }
            return
        }

        if waitingForIDR {
            guard frame.keyframe else { return }
            waitingForIDR = false
        }

        if sentFormat != frame.format {
            pendingFrame = frame
            beginFormatSend(frame.format)
            return
        }

        sendFrameNow(frame)
    }

    /// Sends the format message first and holds all frames until its write
    /// completes, so a new parameter set / resolution / HDR mode change is
    /// always observed by the client before the frames that depend on it.
    private func beginFormatSend(_ format: StreamFormat) {
        sentFormat = format
        formatInFlight = true

        let message = VideoFormatMessage(
            width: format.width,
            height: format.height,
            fps: streamFPS,
            hdr: format.hdr,
            vps: format.vps,
            sps: format.sps,
            pps: format.pps,
            colorPrimaries: format.colorPrimaries,
            transferFunction: format.transferFunction,
            yCbCrMatrix: format.yCbCrMatrix
        )
        guard let data = try? JSONEncoder().encode(message) else {
            endNow(reason: "视频格式消息编码失败")
            return
        }
        channel.send(.videoFormat, payload: data) { [weak self] error in
            guard let self else { return }
            self.queue.async { self.formatSendFinished(error: error) }
        }
    }

    private func formatSendFinished(error: Error?) {
        if let error {
            endNow(reason: "视频格式发送失败：\(error.localizedDescription)")
            return
        }
        formatInFlight = false

        // A newer format arrived while the previous one was being written.
        if let nextFormat = pendingFormat {
            pendingFormat = nil
            beginFormatSend(nextFormat)
            return
        }

        guard let frame = pendingFrame else {
            waitingForIDR = true
            encoder.requestKeyframe()
            return
        }
        pendingFrame = nil

        // The pending frame must belong to the format the client just received
        // and must be an IDR; otherwise wait for one instead of sending a
        // dependent frame with missing references.
        guard frame.format == sentFormat, frame.keyframe else {
            waitingForIDR = true
            encoder.requestKeyframe()
            return
        }
        sendFrameNow(frame)
    }

    private func sendFrameNow(_ frame: EncodedFrame) {
        lock.lock()
        inFlight += 1
        lock.unlock()

        let payload = VideoFramePayload.encode(keyframe: frame.keyframe,
                                               timestampUs: frame.timestampUs,
                                               data: frame.data)
        channel.send(.videoFrame, payload: payload) { [weak self] error in
            guard let self else { return }
            self.queue.async { self.frameSendFinished(error: error) }
        }
    }

    private func frameSendFinished(error: Error?) {
        lock.lock()
        if inFlight > 0 { inFlight -= 1 }
        lock.unlock()
        guard let error else { return }
        if let wireError = error as? WireError, case .payloadTooLarge = wireError {
            // Never kill a live session over one frame at the packet limit;
            // drop it and wait for a fresh IDR instead.
            waitingForIDR = true
            encoder.requestKeyframe()
            return
        }
        endNow(reason: "视频帧发送失败：\(error.localizedDescription)")
    }

    // MARK: File transfer channel

    /// True only between a successful hello and teardown. The file service
    /// uses this before every write, so a late callback cannot send on a
    /// session that has already been replaced or closed.
    var isFileTransferReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return authenticated && !ended
    }

    /// The controlled send entry for file transfer packets. Unlike the video
    /// path it may be called from any thread (the service has its own queue);
    /// `SecureChannel.send` serializes on the session queue, so ordering
    /// between adjacent chunks is preserved.
    func sendFilePacket(_ kind: MessageKind, payload: Data, completion: ((Error?) -> Void)?) {
        guard isFileTransferReady else {
            completion?(WireError.channelClosed)
            return
        }
        channel.send(kind, payload: payload, completion: completion)
    }

    // MARK: Errors

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .EADDRINUSE: return "端口被占用（\(code.rawValue)）"
            case .EACCES: return "没有网络权限（\(code.rawValue)）"
            case .ECONNRESET: return "连接被重置"
            case .ETIMEDOUT: return "连接超时"
            case .EPROTO: return "加密握手失败：配对密钥不匹配或数据被篡改"
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH: return "网络不可达（\(code.rawValue)）"
            default: return "系统网络错误 \(code.rawValue)"
            }
        case .dns(let code):
            return "Bonjour/DNS 错误 \(code)"
        case .tls(let status):
            return "TLS 错误 \(status)"
        default:
            return "\(error)"
        }
    }
}

// MARK: - ClientSession file transfer channel

extension ClientSession: FileTransferSendChannel {}

// MARK: - ClientSession capture delegate

extension ClientSession: CaptureEncoderDelegate {

    func captureEncoder(_ encoder: CaptureEncoder, didEncode frame: EncodedFrame) {
        emit(frame)
    }

    func captureEncoder(_ encoder: CaptureEncoder, didSelectDisplay displayID: CGDirectDisplayID) {
        input.setDisplay(displayID)
    }

    func captureEncoder(_ encoder: CaptureEncoder, didUpdateStatus status: String) {
        delegate?.clientSession(self, didUpdateStream: status)
        delegate?.clientSession(self, didLog: status)
        sendStatus(status)
    }

    func captureEncoder(_ encoder: CaptureEncoder, didFail message: String, retryable: Bool) {
        delegate?.clientSession(self, didReportIssue: message)
        delegate?.clientSession(self, didLog: message)
        sendStatus(message, force: true)
    }
}

// MARK: - Display mode / virtual display sizing

enum HostDisplayMode: String, CaseIterable, Identifiable {
    /// Stream the current main display. Never changes the display arrangement.
    case mirror
    /// Create and stream a 2x Retina virtual display sized to the iPad panel.
    case dedicated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mirror: return "镜像当前屏幕"
        case .dedicated: return "iPad Retina 专用屏"
        }
    }
}

struct VirtualDisplaySize: Equatable {
    let width: Int
    let height: Int
}

/// Converts the client's hello pixel box into a bounded, even virtual-display
/// size. Hello values are not trusted: a malicious or buggy client must not be
/// able to make the host allocate a gigantic framebuffer.
enum VirtualDisplaySizing {
    /// No dimension above 4K. iPad Pro 12.9" is 2732x2048, comfortably below.
    static let maxDimension = 4096
    /// Upper bound on framebuffer pixels (~9.4 MP), also below 4K total pixels.
    static let maxPixels = 4096 * 2304
    static let minimumDimension = 64
    static let refreshRate: Double = 60

    static func normalizedSize(clientWidth: Int, clientHeight: Int) -> VirtualDisplaySize? {
        guard clientWidth > 0, clientHeight > 0 else { return nil }

        var scale = 1.0
        scale = min(scale, Double(maxDimension) / Double(clientWidth))
        scale = min(scale, Double(maxDimension) / Double(clientHeight))
        let pixels = Double(clientWidth) * Double(clientHeight)
        if pixels * scale * scale > Double(maxPixels) {
            scale = min(scale, (Double(maxPixels) / pixels).squareRoot())
        }
        guard scale > 0 else { return nil }

        var width = Int((Double(clientWidth) * scale).rounded())
        var height = Int((Double(width) * Double(clientHeight) / Double(clientWidth)).rounded())
        width -= width % 2
        height -= height % 2
        guard width >= minimumDimension, height >= minimumDimension,
              width <= maxDimension, height <= maxDimension,
              width * height <= maxPixels else { return nil }
        return VirtualDisplaySize(width: width, height: height)
    }
}

// MARK: - Host controller

final class HostController: NSObject, ObservableObject {

    static let shared = HostController()

    @Published private(set) var isListening = false
    @Published private(set) var serviceStatus = "未启动"
    @Published private(set) var clientStatus = "未连接"
    @Published private(set) var videoStatus = "空闲"
    @Published private(set) var lastError: String?
    @Published private(set) var eventLog: [String] = []
    @Published private(set) var pairingKey = ""
    @Published private(set) var pairingURL = ""
    @Published private(set) var keyPersisted = true
    @Published private(set) var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    /// User's persisted choice. Defaults to mirror: it cannot lose windows on
    /// the TV and it never changes the display arrangement.
    @Published private(set) var displayMode: HostDisplayMode
    /// User's persisted quality/bandwidth tier. Lives here so it applies to
    /// every new connection; the live session forwards changes to its encoder.
    @Published private(set) var quality: HostQuality
    /// Currently effective manual target in Mbps; `nil` follows the tier.
    /// Updated by the host UI and by an authenticated client's `.clientSettings`.
    @Published private(set) var manualBitrateMbps: Int?
    /// Human-readable state of the dedicated display, nil when none exists.
    @Published private(set) var virtualDisplaySummary: String?
    @Published private(set) var virtualDisplayIsMain = false
    @Published private(set) var arrangementPromoted = false

    let deviceName: String

    /// Bidirectional file transfer for the current session. Owned here so the
    /// transfer list survives reconnects; the service is bound to exactly one
    /// authenticated session at a time.
    let fileTransfer = FileTransferService()

    /// Mirrors `displayMode` for the network queue, which must not read the
    /// main-thread published property directly.
    private var modeForSessions: HostDisplayMode
    private static let displayModeDefaultsKey = "XDRScreen.host.displayMode"

    /// Mirrors `quality` for the network queue, which creates sessions and
    /// must not read the main-thread published property directly.
    private var qualityForSessions: HostQuality
    private static let qualityDefaultsKey = "XDRScreen.host.quality"
    /// Mirrors `manualBitrateMbps` for the network queue.
    private var manualBitrateMbpsForSessions: Int?
    private static let manualBitrateDefaultsKey = "XDRScreen.host.manualBitrateMbps"

    private let networkQueue = DispatchQueue(label: "com.xdrscreen.host.network", qos: .userInitiated)
    private var listener: NWListener?
    private var session: ClientSession?
    /// At most one not-yet-promoted connection, kept while an authenticated
    /// session is streaming. It gets no encoder and no input until it proves
    /// the pairing key and takes over.
    private var pendingSession: ClientSession?
    private var pairingKeyData: Data?
    private var started = false

    // Virtual display state is main-thread confined. It is intentionally kept
    // across session disconnects so a brief Wi-Fi drop does not destroy and
    // rebuild the screen every few seconds; it is released on mode switch,
    // host stop and app termination.
    private var virtualDisplay: VirtualDisplayManager?
    private var virtualDisplaySize: VirtualDisplaySize?
    private var virtualDisplayFailure: (size: VirtualDisplaySize, at: Date, message: String)?
    /// Incremented whenever the virtual display is released or a mode switch
    /// makes outstanding async work stale. Guarded because prepare decisions
    /// run on `networkQueue` while the display itself lives on the main queue.
    private var displayEpoch = 0
    /// Cached main-display HDR capability for the host hello. Cached on the
    /// main thread so `makeSession` on the network queue never has to block on
    /// the main thread (which the termination path waits on).
    private var helloHDRCapable = false
    private let displayEpochLock = NSLock()
    private let arrangement = DisplayArrangementController()

    private override init() {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        deviceName = name.isEmpty ? "Mac" : name
        let stored = UserDefaults.standard.string(forKey: Self.displayModeDefaultsKey)
            .flatMap(HostDisplayMode.init(rawValue:))
        let mode = stored ?? .mirror
        displayMode = mode
        modeForSessions = mode
        let storedQuality = UserDefaults.standard.string(forKey: Self.qualityDefaultsKey)
            .flatMap(HostQuality.init(rawValue:))
        let quality = storedQuality ?? .auto
        self.quality = quality
        qualityForSessions = quality
        // A stored number is clamped again on read: a hand-edited or stale
        // defaults value must never reach the encoder out of range.
        let storedManual = (UserDefaults.standard.object(forKey: Self.manualBitrateDefaultsKey) as? Int)
            .map(ClientSettingsMessage.clampMbps)
        manualBitrateMbps = storedManual
        manualBitrateMbpsForSessions = storedManual
        super.init()
        arrangement.onMessage = { [weak self] text in
            self?.log(text)
        }
        fileTransfer.onLog = { [weak self] text in
            self?.log(text)
        }
    }

    // MARK: Public control

    func start() {
        guard !started else { return }
        started = true

        guard loadPairingKey() else { return }
        refreshHelloHDRCapability()
        startListener()
        refreshPermissions()
    }

    /// Main thread only. NSScreen's EDR headroom is main-thread state, and the
    /// network queue must never block on the main thread here.
    private func refreshHelloHDRCapability() {
        let capable = DisplayProbe.mainDisplay().supportsHDR
        displayEpochLock.lock()
        helloHDRCapable = capable
        displayEpochLock.unlock()
    }

    func stop() {
        networkQueue.async {
            self.listener?.cancel()
            self.listener = nil
            self.pendingSession?.close(reason: "主机已停止")
            self.pendingSession = nil
            self.session?.close(reason: "主机已停止")
            self.session = nil
            self.fileTransfer.unbind()
            self.publish {
                self.isListening = false
                self.serviceStatus = "已停止"
                self.clientStatus = "未连接"
                self.videoStatus = "空闲"
            }
            self.log("主机服务已停止")
            // The virtual display and any promoted arrangement must go away
            // with the host service, not linger on the TV's desktop.
            DispatchQueue.main.async {
                self.releaseVirtualDisplayOnMain(reason: "主机已停止")
            }
        }
    }

    /// Used from applicationWillTerminate; releases injected input and the
    /// virtual display before exit. Runs on the main thread and must not block
    /// on the session queues while they could post back to the main thread.
    func shutdownForTermination() {
        releaseVirtualDisplayOnMain(reason: "应用退出")
        networkQueue.sync {
            self.listener?.cancel()
            self.listener = nil
            self.pendingSession?.releaseInputNow()
            self.pendingSession?.close(reason: "应用退出")
            self.pendingSession = nil
            self.session?.releaseInputNow()
            self.session?.close(reason: "应用退出")
            self.session = nil
            self.fileTransfer.shutdownForTermination()
        }
    }

    // MARK: Pairing key

    @discardableResult
    private func loadPairingKey() -> Bool {
        do {
            let result = try PairingKeyStore.loadOrCreate()
            let encoded = PairingCodec.base64URL(result.data)
            pairingKeyData = result.data
            publish {
                self.pairingKey = encoded
                self.pairingURL = PairingCodec.pairingURL(key: encoded)
                self.keyPersisted = result.persisted
            }
            if let error = result.error {
                publish {
                    self.lastError = "配对密钥无法保存到钥匙串：\(error)。本次运行使用临时密钥，重启后会变化。"
                }
                log("配对密钥未能持久化（\(error)），使用临时密钥")
            }
            return true
        } catch {
            publish {
                self.serviceStatus = "配对钥匙串不可用"
                self.lastError = "无法读取配对密钥：\(error.localizedDescription) 为避免更换已配对的密钥，本次不会启动服务。请解锁钥匙串并重启本应用；密钥本身没有被修改。"
            }
            log("读取配对密钥失败：\(error.localizedDescription)；未启动服务")
            return false
        }
    }

    // MARK: Listener

    private func startListener() {
        guard let port = NWEndpoint.Port(rawValue: Wire.port) else {
            publish { self.lastError = "无效端口 \(Wire.port)"; self.serviceStatus = "监听启动失败" }
            return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableFastOpen = true
        tcp.connectionTimeout = 10
        // Detect a vanished iPad in ~15 s instead of holding a half-open
        // socket forever, so a held mouse button is never stuck for minutes.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3

        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true

        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(name: bonjourServiceName(), type: Wire.bonjourType)
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            self.listener = listener
            listener.start(queue: networkQueue)
            publish {
                self.isListening = true
                self.serviceStatus = "正在广播 \(Wire.bonjourType) · 端口 \(Wire.port)"
            }
            log("Bonjour 服务 \(Wire.bonjourType) 启动，端口 \(Wire.port)")
        } catch {
            publish {
                self.isListening = false
                self.serviceStatus = "监听启动失败"
                self.lastError = "无法监听端口 \(Wire.port)：\(error.localizedDescription)"
            }
            log("监听端口 \(Wire.port) 失败：\(error.localizedDescription)")
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            publish {
                self.isListening = true
                self.serviceStatus = "已就绪 · Bonjour \(Wire.bonjourType) · 端口 \(Wire.port)"
                self.lastError = nil
            }
        case .waiting(let error):
            let text = describeListenerError(error)
            publish {
                self.isListening = true
                self.serviceStatus = "等待中：\(text)"
                self.lastError = text
            }
            log("监听等待：\(text)")
        case .failed(let error):
            let text = describeListenerError(error)
            publish {
                self.isListening = false
                self.serviceStatus = "监听失败"
                self.lastError = "监听失败：\(text)"
            }
            log("监听失败：\(text)")
            networkQueue.async {
                self.listener?.cancel()
                self.listener = nil
            }
        case .cancelled:
            publish {
                self.isListening = false
                self.serviceStatus = "已停止"
            }
        default:
            break
        }
    }

    private func describeListenerError(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .EADDRINUSE: return "端口 \(Wire.port) 已被其他程序占用"
            case .EACCES: return "没有权限绑定端口 \(Wire.port)"
            default: return "系统错误 \(code.rawValue)"
            }
        case .dns(let code):
            return "Bonjour 注册失败（DNS 错误 \(code)）"
        case .tls(let status):
            return "TLS 错误 \(status)"
        default:
            return "\(error)"
        }
    }

    private func bonjourServiceName() -> String {
        Self.bonjourInstanceName(base: deviceName)
    }

    /// DNS-SD instance labels are limited to 63 UTF-8 *bytes*. Truncating a
    /// long CJK device name by `Character` count can exceed that and either
    /// fail registration or produce a name the iPad cannot match, so cut on a
    /// character boundary within the byte budget.
    static func bonjourInstanceName(base: String) -> String {
        var name = base.replacingOccurrences(of: ".", with: " ")
        name = name.replacingOccurrences(of: ":", with: " ")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Mac" }
        let prefix = "XDRScreen "
        let budget = max(1, 63 - prefix.utf8.count)
        let limited = truncateToUTF8Bytes(name, maxBytes: budget)
        return prefix + (limited.isEmpty ? "Mac" : limited)
    }

    static func truncateToUTF8Bytes(_ text: String, maxBytes: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let bytes = String(character).utf8.count
            guard used + bytes <= maxBytes else { break }
            result.append(character)
            used += bytes
        }
        return result
    }

    // MARK: Connections

    private func handleNewConnection(_ connection: NWConnection) {
        guard let keyData = pairingKeyData else {
            connection.cancel()
            return
        }

        // A newer connection supersedes an older unverified candidate. Neither
        // has input ownership, so this can never disturb the active client.
        if let candidate = pendingSession {
            candidate.close(reason: "被更新的连接替换")
            pendingSession = nil
        }

        if let existing = session {
            if existing.isAuthenticated {
                // Never evict a working, authenticated client on behalf of a
                // connection that has not proved it knows the pairing key.
                // Verify the candidate first and promote it only after hello.
                startCandidate(connection: connection, keyData: keyData)
                return
            }
            // An unauthenticated placeholder owns no input and no encoder.
            existing.close(reason: "等待握手的连接被新的连接替换")
            session = nil
        }

        let newSession = makeSession(connection: connection, keyData: keyData)
        session = newSession
        newSession.start()
        publish { self.clientStatus = "已连接，等待配对握手…" }
        log("接受新的 iPad 连接")
    }

    private func makeSession(connection: NWConnection, keyData: Data) -> ClientSession {
        // Only mirror mode can ever advertise HDR: the dedicated virtual
        // display reports EDR headroom 1.0 on current macOS.
        displayEpochLock.lock()
        let mirrorHDRCapable = helloHDRCapable
        displayEpochLock.unlock()
        let hdrCapable = modeForSessions == .mirror && mirrorHDRCapable
        let session = ClientSession(
            connection: connection,
            key: SymmetricKey(data: keyData),
            displayID: CGMainDisplayID(),
            hostName: deviceName,
            helloSupportsHDR: hdrCapable,
            quality: qualityForSessions,
            manualBitrateMbps: manualBitrateMbpsForSessions
        )
        session.delegate = self
        return session
    }

    private func startCandidate(connection: NWConnection, keyData: Data) {
        let candidate = makeSession(connection: connection, keyData: keyData)
        pendingSession = candidate
        candidate.start()
        log("已有活动会话：新的 iPad 连接先完成配对验证，验证通过后再接管")

        // The session's own handshake deadline covers unauthenticated sockets.
        // This also bounds a candidate that authenticated but was never
        // promoted (e.g. superseded by a newer connection in the same tick).
        networkQueue.asyncAfter(deadline: .now() + 12) { [weak self, weak candidate] in
            guard let self, let candidate, self.pendingSession === candidate else { return }
            self.pendingSession = nil
            candidate.close(reason: "新连接验证超时")
            self.log("新连接未在时限内完成验证，保留当前会话")
        }
    }

    // MARK: Display mode

    /// Persists the choice and restarts the current connection so the iPad
    /// reconnects with the new capture target. The virtual display is always
    /// released on a switch; the arrangement is restored first.
    func setDisplayMode(_ mode: HostDisplayMode) {
        guard mode != displayMode else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: Self.displayModeDefaultsKey)
        publish {
            self.displayMode = mode
            self.lastError = nil
            self.clientStatus = "未连接（显示方式已切换）"
            self.videoStatus = "空闲"
        }
        log("显示方式已切换为：\(mode.title)")

        networkQueue.async {
            self.modeForSessions = mode
            if self.pendingSession != nil {
                self.pendingSession?.close(reason: "显示方式已切换")
                self.pendingSession = nil
            }
            if self.session != nil {
                self.session?.close(reason: "显示方式已切换，iPad 将自动重连")
                self.session = nil
                self.fileTransfer.unbind()
            }
            DispatchQueue.main.async {
                self.releaseVirtualDisplayOnMain(reason: "切换显示方式")
            }
        }
    }

    // MARK: Quality

    /// Persists the tier, publishes it and forwards it to the live encoder.
    /// Unlike a display-mode switch this never drops the connection: the
    /// encoder re-applies the bitrate on its own queue.
    func setQuality(_ quality: HostQuality) {
        guard quality != self.quality else { return }
        UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityDefaultsKey)
        publish {
            self.quality = quality
            self.lastError = nil
        }
        log("画质已切换为：\(quality.title)（上限 \(quality.bitrateUpperBound / 1_000_000) Mbps）")
        networkQueue.async {
            self.qualityForSessions = quality
            self.session?.setQuality(quality)
            self.pendingSession?.setQuality(quality)
        }
    }

    // MARK: Target bitrate

    /// Persists and publishes an explicit target in Mbps; `nil` follows the
    /// quality tier. Never drops the connection: the live and candidate
    /// sessions forward the value to their encoder queues.
    func setManualBitrate(_ mbps: Int?) {
        applyManualBitrate(mbps.map(ClientSettingsMessage.clampMbps), source: .host)
    }

    private enum ManualBitrateSource {
        case host
        case client
    }

    /// Single path for the host UI and an authenticated client, so "last
    /// writer wins" holds and the published UI value is always the effective
    /// one. Persisted; the next session receives it before `start`.
    private func applyManualBitrate(_ mbps: Int?, source: ManualBitrateSource) {
        networkQueue.async {
            guard mbps != self.manualBitrateMbpsForSessions else { return }
            self.manualBitrateMbpsForSessions = mbps
            if let mbps {
                UserDefaults.standard.set(mbps, forKey: Self.manualBitrateDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.manualBitrateDefaultsKey)
            }
            self.publish { self.manualBitrateMbps = mbps }
            switch (source, mbps) {
            case (.client, .some(let value)):
                self.log("客户端已将目标码率设为 \(value) Mbps")
            case (.client, .none):
                self.log("客户端已改为跟随主机的画质档位")
            case (.host, .some(let value)):
                self.log("目标码率已设为 \(value) Mbps（手动）")
            case (.host, .none):
                self.log("目标码率已改为跟随画质档位")
            }
            self.session?.setManualBitrate(mbps)
            self.pendingSession?.setManualBitrate(mbps)
        }
    }

    /// Explicit, user-clicked primary-display switch. Never automatic: an
    /// extended display must not steal the TV's desktop while windows live
    /// there. The previous arrangement is restored on exit/disable.
    func promoteVirtualDisplayToMain() {
        DispatchQueue.main.async {
            // `virtualDisplaySize` is set only after the 2x mode has been
            // selected and verified; never promote a display that is still
            // being prepared at 1x.
            guard let manager = self.virtualDisplay, manager.isOpen,
                  self.virtualDisplaySize != nil,
                  CGDisplayIsOnline(manager.displayID) != 0 else {
                self.publish { self.lastError = "iPad 专用屏尚未创建；连接 iPad 后会自动创建，再设为主屏。" }
                return
            }
            let id = manager.displayID
            if CGDisplayIsMain(id) != 0 {
                self.publish {
                    self.virtualDisplayIsMain = true
                    self.lastError = nil
                }
                self.updateVirtualDisplayStateOnMain()
                self.log("iPad 专用屏已经是主显示器")
                return
            }

            let bounds = CGDisplayBounds(id)
            self.arrangement.promote(virtualDisplayID: id,
                                     pointWidth: bounds.width,
                                     pointHeight: bounds.height) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self.publish { self.lastError = nil }
                        self.log("已将 iPad 专用屏设为主显示器；退出应用或切换显示方式时会恢复原排列")
                    case .failure(let error):
                        self.publish { self.lastError = error.message }
                        self.log(error.message)
                    }
                    self.updateVirtualDisplayStateOnMain()
                }
            }
        }
    }

    func restoreDisplayArrangement() {
        DispatchQueue.main.async {
            let restored = self.arrangement.restoreIfNeeded()
            self.updateVirtualDisplayStateOnMain()
            if restored {
                self.publish { self.lastError = nil }
                self.log("已恢复之前的显示器排列")
            } else {
                self.publish { self.lastError = "无法自动恢复原显示器排列，请在“系统设置 › 显示器”中手动调整。" }
                self.log("恢复显示器排列失败")
            }
        }
    }

    func openDisplaySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Displays-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.displays"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: Virtual display (main thread)

    private func currentDisplayEpoch() -> Int {
        displayEpochLock.lock()
        defer { displayEpochLock.unlock() }
        return displayEpoch
    }

    @discardableResult
    private func bumpDisplayEpoch() -> Int {
        displayEpochLock.lock()
        defer { displayEpochLock.unlock() }
        displayEpoch += 1
        return displayEpoch
    }

    /// Creates the virtual display sized to the client, or reuses the one this
    /// host already owns. Calling it repeatedly with the same size across
    /// reconnects is cheap and never destroys a working screen.
    ///
    /// Creation is asynchronous: the manager returns to the main run loop and
    /// polls for the 2x mode there without blocking it, so WindowServer can
    /// publish the new display. The manager is installed into
    /// `virtualDisplay` while it is still being prepared, so a mode switch,
    /// host stop or rebuild can release it and cancel the search.
    ///
    /// `completion` is called on the main queue together with the display
    /// epoch in effect during this work, so the caller can reject a result
    /// that a later mode switch has already invalidated.
    private func ensureVirtualDisplay(size: VirtualDisplaySize,
                                      completion: @escaping (Result<CaptureTarget, DisplaySetupError>, Int) -> Void) {
        DispatchQueue.main.async {
            var epoch = self.currentDisplayEpoch()
            guard self.displayMode == .dedicated else {
                completion(.failure(DisplaySetupError("显示方式已切换；本次退回镜像当前屏幕。")), epoch)
                return
            }

            // Reuse only a display that is still in the exact 2x mode this host
            // created: same pixels, points at exactly half, same refresh rate.
            // Matching pixels alone would keep a screen the user (or the
            // system) switched to a 1x mode of the same pixel size, and the
            // session would stream from a display whose desktop is 2732x2048
            // points instead of the 1366x1024 the client asked for.
            if let manager = self.virtualDisplay, manager.isOpen,
               self.virtualDisplaySize == size,
               CGDisplayIsOnline(manager.displayID) != 0,
               let mode = CGDisplayCopyDisplayMode(manager.displayID),
               VirtualDisplayManager.isTargetHiDPIMode(VirtualDisplayManager.snapshot(of: mode),
                                                       pixelWidth: size.width,
                                                       pixelHeight: size.height,
                                                       refreshRate: VirtualDisplaySizing.refreshRate) {
                self.updateVirtualDisplayStateOnMain()
                completion(.success(CaptureTarget(displayID: manager.displayID,
                                                  pixelWidth: size.width,
                                                  pixelHeight: size.height)), epoch)
                return
            }

            // A stale or differently sized screen must be fully released
            // before another one is created. This also cancels an in-flight
            // creation whose result belongs to a superseded request.
            if self.virtualDisplay != nil {
                self.releaseVirtualDisplayOnMain(reason: "重建专用屏")
                epoch = self.currentDisplayEpoch()
            }

            // Do not hammer a display creation that just failed: a reconnect
            // a second later should not retry the same failing allocation.
            if let failure = self.virtualDisplayFailure, failure.size == size,
               Date().timeIntervalSince(failure.at) < 30 {
                completion(.failure(DisplaySetupError(failure.message)), epoch)
                return
            }

            let manager = VirtualDisplayManager()
            manager.displayName = "XDRScreen iPad"
            manager.prefersHiDPI = true
            manager.pixelsPerInch = 264
            // Publish the in-flight manager immediately so release paths can
            // cancel it; `virtualDisplaySize` stays nil until it is verified
            // and ready, so the reuse check above never picks a half-built
            // display.
            self.virtualDisplay = manager
            self.virtualDisplaySize = nil
            self.log("正在创建 iPad 专用屏：\(size.width)×\(size.height) px · "
                     + "\(size.width / 2)×\(size.height / 2) pt · "
                     + "\(Int(VirtualDisplaySizing.refreshRate)) Hz · SDR")

            manager.create(width: size.width,
                           height: size.height,
                           refreshRate: VirtualDisplaySizing.refreshRate) { [weak self] result in
                // Delivered on the main queue.
                guard let self else { return }

                // The display was released (mode switch, host stop, rebuild)
                // while it was still being prepared. The manager has already
                // cleaned up and invalidated any later callback; resolve the
                // request so the session state machine never waits forever.
                guard self.virtualDisplay === manager else {
                    completion(.failure(DisplaySetupError("虚拟屏创建已取消；本次退回镜像当前屏幕。")), epoch)
                    return
                }

                switch result {
                case .success(let id):
                    guard CGDisplayIsOnline(id) != 0 else {
                        self.virtualDisplay = nil
                        self.virtualDisplaySize = nil
                        manager.close()
                        let message = "无法创建 iPad 专用屏（虚拟屏创建后未上线。）；已退回镜像当前屏幕。"
                        self.virtualDisplayFailure = (size: size, at: Date(), message: message)
                        self.updateVirtualDisplayStateOnMain()
                        self.log(message)
                        completion(.failure(DisplaySetupError(message)), epoch)
                        return
                    }
                    self.virtualDisplaySize = size
                    self.virtualDisplayFailure = nil
                    self.updateVirtualDisplayStateOnMain()
                    self.log("已创建 iPad 专用屏：displayID \(id) · \(size.width)×\(size.height) px · "
                             + "\(size.width / 2)×\(size.height / 2) pt · "
                             + "\(Int(VirtualDisplaySizing.refreshRate)) Hz · SDR")
                    completion(.success(CaptureTarget(displayID: id,
                                                      pixelWidth: size.width,
                                                      pixelHeight: size.height)), epoch)
                case .failure(let error):
                    self.virtualDisplay = nil
                    self.virtualDisplaySize = nil
                    manager.close()
                    let message = "无法创建 iPad 专用屏（\(error.localizedDescription)）；已退回镜像当前屏幕。"
                    self.virtualDisplayFailure = (size: size, at: Date(), message: message)
                    self.updateVirtualDisplayStateOnMain()
                    self.log(message)
                    completion(.failure(DisplaySetupError(message)), epoch)
                }
            }
        }
    }

    /// Main thread only. Restores the physical arrangement, closes the virtual
    /// display so the host's screen disappears with the app, and invalidates
    /// any in-flight async display work.
    private func releaseVirtualDisplayOnMain(reason: String) {
        bumpDisplayEpoch()
        if arrangement.isPromoted {
            let restored = arrangement.restoreIfNeeded()
            if !restored { log("释放专用屏时未能恢复原显示器排列，请在系统设置中检查") }
        }
        if let manager = virtualDisplay {
            // Drop the reference first: `close()` answers a pending create with
            // a cancellation on this thread, and that completion must see the
            // display as already gone instead of reporting a fresh failure.
            virtualDisplay = nil
            virtualDisplaySize = nil
            manager.close()
            log("已释放 iPad 专用屏（\(reason)）")
        }
        // An explicit release also clears the failure backoff, so switching
        // away and back lets the next connection try again.
        virtualDisplayFailure = nil
        updateVirtualDisplayStateOnMain()
    }

    private func updateVirtualDisplayStateOnMain() {
        var summary: String?
        var isMain = false

        if let manager = virtualDisplay, manager.isOpen {
            let id = manager.displayID
            var pixelText = "像素未知"
            if let mode = CGDisplayCopyDisplayMode(id) {
                pixelText = "\(mode.pixelWidth)×\(mode.pixelHeight) px"
            } else if let observed = manager.observedPixelSize {
                pixelText = "\(Int(observed.width))×\(Int(observed.height)) px"
            }
            let bounds = CGDisplayBounds(id)
            let pointText = "\(Int(bounds.width))×\(Int(bounds.height)) pt"
            let headroom = DisplayProbe.capability(for: id).edrHeadroom
            // The virtual display is SDR. Never call it HDR just because the
            // iPad panel, colour primaries or bit depth would allow it.
            let range = headroom > 1.0
                ? String(format: "EDR %.2f（仍按 SDR 串流）", headroom)
                : String(format: "SDR（EDR %.2f）", headroom)
            summary = "displayID \(id) · \(pixelText) / \(pointText) · "
                + "\(Int(VirtualDisplaySizing.refreshRate)) Hz · \(range)"
            isMain = CGDisplayIsMain(id) != 0
        }

        publish {
            self.virtualDisplaySummary = summary
            self.virtualDisplayIsMain = isMain
            self.arrangementPromoted = self.arrangement.isPromoted
        }
    }

    // MARK: Permissions

    func refreshPermissions() {
        if Thread.isMainThread { refreshHelloHDRCapability() }
        let screen = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        publish {
            if self.screenRecordingGranted != screen { self.screenRecordingGranted = screen }
            if self.accessibilityGranted != accessibility { self.accessibilityGranted = accessibility }
        }
    }

    func requestScreenRecording() {
        let granted = CGRequestScreenCaptureAccess()
        refreshPermissions()
        log(granted ? "屏幕录制权限已授予" : "屏幕录制权限尚未授予")
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermissions()
        log("已请求辅助功能授权")
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Logging / publishing

    func log(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(text)"
        publish {
            self.eventLog.append(line)
            if self.eventLog.count > 40 {
                self.eventLog.removeFirst(self.eventLog.count - 40)
            }
        }
    }

    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

// MARK: - ClientSessionDelegate

extension HostController: ClientSessionDelegate {

    // Every callback that touches published UI state checks that the session
    // is still the current one, so a replaced session finishing its teardown
    // can never report the new session as disconnected or idle.

    func clientSession(_ session: ClientSession, didUpdateClient name: String) {
        networkQueue.async {
            guard self.session === session else { return }
            self.publish {
                self.clientStatus = "已连接：\(name)"
                // A fresh authenticated session invalidates old failures.
                self.lastError = nil
            }
        }
    }

    func clientSession(_ session: ClientSession, didUpdateStream text: String) {
        networkQueue.async {
            guard self.session === session else { return }
            self.publish { self.videoStatus = text }
        }
    }

    func clientSession(_ session: ClientSession, didLog text: String) {
        log(text)
    }

    func clientSession(_ session: ClientSession, didReportIssue text: String) {
        networkQueue.async {
            guard self.session === session else { return }
            self.publish { self.lastError = text }
            self.log(text)
        }
    }

    func clientSession(_ session: ClientSession, didAuthenticate name: String, request: CaptureRequest) {
        networkQueue.async {
            if self.pendingSession === session {
                // Candidate proved the pairing key: promote it, then close the
                // previous session before the new one starts streaming.
                self.pendingSession = nil
                let previous = self.session
                self.session = session
                // Rebinding cancels the old session's transfers; a transfer
                // must never straddle two channels.
                self.fileTransfer.bind(to: session)

                if let previous, previous !== session {
                    self.log("新的 iPad 连接（\(name)）已验证，正在结束旧会话")
                    previous.close(reason: "被已验证的新连接替换") { [weak self, weak session] in
                        guard let self, let session else { return }
                        self.networkQueue.async {
                            self.prepareAndActivate(session, request: request)
                        }
                    }
                } else {
                    self.log("新的 iPad 连接（\(name)）已验证")
                    self.prepareAndActivate(session, request: request)
                }
                return
            }

            guard self.session === session else {
                // Superseded before it could take over; it owns nothing.
                session.close(reason: "不再是当前会话")
                return
            }
            self.log("新的 iPad 连接（\(name)）已验证")
            self.fileTransfer.bind(to: session)
            self.prepareAndActivate(session, request: request)
        }
    }

    func clientSession(_ session: ClientSession, didReceiveFileTransfer packet: WirePacket) {
        networkQueue.async {
            // A candidate that has not taken over owns no file channel.
            guard self.session === session else { return }
            self.fileTransfer.handle(packet)
        }
    }

    func clientSession(_ session: ClientSession, didReceiveManualBitrateMbps mbps: Int?) {
        networkQueue.async {
            // Only a live connection the controller knows about may change the
            // persisted target; a torn-down or superseded session cannot.
            guard self.session === session || self.pendingSession === session else { return }
            self.applyManualBitrate(mbps, source: .client)
        }
    }

    /// Chooses the capture target for one authenticated session and activates
    /// it. Dedicated mode creates (or reuses) the virtual display first; any
    /// failure releases it fully and falls back to mirroring, with a report.
    /// Runs on `networkQueue`.
    private func prepareAndActivate(_ session: ClientSession, request: CaptureRequest) {
        guard self.session === session, session.isAuthenticated else { return }

        guard modeForSessions == .dedicated else {
            session.activate(target: mirrorTarget())
            return
        }

        guard let size = VirtualDisplaySizing.normalizedSize(clientWidth: request.clientWidth,
                                                             clientHeight: request.clientHeight) else {
            let message = "iPad 请求的尺寸 \(request.clientWidth)×\(request.clientHeight) 无法用于专用屏；本次退回镜像当前屏幕。"
            publish { self.lastError = message }
            log(message)
            session.activate(target: mirrorTarget())
            return
        }

        ensureVirtualDisplay(size: size) { [weak self, weak session] result, epoch in
            guard let self, let session else { return }
            self.networkQueue.async {
                // A stale async result must never take over a newer session or
                // a display mode that has been switched in the meantime.
                guard self.session === session else { return }
                guard self.modeForSessions == .dedicated, self.currentDisplayEpoch() == epoch else {
                    session.activate(target: self.mirrorTarget())
                    return
                }
                switch result {
                case .success(let target):
                    session.activate(target: target)
                case .failure(let error):
                    self.publish { self.lastError = error.message }
                    self.log(error.message)
                    session.activate(target: self.mirrorTarget())
                }
            }
        }
    }

    private func mirrorTarget() -> CaptureTarget {
        // Input mapping must match whatever ScreenCaptureKit ends up using;
        // mirror mode always intentionally targets the current main display.
        CaptureTarget(displayID: CGMainDisplayID(), pixelWidth: 0, pixelHeight: 0)
    }

    func clientSessionDidEnd(_ session: ClientSession, reason: String) {
        networkQueue.async {
            // Identity-checked: only the bound session cancels transfers.
            self.fileTransfer.unbind(from: session)
            let wasCandidate = self.pendingSession === session
            if wasCandidate {
                self.pendingSession = nil
            }
            guard self.session === session else {
                self.log(wasCandidate
                         ? "候选连接已结束：\(reason)"
                         : "旧会话结束（当前会话不受影响）：\(reason)")
                return
            }
            self.session = nil
            self.publish {
                self.clientStatus = "未连接"
                self.videoStatus = "空闲"
            }
            self.log("iPad 会话结束：\(reason)")
        }
    }
}
