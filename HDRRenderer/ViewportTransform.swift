//
//  ViewportTransform.swift
//  XDRScreen
//
//  Pure geometry for the iPad client's zoomable video viewport.
//  CoreGraphics only — no UIKit — so the exact code the app runs is compiled
//  and regression-tested off-device by
//  Tests/WireRegression/ZoomViewportRegression.swift.
//
//  Two coordinate spaces are involved and must not be confused:
//
//  - view points: the container view's own (untransformed) coordinate space,
//    origin top-left, size == viewportSize. `touch.location(in: touchView)` is
//    in this space even while the container's transform scales it, so touches
//    and the picture share one space at every zoom level.
//  - screen points: the root view's coordinate space, i.e. what the user sees.
//
//      screen = (view - centre) * scale + centre + translation
//
//  `translation` is therefore measured in screen points. At scale == 1 it is
//  always zero. When scale > 1 it is clamped to (scale - 1) * size / 2 on each
//  axis, which is exactly the range that keeps the scaled viewport covering
//  the whole screen, so no blank edge can be exposed.
//
//  The container's UIView `transform` (see `containerTransform`) is applied by
//  UIKit about its anchor point, i.e. `screen = centre + M(view - centre)`.
//  `screenPoint(fromViewPoint:)` uses the same mapping, so the regression can
//  check the value the app installs on the container.
//

import CoreGraphics

struct ViewportTransform: Equatable {

    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 4

    private static let scaleEpsilon: CGFloat = 1e-6

    /// Current zoom, always within `minimumScale...maximumScale`.
    private(set) var scale: CGFloat = 1
    /// Screen-space offset of the scaled content from its centred position.
    private(set) var translation: CGVector = .zero
    /// Size of the viewport (the container view's bounds) in points.
    private(set) var viewportSize: CGSize = .zero

    init(viewportSize: CGSize = .zero) {
        self.viewportSize = Self.sanitizedSize(viewportSize)
        clampTranslation()
    }

    // MARK: - State

    /// True when the picture is magnified, i.e. when the two-finger gesture
    /// means pan instead of scroll.
    var isZoomed: Bool {
        scale > Self.minimumScale + Self.scaleEpsilon
    }

    var viewportCenter: CGPoint {
        CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    }

    /// The transform the container view installs. UIKit applies it about the
    /// view's anchor point (centre by default), which reproduces
    /// `screenPoint(fromViewPoint:)` for every point in the container.
    var containerTransform: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                          tx: translation.dx, ty: translation.dy)
    }

    /// The rect the viewport occupies on screen. While zoomed it must always
    /// contain the screen rect; the regression checks all four edges.
    var contentScreenRect: CGRect {
        let origin = screenPoint(fromViewPoint: .zero)
        return CGRect(x: origin.x,
                      y: origin.y,
                      width: viewportSize.width * scale,
                      height: viewportSize.height * scale)
    }

    // MARK: - Mutations

    /// Updates the viewport for a new container size (first layout, rotation,
    /// split-view resize) and re-clamps so an old zoom cannot push the picture
    /// off screen.
    mutating func setViewportSize(_ size: CGSize) {
        viewportSize = Self.sanitizedSize(size)
        clampTranslation()
    }

    /// Changes the zoom while keeping the screen point under `anchorViewPoint`
    /// fixed. At scale 1 the anchor is where the pinch midpoint is, so the
    /// picture grows out of the fingers. Returns true when the scale changed.
    @discardableResult
    mutating func zoom(by factor: CGFloat, anchorViewPoint: CGPoint) -> Bool {
        guard factor.isFinite, factor > 0 else { return false }
        return zoom(to: scale * factor, anchorViewPoint: anchorViewPoint)
    }

    @discardableResult
    mutating func zoom(to proposedScale: CGFloat, anchorViewPoint: CGPoint) -> Bool {
        guard proposedScale.isFinite,
              anchorViewPoint.x.isFinite, anchorViewPoint.y.isFinite else { return false }
        let oldScale = scale
        let newScale = Self.clampedScale(proposedScale)
        guard abs(newScale - oldScale) > Self.scaleEpsilon else { return false }
        let center = viewportCenter
        // Solve t' = t + (anchor - centre) * (s - s') so that
        // s'(anchor - centre) + centre + t' == s(anchor - centre) + centre + t.
        translation.dx += (anchorViewPoint.x - center.x) * (oldScale - newScale)
        translation.dy += (anchorViewPoint.y - center.y) * (oldScale - newScale)
        scale = newScale
        clampTranslation()
        return true
    }

    /// Pan by a movement measured in view points (what a finger delta in the
    /// scaled container reports). The screen moves by `scale` times as much,
    /// which is why the fingers carry the picture one-to-one on screen.
    @discardableResult
    mutating func pan(byViewDelta delta: CGVector) -> Bool {
        pan(byScreenDelta: CGVector(dx: delta.dx * scale, dy: delta.dy * scale))
    }

    @discardableResult
    mutating func pan(byScreenDelta delta: CGVector) -> Bool {
        guard delta.dx.isFinite, delta.dy.isFinite else { return false }
        guard isZoomed else { return false }
        let before = translation
        translation.dx += delta.dx
        translation.dy += delta.dy
        clampTranslation()
        return translation != before
    }

    /// Back to 1× with no translation.
    mutating func reset() {
        scale = Self.minimumScale
        translation = .zero
    }

    /// Re-applies the coverage rule. Also drops translation entirely at 1× so
    /// the resting state is always exactly centred.
    mutating func clampTranslation() {
        guard viewportSize.width > 0, viewportSize.height > 0,
              isZoomed else {
            translation = .zero
            return
        }
        let maxX = (scale - Self.minimumScale) * viewportSize.width / 2
        let maxY = (scale - Self.minimumScale) * viewportSize.height / 2
        translation.dx = Self.clamp(translation.dx, lower: -maxX, upper: maxX)
        translation.dy = Self.clamp(translation.dy, lower: -maxY, upper: maxY)
    }

    // MARK: - Mapping

    func screenPoint(fromViewPoint point: CGPoint) -> CGPoint {
        let center = viewportCenter
        return CGPoint(x: (point.x - center.x) * scale + center.x + translation.dx,
                       y: (point.y - center.y) * scale + center.y + translation.dy)
    }

    func viewPoint(fromScreenPoint point: CGPoint) -> CGPoint {
        guard scale > 0, scale.isFinite else { return point }
        let center = viewportCenter
        return CGPoint(x: (point.x - center.x - translation.dx) / scale + center.x,
                       y: (point.y - center.y - translation.dy) / scale + center.y)
    }

    // MARK: - Sanitising

    private static func sanitizedSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return .zero }
        return size
    }

    private static func clampedScale(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return minimumScale }
        return min(max(value, minimumScale), maximumScale)
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, lower), upper)
    }
}
