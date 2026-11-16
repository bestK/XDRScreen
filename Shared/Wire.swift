//
//  Wire.swift
//  XDRScreen
//
//  Shared wire protocol for the macOS host and the iPadOS client.
//  This file is compiled into both app targets and must stay free of
//  platform specific API beyond Network.framework and CryptoKit.
//
//  Framing
//  -------
//  Every message on the TCP stream is:
//
//      UInt32 big-endian bodyLength | body
//
//  The first frame in each direction is the session handshake, a body of
//  exactly `Wire.handshakeBodyBytes` bytes:
//
//      8 byte fixed prefix "XDRAUTH\0" | 1 byte version | 32 byte random challenge |
//      32 byte HMAC-SHA256(preSharedKey, prefix | version | challenge)
//
//  Both peers send and verify one handshake. The pre-shared key never leaves
//  the device. Each side then derives two per-connection AES-256 keys with
//  HKDF-SHA256 over the pre-shared key, salted with the two challenges in a
//  role-independent lexicographic order.
//
//  Every later body is the output of AES.GCM.seal over
//
//      [1 byte MessageKind][8 byte UInt64 big-endian sequence][payload bytes]
//
//  and therefore equals:
//
//      12 byte random nonce | ciphertext | 16 byte tag
//
//  Each direction starts at sequence 0 and increments by one per message. The
//  receiver requires exactly the expected value, so replayed, reordered,
//  dropped and overflowing messages close the channel. Kind and sequence are
//  inside the AEAD plaintext and are therefore authenticated.
//
//  Nothing is delivered to the caller before authentication succeeds, and
//  `onState(.ready)` is only reported after the handshake has completed.
//

import CryptoKit
import Foundation
import Network

// MARK: - Wire constants

/// Fixed cross-platform protocol constants.
public enum Wire {
    /// Bonjour service type advertised by the host and browsed by the client.
    public static let bonjourType = "_xdrscreen._tcp"

    /// TCP port used by the host.
    public static let port: UInt16 = 49321

    /// Upper bound for a single encoded video frame payload, in bytes.
    public static let maxFrameBytes = 16 * 1024 * 1024

    /// Version advertised in `HelloMessage.protocolVersion`.
    public static let protocolVersion = 1

    /// Hard ceiling for one sealed message body, i.e. the value carried by the
    /// 4-byte length prefix. A larger prefix closes the connection before any
    /// payload sized allocation happens.
    public static let maxPacketBodyBytes = 16 * 1024 * 1024

    /// Paired pre-shared key size in bytes (AES-256-GCM).
    public static let keyByteCount = 32

    /// Smallest body that can possibly authenticate:
    /// 12 byte nonce + 1 byte message kind + 16 byte tag.
    public static let minBodyBytes = WireCrypto.nonceByteCount + 1 + WireCrypto.tagByteCount

    /// Fixed prefix opening every handshake body. It lets both sides tell a
    /// handshake apart from an encrypted frame before any key exists.
    public static let handshakePrefix = Data("XDRAUTH\u{0}".utf8)

    /// Version of the handshake format, covered by the HMAC.
    public static let handshakeVersion: UInt8 = 1

    /// Size of each side's random handshake challenge.
    public static let challengeByteCount = 32

    /// Size of the HMAC-SHA256 tag in a handshake body.
    public static let handshakeHMACByteCount = 32

    /// Exact handshake body size: prefix + version + challenge + HMAC. The
    /// receiver requires this exact value, so a handshake can never be confused
    /// with a coalesced encrypted frame.
    public static let handshakeBodyBytes =
        handshakePrefix.count + 1 + challengeByteCount + handshakeHMACByteCount

    /// Smallest authenticated body after the handshake:
    /// 12 byte nonce + 1 byte kind + 8 byte sequence + 16 byte tag.
    public static let minSequencedBodyBytes =
        WireCrypto.nonceByteCount + 1 + 8 + WireCrypto.tagByteCount
}

// MARK: - Message kind

/// First plaintext byte of every sealed body.
public enum MessageKind: UInt8, CaseIterable, Sendable {
    case hello = 1
    case videoFormat = 2
    case videoFrame = 3
    case input = 4
    case ping = 5
    case status = 6
    case requestKeyframe = 7
}

// MARK: - Packet

/// One authenticated, decrypted message.
public struct WirePacket: Equatable, Sendable {
    public let kind: MessageKind
    public let payload: Data

    public init(kind: MessageKind, payload: Data) {
        self.kind = kind
        self.payload = payload
    }
}

// MARK: - Errors

