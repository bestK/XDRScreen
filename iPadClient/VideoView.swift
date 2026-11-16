//
//  VideoView.swift
//  XDRScreen (iPad client)
//
//  Renders the Mac's HEVC stream with AVSampleBufferDisplayLayer. The layer
//  uses the system HEVC hardware decoder; no CPU colour conversion happens
//  here. Colour primaries, transfer function and YCbCr matrix travel from the
//  Mac in VideoFormatMessage and are attached to the format description so
//  HDR content is presented as HDR when the display can do it, and honestly
//  labelled SDR when it cannot.
//

import AVFoundation
import CoreMedia
import Metal
import UIKit

/// Single source of truth for HDR presentation capability on this device.
/// Must be queried from the main queue (it reads UIKit screen state).
///
/// HDR is only advertised when the *renderer* can actually present it: the
/// HDRMetalVideoView path needs a Metal device and extended linear Display P3
/// in addition to an EDR-capable screen. Advertising HDR while falling back to
/// an SDR decoder would mislabel the stream in the host's Hello negotiation.
enum DisplayHDRSupport {
    private static let metalPipelineAvailable: Bool = {
        guard MTLCreateSystemDefaultDevice() != nil else { return false }
        return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) != nil
    }()

    static var isSupported: Bool {
        guard AVPlayer.eligibleForHDRPlayback, metalPipelineAvailable else { return false }
        return UIScreen.main.potentialEDRHeadroom > 1.0
    }

    static var potentialHeadroom: CGFloat {
        UIScreen.main.potentialEDRHeadroom
    }

    static var currentHeadroom: CGFloat {
        UIScreen.main.currentEDRHeadroom
    }
}

final class VideoDisplayView: UIView {

    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    private var displayLayer: AVSampleBufferDisplayLayer {
        // `layerClass` guarantees the type.
        layer as! AVSampleBufferDisplayLayer
    }

    // MARK: Outputs

    /// Called on the main queue when the decoder needs an IDR (backpressure,
    /// flush, format change or decode failure).
    var onNeedKeyframe: (() -> Void)?
    /// Called once per connection when the first sample is handed to the layer.
    var onFirstFrame: (() -> Void)?
    /// Human readable decode trouble, throttled by the recovery logic.
    var onRenderFailure: ((String) -> Void)?

    // MARK: State (main queue)

    /// Same bound as the Metal pipeline. No display this client can present is
    /// anywhere near it, and a larger frame cannot be decoded usefully.
    private static let maxDimension: CGFloat = 16384

    private var formatDescription: CMFormatDescription?
    private var format: VideoFormatMessage?
    private(set) var videoSize: CGSize = .zero
    private var awaitingKeyframe = true
    private var timestampOriginUs: UInt64?
    private var didReportFirstFrame = false
    private var lastRecoveryAt = Date.distantPast
    private var dropWindowStart: Date?
    private var consecutiveDrops = 0
    private var didReportSampleFailure = false

    private var frameCounter = 0
    private var fpsWindowStart = Date()
    private(set) var renderedFPS = 0

    private var failedDecodeObserver: NSObjectProtocol?

    // MARK: Backpressure (any queue)

    private let pendingLock = NSLock()
    private var pendingRenderCount = 0
    private static let maxPendingRenders = 3

