//
//  VideoOrientationRegression.swift
//  WireRegression
//
//  Exercises the iPad renderer's presentation geometry for real: the exact
//  production transform is applied to a four-quadrant frame by a CIContext and
//  read back from a Metal texture. No device, no screen capture, no network.
//
//  Test frame (stored top-down, as a decoded CVPixelBuffer is):
//      top-left red      top-right green
//      bottom-left blue  bottom-right yellow
//
//  A presented CAMetalLayer shows texture row 0 at the top, so the read-back
//  layout is the layout the user sees:
//
//      StreamOrientation.identity        -> the picture appears as the frame
//                                           is stored (red / green / blue /
//                                           yellow)
//      StreamOrientation.flipTopToBottom -> the picture appears flipped
//                                           top-to-bottom (blue / yellow /
//                                           red / green), left and right
//                                           unchanged
//
//  The client applies flipTopToBottom relative to the previous Metal output,
//  based on real device feedback: v3 looked upside down and mirrored, and a
//  180° build was still mirrored left-right. The exact cause is still to be
//  verified, and this has not been checked on a real device. The tests
//  therefore also compare the two outputs of this harness directly (old
//  transform vs new transform), which does not depend on where the source
//  frame's coordinates come from.
//
//  Covered: portrait and landscape drawables, letterboxed and exact-aspect
//  drawables, a source image with a non-zero extent, the raw Core Image ->
//  Metal convention (so removing the required flip fails here), and the touch
//  mapping's four corners against Mac `CGDisplayBounds` in both orientations.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
@testable import XDRScreenVideoGeometry

// MARK: - Frame fixture

private struct Quadrant {
    let name: String
    let b: UInt8
    let g: UInt8
    let r: UInt8
}

/// Order: top-left, top-right, bottom-left, bottom-right.
private let quadrants: [Quadrant] = [
    Quadrant(name: "red", b: 0, g: 0, r: 255),
    Quadrant(name: "green", b: 0, g: 255, r: 0),
    Quadrant(name: "blue", b: 255, g: 0, r: 0),
    Quadrant(name: "yellow", b: 0, g: 255, r: 255)
]

private let frameWidth = 64
private let frameHeight = 36

private func makeQuadPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferCGImageCompatibilityKey as String: true
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault,
                              width,
                              height,
                              kCVPixelFormatType_32BGRA,
                              attributes as CFDictionary,
                              &pixelBuffer) == kCVReturnSuccess,
          let buffer = pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?
        .assumingMemoryBound(to: UInt8.self) else { return nil }
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

    for y in 0..<height {
        for x in 0..<width {
            let index = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
            let quad = quadrants[index]
            let pixel = base + y * rowBytes + x * 4
            pixel[0] = quad.b
            pixel[1] = quad.g
            pixel[2] = quad.r
            pixel[3] = 255
        }
    }
    return buffer
}

// MARK: - GPU rendering

private struct Readback {
    let width: Int
    let height: Int
    /// RGBA half floats expanded to Float, texture row 0 first.
    let pixels: [Float]

    /// `x` = column, `y` = texture row counted from the top — which is what a
    /// presented CAMetalLayer shows at that position on screen.
    func color(x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
        let index = (y * width + x) * 4
        return (Double(pixels[index]),
                Double(pixels[index + 1]),
                Double(pixels[index + 2]))
    }

    /// Classifies a colour that went through sRGB -> extended linear Display P3.
    func name(x: Int, y: Int) -> String {
        let c = color(x: x, y: y)
        if c.r < 0.02, c.g < 0.02, c.b < 0.02 { return "black" }
        if c.r > 0.5, c.g < 0.25, c.b < 0.20 { return "red" }
        if c.g > 0.6, c.r < 0.35, c.b < 0.20 { return "green" }
        if c.b > 0.5, c.r < 0.15, c.g < 0.20 { return "blue" }
        if c.r > 0.7, c.g > 0.7, c.b < 0.25 { return "yellow" }
        return String(format: "unknown(%.3f,%.3f,%.3f)", c.r, c.g, c.b)
    }
}

