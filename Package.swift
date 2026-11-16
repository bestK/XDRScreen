// swift-tools-version:5.9
//
//  Package.swift
//  XDRScreen
//
//  Local-only SwiftPM package used to compile and run the shared protocol
//  regression tests with the system Swift toolchain:
//
//      swift run --package-path . WireRegression
//
//  It deliberately contains no external dependencies and does not take part in
//  the Xcode app builds (the apps compile Shared/Wire.swift directly).
//

import PackageDescription

let package = Package(
    name: "XDRScreenProtocol",
    platforms: [
        // The capture encoder uses the macOS 15 ScreenCaptureKit HDR preset
        // APIs, matching the host app's deployment target. The regression
        // suite only compiles this module; it never starts a capture stream.
        .macOS("15.0")
    ],
    products: [
        .library(name: "XDRScreenWire", targets: ["XDRScreenWire"]),
        .library(name: "XDRScreenVirtualDisplay", targets: ["XDRScreenVirtualDisplay"]),
        .executable(name: "WireRegression", targets: ["WireRegression"])
    ],
    targets: [
        .target(
            name: "XDRScreenWire",
            path: "Shared"
        ),
        // The virtual display manager is compiled here too so its scheduling
        // rules can be regression-tested. Nothing in this module creates a
        // display unless the private classes are used by the host app.
        .target(
            name: "XDRScreenVirtualDisplay",
            path: "VirtualDisplay"
        ),
        // The arrangement controller is compiled here so its promotion and
        // restore transactions can be regression-tested against a fake
        // backend. Nothing in this module touches a display unless the
        // production CoreGraphics backend is used.
        .target(
            name: "XDRScreenDisplayArrangement",
            path: "MacHost",
            exclude: [
                "CaptureEncoder.swift",
                "FileTransferService.swift",
                "HostApp.swift",
                "HostController.swift",
                "InputController.swift"
            ],
            sources: ["DisplayArrangement.swift"]
        ),
        // The capture encoder's queue-confined recovery bookkeeping (keyframe
        // request/cached-frame scheduling, monotonically increasing
        // presentation timestamps, HDR/SDR restart policy) is compiled here so
        // it can be regression-tested. No SCStream, VTCompressionSession or
        // display is ever created by the tests.
        .target(
            name: "XDRScreenCapture",
            dependencies: ["XDRScreenWire"],
            path: "MacHost",
            exclude: [
                "DisplayArrangement.swift",
                "FileTransferService.swift",
                "HostApp.swift",
                "HostController.swift",
                "InputController.swift"
            ],
            sources: ["CaptureEncoder.swift"]
        ),
        // Pure client-side state for the format -> first-IDR handshake. It has
        // no UIKit/Network dependency, so it is compiled here and exercised by
        // WireRegression without a device.
        .target(
            name: "XDRScreenClientState",
            path: "iPadClient/FormatGate"
        ),
        // The video presentation geometry the iPad renderer and touch mapping
        // run (aspect fit, Core Image -> Metal texture convention, stream
        // orientation). CoreGraphics only, so the exact production code is
        // exercised here against a real CIContext and Metal texture.
        .target(
            name: "XDRScreenVideoGeometry",
            path: "HDRRenderer",
            exclude: ["HDRMetalVideoView.swift"],
            sources: ["VideoPresentationGeometry.swift", "ViewportTransform.swift"]
        ),
        .executableTarget(
            name: "WireRegression",
            dependencies: [
                "XDRScreenWire",
                "XDRScreenVirtualDisplay",
                "XDRScreenDisplayArrangement",
                "XDRScreenCapture",
                "XDRScreenClientState",
                "XDRScreenVideoGeometry"
            ],
            path: "Tests/WireRegression"
        )
    ]
)
