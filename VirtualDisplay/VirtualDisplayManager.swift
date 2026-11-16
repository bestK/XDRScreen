//
//  VirtualDisplayManager.swift
//  XDRScreen
//
//  Creates a headless macOS virtual display with the private-but-system
//  `CGVirtualDisplay` Objective-C classes.
//
//  Design constraints:
//
//  * No private headers and no bridging header. Classes are looked up with
//    `NSClassFromString`; the two methods that take several scalar arguments
//    are called through their runtime IMP with an exact C signature, so this
//    file compiles against the public SDK alone.
//  * A missing class, selector or property is a normal, recoverable error;
//    nothing here force-unwraps a private symbol.
//  * This type only ever creates/releases its *own* virtual display. It never
//    changes the main display, mirroring, display modes, or the arrangement of
//    physical displays.
//  * `width`/`height` are PIXEL dimensions. With `prefersHiDPI` (the default)
//    this type also registers a half-sized logical mode, then selects the
//    matching 2x mode on the display it just created, so 2732x2048 pixels is
//    presented as a 1366x1024-point desktop. This matches the iPad Pro 12.9"
//    native panel. If no exact 2x mode is published the virtual display is
//    released and `create` reports failure; a 1x display is never reported as
//    HiDPI. `CGDisplayPixelsWide` returns the logical width for HiDPI modes
//    and must not be used to tell 1x from 2x — check `CGDisplayMode.pixelWidth`.
//
//  Scheduling contract (why creation is asynchronous):
//
//  The virtual display is registered with WindowServer on the queue stored in
//  the descriptor (`DispatchQueue.main`). WindowServer therefore needs the
//  main run loop to keep running before it publishes the display and its
//  modes. The previous implementation waited for those modes with
//  `Thread.sleep` on the main thread; that starved the very run loop the
//  publication depends on, so mode enumeration stayed empty until the deadline
//  and creation failed. `create` now:
//
//    1. builds the descriptor/settings/display object synchronously on the
//       main thread (the private API is main-thread work),
//    2. returns to the run loop and polls for the 2x mode with repeated
//       non-blocking `asyncAfter` hops on the main queue (bounded, ~3 s),
//    3. sets the mode on its own `displayID` only, verifies the committed
//       pixel/point size, and delivers the completion on the main queue.
//
//  Every attempt is tied to a generation. `close()` (or any release) bumps the
//  generation and cancels the selector, so a late asynchronous result can
//  never revive a released display, set a mode on a stale display ID, or
//  invoke the completion twice. Callers get exactly one completion per
//  `create`, including an explicit `.cancelled` failure when the display is
//  released while it is still being prepared.
//
//  * Colour primaries are configurable (Display P3 by default), but colour
//    primaries are NOT HDR/EDR. No EDR headroom API is exposed for virtual
//    displays; do not treat `experimentalTransferFunction` as an HDR switch.
//

import Foundation
import CoreGraphics

public struct VirtualDisplayError: Swift.Error, LocalizedError, Equatable {
    public enum Kind: Equatable {
        case classesUnavailable
        case selectorUnavailable
        case invalidParameters
        case allocationFailed
        case initializationFailed
        case applySettingsFailed
        case missingDisplayID
        case alreadyOpen
        /// `prefersHiDPI` was set but the system never published an exact 2x
        /// mode for the requested pixel size. The virtual display has been
        /// released; nothing is left open at 1x.
        case hiDPIModeUnavailable
        /// The display was released (mode switch, host stop, app exit) while
        /// `create` was still waiting for its 2x mode. Nothing is left open.
        case cancelled
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }
}

public final class VirtualDisplayManager {

    // MARK: - Public configuration

    /// CIE 1931 xy chromaticities. The P3 values below are D65.
    public struct ColorPrimaries: Equatable {
        public var red: CGPoint
        public var green: CGPoint
        public var blue: CGPoint
        public var white: CGPoint

        public init(red: CGPoint, green: CGPoint, blue: CGPoint, white: CGPoint) {
            self.red = red
            self.green = green
            self.blue = blue
            self.white = white
        }

        /// Display P3 with D65 white point. This is colourimetry only; it does
        /// not make the display HDR-capable.
        public static let displayP3 = ColorPrimaries(
            red: CGPoint(x: 0.680, y: 0.320),
            green: CGPoint(x: 0.265, y: 0.690),
            blue: CGPoint(x: 0.150, y: 0.060),
            white: CGPoint(x: 0.3127, y: 0.3290)
        )

        /// The descriptor's default, Rec.709/BT.709 primaries with D65.
        public static let rec709 = ColorPrimaries(
            red: CGPoint(x: 0.640, y: 0.330),
            green: CGPoint(x: 0.300, y: 0.600),
            blue: CGPoint(x: 0.150, y: 0.060),
            white: CGPoint(x: 0.3127, y: 0.3290)
        )
    }

    /// An extra mode that the user may select manually in System Settings.
    /// The mode passed to `create` is always listed first.
    public struct Mode: Equatable {
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var refreshRate: Double
        /// Experimental: `CGVirtualDisplayMode` accepts a transfer function
        /// (0...4 have been observed to round-trip). Its meaning is not
        /// documented and it has not been shown to enable EDR/HDR. Leave nil
        /// unless you are running an explicit experiment.
        public var transferFunction: UInt32?

