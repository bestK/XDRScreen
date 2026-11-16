//
//  main.swift
//  WireRegression
//
//  Local regression suite for Shared/Wire.swift. No external dependencies.
//
//      swift run --package-path . WireRegression
//
//  Covers the JSON messages, the AES-GCM framing round trip, tamper rejection,
//  invalid length / type rejection, the video frame timestamp byte order, the
//  symmetric handshake / HKDF key derivation, per-direction sequence numbers,
//  same-session and cross-session replay rejection, a tampered handshake, the
//  ready contract, and real loopback SecureChannel sessions (ordering, chunk
//  boundaries, completions, authentication failure closing the connection).
//

import CryptoKit
import Foundation
import Network
import XDRScreenWire

// MARK: - Tiny test harness

final class Report {
    private(set) var passed = 0
    private(set) var skipped = 0
    private(set) var failures: [String] = []

    func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            print("  PASS  \(label)")
        } else {
            let extra = detail()
            failures.append(label + (extra.isEmpty ? "" : " — " + extra))
            print("  FAIL  \(label)\(extra.isEmpty ? "" : " — " + extra)")
        }
    }

    func equal<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
        check(lhs == rhs, label, "expected \(rhs), got \(lhs)")
    }

    func skip(_ label: String, _ reason: String) {
        skipped += 1
        print("  SKIP  \(label) — \(reason)")
    }
}

final class Box<Value> {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    var current: Value {
        mutate { $0 }
    }
}

func expectThrows(
    _ report: Report,
    _ label: String,
    _ expected: WireError,
    _ body: () throws -> Void
) {
    do {
        try body()
        report.check(false, label, "expected \(expected), nothing was thrown")
    } catch let error as WireError {
        report.check(error == expected, label, "expected \(expected), got \(error)")
    } catch {
        report.check(false, label, "expected \(expected), got \(error)")
    }
}

func makeKey() -> SymmetricKey {
    SymmetricKey(size: .bits256)
}

// MARK: - JSON messages

func testMessages(_ report: Report) {
    print("\n[1] JSON message round trips")

    let hello = HelloMessage(
        protocolVersion: Wire.protocolVersion,
        width: 3456,
        height: 2234,
        maxFPS: 60,
        supportsHDR: true,
        deviceName: "Mac Studio"
    )
    do {
        let data = try WireJSON.encode(hello)
        let decoded = try WireJSON.decode(HelloMessage.self, from: data)
        report.equal(decoded, hello, "hello encodes and decodes unchanged")
        report.check(decoded.protocolVersion == Wire.protocolVersion, "hello carries protocol version \(Wire.protocolVersion)")
    } catch {
        report.check(false, "hello JSON round trip", "\(error)")
    }

    let format = VideoFormatMessage(
        width: 3456,
        height: 2234,
        fps: 60,
        hdr: true,
        vps: Data([0x40, 0x01, 0x0C]),
        sps: Data([0x42, 0x01, 0x01]),
        pps: Data([0x44, 0x01, 0xC0]),
        colorPrimaries: "ITU_R_2020",
        transferFunction: "ITU_R_2100_HLG",
        yCbCrMatrix: "ITU_R_2020_NCL"
    )
    do {
        let decoded = try WireJSON.decode(VideoFormatMessage.self, from: try WireJSON.encode(format))
        report.equal(decoded, format, "videoFormat keeps parameter sets and color tags")
    } catch {
        report.check(false, "videoFormat JSON round trip", "\(error)")
    }

    let input = InputMessage(type: "tap", x: 0.25, y: 0.75, deltaX: nil, deltaY: nil, text: nil, keyCode: nil)
    do {
        let decoded = try WireJSON.decode(InputMessage.self, from: try WireJSON.encode(input))
        report.equal(decoded, input, "input message keeps optional fields")
    } catch {
        report.check(false, "input JSON round trip", "\(error)")
    }

    do {
        let status = StatusMessage(message: "waiting for display")
        report.equal(try WireJSON.decode(StatusMessage.self, from: try WireJSON.encode(status)), status, "status message round trip")
    } catch {
        report.check(false, "status JSON round trip", "\(error)")
    }
}

// MARK: - Framing and crypto

func testCrypto(_ report: Report) {
    print("\n[2] AES-GCM framing")
    let key = makeKey()
    let payload = Data("hello frame".utf8)

    do {
        let frame = try WireCrypto.sealFrame(kind: .hello, payload: payload, key: key)
        report.equal(Int(frame.prefix(4).reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) }), frame.count - 4, "length prefix excludes itself")

        let opened = try WireCrypto.openFrame(frame, key: key)
        report.equal(opened.kind, .hello, "round trip keeps the message kind")
        report.equal(opened.payload, payload, "round trip keeps the payload")
        report.equal(frame.count - 4, 12 + payload.count + 1 + 16, "body is nonce + type + payload + tag")

        let second = try WireCrypto.sealFrame(kind: .hello, payload: payload, key: key)
        report.check(frame != second, "each seal uses a fresh random nonce")
    } catch {
        report.check(false, "seal/open round trip", "\(error)")
    }

    do {
        let body = try WireCrypto.sealBody(kind: .videoFrame, payload: Data(repeating: 0x5A, count: 4096), key: key)
        let plaintextMarker = Data(repeating: 0x5A, count: 16)
        report.check(body.range(of: plaintextMarker) == nil, "ciphertext does not contain plaintext")
    } catch {
        report.check(false, "ciphertext confidentiality", "\(error)")
    }

    // Empty payloads are legal and must survive.
    do {
        let frame = try WireCrypto.sealFrame(kind: .ping, payload: Data(), key: key)
        let opened = try WireCrypto.openFrame(frame, key: key)
        report.check(opened.kind == .ping && opened.payload.isEmpty, "empty payload round trip")
    } catch {
        report.check(false, "empty payload round trip", "\(error)")
    }

    // Wrong key.
    do {
        let frame = try WireCrypto.sealFrame(kind: .input, payload: payload, key: key)
        expectThrows(report, "a different 256-bit key is rejected", .authenticationFailed) {
            _ = try WireCrypto.openFrame(frame, key: makeKey())
        }
    } catch {
        report.check(false, "wrong key setup", "\(error)")
    }

    // Non 256-bit key is refused instead of silently downgrading to AES-128.
    expectThrows(report, "128-bit key is refused", .invalidKeySize(128)) {
        _ = try WireCrypto.sealFrame(kind: .ping, payload: Data(), key: SymmetricKey(size: .bits128))
    }
}