public enum WireError: Error, Equatable, LocalizedError {
    /// The channel was already closed (locally or by the peer) when sending.
    case channelClosed
    /// A seal/open request whose body would exceed `Wire.maxPacketBodyBytes`.
    case payloadTooLarge(Int)
    /// Length prefix or body size out of range.
    case invalidBodyLength(Int)
    /// Authenticated plaintext whose first byte is not a known `MessageKind`.
    case invalidMessageKind(UInt8)
    /// AES-GCM authentication failed: tampered, truncated or wrong key.
    case authenticationFailed
    /// The peer closed the connection.
    case connectionClosed
    /// CryptoKit refused to seal (should not happen with a 256-bit key).
    case cryptoFailure
    /// Key is not a 32 byte AES-256 key.
    case invalidKeySize(Int)

    public var errorDescription: String? {
        switch self {
        case .channelClosed:
            return "The secure channel is closed."
        case .payloadTooLarge(let size):
            return "Payload body of \(size) bytes exceeds the 16 MiB limit."
        case .invalidBodyLength(let size):
            return "Invalid encrypted body length: \(size)."
        case .invalidMessageKind(let raw):
            return "Unknown message kind byte: \(raw)."
        case .authenticationFailed:
            return "AES-GCM authentication failed."
        case .connectionClosed:
            return "The peer closed the connection."
        case .cryptoFailure:
            return "AES-GCM sealing failed."
        case .invalidKeySize(let bits):
            return "Expected a 256-bit paired key, got \(bits) bits."
        }
    }
}

/// Failures that only exist once two peers try to establish or use a session.
/// Kept separate from `WireError` so existing error handling stays exhaustive.
public enum WireSessionError: Error, Equatable, LocalizedError {
    /// Handshake body is not the fixed prefix/version/challenge/HMAC layout.
    case handshakeMalformed
    /// Handshake announced a different protocol version.
    case handshakeVersionMismatch(UInt8)
    /// Handshake HMAC did not verify: wrong pre-shared key or tampered bytes.
    case handshakeAuthenticationFailed
    /// The peer echoed our own challenge; it cannot prove liveness.
    case handshakeChallengeRepeated
    /// A challenge or derived key had an unexpected size.
    case invalidChallengeSize(Int)
    /// A message arrived with a sequence other than the expected one: a replay,
    /// a drop, a reorder or an injected frame.
    case sequenceMismatch(expected: UInt64, received: UInt64)
    /// The 64-bit per-direction sequence space is exhausted.
    case sequenceOverflow

    public var errorDescription: String? {
        switch self {
        case .handshakeMalformed:
            return "Malformed session handshake."
        case .handshakeVersionMismatch(let version):
            return "Unsupported handshake version \(version)."
        case .handshakeAuthenticationFailed:
            return "Session handshake authentication failed."
        case .handshakeChallengeRepeated:
            return "The peer repeated our own challenge."
        case .invalidChallengeSize(let size):
            return "Expected a 32-byte challenge or key, got \(size) bytes."
        case .sequenceMismatch(let expected, let received):
            return "Expected sequence \(expected), got \(received): replay or reorder."
        case .sequenceOverflow:
            return "The message sequence space is exhausted."
        }
    }
}

// MARK: - Crypto / framing

/// Stateless sealer and opener for the wire format. `SecureChannel` uses it,
/// and the regression tests exercise it directly.
public enum WireCrypto {
    /// AES-GCM nonce length produced by CryptoKit's default random nonce.
    public static let nonceByteCount = 12
    /// AES-GCM authentication tag length.
    public static let tagByteCount = 16
    /// nonce + message kind byte + tag.
    public static let envelopeOverhead = nonceByteCount + 1 + tagByteCount