        public init(pixelWidth: Int, pixelHeight: Int, refreshRate: Double, transferFunction: UInt32? = nil) {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.refreshRate = refreshRate
            self.transferFunction = transferFunction
        }
    }

    /// Called on the main queue exactly once per `create`. On failure the
    /// virtual display has already been released.
    public typealias CreateCompletion = (Result<CGDirectDisplayID, VirtualDisplayError>) -> Void

    /// Name shown by the system for the virtual display.
    public var displayName: String = "XDRScreen iPad"

    /// When true, use a 2x mode (mode dimensions are pixels; the desktop is
    /// half as many points). Default true, which is what the iPad panel wants.
    ///
    /// `create` registers a half-sized logical mode automatically (the
    /// requested width/height must be divisible by two) and, after creating
    /// the display, selects the exact mode whose pixel size equals the
    /// request and whose point size is half of it. If the system never
    /// publishes such a mode, the completion reports
    /// `VirtualDisplayError.Kind.hiDPIModeUnavailable` after releasing the
    /// virtual display.
    public var prefersHiDPI: Bool = true

    /// Colour primaries written through the descriptor's primary properties.
    /// CoreDisplay mirrors these into its EDID-like displayInfo dictionary.
    public var primaries: ColorPrimaries = .displayP3

    /// Used to derive `sizeInMillimeters` when `physicalSizeMillimeters` is
    /// nil. 264 ppi is the iPad Pro 12.9" panel density.
    public var pixelsPerInch: Double = 264

    /// Explicit physical size. When nil it is computed from `pixelsPerInch`.
    public var physicalSizeMillimeters: CGSize?

    /// Optional user-selectable modes. The app must not switch to them on its
    /// own; they are for the user to pick in System Settings. With
    /// `prefersHiDPI` the half-sized logical mode is appended automatically
    /// unless an equivalent mode is already present.
    public var additionalModes: [Mode] = []

    /// Experimental per-mode transfer function for the primary mode. Nil uses
    /// the 3-argument mode initializer (the same one DeskPad-style virtual
    /// displays use). Setting a value does not guarantee HDR/EDR; see
    /// `Mode.transferFunction`.
    public var experimentalTransferFunction: UInt32?

    /// Identity reported to the system. Values are arbitrary but stable.
    public var vendorID: UInt32 = 0x1234
    public var productID: UInt32 = 0x2732
    public var serialNumber: UInt32 = 1

    /// Called on the main queue for non-fatal safety observations.
    public var onWarning: ((String) -> Void)?

    // MARK: - Observable state
    //
    // Main-thread confined: creation, release and the completion are all
    // delivered on the main queue, and HostController only reads these while
    // on the main queue.

    public private(set) var displayID: CGDirectDisplayID = 0
    public private(set) var isOpen: Bool = false
    public private(set) var lastWarning: String?

    /// Best-effort geometry read after the display is ready. Nil until the 2x
    /// mode has been selected and verified.
    public private(set) var observedPixelSize: CGSize?
    public private(set) var observedPointSize: CGSize?

    /// Strong reference keeps the virtual display alive. Releasing it runs
    /// `-[CGVirtualDisplay dealloc]`, which asks CoreDisplay/WindowServer to
    /// destroy the display.
    private var displayObject: AnyObject?

    /// The in-flight 2x mode search, if any. Owned here so `close()` can
    /// cancel it before the display object goes away.
    private var selection: HiDPIModeSelector?

    /// Completion of the `create` currently being prepared.
    private var pendingCreate: CreateCompletion?

    /// Bumped on every create and every release. Asynchronous work carries the
    /// value it started with and is ignored when it no longer matches, so a
    /// late result can never revive a released display or fire twice.
    private var generation: UInt64 = 0

    public init() {}

    deinit {
        releaseNow()
    }

    // MARK: - Lifecycle

    /// Creates the virtual display asynchronously and delivers exactly one
    /// completion on the main queue.
    ///
    /// Safe to call from any thread: the private API is driven on the main
    /// thread and the completion always arrives there. Throws nothing; failure
    /// is reported through the completion. Calling it while a display is open
    /// fails with `.alreadyOpen` — call `close()` first.
    public func create(width: Int,
                       height: Int,
                       refreshRate: Double,
                       completion: @escaping CreateCompletion) {
        if Thread.isMainThread {
            createOnMain(width: width, height: height, refreshRate: refreshRate, completion: completion)
        } else {
            DispatchQueue.main.async {
                self.createOnMain(width: width,
                                  height: height,
                                  refreshRate: refreshRate,
                                  completion: completion)
            }
        }
    }

    /// Destroys this manager's virtual display. Physical displays, the main
    /// display and the display arrangement are untouched.
    ///
    /// Also invalidates any in-flight creation: its pending completion is
    /// answered with `.cancelled` and no later asynchronous result may touch
    /// the display.
    public func close() {
        if Thread.isMainThread {
            releaseNow()
        } else {
            DispatchQueue.main.sync { self.releaseNow() }
        }
    }