func testTampering(_ report: Report) {
    print("\n[3] Tamper rejection")
    let key = makeKey()
    let payload = Data("tamper me".utf8)

    guard let frame = try? WireCrypto.sealFrame(kind: .videoFrame, payload: payload, key: key) else {
        report.check(false, "tamper fixture", "seal failed")
        return
    }

    func tampered(byteOffsetFromEnd offset: Int) -> Data {
        var bytes = [UInt8](frame)
        bytes[bytes.count - 1 - offset] ^= 0x01
        return Data(bytes)
    }

    expectThrows(report, "flipped tag byte is rejected", .authenticationFailed) {
        _ = try WireCrypto.openFrame(tampered(byteOffsetFromEnd: 0), key: key)
    }
    expectThrows(report, "flipped last ciphertext byte is rejected", .authenticationFailed) {
        _ = try WireCrypto.openFrame(tampered(byteOffsetFromEnd: 16), key: key)
    }
    expectThrows(report, "flipped first ciphertext byte is rejected", .authenticationFailed) {
        _ = try WireCrypto.openFrame(tampered(byteOffsetFromEnd: 16 + payload.count - 1), key: key)
    }
    expectThrows(report, "flipped nonce byte is rejected", .authenticationFailed) {
        _ = try WireCrypto.openFrame(tampered(byteOffsetFromEnd: frame.count - 5), key: key)
    }
    expectThrows(report, "body truncated below the envelope size is rejected", .invalidBodyLength(20)) {
        let body = Data([UInt8](frame.dropFirst(4)).prefix(20))
        _ = try WireCrypto.openBody(body, key: key)
    }
    expectThrows(report, "body with its last byte chopped off fails authentication", .authenticationFailed) {
        let body = Data([UInt8](frame.dropFirst(4)).dropLast())
        _ = try WireCrypto.openBody(body, key: key)
    }
}

func testInvalidFrames(_ report: Report) {
    print("\n[4] Invalid length and message type")
    let key = makeKey()

    expectThrows(report, "body shorter than nonce+type+tag is rejected", .invalidBodyLength(Wire.minBodyBytes - 1)) {
        _ = try WireCrypto.openBody(Data(repeating: 0, count: Wire.minBodyBytes - 1), key: key)
    }

    // 16 MiB + 1 length prefix.
    var oversized = Data([0x01, 0x00, 0x00, 0x01])
    oversized.append(Data(repeating: 0, count: 32))
    expectThrows(report, "length prefix above 16 MiB is rejected", .invalidBodyLength(Wire.maxPacketBodyBytes + 1)) {
        _ = try WireCrypto.openFrame(oversized, key: key)
    }

    // Zero length.
    expectThrows(report, "zero length prefix is rejected", .invalidBodyLength(0)) {
        _ = try WireCrypto.openFrame(Data([0, 0, 0, 0]), key: key)
    }

    // A valid seal whose kind byte is not in MessageKind.
    do {
        var plaintext = Data([0x7F])
        plaintext.append(Data("rogue".utf8))
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            report.check(false, "unknown kind fixture", "no combined data")
            return
        }
        expectThrows(report, "unknown message kind byte is rejected", .invalidMessageKind(0x7F)) {
            _ = try WireCrypto.openBody(combined, key: key)
        }
        report.check(MessageKind(rawValue: 0x07) == .requestKeyframe && MessageKind(rawValue: 0x08) == nil,
                     "message kind numbering is fixed")
    } catch {
        report.check(false, "unknown kind fixture", "\(error)")
    }

    // Oversized send is refused before allocating the sealed body.
    let tooBig = Data(count: Wire.maxPacketBodyBytes - WireCrypto.envelopeOverhead + 1)
    expectThrows(report, "payload above the 16 MiB body limit is refused", .payloadTooLarge(Wire.maxPacketBodyBytes + 1)) {
        _ = try WireCrypto.sealBody(kind: .videoFrame, payload: tooBig, key: key)
    }
}

