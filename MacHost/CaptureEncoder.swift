//
//  CaptureEncoder.swift
//  XDRScreen Mac host
//
//  ScreenCaptureKit capture -> hardware VideoToolbox HEVC (Main / Main10) encode.
//  The encoder only ever advertises HDR after the capture pipeline actually
//  produced 10-bit HDR buffers; otherwise it tears the session down and
//  restarts in SDR, reporting the concrete reason.
//

import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox

// The Xcode app compiles Shared/Wire.swift into the same module as this file.
// The headless SwiftPM regression target compiles CaptureEncoder.swift alone,
// so it needs the wire types as an explicit module import.
#if canImport(XDRScreenWire)
import XDRScreenWire
#endif

// MARK: - Wire budget

/// One video frame has to fit in a single sealed packet. `SecureChannel` adds
/// the kind + per-direction sequence header and the AEAD envelope on top of the
/// `VideoFramePayload` header, so compute the AVCC budget here instead of
/// trusting `Wire.maxFrameBytes` (which predates sequenced framing).
enum VideoPacketLimits {
    static var maxFrameDataBytes: Int {
        Wire.maxPacketBodyBytes
            - WireCrypto.envelopeOverhead
            - WireCrypto.sequencedHeaderByteCount
            - VideoFramePayload.headerByteCount
    }
}

// MARK: - Keyframe recovery bookkeeping

/// Outcome of trying to answer a client keyframe request from the cached last
/// capture buffer while the screen is static.
enum SyntheticKeyframeDecision: Equatable {
    /// A forced IDR for the cached frame should be submitted now.
    case encode
    /// Nothing was asked for.
    case noRequest
    /// Capture is not running (stopped, failed, or being torn down).
    case inactive
    /// Another cached-frame IDR is still inside VideoToolbox.
    case encodeInFlight
    /// The first complete sample has not created the VT session yet.
    case encoderNotReady
    /// No complete frame has ever been captured in this generation.
    case noCachedFrame
    /// The session reports an unacknowledged frame backlog.
    case backpressure
}

/// Pure bookkeeping for "last capture buffer + outstanding keyframe request".
///
/// `requestKeyframe()` arrives on an arbitrary thread, while capture, encoder
/// and teardown all run on the encoder queue. All access goes through a lock,
/// and the decisions themselves stay free of ScreenCaptureKit/VideoToolbox
/// types so they can be regression-tested without a display or an encoder.
struct KeyframeRecoveryState {
    /// Monotonic request counter. `requestSerial > satisfiedSerial` means a
    /// client still waits for an IDR.
    private(set) var requestSerial: UInt64 = 0
    private(set) var satisfiedSerial: UInt64 = 0
    /// A forced encode of the cached frame has been submitted and has not
    /// completed yet. At most one is allowed so repeated requests can never
    /// pile frames into VideoToolbox.
    private(set) var syntheticEncodeInFlight = false
    private(set) var hasCachedFrame = false

    var hasOutstandingRequest: Bool { satisfiedSerial < requestSerial }

    /// Serial captured when an encode is submitted. Marking exactly this serial
    /// satisfied leaves a request that arrived during the encode still pending.
    var pendingRequestSerial: UInt64? {
        hasOutstandingRequest ? requestSerial : nil
    }

    mutating func recordKeyframeRequest() {
        requestSerial &+= 1
    }

    mutating func cacheFrame() {
        hasCachedFrame = true
    }

    mutating func discardCachedFrame() {
        hasCachedFrame = false
    }

    mutating func beginSyntheticEncode() {
        syntheticEncodeInFlight = true
    }

    mutating func finishSyntheticEncode() {
        syntheticEncodeInFlight = false
    }

    /// Only called after `VTCompressionSessionEncodeFrame` accepted the frame.
    mutating func markRequestSatisfied(upTo serial: UInt64) {
        satisfiedSerial = max(satisfiedSerial, min(serial, requestSerial))
    }

    /// Drops everything tied to the capture generation that just ended. The
    /// outstanding request counter is deliberately kept: a client that is
    /// still waiting must get an IDR from the next generation's first frame.
    mutating func resetForCaptureTeardown() {
        hasCachedFrame = false
        syntheticEncodeInFlight = false
    }

    func decision(active: Bool, hasEncoder: Bool, congested: Bool) -> SyntheticKeyframeDecision {
        guard active else { return .inactive }
        guard hasOutstandingRequest else { return .noRequest }
        guard !syntheticEncodeInFlight else { return .encodeInFlight }
        guard hasEncoder else { return .encoderNotReady }
        guard hasCachedFrame else { return .noCachedFrame }
        guard !congested else { return .backpressure }
        return .encode
    }
}

/// Coalescing window for cached-frame IDRs. A client that fires requests in a
/// loop gets at most one forced encode per window instead of one per packet.
enum SyntheticKeyframeRateLimit {
    static func delay(since last: Date, now: Date, minimum: TimeInterval) -> TimeInterval? {
        guard minimum > 0 else { return nil }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed < minimum else { return nil }
        return minimum - elapsed
    }
}

/// Presentation timestamps handed to VideoToolbox must be valid and strictly
/// increasing per session. ScreenCaptureKit's `.idle` callbacks carry no PTS,
/// so a cached frame re-encoded on demand is stamped from the host clock and
/// clamped against the last PTS that was submitted.
enum PresentationTimeRules {
    static func next(last: CMTime, proposed: CMTime, fallback: CMTime, step: CMTime) -> CMTime {
        let stepValue: CMTime
        if isUsable(step) {
            stepValue = step
        } else {
            stepValue = CMTime(value: 1, timescale: 60)
        }

        var candidate = isUsable(proposed) ? proposed : fallback
        if !isUsable(candidate) {
            candidate = isUsable(last) ? CMTimeAdd(last, stepValue) : stepValue
        }
        if isUsable(last), CMTimeCompare(candidate, last) <= 0 {
            candidate = CMTimeAdd(last, stepValue)
        }
        return candidate
    }

    private static func isUsable(_ time: CMTime) -> Bool {
        guard time.isValid else { return false }
        let seconds = time.seconds
        return seconds.isFinite && seconds >= 0
    }
}

// MARK: - Restart policy

enum CaptureRestart: Equatable {
    case restartHDR
    case restartSDR(reason: String?)
}

/// Decides whether an unexpectedly stopped capture stream is restarted in HDR
/// or SDR. This is the same availability rule as `hdrUnavailableReason()`,
/// plus a rule that a session which already fell back from HDR (or repeatedly
/// restarted without ever confirming 10-bit output) stays on the reliable SDR
/// path instead of flapping between modes.
enum CaptureRestartPolicy {
    static let maxHDRRestartsWithoutConfirmation = 2

    static func decision(clientSupportsHDR: Bool,
                         hdrUnavailableReason: String?,
                         hdrPreviouslyFailed: Bool,
                         hdrRestartsWithoutConfirmation: Int,
                         maxHDRRestarts: Int = maxHDRRestartsWithoutConfirmation) -> CaptureRestart {
        // The session was SDR by the client's own request: restart plain SDR
        // without claiming anything about HDR.
        guard clientSupportsHDR else { return .restartSDR(reason: nil) }
        if let reason = hdrUnavailableReason { return .restartSDR(reason: reason) }
        if hdrPreviouslyFailed { return .restartSDR(reason: "本次会话的 HDR 采集此前已失败") }
        if hdrRestartsWithoutConfirmation >= max(1, maxHDRRestarts) {
            return .restartSDR(reason: "HDR 采集多次重启后仍未确认 10-bit 输出")
        }
        return .restartHDR
    }
}