    /// Encodes `body` with a 4-byte big-endian length prefix.
    ///
    /// This is the unsequenced legacy encoding used by the low-level tests.
    /// Live connections must use `SecureChannel` / `sealSequencedFrame`, which
    /// carry the per-direction sequence number needed to reject replays.
    public static func sealFrame(kind: MessageKind, payload: Data, key: SymmetricKey) throws -> Data {
        let body = try sealBody(kind: kind, payload: payload, key: key)
        var frame = Data(capacity: 4 + body.count)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    /// Seals `kind` + `payload` into nonce|ciphertext|tag.
    public static func sealBody(kind: MessageKind, payload: Data, key: SymmetricKey) throws -> Data {
        try validate(key)
        let bodySize = payload.count + envelopeOverhead
        guard bodySize <= Wire.maxPacketBodyBytes else {
            throw WireError.payloadTooLarge(bodySize)
        }
        var plaintext = Data(capacity: payload.count + 1)
        plaintext.append(kind.rawValue)
        plaintext.append(payload)

        let sealed: AES.GCM.SealedBox
        do {
            // CryptoKit generates a fresh random 12-byte nonce per call.
            sealed = try AES.GCM.seal(plaintext, using: key)
        } catch {
            throw WireError.cryptoFailure
        }
        guard let combined = sealed.combined,
              combined.count == plaintext.count + nonceByteCount + tagByteCount else {
            throw WireError.cryptoFailure
        }
        return combined
    }

    /// Authenticates and decrypts a body (without the length prefix).
    public static func openBody(_ body: Data, key: SymmetricKey) throws -> WirePacket {
        let plaintext = try openPlaintext(body, key: key, minimumBodyBytes: Wire.minBodyBytes)
        guard let typeByte = plaintext.first else {
            throw WireError.authenticationFailed
        }
        guard let kind = MessageKind(rawValue: typeByte) else {
            throw WireError.invalidMessageKind(typeByte)
        }
        return WirePacket(kind: kind, payload: Data(plaintext.dropFirst()))
    }

    /// Authenticates and decrypts a complete length-prefixed frame.
    public static func openFrame(_ frame: Data, key: SymmetricKey) throws -> WirePacket {
        guard frame.count >= 4 else { throw WireError.invalidBodyLength(frame.count) }
        try validate(key)

        let bodyLength = Int(readBigEndianUInt32(frame.prefix(4)))
        guard bodyLength >= Wire.minBodyBytes, bodyLength <= Wire.maxPacketBodyBytes else {
            throw WireError.invalidBodyLength(bodyLength)
        }
        guard frame.count == 4 + bodyLength else {
            throw WireError.invalidBodyLength(frame.count - 4)
        }
        return try openBody(Data(frame.dropFirst(4)), key: key)
    }

    // MARK: Session handshake

    /// A fresh 32-byte challenge taken from CryptoKit's system CSPRNG.
    public static func randomChallenge() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// Handshake body for our own challenge, authenticated with the pre-shared
    /// key: prefix | version | challenge | HMAC-SHA256(prefix | version | challenge).
    public static func handshakeBody(challenge: Data, preSharedKey: SymmetricKey) throws -> Data {
        try validate(preSharedKey)
        guard challenge.count == Wire.challengeByteCount else {
            throw WireSessionError.invalidChallengeSize(challenge.count)
        }
        let authenticated = handshakeAuthenticatedBytes(challenge: challenge)
        var body = Data(capacity: Wire.handshakeBodyBytes)
        body.append(authenticated)
        let tag = HMAC<SHA256>.authenticationCode(for: authenticated, using: preSharedKey)
        body.append(contentsOf: tag)
        return body
    }

    /// Length-prefixed handshake frame, ready for the wire.
    public static func handshakeFrame(challenge: Data, preSharedKey: SymmetricKey) throws -> Data {
        lengthPrefixed(try handshakeBody(challenge: challenge, preSharedKey: preSharedKey))
    }

    /// Verifies a handshake body with the pre-shared key and returns the peer's
    /// challenge. The HMAC comparison is constant time and the pre-shared key
    /// itself is never transmitted.
    public static func openHandshakeBody(_ body: Data, preSharedKey: SymmetricKey) throws -> Data {
        try validate(preSharedKey)
        guard body.count == Wire.handshakeBodyBytes else {
            throw WireSessionError.handshakeMalformed
        }
        let base = body.startIndex
        let prefixEnd = base + Wire.handshakePrefix.count
        guard Data(body[base ..< prefixEnd]) == Wire.handshakePrefix else {
            throw WireSessionError.handshakeMalformed
        }
        let version = body[prefixEnd]
        guard version == Wire.handshakeVersion else {
            throw WireSessionError.handshakeVersionMismatch(version)
        }
        let challengeStart = prefixEnd + 1
        let challenge = Data(body[challengeStart ..< (challengeStart + Wire.challengeByteCount)])
        let macStart = challengeStart + Wire.challengeByteCount
        let mac = Data(body[macStart ..< (macStart + Wire.handshakeHMACByteCount)])
        guard HMAC<SHA256>.isValidAuthenticationCode(
            mac,
            authenticating: handshakeAuthenticatedBytes(challenge: challenge),
            using: preSharedKey
        ) else {
            throw WireSessionError.handshakeAuthenticationFailed
        }
        return challenge
    }

    /// Verifies a complete length-prefixed handshake frame.
    public static func openHandshakeFrame(_ frame: Data, preSharedKey: SymmetricKey) throws -> Data {
        guard frame.count == 4 + Wire.handshakeBodyBytes,
              readBigEndianUInt32(frame.prefix(4)) == UInt32(Wire.handshakeBodyBytes) else {
            throw WireSessionError.handshakeMalformed
        }
        return try openHandshakeBody(Data(frame.dropFirst(4)), preSharedKey: preSharedKey)
    }

    /// Derives the two directional AES-256 keys for a connection.
    ///
    /// The challenges are public, so both sides simply sort them: the
    /// lexicographically smaller challenge always owns the first derived key.
    /// No host/client role or implicit direction is involved, both peers reach
    /// the same result and each direction gets its own key.
    public static func deriveSessionKeys(
        preSharedKey: SymmetricKey,
        ownChallenge: Data,
        peerChallenge: Data
    ) throws -> (outbound: SymmetricKey, inbound: SymmetricKey) {
        try validate(preSharedKey)
        guard ownChallenge.count == Wire.challengeByteCount else {
            throw WireSessionError.invalidChallengeSize(ownChallenge.count)
        }
        guard peerChallenge.count == Wire.challengeByteCount else {
            throw WireSessionError.invalidChallengeSize(peerChallenge.count)
        }
        guard ownChallenge != peerChallenge else {
            throw WireSessionError.handshakeChallengeRepeated
        }

        let ownIsLow = ownChallenge.lexicographicallyPrecedes(peerChallenge)
        let low = ownIsLow ? ownChallenge : peerChallenge
        let high = ownIsLow ? peerChallenge : ownChallenge
        var salt = Data(capacity: 2 * Wire.challengeByteCount)
        salt.append(low)
        salt.append(high)

        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: preSharedKey,
            salt: salt,
            info: Data("XDRScreen session keys v1".utf8),
            outputByteCount: 2 * Wire.keyByteCount
        )
        let raw = derived.withUnsafeBytes { Data($0) }
        let lowKey = SymmetricKey(data: raw.prefix(Wire.keyByteCount))
        let highKey = SymmetricKey(data: raw.suffix(Wire.keyByteCount))
        return ownIsLow
            ? (outbound: lowKey, inbound: highKey)
            : (outbound: highKey, inbound: lowKey)
    }