    private func releaseNow() {
        generation &+= 1
        selection?.cancel()
        selection = nil
        displayObject = nil
        displayID = 0
        isOpen = false
        lastWarning = nil
        observedPixelSize = nil
        observedPointSize = nil

        // The owner cancelled the creation. Answer it here and now instead of
        // letting a later polling attempt do so, so nothing is silently
        // dropped. `deinit` can run off the main thread; there is no caller
        // left to notify then.
        let pending = pendingCreate
        pendingCreate = nil
        if let pending, Thread.isMainThread {
            pending(.failure(VirtualDisplayError(
                .cancelled,
                "虚拟屏创建已被取消（显示方式切换或主机停止）；没有留下任何虚拟显示器。"
            )))
        }
    }

    // MARK: - Creation

    private func createOnMain(width: Int,
                              height: Int,
                              refreshRate: Double,
                              completion: @escaping CreateCompletion) {
        if isOpen || displayObject != nil {
            completion(.failure(VirtualDisplayError(.alreadyOpen,
                                                    "A virtual display is already open; call close() first.")))
            return
        }

        do {
            try Self.validate(width: width, height: height, refreshRate: refreshRate, hiDPI: prefersHiDPI)
            let (display, newID) = try makeDisplay(width: width, height: height, refreshRate: refreshRate)

            displayObject = display
            displayID = newID
            isOpen = true
            lastWarning = nil
            generation &+= 1
            let gen = generation
            pendingCreate = completion

            guard prefersHiDPI else {
                finishCreation(gen: gen, result: .success(newID))
                return
            }

            // Returns to the run loop immediately. Everything from here on is
            // driven by non-blocking main-queue hops.
            startModeSelection(gen: gen, width: width, height: height, refreshRate: refreshRate)
        } catch let error as VirtualDisplayError {
            completion(.failure(error))
        } catch {
            completion(.failure(VirtualDisplayError(.initializationFailed, error.localizedDescription)))
        }
    }