// MARK: - Values handed to the session layer

/// The concrete display this capture must use. `nil` on `CaptureRequest`
/// keeps the historical "main display" behaviour (mirror mode); a dedicated
/// iPad display always arrives with its real `CGDirectDisplayID` and the pixel
/// size the virtual display was created with.
struct CaptureTarget: Equatable {
    let displayID: CGDirectDisplayID
    /// Expected backing-store pixels (`CGDisplayMode.pixelWidth`), 0 when the
    /// caller has no expectation (mirror mode). Never derived from
    /// `CGDisplayPixelsWide`, which reports logical width for 2x modes.
    let pixelWidth: Int
    let pixelHeight: Int
}

struct CaptureRequest {
    /// Client's requested picture box in pixels. 0 means "native display size".
    let clientWidth: Int
    let clientHeight: Int
    let clientMaxFPS: Int
    let clientSupportsHDR: Bool
    /// nil = current main display (mirror mode).
    let target: CaptureTarget?

    func withTarget(_ target: CaptureTarget?) -> CaptureRequest {
        CaptureRequest(clientWidth: clientWidth,
                       clientHeight: clientHeight,
                       clientMaxFPS: clientMaxFPS,
                       clientSupportsHDR: clientSupportsHDR,
                       target: target)
    }
}

/// Everything the client needs in VideoFormatMessage plus a comparison key.
struct StreamFormat: Equatable {
    let width: Int
    let height: Int
    let hdr: Bool
    let vps: Data
    let sps: Data
    let pps: Data
    let colorPrimaries: String
    let transferFunction: String
    let yCbCrMatrix: String
}

struct EncodedFrame {
    let keyframe: Bool
    let timestampUs: UInt64
    let data: Data
    let format: StreamFormat
}

struct DisplayCapability {
    let displayID: CGDirectDisplayID
    /// True backing-store pixels (CGDisplayMode.pixelWidth), never AppKit points.
    let pixelWidth: Int
    let pixelHeight: Int
    let pointWidth: Double
    let pointHeight: Double
    let edrHeadroom: Double
    let maxFPS: Int

    var supportsHDR: Bool { edrHeadroom > 1.0 }
}

enum DisplayProbe {
    /// Queries the current main display.
    static func mainDisplay() -> DisplayCapability {
        capability(for: CGMainDisplayID())
    }

    /// Queries one concrete display. Used for the iPad virtual display so its
    /// EDR headroom (1.0 on current macOS) decides HDR, not the TV's.
    /// Safe to call from any thread; NSScreen is touched on the main thread only.
    static func capability(for id: CGDirectDisplayID) -> DisplayCapability {
        var pixelWidth = 0
        var pixelHeight = 0
        if let mode = CGDisplayCopyDisplayMode(id) {
            pixelWidth = mode.pixelWidth
            pixelHeight = mode.pixelHeight
        }
        if pixelWidth <= 0 { pixelWidth = CGDisplayPixelsWide(id) }
        if pixelHeight <= 0 { pixelHeight = CGDisplayPixelsHigh(id) }
        let bounds = CGDisplayBounds(id)
        let screen = onMain { screenInfo(id) }
        return DisplayCapability(
            displayID: id,
            pixelWidth: max(pixelWidth, 0),
            pixelHeight: max(pixelHeight, 0),
            pointWidth: Double(bounds.width),
            pointHeight: Double(bounds.height),
            edrHeadroom: screen.headroom,
            maxFPS: screen.maxFPS
        )
    }

    private static func screenInfo(_ id: CGDirectDisplayID) -> (headroom: Double, maxFPS: Int) {
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if number?.uint32Value == id {
                return (Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
                        screen.maximumFramesPerSecond)
            }
        }
        return (1.0, 60)
    }

    private static func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }
}

// MARK: - Quality tiers

/// User-selectable quality/bandwidth trade-off. Every tier keeps 1:1 capture
/// resolution, fps and HDR handling unchanged; only the bits-per-pixel budget
/// and its upper bound move. `reduceBitrateIfNeeded` still applies to all of
/// them, so a bad network can lower the bitrate below the tier's target.
enum HostQuality: String, CaseIterable, Identifiable {
    case auto
    case sharp
    case balanced
    case thrifty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .sharp: return "清晰"
        case .balanced: return "均衡"
        case .thrifty: return "省带宽"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "默认画质，桌面文字清晰，适合大多数网络。"
        case .sharp: return "更高码率，文字与细线最锐利，需要稳定高速网络。"
        case .balanced: return "清晰度与带宽折中，适合一般 Wi-Fi。"
        case .thrifty: return "优先保证流畅，适合弱网、热点或共享带宽。"
        }
    }

    /// Starting bits per pixel. Small UI text needs more than video content,
    /// so even the lowest tier stays far above typical video rates.
    func bitsPerPixel(hdr: Bool) -> Double {
        switch self {
        case .auto: return hdr ? 0.16 : 0.14
        case .sharp: return hdr ? 0.22 : 0.20
        case .balanced: return hdr ? 0.11 : 0.09
        case .thrifty: return hdr ? 0.06 : 0.05
        }
    }

    /// Upper clamp for the starting budget, sized well above the largest
    /// supported panel so rate control is never bounded by this value first.
    var bitrateUpperBound: Int {
        switch self {
        case .auto: return 80_000_000
        case .sharp: return 120_000_000
        case .balanced: return 50_000_000
        case .thrifty: return 25_000_000
        }
    }

    /// Lower clamp for the starting budget. `thrifty` drops to 6 Mbps so
    /// 1080p-class SDR streams (≈6.2 Mbps at 0.05 bpp) are not inflated above
    /// their own target; every other tier keeps the historical 8 Mbps floor.
    var bitrateLowerBound: Int {
        self == .thrifty ? 6_000_000 : 8_000_000
    }
}

// MARK: - Encoder

protocol CaptureEncoderDelegate: AnyObject {
    func captureEncoder(_ encoder: CaptureEncoder, didEncode frame: EncodedFrame)
    func captureEncoder(_ encoder: CaptureEncoder, didSelectDisplay displayID: CGDirectDisplayID)
    /// Human readable, user-facing status (Chinese). Never contains secrets.
    func captureEncoder(_ encoder: CaptureEncoder, didUpdateStatus status: String)
    func captureEncoder(_ encoder: CaptureEncoder, didFail message: String, retryable: Bool)
}

final class CaptureEncoder: NSObject {

    weak var delegate: CaptureEncoderDelegate?

    /// Backpressure probe supplied by the session. Called from the capture
    /// queue; must be cheap and must never block the capture callback.
    private let congestionProbe: () -> Bool

    private let queue = DispatchQueue(label: "com.xdrscreen.capture.encode", qos: .userInteractive)
    private let flagLock = NSLock()

    // flagLock protected (requests arrive from the network queue; caching and
    // synthetic encodes happen on `queue`).
    private var keyframeState = KeyframeRecoveryState()

