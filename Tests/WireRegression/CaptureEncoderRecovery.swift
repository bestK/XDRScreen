//
//  CaptureEncoderRecovery.swift
//  WireRegression
//
//  Regression suite for the capture encoder's keyframe-recovery bookkeeping.
//  Only the pure state machines compiled from MacHost/CaptureEncoder.swift are
//  exercised: no SCStream, no VideoToolbox session, no display and no screen
//  recording permission is involved, so this runs headless.
//
//    * a keyframe request with a cached frame and a ready encoder produces
//      exactly one forced encode even if the screen never delivers another
//      image,
//    * a request without a cache / encoder / under backpressure stays pending
//      instead of being consumed,
//    * repeated requests while one cached-frame encode is in flight never
//      accumulate work, and requests arriving inside the coalescing window
//      wait instead of hammering VideoToolbox,
//    * teardown drops the cached frame and in-flight slot but keeps the
//      client's request so the next generation starts with an IDR,
//    * cached-frame presentation times are valid and strictly increasing,
//    * an unexpectedly stopped stream restarts in HDR only when the target
//      display, client capability and session history allow it, and otherwise
//      degrades to SDR with a concrete reason.
//

import CoreMedia
import Foundation
@testable import XDRScreenCapture

// MARK: - Keyframe scheduling

private func testKeyframeScheduling(_ report: Report) {
    // Nothing requested: even a warm cache and idle encoder does nothing.
    var idle = KeyframeRecoveryState()
    idle.cacheFrame()
    report.equal(idle.decision(active: true, hasEncoder: true, congested: false),
                 .noRequest,
                 "an unrequested keyframe schedules no encode")

    // A request before the first sample cannot be answered yet, but it is not
    // consumed: this is the "stream started on a static screen" case.
    var coldStart = KeyframeRecoveryState()
    coldStart.recordKeyframeRequest()
    report.equal(coldStart.decision(active: true, hasEncoder: false, congested: false),
                 .encoderNotReady,
                 "a request before the VT session exists stays pending")
    report.check(coldStart.hasOutstandingRequest,
                 "a request without an encoder is preserved")
    report.equal(coldStart.decision(active: true, hasEncoder: true, congested: false),
                 .noCachedFrame,
                 "a ready encoder without a cached frame still cannot answer")
    coldStart.cacheFrame()
    report.equal(coldStart.decision(active: true, hasEncoder: true, congested: false),
                 .encode,
                 "the first cached frame answers the preserved request")
    report.equal(coldStart.decision(active: false, hasEncoder: true, congested: false),
                 .inactive,
                 "a stopped capture never fabricates a frame")

    // Backpressure defers, it does not drop the request.
    var congested = KeyframeRecoveryState()
    congested.recordKeyframeRequest()
    congested.cacheFrame()
    report.equal(congested.decision(active: true, hasEncoder: true, congested: true),
                 .backpressure,
                 "a congested link defers the cached-frame IDR")
    report.check(congested.hasOutstandingRequest,
                 "backpressure does not consume the request")
    report.equal(congested.decision(active: true, hasEncoder: true, congested: false),
                 .encode,
                 "the request lands as soon as the backlog clears")

    // One in-flight cached-frame encode is the concurrency bound.
    var bounded = KeyframeRecoveryState()
    bounded.recordKeyframeRequest()
    bounded.cacheFrame()
    report.equal(bounded.decision(active: true, hasEncoder: true, congested: false),
                 .encode,
                 "a ready cached frame schedules an encode")
    bounded.beginSyntheticEncode()
    for _ in 0..<500 { bounded.recordKeyframeRequest() }
    report.equal(bounded.decision(active: true, hasEncoder: true, congested: false),
                 .encodeInFlight,
                 "500 requests during one encode schedule no second encode")
    bounded.finishSyntheticEncode()
    report.equal(bounded.decision(active: true, hasEncoder: true, congested: false),
                 .encode,
                 "after the in-flight encode finishes at most one more is scheduled")
    report.check(bounded.hasOutstandingRequest,
                 "the coalesced requests are still represented by one pending IDR")

    // A request that arrives while an IDR is being submitted must not be
    // swallowed by that IDR's completion.
    var racing = KeyframeRecoveryState()
    racing.recordKeyframeRequest()
    racing.cacheFrame()
    let serialAtSubmission = racing.pendingRequestSerial
    report.check(serialAtSubmission != nil, "the submitted encode captures a request serial")
    racing.beginSyntheticEncode()
    racing.recordKeyframeRequest()          // arrives during the encode
    racing.markRequestSatisfied(upTo: serialAtSubmission ?? 0)
    report.check(racing.hasOutstandingRequest,
                 "a request arriving during the encode stays outstanding")
    racing.finishSyntheticEncode()
    report.equal(racing.decision(active: true, hasEncoder: true, congested: false),
                 .encode,
                 "the late request gets its own forced IDR")
    racing.markRequestSatisfied(upTo: racing.pendingRequestSerial ?? 0)
    report.check(!racing.hasOutstandingRequest, "the late request is satisfied once submitted")
    report.equal(racing.decision(active: true, hasEncoder: true, congested: false),
                 .noRequest,
                 "no further encode is scheduled after both requests are satisfied")

    // Teardown clears generation-scoped state, keeps the client's request.
    var teardown = KeyframeRecoveryState()
    teardown.recordKeyframeRequest()
    teardown.cacheFrame()
    teardown.beginSyntheticEncode()
    teardown.resetForCaptureTeardown()
    report.check(!teardown.hasCachedFrame,
                 "teardown drops the cached frame")
    report.check(!teardown.syntheticEncodeInFlight,
                 "teardown releases the in-flight slot")
    report.check(teardown.hasOutstandingRequest,
                 "teardown keeps the request for the next capture generation")
    report.equal(teardown.decision(active: true, hasEncoder: false, congested: false),
                 .encoderNotReady,
                 "the next generation does not answer before its encoder exists")
    teardown.cacheFrame()
    report.equal(teardown.decision(active: true, hasEncoder: true, congested: false),
                 .encode,
                 "the next generation's first cached frame serves the request")

    // A stale callback cannot resurrect a dropped frame or a released slot.
    teardown.finishSyntheticEncode()
    teardown.discardCachedFrame()
    report.check(!teardown.syntheticEncodeInFlight && !teardown.hasCachedFrame,
                 "stale completion/discard callbacks cannot revive teardown state")
    report.equal(teardown.decision(active: true, hasEncoder: true, congested: false),
                 .noCachedFrame,
                 "no synthetic encode is possible after the cached frame is discarded")
}

