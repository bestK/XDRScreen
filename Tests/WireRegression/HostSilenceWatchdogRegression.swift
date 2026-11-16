//
//  HostSilenceWatchdogRegression.swift
//  WireRegression
//
//  Regression suite for the client's half-open connection detector.
//
//  The iPad client pings every three seconds, but a successful send only means
//  the bytes reached the kernel send buffer. On a half-open link (Mac asleep,
//  AP dropping frames, dead NAT mapping) no RST/FIN ever arrives, TCP keepalive
//  never fires because the client keeps writing, and the picture freezes while
//  the app still believes it is streaming. The client therefore times silence
//  from the last *authenticated packet of any kind* on a monotonic clock, and
//  fails the session after 15 s so the existing backoff reconnect can run.
//
//  Nothing here uses a device, a socket or a renderer: the watchdog is pure
//  state and the test drives it directly.
//

import Foundation
import XDRScreenClientState

func testHostSilenceWatchdog(_ report: Report) {
    print("\nHalf-open connection watchdog")

    // 0. The threshold sits in the required 15–20 s window and a watchdog that
    //    was never armed (connecting/handshaking/background) never fires.
    let defaults = HostSilenceWatchdog()
    report.check(
        defaults.timeout >= 15 && defaults.timeout <= 20,
        "silence timeout is 15–20 s",
        "got \(defaults.timeout)")
    report.check(
        !defaults.isSilent(generation: 1, at: 1_000),
        "an unarmed watchdog never reports silence")
    report.check(
        !defaults.isArmed,
        "a fresh watchdog is unarmed")

    // 1. No host packet at all past the threshold. The controller turns this
    //    into failConnectionLocked, which closes the socket and retries with
    //    the ordinary backoff — no repair prompt.
    var zero = HostSilenceWatchdog()
    zero.begin(generation: 3, at: 100)
    report.check(
        !zero.isSilent(generation: 3, at: 114.999),
        "just below the threshold the session is still trusted")
    report.check(
        zero.isSilent(generation: 3, at: 115),
        "15 s without any host packet fails the session")
    report.check(
        zero.isSilent(generation: 3, at: 130),
        "silence stays detected until the connection is replaced")

    // 2. A still Mac screen with normal ping echoes stays connected: the echo
    //    is an authenticated packet and refreshes the clock every 3 s.
    var still = HostSilenceWatchdog()
    still.begin(generation: 4, at: 0)
    var everSilent = false
    for tick in stride(from: 3.0, through: 90.0, by: 3.0) {
        still.observe(generation: 4, at: tick)
        everSilent = everSilent || still.isSilent(generation: 4, at: tick + 2.9)
    }
    report.check(
        !everSilent,
        "ping echoes keep a static screen connected")

    // 3. Any valid authenticated packet refreshes the clock — status, format
    //    and video frames, not just pings. A dropped frame or a busy host that
    //    still answers is never mistaken for a dead link.
    var mixed = HostSilenceWatchdog()
    mixed.begin(generation: 5, at: 10)
    mixed.observe(generation: 5, at: 22)
    report.check(
        !mixed.isSilent(generation: 5, at: 30),
        "a status packet refreshes the clock")
    mixed.observe(generation: 5, at: 31)
    report.check(
        !mixed.isSilent(generation: 5, at: 44),
        "a video-format packet refreshes the clock")
    mixed.observe(generation: 5, at: 44)
    report.check(
        !mixed.isSilent(generation: 5, at: 58),
        "a video frame refreshes the clock")
    report.check(
        mixed.isSilent(generation: 5, at: 59),
        "silence is still detected once real traffic stops")

    // 4. A late tick or packet from the previous generation can neither keep
    //    the new session alive nor fail it.
    var generations = HostSilenceWatchdog()
    generations.begin(generation: 1, at: 0)
    generations.stop()
    generations.begin(generation: 2, at: 200)
    report.check(
        !generations.observe(generation: 1, at: 300),
        "a packet from the old generation is ignored")
    report.check(
        !generations.isSilent(generation: 1, at: 400),
        "a tick from the old generation cannot fail the new session")
    report.check(
        !generations.isSilent(generation: 2, at: 214.9),
        "the new session keeps its own clock")
    report.check(
        generations.isSilent(generation: 2, at: 215),
        "the new session expires on its own schedule")

    // 5. Background, manual disconnect and sessions that never completed the
    //    handshake are disabled: stop() clears the arming, so a timer tick
    //    that already fired cannot fail an unrelated state.
    var lifecycle = HostSilenceWatchdog()
    lifecycle.begin(generation: 8, at: 50)
    lifecycle.stop()
    report.check(
        !lifecycle.isSilent(generation: 8, at: 1_000),
        "a stopped watchdog never fires")
    report.check(
        !lifecycle.observe(generation: 8, at: 1_000),
        "packets are ignored after the watchdog is stopped")
    let unstarted = HostSilenceWatchdog()
    report.check(
        !unstarted.isSilent(generation: 9, at: 1_000),
        "no timing before the authenticated handshake completes")

    // 6. Only the supplied monotonic uptime matters. A wall-clock change (or a
    //    backwards jump) can neither trip the watchdog nor delay it.
    var monotonic = HostSilenceWatchdog()
    monotonic.begin(generation: 10, at: 5_000)
    report.check(
        !monotonic.isSilent(generation: 10, at: 4_000),
        "a backwards reading cannot trip the watchdog")
    monotonic.observe(generation: 10, at: 5_010)
    report.check(
        !monotonic.isSilent(generation: 10, at: 5_024.9),
        "elapsed time is measured from the last packet")
    report.check(
        monotonic.isSilent(generation: 10, at: 5_025),
        "the last packet is the reference, not the start time")
}