    /// Builds the descriptor, the registered modes, the settings and the
    /// `CGVirtualDisplay` itself. Must run on the main queue.
    private func makeDisplay(width: Int,
                             height: Int,
                             refreshRate: Double) throws -> (AnyObject, CGDirectDisplayID) {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type else {
            throw VirtualDisplayError(.classesUnavailable, "CGVirtualDisplayDescriptor is unavailable on this macOS build.")
        }
        guard let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type else {
            throw VirtualDisplayError(.classesUnavailable, "CGVirtualDisplaySettings is unavailable on this macOS build.")
        }
        guard let modeClass = NSClassFromString("CGVirtualDisplayMode") else {
            throw VirtualDisplayError(.classesUnavailable, "CGVirtualDisplayMode is unavailable on this macOS build.")
        }
        guard let displayClass = NSClassFromString("CGVirtualDisplay") else {
            throw VirtualDisplayError(.classesUnavailable, "CGVirtualDisplay is unavailable on this macOS build.")
        }

        // --- Descriptor -----------------------------------------------------
        let descriptor = descriptorClass.init()

        try Self.set(descriptor, key: "name", setter: "setName:", value: displayName)
        try Self.set(descriptor, key: "maxPixelsWide", setter: "setMaxPixelsWide:", value: NSNumber(value: UInt32(width)))
        try Self.set(descriptor, key: "maxPixelsHigh", setter: "setMaxPixelsHigh:", value: NSNumber(value: UInt32(height)))
        try Self.set(descriptor, key: "vendorID", setter: "setVendorID:", value: NSNumber(value: vendorID))
        try Self.set(descriptor, key: "productID", setter: "setProductID:", value: NSNumber(value: productID))
        try Self.set(descriptor, key: "serialNum", setter: "setSerialNum:", value: NSNumber(value: serialNumber))

        let size = physicalSize(width: width, height: height)
        try Self.set(descriptor, key: "sizeInMillimeters", setter: "setSizeInMillimeters:",
                     value: NSValue(size: NSSize(width: size.width, height: size.height)))
        try Self.set(descriptor, key: "queue", setter: "setQueue:", value: DispatchQueue.main)

        // CoreDisplay copies these into its EDID-like displayInfo dictionary.
        try Self.set(descriptor, key: "redPrimary", setter: "setRedPrimary:",
                     value: NSValue(point: NSPoint(x: primaries.red.x, y: primaries.red.y)))
        try Self.set(descriptor, key: "greenPrimary", setter: "setGreenPrimary:",
                     value: NSValue(point: NSPoint(x: primaries.green.x, y: primaries.green.y)))
        try Self.set(descriptor, key: "bluePrimary", setter: "setBluePrimary:",
                     value: NSValue(point: NSPoint(x: primaries.blue.x, y: primaries.blue.y)))
        try Self.set(descriptor, key: "whitePoint", setter: "setWhitePoint:",
                     value: NSValue(point: NSPoint(x: primaries.white.x, y: primaries.white.y)))

        // --- Modes ----------------------------------------------------------
        // The system publishes the 2x variant (same points, doubled pixels)
        // only when the half-sized logical mode exists, so register it when
        // HiDPI is requested. The requested mode stays first.
        let primaryMode = Mode(pixelWidth: width,
                               pixelHeight: height,
                               refreshRate: refreshRate,
                               transferFunction: experimentalTransferFunction)
        let modes = Self.modeList(primary: primaryMode,
                                  additional: additionalModes,
                                  hiDPI: prefersHiDPI)

        var modeObjects: [AnyObject] = []
        for mode in modes {
            try Self.validate(width: mode.pixelWidth, height: mode.pixelHeight,
                              refreshRate: mode.refreshRate, hiDPI: prefersHiDPI)
            modeObjects.append(try Self.makeMode(modeClass,
                                                 width: mode.pixelWidth,
                                                 height: mode.pixelHeight,
                                                 refreshRate: mode.refreshRate,
                                                 transferFunction: mode.transferFunction))
        }

        // --- Settings -------------------------------------------------------
        let settings = settingsClass.init()
        try Self.set(settings, key: "hiDPI", setter: "setHiDPI:",
                     value: NSNumber(value: UInt32(prefersHiDPI ? 1 : 0)))
        try Self.set(settings, key: "modes", setter: "setModes:", value: modeObjects)

        // --- Display --------------------------------------------------------
        // The descriptor/settings/mode objects must outlive the private calls;
        // withExtendedLifetime prevents ARC from releasing them early while
        // only raw pointers are visible to the runtime.
        let (display, displayPtr) = try withExtendedLifetime((descriptor, settings, modeObjects)) {
            () throws -> (AnyObject, UnsafeMutableRawPointer) in
            let allocated = try Self.allocate(displayClass)
            let initWithDescriptor: Runtime.InitObjectFn = try Self.instanceIMP(
                displayClass, "initWithDescriptor:", as: Runtime.InitObjectFn.self
            )
            guard let pointer = initWithDescriptor(
                allocated,
                NSSelectorFromString("initWithDescriptor:"),
                Self.pointer(of: descriptor)
            ) else {
                throw VirtualDisplayError(.initializationFailed,
                                          "CGVirtualDisplay -initWithDescriptor: returned nil.")
            }
            let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()

            let applySettings: Runtime.ApplySettingsFn = try Self.instanceIMP(
                displayClass, "applySettings:", as: Runtime.ApplySettingsFn.self
            )
            guard applySettings(pointer,
                                NSSelectorFromString("applySettings:"),
                                Self.pointer(of: settings)) else {
                // Releasing `object` destroys the half-created display; no
                // physical display was touched.
                throw VirtualDisplayError(.applySettingsFailed,
                                          "CGVirtualDisplay -applySettings: returned NO.")
            }
            return (object, pointer)
        }

        let getDisplayID: Runtime.UInt32Getter = try Self.instanceIMP(
            displayClass, "displayID", as: Runtime.UInt32Getter.self
        )
        let newID = getDisplayID(displayPtr, NSSelectorFromString("displayID"))
        guard newID != 0 else {
            throw VirtualDisplayError(.missingDisplayID, "CGVirtualDisplay returned displayID 0.")
        }
        return (display, newID)
    }

    /// Starts the asynchronous 2x search on the display this manager just
    /// created. Nothing here blocks: the first attempt is one main-queue hop
    /// away, which is exactly what lets WindowServer publish the display.
    private func startModeSelection(gen: UInt64,
                                    width: Int,
                                    height: Int,
                                    refreshRate: Double) {
        let selector = HiDPIModeSelector(
            displayID: displayID,
            target: HiDPIModeSelector.Target(pixelWidth: width,
                                             pixelHeight: height,
                                             refreshRate: refreshRate),
            backend: CoreGraphicsDisplayModeBackend(),
            queue: .main,
            pollInterval: Self.hiDPIPollInterval,
            timeout: Self.hiDPISelectionTimeout,
            verifyTimeout: Self.hiDPIVerifyTimeout
        )
        selection = selector
        selector.start { [weak self] outcome in
            // The selector delivers on the main queue.
            guard let self else { return }
            self.selection = nil
            guard self.generation == gen, self.isOpen else { return }
            switch outcome {
            case .success:
                self.finishCreation(gen: gen, result: .success(self.displayID))
            case .failure(let failure):
                let error = Self.error(for: failure,
                                       pixelWidth: width,
                                       pixelHeight: height,
                                       refreshRate: refreshRate)
                self.finishCreation(gen: gen, result: .failure(error))
            }
        }
    }

    /// Resolves the pending `create` exactly once. A stale generation (the
    /// display was released while this was in flight) is ignored: the release
    /// already answered the caller with `.cancelled`.
    private func finishCreation(gen: UInt64,
                                result: Result<CGDirectDisplayID, VirtualDisplayError>) {
        guard generation == gen else { return }
        let completion = pendingCreate
        pendingCreate = nil

        switch result {
        case .success(let id):
            readObservedGeometry()
            warnIfUnexpectedMainDisplay(id)
            completion?(.success(id))
        case .failure(let error):
            // Never leave a 1x display open while reporting failure.
            releaseNow()
            completion?(.failure(error))
        }
    }