func testVideoFramePayload(_ report: Report) {
    print("\n[5] Video frame payload")

    let timestamp: UInt64 = 0x0102_0304_0506_0708
    let encoded = VideoFramePayload.encode(keyframe: true, timestampUs: timestamp, data: Data([0xAA, 0xBB]))

    report.equal(
        Data(encoded.prefix(9)),
        Data([0x01, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
        "flags then big-endian timestamp microseconds"
    )
    report.equal(encoded.count, 9 + 2, "header is 1 + 8 bytes and data follows")

    let decoded = VideoFramePayload.decode(encoded)
    report.check(decoded?.keyframe == true, "keyframe flag survives")
    report.check(decoded?.timestampUs == timestamp, "timestamp survives", "got \(String(describing: decoded?.timestampUs))")
    report.check(decoded?.data == Data([0xAA, 0xBB]), "AVCC bytes survive")

    let littleEndianRead = VideoFramePayload.decode(encoded).map { _ in
        Data(encoded[1..<9]).reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    report.check(littleEndianRead != timestamp, "timestamp is not little-endian")

    let nonKey = VideoFramePayload.encode(keyframe: false, timestampUs: 1, data: Data())
    report.check(VideoFramePayload.decode(nonKey)?.keyframe == false, "delta frame flag is clear")

    // Data slices keep a non-zero startIndex; decode must not assume 0.
    let padded = Data([0xFF]) + encoded
    let slice = padded.dropFirst()
    report.check(VideoFramePayload.decode(slice)?.data == Data([0xAA, 0xBB]), "decodes Data slices with non-zero start index")

    report.check(VideoFramePayload.decode(Data([0x01, 0x02])) == nil, "short payload is rejected")
    report.check(VideoFramePayload.decode(Data()) == nil, "empty payload is rejected")
    report.check(VideoFramePayload.maxDataBytes + WireCrypto.envelopeOverhead + 9 == Wire.maxPacketBodyBytes,
                 "max video data fills the body budget")
}

// MARK: - Loopback channel

struct ListenerFixture {
    let listener: NWListener
    let port: UInt16
    let serverChannels: Box<[SecureChannel]>
    let serverPackets: Box<[WirePacket]>
}

func startListener(
    key: SymmetricKey,
    queue: DispatchQueue,
    onChannel: ((SecureChannel) -> Void)? = nil,
    onPacket: @escaping (SecureChannel, WirePacket) -> Void
) -> ListenerFixture? {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

    guard let listener = try? NWListener(using: parameters) else { return nil }

    let channels = Box<[SecureChannel]>([])
    let packets = Box<[WirePacket]>([])
    let ready = DispatchSemaphore(value: 0)
    let port = Box<UInt16>(0)

    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            port.mutate { $0 = listener.port?.rawValue ?? 0 }
            ready.signal()
        case .failed:
            ready.signal()
        default:
            break
        }
    }
    listener.newConnectionHandler = { connection in
        let channel = SecureChannel(connection: connection, key: key, queue: queue)
        channel.onPacket = { [weak channel] packet in
            packets.mutate { $0.append(packet) }
            if let channel { onPacket(channel, packet) }
        }
        channels.mutate { $0.append(channel) }
        onChannel?(channel)
        channel.start()
    }
    listener.start(queue: queue)

    guard ready.wait(timeout: .now() + 5) == .success, port.current != 0 else {
        listener.cancel()
        return nil
    }
    return ListenerFixture(listener: listener, port: port.current, serverChannels: channels, serverPackets: packets)
}

func testLoopbackEcho(_ report: Report) {
    print("\n[6] Loopback SecureChannel (echo, ordering, chunking, completions)")
    let key = makeKey()
    let listenerQueue = DispatchQueue(label: "xdrscreen.test.listener")
    let clientQueue = DispatchQueue(label: "xdrscreen.test.client")

    guard let fixture = startListener(key: key, queue: listenerQueue, onPacket: { channel, packet in
        channel.send(packet.kind, payload: packet.payload, completion: nil)
    }) else {
        report.skip("loopback echo", "could not bind a loopback listener (local network permission or sandbox)")
        return
    }
    defer { fixture.listener.cancel() }

    guard let endpointPort = NWEndpoint.Port(rawValue: fixture.port) else {
        report.check(false, "loopback port", "invalid port \(fixture.port)")
        return
    }
    let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
    let client = SecureChannel(connection: connection, key: key, queue: clientQueue)

    var payloads: [Data] = []
    for index in 0..<25 {
        var sequence = UInt32(index).bigEndian
        var payload = Data(bytes: &sequence, count: 4)
        payload.append(Data(repeating: UInt8(index & 0xFF), count: 1024))
        payloads.append(payload)
    }
    // Larger than one receive chunk, exercises framing across NWConnection splits.
    payloads.append(Data(repeating: 0xAB, count: 2 * 1024 * 1024))

    let echoes = Box<[WirePacket]>([])
    let echoedAll = DispatchSemaphore(value: 0)
    client.onPacket = { packet in
        let count = echoes.mutate { list -> Int in
            list.append(packet)
            return list.count
        }
        if count == payloads.count { echoedAll.signal() }
    }

    // Sends are issued before `start()` on purpose: the channel must start the
    // socket itself and still deliver everything in order.
    let completions = Box<(count: Int, errors: [String])>((0, []))
    for payload in payloads {
        client.send(.videoFrame, payload: payload) { error in
            completions.mutate { state in
                state.count += 1
                if let error { state.errors.append(String(describing: error)) }
            }
        }
    }
    client.start()

    let echoed = echoedAll.wait(timeout: .now() + 15) == .success
    report.check(echoed, "all \(payloads.count) messages echoed within 15 s",
                 "received \(echoes.current.count)")

    let received = echoes.current
    report.check(received.count == payloads.count, "no duplicated or dropped packets",
                 "expected \(payloads.count), got \(received.count)")
    if received.count == payloads.count {
        report.check(zip(received, payloads).allSatisfy { $0.kind == .videoFrame && $0.payload == $1 },
                     "payloads arrive intact and in order")
    }

    let completionState = completions.current
    report.check(completionState.count == payloads.count, "every send completion fires exactly once",
                 "expected \(payloads.count), got \(completionState.count)")
    report.check(completionState.errors.isEmpty, "no send errors",
                 completionState.errors.joined(separator: "; "))

    // Sending after close must report an error instead of silently dropping.
    let closedCompletion = DispatchSemaphore(value: 0)
    let closedError = Box<String?>(nil)
    client.close()
    client.send(.ping, payload: Data(), completion: { error in
        closedError.mutate { $0 = error.map { String(describing: $0) } }
        closedCompletion.signal()
    })
    report.check(closedCompletion.wait(timeout: .now() + 5) == .success, "post-close send completes")
    report.check(closedError.current != nil, "post-close send reports an error", "completion was nil")
}

func testLoopbackAuthenticationFailure(_ report: Report) {
    print("\n[7] Loopback authentication failure closes the receiver")
    let goodKey = makeKey()
    let badKey = makeKey()
    let listenerQueue = DispatchQueue(label: "xdrscreen.test.auth.listener")
    let clientQueue = DispatchQueue(label: "xdrscreen.test.auth.client")

    let serverClosed = DispatchSemaphore(value: 0)

    guard let fixture = startListener(
        key: goodKey,
        queue: listenerQueue,
        onChannel: { channel in
            channel.onState = { state in
                switch state {
                case .failed, .cancelled:
                    serverClosed.signal()
                default:
                    break
                }
            }
        },
        onPacket: { channel, packet in
            channel.send(packet.kind, payload: packet.payload, completion: nil)
        }
    ) else {
        report.skip("authentication failure", "could not bind a loopback listener")
        return
    }
    defer { fixture.listener.cancel() }

    guard let endpointPort = NWEndpoint.Port(rawValue: fixture.port) else {
        report.check(false, "auth loopback port", "invalid port")
        return
    }

    let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
    let attacker = SecureChannel(connection: connection, key: badKey, queue: clientQueue)
    attacker.start()
    attacker.send(.input, payload: Data("{\"type\":\"tap\"}".utf8), completion: nil)

    let closed = serverClosed.wait(timeout: .now() + 10) == .success
    report.check(closed, "server closes the connection after a failed authentication")
    report.check(fixture.serverPackets.current.isEmpty, "no unauthenticated packet is delivered",
                 "\(fixture.serverPackets.current.count) packets delivered")
    attacker.close()
}

// MARK: - Session handshake crypto

func rawKeyBytes(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

func expectSessionThrows(
    _ report: Report,
    _ label: String,
    _ expected: WireSessionError,
    _ body: () throws -> Void
) {
    do {
        try body()
        report.check(false, label, "expected \(expected), nothing was thrown")
    } catch let error as WireSessionError {
        report.check(error == expected, label, "expected \(expected), got \(error)")
    } catch {
        report.check(false, label, "expected \(expected), got \(error)")
    }
}

func testHandshakeCrypto(_ report: Report) {
    print("\n[8] Handshake authentication and HKDF session keys")
    let psk = makeKey()
    let a = WireCrypto.randomChallenge()
    let b = WireCrypto.randomChallenge()
    let c = WireCrypto.randomChallenge()

    report.equal(a.count, Wire.challengeByteCount, "challenge is 32 bytes")
    report.check(a != b && b != c, "each challenge is a fresh random value")

    do {
        let frame = try WireCrypto.handshakeFrame(challenge: a, preSharedKey: psk)
        report.equal(frame.count, 4 + Wire.handshakeBodyBytes, "handshake is length prefix + 73-byte body")
        report.equal(
            Int(frame.prefix(4).reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) }),
            Wire.handshakeBodyBytes,
            "handshake length prefix is exactly the fixed body size"
        )
        report.equal(
            try WireCrypto.openHandshakeFrame(frame, preSharedKey: psk),
            a,
            "peer verifies the HMAC and recovers the challenge"
        )
        report.check(frame.range(of: rawKeyBytes(psk)) == nil, "the pre-shared key never appears on the wire")

        var tamperedMAC = Data([UInt8](frame))
        tamperedMAC[tamperedMAC.count - 1] ^= 0x01
        expectSessionThrows(report, "corrupted handshake HMAC is rejected", .handshakeAuthenticationFailed) {
            _ = try WireCrypto.openHandshakeFrame(tamperedMAC, preSharedKey: psk)
        }

        var tamperedChallenge = Data([UInt8](frame))
        tamperedChallenge[4 + 8 + 1 + 7] ^= 0x01
        expectSessionThrows(report, "corrupted handshake challenge is rejected", .handshakeAuthenticationFailed) {
            _ = try WireCrypto.openHandshakeFrame(tamperedChallenge, preSharedKey: psk)
        }

        var badVersion = Data([UInt8](frame))
        badVersion[4 + 8] = 9
        expectSessionThrows(report, "unsupported handshake version is rejected", .handshakeVersionMismatch(9)) {
            _ = try WireCrypto.openHandshakeFrame(badVersion, preSharedKey: psk)
        }

        var badPrefix = Data([UInt8](frame))
        badPrefix[4] ^= 0xFF
        expectSessionThrows(report, "corrupted handshake prefix is rejected", .handshakeMalformed) {
            _ = try WireCrypto.openHandshakeFrame(badPrefix, preSharedKey: psk)
        }

        expectSessionThrows(report, "a different pre-shared key is rejected", .handshakeAuthenticationFailed) {
            _ = try WireCrypto.openHandshakeFrame(frame, preSharedKey: makeKey())
        }
        expectSessionThrows(report, "a short handshake body is rejected", .handshakeMalformed) {
            _ = try WireCrypto.openHandshakeBody(Data([UInt8](frame.dropFirst(4)).dropLast()), preSharedKey: psk)
        }
    } catch {
        report.check(false, "handshake fixture", "\(error)")
    }

    do {
        let keysA = try WireCrypto.deriveSessionKeys(preSharedKey: psk, ownChallenge: a, peerChallenge: b)
        let keysB = try WireCrypto.deriveSessionKeys(preSharedKey: psk, ownChallenge: b, peerChallenge: a)
        report.equal(rawKeyBytes(keysA.outbound), rawKeyBytes(keysB.inbound), "swapping sides swaps keys: A out == B in")
        report.equal(rawKeyBytes(keysA.inbound), rawKeyBytes(keysB.outbound), "swapping sides swaps keys: A in == B out")
        report.check(rawKeyBytes(keysA.outbound) != rawKeyBytes(keysA.inbound), "each direction gets a distinct key")
        report.check(rawKeyBytes(keysA.outbound) != rawKeyBytes(psk), "the session key is not the pre-shared key")
        report.equal(rawKeyBytes(keysA.outbound).count, 32, "derived key is 32 bytes")

        let again = try WireCrypto.deriveSessionKeys(preSharedKey: psk, ownChallenge: a, peerChallenge: b)
        report.equal(rawKeyBytes(again.outbound), rawKeyBytes(keysA.outbound), "HKDF derivation is deterministic")

        let keysC = try WireCrypto.deriveSessionKeys(preSharedKey: psk, ownChallenge: a, peerChallenge: c)
        report.check(rawKeyBytes(keysC.outbound) != rawKeyBytes(keysA.outbound),
                     "a fresh peer challenge derives a different key")

        let keysOtherPSK = try WireCrypto.deriveSessionKeys(preSharedKey: makeKey(), ownChallenge: a, peerChallenge: b)
        report.check(rawKeyBytes(keysOtherPSK.outbound) != rawKeyBytes(keysA.outbound),
                     "a different pre-shared key derives a different key")

        expectSessionThrows(report, "an echoed challenge is rejected", .handshakeChallengeRepeated) {
            _ = try WireCrypto.deriveSessionKeys(preSharedKey: psk, ownChallenge: a, peerChallenge: a)
        }
        expectSessionThrows(report, "a short challenge is rejected", .invalidChallengeSize(16)) {
            _ = try WireCrypto.deriveSessionKeys(
                preSharedKey: psk,
                ownChallenge: Data(repeating: 0x11, count: 16),
                peerChallenge: b
            )
        }
    } catch {
        report.check(false, "HKDF fixture", "\(error)")
    }
}