    // queue confined
    /// Last complete capture buffer of the current generation. Retaining one
    /// IOSurface-backed buffer is cheap and lets a static screen still answer
    /// a keyframe request. Cleared on teardown, display/format change and when
    /// the display reports blank/suspended/stopped.
    private var cachedFrame: CVPixelBuffer?
    private var active = false
    private var generation = 0
    private var request: CaptureRequest?
    private var stream: SCStream?
    private var vtSession: VTCompressionSession?
    private var fps = 60
    private var targetWidth = 0
    private var targetHeight = 0
    private var hdrMode: HDRMode = .sdr
    private var displayID: CGDirectDisplayID = 0
    private var cachedFormat: StreamFormat?
    private var cachedDescription: CMFormatDescription?
    private var captureColorInfo: ColorInfo?
    private var lastPresentationTime = CMTime.invalid
    private var lastSyntheticKeyframeAt = Date.distantPast
    private var keyframeServiceScheduled = false
    private var needsRecoveryIDR = false
    private var retryAttempt = 0
    private var lastFrameAt = Date()
    private var watchdogReported = false
    private var blankReported = false
    private var formatStatusReported = false
    private var hardwareEncode = false
    private var initialBitrate = 0
    private var currentBitrate = 0
    private var lastBitrateCut = Date.distantPast
    /// Survives teardown: a tier chosen while idle is used when the next
    /// capture session creates its encoder.
    private var quality: HostQuality = .auto
    private var didReportNoDisplay = false
    private var didReportHDRUnavailable = false
    private var hdrFallbackScheduled = false
    /// True only when HDR actually failed in this session (capture start,
    /// 10-bit verification or encoding). A display whose EDR is merely absent
    /// right now is re-probed on every restart instead of being remembered as
    /// a failure, so HDR returns when the display does.
    private var hdrFailedThisSession = false
    /// HDR stream restarts since the last confirmed 10-bit frame. Bounded by
    /// `CaptureRestartPolicy` so a stopping stream cannot flap HDR forever.
    private var hdrRestartsWithoutConfirmation = 0
    private var encodeFailureCount = 0
    private var encoderFailureDetail: String?

    private enum HDRMode {
        case sdr
        case hdrCandidate
        case hdrConfirmed

        var isHDR: Bool { self == .hdrConfirmed }
    }

    private struct ColorInfo {
        var primaries: String?
        var transfer: String?
        var matrix: String?
    }

    init(isCongested: @escaping () -> Bool) {
        self.congestionProbe = isCongested
        super.init()
    }

    // MARK: Public API

    func start(_ request: CaptureRequest) {
        queue.async { self.startInternal(request) }
    }

    func stop() {
        queue.async { self.stopInternal() }
    }

    /// Changes the quality tier. Thread-safe: the work is serialised on the
    /// encoder queue, so it cannot race a capture callback or a teardown.
    /// With a live encoder the bitrate budget is recomputed and applied
    /// immediately; while idle the tier is only remembered for the next start.
    func setQuality(_ quality: HostQuality) {
        queue.async { self.setQualityInternal(quality) }
    }

    private func setQualityInternal(_ quality: HostQuality) {
        self.quality = quality
        guard let session = vtSession, targetWidth > 0, targetHeight > 0 else {
            // No encoder yet: `startInternal` will use `quality` when it
            // builds the next compression session.
            return
        }
        initialBitrate = Self.recommendedBitrate(width: targetWidth,
                                                 height: targetHeight,
                                                 fps: fps,
                                                 hdr: hdrMode.isHDR,
                                                 quality: quality)
        currentBitrate = initialBitrate
        // A deliberate tier change starts from a fresh budget: the auto
        // downgrade floor is derived from `initialBitrate`, so it moves too.
        lastBitrateCut = .distantPast
        applyBitrate(session)
        let mbps = String(format: "%.1f", Double(currentBitrate) / 1_000_000.0)
        delegate?.captureEncoder(self, didUpdateStatus: "画质：\(quality.title) · \(mbps) Mbps")
    }

    /// Marks a client keyframe request and lets the encoder queue answer it
    /// immediately from the cached frame. The request stays pending until a
    /// forced IDR is actually accepted by VideoToolbox, so an encoder that is
    /// not ready yet (or a static screen) cannot swallow it.
    func requestKeyframe() {
        withKeyframeState { $0.recordKeyframeRequest() }
        queue.async { [weak self] in
            self?.serviceKeyframeRequest()
        }
    }

    private func withKeyframeState<T>(_ body: (inout KeyframeRecoveryState) -> T) -> T {
        flagLock.lock()
        defer { flagLock.unlock() }
        return body(&keyframeState)
    }

    // MARK: Lifecycle (queue confined)

    private func startInternal(_ request: CaptureRequest) {
        let gen = teardownCapture()
        active = true
        self.request = request
        fps = min(max(request.clientMaxFPS, 1), 60)
        retryAttempt = 0
        didReportNoDisplay = false
        didReportHDRUnavailable = false
        hdrFallbackScheduled = false
        hdrFailedThisSession = false
        hdrRestartsWithoutConfirmation = 0
        encodeFailureCount = 0
        lastFrameAt = Date()
        watchdogReported = false
        blankReported = false

        var hdrWanted = request.clientSupportsHDR
        if hdrWanted {
            if let reason = hdrUnavailableReason() {
                hdrWanted = false
                if !didReportHDRUnavailable {
                    didReportHDRUnavailable = true
                    delegate?.captureEncoder(self, didUpdateStatus: "HDR 不可用：\(reason)；本次使用 SDR")
                }
            }
        }
        beginAttempt(hdr: hdrWanted, generation: gen)
    }

    private func stopInternal() {
        active = false
        _ = teardownCapture()
        request = nil
    }

    @discardableResult
    private func teardownCapture() -> Int {
        generation += 1
        if let stream {
            stream.stopCapture { _ in }
        }
        stream = nil
        if let vtSession {
            VTCompressionSessionInvalidate(vtSession)
        }
        vtSession = nil
        cachedFormat = nil
        cachedDescription = nil
        captureColorInfo = nil
        cachedFrame = nil
        withKeyframeState { $0.resetForCaptureTeardown() }
        lastPresentationTime = .invalid
        lastSyntheticKeyframeAt = .distantPast
        keyframeServiceScheduled = false
        hdrMode = .sdr
        needsRecoveryIDR = false
        formatStatusReported = false
        encodeFailureCount = 0
        encoderFailureDetail = nil
        return generation
    }

    /// A freshly created virtual display can take a moment to show up in
    /// ScreenCaptureKit's shareable list. Bound that wait so a stale request
    /// can never hang the session.
    private static let displayDiscoveryTimeout: TimeInterval = 2.0
    private static let displayDiscoveryPollInterval: TimeInterval = 0.1

    private func beginAttempt(hdr: Bool, generation gen: Int) {
        let deadline = ProcessInfo.processInfo.systemUptime + Self.displayDiscoveryTimeout
        fetchShareableContent(hdr: hdr, generation: gen, deadline: deadline)
    }