/// The four on-screen corners of the picture, inset so the antialiased edge
/// does not blend into black. `fittedRect` is used as a top-left-origin rect:
/// `imageTransform` ends with the Core Image texture flip, so its output y is
/// a texture row counted from the top, and the centred fitted rect occupies
/// exactly those rows and columns on screen.
private func onScreenCorners(_ fitted: CGRect, inset: CGFloat = 6) -> [(String, Int, Int)] {
    let left = Int(fitted.minX) + Int(inset)
    let right = Int(fitted.maxX) - Int(inset)
    let top = Int(fitted.minY) + Int(inset)
    let bottom = Int(fitted.maxY) - Int(inset)
    return [
        ("top-left", left, top),
        ("top-right", right, top),
        ("bottom-left", left, bottom),
        ("bottom-right", right, bottom)
    ]
}

private func makeTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: width,
        height: height,
        mipmapped: false)
    // Core Image renders with a compute pipeline and needs .shaderWrite, the
    // same requirement as the drawable in HDRMetalVideoView.
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    descriptor.storageMode = .managed
    return device.makeTexture(descriptor: descriptor)
}

/// Renders `source` through `layout.imageTransform` exactly like
/// HDRMetalVideoView.render does, then reads the texture back.
private func renderAndRead(_ source: CIImage,
                           layout: VideoFrameLayout,
                           context: CIContext,
                           queue: MTLCommandQueue,
                           device: MTLDevice,
                           colorSpace: CGColorSpace) -> Readback? {
    let width = Int(layout.drawableSize.width)
    let height = Int(layout.drawableSize.height)
    guard width > 0, height > 0, let texture = makeTexture(device: device, width: width, height: height) else {
        return nil
    }
    let target = CGRect(x: 0, y: 0, width: width, height: height)
    let background = CIImage(color: CIColor.black).cropped(to: target)
    let composed = source.transformed(by: layout.imageTransform)
        .composited(over: background)

    guard let commandBuffer = queue.makeCommandBuffer() else { return nil }
    context.render(composed,
                   to: texture,
                   commandBuffer: commandBuffer,
                   bounds: target,
                   colorSpace: colorSpace)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.status == .completed else { return nil }

    // Managed storage: make the GPU writes visible to the CPU.
    if let syncBuffer = queue.makeCommandBuffer(),
       let blit = syncBuffer.makeBlitCommandEncoder() {
        blit.synchronize(resource: texture)
        blit.endEncoding()
        syncBuffer.commit()
        syncBuffer.waitUntilCompleted()
    }

    var half: [UInt16] = Array(repeating: 0, count: width * height * 4)
    half.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        texture.getBytes(base,
                         bytesPerRow: width * 4 * MemoryLayout<UInt16>.size,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)
    }
    var pixels = [Float](repeating: 0, count: half.count)
    for index in 0..<half.count {
        pixels[index] = Float(Float16(bitPattern: half[index]))
    }
    return Readback(width: width, height: height, pixels: pixels)
}

// MARK: - Suites

func testVideoPresentationGeometry(_ report: Report) {
    print("\n[N] Video presentation geometry (four-quadrant frame, real Metal + Core Image)")

    testOrientationConstant(report)
    testAspectFitMath(report)
    testLayoutMath(report)
    testFlipTopToBottomMatchesOldOutput(report)
    testTextureConventionAndQuadrants(report)
    testTouchCornerMapping(report)
}

/// The Metal renderer flips the picture top-to-bottom relative to the old
/// output.
private func testOrientationConstant(_ report: Report) {
    print("\n  [N1] Stream orientation constant")
    // A top-to-bottom correction relative to the previous Metal output, based
    // on real device feedback. The exact cause is still to be verified.
    report.equal(StreamOrientation.current, .flipTopToBottom,
                 "the Metal renderer flips the picture top-to-bottom relative to the old output")
}