func testSequencedCrypto(_ report: Report) {
    print("\n[9] Sequenced AEAD frames")
    let key = makeKey()
    let payload = Data("{\"type\":\"tap\"}".utf8)

    do {
        let frame = try WireCrypto.sealSequencedFrame(kind: .input, sequence: 0, payload: payload, key: key)
        report.equal(
            Int(frame.prefix(4).reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) }),
            frame.count - 4,
            "length prefix excludes itself"
        )
        report.equal(frame.count - 4, 12 + 1 + 8 + payload.count + 16,
                     "body is nonce + kind + sequence + payload + tag")

        let body = Data(frame.dropFirst(4))
        let packet = try WireCrypto.openSequencedBody(body, key: key, expectedSequence: 0)
        report.equal(packet.kind, .input, "round trip keeps the kind")
        report.equal(packet.payload, payload, "round trip keeps the payload")

        expectSessionThrows(report, "replaying sequence 0 as sequence 1 is rejected",
                            .sequenceMismatch(expected: 1, received: 0)) {
            _ = try WireCrypto.openSequencedBody(body, key: key, expectedSequence: 1)
        }

        expectSessionThrows(report, "receiving sequence 1 where 0 is expected is rejected",
                            .sequenceMismatch(expected: 0, received: 1)) {
            let second = try WireCrypto.sealSequencedFrame(kind: .input, sequence: 1, payload: payload, key: key)
            _ = try WireCrypto.openSequencedBody(Data(second.dropFirst(4)), key: key, expectedSequence: 0)
        }

        let secondBody = Data(try WireCrypto.sealSequencedFrame(
            kind: .ping, sequence: 1, payload: Data(), key: key
        ).dropFirst(4))
        let second = try WireCrypto.openSequencedBody(secondBody, key: key, expectedSequence: 1)
        report.check(second.kind == .ping && second.payload.isEmpty, "empty payload at sequence 1 round trips")

        var tampered = Data([UInt8](body))
        tampered[12 + 9] ^= 0x01
        expectThrows(report, "a flipped ciphertext byte is rejected", .authenticationFailed) {
            _ = try WireCrypto.openSequencedBody(tampered, key: key, expectedSequence: 0)
        }
        expectThrows(report, "a different key is rejected", .authenticationFailed) {
            _ = try WireCrypto.openSequencedBody(body, key: makeKey(), expectedSequence: 0)
        }
        expectThrows(report, "a short sequenced body is rejected",
                     .invalidBodyLength(Wire.minSequencedBodyBytes - 1)) {
            _ = try WireCrypto.openSequencedBody(
                Data(repeating: 0, count: Wire.minSequencedBodyBytes - 1),
                key: key,
                expectedSequence: 0
            )
        }

        let maxFrame = try WireCrypto.sealSequencedFrame(kind: .ping, sequence: UInt64.max, payload: Data([0x01]), key: key)
        let maxPacket = try WireCrypto.openSequencedBody(
            Data(maxFrame.dropFirst(4)),
            key: key,
            expectedSequence: UInt64.max
        )
        report.equal(maxPacket.payload, Data([0x01]), "the last representable sequence still round trips")
    } catch {
        report.check(false, "sequenced frame round trip", "\(error)")
    }

    let tooBig = Data(count: Wire.maxPacketBodyBytes - WireCrypto.envelopeOverhead
        - WireCrypto.sequencedHeaderByteCount + 1)
    expectThrows(report, "oversized sequenced payload is refused",
                 .payloadTooLarge(Wire.maxPacketBodyBytes + 1)) {
        _ = try WireCrypto.sealSequencedBody(kind: .videoFrame, sequence: 0, payload: tooBig, key: key)
    }
}