    private func fetchShareableContent(hdr: Bool, generation gen: Int, deadline: TimeInterval) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            self.queue.async {
                guard self.active, self.generation == gen else { return }
                if let error {
                    self.handleStartFailure(error: error, hdrAttempt: hdr, generation: gen)
                    return
                }
                guard let content, !content.displays.isEmpty else {
                    if self.request?.target != nil, ProcessInfo.processInfo.systemUptime < deadline {
                        self.retryShareableFetch(hdr: hdr, generation: gen, deadline: deadline)
                    } else {
                        self.handleNoDisplay(hdrAttempt: hdr, generation: gen)
                    }
                    return
                }

                guard let target = self.request?.target else {
                    let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays[0]
                    self.prepareAndStart(content: content, display: display, hdr: hdr, generation: gen)
                    return
                }

                if let display = content.displays.first(where: { $0.displayID == target.displayID }) {
                    self.prepareAndStart(content: content, display: display, hdr: hdr, generation: gen)
                } else if ProcessInfo.processInfo.systemUptime < deadline {
                    self.retryShareableFetch(hdr: hdr, generation: gen, deadline: deadline)
                } else {
                    self.handleTargetDisplayMissing(targetID: target.displayID,
                                                    isDedicated: target.pixelWidth > 0,
                                                    generation: gen)
                }
            }
        }
    }

    private func retryShareableFetch(hdr: Bool, generation gen: Int, deadline: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        let delay = min(Self.displayDiscoveryPollInterval, max(0, deadline - now))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.active, self.generation == gen else { return }
            self.fetchShareableContent(hdr: hdr, generation: gen, deadline: deadline)
        }
    }

    /// The dedicated virtual display exists but ScreenCaptureKit never listed
    /// it. Fall back to mirroring the main display for this session and say so
    /// instead of quietly claiming the dedicated screen works.
    private func handleTargetDisplayMissing(targetID: CGDirectDisplayID,
                                            isDedicated: Bool,
                                            generation gen: Int) {
        let message = isDedicated
            ? "iPad 专用屏（displayID \(targetID)）在 2 秒内未出现在可捕获显示器列表中；本次已退回镜像当前屏幕。"
            : "主显示器（displayID \(targetID)）未出现在可捕获显示器列表中；正在尝试其他可用显示器。"
        delegate?.captureEncoder(self, didUpdateStatus: message)
        if let request {
            self.request = request.withTarget(nil)
        }
        let newGen = teardownCapture()
        let wantHDR = (request?.clientSupportsHDR ?? false)
            && Self.isAppleSilicon
            && DisplayProbe.capability(for: CGMainDisplayID()).supportsHDR
        beginAttempt(hdr: wantHDR, generation: newGen)
    }

    private func prepareAndStart(content: SCShareableContent, display: SCDisplay, hdr: Bool, generation gen: Int) {
        displayID = display.displayID
        delegate?.captureEncoder(self, didSelectDisplay: displayID)

        var sourceW = 0
        var sourceH = 0
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            sourceW = mode.pixelWidth
            sourceH = mode.pixelHeight
        }
        if sourceW <= 0 || sourceH <= 0 {
            // CGDisplayPixels* is also backing-store pixels. SCDisplay's
            // width/height are *points*, so they remain only a last resort.
            sourceW = CGDisplayPixelsWide(display.displayID)
            sourceH = CGDisplayPixelsHigh(display.displayID)
        }
        if sourceW <= 0 || sourceH <= 0 {
            sourceW = display.width
            sourceH = display.height
        }
        guard sourceW > 1, sourceH > 1 else {
            handleNoDisplay(hdrAttempt: hdr, generation: gen)
            return
        }

        // The expected backing-store size of a dedicated display comes from
        // CGDisplayMode.pixelWidth/pixelHeight above. A mismatch is reported
        // but the real capture geometry always wins.
        if let expected = request?.target, expected.pixelWidth > 0, expected.pixelHeight > 0,
           (expected.pixelWidth != sourceW || expected.pixelHeight != sourceH) {
            delegate?.captureEncoder(
                self,
                didUpdateStatus: "专用屏实际像素 \(sourceW)×\(sourceH) 与预期 \(expected.pixelWidth)×\(expected.pixelHeight) 不一致；按实际分辨率捕获"
            )
        }

        let target = Self.targetSize(sourceWidth: sourceW,
                                     sourceHeight: sourceH,
                                     requestedWidth: request?.clientWidth ?? 0,
                                     requestedHeight: request?.clientHeight ?? 0)
        targetWidth = target.width
        targetHeight = target.height

        let configuration = makeConfiguration(hdr: hdr, width: targetWidth, height: targetHeight)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            delegate?.captureEncoder(self, didFail: "无法挂接屏幕采集输出：\(error.localizedDescription)", retryable: true)
            scheduleRetry(hdr: hdr, generation: gen)
            return
        }
        stream = newStream

        // The VideoToolbox session is created from the first complete sample,
        // once the capture buffer's real colour attachments are known, so the
        // encoded VUI carries the colours the capture pipeline actually
        // produced instead of a guess made before the first frame.
        vtSession = nil
        hdrMode = hdr ? .hdrCandidate : .sdr
        formatStatusReported = false
        lastPresentationTime = .invalid
        cachedFormat = nil
        cachedDescription = nil
        captureColorInfo = nil
        cachedFrame = nil
        withKeyframeState { $0.resetForCaptureTeardown() }
        lastFrameAt = Date()
        watchdogReported = false
        blankReported = false

        newStream.startCapture { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.active, self.generation == gen, self.stream === newStream else { return }
                if let error {
                    self.handleStartFailure(error: error, hdrAttempt: hdr, generation: gen)
                    return
                }
                self.retryAttempt = 0
                if hdr {
                    self.delegate?.captureEncoder(self, didUpdateStatus: "HDR 采集已启动（\(target.width)×\(target.height)），正在校验首帧 10-bit 输出…")
                } else {
                    self.delegate?.captureEncoder(self, didUpdateStatus: "SDR 采集已启动（\(target.width)×\(target.height)，\(self.fps) fps）")
                }
                self.startWatchdog(generation: gen)
            }
        }
    }

    private func startWatchdog(generation gen: Int) {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.active, self.generation == gen else { return }
            if Date().timeIntervalSince(self.lastFrameAt) > 5 {
                if !self.watchdogReported {
                    self.watchdogReported = true
                    self.delegate?.captureEncoder(self, didUpdateStatus: "已超过 5 秒未收到画面：显示器可能已休眠、关闭或断开")
                }
            } else {
                self.watchdogReported = false
            }
            self.startWatchdog(generation: gen)
        }
    }

    // MARK: Display / configuration

    private func hdrUnavailableReason() -> String? {
        guard Self.isAppleSilicon else { return "HDR 屏幕采集仅支持 Apple Silicon" }
        // Probe the display that will actually be captured, not the main
        // display. The iPad virtual display reports EDR headroom 1.0, so it is
        // SDR even when the iPad panel itself supports HDR.
        let isDedicated = request?.target != nil
        let displayID = request?.target?.displayID ?? CGMainDisplayID()
        let capability = DisplayProbe.capability(for: displayID)
        guard capability.supportsHDR else {
            return String(format: "%@ EDR 余量不足（%.2f）",
                          isDedicated ? "iPad 专用屏" : "主显示器",
                          capability.edrHeadroom)
        }
        return nil
    }

    private static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Aspect-fit the client's box into the source pixels, never upscaling,
    /// always even dimensions (HEVC requirement).
    static func targetSize(sourceWidth: Int, sourceHeight: Int, requestedWidth: Int, requestedHeight: Int) -> (width: Int, height: Int) {
        var scale = 1.0
        if requestedWidth > 0, requestedHeight > 0 {
            scale = min(Double(requestedWidth) / Double(sourceWidth),
                        Double(requestedHeight) / Double(sourceHeight),
                        1.0)
        }
        var width = Int((Double(sourceWidth) * scale).rounded())
        var height = Int((Double(sourceHeight) * scale).rounded())
        width = max(2, width)
        height = max(2, height)
        if width % 2 == 1 { width -= 1 }
        if height % 2 == 1 { height -= 1 }
        return (max(2, width), max(2, height))
    }

    private func makeConfiguration(hdr: Bool, width: Int, height: Int) -> SCStreamConfiguration {
        // Apple's ScreenCaptureKit HDR preset carries the supported pixel
        // format (10-bit 4:4:4), colour space and matrix for HDR capture.
        let configuration = hdr
            ? SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay)
            : SCStreamConfiguration()

        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.shouldBeOpaque = true

        if hdr {
            // Respect every value the HDR preset suggests (10-bit 'xf44',
            // DisplayP3 PQ colour space and its matrix). Overriding only some
            // of them breaks the preset's output contract; the real tags are
            // read back from the first sample buffer and forwarded as-is.
            configuration.captureDynamicRange = .hdrCanonicalDisplay
        } else {
            configuration.captureDynamicRange = .SDR
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.colorSpaceName = CGColorSpace.sRGB
            // Only 420v/420f use colorMatrix; 8-bit screen content is BT.709.
            configuration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
        return configuration
    }

    // MARK: VideoToolbox

    /// Creates the encoder on demand using the colour attachments of the
    /// sample buffer that will be its first frame.
    private func startEncodingSession(hdr: Bool) -> Bool {
        guard let session = makeCompressionSession(width: targetWidth,
                                                   height: targetHeight,
                                                   hdr: hdr,
                                                   color: captureColorInfo) else {
            let detail = encoderFailureDetail ?? "未知编码器错误"
            if hdr {
                // A display can advertise HDR while its Main10 hardware
                // encoder still refuses the requested 10-bit format. Fall back
                // to a working SDR stream instead of staying black.
                fallbackFromHDR(reason: "HEVC Main10 编码器不可用（\(detail)）")
            } else {
                teardownCapture()
                active = false
                delegate?.captureEncoder(self, didFail: "无法创建 HEVC 编码器（\(detail)）。", retryable: false)
            }
            return false
        }
        vtSession = session
        return true
    }

    private func makeCompressionSession(width: Int, height: Int, hdr: Bool, color: ColorInfo?) -> VTCompressionSession? {
        var lastStatus: OSStatus = noErr
        var hardwareAttemptStatus: OSStatus = noErr

        for requireHardware in [true, false] {
            var specification: [CFString: Any] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
            ]
            if requireHardware {
                specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
            }
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
            if requireHardware { hardwareAttemptStatus = status }
            lastStatus = status
            guard status == noErr, let session else { continue }
            guard configure(session, width: width, height: height, fps: fps, hdr: hdr, color: color) else {
                VTCompressionSessionInvalidate(session)
                lastStatus = -1
                continue
            }
            hardwareEncode = requireHardware || Self.sessionUsesHardware(session)
            if !requireHardware {
                delegate?.captureEncoder(self, didUpdateStatus: "硬件 HEVC 编码器不可用，已改用软件编码")
            }
            return session
        }

        encoderFailureDetail = lastStatus == -1
            ? "编码参数不被支持"
            : "OSStatus \(hardwareAttemptStatus == noErr ? lastStatus : hardwareAttemptStatus)"
        return nil
    }

    private func configure(_ session: VTCompressionSession, width: Int, height: Int, fps: Int, hdr: Bool, color: ColorInfo?) -> Bool {
        let profile: CFString = hdr ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        guard Self.setProperty(session, kVTCompressionPropertyKey_ProfileLevel, profile) else {
            delegate?.captureEncoder(self, didUpdateStatus: "HEVC \(hdr ? "Main10" : "Main") profile 不被当前编码器支持")
            return false
        }

        // Emit the real colour description into the HEVC VUI/SPS, not just
        // into our JSON side channel, so any decoder sees the correct
        // primaries / transfer function / matrix even without the metadata
        // message.
        // Prefer the capture buffer's own colour tags; fall back to the
        // documented output colour of the selected ScreenCaptureKit preset.
        let defaults = Self.defaultColors(hdr: hdr)
        let primaries = (color?.primaries ?? defaults.primaries) as CFString
        let transfer = (color?.transfer ?? defaults.transfer) as CFString
        let matrix = (color?.matrix ?? defaults.matrix) as CFString
        _ = Self.setProperty(session, kVTCompressionPropertyKey_ColorPrimaries, primaries)
        _ = Self.setProperty(session, kVTCompressionPropertyKey_TransferFunction, transfer)
        _ = Self.setProperty(session, kVTCompressionPropertyKey_YCbCrMatrix, matrix)
        if hdr {
            _ = Self.setProperty(session, kVTCompressionPropertyKey_HDRMetadataInsertionMode,
                                 kVTHDRMetadataInsertionMode_Auto)
        }

        // Still real-time and low-latency, but no longer trading quality for
        // encode speed: at 1:1 resolution the stream is bounded by bitrate
        // and rate control, not by how fast the encoder can run.
        _ = Self.setProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        _ = Self.setProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        _ = Self.setProperty(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanFalse)
        _ = Self.setProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        _ = Self.setProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: max(fps, 1) * 2))
        _ = Self.setProperty(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2.0))

        initialBitrate = Self.recommendedBitrate(width: width, height: height, fps: fps, hdr: hdr, quality: quality)
        currentBitrate = initialBitrate
        applyBitrate(session)

        let status = VTCompressionSessionPrepareToEncodeFrames(session)
        if status != noErr {
            delegate?.captureEncoder(self, didUpdateStatus: "编码器准备失败（OSStatus \(status)）")
            return false
        }
        return true
    }

    private static func setProperty(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef?) -> Bool {
        VTSessionSetProperty(session, key: key, value: value) == noErr
    }

    private static func sessionUsesHardware(_ session: VTCompressionSession) -> Bool {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            VTSessionCopyProperty(session,
                                  key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                  allocator: nil,
                                  valueOut: UnsafeMutableRawPointer(pointer))
        }
        guard status == noErr else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    /// Resolution/frame-rate based starting point, sized for desktop text
    /// clarity at 1:1: small glyphs and thin strokes need more bits per pixel
    /// than video content, especially once the stream fills a 2732×2048 panel.
    /// This is only the starting budget — `reduceBitrateIfNeeded` can still
    /// lower it (never raise it) when the session reports send backlog.
    private static func recommendedBitrate(width: Int, height: Int, fps: Int, hdr: Bool, quality: HostQuality) -> Int {
        let pixels = Double(width) * Double(height)
        // The tier's bits-per-pixel keeps small UI text from smearing while
        // letting the user trade quality for bandwidth.
        let raw = pixels * Double(fps) * quality.bitsPerPixel(hdr: hdr)
        let lower = Double(quality.bitrateLowerBound)
        // Headroom above the 2732×2048@60 budget of each tier so the encoder
        // is not clamped before rate control sees the frames.
        let upper = Double(quality.bitrateUpperBound)
        return Int(max(lower, min(upper, raw)))
    }

    private func applyBitrate(_ session: VTCompressionSession) {
        _ = Self.setProperty(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: currentBitrate))
        let limits = [NSNumber(value: currentBitrate / 8), NSNumber(value: 1.0)] as CFArray
        _ = Self.setProperty(session, kVTCompressionPropertyKey_DataRateLimits, limits)
    }

    /// Network backstop, applied on top of every quality tier: when the send
    /// path reports backlog the budget is cut by 15% at a time (at most once
    /// per 10 s). Chasing quality cannot help a network that cannot carry it.
    private func reduceBitrateIfNeeded(session: VTCompressionSession) {
        let now = Date()
        guard now.timeIntervalSince(lastBitrateCut) > 10 else { return }
        let floor = max(4_000_000, initialBitrate / 3)
        guard currentBitrate > floor else { return }
        currentBitrate = max(floor, Int(Double(currentBitrate) * 0.85))
        lastBitrateCut = now
        applyBitrate(session)
        delegate?.captureEncoder(self, didUpdateStatus: "发送积压，码率降至 \(currentBitrate / 1_000_000) Mbps")
    }

    // MARK: Capture output

    private func handleSample(_ sampleBuffer: CMSampleBuffer, from sourceStream: SCStream) {
        guard active, stream === sourceStream else { return }
        lastFrameAt = Date()

        let status = Self.frameStatus(sampleBuffer)
        switch status {
        case .some(.idle):
            // Static screen: no new image, but a pending client request can
            // still be answered from the cached buffer.
            serviceKeyframeRequest()
            return
        case .some(.blank), .some(.suspended):
            // Never fabricate a picture while the display is off/sleeping.
            discardCachedFrame()
            if !blankReported {
                blankReported = true
                delegate?.captureEncoder(self, didUpdateStatus: "显示器已关闭或进入睡眠，暂停输出")
            }
            return
        case .some(.stopped):
            discardCachedFrame()
            return
        case .some(.complete), .some(.started), .none:
            blankReported = false
        case .some:
            blankReported = false
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // HDR is only claimed after a real 10-bit HDR buffer is observed.
        if hdrMode == .hdrCandidate {
            let info = Self.colorInfo(from: sampleBuffer, pixelBuffer: pixelBuffer)
            if let reason = Self.hdrVerificationFailure(pixelBuffer: pixelBuffer, info: info) {
                fallbackFromHDR(reason: reason)
                return
            }
            hdrMode = .hdrConfirmed
            hdrRestartsWithoutConfirmation = 0
            captureColorInfo = info
        } else if captureColorInfo == nil {
            captureColorInfo = Self.colorInfo(from: sampleBuffer, pixelBuffer: pixelBuffer)
        }

        // First complete sample: create the encoder with this buffer's actual
        // colour tags. This is also where an HDR Main10 session that the
        // hardware refuses falls back to SDR.
        if vtSession == nil {
            guard startEncodingSession(hdr: hdrMode.isHDR) else { return }
        }

        // Retain the newest complete frame of this generation. If the screen
        // goes static right after this sample, this is what answers a future
        // keyframe request; the same buffer is still encoded normally below.
        if CVPixelBufferGetWidth(pixelBuffer) > 0, CVPixelBufferGetHeight(pixelBuffer) > 0 {
            cachedFrame = pixelBuffer
            withKeyframeState { $0.cacheFrame() }
        }

        // Never queue behind a congested link: skip this *capture sample*.
        // Nothing has been encoded, so the reference chain is intact and no
        // recovery IDR is needed once the backlog clears; forcing one would
        // dump a multi-megabyte keyframe into the just-recovered link.
        if congestionProbe() {
            if vtSession != nil { reduceBitrateIfNeeded(session: vtSession!) }
            return
        }

        guard let session = vtSession else { return }
        encode(pixelBuffer: pixelBuffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), session: session)
    }

    /// Minimum spacing between cached-frame IDRs. Normal clients request one
    /// per recovery, so this only coalesces a pathological request storm.
    private static let syntheticKeyframeMinInterval: TimeInterval = 0.1

    /// Answers a pending client keyframe request from the cached frame when
    /// the screen is static. The request is only marked satisfied once an IDR
    /// is actually emitted, and at most one such encode is in flight, so a
    /// burst of requests cannot pile frames into the encoder.
    private func serviceKeyframeRequest() {
        let congested = congestionProbe()
        let decision = withKeyframeState {
            $0.decision(active: active, hasEncoder: vtSession != nil, congested: congested)
        }
        guard decision == .encode else { return }
        guard let pixelBuffer = cachedFrame, let session = vtSession else { return }

        let now = Date()
        if let delay = SyntheticKeyframeRateLimit.delay(since: lastSyntheticKeyframeAt,
                                                       now: now,
                                                       minimum: Self.syntheticKeyframeMinInterval) {
            scheduleKeyframeService(after: delay)
            return
        }
        lastSyntheticKeyframeAt = now
        withKeyframeState { $0.beginSyntheticEncode() }
        // An `.idle` callback has no PTS of its own; stamp from the host
        // clock. `encode` keeps every submitted timestamp strictly increasing.
        let clock = CMClockGetTime(CMClockGetHostTimeClock())
        let accepted = encode(pixelBuffer: pixelBuffer,
                              presentationTime: clock,
                              session: session,
                              synthetic: true)
        if !accepted {
            // Keep the request outstanding; the next sample or request retries.
            withKeyframeState { $0.finishSyntheticEncode() }
        }
    }

    /// A throttled request still needs to land even if the screen never sends
    /// another sample, so retry once the coalescing window has elapsed.
    private func scheduleKeyframeService(after delay: TimeInterval) {
        guard !keyframeServiceScheduled else { return }
        keyframeServiceScheduled = true
        let gen = generation
        queue.asyncAfter(deadline: .now() + max(delay, 0.01)) { [weak self] in
            guard let self else { return }
            // A stale generation must not release the next generation's slot.
            guard self.generation == gen else { return }
            self.keyframeServiceScheduled = false
            guard self.active else { return }
            self.serviceKeyframeRequest()
        }
    }

    private func discardCachedFrame() {
        cachedFrame = nil
        withKeyframeState { $0.discardCachedFrame() }
    }

    /// Returns true when VideoToolbox accepted the frame. A refused submission
    /// leaves the client's keyframe request outstanding so it is retried.
    @discardableResult
    private func encode(pixelBuffer: CVPixelBuffer,
                        presentationTime: CMTime,
                        session: VTCompressionSession,
                        synthetic: Bool = false) -> Bool {
        let step = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        let pts = PresentationTimeRules.next(last: lastPresentationTime,
                                             proposed: presentationTime,
                                             fallback: CMClockGetTime(CMClockGetHostTimeClock()),
                                             step: step)
        lastPresentationTime = pts

        var requestedSerial: UInt64?
        withKeyframeState { state in
            requestedSerial = state.pendingRequestSerial
        }
        let forceKeyframe = requestedSerial != nil || needsRecoveryIDR

        let properties: CFDictionary? = forceKeyframe
            ? ([kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary)
            : nil
        let gen = generation

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: step,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, infoFlags, sampleBuffer in
            guard let self else { return }
            self.queue.async {
                // Clear the synthetic flag for this generation only: a stale
                // callback must not release the next generation's slot.
                if synthetic, self.generation == gen {
                    self.withKeyframeState { $0.finishSyntheticEncode() }
                }
                guard self.active, self.generation == gen else { return }
                let delivered = self.handleEncodedFrame(status: status,
                                                        infoFlags: infoFlags,
                                                        sampleBuffer: sampleBuffer,
                                                        generation: gen)
                // A client request is only satisfied by an IDR that was
                // actually delivered. A dropped or rejected frame leaves it
                // pending for the next sample or request.
                if let requestedSerial, delivered?.keyframe == true {
                    self.withKeyframeState { $0.markRequestSatisfied(upTo: requestedSerial) }
                    if synthetic {
                        // Answer a request that arrived while this IDR was in
                        // flight, from the same cached frame.
                        self.serviceKeyframeRequest()
                    }
                }
            }
        }
        guard status == noErr else {
            noteEncodeFailure(status)
            return false
        }
        needsRecoveryIDR = false
        return true
    }

    /// Returns the frame handed to the session layer, or nil when this encode
    /// produced no deliverable frame.
    @discardableResult
    private func handleEncodedFrame(status: OSStatus,
                                    infoFlags: VTEncodeInfoFlags,
                                    sampleBuffer: CMSampleBuffer?,
                                    generation gen: Int) -> EncodedFrame? {
        guard active, generation == gen else { return nil }
        if status != noErr {
            noteEncodeFailure(status)
            return nil
        }
        encodeFailureCount = 0
        if infoFlags.contains(.frameDropped) { return nil }
        guard let sampleBuffer, let data = Self.copyFrameData(sampleBuffer) else { return nil }
        guard let format = streamFormat(from: sampleBuffer) else { return nil }
        guard data.count <= VideoPacketLimits.maxFrameDataBytes else {
            delegate?.captureEncoder(self, didUpdateStatus: "编码帧超过单包上限（\(data.count) 字节），已丢弃并等待关键帧")
            needsRecoveryIDR = true
            return nil
        }
        if !formatStatusReported {
            formatStatusReported = true
            delegate?.captureEncoder(self, didUpdateStatus: statusDescription(format))
        }
        let frame = EncodedFrame(
            keyframe: Self.isKeyframe(sampleBuffer),
            timestampUs: Self.microseconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
            data: data,
            format: format
        )
        delegate?.captureEncoder(self, didEncode: frame)
        return frame
    }

    private func statusDescription(_ format: StreamFormat) -> String {
        let profile = format.hdr ? "HEVC Main10 10-bit" : "HEVC Main 8-bit"
        let color = format.hdr
            ? "HDR \(format.colorPrimaries)/\(format.transferFunction)"
            : "SDR \(format.colorPrimaries)/\(format.transferFunction)"
        let encoder = hardwareEncode ? "硬件编码" : "软件编码"
        let mbps = Double(currentBitrate) / 1_000_000.0
        return String(format: "%@ · %d×%d · %d fps · %@ · %@ · 画质 %@ · %.1f Mbps",
                      profile, format.width, format.height, fps, color, encoder, quality.title, mbps)
    }

    // MARK: Format description

    private func streamFormat(from sampleBuffer: CMSampleBuffer) -> StreamFormat? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        if let cachedFormat, let cachedDescription, CFEqual(cachedDescription, description) {
            return cachedFormat
        }
        guard let parameterSets = Self.hevcParameterSets(description) else {
            if !formatStatusReported {
                formatStatusReported = true
                delegate?.captureEncoder(self, didUpdateStatus: "编码输出缺少 VPS/SPS/PPS，无法通知客户端视频格式")
            }
            return nil
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let colors = resolvedColorInfo(description)
        let format = StreamFormat(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            hdr: hdrMode.isHDR,
            vps: parameterSets.vps,
            sps: parameterSets.sps,
            pps: parameterSets.pps,
            colorPrimaries: colors.primaries,
            transferFunction: colors.transfer,
            yCbCrMatrix: colors.matrix
        )
        cachedFormat = format
        cachedDescription = description
        return format
    }

    private func resolvedColorInfo(_ description: CMFormatDescription) -> (primaries: String, transfer: String, matrix: String) {
        let defaults = Self.defaultColors(hdr: hdrMode.isHDR)
        var primaries = captureColorInfo?.primaries ?? defaults.primaries
        var transfer = captureColorInfo?.transfer ?? defaults.transfer
        var matrix = captureColorInfo?.matrix ?? defaults.matrix

        if let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] {
            if let value = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String {
                primaries = value
            }
            if let value = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String {
                transfer = value
            }
            if let value = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String {
                matrix = value
            }
        }
        return (primaries, transfer, matrix)
    }

    private static func defaultColors(hdr: Bool) -> (primaries: String, transfer: String, matrix: String) {
        if hdr {
            // `SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay)`
            // outputs DisplayP3 with the PQ transfer function and a BT.709
            // YCbCr matrix. These are only fallbacks when the capture buffer
            // carries no attachments of its own.
            return (kCMFormatDescriptionColorPrimaries_P3_D65 as String,
                    kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
                    kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        }
        return (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
                kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
                kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
    }

    private static func hevcParameterSets(_ description: CMFormatDescription) -> (vps: Data, sps: Data, pps: Data)? {
        var count = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            description,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil
        ) == noErr, count > 0 else { return nil }
        var vps: Data?
        var sps: Data?
        var pps: Data?
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                description,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer, size > 0 else { continue }
            let nalType = (pointer[0] >> 1) & 0x3F
            let data = Data(bytes: pointer, count: size)
            switch nalType {
            case 32: if vps == nil { vps = data }
            case 33: if sps == nil { sps = data }
            case 34: if pps == nil { pps = data }
            default: break
            }
        }
        guard let vps, let sps, let pps else { return nil }
        return (vps, sps, pps)
    }

    // MARK: Sample helpers

    private static func frameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let raw = attachments[SCStreamFrameInfo.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    private static func colorInfo(from sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer) -> ColorInfo {
        var info = ColorInfo()
        if let description = CMSampleBufferGetFormatDescription(sampleBuffer),
           let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] {
            info.primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
            info.transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            info.matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
        }
        if info.primaries == nil {
            info.primaries = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil) as? String
        }
        if info.transfer == nil {
            info.transfer = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String
        }
        if info.matrix == nil {
            info.matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        }
        return info
    }

    private static func hdrVerificationFailure(pixelBuffer: CVPixelBuffer, info: ColorInfo) -> String? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard isTenBit(pixelFormat) else {
            return "捕获输出为 \(fourCC(pixelFormat))（8-bit），未产生 10-bit HDR 缓冲"
        }
        if let primaries = info.primaries {
            let bt2020 = kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String
            let p3 = kCMFormatDescriptionColorPrimaries_P3_D65 as String
            if primaries != bt2020 && primaries != p3 {
                return "捕获色彩原色为 \(primaries)，不是 BT.2020 或 P3"
            }
        }
        if let transfer = info.transfer {
            let pq = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
            let hlg = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
            if transfer != pq && transfer != hlg {
                return "捕获传输函数为 \(transfer)，不是 PQ/HLG"
            }
        }
        return nil
    }

    private static func isTenBit(_ pixelFormat: OSType) -> Bool {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10,
             kCVPixelFormatType_422YpCbCr10,
             kCVPixelFormatType_ARGB2101010LEPacked,
             kCVPixelFormatType_40ARGBLEWideGamut:
            return true
        default:
            return false
        }
    }

    private static func fourCC(_ value: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "0x\(String(value, radix: 16))"
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let attachments = attachmentsArray.first else { return true }
        if let notSync = attachments[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            return !notSync
        }
        if let notSync = attachments[kCMSampleAttachmentKey_NotSync as String] as? NSNumber {
            return !notSync.boolValue
        }
        return true
    }

    private static func copyFrameData(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base) == kCMBlockBufferNoErr
        }
        return copied ? data : nil
    }

    private static func microseconds(_ time: CMTime) -> UInt64 {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else {
            return DispatchTime.now().uptimeNanoseconds / 1000
        }
        return UInt64((seconds * 1_000_000).rounded())
    }

    // MARK: Failure handling

    /// Tears the HDR pipeline down once and restarts a plain SDR session. Safe
    /// to call from the capture queue; guarded so repeated failing frames do
    /// not start a thundering herd of restarts.
    private func fallbackFromHDR(reason: String) {
        guard !hdrFallbackScheduled else { return }
        hdrFallbackScheduled = true
        delegate?.captureEncoder(self, didUpdateStatus: "HDR 不可用：\(reason)；关闭旧会话并回退到 SDR")
        _ = teardownCapture()
        retryAttempt = 0
        didReportHDRUnavailable = true
        hdrFailedThisSession = true
        beginAttempt(hdr: false, generation: generation)
    }

    private func noteEncodeFailure(_ status: OSStatus) {
        encodeFailureCount += 1
        needsRecoveryIDR = true
        delegate?.captureEncoder(self, didUpdateStatus: "编码失败（OSStatus \(status)）")
        if encodeFailureCount >= 3, hdrMode != .sdr {
            fallbackFromHDR(reason: "HDR 编码连续失败（OSStatus \(status)）")
        }
    }

    private func handleStartFailure(error: Error, hdrAttempt: Bool, generation gen: Int) {
        let description = Self.describe(captureError: error)
        if hdrAttempt {
            delegate?.captureEncoder(self, didUpdateStatus: "HDR 采集启动失败：\(description)；关闭旧会话并回退到 SDR")
            _ = teardownCapture()
            let newGen = generation
            retryAttempt = 0
            didReportHDRUnavailable = true
            hdrFailedThisSession = true
            beginAttempt(hdr: false, generation: newGen)
            return
        }

        if Self.isPermissionError(error) {
            _ = teardownCapture()
            active = false
            delegate?.captureEncoder(self, didFail: "屏幕录制权限不可用：\(description)。请在“系统设置 › 隐私与安全性 › 屏幕录制”中允许后重新启动本应用。", retryable: false)
            return
        }

        delegate?.captureEncoder(self, didFail: "屏幕采集启动失败：\(description)", retryable: true)
        scheduleRetry(hdr: false, generation: gen)
    }

    private func handleNoDisplay(hdrAttempt: Bool, generation gen: Int) {
        if hdrAttempt {
            // Retry in SDR first; the HDR path itself may be unavailable.
            _ = teardownCapture()
            let newGen = generation
            beginAttempt(hdr: false, generation: newGen)
            return
        }
        // On some macOS versions a missing TCC grant surfaces as a successful
        // SCShareableContent with an empty display list. Diagnose that instead
        // of retrying for ten minutes under a "no display / headless" message.
        if !CGPreflightScreenCaptureAccess() {
            _ = teardownCapture()
            active = false
            delegate?.captureEncoder(
                self,
                didFail: "ScreenCaptureKit 没有返回可捕获显示器，且屏幕录制权限尚未授予。请在“系统设置 › 隐私与安全性 › 屏幕录制”中允许本应用，然后重新启动本应用。",
                retryable: false
            )
            return
        }
        let diagnosis = Self.noDisplayDiagnosis()
        if !didReportNoDisplay {
            didReportNoDisplay = true
            delegate?.captureEncoder(self, didFail: diagnosis, retryable: true)
        }
        scheduleRetry(hdr: false, generation: gen)
    }

    private func scheduleRetry(hdr: Bool, generation gen: Int) {
        retryAttempt += 1
        guard retryAttempt <= 120 else {
            delegate?.captureEncoder(self, didFail: "多次重试后仍无可用画面源，已停止自动重试。", retryable: false)
            active = false
            return
        }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.active, self.generation == gen else { return }
            _ = self.teardownCapture()
            let newGen = self.generation
            self.beginAttempt(hdr: hdr, generation: newGen)
        }
    }

    private static func noDisplayDiagnosis() -> String {
        if !CGPreflightScreenCaptureAccess() {
            return "未收到画面：屏幕录制权限尚未授予。请在“系统设置 › 隐私与安全性 › 屏幕录制”中允许本应用并重新启动，授权前不会开始采集。"
        }
        let mainID = CGMainDisplayID()
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineCount)
        if CGDisplayIsAsleep(mainID) != 0 {
            return "未收到画面：主显示器处于睡眠状态，ScreenCaptureKit 没有返回可捕获显示器。本机不会自动唤醒显示器；唤醒后会自动重试。"
        }
        if onlineCount == 0 {
            return "未检测到在线显示器（无头模式）。macOS 15 没有公开的虚拟显示器创建 API，需要连接物理显示器、HDMI 诱骗器或第三方虚拟显示器驱动；本应用不会安装任何驱动。"
        }
        return "ScreenCaptureKit 未返回可捕获显示器（在线显示器 \(onlineCount) 台，主显示器 \(mainID)）。请检查屏幕录制权限与显示器连接状态。"
    }

    private static func describe(captureError error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            switch nsError.code {
            case -3801: return "用户拒绝了屏幕录制权限"
            case -3802: return "系统未能启动采集流"
            case -3803: return "缺少屏幕录制授权（TCC）"
            case -3807, -3808: return "采集状态冲突，请重试"
            case -3811: return "ScreenCaptureKit 内部错误"
            case -3814: return "没有可用的显示器列表"
            case -3815: return "没有可捕获的画面源"
            case -3817: return "采集被用户停止"
            case -3821: return "系统停止了采集流"
            default: return "ScreenCaptureKit 错误 \(nsError.code)"
            }
        }
        return nsError.localizedDescription
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let permissionCodes = [-3801, -3803]
        return (nsError.domain == SCStreamErrorDomain && permissionCodes.contains(nsError.code))
            || !CGPreflightScreenCaptureAccess()
    }
}