    private func warnIfUnexpectedMainDisplay(_ id: CGDirectDisplayID) {
        guard CGDisplayIsMain(id) != 0 else { return }
        let message = "虚拟显示器被系统报告为主显示器；本类没有修改主屏，请检查“显示器”排列设置。"
        lastWarning = message
        onWarning?(message)
    }

    /// Re-reads pixel/point geometry. Safe to call after the display is ready.
    public func readObservedGeometry() {
        guard displayID != 0 else {
            observedPixelSize = nil
            observedPointSize = nil
            return
        }

        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let w = mode.pixelWidth
            let h = mode.pixelHeight
            observedPixelSize = (w > 0 && h > 0) ? CGSize(width: w, height: h) : nil
        } else {
            observedPixelSize = nil
        }

        let bounds = CGDisplayBounds(displayID)
        observedPointSize = (bounds.width > 0 && bounds.height > 0) ? bounds.size : nil
    }

    private func physicalSize(width: Int, height: Int) -> CGSize {
        if let explicit = physicalSizeMillimeters { return explicit }
        let ppi = max(pixelsPerInch, 1)
        return CGSize(width: Double(width) / ppi * 25.4,
                      height: Double(height) / ppi * 25.4)
    }

    // MARK: - HiDPI mode planning and selection

    /// Bounds for the asynchronous search. They are generous because the wait
    /// no longer blocks anything: the run loop stays free, so waiting longer
    /// costs nothing but does let a slow WindowServer publish the mode.
    private static let hiDPISelectionTimeout: TimeInterval = 3.0
    private static let hiDPIVerifyTimeout: TimeInterval = 1.0
    private static let hiDPIPollInterval: TimeInterval = 0.05

    /// What a `CGDisplayMode` reports for geometry. Kept as a value type so
    /// the matching rules and the scheduler can be exercised without a real
    /// display.
    public struct DisplayModeSnapshot: Equatable {
        public var width: Int
        public var height: Int
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var refreshRate: Double

        public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
            self.width = width
            self.height = height
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.refreshRate = refreshRate
        }
    }

    static func snapshot(of mode: CGDisplayMode) -> DisplayModeSnapshot {
        DisplayModeSnapshot(width: mode.width,
                            height: mode.height,
                            pixelWidth: mode.pixelWidth,
                            pixelHeight: mode.pixelHeight,
                            refreshRate: mode.refreshRate)
    }

    /// True only for a genuine 2x mode: the framebuffer is exactly the
    /// requested pixel size and the desktop is exactly half of it in points.
    /// A 1x mode of the same pixel size fails the point-size check, and a 1x
    /// mode of the same point size fails the pixel-size check.
    /// `CGDisplayPixelsWide` is deliberately not used: for HiDPI modes it
    /// reports the logical width on current macOS.
    public static func isTargetHiDPIMode(_ mode: DisplayModeSnapshot,
                                         pixelWidth: Int,
                                         pixelHeight: Int,
                                         refreshRate: Double) -> Bool {
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth % 2 == 0, pixelHeight % 2 == 0 else { return false }
        return mode.pixelWidth == pixelWidth
            && mode.pixelHeight == pixelHeight
            && mode.width == pixelWidth / 2
            && mode.height == pixelHeight / 2
            && abs(mode.refreshRate - refreshRate) <= 0.5
    }

    /// Primary mode first, then the caller's modes, then the half-sized
    /// logical mode that makes the system publish the 2x variant. An
    /// equivalent mode (same pixel size and refresh rate) is not added twice.
    static func modeList(primary: Mode, additional: [Mode], hiDPI: Bool) -> [Mode] {
        var modes = [primary]
        modes.append(contentsOf: additional)
        guard hiDPI,
              primary.pixelWidth % 2 == 0,
              primary.pixelHeight % 2 == 0 else {
            return modes
        }
        let half = Mode(pixelWidth: primary.pixelWidth / 2,
                        pixelHeight: primary.pixelHeight / 2,
                        refreshRate: primary.refreshRate,
                        transferFunction: primary.transferFunction)
        let exists = modes.contains {
            $0.pixelWidth == half.pixelWidth
                && $0.pixelHeight == half.pixelHeight
                && abs($0.refreshRate - half.refreshRate) <= 0.5
        }
        if !exists { modes.append(half) }
        return modes
    }

    private static func error(for failure: HiDPIModeSelector.Failure,
                              pixelWidth: Int,
                              pixelHeight: Int,
                              refreshRate: Double) -> VirtualDisplayError {
        switch failure {
        case .displayNeverOnline:
            return VirtualDisplayError(
                .missingDisplayID,
                "虚拟屏在 \(Int(hiDPISelectionTimeout)) 秒内没有被 WindowServer 上线"
                    + "（显示器未发布）；虚拟屏已释放。"
            )
        case .timedOut(let observed):
            return VirtualDisplayError(
                .hiDPIModeUnavailable,
                "系统未发布 \(pixelWidth)x\(pixelHeight)px / "
                    + "\(pixelWidth / 2)x\(pixelHeight / 2)pt @ "
                    + "\(format(refreshRate))Hz 的 2x 模式；虚拟屏已释放。"
                    + "枚举到的模式：\(describe(observed))"
            )
        case .setModeRejected:
            return VirtualDisplayError(
                .hiDPIModeUnavailable,
                "CGDisplaySetDisplayMode 切换到 2x 模式失败；虚拟屏已释放。"
            )
        case .verificationTimedOut:
            return VirtualDisplayError(
                .hiDPIModeUnavailable,
                "已请求 2x 模式，但当前模式不是 \(pixelWidth)x\(pixelHeight)px / "
                    + "\(pixelWidth / 2)x\(pixelHeight / 2)pt；虚拟屏已释放。"
            )
        case .cancelled:
            return VirtualDisplayError(.cancelled, "虚拟屏创建已被取消；没有留下任何虚拟显示器。")
        }
    }

    private static func format(_ rate: Double) -> String {
        String(format: "%.2f", rate)
    }

    static func describe(_ modes: [DisplayModeSnapshot]) -> String {
        guard !modes.isEmpty else { return "（枚举为空）" }
        return modes.map {
            "\($0.width)x\($0.height)pt/\($0.pixelWidth)x\($0.pixelHeight)px@"
                + "\(format($0.refreshRate))"
        }.joined(separator: ", ")
    }

    // MARK: - Runtime helpers

    private enum Runtime {
        typealias AllocFn = @convention(c) (UnsafeMutableRawPointer, Selector) -> UnsafeMutableRawPointer?
        typealias InitObjectFn = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
        typealias InitModeFn = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double) -> UnsafeMutableRawPointer?
        typealias InitModeTransferFn = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double, UInt32) -> UnsafeMutableRawPointer?
        typealias ApplySettingsFn = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeMutableRawPointer) -> Bool
        typealias UInt32Getter = @convention(c) (UnsafeMutableRawPointer, Selector) -> UInt32
    }

    private static func classIMP<T>(_ cls: AnyClass, _ selector: String, as type: T.Type) throws -> T {
        let sel = NSSelectorFromString(selector)
        guard let method = class_getClassMethod(cls, sel) else {
            throw VirtualDisplayError(.selectorUnavailable, "Class method \(selector) is unavailable on \(cls).")
        }
        return unsafeBitCast(method_getImplementation(method), to: T.self)
    }

    private static func instanceIMP<T>(_ cls: AnyClass, _ selector: String, as type: T.Type) throws -> T {
        let sel = NSSelectorFromString(selector)
        guard let method = class_getInstanceMethod(cls, sel) else {
            throw VirtualDisplayError(.selectorUnavailable, "Instance method \(selector) is unavailable on \(cls).")
        }
        return unsafeBitCast(method_getImplementation(method), to: T.self)
    }

    private static func pointer(of object: AnyObject) -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(object).toOpaque()
    }

    /// Checks that the Objective-C setter exists before KVC is used, so a
    /// missing private property yields a Swift error instead of an
    /// uncatchable NSUnknownKeyException.
    private static func set(_ object: NSObject,
                            key: String,
                            setter: String,
                            value: Any?) throws {
        guard object.responds(to: NSSelectorFromString(setter)) else {
            throw VirtualDisplayError(.selectorUnavailable, "\(setter) is unavailable on \(type(of: object)).")
        }
        object.setValue(value, forKey: key)
    }

    /// +alloc. The returned pointer is +1 and must be handed to an init.
    private static func allocate(_ cls: AnyClass) throws -> UnsafeMutableRawPointer {
        let allocFn: Runtime.AllocFn = try classIMP(cls, "alloc", as: Runtime.AllocFn.self)
        let receiver = pointer(of: cls as AnyObject)
        guard let pointer = allocFn(receiver, NSSelectorFromString("alloc")) else {
            throw VirtualDisplayError(.allocationFailed, "\(cls) +alloc returned nil.")
        }
        return pointer
    }

    /// Builds a CGVirtualDisplayMode. Width/height are pixel dimensions.
    private static func makeMode(_ cls: AnyClass,
                                 width: Int,
                                 height: Int,
                                 refreshRate: Double,
                                 transferFunction: UInt32?) throws -> AnyObject {
        let allocated = try allocate(cls)
        let selectorName: String
        let initialized: UnsafeMutableRawPointer?

        if let transferFunction {
            selectorName = "initWithWidth:height:refreshRate:transferFunction:"
            let initFn: Runtime.InitModeTransferFn = try instanceIMP(
                cls, selectorName, as: Runtime.InitModeTransferFn.self
            )
            initialized = initFn(allocated, NSSelectorFromString(selectorName),
                                 UInt32(width), UInt32(height), refreshRate, transferFunction)
        } else {
            selectorName = "initWithWidth:height:refreshRate:"
            let initFn: Runtime.InitModeFn = try instanceIMP(
                cls, selectorName, as: Runtime.InitModeFn.self
            )
            initialized = initFn(allocated, NSSelectorFromString(selectorName),
                                 UInt32(width), UInt32(height), refreshRate)
        }

        guard let initialized else {
            throw VirtualDisplayError(.initializationFailed,
                                      "CGVirtualDisplayMode -\(selectorName) returned nil.")
        }
        return Unmanaged<AnyObject>.fromOpaque(initialized).takeRetainedValue()
    }

    private static func validate(width: Int, height: Int, refreshRate: Double, hiDPI: Bool) throws {
        guard width > 0, height > 0 else {
            throw VirtualDisplayError(.invalidParameters, "width/height must be positive.")
        }
        guard width <= Int(UInt32.max), height <= Int(UInt32.max) else {
            throw VirtualDisplayError(.invalidParameters, "width/height exceed UInt32.")
        }
        guard refreshRate.isFinite, refreshRate > 0, refreshRate <= 240 else {
            throw VirtualDisplayError(.invalidParameters, "refreshRate must be finite and in (0, 240].")
        }
        if hiDPI && (width % 2 != 0 || height % 2 != 0) {
            throw VirtualDisplayError(
                .invalidParameters,
                "HiDPI modes need even pixel dimensions so the point size stays integral."
            )
        }
    }
}