// MARK: - Rate limit

private func testSyntheticRateLimit(_ report: Report) {
    let now = Date(timeIntervalSinceReferenceDate: 10_000)

    report.check(SyntheticKeyframeRateLimit.delay(since: .distantPast, now: now, minimum: 0.1) == nil,
                 "the first cached-frame IDR is not delayed")

    report.check(SyntheticKeyframeRateLimit.delay(since: now.addingTimeInterval(-0.25), now: now, minimum: 0.1) == nil,
                 "a request outside the coalescing window runs immediately")

    if let delay = SyntheticKeyframeRateLimit.delay(since: now.addingTimeInterval(-0.04), now: now, minimum: 0.1) {
        report.check(delay > 0.05 && delay <= 0.061,
                     "a request inside the window is delayed until it opens")
    } else {
        report.check(false, "a request inside the coalescing window must wait")
    }

    report.check(SyntheticKeyframeRateLimit.delay(since: now.addingTimeInterval(-0.04), now: now, minimum: 0) == nil,
                 "a zero window disables coalescing")
}

// MARK: - Presentation time

private func testPresentationTimes(_ report: Report) {
    let step = CMTime(value: 1, timescale: 60)
    let fallback = CMTime(value: 1000, timescale: 1)

    let increasing = PresentationTimeRules.next(
        last: CMTime(value: 10, timescale: 1),
        proposed: CMTime(value: 11, timescale: 1),
        fallback: fallback,
        step: step
    )
    report.check(CMTimeCompare(increasing, CMTime(value: 11, timescale: 1)) == 0,
                 "a strictly increasing capture timestamp is kept")

    let duplicated = PresentationTimeRules.next(
        last: CMTime(value: 10, timescale: 1),
        proposed: CMTime(value: 10, timescale: 1),
        fallback: fallback,
        step: step
    )
    report.check(CMTimeCompare(duplicated, CMTime(value: 10, timescale: 1)) > 0,
                 "a duplicated timestamp is advanced")

    let equivalentDifferentScale = PresentationTimeRules.next(
        last: CMTime(value: 10, timescale: 1),
        proposed: CMTime(value: 10_000, timescale: 1000),
        fallback: fallback,
        step: step
    )
    report.check(CMTimeCompare(equivalentDifferentScale, CMTime(value: 10, timescale: 1)) > 0,
                 "an equal timestamp in another timescale is advanced")

    let backwards = PresentationTimeRules.next(
        last: CMTime(value: 10, timescale: 1),
        proposed: CMTime(value: 5, timescale: 1),
        fallback: fallback,
        step: step
    )
    report.check(CMTimeCompare(backwards, CMTime(value: 10, timescale: 1)) > 0,
                 "a regressing timestamp is advanced")

    let invalid = PresentationTimeRules.next(
        last: CMTime(value: 10, timescale: 1),
        proposed: .invalid,
        fallback: fallback,
        step: step
    )
    report.check(CMTimeCompare(invalid, fallback) == 0,
                 "an idle cached frame uses the host-clock fallback")

    let noClock = PresentationTimeRules.next(
        last: .invalid,
        proposed: .invalid,
        fallback: .invalid,
        step: step
    )
    report.check(noClock.isValid && noClock.seconds.isFinite && noClock.seconds > 0,
                 "a request before any timestamp still produces a valid PTS")

    let indefinite = PresentationTimeRules.next(
        last: CMTime(value: 10, timescale: 1),
        proposed: .indefinite,
        fallback: .invalid,
        step: step
    )
    report.check(indefinite.isValid && indefinite.seconds.isFinite,
                 "an indefinite timestamp never reaches VideoToolbox")

    let degenerateStep = PresentationTimeRules.next(
        last: CMTime(value: 10, timescale: 1),
        proposed: CMTime(value: 10, timescale: 1),
        fallback: fallback,
        step: .invalid
    )
    report.check(CMTimeCompare(degenerateStep, CMTime(value: 10, timescale: 1)) > 0,
                 "an invalid frame duration falls back to a usable step")

    // Worst case for a static screen: the host clock is frozen at the previous
    // PTS. Every synthetic stamp must still move forward.
    var last = CMTime(value: 42, timescale: 1)
    var monotonic = true
    for _ in 0..<1000 {
        let next = PresentationTimeRules.next(last: last,
                                              proposed: last,
                                              fallback: last,
                                              step: step)
        if CMTimeCompare(next, last) <= 0 || !next.isValid { monotonic = false }
        last = next
    }
    report.check(monotonic, "1000 frozen-clock cached-frame stamps stay strictly increasing")
}