    private static func handshakeAuthenticatedBytes(challenge: Data) -> Data {
        var data = Data(capacity: Wire.handshakeBodyBytes - Wire.handshakeHMACByteCount)
        data.append(Wire.handshakePrefix)
        data.append(Wire.handshakeVersion)
        data.append(challenge)
        return data
    }

    // MARK: Sequenced frames

    /// Seals `kind` + big-endian `sequence` + `payload` into a length-prefixed
    /// frame. Kind and sequence are part of the AEAD plaintext.
    public static func sealSequencedFrame(
        kind: MessageKind,
        sequence: UInt64,
        payload: Data,
        key: SymmetricKey
    ) throws -> Data {
        lengthPrefixed(try sealSequencedBody(kind: kind, sequence: sequence, payload: payload, key: key))
    }

    public static func sealSequencedBody(
        kind: MessageKind,
        sequence: UInt64,
        payload: Data,
        key: SymmetricKey
    ) throws -> Data {
        try validate(key)
        let bodySize = payload.count + sequencedHeaderByteCount + envelopeOverhead
        guard bodySize <= Wire.maxPacketBodyBytes else {
            throw WireError.payloadTooLarge(bodySize)
        }
        var plaintext = Data(capacity: payload.count + sequencedHeaderByteCount)
        plaintext.append(kind.rawValue)
        appendBigEndian(sequence, to: &plaintext)
        plaintext.append(payload)

        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: key)
        } catch {
            throw WireError.cryptoFailure
        }
        guard let combined = sealed.combined,
              combined.count == plaintext.count + nonceByteCount + tagByteCount else {
            throw WireError.cryptoFailure
        }
        return combined
    }

    /// Decrypts a sequenced body and enforces the expected per-direction
    /// sequence number. A mismatch rejects the message before it is delivered.
    public static func openSequencedBody(
        _ body: Data,
        key: SymmetricKey,
        expectedSequence: UInt64
    ) throws -> WirePacket {
        let plaintext = try openPlaintext(body, key: key, minimumBodyBytes: Wire.minSequencedBodyBytes)
        guard plaintext.count >= sequencedHeaderByteCount else {
            throw WireError.authenticationFailed
        }
        let base = plaintext.startIndex
        let typeByte = plaintext[base]
        guard let kind = MessageKind(rawValue: typeByte) else {
            throw WireError.invalidMessageKind(typeByte)
        }
        let sequenceStart = base + 1
        let sequence = readBigEndianUInt64(plaintext[sequenceStart ..< (sequenceStart + 8)])
        guard sequence == expectedSequence else {
            throw WireSessionError.sequenceMismatch(expected: expectedSequence, received: sequence)
        }
        return WirePacket(kind: kind, payload: Data(plaintext[(base + sequencedHeaderByteCount)...]))
    }

    /// Size of kind + sequence in front of every encrypted payload.
    public static let sequencedHeaderByteCount = 1 + 8

    // MARK: Internals

    private static func openPlaintext(_ body: Data, key: SymmetricKey, minimumBodyBytes: Int) throws -> Data {
        try validate(key)
        guard body.count >= minimumBodyBytes, body.count <= Wire.maxPacketBodyBytes else {
            throw WireError.invalidBodyLength(body.count)
        }

        let base = body.startIndex
        let nonceRange = base ..< (base + nonceByteCount)
        let tagStart = base + body.count - tagByteCount
        let ciphertextRange = (base + nonceByteCount) ..< tagStart
        let tagRange = tagStart ..< (base + body.count)

        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: body[nonceRange]),
                ciphertext: body[ciphertextRange],
                tag: body[tagRange]
            )
        } catch {
            throw WireError.authenticationFailed
        }

        do {
            return try AES.GCM.open(box, using: key)
        } catch {
            // Tampered ciphertext, tampered tag, tampered nonce or wrong key.
            throw WireError.authenticationFailed
        }
    }

    private static func lengthPrefixed(_ body: Data) -> Data {
        var frame = Data(capacity: 4 + body.count)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    private static func appendBigEndian(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readBigEndianUInt32(_ data: Data) -> UInt32 {
        data.prefix(4).reduce(into: UInt32(0)) { value, byte in
            value = (value << 8) | UInt32(byte)
        }
    }

    private static func readBigEndianUInt64(_ data: Data) -> UInt64 {
        data.prefix(8).reduce(into: UInt64(0)) { value, byte in
            value = (value << 8) | UInt64(byte)
        }
    }

    private static func validate(_ key: SymmetricKey) throws {
        guard key.bitCount == Wire.keyByteCount * 8 else {
            throw WireError.invalidKeySize(key.bitCount)
        }
    }
}

// MARK: - Video frame payload

/// Inner format of a `videoFrame` payload:
///
///     1 byte flags (bit 0 = keyframe)
///     8 bytes UInt64 big-endian presentation timestamp in microseconds
///     N bytes VideoToolbox HEVC AVCC data (4-byte length prefixed NAL units)
public enum VideoFramePayload {
    public static let headerByteCount = 1 + 8
    public static let keyframeFlag: UInt8 = 0x01

    /// Largest `data` that still fits in one 16 MiB sealed body.
    public static var maxDataBytes: Int {
        Wire.maxPacketBodyBytes - WireCrypto.envelopeOverhead - headerByteCount
    }

    public static func encode(keyframe: Bool, timestampUs: UInt64, data: Data) -> Data {
        var out = Data(capacity: headerByteCount + data.count)
        out.append(keyframe ? keyframeFlag : 0x00)
        var timestamp = timestampUs.bigEndian
        withUnsafeBytes(of: &timestamp) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }

    public static func decode(_ data: Data) -> (keyframe: Bool, timestampUs: UInt64, data: Data)? {
        guard data.count >= headerByteCount else { return nil }
        let base = data.startIndex
        let flags = data[base]
        let timestamp = data[(base + 1) ..< (base + headerByteCount)].reduce(into: UInt64(0)) { value, byte in
            value = (value << 8) | UInt64(byte)
        }
        return (
            keyframe: (flags & keyframeFlag) != 0,
            timestampUs: timestamp,
            data: Data(data[(base + headerByteCount) ..< (base + data.count)])
        )
    }
}

// MARK: - JSON messages

public struct HelloMessage: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let width: Int
    public let height: Int
    public let maxFPS: Int
    public let supportsHDR: Bool
    public let deviceName: String

    public init(
        protocolVersion: Int,
        width: Int,
        height: Int,
        maxFPS: Int,
        supportsHDR: Bool,
        deviceName: String
    ) {
        self.protocolVersion = protocolVersion
        self.width = width
        self.height = height
        self.maxFPS = maxFPS
        self.supportsHDR = supportsHDR
        self.deviceName = deviceName
    }
}

