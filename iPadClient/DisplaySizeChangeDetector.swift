//
//  DisplaySizeChangeDetector.swift
//  XDRScreen (iPad client)
//
//  Pure layout math used to decide whether the client's full-screen pixel box
//  changed enough to justify telling the Mac to rebuild the virtual display.
//
//  The controller compares the size carried by the last Hello of the current
//  session with the latest interface size. Treating every layout pass as a
//  change would reconnect on safe-area updates, HUD appearance, rounding noise
//  and rotation animation frames. This type keeps that decision free of UIKit
//  and networking so it can be exercised without a device.
//

import Foundation

struct DisplaySizeChangeDetector {

    struct Size: Equatable {
        let width: Int
        let height: Int

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        var isValid: Bool { width > 1 && height > 1 }
    }

    /// A dimension must move by at least this many pixels *and* this fraction
    /// of the longer side before a same-orientation resize is acted on. This
    /// keeps 1–2 pixel rounding changes and small safe-area adjustments from
    /// rebuilding the Mac's virtual screen.
    static let minimumDimensionDelta = 64
    static let relativeDimensionDelta = 0.06

    /// A different aspect ratio beyond this fraction means the window geometry
    /// really changed (for example entering/exiting Split View) even when the
    /// orientation bit did not flip.
    static let relativeAspectDelta = 0.04

    /// `true` only for a change that should trigger one controlled
    /// re-negotiation. An orientation flip always qualifies; otherwise both an
    /// absolute and a relative movement must be exceeded, or the aspect ratio
    /// must move substantially.
    static func isMaterialChange(from baseline: Size, to candidate: Size) -> Bool {
        guard baseline.isValid, candidate.isValid else { return false }
        guard baseline != candidate else { return false }

        let widthDelta = abs(candidate.width - baseline.width)
        let heightDelta = abs(candidate.height - baseline.height)
        let maxDelta = max(widthDelta, heightDelta)
        let longestSide = max(baseline.width, baseline.height, candidate.width, candidate.height)

        let orientationChanged = (baseline.width > baseline.height) != (candidate.width > candidate.height)
        if orientationChanged {
            return true
        }

        // Same orientation. A small number of pixels is layout noise even when
        // the relative fraction happens to be large on a tiny window.
        if maxDelta >= minimumDimensionDelta,
           Double(maxDelta) / Double(longestSide) >= relativeDimensionDelta {
            return true
        }

        let baselineAspect = Double(baseline.width) / Double(baseline.height)
        let candidateAspect = Double(candidate.width) / Double(candidate.height)
        let aspectDelta = abs(candidateAspect - baselineAspect)
        let aspectScale = max(baselineAspect, candidateAspect)
        if aspectScale > 0, aspectDelta / aspectScale >= relativeAspectDelta {
            return true
        }

        return false
    }
}