// MARK: - Raw handshake peers for replay tests

/// A hand-built peer that performs the real handshake with `WireCrypto`, then
/// sends sequenced frames. Used to replay captured bytes deterministically.
final class RawPeer {
    let connection: NWConnection
    let queue: DispatchQueue
    let psk: SymmetricKey
    let challenge = WireCrypto.randomChallenge()

    private(set) var handshakeFrame: Data?
    private var outboundKey: SymmetricKey?
    private var inboundKey: SymmetricKey?
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0
    private var buffer = Data()
    private var handshakeDone = false
    private var closed = false

    var onHandshake: (() -> Void)?
    var onSentFrame: ((Data) -> Void)?
    var onPacket: ((WirePacket) -> Void)?
    var onClosed: (() -> Void)?

    init?(port: UInt16, psk: SymmetricKey, queue: DispatchQueue) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        self.connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        self.psk = psk
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHandshake()
            case .failed, .cancelled:
                self.notifyClosed()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func stop() {
        queue.async { [weak self] in
            self?.connection.cancel()
        }
    }

    func send(_ kind: MessageKind, payload: Data) {
        queue.async { [weak self] in
            guard let self, let key = self.outboundKey, !self.closed else { return }
            do {
                let frame = try WireCrypto.sealSequencedFrame(
                    kind: kind,
                    sequence: self.sendSequence,
                    payload: payload,
                    key: key
                )
                self.sendSequence += 1
                self.onSentFrame?(frame)
                self.connection.send(content: frame, completion: .contentProcessed { _ in })
            } catch {
                self.notifyClosed()
            }
        }
    }

    /// Resends raw bytes, e.g. a previously captured frame.
    func sendRaw(_ frame: Data) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    private func sendHandshake() {
        guard handshakeFrame == nil else { return }
        do {
            let frame = try WireCrypto.handshakeFrame(challenge: challenge, preSharedKey: psk)
            handshakeFrame = frame
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self, error != nil else { return }
                self.notifyClosed()
            })
        } catch {
            notifyClosed()
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let content, !content.isEmpty {
                self.buffer.append(content)
            }
            self.drain()
            if isComplete || error != nil {
                self.notifyClosed()
                return
            }
            self.receive()
        }
    }

    private func drain() {
        while !closed {
            guard buffer.count >= 4 else { return }
            let length = Int(buffer.prefix(4).reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) })
            guard buffer.count >= 4 + length else { return }
            let body = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(4 + length)

            if !handshakeDone {
                guard length == Wire.handshakeBodyBytes,
                      let peer = try? WireCrypto.openHandshakeBody(body, preSharedKey: psk),
                      let keys = try? WireCrypto.deriveSessionKeys(
                          preSharedKey: psk,
                          ownChallenge: challenge,
                          peerChallenge: peer
                      ) else {
                    notifyClosed()
                    connection.cancel()
                    return
                }
                inboundKey = keys.inbound
                outboundKey = keys.outbound
                handshakeDone = true
                onHandshake?()
            } else {
                guard let key = inboundKey,
                      let packet = try? WireCrypto.openSequencedBody(
                          body,
                          key: key,
                          expectedSequence: receiveSequence
                      ) else {
                    notifyClosed()
                    connection.cancel()
                    return
                }
                receiveSequence += 1
                onPacket?(packet)
            }
        }
    }

    private func notifyClosed() {
        guard !closed else { return }
        closed = true
        onClosed?()
    }
}

/// A byte-level peer that sends pre-recorded frames as soon as TCP is ready and
/// never proves knowledge of the pre-shared key.
final class ReplayProbe {
    let connection: NWConnection
    let queue: DispatchQueue
    let payloads: [Data]
    private var closed = false

    var onClosed: (() -> Void)?

    init?(port: UInt16, payloads: [Data], queue: DispatchQueue) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        self.connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        self.payloads = payloads
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                for payload in self.payloads {
                    self.connection.send(content: payload, completion: .contentProcessed { _ in })
                }
            case .failed, .cancelled:
                self.notifyClosed()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func stop() {
        queue.async { [weak self] in
            self?.connection.cancel()
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, isComplete, error in
            guard let self, !self.closed else { return }
            if isComplete || error != nil {
                self.notifyClosed()
                return
            }
            self.receive()
        }
    }

    private func notifyClosed() {
        guard !closed else { return }
        closed = true
        onClosed?()
    }
}

// MARK: - Loopback contract and replay

