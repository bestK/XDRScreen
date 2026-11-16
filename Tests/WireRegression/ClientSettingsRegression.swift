//
//  ClientSettingsRegression.swift
//  WireRegression
//
//  Regression coverage for the additive `clientSettings` message: stable kind
//  numbering, the optional `bitrateMbps` field, unknown-field tolerance and
//  the 4–200 Mbps clamp used by both peers.
//

import Foundation
import XDRScreenWire

func testClientSettings(_ report: Report) {
    print("\n[?] Client settings message")

    report.check(MessageKind.clientSettings.rawValue == 8,
                 "clientSettings kind byte is 8")
    report.check(MessageKind(rawValue: 1) == .hello
                 && MessageKind(rawValue: 7) == .requestKeyframe,
                 "existing kind bytes are unchanged")

    // nil = follow the host's quality tier. WireJSON keeps the historical
    // keyed-JSON shape and simply omits the optional field.
    do {
        let follow = ClientSettingsMessage(bitrateMbps: nil)
        let data = try WireJSON.encode(follow)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        report.check(object?.isEmpty == true,
                     "nil bitrate encodes as an empty object without new keys",
                     "json: \(String(data: data, encoding: .utf8) ?? "?")")
        report.equal(try WireJSON.decode(ClientSettingsMessage.self, from: data), follow,
                     "nil bitrate round trips through WireJSON")
    } catch {
        report.check(false, "nil client settings encoding", "\(error)")
    }

    // Non-nil values survive the round trip.
    do {
        let message = ClientSettingsMessage(bitrateMbps: 50)
        let decoded = try WireJSON.decode(ClientSettingsMessage.self, from: try WireJSON.encode(message))
        report.equal(decoded, message, "non-nil bitrate round trips through WireJSON")
        report.equal(decoded.bitrateMbps, 50, "decoded value is the requested Mbps")
    } catch {
        report.check(false, "non-nil client settings round trip", "\(error)")
    }

    // Missing field decodes as nil, so an older client or a hand-written
    // payload can still announce "follow the host".
    do {
        let decoded = try WireJSON.decode(ClientSettingsMessage.self, from: Data("{}".utf8))
        report.check(decoded.bitrateMbps == nil, "missing bitrateMbps decodes as nil")
    } catch {
        report.check(false, "empty JSON client settings", "\(error)")
    }

    // Unknown fields are ignored rather than rejected, keeping the JSON
    // encoding forward compatible.
    do {
        let payload = Data(#"{"bitrateMbps":30,"futureField":"ignored","nested":{"x":1}}"#.utf8)
        let decoded = try WireJSON.decode(ClientSettingsMessage.self, from: payload)
        report.equal(decoded.bitrateMbps, 30, "unknown fields are ignored")
    } catch {
        report.check(false, "unknown fields in client settings", "\(error)")
    }

    // A wrong value type is invalid, not fatal: callers use `try?` and ignore
    // it. The decoder must throw rather than crash.
    let wrongType = Data(#"{"bitrateMbps":"fast"}"#.utf8)
    report.check((try? WireJSON.decode(ClientSettingsMessage.self, from: wrongType)) == nil,
                 "a non-integer bitrate is rejected without crashing")

    // Range clamp used by the host before it touches the encoder.
    report.equal(ClientSettingsMessage.minBitrateMbps, 4, "manual floor is 4 Mbps")
    report.equal(ClientSettingsMessage.maxBitrateMbps, 200, "manual ceiling is 200 Mbps")
    report.equal(ClientSettingsMessage.clampMbps(-5), 4, "negative request clamps to the floor")
    report.equal(ClientSettingsMessage.clampMbps(0), 4, "zero request clamps to the floor")
    report.equal(ClientSettingsMessage.clampMbps(4), 4, "floor is accepted unchanged")
    report.equal(ClientSettingsMessage.clampMbps(120), 120, "mid-range value is unchanged")
    report.equal(ClientSettingsMessage.clampMbps(200), 200, "ceiling is accepted unchanged")
    report.equal(ClientSettingsMessage.clampMbps(999), 200, "oversized request clamps to the ceiling")
    report.equal(ClientSettingsMessage.clampMbps(Int.max), 200, "Int.max clamps without overflowing")
    report.equal(ClientSettingsMessage.clampMbps(Int.min), 4, "Int.min clamps without overflowing")

    report.check(ClientSettingsMessage(bitrateMbps: nil).clampedBitrateMbps == nil,
                 "nil stays nil after clamping")
    report.equal(ClientSettingsMessage(bitrateMbps: 1).clampedBitrateMbps, 4,
                 "payload clamp raises a below-floor request")
    report.equal(ClientSettingsMessage(bitrateMbps: 500).clampedBitrateMbps, 200,
                 "payload clamp lowers an above-ceiling request")
    report.equal(ClientSettingsMessage(bitrateMbps: 30).clampedBitrateMbps, 30,
                 "payload clamp keeps an in-range request")

    // The new kind is a normal authenticated payload: sealing and opening it
    // through the sequenced envelope works exactly like the older kinds.
    do {
        let key = makeKey()
        let message = ClientSettingsMessage(bitrateMbps: 80)
        let payload = try WireJSON.encode(message)
        let body = try WireCrypto.sealSequencedBody(
            kind: .clientSettings,
            sequence: 0,
            payload: payload,
            key: key
        )
        let packet = try WireCrypto.openSequencedBody(body, key: key, expectedSequence: 0)
        report.equal(packet.kind, .clientSettings, "clientSettings survives the sealed envelope")
        report.equal(try WireJSON.decode(ClientSettingsMessage.self, from: packet.payload), message,
                     "clientSettings payload survives the sealed envelope")
    } catch {
        report.check(false, "client settings sealed round trip", "\(error)")
    }
}
