//
//  VirtualDisplayScheduling.swift
//  WireRegression
//
//  Regression suite for the asynchronous virtual-display HiDPI selection.
//
//  The macOS virtual display is registered on the main queue, so WindowServer
//  only publishes it (and its 2x mode) when the main run loop keeps turning.
//  The historical implementation waited with `Thread.sleep` on the main
//  thread, which starved that run loop: the mode enumeration stayed empty and
//  creation failed. These tests reproduce that scheduling shape with a fake
//  display backend and a simulated main queue:
//
//    * a synchronous sleeping probe on the simulated main queue never sees a
//      mode that is published by that same queue,
//    * the asynchronous selector does see it, because every poll yields,
//    * the search is bounded, one-shot, cancellable, and never applies a mode
//      after cancellation or to another display ID,
//    * only an exact 2x mode (pixels == request, points == half, matching
//      refresh rate) is selected.
//
//  Nothing here creates a virtual display or touches a physical display.
//

import Foundation
import CoreGraphics
import XDRScreenVirtualDisplay

// MARK: - Fake backend

/// In-memory stand-in for CoreGraphics display-mode services. A mode can be
/// made visible only after a block has run on the simulated main queue, which
/// is exactly what WindowServer publication looks like to this code.
final class FakeDisplayModeBackend: HiDPIModeBackend {

    private let lock = NSLock()

    var online = true
    /// When true, `availableModes` reports nothing until `markRunloopRan()`.
    var publishRequiresRunloop = false
    /// When false, setting a mode "succeeds" but the current mode never moves.
    var commitMode = true
    var setSucceeds = true

    private var runloopRan = false
    private var modes: [AvailableDisplayMode] = []
    private var current: VirtualDisplayManager.DisplayModeSnapshot?

    private(set) var enumerateCount = 0
    private(set) var currentModeCount = 0
    private(set) var setCalls: [(mode: AvailableDisplayMode, displayID: CGDirectDisplayID)] = []

    func setModes(_ modes: [AvailableDisplayMode]) {
        lock.lock()
        self.modes = modes
        lock.unlock()
    }

    func setCurrent(_ snapshot: VirtualDisplayManager.DisplayModeSnapshot?) {
        lock.lock()
        current = snapshot
        lock.unlock()
    }

    /// Simulates one turn of the main run loop.
    func markRunloopRan() {
        lock.lock()
        runloopRan = true
        lock.unlock()
    }

    func isOnline(_ displayID: CGDirectDisplayID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }

    func availableModes(for displayID: CGDirectDisplayID) -> [AvailableDisplayMode] {
        lock.lock()
        defer { lock.unlock() }
        enumerateCount += 1
        if publishRequiresRunloop && !runloopRan { return [] }
        return modes
    }

    func setMode(_ mode: AvailableDisplayMode, on displayID: CGDirectDisplayID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        setCalls.append((mode: mode, displayID: displayID))
        guard setSucceeds else { return false }
        if commitMode { current = mode.snapshot }
        return true
    }

    func currentMode(for displayID: CGDirectDisplayID) -> VirtualDisplayManager.DisplayModeSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        currentModeCount += 1
        return current
    }

    var setCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return setCalls.count
    }
}

// MARK: - Fixtures

private let target = HiDPIModeSelector.Target(pixelWidth: 2732, pixelHeight: 2048, refreshRate: 60)

private func mode2x(pixelWidth: Int = 2732,
                    pixelHeight: Int = 2048,
                    refreshRate: Double = 60) -> AvailableDisplayMode {
    AvailableDisplayMode(snapshot: .init(width: pixelWidth / 2,
                                         height: pixelHeight / 2,
                                         pixelWidth: pixelWidth,
                                         pixelHeight: pixelHeight,
                                         refreshRate: refreshRate))
}

/// A 1x mode with the requested *pixel* size (2732x2048 points). Must never be
/// mistaken for the 2x mode.
private func mode1xAtPixelSize() -> AvailableDisplayMode {
    AvailableDisplayMode(snapshot: .init(width: 2732, height: 2048,
                                         pixelWidth: 2732, pixelHeight: 2048,
                                         refreshRate: 60))
}