// MARK: - Display mode backend

/// One mode the window server currently publishes for a display, together
/// with the opaque handle needed to select it (`CGDisplayMode` in production).
public struct AvailableDisplayMode {
    public let snapshot: VirtualDisplayManager.DisplayModeSnapshot
    public let handle: AnyObject

    public init(snapshot: VirtualDisplayManager.DisplayModeSnapshot, handle: AnyObject = NSObject()) {
        self.snapshot = snapshot
        self.handle = handle
    }
}

/// The few CoreGraphics operations the 2x search needs. Abstracted so the
/// scheduling rules can be regression-tested without creating a display.
public protocol HiDPIModeBackend: AnyObject {
    func isOnline(_ displayID: CGDirectDisplayID) -> Bool
    /// All published modes, including duplicate/low-resolution variants.
    func availableModes(for displayID: CGDirectDisplayID) -> [AvailableDisplayMode]
    func setMode(_ mode: AvailableDisplayMode, on displayID: CGDirectDisplayID) -> Bool
    func currentMode(for displayID: CGDirectDisplayID) -> VirtualDisplayManager.DisplayModeSnapshot?
}

/// The real backend. `CGDisplayCopyAllDisplayModes` with
/// `kCGDisplayShowDuplicateLowResolutionModes` is what exposes the 2x variant;
/// without it the list holds only 1x modes.
final class CoreGraphicsDisplayModeBackend: HiDPIModeBackend {
    private let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary

