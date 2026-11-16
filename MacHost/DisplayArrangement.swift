//
//  DisplayArrangement.swift
//  XDRScreen Mac host
//
//  Saves and restores the physical display arrangement while the user
//  explicitly promotes the iPad virtual display to primary. Uses only public
//  CoreGraphics display-configuration APIs.
//
//  Nothing here runs automatically. The default host mode mirrors the current
//  main display and never touches the arrangement, so windows on the TV are
//  never moved behind the user's back.
//
//  Both directions are all-or-nothing transactions:
//
//  * promotion only commits when *both* the old main display and the virtual
//    display were accepted into the same configuration; a single failed step
//    cancels the transaction instead of leaving a half-moved desktop,
//  * the saved arrangement is cleared only after the restore has committed and
//    WindowServer actually shows every online display back at its saved origin
//    and the saved main display is primary again. Any failure keeps the
//    snapshot so the user can retry.
//

import Foundation
import CoreGraphics

/// Simple message-only error shared by the display setup helpers.
struct DisplaySetupError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One in-flight `CGBeginDisplayConfiguration` transaction. The token is opaque
/// to the controller; only the backend that created it interprets it.
final class DisplayConfigurationSession {
    fileprivate let raw: CGDisplayConfigRef?
    init(raw: CGDisplayConfigRef?) { self.raw = raw }
}

/// Seam over the CoreGraphics display-configuration calls used by
/// `DisplayArrangementController`. The production implementation talks to
/// WindowServer; tests substitute an in-memory fake so the transaction rules
/// can be exercised without touching real displays.
protocol DisplayConfigurationBackend: AnyObject {
    func onlineDisplayIDs() -> [CGDirectDisplayID]
    func isOnline(_ displayID: CGDirectDisplayID) -> Bool
    func bounds(of displayID: CGDirectDisplayID) -> CGRect?
    func mainDisplayID() -> CGDirectDisplayID
    func isMain(_ displayID: CGDirectDisplayID) -> Bool

    /// Starts a configuration transaction. Returns the error together with a
    /// token when the system accepted the request.
    func beginConfiguration() -> (CGError, DisplayConfigurationSession?)
    func configureOrigin(_ session: DisplayConfigurationSession,
                         displayID: CGDirectDisplayID,
                         origin: CGPoint) -> CGError
    func completeConfiguration(_ session: DisplayConfigurationSession) -> CGError
    func cancelConfiguration(_ session: DisplayConfigurationSession)
}

/// Production backend. Every call goes straight to the public CoreGraphics
/// display-configuration API.
final class CoreGraphicsDisplayBackend: DisplayConfigurationBackend {

    func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var real: UInt32 = 0
        guard CGGetOnlineDisplayList(count, &ids, &real) == .success else { return [] }
        return Array(ids.prefix(Int(real)))
    }

    func isOnline(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(displayID) != 0
    }

    func bounds(of displayID: CGDirectDisplayID) -> CGRect? {
        guard isOnline(displayID) else { return nil }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    func mainDisplayID() -> CGDirectDisplayID {
        CGMainDisplayID()
    }

    func isMain(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsMain(displayID) != 0
    }

    func beginConfiguration() -> (CGError, DisplayConfigurationSession?) {
        var config: CGDisplayConfigRef?
        let error = CGBeginDisplayConfiguration(&config)
        guard error == .success, let config else { return (error, nil) }
        return (.success, DisplayConfigurationSession(raw: config))
    }

    func configureOrigin(_ session: DisplayConfigurationSession,
                         displayID: CGDirectDisplayID,
                         origin: CGPoint) -> CGError {
        guard let raw = session.raw else { return .invalidContext }
        return CGConfigureDisplayOrigin(raw,
                                        displayID,
                                        Int32(origin.x.rounded()),
                                        Int32(origin.y.rounded()))
    }

    func completeConfiguration(_ session: DisplayConfigurationSession) -> CGError {
        guard let raw = session.raw else { return .invalidContext }
        return CGCompleteDisplayConfiguration(raw, CGConfigureOption())
    }

    func cancelConfiguration(_ session: DisplayConfigurationSession) {
        guard let raw = session.raw else { return }
        CGCancelDisplayConfiguration(raw)
    }
}

final class DisplayArrangementController {

    /// Called with human-readable status; never contains secrets.
    var onMessage: ((String) -> Void)?

    private(set) var isPromoted = false

