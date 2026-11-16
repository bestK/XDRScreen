//
//  TouchView.swift
//  XDRScreen (iPad client)
//
//  Maps touches inside the letterboxed video rect to normalised Mac
//  coordinates and turns them into mouse/scroll input. Also acts as the
//  UIKeyInput responder for the on-screen and hardware keyboards.
//
//  Gestures
//  - single finger down / drag / up            -> left click + drag
//  - long press (no movement) or two-finger tap -> right click
//  - two-finger drag                           -> scroll (device-point deltas)
//  - two-finger pinch (distance change)        -> zoom the picture
//  - two-finger drag while zoomed              -> pan the picture
//  - three-finger drag while zoomed            -> scroll (the two-finger drag
//                                                 is taken by panning)
//
//  Zoom/pan are reported to the controller as deltas; the touch handling itself
//  stays in this view's (untransformed) coordinate space, so the picture point
//  under a finger is the same at every zoom level.
//

import UIKit

final class TouchView: UIView, UIKeyInput {

    /// The video rect in this view's coordinate space. Recalculated by the
    /// root controller after rotation, format changes and letterboxing.
    var videoRectProvider: (() -> CGRect)?
    var onInput: ((InputMessage) -> Void)?
    var onKeyboardStateChange: ((Bool) -> Void)?

    /// Current viewport zoom (1 = not zoomed). While zoomed, a two-finger drag
    /// pans the picture and a three-finger drag scrolls the Mac.
    var zoomScaleProvider: (() -> CGFloat)?
    /// One pinch step: the scale factor relative to the previous step, the
    /// midpoint in this view's coordinates, and how far that midpoint moved
    /// since the previous step (also in view coordinates).
    var onPinch: ((_ scaleFactor: CGFloat, _ midpoint: CGPoint, _ viewDelta: CGVector) -> Void)?
    /// One two-finger pan step while zoomed, in this view's coordinates.
    var onPan: ((_ viewDelta: CGVector) -> Void)?

    private enum Mode {
        case idle
        case single
        case multi
        /// A long press already produced a right click; ignore the finger
        /// until it lifts so no left button can be left down.
        case suppressed
    }

    private var mode: Mode = .idle
    private var activeTouches: [UITouch] = []
    private var singleTouch: UITouch?
    private var leftDown = false
    private var pressPoint: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var lastValidPoint: CGPoint = .zero
    private var movedDistance: CGFloat = 0
    private var longPressWork: DispatchWorkItem?

    /// A left press is deferred until the finger actually drags (or lifts as a
    /// tap). Otherwise putting a second finger down for a right click/scroll
    /// would first click whatever was under the first finger.
    private static let dragThreshold: CGFloat = 6

    private var scrollCandidate = false
    private var scrollStartTime: CFTimeInterval = 0
    private var scrollTravel: CGFloat = 0
    private var lastCentroid: CGPoint = .zero
    private var accumulatedDX: CGFloat = 0
    private var accumulatedDY: CGFloat = 0

    // Zoom gesture sub-state inside `.multi`. `didPinch` survives until every
    // finger is up, so lifting one finger mid-pinch can never turn the rest of
    // the gesture into a two-finger right click.
    private var pinchBaseline: (distance: CGFloat, scale: CGFloat)?
    private var pinchLastDistance: CGFloat = 0
    private var pinchLastMidpoint: CGPoint = .zero
    private var pinching = false
    private var didPinch = false
    private var panning = false
    private var panTravel: CGFloat = 0

    /// Change in finger distance, in screen points, before a two-finger drag
    /// becomes a pinch. Screen points so the feel is the same at every zoom.
    private static let pinchThreshold: CGFloat = 12
    /// Movement in this view's points before a zoomed two-finger drag pans.
    private static let panThreshold: CGFloat = 3

