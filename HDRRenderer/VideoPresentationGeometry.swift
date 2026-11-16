//
//  VideoPresentationGeometry.swift
//  XDRScreen
//
//  Pure geometry shared by both video renderers and by touch input.
//  CoreGraphics only — no UIKit, no Metal — so the exact code the app runs is
//  compiled and regression-tested off-device by
//  Tests/WireRegression/VideoOrientationRegression.swift (real CIContext +
//  Metal texture readback, no device).
//
//  Two different things are modelled here and must not be confused:
//
//  1. Core Image -> Metal texture convention (a measured property of
//     CIContext, not a picture rotation).
//
//     CIImage coordinates are y-up: a CIImage decoded from a CVPixelBuffer has
//     the picture's TOP at maxY. `CIContext.render(_:to: MTLTexture ...)`
//     writes the image's logical y = 0 into texture row 0, and a CAMetalLayer
//     drawable presents texture row 0 at the TOP of the layer. Rendering a
//     CIImage with no transform therefore shows the picture upside down.
//
//     Measured on this Mac (Apple M1, macOS 15.6) with a four-quadrant frame:
//     a raw render places the picture's top-left quadrant in the texture's
//     BOTTOM-left corner; with the vertical flip below it lands top-left, i.e.
//     on screen exactly as the frame is stored. `imageTransform` therefore
//     ends with a vertical flip about the drawable's horizontal centre line.
//     This flip is the Core Image convention and is *not* an orientation
//     correction — it is why `StreamOrientation.identity` shows the decoded
//     frame unchanged.
//
//  2. Orientation correction, relative to the previous Metal output.
//
//     Real device feedback: the first Metal output (no correction) appeared
//     upside down *and* mirrored left-right; a later build that turned the
//     picture 180° relative to it was still reported as mirrored left-right.
//     Those two observations leave exactly one correction relative to the
//     first output: flip top-to-bottom. Vertical is then corrected and
//     horizontal is left as it was, so no horizontal mirror is applied. The
//     root cause is not established here: nothing in this file proves where in
//     the capture/encode/decode chain the flip originates, and the correction
//     has not been verified on a real device. `StreamOrientation.current` is
//     the single switch used by the Metal renderer and (indirectly) by the
//     touch mapping.
//

import CoreGraphics

// MARK: - Stream orientation

/// How the picture is turned relative to the previous Metal output.
enum StreamOrientation: Equatable {
    /// Present the decoded frame exactly as the previous version (v3) did.
    /// Kept as the regression reference; not used in production.
    case identity
    /// Flip the picture top-to-bottom relative to `identity`: the source top
    /// is presented at the bottom and vice versa. Left and right are unchanged,
    /// so this is not a mirror and not a 180° rotation.
    case flipTopToBottom

    /// The correction the client applies on the Metal path.
    ///
    /// Real device feedback showed the `identity` output upside down and
    /// mirrored, and a 180° build still mirrored left-right; the only
    /// correction consistent with both is a top-to-bottom flip. The exact cause
    /// is still to be verified and this has not been checked on a real device.
    /// One place to change: set this to `.identity` to restore the previous
    /// direction, and the Metal renderer and touch mapping follow.
    static let current: StreamOrientation = .flipTopToBottom
}

// MARK: - Frame layout

/// Aspect-fit placement of one decoded frame inside a drawable, plus the
/// source-image -> drawable transform that includes the Core Image texture
/// convention and the top-to-bottom orientation correction.
struct VideoFrameLayout: Equatable {

    /// Extent of the CIImage about to be drawn, in image coordinates (y-up).
    /// A non-zero origin (clean aperture, cropped decode) is supported.
    let sourceExtent: CGRect
    /// Drawable size in pixels.
    let drawableSize: CGSize
    let orientation: StreamOrientation
    /// Aspect-fit scale from source pixels to drawable pixels.
    let scale: CGFloat
    /// Where the picture lands inside the drawable, in Core Image coordinates
    /// (y-up, origin bottom-left). Always centred.
    let fittedRect: CGRect
    /// Source image coordinates -> drawable coordinates. Pass directly to
    /// `CIImage.transformed(by:)`; the result is composited over a black
    /// background cropped to the drawable.
    let imageTransform: CGAffineTransform