func testLoopbackReadyContract(_ report: Report) {
    print("\n[10] Loopback ready contract")
    let key = makeKey()
    let listenerQueue = DispatchQueue(label: "xdrscreen.test.ready.listener")
    let clientQueue = DispatchQueue(label: "xdrscreen.test.ready.client")

    guard let fixture = startListener(key: key, queue: listenerQueue, onPacket: { channel, packet in
        channel.send(packet.kind, payload: packet.payload, completion: nil)
    }) else {
        report.skip("ready contract", "could not bind a loopback listener")
        return
    }
    defer { fixture.listener.cancel() }

    guard let port = NWEndpoint.Port(rawValue: fixture.port) else {
        report.check(false, "ready loopback port", "invalid port \(fixture.port)")
        return
    }

    let marker = Data("hello-sent-from-ready".utf8)
    let client = SecureChannel(
        connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp),
        key: key,
        queue: clientQueue
    )
    let events = Box<[String]>([])
    let gotEcho = DispatchSemaphore(value: 0)

    client.onState = { state in
        if case .ready = state {
            events.mutate { $0.append("ready") }
            // The caller's first message must survive the handshake.
            client.send(.hello, payload: marker, completion: nil)
        }
    }
    client.onPacket = { packet in
        events.mutate { $0.append("packet:\(packet.kind.rawValue)") }
        if packet.kind == .hello && packet.payload == marker {
            gotEcho.signal()
        }
    }
    client.start()

    let echoed = gotEcho.wait(timeout: .now() + 10) == .success
    report.check(echoed, "a message sent from the ready handler reaches the peer and comes back")
    let order = events.current
    report.check(order.first == "ready", "ready is reported before any packet",
                 "first event: \(order.first ?? "none")")
    report.check(order.contains("packet:\(MessageKind.hello.rawValue)"), "the echo arrived after the handshake")
    report.check(fixture.serverPackets.current.contains { $0.kind == .hello && $0.payload == marker },
                 "the server received the queued hello")
    client.close()
}

func testSameSessionReplay(_ report: Report) {
    print("\n[11] Same-session replay is rejected")
    let key = makeKey()
    let listenerQueue = DispatchQueue(label: "xdrscreen.test.same.listener")
    let peerQueue = DispatchQueue(label: "xdrscreen.test.same.peer")
    let serverClosed = DispatchSemaphore(value: 0)
    let firstPacket = DispatchSemaphore(value: 0)

    guard let fixture = startListener(
        key: key,
        queue: listenerQueue,
        onChannel: { channel in
            channel.onState = { state in
                switch state {
                case .failed, .cancelled:
                    serverClosed.signal()
                default:
                    break
                }
            }
        },
        onPacket: { _, _ in
            firstPacket.signal()
        }
    ) else {
        report.skip("same-session replay", "could not bind a loopback listener")
        return
    }
    defer { fixture.listener.cancel() }

    guard let peer = RawPeer(port: fixture.port, psk: key, queue: peerQueue) else {
        report.check(false, "same-session peer", "invalid port")
        return
    }
    let handshaken = DispatchSemaphore(value: 0)
    let sentFrame = Box<Data?>(nil)
    peer.onHandshake = { handshaken.signal() }
    peer.onSentFrame = { frame in sentFrame.mutate { $0 = frame } }
    peer.start()

    guard handshaken.wait(timeout: .now() + 5) == .success else {
        report.check(false, "same-session handshake", "peer did not finish the handshake")
        peer.stop()
        return
    }
    let tap = Data("{\"type\":\"tap\",\"x\":0.5,\"y\":0.5}".utf8)
    peer.send(.input, payload: tap)

    report.check(firstPacket.wait(timeout: .now() + 5) == .success, "the first valid touch packet is delivered")
    guard let captured = sentFrame.current else {
        report.check(false, "same-session capture", "no frame was captured")
        peer.stop()
        return
    }

    // Replay the exact authenticated frame the server already accepted.
    peer.sendRaw(captured)
    report.check(serverClosed.wait(timeout: .now() + 10) == .success,
                 "the server closes the connection on a duplicated sequence")
    report.equal(fixture.serverPackets.current.count, 1, "the replayed frame is not delivered twice")
    peer.stop()
}

func testCrossSessionReplay(_ report: Report) {
    print("\n[12] Cross-session replay of a captured touch packet is rejected")
    let key = makeKey()

    // Session 1: perform a real handshake, capture the handshake and one input frame.
    let captureQueue = DispatchQueue(label: "xdrscreen.test.capture.listener")
    let capturePeerQueue = DispatchQueue(label: "xdrscreen.test.capture.peer")
    let capturePacket = DispatchSemaphore(value: 0)
    guard let captureFixture = startListener(
        key: key,
        queue: captureQueue,
        onPacket: { _, _ in capturePacket.signal() }
    ) else {
        report.skip("cross-session replay", "could not bind a capture listener")
        return
    }

    guard let peer = RawPeer(port: captureFixture.port, psk: key, queue: capturePeerQueue) else {
        report.check(false, "cross-session peer", "invalid port")
        captureFixture.listener.cancel()
        return
    }
    let handshaken = DispatchSemaphore(value: 0)
    let capturedHandshake = Box<Data?>(nil)
    let capturedInput = Box<Data?>(nil)
    peer.onHandshake = {
        capturedHandshake.mutate { $0 = peer.handshakeFrame }
        handshaken.signal()
    }
    peer.onSentFrame = { frame in capturedInput.mutate { $0 = frame } }
    peer.start()

    guard handshaken.wait(timeout: .now() + 5) == .success, capturedHandshake.current != nil else {
        report.check(false, "cross-session capture", "peer did not finish the handshake")
        peer.stop()
        captureFixture.listener.cancel()
        return
    }
    peer.send(.input, payload: Data("{\"type\":\"tap\",\"x\":0.1,\"y\":0.2}".utf8))
    guard capturePacket.wait(timeout: .now() + 5) == .success,
          let oldHandshake = capturedHandshake.current,
          let oldInput = capturedInput.current else {
        report.check(false, "cross-session capture", "could not capture a session")
        peer.stop()
        captureFixture.listener.cancel()
        return
    }
    peer.stop()
    captureFixture.listener.cancel()

    // The recorded handshake is genuinely authentic under the paired key; only
    // the fresh server challenge should make the replayed session fail.
    let replayedHandshake = (try? WireCrypto.openHandshakeFrame(oldHandshake, preSharedKey: key)) != nil
    report.check(replayedHandshake, "the captured handshake itself still carries a valid HMAC")

    // Session 2: a new connection replays the captured handshake and touch frame.
    let listenerQueue = DispatchQueue(label: "xdrscreen.test.replay.listener")
    let probeQueue = DispatchQueue(label: "xdrscreen.test.replay.probe")
    let serverClosed = DispatchSemaphore(value: 0)
    guard let fixture = startListener(
        key: key,
        queue: listenerQueue,
        onChannel: { channel in
            channel.onState = { state in
                switch state {
                case .failed, .cancelled:
                    serverClosed.signal()
                default:
                    break
                }
            }
        },
        onPacket: { _, _ in }
    ) else {
        report.skip("cross-session replay session 2", "could not bind a listener")
        return
    }
    defer { fixture.listener.cancel() }

    guard let probe = ReplayProbe(port: fixture.port, payloads: [oldHandshake, oldInput], queue: probeQueue) else {
        report.check(false, "replay probe", "invalid port")
        return
    }
    probe.start()

    report.check(serverClosed.wait(timeout: .now() + 10) == .success,
                 "the new session closes instead of accepting old frames")
    report.check(fixture.serverPackets.current.isEmpty,
                 "no captured packet is delivered in the new session",
                 "\(fixture.serverPackets.current.count) packets delivered")
    probe.stop()
}