    func isOnline(_ displayID: CGDirectDisplayID) -> Bool {
        displayID != 0 && CGDisplayIsOnline(displayID) != 0
    }

    func availableModes(for displayID: CGDirectDisplayID) -> [AvailableDisplayMode] {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return []
        }
        return modes.map {
            AvailableDisplayMode(snapshot: VirtualDisplayManager.snapshot(of: $0), handle: $0)
        }
    }

    func setMode(_ mode: AvailableDisplayMode, on displayID: CGDirectDisplayID) -> Bool {
        // `CGDisplayMode` is a CoreFoundation type, so a conditional cast is
        // diagnosed as always succeeding; compare the runtime type instead so
        // a foreign handle is rejected rather than reinterpreted.
        guard CFGetTypeID(mode.handle as CFTypeRef) == CGDisplayMode.typeID else { return false }
        let cgMode = mode.handle as! CGDisplayMode
        return CGDisplaySetDisplayMode(displayID, cgMode, nil) == .success
    }

    func currentMode(for displayID: CGDirectDisplayID) -> VirtualDisplayManager.DisplayModeSnapshot? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return VirtualDisplayManager.snapshot(of: mode)
    }
}

// MARK: - Asynchronous 2x mode selection

/// Finds, selects and verifies the exact 2x mode for ONE display ID, without
/// ever blocking its scheduler queue.
///
/// Every poll is a separate `asyncAfter` hop, so on the main queue the run
/// loop keeps turning between attempts — the virtual display's publication
/// depends on exactly that. The search is bounded by `timeout` (publish) and
/// `verifyTimeout` (commit), and every outcome resolves the completion once.
///
/// Thread safety: `start`/`cancel` may be called from any thread. The
/// completion and the backend calls run on `queue`. A generation counter makes
/// `cancel()` authoritative: once it returns, no later attempt can enumerate,
/// set a mode, or call the completion.
public final class HiDPIModeSelector {

    public struct Target: Equatable {
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let refreshRate: Double

        public init(pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.refreshRate = refreshRate
        }
    }

    public enum Failure: Error, Equatable {
        /// The window server never reported the display as online within the
        /// deadline: nothing was published to enumerate.
        case displayNeverOnline
        /// No exact 2x mode was published before the deadline. `observed` is
        /// the last enumeration, for a diagnosable error message.
        case timedOut(observed: [VirtualDisplayManager.DisplayModeSnapshot])
        case setModeRejected
        case verificationTimedOut
        case cancelled
    }

    public enum Outcome: Equatable {
        case success(CGDirectDisplayID)
        case failure(Failure)
    }

    public let displayID: CGDirectDisplayID
    public let target: Target