public struct VideoFormatMessage: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let fps: Int
    public let hdr: Bool
    public let vps: Data
    public let sps: Data
    public let pps: Data
    public let colorPrimaries: String
    public let transferFunction: String
    public let yCbCrMatrix: String

    public init(
        width: Int,
        height: Int,
        fps: Int,
        hdr: Bool,
        vps: Data,
        sps: Data,
        pps: Data,
        colorPrimaries: String,
        transferFunction: String,
        yCbCrMatrix: String
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.hdr = hdr
        self.vps = vps
        self.sps = sps
        self.pps = pps
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
    }
}

public struct InputMessage: Codable, Equatable, Sendable {
    public let type: String
    public let x: Double?
    public let y: Double?
    public let deltaX: Double?
    public let deltaY: Double?
    public let text: String?
    public let keyCode: UInt16?

    public init(
        type: String,
        x: Double? = nil,
        y: Double? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        text: String? = nil,
        keyCode: UInt16? = nil
    ) {
        self.type = type
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.text = text
        self.keyCode = keyCode
    }
}

public struct StatusMessage: Codable, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

// MARK: - JSON helpers

/// Small convenience wrappers used by both apps for the JSON payload kinds.
public enum WireJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Secure channel

/// Length-prefixed, AES-GCM authenticated message channel over an `NWConnection`.
///
/// The channel transparently runs a symmetric handshake before any caller
/// message is sent, derives per-connection directional keys from the paired
/// pre-shared key, and numbers every message per direction. `onState(.ready)`
/// is reported only once the connection is up *and* both challenges have been
/// authenticated. Duplicate, missing, reordered or forged messages close the
/// connection and are never delivered.
///
/// All state is touched on the serial `queue` passed to `init`, which is also
/// the queue the connection's callbacks run on. `send` and `close` are safe to
/// call from any thread; work is hopped onto that queue. Messages sent before
/// the channel becomes ready are queued in order (bounded) rather than lost.
public final class SecureChannel {
    public var onPacket: ((WirePacket) -> Void)? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return packetHandler
        }
        set {
            handlerLock.lock()
            packetHandler = newValue
            handlerLock.unlock()
        }
    }

    public var onState: ((NWConnection.State) -> Void)? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return stateHandler
        }
        set {
            handlerLock.lock()
            stateHandler = newValue
            handlerLock.unlock()
        }
    }

    /// What the transport did with the handshake frame.
    ///
    /// A failed write says nothing about the peer or the pre-shared key: the
    /// socket may have been reset by a Wi-Fi roam, the host may have quit, or
    /// the connection may have timed out. Reporting such a failure as a
    /// protocol error would make the caller treat a transient network problem
    /// as a wrong key and stop retrying, so the original `NWError` is kept
    /// verbatim. Only an authenticated-handshake failure is a protocol error.
    public enum HandshakeSendOutcome: Equatable {
        /// The frame was handed to the transport; the handshake may proceed.
        case delivered
        /// The transport refused the write. Forward this error unchanged.
        case transportFailure(NWError)
    }

    /// Classifies the completion of the handshake write. Pure so the
    /// transport-versus-protocol distinction is regression-testable without
    /// tearing down a real connection.
    public static func handshakeSendOutcome(for error: NWError?) -> HandshakeSendOutcome {
        if let error {
            return .transportFailure(error)
        }
        return .delivered
    }

    /// Bounds on messages accepted before the handshake completes, so an early
    /// caller (or a dead handshake) cannot grow memory without limit.
    private static let maxPendingSends = 256
    private static let maxPendingSendBytes = 64 * 1024 * 1024

    private let connection: NWConnection
    private let preSharedKey: SymmetricKey
    private let queue: DispatchQueue

    private let handlerLock = NSLock()
    private var packetHandler: ((WirePacket) -> Void)?
    private var stateHandler: ((NWConnection.State) -> Void)?

    private struct PendingSend {
        let kind: MessageKind
        let payload: Data
        let completion: ((Error?) -> Void)?
    }

    // Queue confined state.
    private var didStart = false
    private var isClosed = false
    private var hasReportedReady = false

    private var ownChallenge: Data?
    private var connectionReady = false
    private var handshakeSent = false
    private var handshakeComplete = false
    private var outboundKey: SymmetricKey?
    private var inboundKey: SymmetricKey?
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0

    private var pendingSends: [PendingSend] = []
    private var pendingSendBytes = 0
    private var sendInFlight = false

    private var receivePending = false
    private var buffer = Data()
    private var expectedBodyLength: Int?

    public init(connection: NWConnection, key: SymmetricKey, queue: DispatchQueue) {
        self.connection = connection
        self.preSharedKey = key
        self.queue = queue
    }

    deinit {
        // Nobody holds the channel any more; make sure the socket does not linger.
        connection.forceCancel()
    }

    /// Starts the connection, the handshake and the receive loop. Idempotent.
    public func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    /// Seals and sends one message once the handshake is complete. Work is
    /// serialized on the channel queue; `completion` fires exactly once, with a
    /// transport error if the write failed, or `channelClosed` if the message
    /// never went out. A successful completion means the message was handed to
    /// the transport; delivery is still subject to the peer's authentication.
    public func send(_ kind: MessageKind, payload: Data, completion: ((Error?) -> Void)?) {
        queue.async { [weak self] in
            guard let self else {
                completion?(WireError.channelClosed)
                return
            }
            self.sendOnQueue(kind: kind, payload: payload, completion: completion)
        }
    }

    /// Cancels the connection; queued and later sends fail with
    /// `WireError.channelClosed`.
    public func close() {
        queue.async { [weak self] in
            self?.shutDown()
        }
    }

    // MARK: Queue confined implementation

    private func startOnQueue() {
        guard !didStart, !isClosed else { return }
        didStart = true
        if ownChallenge == nil {
            ownChallenge = WireCrypto.randomChallenge()
        }
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleStateChange(state)
        }
        connection.start(queue: queue)
        receiveNextChunk()
    }

    private func sendOnQueue(kind: MessageKind, payload: Data, completion: ((Error?) -> Void)?) {
        guard !isClosed else {
            completion?(WireError.channelClosed)
            return
        }
        // Sending before `start()` is allowed; the socket is started eagerly so
        // that the handshake can begin. The message waits for the handshake.
        if !didStart {
            startOnQueue()
        }
        let bodySize = payload.count + WireCrypto.sequencedHeaderByteCount + WireCrypto.envelopeOverhead
        guard bodySize <= Wire.maxPacketBodyBytes else {
            completion?(WireError.payloadTooLarge(bodySize))
            return
        }
        guard pendingSends.count < Self.maxPendingSends,
              pendingSendBytes + payload.count <= Self.maxPendingSendBytes else {
            // Bounded queue: reject instead of buffering without limit.
            completion?(WireError.payloadTooLarge(pendingSendBytes + bodySize))
            return
        }
        pendingSends.append(PendingSend(kind: kind, payload: payload, completion: completion))
        pendingSendBytes += payload.count
        pumpSendQueue()
    }

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connectionReady = true
            sendHandshakeIfNeeded()
        case .failed, .cancelled:
            notifyState(state)
            shutDown()
        default:
            // setup / preparing / waiting: forward, but never claim ready here.
            notifyState(state)
        }
    }

    private func sendHandshakeIfNeeded() {
        guard !isClosed, !handshakeSent, connectionReady, !sendInFlight else { return }
        guard let challenge = ownChallenge else {
            fail(WireSessionError.handshakeMalformed)
            return
        }
        let frame: Data
        do {
            frame = try WireCrypto.handshakeFrame(challenge: challenge, preSharedKey: preSharedKey)
        } catch {
            fail(error)
            return
        }
        handshakeSent = true
        sendInFlight = true
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.sendInFlight = false
            guard !self.isClosed else { return }
            switch Self.handshakeSendOutcome(for: error) {
            case .delivered:
                self.pumpSendQueue()
            case .transportFailure(let transportError):
                // The key may well be correct; only the write failed. Forward
                // the raw transport error (never EPROTO) so the caller can
                // reconnect instead of declaring a pairing failure, and close
                // the channel so nothing is left half-open.
                self.notifyState(.failed(transportError))
                self.shutDown()
            }
        })
    }

    /// Sends at most one queued message at a time. Sequential sealing on the
    /// serial queue is what keeps nonces and sequence numbers ordered.
    private func pumpSendQueue() {
        guard !isClosed, handshakeComplete, !sendInFlight else { return }
        while !pendingSends.isEmpty {
            let item = pendingSends.removeFirst()
            pendingSendBytes -= item.payload.count
            guard let key = outboundKey else {
                item.completion?(WireError.channelClosed)
                continue
            }
            // Never wrap: exhausting the 64-bit space closes the channel.
            guard sendSequence != UInt64.max else {
                item.completion?(WireSessionError.sequenceOverflow)
                fail(WireSessionError.sequenceOverflow)
                return
            }
            let frame: Data
            do {
                frame = try WireCrypto.sealSequencedFrame(
                    kind: item.kind,
                    sequence: sendSequence,
                    payload: item.payload,
                    key: key
                )
            } catch {
                item.completion?(error)
                continue
            }
            sendSequence += 1
            sendInFlight = true
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                item.completion?(error)
                guard let self else { return }
                self.sendInFlight = false
                guard !self.isClosed else { return }
                if error != nil {
                    self.shutDown()
                } else {
                    self.pumpSendQueue()
                }
            })
            return
        }
    }

    private func receiveNextChunk() {
        guard !isClosed, !receivePending else { return }
        receivePending = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            self.receivePending = false
            guard !self.isClosed else { return }

            if error != nil {
                self.shutDown()
                return
            }
            if let content, !content.isEmpty {
                self.buffer.append(content)
            }
            guard self.drainBufferedFrames() else { return }
            if isComplete {
                // EOF without a protocol failure: the peer closed normally.
                self.shutDown()
                return
            }
            self.receiveNextChunk()
        }
    }

    /// Parses the handshake first, then as many complete, authenticated frames
    /// as the buffer holds. Returns `false` once the channel has been shut down.
    private func drainBufferedFrames() -> Bool {
        while !isClosed {
            if expectedBodyLength == nil {
                guard buffer.count >= 4 else { return true }
                let bodyLength = Int(buffer.prefix(4).reduce(into: UInt32(0)) { value, byte in
                    value = (value << 8) | UInt32(byte)
                })
                buffer.removeFirst(4)
                if !handshakeComplete {
                    // The first frame must be exactly one handshake body. This
                    // strict length is what prevents coalesced frames from
                    // being misread as each other.
                    guard bodyLength == Wire.handshakeBodyBytes else {
                        fail(WireSessionError.handshakeMalformed)
                        return false
                    }
                } else {
                    // Reject oversized or impossible lengths before buffering.
                    guard bodyLength >= Wire.minSequencedBodyBytes,
                          bodyLength <= Wire.maxPacketBodyBytes else {
                        fail(WireSessionError.handshakeMalformed)
                        return false
                    }
                }
                expectedBodyLength = bodyLength
            }

            guard let bodyLength = expectedBodyLength, buffer.count >= bodyLength else {
                return true
            }
            let body = Data(buffer.prefix(bodyLength))
            buffer.removeFirst(bodyLength)
            expectedBodyLength = nil

            if !handshakeComplete {
                guard processHandshake(body) else { return false }
                continue
            }

            guard let key = inboundKey else {
                fail(WireSessionError.handshakeMalformed)
                return false
            }
            guard receiveSequence != UInt64.max else {
                fail(WireSessionError.sequenceOverflow)
                return false
            }
            do {
                // AEAD first (kind/sequence are inside the ciphertext), then the
                // exact-sequence check: a replay decrypts but is rejected.
                let packet = try WireCrypto.openSequencedBody(
                    body,
                    key: key,
                    expectedSequence: receiveSequence
                )
                receiveSequence += 1
                currentPacketHandler?(packet)
            } catch {
                // Authentication failure, unknown kind, bad sequence: never
                // deliver, never keep the connection alive.
                fail(error)
                return false
            }
        }
        return false
    }

    private func processHandshake(_ body: Data) -> Bool {
        guard let challenge = ownChallenge else {
            fail(WireSessionError.handshakeMalformed)
            return false
        }
        let peerChallenge: Data
        do {
            peerChallenge = try WireCrypto.openHandshakeBody(body, preSharedKey: preSharedKey)
        } catch {
            fail(error)
            return false
        }
        guard peerChallenge != challenge else {
            fail(WireSessionError.handshakeChallengeRepeated)
            return false
        }
        let keys: (outbound: SymmetricKey, inbound: SymmetricKey)
        do {
            keys = try WireCrypto.deriveSessionKeys(
                preSharedKey: preSharedKey,
                ownChallenge: challenge,
                peerChallenge: peerChallenge
            )
        } catch {
            fail(error)
            return false
        }

        outboundKey = keys.outbound
        inboundKey = keys.inbound
        handshakeComplete = true
        if !hasReportedReady {
            hasReportedReady = true
            notifyState(.ready)
        }
        pumpSendQueue()
        return true
    }

    private func fail(_ error: Error) {
        guard !isClosed else { return }
        // `NWConnection.State.failed` carries an `NWError`; the session error
        // itself stays internal. Callers see an explicit protocol failure.
        notifyState(.failed(NWError.posix(.EPROTO)))
        shutDown()
    }

    private var currentPacketHandler: ((WirePacket) -> Void)? {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        return packetHandler
    }

    private var currentStateHandler: ((NWConnection.State) -> Void)? {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        return stateHandler
    }

    private func notifyState(_ state: NWConnection.State) {
        currentStateHandler?(state)
    }

    private func shutDown() {
        guard !isClosed else { return }
        isClosed = true
        receivePending = false
        buffer.removeAll(keepingCapacity: false)
        expectedBodyLength = nil
        outboundKey = nil
        inboundKey = nil
        let pending = pendingSends
        pendingSends.removeAll(keepingCapacity: false)
        pendingSendBytes = 0
        connection.cancel()
        for item in pending {
            item.completion?(WireError.channelClosed)
        }
    }
}