    private struct Snapshot {
        /// Global display origins in points, keyed by display ID.
        var origins: [CGDirectDisplayID: CGPoint]
        var mainDisplayID: CGDirectDisplayID
    }

    private var snapshot: Snapshot?
    private let backend: DisplayConfigurationBackend

    init(backend: DisplayConfigurationBackend = CoreGraphicsDisplayBackend()) {
        self.backend = backend
    }

    // MARK: - Public API

    /// Makes `virtualDisplayID` the primary display by putting it at the
    /// previous main display's origin and moving the previous main to the
    /// right. The arrangement is applied for this app's lifetime so macOS
    /// reverts it automatically if the app crashes; `restoreIfNeeded` also
    /// restores it explicitly on switch/exit.
    ///
    /// `completion` is always called on the main queue.
    func promote(virtualDisplayID: CGDirectDisplayID,
                 pointWidth: CGFloat,
                 pointHeight: CGFloat,
                 completion: @escaping (Result<Void, DisplaySetupError>) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.promote(virtualDisplayID: virtualDisplayID,
                             pointWidth: pointWidth,
                             pointHeight: pointHeight,
                             completion: completion)
            }
            return
        }

        guard !isPromoted else {
            // A saved arrangement is still pending. Only report success when
            // this display really is primary; otherwise the caller would be
            // told a promotion happened while the old snapshot is unrestored.
            if backend.isMain(virtualDisplayID) {
                completion(.success(()))
            } else {
                completion(.failure(DisplaySetupError("上一次的显示器排列尚未完全恢复；请先恢复原排列，再设为主屏。")))
            }
            return
        }

        guard let current = captureArrangement() else {
            completion(.failure(DisplaySetupError("无法读取当前显示器排列。")))
            return
        }

        guard current.mainDisplayID != virtualDisplayID else {
            snapshot = current
            isPromoted = true
            completion(.success(()))
            return
        }

        guard let virtualBounds = bounds(of: virtualDisplayID), virtualBounds.width > 0,
              let mainBounds = current.origins[current.mainDisplayID] else {
            completion(.failure(DisplaySetupError("无法读取显示器位置，未修改排列。")))
            return
        }

        let targetX = Int32(mainBounds.x.rounded())
        let targetY = Int32(mainBounds.y.rounded())
        // Move the old main to the right of the virtual display, then put the
        // virtual display where the old main was. Its origin (0,0 in the usual
        // case) is what macOS treats as the primary display.
        let displacedX = targetX + Int32(pointWidth.rounded())

        let (beginError, session) = backend.beginConfiguration()
        guard beginError == .success, let session else {
            completion(.failure(DisplaySetupError("系统拒绝了显示器配置请求（CGError \(beginError.rawValue)）。")))
            return
        }

        // Promoting requires both moves. A configuration that contains only
        // one of them would move a real screen without ever making the iPad
        // primary, so cancel rather than commit a partial transaction.
        let movedMain = backend.configureOrigin(session,
                                                displayID: current.mainDisplayID,
                                                origin: CGPoint(x: CGFloat(displacedX), y: CGFloat(targetY)))
        guard movedMain == .success else {
            backend.cancelConfiguration(session)
            completion(.failure(DisplaySetupError("无法移动原主显示器（CGError \(movedMain.rawValue)）；未修改显示器排列。")))
            return
        }

        let movedVirtual = backend.configureOrigin(session,
                                                   displayID: virtualDisplayID,
                                                   origin: CGPoint(x: CGFloat(targetX), y: CGFloat(targetY)))
        guard movedVirtual == .success else {
            backend.cancelConfiguration(session)
            completion(.failure(DisplaySetupError("无法把 iPad 专用屏移到主屏位置（CGError \(movedVirtual.rawValue)）；未修改显示器排列。")))
            return
        }

        let completed = backend.completeConfiguration(session)
        guard completed == .success else {
            // A failed commit applies nothing, so no snapshot is recorded.
            completion(.failure(DisplaySetupError("应用显示器排列失败（CGError \(completed.rawValue)），未改动桌面。")))
            return
        }

        snapshot = current
        isPromoted = true

        // WindowServer applies the configuration synchronously, but allow one
        // short turn for the main-display flag to settle before deciding that
        // this macOS build refuses to move the menu bar programmatically.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // The virtual display may have been released while the check was
            // pending (mode switch, host stop). Never touch a stale ID.
            guard self.backend.isOnline(virtualDisplayID) else {
                let restored = self.restoreIfNeeded()
                completion(.failure(DisplaySetupError(restored
                    ? "iPad 专用屏已释放，原显示器排列已恢复。"
                    : "iPad 专用屏已释放，但未能恢复原显示器排列；原排列已保留，可重试恢复。")))
                return
            }
            if self.backend.isMain(virtualDisplayID) {
                self.onMessage?("已将 iPad 专用屏设为主显示器")
                completion(.success(()))
                return
            }
            let restored = self.restoreIfNeeded()
            completion(.failure(DisplaySetupError(restored
                ? "系统没有把 iPad 专用屏设为主屏，已恢复原排列。请在“系统设置 › 显示器”中手动拖动菜单栏到 iPad 屏。"
                : "系统没有把 iPad 专用屏设为主屏，且恢复原排列失败；原排列已保留，可重试恢复。请在“系统设置 › 显示器”中手动调整。")))
        }
    }

    /// Restores the arrangement captured by the most recent successful
    /// promotion. Safe to call when nothing was promoted (returns true).
    ///
    /// The snapshot is kept until the restore has committed and been verified,
    /// so a failed attempt can be retried without losing the only record of
    /// where the displays used to be.
    @discardableResult
    func restoreIfNeeded() -> Bool {
        guard Thread.isMainThread else {
            var result = false
            DispatchQueue.main.sync { result = self.restoreIfNeeded() }
            return result
        }

        guard isPromoted, let snapshot else { return true }

        let online = Set(backend.onlineDisplayIDs())
        let targets = snapshot.origins.filter { online.contains($0.key) }
        guard !targets.isEmpty else {
            onMessage?("原显示器均已离线，暂时无法恢复排列；已保留原排列供稍后重试")
            return false
        }

        let (beginError, session) = backend.beginConfiguration()
        guard beginError == .success, let session else {
            onMessage?("无法开始恢复显示器排列（CGError \(beginError.rawValue)）；已保留原排列供稍后重试")
            return false
        }

        // All-or-nothing: one display that cannot be put back aborts the whole
        // transaction. Committing the rest would leave a half-restored desktop
        // while claiming success.
        for (id, origin) in targets {
            let error = backend.configureOrigin(session, displayID: id, origin: origin)
            guard error == .success else {
                backend.cancelConfiguration(session)
                onMessage?("恢复显示器排列失败（CGError \(error.rawValue)）；未提交任何更改，已保留原排列供稍后重试")
                return false
            }
        }

        let completed = backend.completeConfiguration(session)
        guard completed == .success else {
            onMessage?("应用原显示器排列失败（CGError \(completed.rawValue)），已保留原排列供稍后重试")
            return false
        }

        // A committed configuration is not proof of the outcome: check what
        // WindowServer actually reports before dropping the snapshot.
        var unplaced: [CGDirectDisplayID] = []
        for (id, origin) in targets where backend.isOnline(id) {
            guard let current = backend.bounds(of: id) else {
                unplaced.append(id)
                continue
            }
            if abs(current.minX - origin.x) > 1 || abs(current.minY - origin.y) > 1 {
                unplaced.append(id)
            }
        }
        let mainWasOnline = online.contains(snapshot.mainDisplayID)
        let mainRestored = !mainWasOnline || backend.isMain(snapshot.mainDisplayID)

        guard unplaced.isEmpty, mainRestored else {
            var problems: [String] = []
            if !unplaced.isEmpty { problems.append("\(unplaced.count) 台显示器未回到原位置") }
            if !mainRestored { problems.append("主显示器标志未回到原屏幕") }
            onMessage?("原排列未能完全恢复（\(problems.joined(separator: "，"))）；已保留快照，可重试")
            return false
        }

        isPromoted = false
        self.snapshot = nil

        let offlineCount = snapshot.origins.keys.filter { !online.contains($0) }.count
        if offlineCount > 0 {
            onMessage?("已恢复原显示器排列（\(offlineCount) 台离线显示器将在重新连接后由系统放置）")
        } else {
            onMessage?("已恢复原显示器排列")
        }
        return true
    }

    // MARK: - Helpers

    private func captureArrangement() -> Snapshot? {
        let ids = backend.onlineDisplayIDs()
        guard !ids.isEmpty else { return nil }
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        for id in ids {
            origins[id] = bounds(of: id)?.origin
        }
        return Snapshot(origins: origins, mainDisplayID: backend.mainDisplayID())
    }

    private func bounds(of displayID: CGDirectDisplayID) -> CGRect? {
        guard backend.isOnline(displayID) else { return nil }
        return backend.bounds(of: displayID)
    }
}