/// The fix must be exactly the old transform followed by a top-to-bottom flip
/// of the drawable: (x, y) -> (x, drawableHeight - y). Left and right are
/// unchanged. Checked point-wise for portrait, landscape, letterboxed and
/// exact-aspect drawables, including a non-zero source extent.
private func testFlipTopToBottomMatchesOldOutput(_ report: Report) {
    print("\n  [N3b] flipTopToBottom == old output flipped top-to-bottom (point-wise)")

    let extents = [
        CGRect(x: 0, y: 0, width: 64, height: 36),
        CGRect(x: 37, y: 19, width: 64, height: 36),
        CGRect(x: -12, y: 5, width: 1920, height: 1080)
    ]
    let drawables = [
        CGSize(width: 480, height: 640),
        CGSize(width: 640, height: 480),
        CGSize(width: 320, height: 320),
        CGSize(width: 320, height: 180)
    ]

    var matches = true
    var detail = ""
    outer: for extent in extents {
        for drawable in drawables {
            guard let old = VideoFrameLayout(sourceExtent: extent,
                                             drawableSize: drawable,
                                             orientation: .identity),
                  let new = VideoFrameLayout(sourceExtent: extent,
                                             drawableSize: drawable,
                                             orientation: .flipTopToBottom) else {
                matches = false
                detail = "no layout for extent \(extent), drawable \(drawable)"
                break outer
            }

            // Corners, centre and an asymmetric interior point of the source.
            let samples = [
                CGPoint(x: extent.minX, y: extent.minY),
                CGPoint(x: extent.maxX, y: extent.minY),
                CGPoint(x: extent.minX, y: extent.maxY),
                CGPoint(x: extent.maxX, y: extent.maxY),
                CGPoint(x: extent.midX, y: extent.midY),
                CGPoint(x: extent.minX + extent.width * 0.125,
                        y: extent.minY + extent.height * 0.75)
            ]
            for point in samples {
                let oldPoint = point.applying(old.imageTransform)
                let expected = CGPoint(x: oldPoint.x,
                                       y: drawable.height - oldPoint.y)
                let actual = point.applying(new.imageTransform)
                if abs(actual.x - expected.x) > 1e-6 || abs(actual.y - expected.y) > 1e-6 {
                    matches = false
                    detail = "extent \(extent) drawable \(drawable) point \(point): "
                        + "got \(actual), expected \(expected)"
                    break outer
                }
            }
        }
    }
    report.check(matches,
                 "flipTopToBottom equals the identity (old) transform followed by a top-to-bottom drawable flip",
                 detail)
}

/// `AspectFit` is the single rule behind `playbackRect` in both classes.
private func testAspectFitMath(_ report: Report) {
    print("\n  [N2] Aspect-fit / letterbox geometry")

    let bounds = CGRect(x: 0, y: 0, width: 1032, height: 1376)   // iPad Pro 13" portrait
    let wide = AspectFit.rect(for: CGSize(width: 1920, height: 1080), in: bounds)
    report.check(abs(wide.width - 1032) < 0.5,
                 "a 16:9 frame fills the width of a portrait screen",
                 "got \(wide.width)")
    report.check(abs(wide.height - 1032 * 1080 / 1920) < 0.5,
                 "letterboxed height keeps the 16:9 aspect ratio",
                 "got \(wide.height)")
    report.check(abs(wide.midX - bounds.midX) < 0.001, "letterbox is horizontally centred")
    report.check(wide.minY > 1 && wide.maxY < bounds.height - 1,
                 "a 16:9 frame leaves top and bottom letterbox bars",
                 "got \(wide)")

    let tall = AspectFit.rect(for: CGSize(width: 1080, height: 1920), in: bounds)
    report.check(abs(tall.height - 1376) < 0.5,
                 "a portrait frame fills the height of a portrait screen",
                 "got \(tall.height)")
    report.check(abs(tall.midY - bounds.midY) < 0.001, "pillarbox is vertically centred")

    let exact = AspectFit.rect(for: CGSize(width: 1032, height: 1376), in: bounds)
    report.check(abs(exact.width - bounds.width) < 0.001 &&
                 abs(exact.height - bounds.height) < 0.001,
                 "an exact-aspect frame fills the whole view")

    report.check(AspectFit.rect(for: CGSize(width: 1920, height: 1080), in: bounds).width > 0 &&
                 AspectFit.rect(for: .zero, in: bounds) == .zero,
                 "no picture yields an empty rect")
}

