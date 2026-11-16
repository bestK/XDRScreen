//
//  ZoomViewportRegression.swift
//  WireRegression
//
//  Pure-math regression for the iPad client's zoom/pan viewport
//  (HDRRenderer/ViewportTransform.swift). No UIKit, no GPU, no device.
//
//  Covers the contract the touch layer and the container transform rely on:
//  anchor-preserving pinch zoom, edge clamping that keeps the scaled viewport
//  covering the screen, translation returning to zero at 1×, invertible
//  view<->screen mapping, re-clamping after a rotation, and the four screen
//  corners mapping to the correct Mac 0...1 picture coordinates at 1× and 2×.
//

import CoreGraphics
import Foundation
@testable import XDRScreenVideoGeometry

private let zoomEpsilon: CGFloat = 1e-9

private func zoomPointsEqual(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat = zoomEpsilon) -> Bool {
    abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
}

private func zoomPointText(_ point: CGPoint) -> String {
    String(format: "(%.6f, %.6f)", Double(point.x), Double(point.y))
}

private func zoomCheckPoint(_ report: Report, _ actual: CGPoint, _ expected: CGPoint,
                            _ label: String, tolerance: CGFloat = zoomEpsilon) {
    report.check(zoomPointsEqual(actual, expected, tolerance: tolerance),
                 label,
                 "expected \(zoomPointText(expected)), got \(zoomPointText(actual))")
}

func testViewportZoomGeometry(_ report: Report) {
    print("\n[O] Zoom viewport geometry (pinch anchor, clamping, touch mapping)")

    testZoomDefaultState(report)
    testZoomAnchorPreservation(report)
    testZoomClamping(report)
    testZoomViewportResize(report)
    testZoomMappingInvertibility(report)
    testZoomContainerTransform(report)
    testZoomTouchCorners(report)
    testZoomLetterboxedTouchConsistency(report)
}

// MARK: - O1: resting state and scale range

private func testZoomDefaultState(_ report: Report) {
    print("\n  [O1] Resting state and scale range")

    var viewport = ViewportTransform(viewportSize: CGSize(width: 1000, height: 800))
    report.equal(viewport.scale, 1, "a new viewport is 1×")
    report.equal(viewport.translation, CGVector.zero, "a new viewport has no translation")
    report.check(!viewport.isZoomed, "a new viewport is not zoomed")
    report.check(viewport.containerTransform.isIdentity,
                 "the 1× container transform is the identity")

    // 1× has nothing to pan, and panning must never create translation.
    report.check(!viewport.pan(byViewDelta: CGVector(dx: 40, dy: 40)),
                 "panning at 1× reports no movement")
    report.equal(viewport.translation, CGVector.zero, "panning at 1× leaves translation at zero")

    // Scale is always confined to 1...4, from either direction or by a pinch
    // factor that is not a number.
    viewport.zoom(to: 9, anchorViewPoint: CGPoint(x: 500, y: 400))
    report.equal(viewport.scale, 4, "zoom is clamped to 4×")
    viewport.zoom(to: 0.1, anchorViewPoint: CGPoint(x: 500, y: 400))
    report.equal(viewport.scale, 1, "zoom is clamped to 1×")
    report.equal(viewport.translation, CGVector.zero,
                 "zooming back to 1× clears the translation")
    report.check(!viewport.zoom(by: .nan, anchorViewPoint: CGPoint(x: 500, y: 400)),
                 "a non-finite pinch factor is ignored")
    report.check(!viewport.zoom(to: .infinity, anchorViewPoint: CGPoint(x: 500, y: 400)),
                 "a non-finite target scale is ignored")

    // reset() is the control bar's 适应 action.
    viewport.zoom(to: 2.5, anchorViewPoint: CGPoint(x: 250, y: 700))
    viewport.pan(byViewDelta: CGVector(dx: -10, dy: 10))
    report.check(viewport.isZoomed, "the viewport is zoomed before reset")
    viewport.reset()
    report.equal(viewport.scale, 1, "reset returns to 1×")
    report.equal(viewport.translation, CGVector.zero, "reset clears the translation")
    report.check(viewport.containerTransform.isIdentity,
                 "reset restores the identity container transform")
}

