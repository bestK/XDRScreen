//
//  ClientController.swift
//  XDRScreen (iPad client)
//
//  Owns discovery, pairing, the encrypted connection and the control plane
//  state machine. Rendering lives in ClientVideoView (HDR/Metal with an
//  AVSampleBufferDisplayLayer fallback); touch and keyboard input live in
//  TouchView. Everything network related is confined to one serial queue; only
//  `onSnapshot` is delivered on the main queue.
//

import AVFoundation
import CryptoKit
import Foundation
import Network
import Security
import UIKit

// MARK: - Pairing material

/// The one Mac this iPad is paired with. The key only ever lives in the
/// Keychain; this in-memory copy exists for the lifetime of the app.
struct Pairing {
    let hostName: String
    let key: Data
    let pairedAt: Date
}

enum PairingStoreError: LocalizedError {
    case invalidKey
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "密钥必须是 32 字节（AES-256）。"
        case .keychain(let status):
            return "无法写入系统钥匙串（错误 \(status)）。"
        }
    }
}

/// Keychain-backed persistence for the paired key. The host service name and
/// the auto-connect preference use UserDefaults, never the key itself.
enum PairingStore {
    private static let service = "dev.xdrscreen.pairing"
    private static let account = "mac-host"

    private struct Record: Codable {
        let hostName: String
        let key: String
        let pairedAt: Date
    }