/// The production transform: aspect fit preserved, a top-to-bottom flip about
/// the fitted rect's horizontal centre line, and a non-zero extent still lands
/// exactly in the fitted rect.
private func testLayoutMath(_ report: Report) {
    print("\n  [N3] VideoFrameLayout transform")

    let extent = CGRect(x: 0, y: 0, width: 64, height: 36)
    let drawable = CGSize(width: 480, height: 640)
    guard let identity = VideoFrameLayout(sourceExtent: extent,
                                          drawableSize: drawable,
                                          orientation: .identity),
          let flipped = VideoFrameLayout(sourceExtent: extent,
                                         drawableSize: drawable,
                                         orientation: .flipTopToBottom) else {
        report.check(false, "layouts are created for a normal frame")
        return
    }

    report.check(abs(identity.fittedRect.width - 480) < 0.001 &&
                 abs(identity.fittedRect.height - 270) < 0.001,
                 "aspect fit keeps the 16:9 ratio in a portrait drawable",
                 "got \(identity.fittedRect)")
    report.equal(identity.fittedRect, flipped.fittedRect,
                 "flipping the picture does not move or resize the fitted rect")
    report.check(abs(identity.scale - 7.5) < 0.001,
                 "scale is drawable pixels per source pixel",
                 "got \(identity.scale)")

    // Source top-left corner. `imageTransform` ends with the Core Image
    // texture flip, so its output y is a texture row counted from the TOP (the
    // same numbers a presented CAMetalLayer shows on screen).
    let topLeft = CGPoint(x: extent.minX, y: extent.maxY)
    let identityTopLeft = topLeft.applying(identity.imageTransform)
    report.check(abs(identityTopLeft.x - identity.fittedRect.minX) < 0.001 &&
                 abs(identityTopLeft.y - identity.fittedRect.minY) < 0.001,
                 "identity: the frame's top-left stays the fitted rect's top-left",
                 "got \(identityTopLeft), fitted \(identity.fittedRect)")

    let flippedTopLeft = topLeft.applying(flipped.imageTransform)
    report.check(abs(flippedTopLeft.x - flipped.fittedRect.minX) < 0.001 &&
                 abs(flippedTopLeft.y - flipped.fittedRect.maxY) < 0.001,
                 "flipTopToBottom: the frame's top-left moves to the fitted rect's bottom-left",
                 "got \(flippedTopLeft), fitted \(flipped.fittedRect)")

    // Non-zero extent: the picture must land in the same fitted rect.
    let shifted = CGRect(x: 37, y: 19, width: 64, height: 36)
    guard let shiftedLayout = VideoFrameLayout(sourceExtent: shifted,
                                               drawableSize: drawable,
                                               orientation: .flipTopToBottom) else {
        report.check(false, "a layout is created for a non-zero extent")
        return
    }
    let transformedExtent = shifted.applying(shiftedLayout.imageTransform)
    report.check(abs(transformedExtent.minX - shiftedLayout.fittedRect.minX) < 0.001 &&
                 abs(transformedExtent.minY - shiftedLayout.fittedRect.minY) < 0.001 &&
                 abs(transformedExtent.width - shiftedLayout.fittedRect.width) < 0.001 &&
                 abs(transformedExtent.height - shiftedLayout.fittedRect.height) < 0.001,
                 "a non-zero source extent is normalised into the fitted rect",
                 "got \(transformedExtent), fitted \(shiftedLayout.fittedRect)")

    report.check(VideoFrameLayout(sourceExtent: CGRect(x: 0, y: 0, width: 0, height: 36),
                                  drawableSize: drawable) == nil,
                 "an empty extent cannot be laid out")
    report.check(VideoFrameLayout(sourceExtent: extent,
                                  drawableSize: CGSize(width: 0, height: 0)) == nil,
                 "an empty drawable cannot be laid out")
}