    private let backend: HiDPIModeBackend
    private let queue: DispatchQueue
    private let pollInterval: TimeInterval
    private let timeout: TimeInterval
    private let verifyTimeout: TimeInterval

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var completion: ((Outcome) -> Void)?
    private var finished = true
    /// Last enumeration seen, used only to build a timeout message.
    private var lastObserved: [VirtualDisplayManager.DisplayModeSnapshot] = []

    public init(displayID: CGDirectDisplayID,
                target: Target,
                backend: HiDPIModeBackend,
                queue: DispatchQueue = .main,
                pollInterval: TimeInterval = 0.05,
                timeout: TimeInterval = 3.0,
                verifyTimeout: TimeInterval = 1.0) {
        self.displayID = displayID
        self.target = target
        self.backend = backend
        self.queue = queue
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.verifyTimeout = verifyTimeout
    }

    /// Begins the search. Returns immediately; the completion is delivered on
    /// `queue` at most once (another `start` supersedes it).
    public func start(completion: @escaping (Outcome) -> Void) {
        lock.lock()
        generation &+= 1
        let gen = generation
        self.completion = completion
        finished = false
        lastObserved = []
        lock.unlock()

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        schedule(after: 0, gen: gen) { [weak self] in
            self?.attemptDiscovery(gen: gen, deadline: deadline, sawOnline: false)
        }
    }

    /// Cancels the search. Idempotent. No completion is delivered afterwards
    /// and no backend call is made after this returns.
    public func cancel() {
        lock.lock()
        generation &+= 1
        finished = true
        completion = nil
        lock.unlock()
    }

    // MARK: Steps (all on `queue`)

    private func attemptDiscovery(gen: UInt64, deadline: TimeInterval, sawOnline: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let online = backend.isOnline(displayID)
        let modes: [AvailableDisplayMode]
        if online {
            modes = backend.availableModes(for: displayID)
        } else {
            modes = []
        }
        lastObserved = modes.map { $0.snapshot }

        if let match = modes.first(where: {
            VirtualDisplayManager.isTargetHiDPIMode($0.snapshot,
                                                    pixelWidth: target.pixelWidth,
                                                    pixelHeight: target.pixelHeight,
                                                    refreshRate: target.refreshRate)
        }) {
            switch commit(match, gen: gen) {
            case .committed:
                let verifyDeadline = now + verifyTimeout
                schedule(after: pollInterval, gen: gen) { [weak self] in
                    self?.attemptVerification(gen: gen, deadline: verifyDeadline)
                }
            case .rejected:
                finish(gen: gen, .failure(.setModeRejected))
            case .stale:
                return
            }
            return
        }

        if now >= deadline {
            // "Never published at all" is a different, more actionable
            // failure than "published but without the 2x mode".
            let sawOnlineInThisSearch = sawOnline || online
            finish(gen: gen, .failure(sawOnlineInThisSearch
                                      ? .timedOut(observed: lastObserved)
                                      : .displayNeverOnline))
            return
        }
        let delay = min(max(pollInterval, 0.001), max(0, deadline - now))
        schedule(after: delay, gen: gen) { [weak self] in
            self?.attemptDiscovery(gen: gen, deadline: deadline, sawOnline: sawOnline || online)
        }
    }

    private func attemptVerification(gen: UInt64, deadline: TimeInterval) {
        let current = backend.currentMode(for: displayID)
        if let current,
           VirtualDisplayManager.isTargetHiDPIMode(current,
                                                   pixelWidth: target.pixelWidth,
                                                   pixelHeight: target.pixelHeight,
                                                   refreshRate: target.refreshRate) {
            finish(gen: gen, .success(displayID))
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now >= deadline {
            finish(gen: gen, .failure(.verificationTimedOut))
            return
        }
        let delay = min(max(pollInterval, 0.001), max(0, deadline - now))
        schedule(after: delay, gen: gen) { [weak self] in
            self?.attemptVerification(gen: gen, deadline: deadline)
        }
    }

    private enum CommitResult {
        case committed
        case rejected
        /// The search was cancelled before the mode could be set.
        case stale
    }

    /// Sets the mode with the generation lock held, so `cancel()` can never
    /// return while a mode change is being applied to this display ID.
    private func commit(_ mode: AvailableDisplayMode, gen: UInt64) -> CommitResult {
        lock.lock()
        defer { lock.unlock() }
        guard gen == generation, !finished else { return .stale }
        return backend.setMode(mode, on: displayID) ? .committed : .rejected
    }

    /// Resolves the completion exactly once. A stale generation (cancelled or
    /// superseded) is dropped silently.
    private func finish(gen: UInt64, _ outcome: Outcome) {
        lock.lock()
        guard gen == generation, !finished else {
            lock.unlock()
            return
        }
        finished = true
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?(outcome)
    }

    /// One non-blocking hop. Nothing runs when the search was cancelled or
    /// already finished.
    private func schedule(after delay: TimeInterval, gen: UInt64, _ body: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = (gen == self.generation && !self.finished)
            self.lock.unlock()
            guard current else { return }
            body()
        }
    }
}
