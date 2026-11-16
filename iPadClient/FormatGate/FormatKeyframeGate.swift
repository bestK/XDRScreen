//
//  FormatKeyframeGate.swift
//  XDRScreen (iPad client)
//
//  Bounded decision state for the format → first-IDR race.
//
//  Why this exists
//  ---------------
//  The Mac sends a `VideoFormatMessage` and writes the key frame that belongs
//  to it immediately afterwards. Both arrive on the client's serial network
//  queue microseconds apart, but installing the format is main-queue work
//  (`ClientVideoView.applyFormat`). Frames that arrive before the main queue
//  has run are dropped by the renderer because no format is active yet, so the
//  first IDR of every format change is normally lost. A P frame cannot start a
//  prediction chain, and a still Mac screen may not produce another IDR for a
//  long time, so the client must ask for exactly one new IDR *after* the
//  renderer accepted the format.
//
//  This type holds the two generations that identify such a request (the
//  connection and the format), plus the connection/lifecycle state that makes
//  a request pointless. It is a pure value type with no threads, clocks or
//  callbacks: the controller mutates it only on its serial network queue.
//
//  Rules
//  -----
//    * at most one request per format generation ("one-shot"), so repeated
//      callbacks, dropped frames or a stalled renderer cannot spin the
//      control channel;
//    * a ticket from a previous connection or a replaced format is refused,
//      so a late main-queue callback can never send an IDR request into a
//      newer session;
//    * no request while disconnected, suspended or after the renderer turned
//      terminal;
//    * both the Metal and the compatibility renderer need the same post-apply
//      request, so both `applied` outcomes are approved.
//

import Foundation

public struct FormatKeyframeGate {

    /// Identifies the exact session and format an asynchronous apply belongs
    /// to. Values are captured on the network queue when the format message is
    /// received and checked again after the main queue has installed it.
    public struct Ticket: Equatable {
        public let connectionGeneration: Int
        public let formatGeneration: UInt64

        public init(connectionGeneration: Int, formatGeneration: UInt64) {
            self.connectionGeneration = connectionGeneration
            self.formatGeneration = formatGeneration
        }
    }

    /// What the main queue reported after trying to install the format.
    public enum ApplyOutcome: Equatable {
        /// The preferred (Metal/EDR) renderer accepted the format.
        case applied
        /// The compatibility `AVSampleBufferDisplayLayer` renderer accepted it
        /// after a fallback. It starts with no reference frames as well.
        case appliedByFallback
        /// No renderer accepted the format; no decoder can consume an IDR.
        case rejected
    }

    public enum Decision: Equatable {
        /// Send one key-frame request now.
        case request
        /// The apply belongs to an older connection or a replaced format.
        case ignoreStale
        /// The renderer proved it cannot present this format.
        case ignoreTerminal
        /// The connection is gone.
        case ignoreDisconnected
        /// The app is backgrounded.
        case ignoreSuspended
        /// The renderer rejected the format.
        case ignoreRejected
        /// This format generation already requested its one IDR.
        case ignoreAlreadyRequested
    }

    /// Monotonic per-format token; never reused, also not across connections.
    public private(set) var formatGeneration: UInt64 = 0
    public private(set) var connectionGeneration = 0
    public private(set) var isConnected = false
    public private(set) var isSuspended = false
    public private(set) var isTerminal = false
    public private(set) var hasRequestedForCurrentFormat = false

    public init() {}

    /// A new connection owns the gate. Called once per connection attempt.
    public mutating func connectionDidStart(_ generation: Int) {
        connectionGeneration = generation
        isConnected = true
        // A connection can only begin while the app is in the foreground.
        isSuspended = false
        isTerminal = false
        hasRequestedForCurrentFormat = false
    }

    /// The connection is being torn down (failure, disconnect, background,
    /// reconnect). Any apply callback still in flight becomes stale.
    public mutating func connectionDidEnd() {
        isConnected = false
        hasRequestedForCurrentFormat = false
    }

    public mutating func appDidSuspend() {
        isSuspended = true
    }

    public mutating func appDidResume() {
        isSuspended = false
    }

    /// Neither renderer can present the current format. The caller stops the
    /// connection as well; this only closes the window before it does.
    public mutating func rendererBecameTerminal() {
        isTerminal = true
    }

    /// A new, already validated format was accepted from the host. Returns the
    /// ticket to pass back with the apply result from the main queue.
    public mutating func beginFormat() -> Ticket {
        formatGeneration &+= 1
        isTerminal = false
        hasRequestedForCurrentFormat = false
        return Ticket(
            connectionGeneration: connectionGeneration,
            formatGeneration: formatGeneration
        )
    }

    /// Decides whether the apply callback may send the one post-install IDR
    /// request. Mutating: `.request` consumes the one-shot budget.
    public mutating func decide(_ ticket: Ticket, outcome: ApplyOutcome) -> Decision {
        guard ticket.connectionGeneration == connectionGeneration,
              ticket.formatGeneration == formatGeneration else {
            return .ignoreStale
        }
        guard !isTerminal else { return .ignoreTerminal }
        guard isConnected else { return .ignoreDisconnected }
        guard !isSuspended else { return .ignoreSuspended }
        guard outcome != .rejected else { return .ignoreRejected }
        guard !hasRequestedForCurrentFormat else { return .ignoreAlreadyRequested }
        hasRequestedForCurrentFormat = true
        return .request
    }
}