/// Real GPU: the Core Image -> Metal convention, and the four quadrants for
/// both orientations in several drawables.
private func testTextureConventionAndQuadrants(_ report: Report) {
    print("\n  [N4] Core Image -> Metal texture, four quadrants")

    guard let device = MTLCreateSystemDefaultDevice() else {
        report.skip("Core Image + Metal quadrant rendering", "no Metal device on this machine")
        return
    }
    guard let queue = device.makeCommandQueue() else {
        report.check(false, "a Metal command queue is created")
        return
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        ?? CGColorSpaceCreateDeviceRGB()
    let context = CIContext(mtlDevice: device, options: [
        .workingColorSpace: colorSpace,
        .outputColorSpace: colorSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false
    ])

    guard let pixelBuffer = makeQuadPixelBuffer(width: frameWidth, height: frameHeight) else {
        report.check(false, "the four-quadrant pixel buffer is created")
        return
    }
    let sourceColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let source = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: sourceColorSpace])

    // A raw render (no transform at all) proves the convention the vertical
    // flip exists for: the picture's top-left quadrant lands in the texture's
    // BOTTOM-left corner, i.e. it is upside down on a presented layer.
    do {
        let target = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        if let raw = renderRaw(source, target: target, context: context, queue: queue,
                               device: device, colorSpace: colorSpace) {
            // Texture row 0 is the top of a presented layer; the frame's
            // bottom-left (blue) shows up there.
            report.equal(raw.name(x: 2, y: 2), "blue",
                         "untransformed CIContext render is vertically flipped (row 0 = frame bottom)")
            report.equal(raw.name(x: frameWidth - 3, y: frameHeight - 3), "green",
                         "untransformed render keeps the frame's columns (no horizontal mirror)")
        } else {
            report.check(false, "a raw Core Image -> texture render completes")
        }
    }

    let drawables: [(label: String, size: CGSize)] = [
        ("portrait 480x640", CGSize(width: 480, height: 640)),
        ("landscape 640x480", CGSize(width: 640, height: 480)),
        ("square 320x320", CGSize(width: 320, height: 320)),
        ("exact aspect 320x180", CGSize(width: 320, height: 180))
    ]

    for drawable in drawables {
        for orientation in [StreamOrientation.identity, .flipTopToBottom] {
            // Corners in on-screen order: top-left, top-right, bottom-left,
            // bottom-right. A top-to-bottom flip swaps the rows and leaves the
            // columns alone.
            let expected: [String] = orientation == .identity
                ? ["red", "green", "blue", "yellow"]
                : ["blue", "yellow", "red", "green"]
            let label = "\(orientation) in \(drawable.label)"

            guard let layout = VideoFrameLayout(sourceExtent: source.extent,
                                                drawableSize: drawable.size,
                                                orientation: orientation),
                  let readback = renderAndRead(source, layout: layout, context: context,
                                               queue: queue, device: device,
                                               colorSpace: colorSpace) else {
                report.check(false, "\(label): render and read-back")
                continue
            }

            let fitted = layout.fittedRect
            let corners = onScreenCorners(fitted).map { readback.name(x: $0.1, y: $0.2) }
            report.check(corners == expected,
                         "\(label): on-screen corners are \(expected.joined(separator: "/"))",
                         "got \(corners.joined(separator: "/"))")

            // Letterbox (if any) must stay black.
            var letterboxOK = true
            if fitted.minY >= 8 {
                let c = readback.color(x: Int(fitted.midX), y: 3)
                letterboxOK = letterboxOK && c.r < 0.02 && c.g < 0.02 && c.b < 0.02
            }
            if fitted.minX >= 8 {
                let c = readback.color(x: 3, y: Int(fitted.midY))
                letterboxOK = letterboxOK && c.r < 0.02 && c.g < 0.02 && c.b < 0.02
            }
            report.check(letterboxOK, "\(label): outside the picture stays black")

            // Aspect ratio of the picture on screen.
            let aspect = fitted.width / fitted.height
            report.check(abs(aspect - source.extent.width / source.extent.height) < 0.01,
                         "\(label): picture keeps its aspect ratio",
                         "got \(aspect)")
        }
    }

    // Direct old-vs-new texture comparison: the same artificial frame through
    // the identity (old) transform and through flipTopToBottom must differ by
    // exactly a top-to-bottom flip. Both textures come from this harness, so
    // the check does not assume anything about where the source frame's
    // coordinates come from. Because a presented layer reads texture row 0 at
    // the top, the new texture at (x, y) must equal the old texture at
    // (x, height - 1 - y); the column is unchanged.
    for drawable in drawables {
        guard let oldLayout = VideoFrameLayout(sourceExtent: source.extent,
                                               drawableSize: drawable.size,
                                               orientation: .identity),
              let newLayout = VideoFrameLayout(sourceExtent: source.extent,
                                               drawableSize: drawable.size,
                                               orientation: .flipTopToBottom),
              let old = renderAndRead(source, layout: oldLayout, context: context,
                                      queue: queue, device: device,
                                      colorSpace: colorSpace),
              let new = renderAndRead(source, layout: newLayout, context: context,
                                      queue: queue, device: device,
                                      colorSpace: colorSpace) else {
            report.check(false, "\(drawable.label): old and new renders complete")
            continue
        }

        let corners = onScreenCorners(newLayout.fittedRect)
        var cornersMatch = true
        var namesMatch = true
        var detail: [String] = []
        var oldNames: [String] = []
        var newNames: [String] = []
        for (name, x, y) in corners {
            let flippedY = old.height - 1 - y
            let a = old.color(x: x, y: flippedY)
            let b = new.color(x: x, y: y)
            let delta = max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
            if delta > 0.02 {
                cornersMatch = false
                detail.append("\(name) Δ\(String(format: "%.3f", delta))")
            }
            let oldName = old.name(x: x, y: flippedY)
            let newName = new.name(x: x, y: y)
            oldNames.append(oldName)
            newNames.append(newName)
            if oldName != newName || newName == "black" || newName.hasPrefix("unknown") {
                namesMatch = false
            }
        }
        report.check(cornersMatch,
                     "\(drawable.label): new texture equals old texture flipped top-to-bottom at all four picture corners",
                     detail.joined(separator: ", "))
        report.check(namesMatch && Set(oldNames).count == 4,
                     "\(drawable.label): four asymmetric corners map onto their vertical opposites",
                     "old \(oldNames.joined(separator: "/")), new \(newNames.joined(separator: "/"))")
    }

    // Non-zero extent, letterboxed: same result as the zero-origin frame.
    do {
        let shifted = source.transformed(by: CGAffineTransform(translationX: 37, y: 19))
        guard let layout = VideoFrameLayout(sourceExtent: shifted.extent,
                                            drawableSize: CGSize(width: 480, height: 640),
                                            orientation: .current),
              let readback = renderAndRead(shifted, layout: layout, context: context,
                                           queue: queue, device: device,
                                           colorSpace: colorSpace) else {
            report.check(false, "non-zero extent: render and read-back")
            return
        }
        let fitted = layout.fittedRect
        let corners = onScreenCorners(fitted).map { readback.name(x: $0.1, y: $0.2) }
        report.check(corners == ["blue", "yellow", "red", "green"],
                     "non-zero extent: top-to-bottom flipped quadrants land in the fitted rect",
                     "got \(corners.joined(separator: "/"))")
    }
}

