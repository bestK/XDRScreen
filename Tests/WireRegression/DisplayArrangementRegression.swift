//
//  DisplayArrangementRegression.swift
//  WireRegression
//
//  Regression suite for the explicit primary-display promotion/restore
//  transaction. The controller is driven through an in-memory backend, so no
//  CoreGraphics display-configuration call is made and no display is touched:
//
//    * promotion commits only when both origin moves are accepted; a single
//      failed step cancels the transaction and records no snapshot,
//    * a restore that fails at any step (configure or commit) keeps the
//      snapshot so a later attempt can still restore the arrangement,
//    * a committed restore that does not actually put every online display
//      back, or does not return the main-display flag, is a failure,
//    * a verified restore clears the snapshot and a second call is a no-op.
//
//  The 0.6 s main-display settle check in `promote` is exercised by running the
//  main run loop; nothing here asks WindowServer for anything.
//

import Foundation
import CoreGraphics
@testable import XDRScreenDisplayArrangement

// MARK: - Fake backend

/// In-memory stand-in for the display-configuration API. Origins are only
/// applied on a successful commit, exactly like a real CG transaction, so a
/// cancelled configuration leaves the desktop untouched.
private final class FakeDisplayConfigurationBackend: DisplayConfigurationBackend {

    struct DisplayState {
        var origin: CGPoint
        var size: CGSize
        var online: Bool = true
    }

    private var displays: [CGDirectDisplayID: DisplayState]
    private var currentMain: CGDirectDisplayID
    private var pendingOrigins: [CGDirectDisplayID: CGPoint] = [:]

    /// Injected failures. `configureErrors` is keyed per display.
    var beginError: CGError = .success
    var completeError: CGError = .success
    var configureErrors: [CGDirectDisplayID: CGError] = [:]

    /// When true, a committed configuration recomputes the main display from
    /// the display sitting at the global origin, mirroring WindowServer.
    var deriveMainFromOrigin = true

    private(set) var beginCount = 0
    private(set) var completeCount = 0
    private(set) var cancelCount = 0
    private(set) var configureCalls: [(id: CGDirectDisplayID, origin: CGPoint)] = []

    init(displays: [CGDirectDisplayID: DisplayState],
         main: CGDirectDisplayID) {
        self.displays = displays
        self.currentMain = main
    }

    // MARK: Inspection / fixture control

    func origin(of displayID: CGDirectDisplayID) -> CGPoint? {
        displays[displayID]?.origin
    }

    func setOnline(_ online: Bool, for displayID: CGDirectDisplayID) {
        displays[displayID]?.online = online
    }

    func setMain(_ displayID: CGDirectDisplayID) {
        currentMain = displayID
    }

    var beganTransactions: Int { beginCount }

    // MARK: DisplayConfigurationBackend

    func onlineDisplayIDs() -> [CGDirectDisplayID] {
        displays.filter { $0.value.online }.keys.sorted()
    }

    func isOnline(_ displayID: CGDirectDisplayID) -> Bool {
        displays[displayID]?.online ?? false
    }

    func bounds(of displayID: CGDirectDisplayID) -> CGRect? {
        guard let display = displays[displayID], display.online else { return nil }
        return CGRect(origin: display.origin, size: display.size)
    }

    func mainDisplayID() -> CGDirectDisplayID {
        currentMain
    }

    func isMain(_ displayID: CGDirectDisplayID) -> Bool {
        currentMain == displayID && isOnline(displayID)
    }

    func beginConfiguration() -> (CGError, DisplayConfigurationSession?) {
        beginCount += 1
        guard beginError == .success else { return (beginError, nil) }
        pendingOrigins = [:]
        return (.success, DisplayConfigurationSession(raw: nil))
    }

    func configureOrigin(_ session: DisplayConfigurationSession,
                         displayID: CGDirectDisplayID,
                         origin: CGPoint) -> CGError {
        configureCalls.append((id: displayID, origin: origin))
        if let error = configureErrors[displayID] { return error }
        pendingOrigins[displayID] = origin
        return .success
    }