    static func load() -> Pairing? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              let key = Data(base64Encoded: record.key),
              key.count == Wire.keyByteCount else {
            return nil
        }
        return Pairing(hostName: record.hostName, key: key, pairedAt: record.pairedAt)
    }

    static func save(_ pairing: Pairing) throws {
        guard pairing.key.count == Wire.keyByteCount else {
            throw PairingStoreError.invalidKey
        }
        let record = Record(
            hostName: pairing.hostName,
            key: pairing.key.base64EncodedString(),
            pairedAt: pairing.pairedAt
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(record)
        } catch {
            throw PairingStoreError.keychain(errSecParam)
        }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let changes: [String: Any] = [
            kSecValueData as String: data
        ]

        var status = SecItemUpdate(base as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw PairingStoreError.keychain(status)
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Parses the key from a QR payload or a hand-typed value. Accepts:
/// `xdrscreen://pair?key=<base64url>`, a bare base64url/base64 key, or 64 hex
/// characters. Never logs the value.
enum PairingKey {
    static func decode(_ text: String) -> Data? {
        var token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        if token.lowercased().hasPrefix("xdrscreen://") {
            guard let components = URLComponents(string: token),
                  components.scheme?.lowercased() == "xdrscreen",
                  let value = components.queryItems?.first(where: { $0.name.lowercased() == "key" })?.value else {
                return nil
            }
            token = value
        }

        token = token
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")

        // Try hex first when the shape is unmistakable.
        if token.count == Wire.keyByteCount * 2, token.allSatisfy({ $0.isHexDigit }) {
            var bytes = Data(capacity: Wire.keyByteCount)
            var index = token.startIndex
            while index < token.endIndex {
                let next = token.index(index, offsetBy: 2)
                guard let byte = UInt8(token[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            if bytes.count == Wire.keyByteCount { return bytes }
        }

        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        if let data = Data(base64Encoded: base64), data.count == Wire.keyByteCount {
            return data
        }
        if let data = Data(base64Encoded: token), data.count == Wire.keyByteCount {
            return data
        }
        return nil
    }
}

// MARK: - UI-facing models

struct ClientHost: Equatable, Identifiable {
    /// Bonjour service instance name, which is also what we persist.
    let name: String
    var id: String { name }
}

struct ClientStreamStatus: Equatable {
    let width: Int
    let height: Int
    let fps: Int
    let codec: String
    /// Honest description of what is actually being presented.
    let hdrText: String
    let colorText: String
}

struct ClientSnapshot: Equatable {
    enum Phase: Equatable {
        case idle
        case searching
        case connecting(String)
        case handshaking(String)
        case streaming
        case reconnecting(String)
        case failed
        case paused
    }

    var phase: Phase = .idle
    var hosts: [ClientHost] = []
    var pairedHostName: String?
    var hasPairing = false
    var autoConnect = true
    var needsRepair = false
    var detail = ""
    var stream: ClientStreamStatus?
    var latencyMs = 0
    var lastStatusMessage: String?
    /// Explicit target bitrate the user picked on this iPad, in Mbps. `nil`
    /// means "follow the host"; the control-bar action sheet checks this row.
    var preferredBitrateMbps: Int?
}

// MARK: - Controller

final class ClientController {

    private static let autoConnectKey = "dev.xdrscreen.client.autoConnect"
    private static let pairedHostKey = "dev.xdrscreen.client.pairedHostName"
    private static let preferredBitrateKey = "dev.xdrscreen.client.preferredBitrateMbps"

    private struct Capabilities {
        var pixelWidth: Int
        var pixelHeight: Int
        var maxFPS: Int
        var supportsHDR: Bool
        var deviceName: String
    }

    // Main queue.
    private(set) var snapshot = ClientSnapshot()
    var onSnapshot: ((ClientSnapshot) -> Void)?

    /// File transfer state, published on the main queue. The controller owns
    /// the service so binding follows the connection lifetime exactly.
    let fileTransfer = FileTransferService()

    // Everything below is confined to `queue`.
    private let queue = DispatchQueue(label: "dev.xdrscreen.client.network", qos: .userInitiated)

    private var started = false
    private var pairing: Pairing?
    private var autoConnect = true
    private var wantsConnection = false
    private var suspended = false
    private var needsRepair = false
    /// User's saved target in Mbps; `nil` follows the host. Restored on launch
    /// and re-sent to the host after every authenticated connection.
    private var preferredBitrateMbps: Int?

    private var phase: ClientSnapshot.Phase = .idle
    private var detail = ""
    private var hostMap: [String: ClientHost] = [:]
    private var streamStatus: ClientStreamStatus?
    private var latencyMs = 0

    private var browser: NWBrowser?
    private var browserRestartWork: DispatchWorkItem?
    private var connection: NWConnection?
    private var channel: SecureChannel?
    /// The authenticated-session wrapper the file service writes through.
    /// Created on `.ready` (after the handshake) and detached on teardown.
    private var fileChannel: ClientFileSendChannel?
    private var currentHostName: String?
    private var connectionGeneration = 0
    private var everReady = false
    private var hasVideoFormat = false
    private var currentFormat: VideoFormatMessage?
    /// A format message was accepted but the main queue has not installed it
    /// yet. Frames that arrive in this window belong to the new format and
    /// must not reach the decoder that still holds the previous one.
    private var formatApplyPending = false
    private var awaitingFirstFrame = false
    private var lastFrameAt: Date?

    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var connectTimeoutWork: DispatchWorkItem?
    private var handshakeTimeoutWork: DispatchWorkItem?

    /// Pixel box carried by the Hello of the session that currently owns the
    /// Mac's virtual display. Nil until a Hello has been sent; cleared when the
    /// connection goes away so a stale baseline cannot trigger a reconnect.
    private var helloPixelSize: DisplaySizeChangeDetector.Size?
    /// Coalesces rotation-animation and repeated-layout size updates into one
    /// check after the interface settles.
    private var sizeChangeWork: DispatchWorkItem?
    /// Set for exactly one connection attempt so the setup panel explains why
    /// the picture is being re-negotiated instead of looking like a failure.
    private var sizeRenegotiationInFlight = false
    /// Main-queue only: avoids dispatching an identical size on every layout.
    private var lastObservedPixelSize: DisplaySizeChangeDetector.Size?

    private var pingTimer: DispatchSourceTimer?
    private var pingSentAt: [UInt64: Date] = [:]
    /// Half-open-link detector. A successful write only means the bytes entered
    /// the local send buffer, and the 3-second ping keeps TCP keepalive from
    /// ever firing, so a socket that is still "connected" is no proof that the
    /// Mac is there. Armed after the authenticated handshake and refreshed by
    /// every authenticated packet; see HostSilenceWatchdog.
    private var hostSilence = HostSilenceWatchdog()
    private var lastLatencyPublishAt = Date.distantPast
    private var lastKeyframeRequestAt = Date.distantPast
    private var lastStatusMessage: String?
    /// Bounds the post-format IDR request to one per connection+format. The
    /// format is installed on the main queue while frames keep arriving on this
    /// queue, so the key frame the host sends right after the format message is
    /// dropped; the renderer requests a new one once the format is actually in
    /// place. See FormatKeyframeGate for the exact rules.
    private var formatGate = FormatKeyframeGate()

    // Shared with the main queue.
    private let displayLock = NSLock()
    private weak var storedDisplayView: ClientVideoView?

    private var displayView: ClientVideoView? {
        get {
            displayLock.lock()
            defer { displayLock.unlock() }
            return storedDisplayView
        }
        set {
            displayLock.lock()
            storedDisplayView = newValue
            displayLock.unlock()
        }
    }

    private let capabilityLock = NSLock()
    private var capabilities = Capabilities(
        pixelWidth: 1200,
        pixelHeight: 1600,
        maxFPS: 60,
        supportsHDR: false,
        deviceName: "iPad"
    )

    // MARK: Lifecycle

    init() {
        let defaults = UserDefaults.standard
        autoConnect = defaults.object(forKey: Self.autoConnectKey) as? Bool ?? true
        // Re-clamp on read: a stale or hand-edited defaults value must never
        // be sent outside the range the host accepts.
        preferredBitrateMbps = (defaults.object(forKey: Self.preferredBitrateKey) as? Int)
            .map(ClientSettingsMessage.clampMbps)
        if var stored = PairingStore.load() {
            // The last host the user picked wins over the host that happened to
            // be selected when the key was saved. The key itself stays in the
            // Keychain; only the remembered name changes.
            if let selected = defaults.string(forKey: Self.pairedHostKey),
               !selected.isEmpty,
               selected != stored.hostName {
                stored = Pairing(
                    hostName: selected,
                    key: stored.key,
                    pairedAt: stored.pairedAt
                )
            }
            pairing = stored
        }
    }

    func attach(displayView: ClientVideoView) {
        self.displayView = displayView
    }

    /// Called once from the root view controller after the view exists.
    func start() {
        guard !started else { return }
        started = true
        queue.async { [weak self] in
            guard let self else { return }
            self.startBrowserLocked()
            self.publishLocked()
            if self.autoConnect, let pairing = self.pairing {
                self.wantsConnection = true
                self.phase = .searching
                self.detail = "正在查找 \(pairing.hostName)…"
                self.publishLocked()
                self.beginConnectionLocked()
            } else {
                self.phase = .idle
                self.detail = self.pairing == nil
                    ? ""
                    : "已配对 \(self.pairing?.hostName ?? "")，点按连接或开启自动连接"
                self.publishLocked()
            }
        }
    }

    /// Must be called on the main queue, e.g. from viewDidLayoutSubviews.
    /// `interfaceSize` is the current interface size in points, so rotation is
    /// reflected in subsequent Hello messages. The latest value is always kept:
    /// a change while the app is in the background or before the first Hello is
    /// therefore picked up by the next connection attempt.
    func updateDisplayCapabilities(interfaceSize: CGSize, scale: CGFloat) {
        guard interfaceSize.width > 1, interfaceSize.height > 1, scale > 0 else { return }
        let screen = UIScreen.main
        let pixelWidth = Int((interfaceSize.width * scale).rounded())
        let pixelHeight = Int((interfaceSize.height * scale).rounded())
        let maxFPS = min(max(screen.maximumFramesPerSecond, 30), 60)
        let supportsHDR = DisplayHDRSupport.isSupported
        let name = UIDevice.current.name
        capabilityLock.lock()
        capabilities = Capabilities(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            maxFPS: maxFPS,
            supportsHDR: supportsHDR,
            deviceName: name.isEmpty ? "iPad" : name
        )
        capabilityLock.unlock()

        let size = DisplaySizeChangeDetector.Size(width: pixelWidth, height: pixelHeight)
        guard size != lastObservedPixelSize else { return }
        lastObservedPixelSize = size
        queue.async { [weak self] in
            self?.scheduleSizeCheckLocked()
        }
    }

    // MARK: User intents (main queue)

    func connect(toHostNamed name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.pairing != nil else {
                self.phase = .failed
                self.detail = "尚未配对。请先选择这台 Mac 并扫描它显示的二维码。"
                self.publishLocked()
                return
            }
            self.rememberHostLocked(name)
            self.wantsConnection = true
            self.suspended = false
            self.needsRepair = false
            self.reconnectAttempt = 0
            self.startBrowserIfNeededLocked()
            self.beginConnectionLocked(hostName: name)
        }
    }

    /// Persists the discovered Mac the user chose. Only the host name changes;
    /// the 32-byte key is copied from the existing Keychain-backed pairing and
    /// is never written to UserDefaults.
    private func rememberHostLocked(_ hostName: String) {
        guard !hostName.isEmpty else { return }
        UserDefaults.standard.set(hostName, forKey: Self.pairedHostKey)
        guard let current = pairing, current.hostName != hostName else { return }
        let updated = Pairing(
            hostName: hostName,
            key: current.key,
            pairedAt: current.pairedAt
        )
        pairing = updated
        do {
            try PairingStore.save(updated)
        } catch {
            // The selection still survives in UserDefaults; the key is already
            // persisted, so this only costs a manual tap next launch.
            lastStatusMessage = "无法保存所选主机：\(error.localizedDescription)"
        }
    }

    /// Saves the key synchronously (Keychain) and then reconnects. Returns a
    /// failure without touching the stored key when the input is invalid.
    func pair(hostName: String, key: Data) -> Result<Void, Error> {
        guard key.count == Wire.keyByteCount else {
            return .failure(PairingStoreError.invalidKey)
        }
        let pairing = Pairing(hostName: hostName, key: key, pairedAt: Date())
        do {
            try PairingStore.save(pairing)
        } catch {
            return .failure(error)
        }
        UserDefaults.standard.set(hostName, forKey: Self.pairedHostKey)

        queue.async { [weak self] in
            guard let self else { return }
            self.pairing = pairing
            self.wantsConnection = true
            self.suspended = false
            self.needsRepair = false
            self.reconnectAttempt = 0
            self.startBrowserIfNeededLocked()
            self.beginConnectionLocked(hostName: hostName)
        }
        return .success(())
    }

    func forgetPairing() {
        PairingStore.delete()
        UserDefaults.standard.removeObject(forKey: Self.pairedHostKey)
        queue.async { [weak self] in
            guard let self else { return }
            self.pairing = nil
            self.wantsConnection = false
            self.needsRepair = false
            self.reconnectAttempt = 0
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.cancelConnectionLocked()
            self.phase = .idle
            self.detail = "配对密钥已清除"
            self.streamStatus = nil
            self.publishLocked()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsConnection = false
            self.suspended = false
            self.reconnectAttempt = 0
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.cancelConnectionLocked()
            self.phase = .idle
            self.detail = "已断开"
            self.streamStatus = nil
            self.publishLocked()
        }
    }

    func retryConnection() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.pairing != nil else {
                self.phase = .idle
                self.publishLocked()
                return
            }
            self.wantsConnection = true
            self.suspended = false
            self.needsRepair = false
            self.reconnectAttempt = 0
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            // An explicit retry also restarts a browser that gave up after a
            // permission error, so the host list comes back without relaunching.
            self.startBrowserLocked()
            self.beginConnectionLocked()
        }
    }

    func restartDiscovery() {
        queue.async { [weak self] in
            self?.startBrowserLocked()
        }
    }

    func setAutoConnect(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.autoConnectKey)
        queue.async { [weak self] in
            guard let self else { return }
            self.autoConnect = enabled
            if enabled, self.pairing != nil, self.channel == nil, !self.suspended, self.phase != .streaming {
                self.wantsConnection = true
                self.beginConnectionLocked()
            }
            self.publishLocked()
        }
    }

    /// Saves the target bitrate chosen in the control bar (`nil` = follow the
    /// host) and pushes it to the host immediately when the channel is
    /// authenticated. While disconnected the value is only stored; the next
    /// connection sends it right after its hello.
    func setPreferredBitrateMbps(_ mbps: Int?) {
        let normalized = mbps.map(ClientSettingsMessage.clampMbps)
        queue.async { [weak self] in
            guard let self else { return }
            self.preferredBitrateMbps = normalized
            if let normalized {
                UserDefaults.standard.set(normalized, forKey: Self.preferredBitrateKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.preferredBitrateKey)
            }
            if self.everReady, self.channel != nil {
                // `force` matters for the nil case: choosing "跟随主机" must
                // clear a target that was sent earlier in this connection.
                self.sendClientSettingsLocked(force: true)
            }
            self.publishLocked()
        }
    }

    func sendInput(_ message: InputMessage) {
        guard let data = try? WireJSON.encode(message) else { return }
        queue.async { [weak self] in
            guard let self, let channel = self.channel, self.everReady else { return }
            channel.send(.input, payload: data, completion: nil)
        }
    }

    func requestKeyframe() {
        queue.async { [weak self] in
            self?.requestKeyframeLocked()
        }
    }

    /// First sample buffer was handed to the display layer for this connection.
    func markFirstFrameRendered() {
        queue.async { [weak self] in
            guard let self, self.channel != nil else { return }
            self.handshakeTimeoutWork?.cancel()
            self.handshakeTimeoutWork = nil
            self.awaitingFirstFrame = false
            self.reconnectAttempt = 0
            self.needsRepair = false
            if self.phase != .streaming {
                self.phase = .streaming
                self.detail = ""
                self.publishLocked()
            }
        }
    }

    func reportRenderFailure(_ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastStatusMessage = message
            self.publishLocked()
            self.requestKeyframeLocked()
        }
    }

    /// No renderer on this device can present the format the Mac sent. Retrying
    /// the same connection would only repeat the failure, so stop and leave an
    /// actionable message instead of a black screen that looks connected.
    ///
    /// `format` identifies the session this report belongs to: if it is no
    /// longer the current format, the report is stale and must not tear down a
    /// newer connection.
    func reportRendererUnavailable(_ message: String, format: VideoFormatMessage) {
        queue.async { [weak self] in
            guard let self, self.currentFormat == format else { return }
            // No decoder can consume an IDR for this format; never ask for one.
            self.formatGate.rendererBecameTerminal()
            self.cancelConnectionLocked()
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.reconnectAttempt = 0
            self.wantsConnection = false
            self.needsRepair = false
            self.phase = .failed
            self.detail = message
            self.publishLocked()
        }
    }

    // MARK: App lifecycle

    func handleDidEnterBackground() {
        queue.async { [weak self] in
            guard let self, !self.suspended else { return }
            self.suspended = true
            self.formatGate.appDidSuspend()
            // Cancel first so the rows keep the background reason; the unbind
            // that follows then finds nothing active to overwrite it with.
            self.fileTransfer.cancelAllForBackground()
            self.cancelConnectionLocked()
            self.stopBrowserLocked()
            self.phase = .paused
            self.detail = self.wantsConnection ? "已暂停，回到前台后自动恢复" : "已暂停"
            self.streamStatus = nil
            self.publishLocked()
        }
    }

    /// Called from `applicationWillTerminate`. Deletes unfinished temp files
    /// synchronously, before the process can exit.
    func handleWillTerminate() {
        fileTransfer.shutdownForTermination()
    }

    func handleWillEnterForeground() {
        queue.async { [weak self] in
            guard let self, self.suspended else { return }
            self.suspended = false
            self.formatGate.appDidResume()
            self.startBrowserLocked()
            if self.wantsConnection, self.pairing != nil {
                self.phase = .searching
                self.detail = "正在恢复连接…"
                self.publishLocked()
                self.beginConnectionLocked()
            } else {
                self.phase = .idle
                self.detail = ""
                self.publishLocked()
            }
        }
    }

    deinit {
        browser?.cancel()
        pingTimer?.cancel()
        channel?.close()
    }

    // MARK: - Discovery (queue)

    private func startBrowserIfNeededLocked() {
        if browser == nil {
            startBrowserLocked()
        }
    }

    private func startBrowserLocked() {
        stopBrowserLocked()
        let parameters = NWParameters.tcp
        let browser = NWBrowser(
            for: .bonjour(type: Wire.bonjourType, domain: "local."),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            self.handleBrowserStateLocked(state)
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            self.updateHostsLocked(results)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func stopBrowserLocked() {
        browserRestartWork?.cancel()
        browserRestartWork = nil
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
    }

    private func handleBrowserStateLocked(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            if hostMap.isEmpty {
                detail = pairing == nil
                    ? "在 Mac 上打开 XDRScreen 后，它会出现在这里"
                    : "正在查找 \(pairing?.hostName ?? "Mac")…"
                publishLocked()
            }
        case .waiting(let error):
            detail = Self.localNetworkPermissionMessage(error)
                ?? "搜索服务暂不可用：\(Self.describe(error))"
            publishLocked()
        case .failed(let error):
            if let permissionMessage = Self.localNetworkPermissionMessage(error) {
                // Retrying cannot fix a denied permission and would spin a
                // failed browser every few seconds. Wait for the user.
                detail = permissionMessage
                publishLocked()
                return
            }
            detail = "Bonjour 搜索失败：\(Self.describe(error))"
            publishLocked()
            scheduleBrowserRestartLocked()
        case .cancelled:
            break
        default:
            break
        }
    }

    private func scheduleBrowserRestartLocked() {
        guard !suspended, browserRestartWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.suspended else { return }
            self.browserRestartWork = nil
            self.startBrowserLocked()
        }
        browserRestartWork = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func updateHostsLocked(_ results: Set<NWBrowser.Result>) {
        var updated: [String: ClientHost] = [:]
        for result in results {
            if case let .service(name, _, _, _) = result.endpoint {
                updated[name] = ClientHost(name: name)
            }
        }
        let oldNames = hostMap.keys.sorted()
        let newNames = updated.keys.sorted()
        hostMap = updated
        if oldNames != newNames {
            publishLocked()
        }
    }

    // MARK: - Connection (queue)

    private func beginConnectionLocked(hostName: String? = nil) {
        guard !suspended, let pairing else { return }
        let host = hostName ?? pairing.hostName

        cancelConnectionLocked()
        reconnectWork?.cancel()
        reconnectWork = nil

        let generation = connectionGeneration
        formatGate.connectionDidStart(generation)
        currentHostName = host
        everReady = false
        hasVideoFormat = false
        formatApplyPending = false
        awaitingFirstFrame = false
        currentFormat = nil
        lastFrameAt = nil
        lastStatusMessage = nil

        phase = .connecting(host)
        if sizeRenegotiationInFlight {
            // Consumed by this attempt. A later failure falls back to the
            // ordinary retry wording instead of claiming another negotiation.
            sizeRenegotiationInFlight = false
            detail = "屏幕方向或尺寸已改变，正在按新尺寸重新协商画面…"
        } else {
            detail = reconnectAttempt > 0 ? "第 \(reconnectAttempt + 1) 次尝试" : ""
        }
        publishLocked()

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 3
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: nil, tcp: tcp)

        let endpoint = NWEndpoint.service(
            name: host,
            type: Wire.bonjourType,
            domain: "local.",
            interface: nil
        )
        let connection = NWConnection(to: endpoint, using: parameters)
        let channel = SecureChannel(
            connection: connection,
            key: SymmetricKey(data: pairing.key),
            queue: queue
        )
        channel.onState = { [weak self] state in
            self?.handleConnectionStateLocked(state, generation: generation)
        }
        channel.onPacket = { [weak self] packet in
            self?.handlePacketLocked(packet, generation: generation)
        }

        self.connection = connection
        self.channel = channel
        channel.start()

        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.connectionGeneration == generation,
                  !self.everReady else { return }
            self.failConnectionLocked(
                "连接超时，未找到 \(host)",
                generation: generation,
                error: nil
            )
        }
        connectTimeoutWork = timeout
        queue.asyncAfter(deadline: .now() + 9, execute: timeout)
    }

    private func cancelConnectionLocked() {
        connectionGeneration += 1
        // Detach file transfer before the socket goes away. The service queue
        // cancels active transfers and deletes unfinished temp files.
        if let fileChannel {
            fileChannel.detach()
            fileTransfer.unbind(from: fileChannel)
            self.fileChannel = nil
        }
        // Any apply callback still queued on the main queue belongs to the
        // session that is ending; it must not request an IDR for the next one.
        formatGate.connectionDidEnd()
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        handshakeTimeoutWork?.cancel()
        handshakeTimeoutWork = nil
        sizeChangeWork?.cancel()
        sizeChangeWork = nil
        helloPixelSize = nil
        stopPingLocked()
        // Backgrounding, a manual disconnect or a replacement session must not
        // leave a tick armed that could fail the next connection.
        hostSilence.stop()
        channel?.onState = nil
        channel?.onPacket = nil
        channel?.close()
        channel = nil
        connection = nil
        currentHostName = nil
        everReady = false
        hasVideoFormat = false
        formatApplyPending = false
        currentFormat = nil
        awaitingFirstFrame = false
        lastFrameAt = nil
        streamStatus = nil
        latencyMs = 0
        DispatchQueue.main.async { [weak self] in
            self?.displayView?.resetForDisconnect()
        }
    }

    // MARK: - Size re-negotiation (queue)

    /// Called after the interface reports a different pixel box. The debounce
    /// collapses rotation-animation frames and repeated layout passes into one
    /// check; a change that is not material is dropped without touching the
    /// connection.
    private func scheduleSizeCheckLocked() {
        guard started,
              wantsConnection,
              !suspended,
              pairing != nil,
              helloPixelSize != nil else { return }
        sizeChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.evaluateSizeChangeLocked()
        }
        sizeChangeWork = work
        queue.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func evaluateSizeChangeLocked() {
        sizeChangeWork = nil
        // A Hello that has not gone out yet needs no re-negotiation: the next
        // one already carries the latest size. The same is true while
        // backgrounded or disconnected.
        guard started,
              wantsConnection,
              !suspended,
              pairing != nil,
              channel != nil,
              let baseline = helloPixelSize else { return }

        capabilityLock.lock()
        let candidate = DisplaySizeChangeDetector.Size(
            width: capabilities.pixelWidth,
            height: capabilities.pixelHeight
        )
        capabilityLock.unlock()

        guard DisplaySizeChangeDetector.isMaterialChange(from: baseline, to: candidate) else {
            return
        }
        renegotiateForSizeLocked(host: currentHostName ?? pairing?.hostName)
    }

    /// Replaces the current session with a fresh Hello at the new pixel size.
    /// The host accepts only the first Hello per session, so a clean TCP close
    /// followed by an automatic reconnect is the reliable way to make it
    /// release input and rebuild the virtual display. This never scans a QR
    /// code, never drops the stored pairing and does not increment the failure
    /// retry counter.
    private func renegotiateForSizeLocked(host: String?) {
        guard let host, !host.isEmpty else { return }
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectAttempt = 0
        lastStatusMessage = nil
        sizeRenegotiationInFlight = true
        cancelConnectionLocked()
        beginConnectionLocked(hostName: host)
    }

    private func handleConnectionStateLocked(_ state: NWConnection.State, generation: Int) {
        guard generation == connectionGeneration else { return }
        switch state {
        case .ready:
            everReady = true
            // `.ready` is only reported after the authenticated handshake, so
            // this is the earliest safe point to start judging silence.
            hostSilence.begin(generation: generation, at: Self.monotonicUptime())
            connectTimeoutWork?.cancel()
            connectTimeoutWork = nil
            sendHelloLocked(generation: generation)
            // Sent after the hello on the same ordered channel, so the host
            // has already authenticated this session when it arrives.
            sendClientSettingsLocked()
            phase = .handshaking(currentHostName ?? "Mac")
            detail = "加密通道已建立，正在请求画面…"
            publishLocked()
            startPingLocked(generation: generation)
            scheduleHandshakeTimeout(generation: generation)
            bindFileTransferLocked()
        case .waiting(let error):
            if !everReady {
                detail = Self.describe(error)
                publishLocked()
            }
            if Self.localNetworkPermissionMessage(error) != nil {
                failConnectionLocked(
                    Self.describe(error),
                    generation: generation,
                    error: error
                )
            }
        case .failed(let error):
            if !everReady, Self.isSessionProtocolFailure(error) {
                // SecureChannel reports an authenticated-handshake failure as
                // EPROTO before ever reaching `.ready`. Retrying cannot fix a
                // reset key or a different protocol version.
                pairingFailedLocked(generation: generation)
                return
            }
            failConnectionLocked(
                Self.describe(error),
                generation: generation,
                error: error
            )
        case .cancelled:
            failConnectionLocked(
                "连接已断开",
                generation: generation,
                error: nil
            )
        default:
            break
        }
    }

    private func sendHelloLocked(generation: Int) {
        capabilityLock.lock()
        let caps = capabilities
        capabilityLock.unlock()

        let hello = HelloMessage(
            protocolVersion: Wire.protocolVersion,
            width: max(caps.pixelWidth, 1),
            height: max(caps.pixelHeight, 1),
            maxFPS: max(caps.maxFPS, 1),
            supportsHDR: caps.supportsHDR,
            deviceName: caps.deviceName
        )
        // Baseline for rotation detection. Set before sending so a size change
        // that lands in between is still seen as a change.
        helloPixelSize = DisplaySizeChangeDetector.Size(width: hello.width, height: hello.height)
        guard let data = try? WireJSON.encode(hello), let channel else {
            failConnectionLocked(
                "无法编码 Hello 消息",
                generation: generation,
                error: nil
            )
            return
        }
        channel.send(.hello, payload: data) { [weak self] error in
            guard let self, let error, self.connectionGeneration == generation else { return }
            self.failConnectionLocked(
                "发送 Hello 失败：\(error.localizedDescription)",
                generation: generation,
                error: nil
            )
        }
    }

    /// Sends the client's target bitrate request. `force` is used for a user
    /// action; without it an unset preference stays silent, so reconnecting
    /// never clears a manual target the user set on the Mac itself.
    private func sendClientSettingsLocked(force: Bool = false) {
        guard force || preferredBitrateMbps != nil else { return }
        guard let channel, everReady else { return }
        let message = ClientSettingsMessage(bitrateMbps: preferredBitrateMbps)
        guard let data = try? WireJSON.encode(message) else { return }
        channel.send(.clientSettings, payload: data, completion: nil)
    }

    /// Called only from `.ready`, which `SecureChannel` reports after the
    /// authenticated handshake. Binding any earlier would let a queued file
    /// packet leave before the session is proven.
    private func bindFileTransferLocked() {
        guard everReady, let channel else { return }
        if let fileChannel {
            fileChannel.detach()
            fileTransfer.unbind(from: fileChannel)
        }
        let wrapper = ClientFileSendChannel(channel: channel)
        fileChannel = wrapper
        fileTransfer.bind(to: wrapper)
    }

    private func scheduleHandshakeTimeout(generation: Int) {
        handshakeTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.connectionGeneration == generation,
                  self.phase != .streaming else { return }
            self.failConnectionLocked(
                "已连接但未收到可用画面。请确认 Mac 端正在运行、已允许屏幕录制且未进入睡眠。",
                generation: generation,
                error: nil
            )
        }
        handshakeTimeoutWork = work
        queue.asyncAfter(deadline: .now() + 12, execute: work)
    }

    private func failConnectionLocked(_ reason: String, generation: Int, error: NWError?) {
        guard generation == connectionGeneration else { return }
        guard wantsConnection, !suspended else {
            cancelConnectionLocked()
            phase = .idle
            detail = "已断开"
            publishLocked()
            return
        }

        if let error, let permissionMessage = Self.localNetworkPermissionMessage(error) {
            cancelConnectionLocked()
            phase = .failed
            detail = permissionMessage
            needsRepair = false
            wantsConnection = false
            publishLocked()
            return
        }

        let host = currentHostName ?? pairing?.hostName ?? "Mac"
        cancelConnectionLocked()

        reconnectAttempt += 1
        phase = .reconnecting(host)
        detail = "\(reason)；正在自动重试（第 \(reconnectAttempt) 次）"
        publishLocked()
        scheduleReconnectLocked(after: min(1.2 * Double(reconnectAttempt), 5.0))
    }

    /// The Mac answered TCP but the authenticated handshake did not complete.
    /// That is a pairing/protocol problem, not a transient network failure, so
    /// stop the reconnect loop and ask for a fresh key.
    private func pairingFailedLocked(generation: Int) {
        guard generation == connectionGeneration else { return }
        cancelConnectionLocked()
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectAttempt = 0
        wantsConnection = false
        needsRepair = true
        phase = .failed
        detail = "与 Mac 的加密握手失败。配对密钥可能已在 Mac 上重置，或两台设备的协议版本不同。请在 Mac 上重新显示二维码，然后点“重新配对”。"
        publishLocked()
    }

    private static func isSessionProtocolFailure(_ error: NWError) -> Bool {
        if case .posix(let code) = error {
            return code == .EPROTO
        }
        return false
    }

    private func scheduleReconnectLocked(after delay: Double) {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.wantsConnection,
                  !self.suspended,
                  self.channel == nil,
                  self.pairing != nil else { return }
            self.reconnectWork = nil
            self.beginConnectionLocked()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Packets (queue)

    private func handlePacketLocked(_ packet: WirePacket, generation: Int) {
        guard generation == connectionGeneration else { return }

        // Every packet that reaches this point was authenticated by
        // SecureChannel, so any kind (frame, IDR reply, status, format, ping
        // echo) proves the peer is alive and the link works in both
        // directions. This is the only liveness signal that survives a
        // half-open link.
        hostSilence.observe(generation: generation, at: Self.monotonicUptime())

        switch packet.kind {
        case .hello:
            if let hello = try? WireJSON.decode(HelloMessage.self, from: packet.payload),
               !hello.deviceName.isEmpty,
               phase != .streaming {
                detail = "Mac：\(hello.deviceName)"
                publishLocked()
            }

        case .videoFormat:
            handleVideoFormatLocked(packet.payload, generation: generation)

        case .videoFrame:
            handleVideoFrameLocked(packet.payload)

        case .status:
            if let status = try? WireJSON.decode(StatusMessage.self, from: packet.payload) {
                lastStatusMessage = status.message
                publishLocked()
            }

        case .ping:
            handlePingEchoLocked(packet.payload)

        case .input, .requestKeyframe, .clientSettings:
            // Client-to-host kinds; ignore anything echoed back.
            break

        case .fileOffer, .fileAccept, .fileReject, .fileChunk, .fileEnd, .fileCancel:
            // File-transfer kinds are only meaningful inside an authenticated
            // session. `everReady` is false before the handshake and is
            // cleared by `cancelConnectionLocked`, so a message arriving on a
            // candidate or half-torn-down connection is dropped here.
            guard everReady, fileChannel != nil else { break }
            fileTransfer.handle(packet)
        }
    }

    private func handleVideoFormatLocked(_ payload: Data, generation: Int) {
        guard let message = try? WireJSON.decode(VideoFormatMessage.self, from: payload) else {
            lastStatusMessage = "Mac 发送了无法解析的视频格式"
            publishLocked()
            return
        }
        guard message.width > 1,
              message.height > 1,
              !message.vps.isEmpty,
              !message.sps.isEmpty,
              !message.pps.isEmpty else {
            lastStatusMessage = "Mac 发送的视频参数不完整"
            publishLocked()
            requestKeyframeLocked()
            return
        }
        guard message != currentFormat else { return }

        currentFormat = message
        hasVideoFormat = true
        formatApplyPending = true
        awaitingFirstFrame = true
        lastFrameAt = nil
        if phase != .streaming {
            phase = .handshaking(currentHostName ?? "Mac")
        }

        capabilityLock.lock()
        let supportsHDR = capabilities.supportsHDR
        capabilityLock.unlock()

        streamStatus = ClientStreamStatus(
            width: message.width,
            height: message.height,
            fps: max(message.fps, 1),
            codec: message.hdr ? "HEVC Main10" : "HEVC Main",
            hdrText: Self.hdrText(for: message, deviceSupportsHDR: supportsHDR),
            colorText: Self.colorText(for: message)
        )
        detail = "正在解码首帧…"
        publishLocked()

        // The key frame the host writes right after this message normally
        // arrives before the main queue installs the format, and the renderer
        // drops it because no format is active yet. Ask for one *new* IDR only
        // after the format is really in place, and only for this exact
        // connection+format. The gate bounds that to one request per format,
        // so a lost IDR can never turn into a request loop.
        let ticket = formatGate.beginFormat()
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.displayView else { return }
            let applied = view.applyFormat(message)
            let outcome: FormatKeyframeGate.ApplyOutcome
            if !applied {
                outcome = .rejected
            } else if view.isUsingFallbackRenderer {
                outcome = .appliedByFallback
            } else {
                outcome = .applied
            }
            self.queue.async { [weak self] in
                guard let self else { return }
                // Only the format that is still current owns the pending flag;
                // a newer format message keeps it set for its own apply.
                if self.currentFormat == message {
                    self.formatApplyPending = false
                }
                guard self.formatGate.decide(ticket, outcome: outcome) == .request else { return }
                self.requestKeyframeLocked(force: true)
            }
        }
        scheduleHandshakeTimeout(generation: generation)
    }

    private func handleVideoFrameLocked(_ payload: Data) {
        guard hasVideoFormat, !formatApplyPending else { return }
        if awaitingFirstFrame,
           let first = payload.first,
           (first & VideoFramePayload.keyframeFlag) != 0 {
            awaitingFirstFrame = false
        }
        lastFrameAt = Date()
        // Safe from any thread and internally bounds its main-queue backlog.
        displayView?.submitFrame(payload: payload)
    }

    /// `force` is only used by the post-format gate. That call is already
    /// limited to one per connection+format generation, so it must not be
    /// swallowed by an unrelated request that happened moments earlier; the
    /// ordinary retry paths stay throttled.
    private func requestKeyframeLocked(force: Bool = false) {
        guard let channel else { return }
        let now = Date()
        if !force {
            guard now.timeIntervalSince(lastKeyframeRequestAt) > 0.4 else { return }
        }
        lastKeyframeRequestAt = now
        channel.send(.requestKeyframe, payload: Data(), completion: nil)
    }

    // MARK: Keepalive / latency

    private func startPingLocked(generation: Int) {
        stopPingLocked()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            self?.pingTickLocked(generation: generation)
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPingLocked() {
        pingTimer?.cancel()
        pingTimer = nil
        pingSentAt.removeAll()
    }

    private func pingTickLocked(generation: Int) {
        guard generation == connectionGeneration, let channel else { return }
        let uptime = Self.monotonicUptime()
        let value = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        var bigEndian = value.bigEndian
        let payload = withUnsafeBytes(of: &bigEndian) { Data($0) }
        pingSentAt[value] = Date()
        if pingSentAt.count > 8 {
            if let oldest = pingSentAt.keys.min() {
                pingSentAt.removeValue(forKey: oldest)
            }
        }
        channel.send(.ping, payload: payload, completion: nil)

        // A successful send above only means the bytes reached the local send
        // buffer; on a half-open link (Mac asleep, AP black-holing frames, dead
        // NAT mapping) nothing comes back and TCP reports no error for minutes.
        // Judge silence from the last *authenticated host packet*, not from the
        // oldest unanswered ping: a still screen whose ping echoes arrive
        // normally must never be failed. The existing backoff reconnect then
        // runs; this is a transient network condition, so nothing asks for a
        // new pairing.
        if hostSilence.isSilent(generation: generation, at: uptime) {
            failConnectionLocked(
                "与 Mac 的连接已失去响应",
                generation: generation,
                error: nil
            )
            return
        }

        // A live TCP socket with no frames for a while can mean the decoder
        // lost its reference chain (or the Mac stopped encoding). Ask for an
        // IDR instead of waiting forever.
        if phase == .streaming {
            if let lastFrameAt, Date().timeIntervalSince(lastFrameAt) > 2.0 {
                requestKeyframeLocked()
            }
        }
    }

    private func handlePingEchoLocked(_ payload: Data) {
        guard payload.count == 8 else { return }
        let value = payload.reduce(into: UInt64(0)) { result, byte in
            result = (result << 8) | UInt64(byte)
        }
        guard let sentAt = pingSentAt.removeValue(forKey: value) else { return }
        latencyMs = max(0, Int((Date().timeIntervalSince(sentAt) * 1000).rounded()))
        if Date().timeIntervalSince(lastLatencyPublishAt) > 1 {
            lastLatencyPublishAt = Date()
            publishLocked()
        }
    }

    // MARK: - Snapshot

    private func publishLocked() {
        var snapshot = ClientSnapshot()
        snapshot.phase = phase
        snapshot.hosts = hostMap.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        snapshot.pairedHostName = pairing?.hostName
        snapshot.hasPairing = pairing != nil
        snapshot.autoConnect = autoConnect
        snapshot.needsRepair = needsRepair
        snapshot.detail = detail
        snapshot.stream = streamStatus
        snapshot.latencyMs = latencyMs
        snapshot.lastStatusMessage = lastStatusMessage
        snapshot.preferredBitrateMbps = preferredBitrateMbps

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = snapshot
            self.onSnapshot?(snapshot)
        }
    }

    // MARK: - Helpers

    /// Monotonic seconds since boot. Used instead of `Date` so a user changing
    /// the system clock can neither trip the silence watchdog nor postpone it.
    private static func monotonicUptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func hdrText(for message: VideoFormatMessage, deviceSupportsHDR: Bool) -> String {
        guard message.hdr else { return "SDR" }
        let transfer = shortTransfer(message.transferFunction)
        guard deviceSupportsHDR else {
            return "SDR 显示 · 源为 HDR \(transfer)"
        }
        return "HDR · \(transfer)"
    }

    private static func colorText(for message: VideoFormatMessage) -> String {
        let primaries = shortPrimaries(message.colorPrimaries)
        let matrix = shortMatrix(message.yCbCrMatrix)
        if matrix.isEmpty { return primaries }
        return "\(primaries) · \(matrix)"
    }

    private static func shortTransfer(_ value: String) -> String {
        switch value.uppercased() {
        case "SMPTE_ST_2084_PQ", "SMPTE2084", "PQ":
            return "PQ"
        case "ITU_R_2100_HLG", "ARIB_STD_B67", "HLG":
            return "HLG"
        default:
            return value.isEmpty ? "HDR" : value
        }
    }

    private static func shortPrimaries(_ value: String) -> String {
        switch value.uppercased() {
        case "ITU_R_2020", "BT2020", "REC2020":
            return "BT.2020"
        case "ITU_R_709_2", "BT709", "REC709":
            return "BT.709"
        case "P3_D65", "P3":
            return "P3-D65"
        case "DCI_P3":
            return "DCI-P3"
        default:
            return value.isEmpty ? "未知色域" : value
        }
    }

    private static func shortMatrix(_ value: String) -> String {
        switch value.uppercased() {
        case "ITU_R_2020", "BT2020", "BT2020_NCL", "BT2020_CL":
            return "BT.2020"
        case "ITU_R_709_2", "BT709":
            return "BT.709"
        case "ITU_R_601_4", "BT601":
            return "BT.601"
        default:
            return value
        }
    }

    private static func localNetworkPermissionMessage(_ error: NWError) -> String? {
        switch error {
        case .dns(let code) where code == -65570: // kDNSServiceErr_PolicyDenied
            return "本地网络权限被拒绝。请到“设置 › 隐私与安全性 › 本地网络”允许 XDRScreen，然后点“重试连接”。"
        case .posix(let code) where code == .EACCES || code == .EPERM:
            return "本地网络权限被拒绝。请到“设置 › 隐私与安全性 › 本地网络”允许 XDRScreen，然后点“重试连接”。"
        default:
            return nil
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:
                return "Mac 拒绝了连接（主机端未运行？）"
            case .ETIMEDOUT:
                return "连接超时"
            case .ENETUNREACH, .EHOSTUNREACH:
                return "网络不可达"
            case .ECONNRESET:
                return "连接被重置"
            default:
                return "网络错误（\(code.rawValue)）"
            }
        case .dns:
            if localNetworkPermissionMessage(error) != nil {
                return "本地网络权限被拒绝"
            }
            return "无法解析 Mac 的 Bonjour 服务"
        case .tls:
            return "加密连接错误"
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - File transfer session channel

/// The controlled send path for one authenticated session.
///
/// The file service runs on its own queue and may keep completing writes while
/// the network controller tears the session down. `detach()` is called on the
/// network queue first, so no later file packet can reach a closed or replaced
/// `SecureChannel`; the lock makes that handshake safe across the two queues.
final class ClientFileSendChannel: FileTransferSendChannel {
    private let lock = NSLock()
    private var channel: SecureChannel?

    init(channel: SecureChannel) {
        self.channel = channel
    }

    var isFileTransferReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return channel != nil
    }

    func sendFilePacket(_ kind: MessageKind, payload: Data, completion: ((Error?) -> Void)?) {
        lock.lock()
        let current = channel
        lock.unlock()
        guard let current else {
            completion?(WireError.channelClosed)
            return
        }
        // `SecureChannel.send` serialises on its own queue, so chunk order is
        // preserved even though the file service calls from another queue.
        current.send(kind, payload: payload, completion: completion)
    }

    func detach() {
        lock.lock()
        channel = nil
        lock.unlock()
    }
}
