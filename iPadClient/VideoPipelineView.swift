//
//  VideoPipelineView.swift
//  XDRScreen (iPad client)
//
//  The single video surface owned by the client UI. It hosts two renderers:
//
//    * HDRMetalVideoView   — VideoToolbox 10-bit HEVC decode + CoreImage/Metal
//                            presentation with CAMetalLayer EDR. Preferred.
//    * VideoDisplayView    — AVSampleBufferDisplayLayer (system HEVC decoder).
//                            Compatibility fallback when Metal/EDR cannot run.
//
//  Both subviews fill the container; only the selected engine is visible.
//  `ClientController` talks to this type exactly like it used to talk to
//  VideoDisplayView, so the touch/letterbox contract stays unchanged:
//
//    applyFormat(_:)        new VPS/SPS/PPS + colour metadata (main queue)
//    submitFrame(payload:)  one VideoFramePayload (any queue, non-blocking)
//    resetForDisconnect()   drop decoder state, wait for the next key frame
//    playbackRect           aspect-fit video rect in this view's coordinates
//
//  Fallback policy
//  ---------------
//  HDRMetalVideoView reports typed failures. Only `.unrecoverable` ones switch
//  engines: no Metal device/queue/CAMetalLayer, rejected format metadata
//  (parameter sets, dimensions, matrix, primaries/transfer pair) or a decoder
//  that could not be created for the format. Transient decode errors stay in
//  HDRMetalVideoView, which rebuilds its own session and asks for a key frame.
//
//  A switch happens at most once per connection, reuses the format that is
//  current at that moment and requests a key frame. Every failure carries the
//  format generation it belongs to; callbacks for a replaced format or a
//  previous connection are ignored. If the compatibility decoder also rejects
//  the format, the view becomes terminal: frames are dropped, no more key
//  frames are requested, and `onRendererUnavailable` tells the controller to
//  stop and show an actionable error instead of pretending to stream.
//

import CoreMedia
import Metal
import UIKit

final class ClientVideoView: UIView {

    // MARK: - Outputs (main queue)

    /// The active decoder needs an IDR. Both engines may call this.
    var onNeedKeyframe: (() -> Void)?
    /// First frame committed to the screen for this connection.
    var onFirstFrame: (() -> Void)?
    /// User-presentable renderer trouble. The controller shows it and asks the
    /// host for a key frame; input is never blocked.
    var onRenderFailure: ((String) -> Void)?
    /// Neither renderer can present the format the Mac sent. The controller
    /// stops the connection and shows `message`; frames are already dropped
    /// and no more key frames are requested.
    var onRendererUnavailable: ((String, VideoFormatMessage) -> Void)?

    // MARK: - Engines

    private let metalView = HDRMetalVideoView()
    private let layerView = VideoDisplayView()

    /// Thread-safe: `submitFrame` runs on the network queue while format and
    /// fallback changes happen on the main queue.
    private let stateLock = NSLock()
    private var policy: RendererFallbackPolicy
    private var activeFormat: VideoFormatMessage?
    /// Monotonic token that identifies one applied format. Every Metal failure
    /// echoes the token it belongs to, so late callbacks from a replaced
    /// format or a previous connection can be dropped. The policy holds the
    /// token that is current now; tokens are never reused.
    private var formatEpoch: UInt64 = 0

    private var didReportFirstFrame = false

    /// Presentation size in pixels; main queue (used by playbackRect).
    private(set) var videoSize: CGSize = .zero

    /// The Metal pipeline is only offered when the device can actually run it.
    private static let metalPipelineAvailable: Bool = {
        guard MTLCreateSystemDefaultDevice() != nil else { return false }
        // The renderer's working space; without it there is no HDR path.
        return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) != nil
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        policy = RendererFallbackPolicy(metalAvailable: Self.metalPipelineAvailable)
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        policy = RendererFallbackPolicy(metalAvailable: Self.metalPipelineAvailable)
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true
        isUserInteractionEnabled = false

