import Foundation

/// Bounded liveness state for one authenticated client session.
///
/// The client pings every three seconds, but a ping send "succeeding" only
/// means the bytes entered the kernel send buffer. On a half-open link (Mac
/// asleep, Wi-Fi AP dropping frames, NAT mapping gone) no RST/FIN ever arrives
/// and TCP keepalive never fires because the client keeps writing. The only
/// reliable evidence that the peer is alive is a packet that arrived and
/// authenticated.
///
/// This type is pure value state: no clock, no threads, no callbacks. The
/// controller mutates it on its serial network queue and feeds it a monotonic
/// uptime (`ProcessInfo.processInfo.systemUptime`), so changing the wall clock
/// cannot arm or disarm the watchdog.
public struct HostSilenceWatchdog {

    /// 15 s matches the host's own idle timeout. Five ping periods fit inside
    /// it, so a single lost echo (or a busy encoder) never trips it.
    public static let defaultTimeout: TimeInterval = 15

    public let timeout: TimeInterval

    /// The session this watchdog belongs to. A packet or tick from any other
    /// generation is ignored, so a callback left over from the previous
    /// connection can never keep a new session alive or fail it.
    private var armedGeneration: Int?
    /// Last authenticated host packet, or the moment the handshake completed.
    private var lastActivityUptime: TimeInterval?

    public init(timeout: TimeInterval = HostSilenceWatchdog.defaultTimeout) {
        self.timeout = timeout
    }

    public var isArmed: Bool { armedGeneration != nil }

    /// Arms the watchdog for `generation`. Nothing is timed before the
    /// authenticated handshake completes, so connecting/handshaking states are
    /// never judged by this clock.
    public mutating func begin(generation: Int, at uptime: TimeInterval) {
        armedGeneration = generation
        lastActivityUptime = uptime
    }

    /// Records a valid authenticated packet from the host (video frame, IDR
    /// request reply, status, ping echo — any of them proves the peer is
    /// alive). Returns `false` when the packet belongs to an older session and
    /// was therefore ignored.
    @discardableResult
    public mutating func observe(generation: Int, at uptime: TimeInterval) -> Bool {
        guard armedGeneration == generation else { return false }
        lastActivityUptime = uptime
        return true
    }

    /// True only for the armed generation once a full `timeout` has elapsed
    /// without any host packet. A stopped, unarmed or foreign generation is
    /// never reported silent.
    public func isSilent(generation: Int, at uptime: TimeInterval) -> Bool {
        guard armedGeneration == generation, let lastActivityUptime else { return false }
        return uptime - lastActivityUptime >= timeout
    }

    /// Disarms. Called when the connection ends, the app is backgrounded or the
    /// user disconnects; a timer tick that fires afterwards cannot fail the
    /// session.
    public mutating func stop() {
        armedGeneration = nil
        lastActivityUptime = nil
    }
}