func testTamperedHandshakeRejected(_ report: Report) {
    print("\n[13] Tampered handshake and pre-handshake frames are rejected")
    let key = makeKey()
    let listenerQueue = DispatchQueue(label: "xdrscreen.test.tamper.listener")
    let probeQueue = DispatchQueue(label: "xdrscreen.test.tamper.probe")
    let serverClosed = DispatchSemaphore(value: 0)
    let readySeen = Box(false)

    guard let fixture = startListener(
        key: key,
        queue: listenerQueue,
        onChannel: { channel in
            channel.onState = { state in
                switch state {
                case .ready:
                    readySeen.mutate { $0 = true }
                case .failed, .cancelled:
                    serverClosed.signal()
                default:
                    break
                }
            }
        },
        onPacket: { _, _ in }
    ) else {
        report.skip("tampered handshake", "could not bind a listener")
        return
    }
    defer { fixture.listener.cancel() }

    guard let goodHandshake = try? WireCrypto.handshakeFrame(
        challenge: WireCrypto.randomChallenge(),
        preSharedKey: key
    ) else {
        report.check(false, "tampered handshake fixture", "could not build a handshake")
        return
    }
    var tampered = Data([UInt8](goodHandshake))
    tampered[tampered.count - 1] ^= 0x01

    guard let probe = ReplayProbe(port: fixture.port, payloads: [tampered], queue: probeQueue) else {
        report.check(false, "tampered probe", "invalid port")
        return
    }
    probe.start()

    report.check(serverClosed.wait(timeout: .now() + 10) == .success,
                 "a handshake with a corrupted HMAC closes the connection")
    report.check(!readySeen.current, "ready is never reported for an unauthenticated peer")
    report.check(fixture.serverPackets.current.isEmpty, "no packet is delivered")
    probe.stop()
}

func testFrameBeforeHandshakeRejected(_ report: Report) {
    print("\n[14] A sealed frame before the handshake is rejected")
    let key = makeKey()
    let listenerQueue = DispatchQueue(label: "xdrscreen.test.prehandshake.listener")
    let probeQueue = DispatchQueue(label: "xdrscreen.test.prehandshake.probe")
    let serverClosed = DispatchSemaphore(value: 0)
    let readySeen = Box(false)

    guard let fixture = startListener(
        key: key,
        queue: listenerQueue,
        onChannel: { channel in
            channel.onState = { state in
                switch state {
                case .ready:
                    readySeen.mutate { $0 = true }
                case .failed, .cancelled:
                    serverClosed.signal()
                default:
                    break
                }
            }
        },
        onPacket: { _, _ in }
    ) else {
        report.skip("pre-handshake frame", "could not bind a listener")
        return
    }
    defer { fixture.listener.cancel() }

    guard let frame = try? WireCrypto.sealSequencedFrame(
        kind: .input,
        sequence: 0,
        payload: Data("{\"type\":\"tap\"}".utf8),
        key: makeKey()
    ), let probe = ReplayProbe(port: fixture.port, payloads: [frame], queue: probeQueue) else {
        report.check(false, "pre-handshake fixture", "could not build the frame")
        return
    }
    probe.start()

    report.check(serverClosed.wait(timeout: .now() + 10) == .success,
                 "a frame that is not the fixed-size handshake closes the connection")
    report.check(!readySeen.current, "ready is not reported before the handshake")
    report.check(fixture.serverPackets.current.isEmpty, "the frame is not delivered")
    probe.stop()
}

// MARK: - Handshake transport versus protocol failures

func isProtocolFailure(_ error: NWError) -> Bool {
    guard case .posix(let code) = error else { return false }
    return code == .EPROTO
}

func testHandshakeSendOutcomeClassification(_ report: Report) {
    print("\n[15] Handshake write failures are transport errors, not protocol errors")

    report.equal(
        SecureChannel.handshakeSendOutcome(for: nil),
        .delivered,
        "a completed write lets the handshake proceed"
    )

    // Every one of these is a transient transport failure that can happen
    // after TCP is ready (Wi-Fi roam, host quit, timeout) while the key is
    // still correct. None may be turned into EPROTO.
    let transient: [NWError] = [
        .posix(.ECONNRESET),
        .posix(.ETIMEDOUT),
        .posix(.ECONNREFUSED),
        .posix(.EHOSTUNREACH),
        .posix(.ENETDOWN),
        .posix(.ENOBUFS)
    ]
    for error in transient {
        let outcome = SecureChannel.handshakeSendOutcome(for: error)
        report.equal(outcome, .transportFailure(error), "\(error) is forwarded unchanged")
        guard case .transportFailure(let forwarded) = outcome else {
            report.check(false, "\(error) is classified as a transport failure")
            continue
        }
        report.check(!isProtocolFailure(forwarded), "\(error) is never reported as EPROTO")
    }
}