        layerView.isHidden = true
        metalView.isHidden = true
        for child in [layerView, metalView] as [UIView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: leadingAnchor),
                child.trailingAnchor.constraint(equalTo: trailingAnchor),
                child.topAnchor.constraint(equalTo: topAnchor),
                child.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        metalView.onNeedKeyFrame = { [weak self] in
            self?.onNeedKeyframe?()
        }
        metalView.onFailure = { [weak self] failure in
            self?.handleMetalFailure(failure)
        }
        metalView.onFirstFrame = { [weak self] in
            self?.reportFirstFrame(from: .metal)
        }

        layerView.onNeedKeyframe = { [weak self] in
            self?.onNeedKeyframe?()
        }
        layerView.onRenderFailure = { [weak self] message in
            self?.onRenderFailure?(message)
        }
        layerView.onFirstFrame = { [weak self] in
            self?.reportFirstFrame(from: .layer)
        }
    }

    // MARK: - Geometry

    /// The rect the video actually occupies inside this view (aspect fit).
    /// Touch mapping uses this so letterboxed taps are ignored; rotation and
    /// format changes only move this rect, never the input contract.
    var playbackRect: CGRect {
        AspectFit.rect(for: videoSize, in: bounds)
    }

    /// Frames actually presented by the active engine (for the control bar).
    var renderedFPS: Int {
        stateLock.lock()
        let engine = policy.engine
        stateLock.unlock()
        switch engine {
        case .metal:
            return metalView.renderedFPS
        case .layer:
            return layerView.renderedFPS
        }
    }

    /// True when HDR/Metal was unavailable and the compatibility engine is
    /// presenting instead. The control bar uses it to avoid implying that an
    /// EDR picture is on screen.
    var isUsingFallbackRenderer: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return policy.engine == .layer && activeFormat != nil
    }

    // MARK: - Format (main queue)

    @discardableResult
    func applyFormat(_ message: VideoFormatMessage) -> Bool {
        guard message.width > 1,
              message.height > 1,
              !message.vps.isEmpty,
              !message.sps.isEmpty,
              !message.pps.isEmpty else {
            onRenderFailure?("Mac 发送的视频参数不完整，无法解码。")
            return false
        }

        videoSize = Self.presentationSize(for: message)
            ?? CGSize(width: message.width, height: message.height)

        let metalUsable = metalView.isRendererUsable

        stateLock.lock()
        activeFormat = message
        formatEpoch &+= 1
        let generation = formatEpoch
        let begun = policy.beginFormat(generation: generation, metalUsable: metalUsable)
        stateLock.unlock()

        switch begun.engine {
        case .metal:
            layerView.resetForDisconnect()
            layerView.isHidden = true
            metalView.isHidden = false
            metalView.configure(message, generation: generation)
        case .layer:
            adoptFormatOnLayer(
                message,
                reason: begun.didFallBack ? "此设备无法创建 Metal 渲染管线" : nil)
        }

        setNeedsLayout()
        return true
    }

    /// Disconnect / background / new connection: drop all decoder state and
    /// wait for the next IDR. The last remote image must not stay on screen
    /// while the UI says it is disconnected.
    func resetForDisconnect() {
        stateLock.lock()
        activeFormat = nil
        // A new session gets new tokens, so a callback that is still queued
        // from the old one can never match the generation that is active now.
        policy.endSession()
        stateLock.unlock()

        didReportFirstFrame = false
        videoSize = .zero
        metalView.reset()
        metalView.isHidden = true
        layerView.resetForDisconnect()
        layerView.isHidden = true
        setNeedsLayout()
    }

    // MARK: - Frames (any queue)

    /// Thread-safe and non-blocking. Each engine applies its own bounded
    /// in-flight limit and requests an IDR instead of buffering without limit.
    func submitFrame(payload: Data) {
        stateLock.lock()
        let engine = policy.engine
        let acceptsFrames = activeFormat != nil && !policy.isTerminal
        stateLock.unlock()
        // A terminal renderer drops frames without asking for a key frame: the
        // controller has already been told that this stream cannot be shown.
        guard acceptsFrames else { return }

        switch engine {
        case .layer:
            // VideoDisplayView decodes and bounds its main-queue backlog.
            layerView.submitFrame(payload: payload)
        case .metal:
            guard let decoded = VideoFramePayload.decode(payload) else {
                notifyRenderFailure("收到损坏的视频帧。")
                notifyNeedKeyframe()
                return
            }
            guard !decoded.data.isEmpty, decoded.data.count <= Wire.maxFrameBytes else {
                notifyRenderFailure("视频帧长度异常。")
                notifyNeedKeyframe()
                return
            }
            // HDRMetalVideoView owns the in-flight budget and asks for a key
            // frame when the budget is full; never queues here.
            metalView.enqueue(
                keyframe: decoded.keyframe,
                timestampUs: decoded.timestampUs,
                data: decoded.data
            )
        }
    }

    // MARK: - Renderer selection

    private func handleMetalFailure(_ failure: HDRMetalVideoView.Failure) {
        // Called on the main queue by HDRMetalVideoView.
        let kind: RendererFallbackPolicy.FailureKind
        switch failure.kind {
        case .recoverable:
            kind = .recoverable
        case .unrecoverable:
            kind = .unrecoverable
        }

        stateLock.lock()
        let disposition = policy.evaluateFailure(
            kind: kind,
            generation: failure.formatGeneration)
        let format = activeFormat
        stateLock.unlock()

        switch disposition {
        case .ignore:
            // Stale format generation, already-fell-back session, or the view
            // is terminal. Acting here would switch/reset a newer session.
            return
        case .report:
            onRenderFailure?(failure.message)
        case .fallBackToLayer:
            // `evaluateFailure` already consumed the single allowed fallback,
            // so a second failure for this format cannot switch twice.
            guard let format else { return }
            adoptFormatOnLayer(format, reason: failure.message)
        }
    }

    /// Hands `format` to the compatibility decoder and, when asked, explains
    /// why the Metal path is no longer used. The format is the one that is
    /// current in this session; stale formats never reach here.
    private func adoptFormatOnLayer(_ format: VideoFormatMessage, reason: String?) {
        metalView.reset()
        metalView.isHidden = true
        layerView.isHidden = false

        if layerView.applyFormat(format) {
            stateLock.lock()
            policy.fallbackSucceeded()
            stateLock.unlock()

            if let reason {
                onRenderFailure?("HDR/Metal 渲染不可用，已切换到兼容渲染（HEVC 系统解码器）：\(reason)")
            }
            // The compatibility decoder also has no reference frames.
            notifyNeedKeyframe()
        } else {
            markRendererUnavailable(format, reason: reason)
        }
    }

    /// No engine on this device can present the current format. Stop feeding
    /// frames, stop requesting key frames and let the controller end the
    /// connection with an actionable message instead of a black screen that
    /// looks connected.
    private func markRendererUnavailable(_ format: VideoFormatMessage, reason: String?) {
        stateLock.lock()
        policy.fallbackFailed()
        activeFormat = nil
        stateLock.unlock()

        videoSize = .zero
        setNeedsLayout()

        var message = "此视频格式无法由本机解码器渲染，已停止请求画面。请在 Mac 端降低分辨率或关闭 HDR 后重新连接。"
        if let reason, !reason.isEmpty {
            message += "（\(reason)）"
        }
        onRendererUnavailable?(message, format)
    }

    private func reportFirstFrame(from engine: RendererFallbackPolicy.Engine) {
        stateLock.lock()
        let isCurrent = policy.engine == engine
        stateLock.unlock()
        guard isCurrent, !didReportFirstFrame else { return }
        didReportFirstFrame = true
        onFirstFrame?()
    }

    // MARK: - Callbacks from non-main contexts

    private func notifyNeedKeyframe() {
        if Thread.isMainThread {
            onNeedKeyframe?()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onNeedKeyframe?()
            }
        }
    }

    private func notifyRenderFailure(_ message: String) {
        if Thread.isMainThread {
            onRenderFailure?(message)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onRenderFailure?(message)
            }
        }
    }

    // MARK: - Presentation size

    /// Matches what the decoder actually shows (pixel aspect ratio and clean
    /// aperture), so the aspect-fit touch rectangle is not a few pixels off.
    private static func presentationSize(for message: VideoFormatMessage) -> CGSize? {
        let vps = message.vps
        let sps = message.sps
        let pps = message.pps
        var description: CMFormatDescription?
        let status: OSStatus = vps.withUnsafeBytes { vpsRaw in
            sps.withUnsafeBytes { spsRaw in
                pps.withUnsafeBytes { ppsRaw in
                    guard let vpsBase = vpsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let spsBase = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsBase = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return OSStatus(-1)
                    }
                    var pointers: [UnsafePointer<UInt8>] = [vpsBase, spsBase, ppsBase]
                    var sizes: [Int] = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &description
                    )
                }
            }
        }
        guard status == noErr, let description else { return nil }
        let presented = CMVideoFormatDescriptionGetPresentationDimensions(
            description,
            usePixelAspectRatio: true,
            useCleanAperture: true
        )
        guard presented.width > 1, presented.height > 1 else { return nil }
        return presented
    }
}

