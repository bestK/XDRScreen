//
//  HDRMetalVideoView.swift
//  XDRScreen
//
//  A self-contained UIView that hardware-decodes 10-bit HEVC (Main10) with
//  VideoToolbox and presents the result on an EDR-capable CAMetalLayer.
//
//  Pipeline
//  --------
//  VPS/SPS/PPS + sender color metadata
//      -> CMVideoFormatDescriptionCreateFromHEVCParameterSets (extensions are
//         filled in verbatim from the sender; nothing is guessed)
//      -> VTDecompressionSession (hardware HEVC required, 10-bit 4:2:0 output)
//      -> CIImage tagged with the sender's primaries/transfer function
//      -> CIContext (Metal, half-float RGBAh working space = extended linear
//         Display P3) converts YCbCr -> linear extended-range RGB on the GPU,
//         with no 8-bit intermediate
//      -> RGBA16Float drawable, CAMetalLayer.wantsExtendedDynamicRangeContent
//         = true, presented immediately.
//
//  Orientation (see VideoPresentationGeometry.swift)
//  -----------
//  CIContext renders into a texture bottom-up, so the Core Image transform
//  ends with a vertical flip that makes the presented picture match the
//  decoded frame (measured with a four-quadrant frame, not assumed). On top of
//  that, `StreamOrientation.current` flips the picture top-to-bottom relative
//  to the previous Metal output, based on real device feedback; the exact
//  cause is still to be verified and this has not been checked on a real
//  device. Aspect-fit, letterboxing, the frame's own extent and HDR colour all
//  stay untouched: only a vertical flip of the picture inside the same fitted
//  rect, with left and right unchanged.
//
//  Integration
//  -----------
//  let view = HDRMetalVideoView(frame: ...)
//  view.onFailure = { failure in /* unrecoverable: switch renderer once */ }
//  view.onNeedKeyFrame = { /* ask the host for an IDR/CRA */ }
//  view.configure(format, generation: token)    // on a format message
//  view.enqueue(keyframe:ts:data:)              // per video frame
//  view.reset()                                 // disconnect / background / format change
//
//  `onFailure` and `onNeedKeyFrame` are invoked on the main queue. Both may be
//  assigned or replaced from any thread. `configure`, `enqueue` and `reset`
//  are thread-safe; they never block the caller and never present UI off-main.
//  Decoding and rendering are serialized on a private serial queue.
//
//  Failures are typed. `.unrecoverable` means this view cannot present the
//  stream at all (Metal unavailable, format metadata rejected, decoder could
//  not be created for the format); a caller that owns a compatibility
//  renderer should switch to it once. `.recoverable` is a transient decode or
//  render hiccup this view repairs by itself (rebuild + key-frame request) and
//  must not cause a renderer switch. Each failure also carries the caller's
//  `generation` token for the format it belongs to, so a late callback from a
//  replaced format or a previous connection can be ignored.
//
//  Deliberate color policy (no guessing)
//  -------------------------------------
//  The format message is the only source of color metadata. Contradictions are
//  rejected with `onFailure` instead of being silently repaired:
//    * hdr == true requires an HLG or PQ transfer function;
//    * hdr == false forbids HLG/PQ;
//    * unknown primaries/transfer/matrix strings are rejected;
//    * unsupported primaries/transfer pairs are rejected (no BT.709+PQ
//      invention, no "assume BT.2020").
//
//  Known limitations (not verified on device)
//  ------------------------------------------
//    * No real iPad was available to this task. The code is SDK type-checked
//      for iOS 16.0 and its colour/orientation/drawable behaviour was checked
//      in the iPadOS 18.3 simulator, but brightness, EDR headroom and decode
//      behaviour have not been observed on an iPad13,8 / iPadOS 16.6.1. Do
//      not claim that true XDR luminance has been proven.
//    * YCbCr -> RGB uses the CoreVideo attachments we set on the pixel buffer
//      plus CIImage's `.colorSpace` option. CoreImage/ColorSync own the exact
//      transfer-function math and the mapping of code values to nits; this
//      view neither calibrates nor tone maps.
//    * CAEDRMetadata is deliberately nil for both PQ and HLG. Measured on
//      macOS and on the iPadOS 18.3 simulator (same engine family; NOT
//      verified on an iPadOS 16.6.1 device): PQ -> extended linear P3 maps
//      10,000 nits to ~49.25, i.e. 1.0 is a 203-nit reference white; HLG -> linear
//      already applies the inverse OETF *and* the 1.2-gamma OOTF normalized
//      to a 1000-nit reference (signal 0.75 -> 1.0, signal 1.0 -> ~4.93).
//      Setting `CAEDRMetadata.hlg` would make the system apply the OOTF a
//      second time, and the wire format carries no mastering-display/CLLI
//      information from which honest HDR10 metadata could be built. The layer
//      therefore presents the linear values as-is, clamping only at the
//      display's EDR headroom; values above headroom are clipped rather than
//      tone mapped.
//    * The layer is always configured as extended linear Display P3. SDR
//      content is color converted into that space and stays at <= 1.0.
//    * Frames are presented in decoder output order immediately; input PTS is
//      forwarded to VideoToolbox but is not used to pace presentation.
//    * Full-range vs video-range is left to VideoToolbox (both 10-bit and
//      8-bit biplanar formats are offered). The bitstream's own flag wins.
//    * No audio is handled here.
//

import CoreImage
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import UIKit
import VideoToolbox

final class HDRMetalVideoView: UIView {

    // MARK: - Public API

    /// Why `onFailure` fired.
    enum FailureKind {
        /// A transient decode/render hiccup. The view rebuilds or re-requests
        /// a key frame by itself; callers should only surface the message.
        case recoverable
        /// This view cannot present the stream at all: unusable Metal
        /// pipeline, rejected format metadata, or a decoder that could not be
        /// created for the format. A caller that owns a compatibility
        /// renderer may switch to it once per format generation.
        case unrecoverable
    }

    struct Failure {
        let kind: FailureKind
        let message: String
        /// The generation passed to `configure` when the failure belongs to a
        /// stream format; nil for device-level failures (no Metal at all).
        /// Callers compare it with the generation they consider current so a
        /// late callback for a replaced format is ignored.
        let formatGeneration: UInt64?
    }