    private let requestLock = NSLock()
    private var lastKeyframeRequestAt = Date.distantPast

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = false
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        failedDecodeObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferDisplayLayerFailedToDecode,
            object: displayLayer,
            queue: .main
        ) { [weak self] note in
            guard let self, self.format != nil else { return }
            var detail = "视频解码失败"
            if let error = note.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey as String] as? Error {
                detail += "（\(error.localizedDescription)）"
            }
            self.recoverDisplayLayer(detail + "，正在恢复…")
        }
    }

    deinit {
        if let failedDecodeObserver {
            NotificationCenter.default.removeObserver(failedDecodeObserver)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    /// The rect the video actually occupies inside this view (videoGravity is
    /// resizeAspect). Touch mapping uses this so letterboxed taps are ignored.
    var playbackRect: CGRect {
        AspectFit.rect(for: videoSize, in: bounds)
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
        guard let description = Self.makeFormatDescription(message) else {
            onRenderFailure?("无法根据 VPS/SPS/PPS 创建 HEVC 解码格式。")
            return false
        }

        formatDescription = description
        format = message
        // Match the size AVSampleBufferDisplayLayer actually presents, including
        // pixel aspect ratio and clean aperture, so the aspect-fit touch rect is
        // exact instead of being a few pixels off.
        let presented = CMVideoFormatDescriptionGetPresentationDimensions(
            description,
            usePixelAspectRatio: true,
            useCleanAperture: true
        )
        let displayed = presented.width > 1 && presented.height > 1
            ? presented
            : CGSize(width: message.width, height: message.height)
        // A size the system decoder cannot possibly render is rejected here
        // instead of failing asynchronously for every frame, so the caller can
        // stop cleanly rather than retrying forever.
        guard displayed.width <= Self.maxDimension,
              displayed.height <= Self.maxDimension else {
            formatDescription = nil
            format = nil
            onRenderFailure?("视频尺寸 \(Int(displayed.width))×\(Int(displayed.height)) 超出本机解码器支持范围。")
            return false
        }
        videoSize = displayed
        awaitingKeyframe = true
        timestampOriginUs = nil
        didReportSampleFailure = false
        dropWindowStart = nil
        consecutiveDrops = 0
        lastRecoveryAt = .distantPast
        renderedFPS = 0
        frameCounter = 0
        fpsWindowStart = Date()

        displayLayer.flushAndRemoveImage()
        applyEDRPreference(for: message)
        setNeedsLayout()
        return true
    }

    /// Called when the connection ends: never leave the last remote frame on
    /// screen while the UI claims to be disconnected.
    func resetForDisconnect() {
        formatDescription = nil
        format = nil
        videoSize = .zero
        awaitingKeyframe = true
        timestampOriginUs = nil
        didReportFirstFrame = false
        didReportSampleFailure = false
        dropWindowStart = nil
        consecutiveDrops = 0
        renderedFPS = 0
        frameCounter = 0
        fpsWindowStart = Date()
        displayLayer.flushAndRemoveImage()
        if #available(iOS 17.0, *) {
            displayLayer.wantsExtendedDynamicRangeContent = false
        }
        setNeedsLayout()
    }

    private func applyEDRPreference(for message: VideoFormatMessage) {
        let wantsHDR = message.hdr && DisplayHDRSupport.isSupported
        if #available(iOS 17.0, *) {
            displayLayer.wantsExtendedDynamicRangeContent = wantsHDR
        }
    }

    // MARK: - Frames (any queue entry point)

    /// Thread-safe: bounds how many frames can wait for the main queue so a
    /// stalled UI can never build an unbounded video backlog.
    func submitFrame(payload: Data) {
        pendingLock.lock()
        if pendingRenderCount >= Self.maxPendingRenders {
            pendingLock.unlock()
            requestKeyframeThrottled()
            return
        }
        pendingRenderCount += 1
        pendingLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            if self.pendingRenderCount > 0 { self.pendingRenderCount -= 1 }
            self.pendingLock.unlock()
            self.render(payload)
        }
    }

    private func render(_ payload: Data) {
        guard let formatDescription, let format else { return }
        guard let decoded = VideoFramePayload.decode(payload) else {
            reportSampleFailureOnce("收到损坏的视频帧。")
            return
        }
        guard !decoded.data.isEmpty, decoded.data.count <= Wire.maxFrameBytes else {
            reportSampleFailureOnce("视频帧长度异常。")
            return
        }

        if displayLayer.requiresFlushToResumeDecoding {
            recoverDisplayLayer("视频解码器需要刷新，正在恢复…")
            return
        }

        if displayLayer.status == .failed {
            recoverDisplayLayer("视频解码器需要重启，正在恢复…")
            return
        }

        if awaitingKeyframe {
            guard decoded.keyframe else {
                // A P frame cannot start a prediction chain. Ask for an IDR
                // instead of silently waiting for the host's periodic key
                // frame, which may never arrive while the Mac screen is still.
                requestKeyframeThrottled()
                return
            }
        }

        guard displayLayer.isReadyForMoreMediaData else {
            noteBackpressureDrop()
            return
        }

        guard let sampleBuffer = makeSampleBuffer(
            decoded,
            formatDescription: formatDescription,
            fps: format.fps
        ) else {
            reportSampleFailureOnce("无法创建视频样本。")
            return
        }

        if awaitingKeyframe {
            awaitingKeyframe = false
            timestampOriginUs = decoded.timestampUs
        }

        displayLayer.enqueue(sampleBuffer)
        consecutiveDrops = 0
        dropWindowStart = nil

        frameCounter += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(fpsWindowStart)
        if elapsed >= 0.5 {
            renderedFPS = Int((Double(frameCounter) / elapsed).rounded())
            frameCounter = 0
            fpsWindowStart = now
        }

        if !didReportFirstFrame {
            didReportFirstFrame = true
            onFirstFrame?()
        }
    }

    private func noteBackpressureDrop() {
        let now = Date()
        if dropWindowStart == nil { dropWindowStart = now }
        consecutiveDrops += 1
        let sustained = consecutiveDrops >= 3
            || (dropWindowStart.map { now.timeIntervalSince($0) > 0.4 } ?? false)
        guard sustained else { return }
        dropWindowStart = nil
        consecutiveDrops = 0
        guard now.timeIntervalSince(lastRecoveryAt) > 0.8 else { return }
        lastRecoveryAt = now
        // Drop queued frames so latency does not grow, then wait for a clean IDR.
        displayLayer.flush()
        awaitingKeyframe = true
        timestampOriginUs = nil
        requestKeyframeThrottled()
    }

    private func recoverDisplayLayer(_ message: String) {
        let now = Date()
        guard now.timeIntervalSince(lastRecoveryAt) > 0.8 else { return }
        lastRecoveryAt = now
        displayLayer.flush()
        awaitingKeyframe = true
        timestampOriginUs = nil
        onRenderFailure?(message)
    }

    private func reportSampleFailureOnce(_ message: String) {
        guard !didReportSampleFailure else { return }
        didReportSampleFailure = true
        onRenderFailure?(message)
    }

    private func requestKeyframeThrottled() {
        requestLock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastKeyframeRequestAt) > 0.5 else {
            requestLock.unlock()
            return
        }
        lastKeyframeRequestAt = now
        requestLock.unlock()

        if Thread.isMainThread {
            onNeedKeyframe?()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onNeedKeyframe?()
            }
        }
    }

    // MARK: - Sample buffer

    private func makeSampleBuffer(
        _ decoded: (keyframe: Bool, timestampUs: UInt64, data: Data),
        formatDescription: CMFormatDescription,
        fps: Int
    ) -> CMSampleBuffer? {
        let data = decoded.data
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus: OSStatus = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        if timestampOriginUs == nil {
            timestampOriginUs = decoded.timestampUs
        }
        var origin = timestampOriginUs ?? decoded.timestampUs
        if decoded.timestampUs < origin {
            origin = decoded.timestampUs
            timestampOriginUs = origin
        }
        let delta = decoded.timestampUs - origin

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(max(fps, 1))),
            presentationTimeStamp: CMTime(value: CMTimeValue(delta), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return nil }

        if !decoded.keyframe {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_NotSync,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        // Display as soon as the decoder has the picture instead of scheduling
        // on a wall clock the Mac and iPad do not share.
        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        return sampleBuffer
    }

    // MARK: - Format description

    private static func makeFormatDescription(_ message: VideoFormatMessage) -> CMFormatDescription? {
        let vps = message.vps
        let sps = message.sps
        let pps = message.pps
        guard !vps.isEmpty, !sps.isEmpty, !pps.isEmpty else { return nil }

        var extensions: [String: Any] = [:]
        if let primaries = normalizedColorValue(message.colorPrimaries, aliases: primariesAliases) {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = primaries
        }
        if let transfer = normalizedColorValue(message.transferFunction, aliases: transferAliases) {
            extensions[kCMFormatDescriptionExtension_TransferFunction as String] = transfer
        }
        if let matrix = normalizedColorValue(message.yCbCrMatrix, aliases: matrixAliases) {
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = matrix
        }

        return vps.withUnsafeBytes { vpsRaw -> CMFormatDescription? in
            guard let vpsBase = vpsRaw.baseAddress else { return nil }
            return sps.withUnsafeBytes { spsRaw -> CMFormatDescription? in
                guard let spsBase = spsRaw.baseAddress else { return nil }
                return pps.withUnsafeBytes { ppsRaw -> CMFormatDescription? in
                    guard let ppsBase = ppsRaw.baseAddress else { return nil }
                    var pointers: [UnsafePointer<UInt8>] = [
                        vpsBase.assumingMemoryBound(to: UInt8.self),
                        spsBase.assumingMemoryBound(to: UInt8.self),
                        ppsBase.assumingMemoryBound(to: UInt8.self)
                    ]
                    var sizes: [Int] = [vps.count, sps.count, pps.count]
                    var description: CMFormatDescription?
                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: extensions.isEmpty ? nil : (extensions as CFDictionary),
                        formatDescriptionOut: &description
                    )
                    return status == noErr ? description : nil
                }
            }
        }
    }

    private static let primariesAliases: [String: String] = [
        "BT709": "ITU_R_709_2",
        "REC709": "ITU_R_709_2",
        "REC_709": "ITU_R_709_2",
        "BT2020": "ITU_R_2020",
        "REC2020": "ITU_R_2020",
        "REC_2020": "ITU_R_2020",
        "P3": "P3_D65"
    ]

    private static let transferAliases: [String: String] = [
        "BT709": "ITU_R_709_2",
        "REC709": "ITU_R_709_2",
        "BT2020": "ITU_R_2020",
        "SMPTE2084": "SMPTE_ST_2084_PQ",
        "SMPTE_ST_2084": "SMPTE_ST_2084_PQ",
        "PQ": "SMPTE_ST_2084_PQ",
        "HLG": "ITU_R_2100_HLG",
        "ARIB_STD_B67": "ITU_R_2100_HLG"
    ]

    private static let matrixAliases: [String: String] = [
        "BT709": "ITU_R_709_2",
        "REC709": "ITU_R_709_2",
        "BT601": "ITU_R_601_4",
        "BT601_4": "ITU_R_601_4",
        "BT2020": "ITU_R_2020",
        "BT2020_NCL": "ITU_R_2020",
        "BT2020_CL": "ITU_R_2020"
    ]

    /// CoreVideo and CoreMedia share the same colour strings. Map only common
    /// aliases; otherwise pass the Mac's value through unchanged instead of
    /// inventing metadata.
    private static func normalizedColorValue(_ raw: String, aliases: [String: String]) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let mapped = aliases[trimmed.uppercased()] {
            return mapped
        }
        return trimmed
    }
}