// MARK: - O2: the pinch anchor stays under the fingers

private func testZoomAnchorPreservation(_ report: Report) {
    print("\n  [O2] Pinch midpoint stays fixed on screen")

    let size = CGSize(width: 1000, height: 800)
    let anchors = [
        CGPoint(x: 500, y: 400),   // centre
        CGPoint(x: 300, y: 200),   // up-left of centre
        CGPoint(x: 900, y: 700),   // down-right of centre
        CGPoint(x: 500, y: 120),   // near the top edge
        CGPoint(x: 40, y: 760)     // near the bottom-left edge
    ]

    for anchor in anchors {
        for factor in [CGFloat(2), 1.5, 1.25] {
            var viewport = ViewportTransform(viewportSize: size)
            let before = viewport.screenPoint(fromViewPoint: anchor)
            viewport.zoom(by: factor, anchorViewPoint: anchor)
            let after = viewport.screenPoint(fromViewPoint: anchor)
            zoomCheckPoint(report, after, before,
                           "pinch \(factor)× at \(zoomPointText(anchor)) keeps that screen point fixed")
        }
    }

    // Zooming while already zoomed (2× -> 3×) keeps the anchor too.
    var viewport = ViewportTransform(viewportSize: size)
    viewport.zoom(to: 2, anchorViewPoint: CGPoint(x: 500, y: 400))
    let anchor = CGPoint(x: 620, y: 380)
    let before = viewport.screenPoint(fromViewPoint: anchor)
    viewport.zoom(by: 1.5, anchorViewPoint: anchor)
    zoomCheckPoint(report, viewport.screenPoint(fromViewPoint: anchor), before,
                   "zooming 2× -> 3× keeps the pinch midpoint fixed")
    report.equal(viewport.scale, 3, "2× with a 1.5 pinch factor is 3×")

    // Pinching back out by the reciprocal returns to the resting state.
    viewport.zoom(by: 1 / 1.5, anchorViewPoint: anchor)
    report.check(abs(viewport.scale - 2) < 1e-6,
                 "the reciprocal pinch factor returns to 2×",
                 "got \(viewport.scale)")

    // A pinch that reaches 1× drops all translation, and the clamp keeps the
    // whole screen covered at every intermediate scale.
    var covering = true
    var detail = ""
    var pinching = ViewportTransform(viewportSize: size)
    for _ in 0..<20 {
        pinching.zoom(by: 0.85, anchorViewPoint: CGPoint(x: 80, y: 60))
        let screen = CGRect(origin: .zero, size: size)
        if !pinching.contentScreenRect.insetBy(dx: -1e-6, dy: -1e-6).contains(screen) {
            covering = false
            detail = "scale \(pinching.scale) rect \(pinching.contentScreenRect)"
            break
        }
    }
    report.check(covering, "a pinch out to 1× keeps the picture covering the screen", detail)
    report.equal(pinching.scale, 1, "a continued pinch out stops at 1×")
    report.equal(pinching.translation, CGVector.zero, "1× after a pinch has no translation")
}

// MARK: - O3: clamping keeps the screen covered on all four edges