// MARK: - Restart policy

private func testRestartPolicy(_ report: Report) {
    report.equal(
        CaptureRestartPolicy.decision(clientSupportsHDR: false,
                                      hdrUnavailableReason: "unused",
                                      hdrPreviouslyFailed: true,
                                      hdrRestartsWithoutConfirmation: 99),
        .restartSDR(reason: nil),
        "an SDR client restarts in SDR without an HDR warning"
    )

    let edr = "iPad 专用屏 EDR 余量不足（1.00）"
    report.equal(
        CaptureRestartPolicy.decision(clientSupportsHDR: true,
                                      hdrUnavailableReason: edr,
                                      hdrPreviouslyFailed: false,
                                      hdrRestartsWithoutConfirmation: 0),
        .restartSDR(reason: edr),
        "a target display without EDR headroom restarts in SDR with the reason"
    )

    report.equal(
        CaptureRestartPolicy.decision(clientSupportsHDR: true,
                                      hdrUnavailableReason: nil,
                                      hdrPreviouslyFailed: false,
                                      hdrRestartsWithoutConfirmation: 0),
        .restartHDR,
        "a healthy HDR session recovers as HDR instead of being pinned to SDR"
    )

    if case .restartSDR(let reason) = CaptureRestartPolicy.decision(
        clientSupportsHDR: true,
        hdrUnavailableReason: nil,
        hdrPreviouslyFailed: true,
        hdrRestartsWithoutConfirmation: 0
    ) {
        report.check(reason?.isEmpty == false,
                     "a session that already fell back to SDR reports why")
    } else {
        report.check(false, "a session that already fell back to SDR must not retry HDR")
    }

    report.equal(
        CaptureRestartPolicy.decision(clientSupportsHDR: true,
                                      hdrUnavailableReason: nil,
                                      hdrPreviouslyFailed: false,
                                      hdrRestartsWithoutConfirmation: 1),
        .restartHDR,
        "the first HDR restart is allowed"
    )

    if case .restartSDR(let reason) = CaptureRestartPolicy.decision(
        clientSupportsHDR: true,
        hdrUnavailableReason: nil,
        hdrPreviouslyFailed: false,
        hdrRestartsWithoutConfirmation: 2
    ) {
        report.check(reason?.isEmpty == false,
                     "the HDR restart bound degrades to SDR with a reason")
    } else {
        report.check(false, "HDR restarts without confirmation are bounded")
    }

    // The bound is a parameter so the rule itself is testable, but production
    // always uses the documented default.
    report.equal(CaptureRestartPolicy.maxHDRRestartsWithoutConfirmation, 2,
                 "the production HDR restart bound is two attempts")
}

// MARK: - Entry point

func testCaptureEncoderRecovery(_ report: Report) {
    print("\nCapture encoder keyframe recovery / HDR restart policy")
    testKeyframeScheduling(report)
    testSyntheticRateLimit(report)
    testPresentationTimes(report)
    testRestartPolicy(report)
}