func testLoopbackAuthenticationFailureIsProtocolFailure(_ report: Report) {
    print("\n[16] A failed handshake authentication is still a protocol failure")

    let key = makeKey()
    let listenerQueue = DispatchQueue(label: "xdrscreen.test.protocol.listener")
    let probeQueue = DispatchQueue(label: "xdrscreen.test.protocol.probe")
    let clientQueue = DispatchQueue(label: "xdrscreen.test.protocol.client")

    let serverTerminated = DispatchSemaphore(value: 0)
    let serverErrors = Box<[NWError]>([])
    let serverReady = Box(false)

    guard let fixture = startListener(
        key: key,
        queue: listenerQueue,
        onChannel: { channel in
            channel.onState = { state in
                switch state {
                case .ready:
                    serverReady.mutate { $0 = true }
                case .failed(let error):
                    serverErrors.mutate { $0.append(error) }
                    serverTerminated.signal()
                case .cancelled:
                    serverTerminated.signal()
                default:
                    break
                }
            }
        },
        onPacket: { channel, packet in
            channel.send(packet.kind, payload: packet.payload, completion: nil)
        }
    ) else {
        report.skip("protocol failure", "could not bind a loopback listener")
        return
    }
    defer { fixture.listener.cancel() }

    // A peer that proves knowledge of a different key: a genuine
    // authentication failure, not a transport problem.
    guard let badHandshake = try? WireCrypto.handshakeFrame(
        challenge: WireCrypto.randomChallenge(),
        preSharedKey: makeKey()
    ), let probe = ReplayProbe(port: fixture.port, payloads: [badHandshake], queue: probeQueue) else {
        report.check(false, "wrong-key probe fixture", "could not build a wrong-key handshake")
        return
    }
    probe.start()

    report.check(serverTerminated.wait(timeout: .now() + 10) == .success,
                 "the receiver terminates the session after a failed HMAC")
    let reported = serverErrors.current
    report.check(reported.contains(where: isProtocolFailure),
                 "the failure is reported as EPROTO, not a transport error",
                 "reported: \(reported)")
    report.check(!serverReady.current, "ready is never reported for a wrong-key peer")
    report.check(fixture.serverPackets.current.isEmpty, "no packet is delivered",
                 "\(fixture.serverPackets.current.count) packets delivered")
    probe.stop()

    // The listener is unharmed: once the key is right, a fresh session works.
    guard let port = NWEndpoint.Port(rawValue: fixture.port) else {
        report.check(false, "reconnect port", "invalid port \(fixture.port)")
        return
    }
    let reconnected = DispatchSemaphore(value: 0)
    let payload = Data("after-protocol-failure".utf8)
    let client = SecureChannel(
        connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp),
        key: key,
        queue: clientQueue
    )
    client.onPacket = { packet in
        if packet.kind == .ping, packet.payload == payload {
            reconnected.signal()
        }
    }
    client.send(.ping, payload: payload, completion: nil)
    client.start()
    report.check(reconnected.wait(timeout: .now() + 10) == .success,
                 "a new, correctly keyed session connects and echoes")
    client.close()
}

func testLoopbackTransportTeardownIsNotProtocolFailure(_ report: Report) {
    print("\n[17] A pre-handshake transport teardown is not a protocol failure")

    let key = makeKey()
    let listenerQueue = DispatchQueue(label: "xdrscreen.test.teardown.listener")
    let clientQueue = DispatchQueue(label: "xdrscreen.test.teardown.client")

    // A listener that accepts and immediately aborts the TCP connection, the
    // way a roaming interface or a quitting host looks to the client. The
    // handshake can never be authenticated, but the key is not at fault.
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    guard let listener = try? NWListener(using: parameters) else {
        report.skip("transport teardown", "could not bind a loopback listener")
        return
    }
    let ready = DispatchSemaphore(value: 0)
    let listenerPort = Box<UInt16>(0)
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            listenerPort.mutate { $0 = listener.port?.rawValue ?? 0 }
            ready.signal()
        case .failed:
            ready.signal()
        default:
            break
        }
    }
    listener.newConnectionHandler = { connection in
        connection.forceCancel()
    }
    listener.start(queue: listenerQueue)
    defer { listener.cancel() }

    guard ready.wait(timeout: .now() + 5) == .success,
          listenerPort.current != 0,
          let port = NWEndpoint.Port(rawValue: listenerPort.current) else {
        report.skip("transport teardown", "listener never became ready")
        return
    }

    let terminated = DispatchSemaphore(value: 0)
    let reportedStates = Box<[String]>([])
    let sawProtocolFailure = Box(false)
    let pendingCompleted = DispatchSemaphore(value: 0)

    let client = SecureChannel(
        connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp),
        key: key,
        queue: clientQueue
    )
    client.onState = { state in
        switch state {
        case .failed(let error):
            reportedStates.mutate { $0.append("failed(\(error))") }
            if isProtocolFailure(error) {
                sawProtocolFailure.mutate { $0 = true }
            }
            terminated.signal()
        case .cancelled:
            reportedStates.mutate { $0.append("cancelled") }
            terminated.signal()
        default:
            reportedStates.mutate { $0.append("\(state)") }
        }
    }
    client.send(.hello, payload: Data(), completion: { _ in pendingCompleted.signal() })
    client.start()

    report.check(terminated.wait(timeout: .now() + 10) == .success,
                 "the channel reaches a terminal state instead of hanging")
    report.check(!sawProtocolFailure.current,
                 "an aborted transport is never reported as EPROTO",
                 "reported: \(reportedStates.current)")
    report.check(pendingCompleted.wait(timeout: .now() + 5) == .success,
                 "a queued send completes when the channel closes instead of hanging")
    client.close()
}

// MARK: - Main

let report = Report()
print("XDRScreen wire protocol regression")
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

testMessages(report)
testCrypto(report)
testTampering(report)
testInvalidFrames(report)
testVideoFramePayload(report)
testLoopbackEcho(report)
testLoopbackAuthenticationFailure(report)
testHandshakeCrypto(report)
testSequencedCrypto(report)
testLoopbackReadyContract(report)
testSameSessionReplay(report)
testCrossSessionReplay(report)
testTamperedHandshakeRejected(report)
testFrameBeforeHandshakeRejected(report)
testHandshakeSendOutcomeClassification(report)
testLoopbackAuthenticationFailureIsProtocolFailure(report)
testLoopbackTransportTeardownIsNotProtocolFailure(report)
testVirtualDisplayScheduling(report)
testDisplayArrangementTransactions(report)
testCaptureEncoderRecovery(report)
testFormatKeyframeGate(report)
testHostSilenceWatchdog(report)
testVideoPresentationGeometry(report)
testViewportZoomGeometry(report)

print("\n────────────────────────────────────────")
print("passed: \(report.passed)   failed: \(report.failures.count)   skipped: \(report.skipped)")
if !report.failures.isEmpty {
    print("\nFailures:")
    for failure in report.failures {
        print("  • \(failure)")
    }
    exit(1)
}
print("RESULT: PASS")
exit(0)