    /// Called on the main queue with a user-presentable message when the view
    /// cannot (or can no longer) present the stream faithfully. The view keeps
    /// accepting input; callers must not block the UI on this.
    var onFailure: ((Failure) -> Void)? {
        get {
            publicStateLock.lock()
            defer { publicStateLock.unlock() }
            return failureHandler
        }
        set {
            publicStateLock.lock()
            failureHandler = newValue
            // Initialization failures are buffered until a handler exists, so
            // a nil handler at init time cannot swallow them.
            let pending = pendingFailures
            pendingFailures.removeAll()
            if let last = pending.last {
                lastReportedFailureKey = Self.failureKey(last)
            }
            publicStateLock.unlock()

            guard let newValue, !pending.isEmpty else { return }
            DispatchQueue.main.async {
                pending.forEach(newValue)
            }
        }
    }

    /// Called on the main queue the first time a decoded frame is committed to
    /// the drawable after `configure`. Re-armed by the next `configure`.
    var onFirstFrame: (() -> Void)? {
        get {
            publicStateLock.lock()
            defer { publicStateLock.unlock() }
            return firstFrameHandler
        }
        set {
            publicStateLock.lock()
            firstFrameHandler = newValue
            publicStateLock.unlock()
        }
    }

    /// False when this view cannot present anything on the current device
    /// (no CAMetalLayer, no Metal device or no command queue). Callers use it
    /// to pick a compatibility renderer synchronously, before the
    /// asynchronous failure handler would otherwise report the same problem.
    var isRendererUsable: Bool {
        publicStateLock.lock()
        defer { publicStateLock.unlock() }
        return rendererUsable
    }

    /// Frames actually committed to the drawable over the last half second.
    /// Thread-safe; 0 while nothing is being presented.
    var renderedFPS: Int {
        publicStateLock.lock()
        defer { publicStateLock.unlock() }
        return fpsValue
    }

    /// Called on the main queue when the decoder needs an IRAP (key) frame to
    /// resume. Coalesced: one request is outstanding until a key frame is
    /// accepted for decoding.
    var onNeedKeyFrame: (() -> Void)? {
        get {
            publicStateLock.lock()
            defer { publicStateLock.unlock() }
            return needKeyframeHandler
        }
        set {
            publicStateLock.lock()
            needKeyframeHandler = newValue
            publicStateLock.unlock()

            guard newValue != nil else { return }
            // A request made before a handler existed is retried here instead
            // of being lost forever (the host may be waiting for it).
            videoQueue.async { [weak self] in
                guard let self,
                      self.currentFormat != nil,
                      !self.formatRejected,
                      self.needKeyframe else { return }
                self.lastKeyFrameRequestTime = 0
                self.requestKeyFrameOnQueue()
            }
        }
    }

    /// Installs a new stream format. Safe to call from any thread; any decoder
    /// state from the previous format is torn down first. `generation` is the
    /// caller's token for this format; it is echoed in `Failure` so callbacks
    /// that belong to a replaced format can be ignored.
    ///
    /// Invalid metadata is reported as `.unrecoverable` and leaves the view
    /// waiting for a valid `configure`; it does not keep asking the host for
    /// key frames that no decoder could consume.
    func configure(_ format: VideoFormatMessage, generation: UInt64) {
        switch Self.parse(format) {
        case .failure(let error):
            // Anything still in flight belongs to the previous format.
            budget.invalidateAll()
            videoQueue.async { [weak self] in
                self?.rejectFormatOnQueue(generation: generation)
            }
            reportFailure(
                error.message,
                kind: .unrecoverable,
                generation: generation)
        case .success(let parsed):
            // Anything still in flight belongs to the previous format.
            budget.invalidateAll()
            checkHeadroom(for: parsed, generation: generation)
            videoQueue.async { [weak self] in
                self?.configureOnQueue(parsed, generation: generation)
            }
        }
    }

    /// Submits one access unit. `data` is a set of 4-byte length-prefixed HEVC
    /// NAL units (AVCC-style), exactly as carried by the wire protocol.
    ///
    /// The call never blocks. If the decoder/GPU already has the maximum
    /// number of frames in flight, the frame is dropped and a key frame is
    /// requested: silently dropping one P frame would corrupt the rest of the
    /// prediction chain.
    func enqueue(keyframe: Bool, timestampUs: UInt64, data: Data) {
        guard !data.isEmpty,
              data.count <= Limits.maxFrameBytes,
              timestampUs <= UInt64(Int64.max) else {
            videoQueue.async { [weak self] in
                guard let self else { return }
                self.consecutiveInvalidFrames += 1
                self.requestKeyFrameOnQueue()
                if self.consecutiveInvalidFrames >= Limits.maxConsecutiveInvalidFramesBeforeReporting {
                    self.reportFailure(
                        "Rejected an invalid video frame (\(data.count) bytes, timestamp \(timestampUs) us).",
                        generation: self.activeGeneration)
                }
            }
            return
        }

        guard let generation = budget.acquire() else {
            videoQueue.async { [weak self] in
                self?.requestKeyFrameOnQueue()
            }
            return
        }

        let frameContext = FrameContext(budget: budget, generation: generation)
        videoQueue.async { [weak self] in
            self?.processFrame(
                keyframe: keyframe,
                timestampUs: timestampUs,
                data: data,
                frameContext: frameContext)
        }
    }

    /// Tears down the decoder and waits for the next key frame. Call on
    /// disconnect, when the app goes to the background, or before changing the
    /// format. The last presented frame stays on screen (it is a valid image);
    /// the stream resumes only from a key frame.
    func reset() {
        budget.invalidateAll()
        videoQueue.async { [weak self] in
            self?.resetOnQueue()
        }
    }

    // MARK: - Limits and constants

    private enum Limits {
        /// Matches the wire protocol's 16 MiB frame ceiling.
        static let maxFrameBytes = 16 * 1024 * 1024
        /// Decode + render work allowed in flight. This is the only frame
        /// queue in the component; there is no unbounded buffering.
        static let maxInFlightFrames = 4
        static let maxDimension = 16384
        static let maxFPS = 240
        static let maxConsecutiveDecodeErrorsBeforeRebuild = 3
        static let maxConsecutiveInvalidFramesBeforeReporting = 3
        /// Minimum spacing between key-frame requests while no IRAP arrives.
        /// The iPad client throttles wire requests too; this keeps a stalled
        /// stream retrying without flooding the control channel.
        static let keyFrameRequestInterval: CFTimeInterval = 0.5
    }