private func testZoomClamping(_ report: Report) {
    print("\n  [O3] Translation clamping covers all four edges")

    let size = CGSize(width: 1000, height: 800)
    let screen = CGRect(origin: .zero, size: size)
    let huge: CGFloat = 100_000

    var viewport = ViewportTransform(viewportSize: size)
    viewport.zoom(to: 4, anchorViewPoint: CGPoint(x: 500, y: 400))

    viewport.pan(byScreenDelta: CGVector(dx: huge, dy: huge))
    report.equal(viewport.translation, CGVector(dx: 1500, dy: 1200),
                 "panning far right/down stops at (scale-1)*size/2")
    report.check(viewport.contentScreenRect.contains(screen),
                 "the top-left corner of the screen is covered at the right/down limit",
                 "rect \(viewport.contentScreenRect)")

    viewport.pan(byScreenDelta: CGVector(dx: -huge, dy: -huge))
    report.equal(viewport.translation, CGVector(dx: -1500, dy: -1200),
                 "panning far left/up stops at the opposite limit")
    report.check(viewport.contentScreenRect.contains(screen),
                 "the bottom-right corner of the screen is covered at the left/up limit",
                 "rect \(viewport.contentScreenRect)")

    // Every edge alone: the scaled content's edge may touch the screen edge but
    // must never cross inside it.
    viewport.pan(byScreenDelta: CGVector(dx: huge, dy: 0))
    report.check(abs(viewport.contentScreenRect.minX) < 1e-6,
                 "at the right limit the content's left edge sits exactly on screen x = 0",
                 "minX \(viewport.contentScreenRect.minX)")
    viewport.pan(byScreenDelta: CGVector(dx: -huge, dy: 0))
    report.check(abs(viewport.contentScreenRect.maxX - size.width) < 1e-6,
                 "at the left limit the content's right edge sits exactly on screen maxX",
                 "maxX \(viewport.contentScreenRect.maxX)")

    // View-space pan is scaled to screen space, which is what makes a finger
    // drag carry the picture one-to-one on screen.
    var panned = ViewportTransform(viewportSize: size)
    panned.zoom(to: 2, anchorViewPoint: CGPoint(x: 500, y: 400))
    panned.pan(byViewDelta: CGVector(dx: 10, dy: -6))
    report.equal(panned.translation, CGVector(dx: 20, dy: -12),
                 "a view-space pan moves the screen by scale × delta")

    // A sweep of scales and pan directions never exposes a blank edge.
    var covered = true
    var detail = ""
    outer: for scale in [CGFloat(1.01), 1.5, 2, 3, 4] {
        var swept = ViewportTransform(viewportSize: size)
        swept.zoom(to: scale, anchorViewPoint: CGPoint(x: 137, y: 649))
        for dx in stride(from: CGFloat(-3000), through: 3000, by: 137) {
            for dy in stride(from: CGFloat(-3000), through: 3000, by: 211) {
                swept.pan(byScreenDelta: CGVector(dx: dx * 0.01, dy: dy * 0.01))
                if !swept.contentScreenRect.insetBy(dx: -1e-6, dy: -1e-6).contains(screen) {
                    covered = false
                    detail = "scale \(swept.scale) translation \(swept.translation)"
                    break outer
                }
            }
        }
    }
    report.check(covered, "a sweep of scales and pan limits never exposes a blank edge", detail)
}

// MARK: - O4: rotation / resize re-clamps

private func testZoomViewportResize(_ report: Report) {
    print("\n  [O4] Rotation and resize re-clamp the viewport")

    var viewport = ViewportTransform(viewportSize: CGSize(width: 1000, height: 800))
    viewport.zoom(to: 4, anchorViewPoint: CGPoint(x: 500, y: 400))
    viewport.pan(byScreenDelta: CGVector(dx: 100_000, dy: 100_000))
    report.equal(viewport.translation, CGVector(dx: 1500, dy: 1200),
                 "landscape viewport is panned to its limit")

    let portrait = CGSize(width: 800, height: 1000)
    viewport.setViewportSize(portrait)
    report.equal(viewport.translation, CGVector(dx: 1200, dy: 1200),
                 "a portrait viewport clamps the old translation to the new limits")
    report.check(viewport.contentScreenRect.contains(CGRect(origin: .zero, size: portrait)),
                 "the rotated viewport is still covered",
                 "rect \(viewport.contentScreenRect)")
    report.equal(viewport.scale, 4, "rotation keeps the zoom level")

    // 1× stays 1× and centred after rotation.
    var resting = ViewportTransform(viewportSize: CGSize(width: 1000, height: 800))
    resting.setViewportSize(portrait)
    report.equal(resting.scale, 1, "1× stays 1× after rotation")
    report.equal(resting.translation, CGVector.zero, "1× stays centred after rotation")

    // A degenerate size (before first layout) must not produce NaN geometry.
    var unprepared = ViewportTransform(viewportSize: .zero)
    unprepared.zoom(to: 2, anchorViewPoint: CGPoint(x: 0, y: 0))
    report.check(unprepared.translation.dx.isFinite && unprepared.translation.dy.isFinite,
                 "a zero viewport never yields a non-finite translation")
    unprepared.setViewportSize(CGSize(width: 800, height: 1000))
    report.check(unprepared.contentScreenRect.contains(CGRect(origin: .zero, size: portrait)),
                 "the first real layout clamps a zoom made before layout",
                 "rect \(unprepared.contentScreenRect)")
}