// BEGIN RendererFallbackPolicy — pure decision state, no UIKit. The region
// between these markers is compiled and exercised by the state-machine test.
//
// Rules:
//   * the compatibility renderer is used at most once per connection;
//   * a failure is only acted on when it belongs to the format generation that
//     is active now, so late callbacks from a replaced format or a previous
//     connection cannot switch or reset the new session;
//   * recoverable failures never switch renderers;
//   * when neither renderer can present the format the state becomes terminal:
//     frames are dropped and no more key frames are requested.
struct RendererFallbackPolicy {

    enum Engine: Equatable {
        case metal
        case layer
    }

    enum FailureKind: Equatable {
        case recoverable
        case unrecoverable
    }

    enum Disposition: Equatable {
        /// Stale generation, no active format, or already terminal.
        case ignore
        /// Surface the message; keep the current engine.
        case report
        /// Switch to the compatibility renderer (allowed once).
        case fallBackToLayer
    }

    struct BeginResult: Equatable {
        let engine: Engine
        let didFallBack: Bool
    }

    private let metalAvailable: Bool
    private(set) var engine: Engine
    private(set) var isTerminal = false
    private(set) var fallbackUsed = false
    /// Generation of the format currently handed to the Metal view; 0 when the
    /// compatibility engine owns it or nothing is active.
    private(set) var activeMetalGeneration: UInt64 = 0