/// The half-sized logical mode the manager registers (1366x1024 points and
/// pixels). Also not 2x.
private func mode1xAtPointSize() -> AvailableDisplayMode {
    AvailableDisplayMode(snapshot: .init(width: 1366, height: 1024,
                                         pixelWidth: 1366, pixelHeight: 1024,
                                         refreshRate: 60))
}

private func snapshot(_ mode: AvailableDisplayMode) -> VirtualDisplayManager.DisplayModeSnapshot {
    mode.snapshot
}

/// The reconnect reuse decision used by the host: a still-open screen is kept
/// only while its current mode is the exact 2x mode the host created. The host
/// passes the mode it reads back from CoreGraphics, so `nil` (no readable mode)
/// must also fall through to a rebuild.
private func canReuseVirtualDisplay(_ current: VirtualDisplayManager.DisplayModeSnapshot?,
                                    pixelWidth: Int = 2732,
                                    pixelHeight: Int = 2048,
                                    refreshRate: Double = 60) -> Bool {
    guard let current else { return false }
    return VirtualDisplayManager.isTargetHiDPIMode(current,
                                                   pixelWidth: pixelWidth,
                                                   pixelHeight: pixelHeight,
                                                   refreshRate: refreshRate)
}

// MARK: - Legacy shape, kept only for the regression comparison