/// Raw render without any transform (the convention measurement).
private func renderRaw(_ source: CIImage,
                       target: CGRect,
                       context: CIContext,
                       queue: MTLCommandQueue,
                       device: MTLDevice,
                       colorSpace: CGColorSpace) -> Readback? {
    let width = Int(target.width)
    let height = Int(target.height)
    guard let texture = makeTexture(device: device, width: width, height: height),
          let commandBuffer = queue.makeCommandBuffer() else { return nil }
    context.render(source, to: texture, commandBuffer: commandBuffer,
                   bounds: target, colorSpace: colorSpace)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.status == .completed else { return nil }
    if let syncBuffer = queue.makeCommandBuffer(), let blit = syncBuffer.makeBlitCommandEncoder() {
        blit.synchronize(resource: texture)
        blit.endEncoding()
        syncBuffer.commit()
        syncBuffer.waitUntilCompleted()
    }
    var half: [UInt16] = Array(repeating: 0, count: width * height * 4)
    half.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        texture.getBytes(base,
                         bytesPerRow: width * 4 * MemoryLayout<UInt16>.size,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)
    }
    var pixels = [Float](repeating: 0, count: half.count)
    for index in 0..<half.count {
        pixels[index] = Float(Float16(bitPattern: half[index]))
    }
    return Readback(width: width, height: height, pixels: pixels)
}