// MARK: - O5: mapping is invertible

private func testZoomMappingInvertibility(_ report: Report) {
    print("\n  [O5] viewPoint <-> screenPoint is invertible")

    let size = CGSize(width: 1000, height: 800)
    let viewPoints = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 1000, y: 800),
        CGPoint(x: 437, y: 611),
        CGPoint(x: 0.5, y: 799.5)
    ]

    var mappingOK = true
    var detail = ""
    for scale in [CGFloat(1), 1.01, 1.7, 2, 3.3, 4] {
        for anchor in [CGPoint(x: 500, y: 400), CGPoint(x: 120, y: 700), CGPoint(x: 880, y: 90)] {
            var viewport = ViewportTransform(viewportSize: size)
            viewport.zoom(to: scale, anchorViewPoint: anchor)
            viewport.pan(byScreenDelta: CGVector(dx: 37, dy: -19))
            for point in viewPoints {
                let screen = viewport.screenPoint(fromViewPoint: point)
                let roundTrip = viewport.viewPoint(fromScreenPoint: screen)
                if !zoomPointsEqual(roundTrip, point, tolerance: 1e-6) {
                    mappingOK = false
                    detail = "scale \(scale) anchor \(anchor) point \(point) -> "
                        + "\(roundTrip)"
                    break
                }
                let back = viewport.screenPoint(fromViewPoint: viewport.viewPoint(fromScreenPoint: screen))
                if !zoomPointsEqual(back, screen, tolerance: 1e-6) {
                    mappingOK = false
                    detail = "scale \(scale) anchor \(anchor) screen \(screen) -> \(back)"
                    break
                }
            }
        }
    }
    report.check(mappingOK, "view -> screen -> view returns the original point", detail)

    // The mapping is a pure scale + translation, so a screen delta is the same
    // everywhere, which is what the pan gesture assumes.
    var viewport = ViewportTransform(viewportSize: size)
    viewport.zoom(to: 2, anchorViewPoint: CGPoint(x: 500, y: 400))
    let a = viewport.screenPoint(fromViewPoint: CGPoint(x: 400, y: 300))
    let b = viewport.screenPoint(fromViewPoint: CGPoint(x: 500, y: 300))
    report.check(abs((b.x - a.x) - 200) < 1e-9,
                 "one view point is two screen points at 2×",
                 "delta \(b.x - a.x)")
}

// MARK: - O6: the transform the container installs matches the mapping

private func testZoomContainerTransform(_ report: Report) {
    print("\n  [O6] The container transform reproduces the mapping")

    let size = CGSize(width: 1000, height: 800)
    let center = CGPoint(x: 500, y: 400)
    var viewport = ViewportTransform(viewportSize: size)
    viewport.zoom(to: 3, anchorViewPoint: CGPoint(x: 700, y: 500))
    viewport.pan(byViewDelta: CGVector(dx: -20, dy: 15))

    // UIKit applies the view transform about the anchor point (centre):
    // presented = centre + M(point - centre).
    let transform = viewport.containerTransform
    var matches = true
    var detail = ""
    for point in [CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 800), CGPoint(x: 333, y: 222)] {
        let local = CGPoint(x: point.x - center.x, y: point.y - center.y).applying(transform)
        let presented = CGPoint(x: local.x + center.x, y: local.y + center.y)
        let mapped = viewport.screenPoint(fromViewPoint: point)
        if !zoomPointsEqual(presented, mapped, tolerance: 1e-9) {
            matches = false
            detail = "point \(point) presented \(presented) mapped \(mapped)"
            break
        }
    }
    report.check(matches, "UIKit's centre-relative transform equals the view->screen mapping", detail)
    report.check(abs(transform.tx - viewport.translation.dx) < 1e-9 &&
                 abs(transform.ty - viewport.translation.dy) < 1e-9,
                 "the transform's translation is the screen-space translation")
}

