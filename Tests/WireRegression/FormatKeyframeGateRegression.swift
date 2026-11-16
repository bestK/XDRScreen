//
//  FormatKeyframeGateRegression.swift
//  WireRegression
//
//  Regression suite for the client's format -> first-IDR race.
//
//  The Mac writes a format message and the key frame that belongs to it back to
//  back. The client installs formats on the main queue, so frames that arrive
//  before that apply are dropped and the first key frame is lost. The gate must
//  approve exactly one fresh IDR request after the format is installed, for the
//  exact connection+format generation, and must stay silent when disconnected,
//  suspended or terminal.
//
//  Nothing here uses a device, a network connection or a renderer: the gate is
//  pure state and the test drives it directly.
//

import Foundation
import XDRScreenClientState

func testFormatKeyframeGate(_ report: Report) {
    print("\nFormat / first-IDR race gate")

    // 1. The host's first IDR is dropped while the format is still waiting on
    //    the main queue. Once the apply lands, exactly one request is approved.
    var gate = FormatKeyframeGate()
    gate.connectionDidStart(7)
    let first = gate.beginFormat()
    report.equal(
        first,
        FormatKeyframeGate.Ticket(connectionGeneration: 7, formatGeneration: 1),
        "the ticket binds the connection and format generations")
    report.equal(
        gate.decide(first, outcome: .applied),
        .request,
        "installing the format requests the IDR that was dropped before it")
    report.equal(
        gate.decide(first, outcome: .applied),
        .ignoreAlreadyRequested,
        "a repeated apply callback cannot request a second IDR")

    // The one-shot bound is what keeps a stalled renderer from spinning the
    // control channel: every further report for this format is a no-op.
    var repeats = 0
    for _ in 0..<100 {
        if gate.decide(first, outcome: .applied) == .request { repeats += 1 }
    }
    report.equal(repeats, 0, "100 late reports for one format add no requests")

    // 2. The compatibility renderer starts without reference frames too, so
    //    the fallback path needs the same post-install request.
    var fallback = FormatKeyframeGate()
    fallback.connectionDidStart(1)
    let layerTicket = fallback.beginFormat()
    report.equal(
        fallback.decide(layerTicket, outcome: .appliedByFallback),
        .request,
        "the layer fallback also requests one fresh IDR")
    report.equal(
        fallback.decide(layerTicket, outcome: .applied),
        .ignoreAlreadyRequested,
        "a late Metal report cannot duplicate the fallback request")

    // 3. A format no renderer accepted must not consume an IDR request.
    var rejected = FormatKeyframeGate()
    rejected.connectionDidStart(1)
    let rejectedTicket = rejected.beginFormat()
    report.equal(
        rejected.decide(rejectedTicket, outcome: .rejected),
        .ignoreRejected,
        "a rejected format requests nothing")
    report.equal(
        rejected.decide(rejectedTicket, outcome: .applied),
        .request,
        "a later accepted apply for the same format is still allowed")

    // 4. An apply callback from the previous connection must not touch the new
    //    session: the new session still gets its own request.
    var session = FormatKeyframeGate()
    session.connectionDidStart(1)
    let oldConnectionTicket = session.beginFormat()
    session.connectionDidEnd()
    session.connectionDidStart(2)
    let newConnectionTicket = session.beginFormat()
    report.check(
        oldConnectionTicket != newConnectionTicket,
        "a reconnect produces a different ticket")
    report.equal(
        session.decide(oldConnectionTicket, outcome: .applied),
        .ignoreStale,
        "a late apply from the old connection is ignored")
    report.equal(
        session.decide(newConnectionTicket, outcome: .applied),
        .request,
        "the new connection still requests its own key frame")

    // 5. A replaced format inside the same connection is stale as well.
    let newFormatTicket = session.beginFormat()
    report.equal(
        session.decide(newConnectionTicket, outcome: .applied),
        .ignoreStale,
        "an apply for the previous format is ignored")
    report.equal(
        session.decide(newFormatTicket, outcome: .applied),
        .request,
        "the current format gets the request")
    report.equal(
        session.decide(newFormatTicket, outcome: .appliedByFallback),
        .ignoreAlreadyRequested,
        "the generation, not the renderer, owns the one-shot budget")

    // 6. Disconnect, background and terminal renderers stop requests. None of
    //    these paths can schedule a retry: there is no timer and no queue.
    var offline = FormatKeyframeGate()
    offline.connectionDidStart(3)
    let offlineTicket = offline.beginFormat()
    offline.connectionDidEnd()
    report.equal(
        offline.decide(offlineTicket, outcome: .applied),
        .ignoreDisconnected,
        "a disconnected session requests nothing")

    var background = FormatKeyframeGate()
    background.connectionDidStart(4)
    let backgroundTicket = background.beginFormat()
    background.appDidSuspend()
    report.equal(
        background.decide(backgroundTicket, outcome: .applied),
        .ignoreSuspended,
        "a backgrounded app requests nothing")
    background.appDidResume()
    report.equal(
        background.decide(backgroundTicket, outcome: .applied),
        .request,
        "resuming the same session allows the pending request")

    var terminal = FormatKeyframeGate()
    terminal.connectionDidStart(5)
    let terminalTicket = terminal.beginFormat()
    terminal.rendererBecameTerminal()
    report.equal(
        terminal.decide(terminalTicket, outcome: .applied),
        .ignoreTerminal,
        "a terminal renderer requests nothing")
    let nextFormat = terminal.beginFormat()
    report.equal(
        terminal.decide(nextFormat, outcome: .applied),
        .request,
        "a new format clears the terminal state")

    // 7. A stale ticket never consumes the current format's budget.
    var budget = FormatKeyframeGate()
    budget.connectionDidStart(6)
    let current = budget.beginFormat()
    let stale = FormatKeyframeGate.Ticket(
        connectionGeneration: 5,
        formatGeneration: current.formatGeneration)
    _ = budget.decide(stale, outcome: .applied)
    report.equal(
        budget.decide(current, outcome: .applied),
        .request,
        "a stale callback does not spend the current generation's request")
}