    private static let videoQueueKey = DispatchSpecificKey<UInt8>()

    /// Working space of the CIContext, color space of the drawable and of the
    /// CAMetalLayer. EDR values above 1.0 are representable.
    private static let renderColorSpace: CGColorSpace = {
        if let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }()

    private static let renderColorSpaceSupportsEDR: Bool =
        CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) != nil

    // CoreVideo color constant strings. Using the constants avoids typos and
    // keeps the accepted vocabulary identical to what VideoToolbox emits.
    private static let primaries709 = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
    private static let primaries2020 = kCVImageBufferColorPrimaries_ITU_R_2020 as String
    private static let primariesP3D65 = kCVImageBufferColorPrimaries_P3_D65 as String

    private static let transfer709 = kCVImageBufferTransferFunction_ITU_R_709_2 as String
    private static let transfer2020 = kCVImageBufferTransferFunction_ITU_R_2020 as String
    private static let transferSRGB = kCVImageBufferTransferFunction_sRGB as String
    private static let transferLinear = kCVImageBufferTransferFunction_Linear as String
    private static let transferPQ = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
    private static let transferHLG = kCVImageBufferTransferFunction_ITU_R_2100_HLG as String

    private static let matrix709 = kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
    private static let matrix601 = kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
    private static let matrix240M = kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String
    private static let matrix2020 = kCVImageBufferYCbCrMatrix_ITU_R_2020 as String

    // MARK: - Public state (guarded by publicStateLock)

    private let publicStateLock = NSLock()
    private var failureHandler: ((Failure) -> Void)?
    private var needKeyframeHandler: (() -> Void)?
    private var firstFrameHandler: (() -> Void)?
    private var lastReportedFailureKey: String?
    private var pendingFailures: [Failure] = []
    private var drawablePixelSize = CGSize.zero
    private var rendererUsable = true
    private var fpsValue = 0

    // MARK: - Metal objects

    private let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    private var renderLayer: CAMetalLayer?

    // MARK: - Queues and backpressure

    private let videoQueue = DispatchQueue(label: "dev.xdrscreen.hdr.video", qos: .userInteractive)
    private let budget = InFlightBudget(limit: Limits.maxInFlightFrames)

    // MARK: - Decoder state (videoQueue only)

    private var session: VTDecompressionSession?
    private var sessionContext: Unmanaged<SessionContext>?
    private var formatDescription: CMFormatDescription?
    private var currentFormat: ParsedFormat?
    /// Generation of the format that owns the decoder state below. Echoed in
    /// failures so the caller can drop callbacks from an older format.
    private var activeGeneration: UInt64 = 0
    /// True while `currentFormat` cannot be decoded by this view (rejected
    /// metadata or decoder setup failure). Frame processing stops asking for
    /// key frames, so an unrenderable stream cannot spin the control channel.
    private var formatRejected = false
    private var needKeyframe = true
    /// Time of the last delivered key-frame request; rate-limits retries while
    /// no key frame arrives (for example when a requested IRAP is lost).
    private var lastKeyFrameRequestTime: CFTimeInterval = 0
    private var decoderEpoch: UInt64 = 0
    private var consecutiveDecodeErrors = 0
    private var consecutiveInvalidFrames = 0
    private var consecutiveDrawableFailures = 0
    private var didReportFirstFrame = false
    private var fpsFrameCounter = 0
    private var fpsWindowStart = CACurrentMediaTime()

    // MARK: - Lifecycle

    override class var layerClass: AnyClass { CAMetalLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if DispatchQueue.getSpecific(key: Self.videoQueueKey) != nil {
            tearDownDecoderOnQueue()
        } else {
            videoQueue.sync {
                tearDownDecoderOnQueue()
            }
        }
    }

    private func commonInit() {
        videoQueue.setSpecific(key: Self.videoQueueKey, value: 1)
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true

        guard let layer = self.layer as? CAMetalLayer else {
            markRendererUnusable()
            reportFailure(
                "HDRMetalVideoView requires a CAMetalLayer-backed view.",
                kind: .unrecoverable)
            return
        }
        renderLayer = layer
        layer.isOpaque = true
        layer.pixelFormat = .rgba16Float          // half float: > 1.0 and 10-bit precision
        // CIContext renders into its destination with a compute pipeline and
        // requires MTLTextureUsage.shaderWrite. With framebufferOnly = true the
        // drawable texture is renderTarget-only and Core Image silently writes
        // nothing (verified on the iOS simulator: all-zero readback).
        layer.framebufferOnly = false
        layer.maximumDrawableCount = 3            // bounded swap queue
        layer.allowsNextDrawableTimeout = true
        layer.colorspace = Self.renderColorSpace
        layer.wantsExtendedDynamicRangeContent = true   // iOS 16+
        layer.edrMetadata = nil
        layer.contentsScale = contentScaleFactor

        if let device = metalDevice {
            layer.device = device
            commandQueue = device.makeCommandQueue()
            ciContext = CIContext(mtlDevice: device, options: [
                .workingColorSpace: Self.renderColorSpace,
                .outputColorSpace: Self.renderColorSpace,
                // RGBAh is the default, but stating it prevents an accidental
                // 8-bit working format, which would silently break HDR.
                .workingFormat: CIFormat.RGBAh,
                .cacheIntermediates: false,
                .highQualityDownsample: true
            ])
            if commandQueue == nil {
                markRendererUnusable()
                reportFailure(
                    "Failed to create a Metal command queue.",
                    kind: .unrecoverable)
            }
        } else {
            markRendererUnusable()
            reportFailure(
                "Metal is not available on this device; video cannot be displayed.",
                kind: .unrecoverable)
        }

        if !Self.renderColorSpaceSupportsEDR {
            reportFailure("Extended linear Display P3 is unavailable; EDR presentation is disabled.")
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil)
    }

    @objc private func applicationDidEnterBackground() {
        reset()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableGeometry()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableGeometry()
    }

    private func updateDrawableGeometry() {
        guard let renderLayer else { return }
        let scale = max(1, contentScaleFactor)
        let isEmpty = bounds.width < 1 || bounds.height < 1
        let pixelWidth = min(max(1, (bounds.width * scale).rounded()), CGFloat(Limits.maxDimension))
        let pixelHeight = min(max(1, (bounds.height * scale).rounded()), CGFloat(Limits.maxDimension))
        let size = isEmpty ? .zero : CGSize(width: pixelWidth, height: pixelHeight)

        renderLayer.contentsScale = scale

        // drawableSize is only touched on the video queue, which also calls
        // nextDrawable(), so the swap queue is never reconfigured while a
        // drawable is being acquired.
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.publicStateLock.lock()
            self.drawablePixelSize = size
            self.publicStateLock.unlock()

            guard size.width >= 1, size.height >= 1, let layer = self.renderLayer else { return }
            if layer.drawableSize != size {
                layer.drawableSize = size
            }
        }
    }

    // MARK: - Format configuration

    /// Layer colour state follows the current format. Called on the video
    /// queue: `edrMetadata` must be set before `nextDrawable()`, and both
    /// happen on this serial queue, so a format change can never race a
    /// drawable acquisition.
    private func applyLayerColorConfigurationOnQueue() {
        guard let renderLayer else { return }
        renderLayer.colorspace = Self.renderColorSpace
        renderLayer.wantsExtendedDynamicRangeContent = true
        // No EDR metadata: Core Image has already produced display-referred
        // extended-linear values (see the header notes). Nil means "no tone
        // mapping", which keeps those values 1:1 up to the display headroom.
        renderLayer.edrMetadata = nil
    }

    /// `window`/`UIScreen` are main-thread API, so only the diagnostic runs
    /// there. It never gates setup: the stream is still decoded and presented.
    private func checkHeadroom(for format: ParsedFormat, generation: UInt64) {
        guard format.isHDR else { return }
        let check = { [weak self] in
            guard let self else { return }
            let screen = self.window?.screen ?? UIScreen.main
            let headroom = screen.potentialEDRHeadroom
            if headroom <= 1.0 {
                self.reportFailure(String(
                    format: "HDR stream requested, but this display reports potentialEDRHeadroom = %.2f; HDR highlights will be clipped to SDR.",
                    Double(headroom)),
                    generation: generation)
            }
        }
        if Thread.isMainThread {
            check()
        } else {
            DispatchQueue.main.async(execute: check)
        }
    }

    private func configureOnQueue(_ format: ParsedFormat, generation: UInt64) {
        activeGeneration = generation
        formatRejected = false
        tearDownDecoderOnQueue()
        currentFormat = format
        needKeyframe = true
        lastKeyFrameRequestTime = 0
        consecutiveDecodeErrors = 0
        consecutiveInvalidFrames = 0
        consecutiveDrawableFailures = 0
        didReportFirstFrame = false
        fpsFrameCounter = 0
        fpsWindowStart = CACurrentMediaTime()
        publicStateLock.lock()
        fpsValue = 0
        publicStateLock.unlock()
        applyLayerColorConfigurationOnQueue()
        setupDecoderOnQueue(format)
        // A fresh decoder has no reference frames, so the first frame must be
        // an IRAP. Ask the host immediately instead of waiting for a P frame
        // to be rejected.
        if session != nil {
            requestKeyFrameOnQueue()
        }
    }

    private func resetOnQueue() {
        tearDownDecoderOnQueue()
        currentFormat = nil
        activeGeneration = 0
        formatRejected = false
        needKeyframe = true
        lastKeyFrameRequestTime = 0
        consecutiveDecodeErrors = 0
        consecutiveInvalidFrames = 0
        consecutiveDrawableFailures = 0
        didReportFirstFrame = false
        fpsFrameCounter = 0
        fpsWindowStart = CACurrentMediaTime()
        publicStateLock.lock()
        fpsValue = 0
        publicStateLock.unlock()
        // The stream will only resume from an IRAP; request one so a
        // background/foreground cycle does not wait for the host's periodic
        // key-frame interval.
        requestKeyFrameOnQueue()
    }

    /// The metadata was rejected before any decoder existed. Tear down the
    /// previous format and stay quiet: no decoder can consume a key frame, so
    /// asking the host for one would just spin the control channel.
    private func rejectFormatOnQueue(generation: UInt64) {
        activeGeneration = generation
        tearDownDecoderOnQueue()
        currentFormat = nil
        formatRejected = true
        needKeyframe = true
        lastKeyFrameRequestTime = 0
        consecutiveDecodeErrors = 0
        consecutiveInvalidFrames = 0
        consecutiveDrawableFailures = 0
        didReportFirstFrame = false
        fpsFrameCounter = 0
        fpsWindowStart = CACurrentMediaTime()
        publicStateLock.lock()
        fpsValue = 0
        publicStateLock.unlock()
    }

    // MARK: - Decoder setup / teardown

    private func setupDecoderOnQueue(_ format: ParsedFormat) {
        needKeyframe = true

        let description: CMFormatDescription
        switch Self.makeFormatDescription(format) {
        case .failure(let error):
            markFormatRejected()
            reportFailure(error.message, kind: .unrecoverable, generation: activeGeneration)
            return
        case .success(let created):
            description = created
        }
        formatDescription = description

        let context = SessionContext(owner: self)
        let box = Unmanaged.passRetained(context)
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.decodeOutputCallback,
            decompressionOutputRefCon: box.toOpaque())

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: Self.decoderSpecification as CFDictionary,
            imageBufferAttributes: Self.pixelBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &newSession)

        guard status == noErr, let newSession else {
            box.release()
            formatDescription = nil
            markFormatRejected()
            reportFailure(
                "Failed to create a HEVC decoder (OSStatus \(status)). The stream profile, level or color configuration may be unsupported.",
                kind: .unrecoverable,
                generation: activeGeneration)
            return
        }

        if let usesHardware = Self.hardwareDecoderInUse(newSession), usesHardware == false {
            VTDecompressionSessionInvalidate(newSession)
            box.release()
            formatDescription = nil
            markFormatRejected()
            reportFailure(
                "VideoToolbox selected a software HEVC decoder; this view requires hardware decoding.",
                kind: .unrecoverable,
                generation: activeGeneration)
            return
        }

        session = newSession
        sessionContext = box
        formatRejected = false
    }

    /// Stops frame processing from requesting key frames for a format this
    /// view already proved it cannot decode.
    private func markFormatRejected() {
        formatRejected = true
        needKeyframe = true
    }

    private func tearDownDecoderOnQueue() {
        // Invalidates every FrameContext currently in flight: their callbacks
        // may still hop onto this queue, but they will be dropped.
        decoderEpoch &+= 1

        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil

        if let context = sessionContext {
            // Safe only after the asynchronous frames above have completed.
            context.release()
            sessionContext = nil
        }
        formatDescription = nil
    }

    private func rebuildDecoderOnQueue() {
        guard let format = currentFormat else { return }
        tearDownDecoderOnQueue()
        setupDecoderOnQueue(format)
        // A failed rebuild marks the format rejected; do not ask for frames
        // that no decoder can consume.
        if session != nil {
            requestKeyFrameOnQueue()
        }
    }

    private static var decoderSpecification: [String: Any] {
        // These keys are annotated iOS 17+ in the SDK, but the same CFString
        // values have been accepted by VideoToolbox since iOS 11. The literal
        // keeps iOS 16 support; when the SDK exposes the constant we use it.
        if #available(iOS 17.0, *) {
            return [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true]
        }
        return ["RequireHardwareAcceleratedVideoDecoder": true]
    }

    private static var pixelBufferAttributes: [String: Any] {
        [
            // 10-bit formats first: accepting 8-bit is only for SDR streams.
            // HDR output is verified to be 10-bit before it is presented.
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ],
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    private static func hardwareDecoderInUse(_ session: VTDecompressionSession) -> Bool? {
        let key: CFString
        if #available(iOS 17.0, *) {
            key = kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder
        } else {
            key = "UsingHardwareAcceleratedVideoDecoder" as CFString
        }
        // `VTSessionCopyProperty` returns a +1 reference through a raw
        // pointer. Model it as Unmanaged so ARC takes ownership exactly once
        // (passing `&CFTypeRef?` triggers a compiler warning for this reason).
        var value: Unmanaged<CFTypeRef>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            VTSessionCopyProperty(
                session,
                key: key,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer))
        }
        guard status == noErr, let value else { return nil }
        return (value.takeRetainedValue() as? NSNumber)?.boolValue
    }

    // MARK: - Frame processing

    private func processFrame(
        keyframe: Bool,
        timestampUs: UInt64,
        data: Data,
        frameContext: FrameContext
    ) {
        guard frameContext.generation == budget.currentGeneration else { return }

        guard let session,
              let formatDescription,
              let format = currentFormat else {
            requestKeyFrameOnQueue()
            return
        }

        // Frames submitted to the old decoder session must not be rendered.
        frameContext.decoderEpoch = decoderEpoch

        if needKeyframe {
            guard keyframe else {
                // A P frame cannot start a prediction chain.
                requestKeyFrameOnQueue()
                return
            }
        }

        guard Self.isValidLengthPrefixedHEVCFrame(data, requiresIRAP: keyframe) else {
            consecutiveInvalidFrames += 1
            requestKeyFrameOnQueue()
            if consecutiveInvalidFrames >= Limits.maxConsecutiveInvalidFramesBeforeReporting {
                reportFailure(
                    "Malformed HEVC frame: expected 4-byte length-prefixed NAL units.",
                    generation: activeGeneration)
            }
            return
        }
        consecutiveInvalidFrames = 0

        if keyframe {
            needKeyframe = false
        }

        guard let sampleBuffer = Self.makeSampleBuffer(
            data: data,
            formatDescription: formatDescription,
            timestampUs: timestampUs,
            fps: format.fps,
            keyframe: keyframe) else {
            requestKeyFrameOnQueue()
            reportFailure(
                "Failed to wrap an HEVC access unit in a CMSampleBuffer.",
                generation: activeGeneration)
            return
        }

        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        let retainedContext = Unmanaged.passRetained(frameContext)
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: flags,
            frameRefcon: retainedContext.toOpaque(),
            infoFlagsOut: nil)

        if status != noErr {
            // No callback will run for a frame rejected synchronously.
            retainedContext.release()
            consecutiveDecodeErrors += 1
            requestKeyFrameOnQueue()
            if status == kVTVideoDecoderMalfunctionErr || status == kVTVideoDecoderUnsupportedDataFormatErr {
                reportFailure(
                    "HEVC decoder rejected the stream (OSStatus \(status)); rebuilding the decoder.",
                    generation: activeGeneration)
                rebuildDecoderOnQueue()
            } else if consecutiveDecodeErrors >= Limits.maxConsecutiveDecodeErrorsBeforeRebuild {
                rebuildDecoderOnQueue()
            }
        }
    }

    private func requestKeyFrameOnQueue() {
        needKeyframe = true
        // A format this view rejected has no decoder that could consume an
        // IRAP. Dropping frames silently is the only correct behaviour; asking
        // the host again for every frame would spin the control channel.
        guard !formatRejected else { return }
        // Coalesce, but keep retrying while no key frame arrives: a request
        // can be lost (backgrounded network, dropped datagram), and the
        // decoder must not stay stuck on rejected P frames forever. The
        // client applies its own throttle, this is only a floor.
        let now = CACurrentMediaTime()
        guard now - lastKeyFrameRequestTime >= Limits.keyFrameRequestInterval else { return }
        // No handler yet: leave the timestamp alone so installing a handler
        // (see onNeedKeyFrame) or the next rejected frame retries immediately.
        guard let handler = currentNeedKeyframeHandler() else { return }
        lastKeyFrameRequestTime = now

        DispatchQueue.main.async {
            handler()
        }
    }

    private func currentNeedKeyframeHandler() -> (() -> Void)? {
        publicStateLock.lock()
        defer { publicStateLock.unlock() }
        return needKeyframeHandler
    }

    // MARK: - Decode output

    private static let decodeOutputCallback: VTDecompressionOutputCallback = {
        refcon, frameRefcon, status, infoFlags, imageBuffer, _, _ in
        guard let frameRefcon else { return }
        // Balances the passRetained in processFrame. The context releases its
        // in-flight slot when it deinits.
        let frameContext = Unmanaged<FrameContext>.fromOpaque(frameRefcon).takeRetainedValue()
        guard let refcon else { return }
        let sessionContext = Unmanaged<SessionContext>.fromOpaque(refcon).takeUnretainedValue()
        let result = DecodeResult(status: status, infoFlags: infoFlags, imageBuffer: imageBuffer)
        sessionContext.owner?.handleDecodedFrame(result, frameContext: frameContext)
    }

    private func handleDecodedFrame(_ result: DecodeResult, frameContext: FrameContext) {
        // The callback runs on VideoToolbox's queue; serializer work here.
        videoQueue.async { [weak self] in
            self?.deliver(result, frameContext: frameContext)
        }
    }

    private func deliver(_ result: DecodeResult, frameContext: FrameContext) {
        guard frameContext.generation == budget.currentGeneration,
              frameContext.decoderEpoch == decoderEpoch else {
            return
        }

        if result.status != noErr || result.infoFlags.contains(.frameDropped) {
            consecutiveDecodeErrors += 1
            requestKeyFrameOnQueue()
            let fatal = result.status == kVTVideoDecoderMalfunctionErr
                || result.status == kVTVideoDecoderUnsupportedDataFormatErr
            if fatal || consecutiveDecodeErrors >= Limits.maxConsecutiveDecodeErrorsBeforeRebuild {
                reportFailure(
                    "HEVC decode failed (OSStatus \(result.status)); rebuilding the decoder and requesting a key frame.",
                    generation: activeGeneration)
                rebuildDecoderOnQueue()
            }
            return
        }

        guard let pixelBuffer = result.imageBuffer else {
            consecutiveDecodeErrors += 1
            requestKeyFrameOnQueue()
            return
        }
        consecutiveDecodeErrors = 0

        guard let format = currentFormat else { return }

        // Never present 8-bit content as HDR.
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if format.isHDR && !Self.isTenBitPixelFormat(pixelFormat) {
            reportFailure(
                "Decoder produced \(Self.fourCC(pixelFormat)) instead of 10-bit 4:2:0; refusing to present it as HDR.",
                generation: activeGeneration)
            return
        }

        Self.attachColorMetadata(to: pixelBuffer, format: format)
        render(pixelBuffer, color: format.displayColor)
    }

    // MARK: - Rendering

    private func render(_ pixelBuffer: CVPixelBuffer, color: DisplayColor) {
        guard let renderLayer, let commandQueue, let ciContext else {
            // The Metal objects this view was built with are gone; no frame
            // will ever be presented here again.
            markRendererUnusable()
            reportFailure(
                "Metal rendering is unavailable.",
                kind: .unrecoverable,
                generation: activeGeneration)
            return
        }

        publicStateLock.lock()
        let expectedSize = drawablePixelSize
        publicStateLock.unlock()
        guard expectedSize.width >= 1, expectedSize.height >= 1 else { return }

        // Bounded: nextDrawable times out after about one second and returns
        // nil instead of enqueueing work without limit.
        guard let drawable = renderLayer.nextDrawable() else {
            consecutiveDrawableFailures += 1
            if consecutiveDrawableFailures == 3 {
                reportFailure(
                    "Unable to acquire a Metal drawable after repeated attempts; video frames are being dropped.",
                    generation: activeGeneration)
            }
            return
        }
        consecutiveDrawableFailures = 0

        let target = CGRect(
            x: 0,
            y: 0,
            width: drawable.texture.width,
            height: drawable.texture.height)
        guard target.width >= 1, target.height >= 1 else { return }

        // `color.colorSpace` is the sender's primaries + transfer function.
        // CoreImage converts to the CIContext working space (extended linear
        // Display P3) in half float; nothing is quantized to 8 bit.
        let source = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: color.colorSpace])
        let extent = source.extent
        guard !extent.isInfinite, !extent.isNull, !extent.isEmpty else { return }

        // Aspect fit, the Core Image -> Metal texture convention and the
        // top-to-bottom orientation correction live in one tested place.
        // `imageTransform` already ends with the vertical flip that cancels
        // Core Image writing logical y = 0 into texture row 0 (the top row of a
        // presented CAMetalLayer); without it the picture would be upside down.
        // `StreamOrientation.current` then flips the frame top-to-bottom
        // relative to the previous output, based on real device feedback; the
        // exact cause is still to be verified. See
        // VideoPresentationGeometry.swift.
        guard let layout = VideoFrameLayout(
            sourceExtent: extent,
            drawableSize: CGSize(width: target.width, height: target.height)) else {
            return
        }
        let background = CIImage(color: CIColor.black).cropped(to: target)
        let composed = source.transformed(by: layout.imageTransform)
            .composited(over: background)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            reportFailure(
                "Failed to create a Metal command buffer.",
                generation: activeGeneration)
            return
        }

        ciContext.render(
            composed,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: target,
            colorSpace: Self.renderColorSpace)

        // The decoded IOSurface-backed buffer must outlive the GPU read.
        commandBuffer.addCompletedHandler { [weak self] buffer in
            withExtendedLifetime(pixelBuffer) {}
            if buffer.status == .error {
                self?.reportFailure("Metal command buffer failed while presenting a video frame.")
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        fpsFrameCounter += 1
        let now = CACurrentMediaTime()
        let elapsed = now - fpsWindowStart
        if elapsed >= 0.5 {
            let fps = Int((Double(fpsFrameCounter) / elapsed).rounded())
            fpsFrameCounter = 0
            fpsWindowStart = now
            publicStateLock.lock()
            fpsValue = fps
            publicStateLock.unlock()
        }

        if !didReportFirstFrame {
            didReportFirstFrame = true
            if let handler = currentFirstFrameHandler() {
                DispatchQueue.main.async {
                    handler()
                }
            }
        }
    }

    // MARK: - Failure reporting

    private func markRendererUnusable() {
        publicStateLock.lock()
        rendererUsable = false
        publicStateLock.unlock()
    }

    private func currentFirstFrameHandler() -> (() -> Void)? {
        publicStateLock.lock()
        defer { publicStateLock.unlock() }
        return firstFrameHandler
    }

    /// Identity used for duplicate suppression. The generation is part of the
    /// key: the same complaint about a new format generation is a new failure
    /// and must still reach the caller (otherwise a reconnect to the same
    /// unsupported stream would never fall back).
    private static func failureKey(_ failure: Failure) -> String {
        let generation = failure.formatGeneration.map(String.init) ?? "-"
        return "\(generation)|\(failure.message)"
    }

    private func reportFailure(
        _ message: String,
        kind: FailureKind = .recoverable,
        generation: UInt64? = nil
    ) {
        // Generation 0 means "no configure has happened"; model it as a
        // device-level failure so the caller's own token check applies.
        let failure = Failure(
            kind: kind,
            message: message,
            formatGeneration: (generation ?? 0) == 0 ? nil : generation)
        let key = Self.failureKey(failure)

        publicStateLock.lock()
        guard let handler = failureHandler else {
            if !pendingFailures.contains(where: { Self.failureKey($0) == key }),
               pendingFailures.count < 8 {
                pendingFailures.append(failure)
            }
            publicStateLock.unlock()
            return
        }
        if lastReportedFailureKey == key {
            publicStateLock.unlock()
            return
        }
        lastReportedFailureKey = key
        publicStateLock.unlock()

        DispatchQueue.main.async {
            handler(failure)
        }
    }

    // MARK: - Color metadata

    private struct DisplayColor {
        let colorSpace: CGColorSpace
        let primaries: String
        let transfer: String
        let matrix: String
    }

    private struct FormatError: Error, ExpressibleByStringInterpolation {
        let message: String
        init(stringLiteral value: String) {
            message = value
        }
        init(stringInterpolation: DefaultStringInterpolation) {
            message = String(stringInterpolation: stringInterpolation)
        }
    }

    private struct ParsedFormat {
        let width: Int
        let height: Int
        let fps: Int
        let isHDR: Bool
        let vps: Data
        let sps: Data
        let pps: Data
        let primaries: String
        let transfer: String
        let matrix: String
        let displayColor: DisplayColor
    }

    private static func parse(_ format: VideoFormatMessage) -> Result<ParsedFormat, FormatError> {
        guard (1...Limits.maxDimension).contains(format.width),
              (1...Limits.maxDimension).contains(format.height) else {
            return .failure("Invalid video dimensions \(format.width)x\(format.height).")
        }
        guard (1...Limits.maxFPS).contains(format.fps) else {
            return .failure("Invalid frame rate \(format.fps) fps.")
        }

        guard let vps = normalizeParameterSet(format.vps, expectedNALType: 32) else {
            return .failure("VPS is not a valid HEVC video parameter set NAL unit.")
        }
        guard let sps = normalizeParameterSet(format.sps, expectedNALType: 33) else {
            return .failure("SPS is not a valid HEVC sequence parameter set NAL unit.")
        }
        guard let pps = normalizeParameterSet(format.pps, expectedNALType: 34) else {
            return .failure("PPS is not a valid HEVC picture parameter set NAL unit.")
        }

        let primaries = format.colorPrimaries
        let transfer = format.transferFunction
        let matrix = format.yCbCrMatrix

        guard [matrix709, matrix601, matrix240M, matrix2020].contains(matrix) else {
            return .failure("Unsupported YCbCr matrix '\(matrix)'.")
        }

        let isHDRTransfer = transfer == transferHLG || transfer == transferPQ
        if format.hdr, !isHDRTransfer {
            return .failure("hdr is true but transfer function '\(transfer)' is not HLG or PQ; refusing to guess HDR.")
        }
        if !format.hdr, isHDRTransfer {
            return .failure("Transfer function '\(transfer)' is HDR but hdr is false; inconsistent color metadata.")
        }

        let colorSpace: CGColorSpace

        if format.hdr {
            switch (primaries, transfer) {
            case (primaries2020, transferHLG):
                guard let space = makeColorSpace(CGColorSpace.itur_2100_HLG) else {
                    return .failure("This system cannot represent BT.2100 HLG color.")
                }
                colorSpace = space
            case (primaries2020, transferPQ):
                guard let space = makeColorSpace(CGColorSpace.itur_2100_PQ) else {
                    return .failure("This system cannot represent BT.2100 PQ color.")
                }
                colorSpace = space
            case (primariesP3D65, transferHLG):
                guard let space = makeColorSpace(CGColorSpace.displayP3_HLG) else {
                    return .failure("This system cannot represent Display P3 HLG color.")
                }
                colorSpace = space
            case (primariesP3D65, transferPQ):
                guard let space = makeColorSpace(CGColorSpace.displayP3_PQ) else {
                    return .failure("This system cannot represent Display P3 PQ color.")
                }
                colorSpace = space
            default:
                return .failure("Unsupported HDR color metadata: primaries '\(primaries)', transfer '\(transfer)'.")
            }
        } else {
            let name: CFString?
            switch (primaries, transfer) {
            case (primaries709, transfer709):
                name = CGColorSpace.itur_709
            case (primaries2020, transfer709), (primaries2020, transfer2020):
                name = CGColorSpace.itur_2020
            case (primaries709, transferSRGB):
                name = CGColorSpace.sRGB
            case (primaries2020, transferSRGB):
                name = CGColorSpace.itur_2020_sRGBGamma
            // ScreenCaptureKit can tag an SDR capture of a P3 display with
            // Display P3 primaries. `displayP3` is the only system space with
            // those primaries; Core Image then converts to the render space.
            case (primariesP3D65, transfer709), (primariesP3D65, transferSRGB):
                name = CGColorSpace.displayP3
            case (primaries709, transferLinear):
                name = CGColorSpace.extendedLinearSRGB
            case (primaries2020, transferLinear):
                name = CGColorSpace.extendedLinearITUR_2020
            default:
                return .failure("Unsupported SDR color metadata: primaries '\(primaries)', transfer '\(transfer)'.")
            }
            guard let name, let space = makeColorSpace(name) else {
                return .failure("This system cannot represent the requested SDR color space.")
            }
            colorSpace = space
        }

        let displayColor = DisplayColor(
            colorSpace: colorSpace,
            primaries: primaries,
            transfer: transfer,
            matrix: matrix)

        return .success(ParsedFormat(
            width: format.width,
            height: format.height,
            fps: format.fps,
            isHDR: format.hdr,
            vps: vps,
            sps: sps,
            pps: pps,
            primaries: primaries,
            transfer: transfer,
            matrix: matrix,
            displayColor: displayColor))
    }

    private static func makeColorSpace(_ name: CFString) -> CGColorSpace? {
        CGColorSpace(name: name)
    }

    /// Accepts a raw NAL unit, or Annex-B with a 3/4-byte start code, and
    /// strips trailing zero bytes. Returns nil when the NAL type is wrong.
    private static func normalizeParameterSet(_ data: Data, expectedNALType: UInt8) -> Data? {
        var bytes = [UInt8](data)
        if bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 1 {
            bytes.removeFirst(4)
        } else if bytes.count >= 3, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1 {
            bytes.removeFirst(3)
        }
        while let last = bytes.last, last == 0 {
            bytes.removeLast()
        }
        guard bytes.count >= 3 else { return nil }
        guard bytes[0] & 0x80 == 0 else { return nil }   // forbidden_zero_bit
        let nalType = (bytes[0] >> 1) & 0x3F
        guard nalType == expectedNALType else { return nil }
        return Data(bytes)
    }

    /// Walks the AVCC-style 4-byte length prefixes. Also verifies that a frame
    /// the sender calls a key frame really contains an IRAP NAL unit.
    private static func isValidLengthPrefixedHEVCFrame(_ data: Data, requiresIRAP: Bool) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let count = raw.count
            var offset = 0
            var sawIRAP = false

            while offset < count {
                guard count - offset >= 4 else { return false }
                let length = (Int(base[offset]) << 24)
                    | (Int(base[offset + 1]) << 16)
                    | (Int(base[offset + 2]) << 8)
                    | Int(base[offset + 3])
                offset += 4
                guard length >= 2, length <= count - offset else { return false }
                let nalType = (Int(base[offset]) >> 1) & 0x3F
                // BLA_W_LP (16) ... RSV_IRAP_VCL23 (23)
                if (16...23).contains(nalType) {
                    sawIRAP = true
                }
                offset += length
            }

            return offset == count && (!requiresIRAP || sawIRAP)
        }
    }

    private static func isTenBitPixelFormat(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    private static func fourCC(_ value: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", value)
    }

    // MARK: - Format description and sample buffers

    private static func makeFormatDescription(_ format: ParsedFormat) -> Result<CMFormatDescription, FormatError> {
        // The sender's color metadata is forwarded verbatim: the extensions
        // are the contract, and no value is inferred from the bitstream.
        let extensions: [String: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries as String: format.primaries,
            kCMFormatDescriptionExtension_TransferFunction as String: format.transfer,
            kCMFormatDescriptionExtension_YCbCrMatrix as String: format.matrix
        ]

        var description: CMFormatDescription?
        let status: OSStatus = format.vps.withUnsafeBytes { vpsRaw in
            format.sps.withUnsafeBytes { spsRaw in
                format.pps.withUnsafeBytes { ppsRaw in
                    guard let vpsBase = vpsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let spsBase = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsBase = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return OSStatus(-1)
                    }
                    var pointers: [UnsafePointer<UInt8>] = [vpsBase, spsBase, ppsBase]
                    var sizes: [Int] = [format.vps.count, format.sps.count, format.pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: extensions as CFDictionary,
                        formatDescriptionOut: &description)
                }
            }
        }

        guard status == noErr, let description else {
            return .failure("Failed to create a CMVideoFormatDescription from VPS/SPS/PPS (OSStatus \(status)).")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0,
              dimensions.height > 0,
              dimensions.width <= Int32(Limits.maxDimension),
              dimensions.height <= Int32(Limits.maxDimension) else {
            return .failure("The SPS reports invalid dimensions \(dimensions.width)x\(dimensions.height).")
        }
        // Note: the SPS dimensions are authoritative; format.width/height are
        // only sanity checked. Rendering uses the decoded buffer's extent.
        return .success(description)
    }

    private static func makeSampleBuffer(
        data: Data,
        formatDescription: CMFormatDescription,
        timestampUs: UInt64,
        fps: Int,
        keyframe: Bool
    ) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer)
        guard createStatus == noErr, let blockBuffer else { return nil }

        let copyStatus: OSStatus = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count)
        }
        guard copyStatus == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(max(1, fps))),
            presentationTimeStamp: CMTime(value: Int64(timestampUs), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?

        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        setSyncAttachment(on: sampleBuffer, isSync: keyframe)
        return sampleBuffer
    }

    private static func setSyncAttachment(on sampleBuffer: CMSampleBuffer, isSync: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0,
              let raw = CFArrayGetValueAtIndex(attachments, 0) else {
            return
        }
        let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
        let value: CFBoolean = isSync ? kCFBooleanFalse : kCFBooleanTrue
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
            Unmanaged.passUnretained(value).toOpaque())
    }

    private static func attachColorMetadata(to pixelBuffer: CVPixelBuffer, format: ParsedFormat) {
        let color = format.displayColor
        // Overwriting with the validated sender metadata keeps CoreImage's
        // YCbCr conversion consistent with the format description.
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            color.primaries as CFString,
            .shouldPropagate)
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            color.transfer as CFString,
            .shouldPropagate)
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            color.matrix as CFString,
            .shouldPropagate)
    }

    // MARK: - Internal types

    private struct DecodeResult {
        let status: OSStatus
        let infoFlags: VTDecodeInfoFlags
        let imageBuffer: CVImageBuffer?
    }

    /// Kept alive by the VTDecompressionSession's output refcon; holds only a
    /// weak reference so a deallocating view can never be resurrected.
    private final class SessionContext {
        weak var owner: HDRMetalVideoView?
        init(owner: HDRMetalVideoView) {
            self.owner = owner
        }
    }

    /// One budget slot. Released exactly when the frame has been delivered or
    /// dropped, including when VideoToolbox reports an error.
    private final class FrameContext {
        let generation: UInt64
        var decoderEpoch: UInt64 = 0
        private weak var budget: InFlightBudget?

        init(budget: InFlightBudget, generation: UInt64) {
            self.budget = budget
            self.generation = generation
        }

        deinit {
            budget?.release(generation)
        }
    }

    /// Bound on frames submitted to the decoder but not yet delivered. This is
    /// the component's only queue, so memory cannot grow without limit.
    private final class InFlightBudget {
        private let lock = NSLock()
        private var generation: UInt64 = 1
        private var inFlight = 0
        private let limit: Int

        init(limit: Int) {
            self.limit = limit
        }

        var currentGeneration: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return generation
        }

        func acquire() -> UInt64? {
            lock.lock()
            defer { lock.unlock() }
            guard inFlight < limit else { return nil }
            inFlight += 1
            return generation
        }

        func release(_ generation: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            guard generation == self.generation else { return }
            if inFlight > 0 {
                inFlight -= 1
            }
        }

        /// Drops every in-flight slot of the previous generation.
        func invalidateAll() {
            lock.lock()
            generation &+= 1
            inFlight = 0
            lock.unlock()
        }
    }
}