// MARK: - O7: screen corners -> Mac picture coordinates

private func testZoomTouchCorners(_ report: Report) {
    print("\n  [O7] Screen corners -> Mac 0...1 at 1× and 2×")

    let size = CGSize(width: 1000, height: 800)
    let videoRect = CGRect(origin: .zero, size: size) // picture fills the screen
    // Points half a point inside the screen corners: CGRect.contains excludes
    // the max edges, and a real tap at the very edge is the same pixel.
    let inset: CGFloat = 0.5
    let corners = [
        CGPoint(x: inset, y: inset),
        CGPoint(x: size.width - inset, y: inset),
        CGPoint(x: inset, y: size.height - inset),
        CGPoint(x: size.width - inset, y: size.height - inset)
    ]
    let cornerTolerance: CGFloat = 0.001

    // Mirrors TouchView: the touch is resolved in view space, then
    // TouchMapping.picturePoint turns it into the Mac's 0...1 coordinates.
    func picturePoint(atScreen screen: CGPoint, in viewport: ViewportTransform) -> CGPoint? {
        TouchMapping.picturePoint(viewPoint: viewport.viewPoint(fromScreenPoint: screen),
                                  videoRect: videoRect)
    }

    // 1×: the screen and the view are the same space.
    var resting = ViewportTransform(viewportSize: size)
    let restingExpected = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
        CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)
    ]
    for (index, corner) in corners.enumerated() {
        guard let mapped = picturePoint(atScreen: corner, in: resting) else {
            report.check(false, "1×: screen corner \(index) maps to a picture point")
            continue
        }
        zoomCheckPoint(report, mapped, restingExpected[index],
                       "1×: screen corner \(index) is Mac \(zoomPointText(restingExpected[index]))",
                       tolerance: cornerTolerance)
    }

    // 2× centred: only the middle half of the picture is on screen, so the
    // screen corners address the picture's quarter/three-quarter points.
    var centered = ViewportTransform(viewportSize: size)
    centered.zoom(to: 2, anchorViewPoint: CGPoint(x: 500, y: 400))
    report.equal(centered.translation, CGVector.zero, "2× centred has no translation")
    let centeredExpected = [
        CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
        CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.75, y: 0.75)
    ]
    for (index, corner) in corners.enumerated() {
        guard let mapped = picturePoint(atScreen: corner, in: centered) else {
            report.check(false, "2× centred: screen corner \(index) maps to a picture point")
            continue
        }
        zoomCheckPoint(report, mapped, centeredExpected[index],
                       "2× centred: screen corner \(index) is Mac \(zoomPointText(centeredExpected[index]))",
                       tolerance: cornerTolerance)
    }

    // 2× panned fully towards the picture's top-left: the screen's top-left is
    // the picture's origin and the far corners address the picture's midpoint.
    var topLeft = ViewportTransform(viewportSize: size)
    topLeft.zoom(to: 2, anchorViewPoint: CGPoint(x: 500, y: 400))
    topLeft.pan(byScreenDelta: CGVector(dx: 100_000, dy: 100_000))
    let topLeftExpected = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0),
        CGPoint(x: 0, y: 0.5), CGPoint(x: 0.5, y: 0.5)
    ]
    for (index, corner) in corners.enumerated() {
        guard let mapped = picturePoint(atScreen: corner, in: topLeft) else {
            report.check(false, "2× top-left: screen corner \(index) maps to a picture point")
            continue
        }
        zoomCheckPoint(report, mapped, topLeftExpected[index],
                       "2× at the top-left limit: screen corner \(index) is Mac \(zoomPointText(topLeftExpected[index]))",
                       tolerance: cornerTolerance)
    }

    // 2× panned fully towards the picture's bottom-right.
    var bottomRight = ViewportTransform(viewportSize: size)
    bottomRight.zoom(to: 2, anchorViewPoint: CGPoint(x: 500, y: 400))
    bottomRight.pan(byScreenDelta: CGVector(dx: -100_000, dy: -100_000))
    let bottomRightExpected = [
        CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 0.5),
        CGPoint(x: 0.5, y: 1), CGPoint(x: 1, y: 1)
    ]
    for (index, corner) in corners.enumerated() {
        guard let mapped = picturePoint(atScreen: corner, in: bottomRight) else {
            report.check(false, "2× bottom-right: screen corner \(index) maps to a picture point")
            continue
        }
        zoomCheckPoint(report, mapped, bottomRightExpected[index],
                       "2× at the bottom-right limit: screen corner \(index) is Mac \(zoomPointText(bottomRightExpected[index]))",
                       tolerance: cornerTolerance)
    }
}

