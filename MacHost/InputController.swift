//
//  InputController.swift
//  XDRScreen Mac host
//
//  Injects iPad touch / mouse / keyboard events with CGEvent.
//  Coordinates arrive normalised (0...1) inside the streamed picture and are
//  mapped onto the captured display's CGDisplayBounds (points).
//

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

final class InputController {

    private let queue = DispatchQueue(label: "com.xdrscreen.input", qos: .userInteractive)
    private var displayID: CGDirectDisplayID

    // All mutable state below is confined to `queue`.
    private var leftDown = false
    private var rightDown = false
    private var pressedKeys = Set<UInt16>()
    private var lastPoint = CGPoint.zero

    private static let queueKey = DispatchSpecificKey<UInt8>()

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    /// Updates the display used for coordinate mapping (called when the
    /// capture session settles on a concrete SCDisplay).
    func setDisplay(_ id: CGDirectDisplayID) {
        queue.async { self.displayID = id }
    }

    func handle(_ message: InputMessage) {
        queue.async { self.handleLocked(message) }
    }

    /// Releases anything this session may have left pressed. Used when the
    /// client disconnects so no button or key stays stuck.
    func releaseAll() {
        queue.async { self.releaseAllLocked() }
    }

    /// Synchronous variant for app termination.
    func releaseAllNow() {
        if DispatchQueue.getSpecific(key: InputController.queueKey) != nil {
            releaseAllLocked()
        } else {
            queue.sync { self.releaseAllLocked() }
        }
    }

    // MARK: - Event handling (queue confined)

    private func handleLocked(_ message: InputMessage) {
        // CGEvent posting is silently dropped without Accessibility trust, so
        // refuse early instead of pretending the touch worked.
        guard AXIsProcessTrusted() else { return }

        switch message.type {
        case "tap":
            // One-shot click: the client does not follow this with move/up.
            guard let point = normalizedPoint(x: message.x, y: message.y) else { return }
            lastPoint = point
            postMouse(type: .leftMouseDown, at: point, button: .left)
            postMouse(type: .leftMouseUp, at: point, button: .left)
            leftDown = false

        case "down", "leftDown":
            guard let point = normalizedPoint(x: message.x, y: message.y) else { return }
            lastPoint = point
            postMouse(type: .leftMouseDown, at: point, button: .left)
            leftDown = true

        case "move":
            guard let point = normalizedPoint(x: message.x, y: message.y) else { return }
            lastPoint = point
            let type: CGEventType
            let button: CGMouseButton
            if leftDown {
                type = .leftMouseDragged
                button = .left
            } else if rightDown {
                type = .rightMouseDragged
                button = .right
            } else {
                type = .mouseMoved
                button = .left
            }
            postMouse(type: type, at: point, button: button)

        case "up", "leftUp":
            guard let point = normalizedPoint(x: message.x, y: message.y) else {
                postMouse(type: .leftMouseUp, at: lastPoint, button: .left)
                leftDown = false
                return
            }
            lastPoint = point
            postMouse(type: .leftMouseUp, at: point, button: .left)
            leftDown = false

        case "rightDown":
            guard let point = normalizedPoint(x: message.x, y: message.y) else { return }
            lastPoint = point
            postMouse(type: .rightMouseDown, at: point, button: .right)
            rightDown = true

        case "rightUp":
            guard let point = normalizedPoint(x: message.x, y: message.y) else {
                postMouse(type: .rightMouseUp, at: lastPoint, button: .right)
                rightDown = false
                return
            }
            lastPoint = point
            postMouse(type: .rightMouseUp, at: point, button: .right)
            rightDown = false

        case "scroll":
            postScroll(deltaX: message.deltaX ?? 0, deltaY: message.deltaY ?? 0)

        case "text":
            guard let text = message.text, !text.isEmpty else { return }
            postUnicodeText(text)

        case "keyDown":
            guard let keyCode = message.keyCode else { return }
            postKey(keyCode: keyCode, down: true)

        case "keyUp":
            guard let keyCode = message.keyCode else { return }
            postKey(keyCode: keyCode, down: false)

        default:
            break
        }
    }

    private func releaseAllLocked() {
        if leftDown {
            postMouse(type: .leftMouseUp, at: lastPoint, button: .left)
            leftDown = false
        }
        if rightDown {
            postMouse(type: .rightMouseUp, at: lastPoint, button: .right)
            rightDown = false
        }
        for keyCode in pressedKeys {
            postKey(keyCode: keyCode, down: false)
        }
        pressedKeys.removeAll()
    }

    // MARK: - Coordinate mapping

    /// Normalised 0...1 inside the streamed picture -> global display points.
    private func normalizedPoint(x: Double?, y: Double?) -> CGPoint? {
        guard let x, let y, x.isFinite, y.isFinite else { return nil }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)
        return CGPoint(x: bounds.minX + CGFloat(clampedX) * bounds.width,
                       y: bounds.minY + CGFloat(clampedY) * bounds.height)
    }

    // MARK: - CGEvent posting

    private var eventSource: CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private func postMouse(type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: eventSource,
                                  mouseType: type,
                                  mouseCursorPosition: point,
                                  mouseButton: button) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postScroll(deltaX: Double, deltaY: Double) {
        let wheelY = Self.clampedWheelValue(deltaY)
        let wheelX = Self.clampedWheelValue(deltaX)
        guard wheelX != 0 || wheelY != 0 else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: eventSource,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: wheelY,
                                  wheel2: wheelX,
                                  wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postKey(keyCode: UInt16, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: eventSource,
                                  virtualKey: CGKeyCode(keyCode),
                                  keyDown: down) else { return }
        event.post(tap: .cghidEventTap)
        if down {
            pressedKeys.insert(keyCode)
        } else {
            pressedKeys.remove(keyCode)
        }
    }

    /// Unicode injection for text input. Chunks by Character so surrogate
    /// pairs are never split across events.
    private func postUnicodeText(_ text: String) {
        var units: [UniChar] = []
        for character in text.prefix(256) {
            let characterUnits = Array(String(character).utf16)
            if !units.isEmpty, units.count + characterUnits.count > 20 {
                postUnicodeUnits(units)
                units.removeAll(keepingCapacity: true)
            }
            units.append(contentsOf: characterUnits)
        }
        if !units.isEmpty {
            postUnicodeUnits(units)
        }
    }

    private func postUnicodeUnits(_ units: [UniChar]) {
        guard !units.isEmpty else { return }
        if let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true) {
            units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base)
            }
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) {
            units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base)
            }
            up.post(tap: .cghidEventTap)
        }
    }

    private static func clampedWheelValue(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded()
        let bounded = min(max(rounded, -100_000), 100_000)
        return Int32(bounded)
    }
}