    init(metalAvailable: Bool) {
        self.metalAvailable = metalAvailable
        self.engine = metalAvailable ? .metal : .layer
    }

    /// A new format arrives. If the Metal renderer was already known to be
    /// unusable, this is the single implicit fallback for the connection.
    mutating func beginFormat(generation: UInt64, metalUsable: Bool) -> BeginResult {
        isTerminal = false
        var didFallBack = false
        if engine == .metal, !metalUsable {
            engine = .layer
            fallbackUsed = true
            didFallBack = true
        }
        activeMetalGeneration = engine == .metal ? generation : 0
        return BeginResult(engine: engine, didFallBack: didFallBack)
    }

    /// Decides what a Metal failure means for the current session. Returning
    /// `.fallBackToLayer` consumes the one allowed fallback.
    mutating func evaluateFailure(kind: FailureKind, generation: UInt64?) -> Disposition {
        guard !isTerminal, engine == .metal, activeMetalGeneration != 0 else {
            return .ignore
        }
        if let generation, generation != activeMetalGeneration {
            return .ignore
        }
        switch kind {
        case .recoverable:
            return .report
        case .unrecoverable:
            guard !fallbackUsed else { return .ignore }
            fallbackUsed = true
            return .fallBackToLayer
        }
    }

    /// The compatibility decoder accepted the format.
    mutating func fallbackSucceeded() {
        engine = .layer
        fallbackUsed = true
        activeMetalGeneration = 0
    }

    /// The compatibility decoder rejected the format too.
    mutating func fallbackFailed() {
        engine = .layer
        fallbackUsed = true
        activeMetalGeneration = 0
        isTerminal = true
    }

    mutating func endSession() {
        engine = metalAvailable ? .metal : .layer
        fallbackUsed = false
        isTerminal = false
        activeMetalGeneration = 0
    }
}
// END RendererFallbackPolicy