// MARK: - SCStream callbacks

extension CaptureEncoder: SCStreamOutput, SCStreamDelegate {

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        handleSample(sampleBuffer, from: stream)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, self.active, self.stream === stream else { return }
            let description = Self.describe(captureError: error)
            let code = (error as NSError).code
            if code == -3817 {
                self.delegate?.captureEncoder(self, didUpdateStatus: "采集流已被停止：\(description)")
                self.teardownCapture()
                self.active = false
                return
            }
            // Recompute the mode instead of silently pinning the session to
            // SDR: a healthy HDR session must come back as HDR, while a
            // session that already fell back (or whose display no longer has
            // EDR headroom, or whose client never asked for HDR) restarts as
            // SDR with an accurate status.
            let unavailableReason = self.hdrUnavailableReason()
            let decision = CaptureRestartPolicy.decision(
                clientSupportsHDR: self.request?.clientSupportsHDR ?? false,
                hdrUnavailableReason: unavailableReason,
                hdrPreviouslyFailed: self.hdrFailedThisSession,
                hdrRestartsWithoutConfirmation: self.hdrRestartsWithoutConfirmation
            )
            let restartHDR: Bool
            switch decision {
            case .restartHDR:
                restartHDR = true
                self.hdrRestartsWithoutConfirmation += 1
                self.delegate?.captureEncoder(
                    self,
                    didUpdateStatus: "采集流意外停止：\(description)；正在以 HDR 重新启动采集（第 \(self.hdrRestartsWithoutConfirmation) 次）"
                )
            case .restartSDR(let reason):
                restartHDR = false
                // Staying on SDR while the display still has EDR headroom and
                // the client asked for HDR means HDR actually failed.
                if reason != nil, unavailableReason == nil {
                    self.hdrFailedThisSession = true
                }
                // Say "HDR 已关闭" once; later stops repeat only the plain
                // SDR restart status instead of spamming the same reason.
                let wasAlreadyReported = self.didReportHDRUnavailable
                if reason != nil { self.didReportHDRUnavailable = true }
                if let reason, !wasAlreadyReported {
                    self.delegate?.captureEncoder(
                        self,
                        didUpdateStatus: "采集流意外停止：\(description)；HDR 已关闭：\(reason)；以 SDR 重新启动采集"
                    )
                } else {
                    self.delegate?.captureEncoder(
                        self,
                        didUpdateStatus: "采集流意外停止：\(description)；正在以 SDR 重新启动采集"
                    )
                }
            }
            let gen = self.teardownCapture()
            self.retryAttempt = 0
            self.beginAttempt(hdr: restartHDR, generation: gen)
        }
    }
}