    private var heldHardwareKeys: [UIKeyboardHIDUsage: UInt16] = [:]

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            releaseAllInput()
        }
    }

    // MARK: - Geometry

    private var videoRect: CGRect {
        videoRectProvider?() ?? .zero
    }

    // The rect is in displayed-picture space. The Metal renderer has applied
    // the top-to-bottom correction relative to the previous output (see
    // StreamOrientation in VideoPresentationGeometry.swift), so the 0...1
    // coordinates below follow the picture as shown: right is +x, down is +y.
    // They must not be inverted again here.

    private func isInsideVideo(_ point: CGPoint) -> Bool {
        let rect = videoRect
        return rect.width > 1 && rect.height > 1 && rect.contains(point)
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let inside = touches.filter { isInsideVideo($0.location(in: self)) }
        guard !inside.isEmpty else { return }
        for touch in inside where !activeTouches.contains(where: { $0 === touch }) {
            activeTouches.append(touch)
        }

        switch mode {
        case .idle:
            if activeTouches.count == 1, let touch = activeTouches.first {
                beginSingle(touch)
            } else if activeTouches.count >= 2 {
                beginMulti()
            }
        case .single:
            if activeTouches.count >= 2 {
                beginMulti()
            }
        case .multi:
            // A new finger changes the centroid and the pair distance. Rebase
            // and end any pinch/pan so the new finger count starts clean.
            rebaseMultiTouch()
        case .suppressed:
            break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        switch mode {
        case .single:
            guard let touch = singleTouch else { return }
            let point = touch.location(in: self)
            movedDistance += hypot(point.x - lastPoint.x, point.y - lastPoint.y)
            lastPoint = point
            if movedDistance > Self.dragThreshold {
                cancelLongPress()
            }
            if isInsideVideo(point) {
                lastValidPoint = point
                if !leftDown, movedDistance > Self.dragThreshold {
                    // Start the drag where the finger first landed so the Mac
                    // sees the full gesture, then move to the current point.
                    leftDown = true
                    send("down", at: pressPoint)
                }
                if leftDown {
                    send("move", at: point)
                }
            }
        case .multi:
            updateMultiTouch()
        case .idle, .suppressed:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let ended = touches.filter { touch in activeTouches.contains(where: { $0 === touch }) }
        for touch in ended {
            activeTouches.removeAll { $0 === touch }
        }

        switch mode {
        case .single:
            guard let touch = singleTouch, ended.contains(where: { $0 === touch }) else { return }
            cancelLongPress()
            let point = touch.location(in: self)
            if isInsideVideo(point) {
                lastValidPoint = point
            }
            if leftDown {
                send("up", at: lastValidPoint)
                leftDown = false
            } else {
                // No drag threshold was crossed: a clean one-shot click.
                send("tap", at: lastValidPoint)
            }
            finishGesture()
        case .multi:
            if activeTouches.isEmpty {
                if scrollCandidate {
                    finishMultiGesture(endedTouches: Array(ended))
                }
                finishGesture()
            } else {
                // A finger lifted mid-pinch/pan: drop the zoom sub-state and
                // rebase on the remaining fingers. `didPinch` stays set, so the
                // rest of this gesture cannot end as a right click.
                rebaseMultiTouch()
            }
        case .suppressed:
            if activeTouches.isEmpty {
                finishGesture()
            }
        case .idle:
            finishGesture()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        releaseAllInput()
    }

    // MARK: Single finger

    private func beginSingle(_ touch: UITouch) {
        mode = .single
        singleTouch = touch
        let point = touch.location(in: self)
        pressPoint = point
        lastPoint = point
        lastValidPoint = point
        movedDistance = 0
        leftDown = false
        scheduleLongPress()
    }

    private func scheduleLongPress() {
        cancelLongPress()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.mode == .single,
                  !self.leftDown,
                  self.movedDistance < Self.dragThreshold else { return }
            self.longPressWork = nil
            self.send("rightDown", at: self.lastValidPoint)
            self.send("rightUp", at: self.lastValidPoint)
            self.mode = .suppressed
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }

    // MARK: Two fingers

    private func beginMulti() {
        cancelLongPress()
        if leftDown {
            send("up", at: lastValidPoint)
            leftDown = false
        }
        singleTouch = nil
        mode = .multi
        scrollCandidate = activeTouches.count == 2
        scrollStartTime = CACurrentMediaTime()
        scrollTravel = 0
        accumulatedDX = 0
        accumulatedDY = 0
        lastCentroid = centroid()
        lastValidPoint = lastCentroid
        resetZoomGestureTracking()
        if let pair = twoFingerPoints() {
            pinchBaseline = (hypot(pair.b.x - pair.a.x, pair.b.y - pair.a.y), zoomScale)
        }
    }

    private func updateMultiTouch() {
        guard activeTouches.count >= 2, let pair = twoFingerPoints() else {
            // One finger lifted; a right click or scroll is no longer a
            // clean two-finger gesture.
            endZoomGestureTracking()
            scrollCandidate = false
            return
        }

        let distance = hypot(pair.b.x - pair.a.x, pair.b.y - pair.a.y)
        let midpoint = CGPoint(x: (pair.a.x + pair.b.x) / 2,
                               y: (pair.a.y + pair.b.y) / 2)

        if pinching {
            // Once a pinch has started it owns the gesture until the finger
            // count changes: no scroll, no right click.
            updatePinch(distance: distance, midpoint: midpoint)
            return
        }

        if activeTouches.count >= 3 {
            // Panning is two-finger only. Three fingers keep the existing
            // scroll behaviour (and are how the Mac is scrolled while zoomed).
            updateScrollStep(midpoint: midpoint)
            return
        }

        // A large change in finger distance is a pinch, not a scroll/pan.
        if let baseline = pinchBaseline,
           abs(distance - baseline.distance) * baseline.scale > Self.pinchThreshold {
            beginPinch(midpoint: midpoint, baselineDistance: baseline.distance)
            return
        }

        if zoomScale > 1 {
            // Zoomed: the two-finger drag pans the picture; scrolling moves to
            // three fingers.
            updatePanStep(midpoint: midpoint)
            return
        }

        updateScrollStep(midpoint: midpoint)
    }

    /// Existing two-finger scroll behaviour, unchanged. `midpoint` is the
    /// average of the first two fingers, exactly what `centroid()` returned.
    private func updateScrollStep(midpoint point: CGPoint) {
        let dx = point.x - lastCentroid.x
        let dy = point.y - lastCentroid.y
        lastCentroid = point
        lastValidPoint = point
        scrollTravel += hypot(dx, dy)

        if scrollCandidate {
            let elapsed = CACurrentMediaTime() - scrollStartTime
            if scrollTravel > 8 || elapsed > 0.5 {
                scrollCandidate = false
            } else {
                return
            }
        }

        accumulatedDX += dx
        accumulatedDY += dy
        let stepX = accumulatedDX.rounded(.towardZero)
        let stepY = accumulatedDY.rounded(.towardZero)
        if stepX != 0 || stepY != 0 {
            accumulatedDX -= stepX
            accumulatedDY -= stepY
            onInput?(InputMessage(
                type: "scroll",
                deltaX: Double(stepX),
                deltaY: Double(stepY)
            ))
        }
    }

    // MARK: Zoom gestures (pinch / pan inside .multi)

    private var zoomScale: CGFloat {
        max(zoomScaleProvider?() ?? 1, 1)
    }

    private func twoFingerPoints() -> (a: CGPoint, b: CGPoint)? {
        let points = activeTouches.prefix(2).map { $0.location(in: self) }
        guard points.count == 2 else { return nil }
        return (points[0], points[1])
    }

    private func beginPinch(midpoint: CGPoint, baselineDistance: CGFloat) {
        pinching = true
        didPinch = true
        scrollCandidate = false
        accumulatedDX = 0
        accumulatedDY = 0
        // Start from the baseline distance so the movement that crossed the
        // threshold is not thrown away.
        pinchLastDistance = baselineDistance
        pinchLastMidpoint = midpoint
        lastCentroid = midpoint
        lastValidPoint = midpoint
    }

    private func updatePinch(distance: CGFloat, midpoint: CGPoint) {
        let factor = pinchLastDistance > 1 ? distance / pinchLastDistance : 1
        let viewDelta = CGVector(dx: midpoint.x - pinchLastMidpoint.x,
                                 dy: midpoint.y - pinchLastMidpoint.y)
        pinchLastDistance = distance
        pinchLastMidpoint = midpoint
        lastCentroid = midpoint
        lastValidPoint = midpoint
        if abs(factor - 1) > 1e-4 || viewDelta.dx != 0 || viewDelta.dy != 0 {
            onPinch?(factor, midpoint, viewDelta)
        }
    }

    private func updatePanStep(midpoint: CGPoint) {
        let dx = midpoint.x - lastCentroid.x
        let dy = midpoint.y - lastCentroid.y
        lastCentroid = midpoint
        lastValidPoint = midpoint
        scrollTravel += hypot(dx, dy)
        panTravel += hypot(dx, dy)
        if !panning, panTravel > Self.panThreshold {
            panning = true
        }
        guard panning, dx != 0 || dy != 0 else { return }
        onPan?(CGVector(dx: dx, dy: dy))
    }

    /// Forgets an in-progress pinch/pan and its baselines. `didPinch` is kept:
    /// the gesture is still the same one, and it must not end as a right click.
    private func endZoomGestureTracking() {
        pinching = false
        panning = false
        panTravel = 0
        pinchBaseline = nil
        pinchLastDistance = 0
        pinchLastMidpoint = .zero
    }

    private func resetZoomGestureTracking() {
        endZoomGestureTracking()
        didPinch = false
    }

    private func rebaseMultiTouch() {
        scrollCandidate = false
        accumulatedDX = 0
        accumulatedDY = 0
        lastCentroid = centroid()
        endZoomGestureTracking()
        if let pair = twoFingerPoints() {
            pinchBaseline = (hypot(pair.b.x - pair.a.x, pair.b.y - pair.a.y), zoomScale)
        }
    }

    private func finishMultiGesture(endedTouches: [UITouch]) {
        // A pinch is never a two-finger tap.
        guard !didPinch else { return }
        let elapsed = CACurrentMediaTime() - scrollStartTime
        guard elapsed < 0.5, scrollTravel < 10 else { return }
        var point = lastCentroid
        if !isInsideVideo(point) {
            if let location = endedTouches.first?.location(in: self) {
                point = location
            }
        }
        guard isInsideVideo(point) else { return }
        send("rightDown", at: point)
        send("rightUp", at: point)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func centroid() -> CGPoint {
        let points = activeTouches.prefix(2).map { $0.location(in: self) }
        guard !points.isEmpty else { return lastCentroid }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func finishGesture() {
        cancelLongPress()
        mode = .idle
        singleTouch = nil
        activeTouches.removeAll()
        leftDown = false
        scrollCandidate = false
        accumulatedDX = 0
        accumulatedDY = 0
        resetZoomGestureTracking()
    }

    /// Sends a best-effort mouse-up / key-up and clears local gesture state.
    /// Safe to call when disconnected (the input is then dropped by the
    /// controller, and the Mac releases everything when the session ends).
    func releaseAllInput() {
        cancelLongPress()
        if leftDown {
            send("up", at: lastValidPoint)
            leftDown = false
        }
        releaseHardwareKeys()
        mode = .idle
        singleTouch = nil
        activeTouches.removeAll()
        scrollCandidate = false
        accumulatedDX = 0
        accumulatedDY = 0
        // Zoom itself is kept across reconnects; only the in-flight gesture is
        // dropped so no scroll/pan/right-click can resume against a new stream.
        resetZoomGestureTracking()
    }

    // MARK: - Sending

    private func send(_ type: String, at point: CGPoint? = nil) {
        var x: Double?
        var y: Double?
        if let point,
           let picturePoint = TouchMapping.picturePoint(viewPoint: point, videoRect: videoRect) {
            x = Double(picturePoint.x)
            y = Double(picturePoint.y)
        }
        // Every mouse event needs a point; scroll uses deltas only.
        if type != "scroll", x == nil || y == nil { return }
        onInput?(InputMessage(type: type, x: x, y: y))
    }

    // MARK: - Keyboard (UIKeyInput)

    var hasText: Bool { false }

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            onKeyboardStateChange?(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let wasFirstResponder = isFirstResponder
        let resigned = super.resignFirstResponder()
        if resigned, wasFirstResponder {
            releaseHardwareKeys()
            onKeyboardStateChange?(false)
        }
        return resigned
    }

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        switch text {
        case "\n", "\r":
            sendKeyTap(36) // macOS Return
        case "\t":
            sendKeyTap(48) // macOS Tab
        default:
            onInput?(InputMessage(type: "text", text: text))
        }
    }

    func deleteBackward() {
        sendKeyTap(51) // macOS Delete (backspace)
    }

    private func sendKeyTap(_ macKeyCode: UInt16) {
        onInput?(InputMessage(type: "keyDown", keyCode: macKeyCode))
        onInput?(InputMessage(type: "keyUp", keyCode: macKeyCode))
    }

    // MARK: Hardware keyboard special keys

    private static let hardwareKeyMap: [UIKeyboardHIDUsage: UInt16] = [
        .keyboardEscape: 53,
        .keyboardDeleteForward: 117,
        .keyboardLeftArrow: 123,
        .keyboardRightArrow: 124,
        .keyboardDownArrow: 125,
        .keyboardUpArrow: 126,
        .keyboardHome: 115,
        .keyboardEnd: 119,
        .keyboardPageUp: 116,
        .keyboardPageDown: 121
    ]

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key,
                  let macCode = Self.hardwareKeyMap[key.keyCode] else { continue }
            // InputMessage carries no modifier flags, so shortcuts would be
            // wrong on the Mac; let them fall through instead of faking them.
            if key.modifierFlags.contains(.command)
                || key.modifierFlags.contains(.control)
                || key.modifierFlags.contains(.alternate) {
                continue
            }
            if heldHardwareKeys[key.keyCode] == nil {
                heldHardwareKeys[key.keyCode] = macCode
                onInput?(InputMessage(type: "keyDown", keyCode: macCode))
            }
            handled.insert(press)
        }
        let remaining = presses.subtracting(handled)
        if !remaining.isEmpty {
            super.pressesBegan(remaining, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key,
                  let macCode = heldHardwareKeys.removeValue(forKey: key.keyCode) else { continue }
            onInput?(InputMessage(type: "keyUp", keyCode: macCode))
            handled.insert(press)
        }
        let remaining = presses.subtracting(handled)
        if !remaining.isEmpty {
            super.pressesEnded(remaining, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key,
                  let macCode = heldHardwareKeys.removeValue(forKey: key.keyCode) else { continue }
            onInput?(InputMessage(type: "keyUp", keyCode: macCode))
        }
        super.pressesCancelled(presses, with: event)
    }

    private func releaseHardwareKeys() {
        for (_, macCode) in heldHardwareKeys {
            onInput?(InputMessage(type: "keyUp", keyCode: macCode))
        }
        heldHardwareKeys.removeAll()
    }
}