    /// nil when the frame cannot be fitted (empty or non-finite extent,
    /// non-positive drawable).
    init?(sourceExtent: CGRect,
          drawableSize: CGSize,
          orientation: StreamOrientation = .current) {
        guard !sourceExtent.isNull, !sourceExtent.isInfinite,
              sourceExtent.width > 0, sourceExtent.height > 0,
              sourceExtent.minX.isFinite, sourceExtent.minY.isFinite,
              drawableSize.width >= 1, drawableSize.height >= 1,
              drawableSize.width.isFinite, drawableSize.height.isFinite else {
            return nil
        }

        let scale = min(drawableSize.width / sourceExtent.width,
                        drawableSize.height / sourceExtent.height)
        guard scale.isFinite, scale > 0 else { return nil }

        let fitted = CGRect(
            x: (drawableSize.width - sourceExtent.width * scale) * 0.5,
            y: (drawableSize.height - sourceExtent.height * scale) * 0.5,
            width: sourceExtent.width * scale,
            height: sourceExtent.height * scale)

        // 1. Normalise a non-zero extent origin to (0, 0).
        var transform = CGAffineTransform(translationX: -sourceExtent.minX,
                                          y: -sourceExtent.minY)

        // 2. Orientation correction: flip the picture top-to-bottom relative
        //    to the old output. Mirroring the normalised source about its own
        //    horizontal centre line — (x, y) -> (x, height - y) — and then
        //    aspect-fitting a centred rect is point-wise identical to the old
        //    transform followed by a vertical flip of the drawable, i.e.
        //    (x, y) -> (x, drawableHeight - y). Left and right are untouched,
        //    so there is no horizontal mirror. The regression checks that
        //    equivalence directly.
        if orientation == .flipTopToBottom {
            transform = transform
                .concatenating(CGAffineTransform(scaleX: 1, y: -1))
                .concatenating(CGAffineTransform(translationX: 0,
                                                 y: sourceExtent.height))
        }

        // 3. Aspect-fit scale, then centre inside the drawable.
        transform = transform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: fitted.minX,
                                             y: fitted.minY))

        // 4. Core Image -> Metal texture convention: CIContext writes logical
        //    y = 0 into texture row 0, and a presented drawable shows row 0 at
        //    the top. Flip about the drawable's horizontal centre line so the
        //    presented picture keeps the CI image's orientation. The fitted
        //    rect is centred, so its placement is unchanged.
        transform = transform
            .concatenating(CGAffineTransform(scaleX: 1, y: -1))
            .concatenating(CGAffineTransform(translationX: 0,
                                             y: drawableSize.height))

        self.sourceExtent = sourceExtent
        self.drawableSize = drawableSize
        self.orientation = orientation
        self.scale = scale
        self.fittedRect = fitted
        self.imageTransform = transform
    }
}

// MARK: - Upright aspect fit (UIKit coordinates)

/// The aspect-fit rule used by both renderers and by touch input. UIKit
/// coordinates: origin top-left, y down — the same convention as
/// AVSampleBufferDisplayLayer's `.resizeAspect` and `playbackRect`.
enum AspectFit {
    /// The rect `size` occupies inside `bounds`. `.zero` when either is
    /// unusable, matching the renderers' "no picture yet" state.
    static func rect(for size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 1, size.height > 1,
              bounds.width > 1, bounds.height > 1 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2,
                      y: bounds.midY - fitted.height / 2,
                      width: fitted.width,
                      height: fitted.height)
    }
}

// MARK: - Touch mapping

enum TouchMapping {
    /// A point in the view -> 0...1 coordinates of the picture as it is shown,
    /// or nil when the point is outside the picture (letterbox), which is what
    /// `TouchView` uses to ignore taps.
    ///
    /// The renderer has already applied the orientation correction, so these
    /// coordinates are taken straight from the displayed aspect-fit rect:
    /// right is +x and down is +y, which `InputController` maps onto
    /// `CGDisplayBounds` (y = 0 is the display's top edge). Do not invert them
    /// here: that would undo the correction for input only.
    static func picturePoint(viewPoint: CGPoint, videoRect: CGRect) -> CGPoint? {
        guard videoRect.width > 1, videoRect.height > 1,
              videoRect.contains(viewPoint) else {
            return nil
        }
        let x = min(max((viewPoint.x - videoRect.minX) / videoRect.width, 0), 1)
        let y = min(max((viewPoint.y - videoRect.minY) / videoRect.height, 0), 1)
        return CGPoint(x: x, y: y)
    }
}