    func completeConfiguration(_ session: DisplayConfigurationSession) -> CGError {
        completeCount += 1
        guard completeError == .success else {
            pendingOrigins = [:]
            return completeError
        }
        for (id, origin) in pendingOrigins where displays[id]?.online == true {
            displays[id]?.origin = origin
        }
        if deriveMainFromOrigin,
           let main = displays
            .filter({ $0.value.online && $0.value.origin == .zero })
            .keys
            .sorted()
            .first {
            currentMain = main
        }
        pendingOrigins = [:]
        return .success
    }

    func cancelConfiguration(_ session: DisplayConfigurationSession) {
        cancelCount += 1
        pendingOrigins = [:]
    }
}

// MARK: - Fixtures

private let physicalID: CGDirectDisplayID = 1
private let virtualID: CGDirectDisplayID = 99

/// Physical main display at the origin, virtual display to its right.
private func makeBackend() -> FakeDisplayConfigurationBackend {
    FakeDisplayConfigurationBackend(
        displays: [
            physicalID: .init(origin: .zero, size: CGSize(width: 1920, height: 1080)),
            virtualID: .init(origin: CGPoint(x: 1920, y: 0), size: CGSize(width: 1366, height: 1024))
        ],
        main: physicalID
    )
}

private func pumpMainQueue(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@discardableResult
private func runPromotion(_ controller: DisplayArrangementController)
    -> Result<Void, DisplaySetupError>? {
    var result: Result<Void, DisplaySetupError>?
    controller.promote(virtualDisplayID: virtualID,
                       pointWidth: 1366,
                       pointHeight: 1024) { result = $0 }
    // The completion is delivered after the 0.6 s main-display settle check.
    pumpMainQueue(1.2)
    return result
}

private func isSuccess(_ result: Result<Void, DisplaySetupError>?) -> Bool {
    if case .success? = result { return true }
    return false
}

private func describe(_ result: Result<Void, DisplaySetupError>?) -> String {
    switch result {
    case .success?: return "success"
    case .failure(let error)?: return error.message
    case nil: return "completion never fired"
    }
}

// MARK: - Tests

func testDisplayArrangementTransactions(_ report: Report) {
    print("\n[Display arrangement] promotion and restore transactions")

    // 1. Both moves accepted: one committed configuration, virtual is primary.
    do {
        let backend = makeBackend()
        let controller = DisplayArrangementController(backend: backend)
        let result = runPromotion(controller)

        report.check(isSuccess(result), "promotion commits when both origin moves are accepted",
                     describe(result))
        report.equal(backend.completeCount, 1, "promotion commits exactly one configuration")
        report.equal(backend.cancelCount, 0, "a successful promotion never cancels")
        report.check(backend.origin(of: physicalID) == CGPoint(x: 1366, y: 0),
                     "the old main display is moved right of the virtual display",
                     "got \(String(describing: backend.origin(of: physicalID)))")
        report.check(backend.origin(of: virtualID) == .zero,
                     "the virtual display is moved to the old main origin",
                     "got \(String(describing: backend.origin(of: virtualID)))")
        report.check(controller.isPromoted, "a committed promotion records its snapshot")
        report.check(backend.isMain(virtualID), "the virtual display is primary after promotion")
    }

    // 2. Second move rejected: the first move must not be committed.
    do {
        let backend = makeBackend()
        backend.configureErrors[virtualID] = .failure
        let controller = DisplayArrangementController(backend: backend)
        let result = runPromotion(controller)

        report.check(!isSuccess(result), "a rejected virtual-display move fails promotion")
        report.equal(backend.completeCount, 0, "no configuration is committed when one step fails")
        report.equal(backend.cancelCount, 1, "the partial configuration is cancelled")
        report.check(backend.origin(of: physicalID) == .zero,
                     "the old main display is not moved by a partial transaction",
                     "got \(String(describing: backend.origin(of: physicalID)))")
        report.check(backend.origin(of: virtualID) == CGPoint(x: 1920, y: 0),
                     "the virtual display is not moved by a partial transaction",
                     "got \(String(describing: backend.origin(of: virtualID)))")
        report.check(!controller.isPromoted, "a failed promotion records no snapshot")
        report.check(controller.restoreIfNeeded(), "restore is a no-op after a failed promotion")
        report.equal(backend.beginCount, 1,
                     "no restore transaction is started without a saved snapshot")
    }

    // 3. First move rejected: same all-or-nothing rule.
    do {
        let backend = makeBackend()
        backend.configureErrors[physicalID] = .failure
        let controller = DisplayArrangementController(backend: backend)
        let result = runPromotion(controller)

        report.check(!isSuccess(result), "a rejected main-display move fails promotion")
        report.equal(backend.completeCount, 0, "no configuration is committed when the first step fails")
        report.equal(backend.cancelCount, 1, "the failed configuration is cancelled")
        report.check(backend.origin(of: physicalID) == .zero, "the old main display stays put")
        report.check(backend.origin(of: virtualID) == CGPoint(x: 1920, y: 0),
                     "the virtual display stays put")
        report.check(!controller.isPromoted, "a promotion that began but failed records no snapshot")
    }

    // 4. Rejected begin: nothing is attempted.
    do {
        let backend = makeBackend()
        backend.beginError = .invalidContext
        let controller = DisplayArrangementController(backend: backend)
        let result = runPromotion(controller)

        report.check(!isSuccess(result), "a rejected configuration request fails promotion")
        report.equal(backend.completeCount, 0, "a rejected begin never commits")
        report.equal(backend.cancelCount, 0, "a rejected begin has no session to cancel")
        report.equal(backend.configureCalls.count, 0, "a rejected begin configures no display")
        report.check(!controller.isPromoted, "a rejected begin records no snapshot")
    }

    // 5. Successful restore clears the snapshot and a second call is a no-op.
    do {
        let backend = makeBackend()
        let controller = DisplayArrangementController(backend: backend)
        runPromotion(controller)

        report.check(controller.restoreIfNeeded(), "restore succeeds after a successful promotion")
        report.check(!controller.isPromoted, "a verified restore clears the promotion state")
        report.equal(backend.cancelCount, 0, "a successful restore never cancels")
        report.check(backend.origin(of: physicalID) == .zero,
                     "the original main display returns to its origin",
                     "got \(String(describing: backend.origin(of: physicalID)))")
        report.check(backend.origin(of: virtualID) == CGPoint(x: 1920, y: 0),
                     "the virtual display returns to its saved origin",
                     "got \(String(describing: backend.origin(of: virtualID)))")
        report.check(backend.isMain(physicalID), "the original main display is primary again")

        let beginsAfterRestore = backend.beginCount
        report.check(controller.restoreIfNeeded(), "a second restore reports success")
        report.equal(backend.beginCount, beginsAfterRestore,
                     "a cleared snapshot starts no new transaction")
    }

    // 6. A configure step fails during restore: no commit, snapshot retained.
    do {
        let backend = makeBackend()
        let controller = DisplayArrangementController(backend: backend)
        runPromotion(controller)
        let completesAfterPromotion = backend.completeCount

        backend.configureErrors[virtualID] = .failure
        report.check(!controller.restoreIfNeeded(), "a failed restore step reports failure")
        report.check(controller.isPromoted, "a failed restore keeps the snapshot for a retry")
        report.equal(backend.completeCount, completesAfterPromotion,
                     "a failed restore does not commit a partial transaction")
        report.equal(backend.cancelCount, 1, "a failed restore cancels the transaction")
        report.check(backend.origin(of: physicalID) == CGPoint(x: 1366, y: 0),
                     "a failed restore leaves the arrangement untouched",
                     "got \(String(describing: backend.origin(of: physicalID)))")

        backend.configureErrors.removeValue(forKey: virtualID)
        report.check(controller.restoreIfNeeded(), "the retained snapshot can be restored on a retry")
        report.check(!controller.isPromoted && backend.isMain(physicalID),
                     "the retry restores the arrangement and clears the snapshot")
        report.check(backend.origin(of: physicalID) == .zero,
                     "the retry puts the original main display back at its origin")
    }

    // 7. Commit fails during restore: snapshot retained, retry succeeds.
    do {
        let backend = makeBackend()
        let controller = DisplayArrangementController(backend: backend)
        runPromotion(controller)

        backend.completeError = .failure
        report.check(!controller.restoreIfNeeded(), "a failed restore commit reports failure")
        report.check(controller.isPromoted, "a failed restore commit keeps the snapshot")
        report.check(backend.origin(of: physicalID) == CGPoint(x: 1366, y: 0),
                     "a failed commit applies no origin changes",
                     "got \(String(describing: backend.origin(of: physicalID)))")

        backend.completeError = .success
        report.check(controller.restoreIfNeeded(), "the snapshot survives a failed commit")
        report.check(!controller.isPromoted, "the successful retry clears the snapshot")
        report.check(backend.isMain(physicalID), "the retry returns the main flag")
    }

    // 8. Positions restored but main flag did not return: still a failure.
    do {
        let backend = makeBackend()
        let controller = DisplayArrangementController(backend: backend)
        runPromotion(controller)

        backend.deriveMainFromOrigin = false
        report.check(!controller.restoreIfNeeded(),
                     "a restore that leaves the wrong display primary reports failure")
        report.check(controller.isPromoted, "a main-display mismatch keeps the snapshot for a retry")
        report.check(backend.origin(of: physicalID) == .zero,
                     "the origin part of the restore was applied",
                     "got \(String(describing: backend.origin(of: physicalID)))")
        report.check(!backend.isMain(physicalID), "the main flag is still on the virtual display")

        backend.deriveMainFromOrigin = true
        report.check(controller.restoreIfNeeded(), "the retained snapshot can fix the main flag")
        report.check(!controller.isPromoted && backend.isMain(physicalID),
                     "the retry clears the snapshot only after the main flag is verified")
    }

    // 9. A saved display going offline must not block restoring the rest.
    do {
        let backend = makeBackend()
        let controller = DisplayArrangementController(backend: backend)
        runPromotion(controller)

        backend.setOnline(false, for: virtualID)
        report.check(controller.restoreIfNeeded(),
                     "restore succeeds while an unrelated saved display is offline")
        report.check(backend.isMain(physicalID), "the online original main display becomes primary")
        report.check(!controller.isPromoted, "an offline display does not leave the snapshot stuck")
    }

    // 10. While a snapshot is still pending, a repeated promotion must not
    //     claim success for a display that is not primary.
    do {
        let backend = makeBackend()
        let controller = DisplayArrangementController(backend: backend)
        runPromotion(controller)

        // Simulate the user changing the primary display by hand while the
        // saved arrangement is still recorded.
        backend.setMain(physicalID)
        let result = runPromotion(controller)
        report.check(!isSuccess(result),
                     "a repeated promotion does not report success while the saved arrangement is pending",
                     describe(result))
        report.check(controller.isPromoted,
                     "the failed repeated promotion keeps the saved arrangement for restore")
        report.equal(backend.completeCount, 1,
                     "a repeated promotion starts no second configuration")
        report.check(controller.restoreIfNeeded(),
                     "the pending arrangement can still be restored afterwards")
        report.check(!controller.isPromoted && backend.isMain(physicalID),
                     "restoring after the refused promotion clears the snapshot")
    }

    // 11. All saved displays offline: report failure and keep the snapshot.
    do {
        let backend = makeBackend()
        let controller = DisplayArrangementController(backend: backend)
        runPromotion(controller)

        backend.setOnline(false, for: physicalID)
        backend.setOnline(false, for: virtualID)
        let beginsBefore = backend.beginCount
        report.check(!controller.restoreIfNeeded(),
                     "restore reports failure when every saved display is offline")
        report.check(controller.isPromoted, "an all-offline restore keeps the snapshot")
        report.equal(backend.beginCount, beginsBefore,
                     "an all-offline restore opens no configuration transaction")

        backend.setOnline(true, for: physicalID)
        backend.setOnline(true, for: virtualID)
        report.check(controller.restoreIfNeeded(),
                     "the snapshot restores once the displays come back online")
        report.check(!controller.isPromoted, "the recovered restore clears the snapshot")
        report.check(backend.isMain(physicalID), "the original main display is primary after recovery")
    }
}