/// What the old implementation did on the main thread: enumerate, and sleep
/// while nothing matches. Used to prove the scheduling regression, not as a
/// product path.
private func legacySynchronousProbe(backend: FakeDisplayModeBackend,
                                    displayID: CGDirectDisplayID,
                                    target: HiDPIModeSelector.Target,
                                    timeout: TimeInterval) -> VirtualDisplayManager.DisplayModeSnapshot? {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while true {
        if backend.isOnline(displayID) {
            let modes = backend.availableModes(for: displayID)
            if let match = modes.first(where: {
                VirtualDisplayManager.isTargetHiDPIMode($0.snapshot,
                                                        pixelWidth: target.pixelWidth,
                                                        pixelHeight: target.pixelHeight,
                                                        refreshRate: target.refreshRate)
            }) {
                _ = backend.setMode(match, on: displayID)
                return match.snapshot
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now >= deadline { return nil }
        Thread.sleep(forTimeInterval: min(0.02, deadline - now))
    }
}

// MARK: - Tests

func testVirtualDisplayScheduling(_ report: Report) {
    print("\n[Virtual display] asynchronous 2x mode selection")

    let mainSim = DispatchQueue(label: "com.xdrscreen.test.main-sim")

    // 1. The old synchronous-on-main shape cannot observe a mode that the
    //    main queue itself has to publish.
    let legacyBackend = FakeDisplayModeBackend()
    legacyBackend.publishRequiresRunloop = true
    legacyBackend.setModes([mode2x()])

    let legacyStarted = DispatchSemaphore(value: 0)
    let legacyResult = Box<VirtualDisplayManager.DisplayModeSnapshot?>(nil)
    mainSim.async {
        legacyStarted.signal()
        let result = legacySynchronousProbe(backend: legacyBackend,
                                            displayID: 9,
                                            target: target,
                                            timeout: 0.4)
        legacyResult.mutate { $0 = result }
    }
    // Publication needs the run loop; the sleeping probe is holding it.
    mainSim.async { legacyBackend.markRunloopRan() }
    legacyStarted.wait()
    mainSim.sync {}  // drain: probe times out, then the marker runs

    report.check(legacyResult.current == nil,
                 "a synchronous sleep probe on the main queue never observes queue-published modes")
    report.equal(legacyBackend.setCallCount, 0,
                 "the synchronous probe selects nothing (no 1x fallback)")

    // 2. The asynchronous selector succeeds against the same fake: each poll
    //    is a queue hop, so the marker runs and the mode appears.
    let asyncBackend = FakeDisplayModeBackend()
    asyncBackend.publishRequiresRunloop = true
    asyncBackend.setModes([mode2x()])
    let asyncSelector = HiDPIModeSelector(displayID: 9,
                                          target: target,
                                          backend: asyncBackend,
                                          queue: mainSim,
                                          pollInterval: 0.01,
                                          timeout: 1.0,
                                          verifyTimeout: 0.5)
    let asyncDone = DispatchSemaphore(value: 0)
    let asyncOutcome = Box<HiDPIModeSelector.Outcome?>(nil)
    let asyncCompletions = Box(0)
    asyncSelector.start { outcome in
        asyncCompletions.mutate { $0 += 1 }
        asyncOutcome.mutate { $0 = outcome }
        asyncDone.signal()
    }
    mainSim.async { asyncBackend.markRunloopRan() }

    report.check(asyncDone.wait(timeout: .now() + 5) == .success,
                 "asynchronous polling resolves once the main queue runs")
    report.check(asyncOutcome.current == HiDPIModeSelector.Outcome.success(9),
                 "asynchronous polling selects the 2x mode",
                 "got \(String(describing: asyncOutcome.current))")
    report.equal(asyncBackend.setCallCount, 1, "the 2x mode is applied exactly once")
    report.check(asyncBackend.setCalls.first?.mode.snapshot == mode2x().snapshot,
                 "the applied mode is the exact 2x mode")
    report.check(asyncBackend.setCalls.first?.displayID == 9,
                 "the mode is applied only to this manager's display ID")
    report.equal(asyncCompletions.current, 1, "the completion fires exactly once")

    // A cancel after success must not report a second result.
    mainSim.sync { asyncSelector.cancel() }
    mainSim.async {}  // let any late scheduled attempt run
    mainSim.sync {}
    report.equal(asyncCompletions.current, 1, "cancel after success does not re-fire the completion")

    // 3. Distinct 2x only: the pixel-sized 1x mode, the point-sized 1x mode
    //    and a wrong-refresh 2x mode are all rejected.
    let exactBackend = FakeDisplayModeBackend()
    let correct = mode2x()
    // 30 Hz is outside the ±0.5 Hz tolerance the matcher allows.
    let wrongRefresh = mode2x(refreshRate: 30)
    exactBackend.setModes([mode1xAtPixelSize(), mode1xAtPointSize(), wrongRefresh, correct])
    let exactSelector = HiDPIModeSelector(displayID: 42,
                                          target: target,
                                          backend: exactBackend,
                                          queue: mainSim,
                                          pollInterval: 0.01,
                                          timeout: 1.0,
                                          verifyTimeout: 0.5)
    let exactDone = DispatchSemaphore(value: 0)
    let exactOutcome = Box<HiDPIModeSelector.Outcome?>(nil)
    exactSelector.start { outcome in
        exactOutcome.mutate { $0 = outcome }
        exactDone.signal()
    }
    report.check(exactDone.wait(timeout: .now() + 5) == .success,
                 "exact-mode selection resolves")
    report.check(exactOutcome.current == HiDPIModeSelector.Outcome.success(42),
                 "exact-mode selection succeeds on the right display")
    report.equal(exactBackend.setCallCount, 1, "exactly one candidate is applied")
    report.check(exactBackend.setCalls.first?.mode.snapshot == correct.snapshot,
                 "1x-at-pixel-size, 1x-at-point-size and wrong-refresh modes are rejected")

    // Direct matching rules, independent of the scheduler.
    let target27 = mode2x().snapshot
    report.check(VirtualDisplayManager.isTargetHiDPIMode(target27,
                                                         pixelWidth: 2732, pixelHeight: 2048,
                                                         refreshRate: 60),
                 "matching rule accepts 2732x2048px / 1366x1024pt @60")
    report.check(!VirtualDisplayManager.isTargetHiDPIMode(snapshot(mode1xAtPixelSize()),
                                                          pixelWidth: 2732, pixelHeight: 2048,
                                                          refreshRate: 60),
                 "matching rule rejects a 1x mode with the requested pixel size")
    report.check(!VirtualDisplayManager.isTargetHiDPIMode(snapshot(mode1xAtPointSize()),
                                                          pixelWidth: 2732, pixelHeight: 2048,
                                                          refreshRate: 60),
                 "matching rule rejects a 1x mode with the requested point size")
    report.check(!VirtualDisplayManager.isTargetHiDPIMode(snapshot(wrongRefresh),
                                                          pixelWidth: 2732, pixelHeight: 2048,
                                                          refreshRate: 60),
                 "matching rule rejects a 2x mode at the wrong refresh rate")

    // 3b. Reconnect reuse. `HostController.ensureVirtualDisplay` keeps an open
    //     screen across reconnects only when its *current* mode is still the
    //     exact 2x mode at the host refresh rate. Comparing pixels alone would
    //     reuse a screen that the user or the system switched to a 1x mode of
    //     the same 2732x2048 pixel size: the desktop would be 2732x2048 points
    //     and the stream would no longer be the 1366x1024 point Retina layout
    //     the client asked for. Anything else must fall through to the safe
    //     release-and-rebuild path.
    report.check(canReuseVirtualDisplay(mode2x().snapshot),
                 "reuse accepts the exact 2732x2048px / 1366x1024pt @60 mode")
    report.check(!canReuseVirtualDisplay(mode1xAtPixelSize().snapshot),
                 "reuse rejects a same-pixel 1x mode (the bug this guards)")
    report.check(!canReuseVirtualDisplay(mode1xAtPointSize().snapshot),
                 "reuse rejects a same-point 1x mode")
    report.check(!canReuseVirtualDisplay(wrongRefresh.snapshot),
                 "reuse rejects a 2x mode at the wrong refresh rate")
    report.check(!canReuseVirtualDisplay(nil),
                 "reuse rejects a display whose mode cannot be read")

    // 4. Bounded timeout: no 2x mode is ever published.
    let timeoutBackend = FakeDisplayModeBackend()
    timeoutBackend.setModes([mode1xAtPixelSize()])
    let timeoutSelector = HiDPIModeSelector(displayID: 11,
                                            target: target,
                                            backend: timeoutBackend,
                                            queue: mainSim,
                                            pollInterval: 0.01,
                                            timeout: 0.2,
                                            verifyTimeout: 0.2)
    let timeoutDone = DispatchSemaphore(value: 0)
    let timeoutOutcome = Box<HiDPIModeSelector.Outcome?>(nil)
    let timeoutCompletions = Box(0)
    let timeoutStart = ProcessInfo.processInfo.systemUptime
    timeoutSelector.start { outcome in
        timeoutCompletions.mutate { $0 += 1 }
        timeoutOutcome.mutate { $0 = outcome }
        timeoutDone.signal()
    }
    report.check(timeoutDone.wait(timeout: .now() + 5) == .success,
                 "a missing 2x mode resolves instead of hanging")
    let timeoutElapsed = ProcessInfo.processInfo.systemUptime - timeoutStart
    report.check(timeoutElapsed < 2.0, "the timeout stays bounded", "elapsed \(timeoutElapsed)s")
    if case .failure(.timedOut(let observed))? = timeoutOutcome.current {
        report.equal(observed, [mode1xAtPixelSize().snapshot],
                     "the timeout reports the modes it actually saw")
    } else {
        report.check(false, "the timeout reports the observed modes",
                     "got \(String(describing: timeoutOutcome.current))")
    }
    report.equal(timeoutBackend.setCallCount, 0, "nothing is applied when no 2x mode exists")
    Thread.sleep(forTimeInterval: 0.1)
    report.equal(timeoutCompletions.current, 1, "the timeout completion fires exactly once")

    // 4b. A display that never comes online is reported as such, not as a
    //     missing 2x mode: the two failures need different fixes.
    let offlineBackend = FakeDisplayModeBackend()
    offlineBackend.online = false
    offlineBackend.setModes([mode2x()])
    let offlineSelector = HiDPIModeSelector(displayID: 15,
                                            target: target,
                                            backend: offlineBackend,
                                            queue: mainSim,
                                            pollInterval: 0.01,
                                            timeout: 0.15,
                                            verifyTimeout: 0.2)
    let offlineDone = DispatchSemaphore(value: 0)
    let offlineOutcome = Box<HiDPIModeSelector.Outcome?>(nil)
    offlineSelector.start { outcome in
        offlineOutcome.mutate { $0 = outcome }
        offlineDone.signal()
    }
    report.check(offlineDone.wait(timeout: .now() + 5) == .success,
                 "a display that never comes online resolves")
    report.check(offlineOutcome.current == HiDPIModeSelector.Outcome.failure(.displayNeverOnline),
                 "a never-online display is reported distinctly",
                 "got \(String(describing: offlineOutcome.current))")
    report.equal(offlineBackend.setCallCount, 0, "nothing is applied to an offline display")

    // 5. Cancellation: a late publication must not set a mode or call back.
    let cancelBackend = FakeDisplayModeBackend()
    let cancelSelector = HiDPIModeSelector(displayID: 12,
                                           target: target,
                                           backend: cancelBackend,
                                           queue: mainSim,
                                           pollInterval: 0.02,
                                           timeout: 2.0,
                                           verifyTimeout: 0.5)
    let cancelCompletions = Box(0)
    let cancelOutcome = Box<HiDPIModeSelector.Outcome?>(nil)
    cancelSelector.start { outcome in
        cancelCompletions.mutate { $0 += 1 }
        cancelOutcome.mutate { $0 = outcome }
    }
    mainSim.async { cancelSelector.cancel() }
    mainSim.sync {}
    // Publish the 2x mode only after the cancellation.
    cancelBackend.setModes([mode2x()])
    Thread.sleep(forTimeInterval: 0.3)
    report.equal(cancelCompletions.current, 0, "a cancelled search never calls back")
    report.equal(cancelBackend.setCallCount, 0, "a cancelled search never applies a mode")
    report.equal(cancelBackend.currentModeCount, 0, "a cancelled search never verifies a mode")

    // 6. Mode change rejected by the system.
    let rejectBackend = FakeDisplayModeBackend()
    rejectBackend.setModes([mode2x()])
    rejectBackend.setSucceeds = false
    let rejectSelector = HiDPIModeSelector(displayID: 13,
                                           target: target,
                                           backend: rejectBackend,
                                           queue: mainSim,
                                           pollInterval: 0.01,
                                           timeout: 1.0,
                                           verifyTimeout: 0.3)
    let rejectDone = DispatchSemaphore(value: 0)
    let rejectOutcome = Box<HiDPIModeSelector.Outcome?>(nil)
    rejectSelector.start { outcome in
        rejectOutcome.mutate { $0 = outcome }
        rejectDone.signal()
    }
    report.check(rejectDone.wait(timeout: .now() + 5) == .success,
                 "a rejected mode change resolves")
    report.check(rejectOutcome.current == .failure(.setModeRejected),
                 "a rejected mode change reports setModeRejected",
                 "got \(String(describing: rejectOutcome.current))")

    // 7. The mode change is accepted but never commits: verification is
    //    bounded and never claims a 1x desktop as 2x.
    let verifyBackend = FakeDisplayModeBackend()
    verifyBackend.setModes([mode2x()])
    verifyBackend.setCurrent(mode1xAtPixelSize().snapshot)
    verifyBackend.commitMode = false
    let verifySelector = HiDPIModeSelector(displayID: 14,
                                           target: target,
                                           backend: verifyBackend,
                                           queue: mainSim,
                                           pollInterval: 0.01,
                                           timeout: 1.0,
                                           verifyTimeout: 0.2)
    let verifyDone = DispatchSemaphore(value: 0)
    let verifyOutcome = Box<HiDPIModeSelector.Outcome?>(nil)
    let verifyStart = ProcessInfo.processInfo.systemUptime
    verifySelector.start { outcome in
        verifyOutcome.mutate { $0 = outcome }
        verifyDone.signal()
    }
    report.check(verifyDone.wait(timeout: .now() + 5) == .success,
                 "a mode that does not commit resolves")
    let verifyElapsed = ProcessInfo.processInfo.systemUptime - verifyStart
    report.check(verifyElapsed < 2.0, "verification stays bounded", "elapsed \(verifyElapsed)s")
    report.check(verifyOutcome.current == .failure(.verificationTimedOut),
                 "a 1x desktop is never reported as verified 2x",
                 "got \(String(describing: verifyOutcome.current))")
    report.equal(verifyBackend.setCallCount, 1, "the mode is attempted once before verification fails")
}