/// Touch corners in portrait and landscape must reach the matching corners of
/// the Mac display, and letterbox taps must be ignored.
private func testTouchCornerMapping(_ report: Report) {
    print("\n  [N5] Touch corners -> Mac CGDisplayBounds")

    let draws: [(label: String, size: CGSize)] = [
        ("iPad portrait 1032x1376", CGSize(width: 1032, height: 1376)),
        ("iPad landscape 1376x1032", CGSize(width: 1376, height: 1032))
    ]
    let videos: [(label: String, size: CGSize)] = [
        ("1920x1080", CGSize(width: 1920, height: 1080)),
        ("2560x1440", CGSize(width: 2560, height: 1440)),
        ("1024x768", CGSize(width: 1024, height: 768)),
        ("1080x1920", CGSize(width: 1080, height: 1920)),
        ("1200x1200", CGSize(width: 1200, height: 1200))
    ]
    let displays: [(label: String, bounds: CGRect)] = [
        ("1920x1080 at (0,0)", CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        ("2560x1440 at (1920,0)", CGRect(x: 1920, y: 0, width: 2560, height: 1440))
    ]

    for draw in draws {
        let bounds = CGRect(origin: .zero, size: draw.size)
        for video in videos {
            let videoRect = AspectFit.rect(for: video.size, in: bounds)
            guard videoRect.width > 10, videoRect.height > 10 else {
                report.check(false, "\(draw.label) / \(video.label): picture rect exists")
                continue
            }

            // Points just inside the four corners of the displayed picture.
            let epsilon: CGFloat = 0.25
            let corners: [(String, CGPoint, CGPoint)] = [
                ("top-left", CGPoint(x: videoRect.minX + epsilon, y: videoRect.minY + epsilon), CGPoint(x: 0, y: 0)),
                ("top-right", CGPoint(x: videoRect.maxX - epsilon, y: videoRect.minY + epsilon), CGPoint(x: 1, y: 0)),
                ("bottom-left", CGPoint(x: videoRect.minX + epsilon, y: videoRect.maxY - epsilon), CGPoint(x: 0, y: 1)),
                ("bottom-right", CGPoint(x: videoRect.maxX - epsilon, y: videoRect.maxY - epsilon), CGPoint(x: 1, y: 1))
            ]

            var mappingOK = true
            var detail = ""
            for (name, point, expected) in corners {
                guard let normalized = TouchMapping.picturePoint(viewPoint: point,
                                                                 videoRect: videoRect) else {
                    mappingOK = false
                    detail = "\(name) outside the picture"
                    break
                }
                if abs(normalized.x - expected.x) > 0.002 || abs(normalized.y - expected.y) > 0.002 {
                    mappingOK = false
                    detail = "\(name) -> \(normalized), expected \(expected)"
                    break
                }
            }
            report.check(mappingOK,
                         "\(draw.label) / \(video.label): the four picture corners map to 0/1",
                         detail)

            // The renderer owns the top-to-bottom correction, so touch input
            // must follow the picture as displayed, not undo it: the screen's
            // top-left addresses Mac 0,0 (right is +x, down is +y).
            let topLeftPoint = CGPoint(x: videoRect.minX + epsilon, y: videoRect.minY + epsilon)
            let topLeftNormalized = TouchMapping.picturePoint(viewPoint: topLeftPoint, videoRect: videoRect)
            report.check(topLeftNormalized.map { $0.x < 0.01 && $0.y < 0.01 } ?? false,
                         "\(draw.label) / \(video.label): a tap on the picture's top-left is Mac (0,0)")

            for display in displays {
                guard let normalized = topLeftNormalized else { continue }
                // Mirrors InputController.normalizedPoint (MacHost/InputController.swift):
                // the display's CGDisplayBounds origin is its top-left, y down.
                let macPoint = CGPoint(
                    x: display.bounds.minX + normalized.x * display.bounds.width,
                    y: display.bounds.minY + normalized.y * display.bounds.height)
                // The touch point sits `epsilon` inside the picture, so allow
                // that much of the display plus one point of rounding.
                let toleranceX = display.bounds.width * (epsilon / videoRect.width) + 1
                let toleranceY = display.bounds.height * (epsilon / videoRect.height) + 1
                report.check(abs(macPoint.x - display.bounds.minX) < toleranceX &&
                             abs(macPoint.y - display.bounds.minY) < toleranceY,
                             "\(draw.label) / \(video.label) -> \(display.label): top-left lands on the display's top-left",
                             "got \(macPoint)")
            }

            // Letterbox taps are rejected.
            var letterboxChecked = false
            if videoRect.minY > 4 {
                letterboxChecked = true
                report.check(TouchMapping.picturePoint(
                    viewPoint: CGPoint(x: bounds.midX, y: videoRect.minY - 2),
                    videoRect: videoRect) == nil,
                    "\(draw.label) / \(video.label): a tap in the top letterbox is ignored")
            }
            if videoRect.minX > 4 {
                letterboxChecked = true
                report.check(TouchMapping.picturePoint(
                    viewPoint: CGPoint(x: videoRect.minX - 2, y: bounds.midY),
                    videoRect: videoRect) == nil,
                    "\(draw.label) / \(video.label): a tap in the left letterbox is ignored")
            }
            report.check(letterboxChecked || (
                abs(videoRect.width - bounds.width) < 1 && abs(videoRect.height - bounds.height) < 1),
                "\(draw.label) / \(video.label): either letterbox is rejected or the picture fills the view")
        }
    }
}