// MARK: - O8: letterboxed picture stays consistent under zoom

private func testZoomLetterboxedTouchConsistency(_ report: Report) {
    print("\n  [O8] Letterboxed picture: a tap still addresses what is drawn")

    let size = CGSize(width: 1000, height: 800)
    let screen = CGRect(origin: .zero, size: size)
    let videoRect = AspectFit.rect(for: CGSize(width: 1920, height: 1080), in: screen)
    report.check(videoRect.width > 10 && videoRect.height > 10,
                 "the letterboxed picture rect exists",
                 "rect \(videoRect)")

    var consistent = true
    var detail = ""

    for scale in [CGFloat(1), 2, 3.5] {
        for pan in [CGVector.zero, CGVector(dx: 900, dy: -700), CGVector(dx: -100_000, dy: 100_000)] {
            var viewport = ViewportTransform(viewportSize: size)
            viewport.zoom(to: scale, anchorViewPoint: CGPoint(x: 500, y: 400))
            viewport.pan(byScreenDelta: pan)

            // Corners and centre of the picture as it is drawn, in view space.
            let picturePoints = [
                CGPoint(x: videoRect.minX + 0.5, y: videoRect.minY + 0.5),
                CGPoint(x: videoRect.maxX - 0.5, y: videoRect.minY + 0.5),
                CGPoint(x: videoRect.minX + 0.5, y: videoRect.maxY - 0.5),
                CGPoint(x: videoRect.maxX - 0.5, y: videoRect.maxY - 0.5),
                CGPoint(x: videoRect.midX, y: videoRect.midY)
            ]
            let expected = [
                CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
                CGPoint(x: 0.5, y: 0.5)
            ]

            for (index, picturePoint) in picturePoints.enumerated() {
                let onScreen = viewport.screenPoint(fromViewPoint: picturePoint)
                guard screen.insetBy(dx: -0.001, dy: -0.001).contains(onScreen) else {
                    continue // This part of the picture is panned off screen.
                }
                // A touch at that screen position resolves through the same
                // inverse mapping TouchView uses.
                guard let normalized = TouchMapping.picturePoint(
                    viewPoint: viewport.viewPoint(fromScreenPoint: onScreen),
                    videoRect: videoRect) else {
                    consistent = false
                    detail = "scale \(scale) pan \(pan): picture point \(index) fell outside the picture"
                    break
                }
                if abs(normalized.x - expected[index].x) > 0.001 ||
                    abs(normalized.y - expected[index].y) > 0.001 {
                    consistent = false
                    detail = "scale \(scale) pan \(pan) picture point \(index) -> \(normalized)"
                    break
                }
            }
        }
    }
    report.check(consistent, "a tap on drawn picture content addresses the same Mac coordinate at every zoom", detail)

    // At 1× the letterbox is still rejected, exactly as before zoom existed.
    var resting = ViewportTransform(viewportSize: size)
    if videoRect.minY > 4 {
        report.check(TouchMapping.picturePoint(
            viewPoint: resting.viewPoint(fromScreenPoint: CGPoint(x: size.width / 2, y: videoRect.minY - 2)),
            videoRect: videoRect) == nil,
            "1×: a tap in the top letterbox is still ignored")
    }
    if videoRect.minX > 4 {
        report.check(TouchMapping.picturePoint(
            viewPoint: resting.viewPoint(fromScreenPoint: CGPoint(x: videoRect.minX - 2, y: size.height / 2)),
            videoRect: videoRect) == nil,
            "1×: a tap in the left letterbox is still ignored")
    }
}
