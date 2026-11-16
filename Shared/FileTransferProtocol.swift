//
//  FileTransferProtocol.swift
//  XDRScreen
//
//  Pure, platform-independent helpers for the bidirectional file transfer
//  protocol. Compiled into both apps and exercised by WireRegression; this
//  file performs no I/O and touches no UI.
//
//  Transfer shape
//  --------------
//  One file at a time per direction. The sender offers metadata, the receiver
//  accepts or rejects, the sender streams 64 KiB chunks, then announces the
//  whole-file SHA-256:
//
//      sender                          receiver
//        | ---- fileOffer -------------> |
//        | <------------- fileAccept --- |   (or fileReject with a short code)
//        | ---- fileChunk * N ---------> |   offset must advance exactly
//        | ---- fileEnd (sha256) ------> |
//        |                              |   verify hash, rename temp -> final
//
//  `fileChunk` is the only binary payload:
//
//      UInt32 big-endian transfer id | UInt64 big-endian offset | raw bytes
//
//  The receiver requires every chunk to start at the exact number of bytes
//  already written and requires offset + count never to exceed the offered
//  size. Empty chunks, wrong ids, gaps, overlaps, oversized chunks and
//  overruns are protocol errors and abort the transfer.
//

import CryptoKit
import Foundation

/// Cross-platform constants and pure helpers for file transfer.
public enum FileTransfer {
    /// Payload bytes carried by one `fileChunk` message, excluding the header.
    public static let chunkByteCount = 64 * 1024

    /// 4-byte transfer id + 8-byte offset in front of every chunk's bytes.
    public static let chunkHeaderByteCount = 4 + 8

    /// Hard ceiling for one offered file (4 GiB).
    public static let maxFileByteCount: UInt64 = 4 * 1024 * 1024 * 1024

    /// Longest accepted file name, measured in UTF-8 bytes.
    public static let maxFileNameByteCount = 200

    /// Sender waits this long for a `fileAccept` before cancelling.
    public static let acceptTimeout: TimeInterval = 30

    /// Name used when sanitising produces nothing usable.
    public static let fallbackFileName = "file"

    /// Maximum number of chunks a sender may have handed to the transport but
    /// not yet seen completed.
    public static let maxInFlightChunks = 4

    /// Fixed `reason` codes shared by `fileReject` and `fileCancel`.
    public enum RejectReason: String, CaseIterable, Sendable {
        /// The receiver already has a transfer in progress in this direction.
        case busy
        /// The file exceeds `maxFileByteCount`.
        case tooLarge
        /// The offered name is unusable after sanitising.
        case invalidName
        /// The receiver could not create, write or rename the file.
        case io
        /// The user or the peer cancelled the transfer.
        case cancelled
        /// The payload does not follow this protocol (bad chunk, unknown id).
        case unsupported
    }

    // MARK: - File names

    /// Turns a peer-provided name into one safe to join with a directory.
    ///
    /// - Takes `lastPathComponent`, so any leading directories are discarded.
    /// - Removes Unicode control characters and the `/` and `\` separators.
    /// - Rejects `.` and `..` with `nil`; callers answer `invalidName`.
    /// - Falls back to `fallbackFileName` when nothing remains.
    /// - Truncates to `maxFileNameByteCount` UTF-8 bytes on a character
    ///   boundary, never splitting a scalar.
    ///
    /// The result is only a name: callers must still append it to a directory
    /// themselves and must not treat a successful return as a path check.
    public static func sanitizeFileName(_ raw: String) -> String? {
        let last = (raw as NSString).lastPathComponent

        var cleaned = ""
        cleaned.unicodeScalars.reserveCapacity(last.unicodeScalars.count)
        for scalar in last.unicodeScalars {
            if scalar == "/" || scalar == "\\" { continue }
            if CharacterSet.controlCharacters.contains(scalar) { continue }
            cleaned.unicodeScalars.append(scalar)
        }

        if cleaned == "." || cleaned == ".." { return nil }
        if cleaned.isEmpty { cleaned = fallbackFileName }
        if cleaned.utf8.count > maxFileNameByteCount {
            cleaned = truncateToUTF8Bytes(cleaned, maxBytes: maxFileNameByteCount)
        }
        // Truncation cannot empty a non-empty string (the first scalar is at
        // most 4 bytes and the budget is 200), but keep the invariant explicit.
        return cleaned.isEmpty ? fallbackFileName : cleaned
    }

    /// Returns `desired`, or the first free `"name 2.ext"`, `"name 3.ext"`, …
    ///
    /// `existing` may contain any names in the destination directory. The
    /// comparison is case-insensitive because the default macOS file system is,
    /// which also prevents "File.txt" and "file.txt" from colliding.
    ///
    /// `desired` is expected to have been sanitised already; if it is longer
    /// than the byte limit it is truncated like `sanitizeFileName` does.
    public static func uniqueFileName(_ desired: String, existing: Set<String>) -> String {
        var candidate = desired
        if candidate.isEmpty { candidate = fallbackFileName }
        if candidate.utf8.count > maxFileNameByteCount {
            candidate = truncateToUTF8Bytes(candidate, maxBytes: maxFileNameByteCount)
        }
        guard !candidate.isEmpty else { return fallbackFileName }

        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(candidate.lowercased()) else { return candidate }

        let parts = splitExtension(candidate)
        var counter = 2
        while true {
            let next = appending(counter: counter, to: parts.base, extension: parts.extension)
            if !taken.contains(next.lowercased()) { return next }
            counter += 1
        }
    }

    // MARK: - Chunks

    /// Validates one received chunk against the active offer.
    ///
    /// Returns `nil` when the chunk is acceptable, otherwise the first problem
    /// in wire order: wrong id, empty body, oversized body, non-contiguous
    /// offset, or a total that would exceed the offered size.
    public static func validateChunk(
        _ chunk: FileChunk,
        expectedID: UInt32,
        expectedOffset: UInt64,
        fileSize: UInt64
    ) -> FileChunkError? {
        guard chunk.id == expectedID else {
            return .wrongID(expected: expectedID, received: chunk.id)
        }
        guard !chunk.data.isEmpty else { return .emptyChunk }
        guard chunk.data.count <= chunkByteCount else {
            return .chunkTooLarge(count: chunk.data.count, limit: chunkByteCount)
        }
        guard chunk.offset == expectedOffset else {
            return .wrongOffset(expected: expectedOffset, received: chunk.offset)
        }
        let (end, overflow) = chunk.offset.addingReportingOverflow(UInt64(chunk.data.count))
        guard !overflow, end <= fileSize else {
            return .exceedsFileSize(offset: chunk.offset,
                                    length: chunk.data.count,
                                    fileSize: fileSize)
        }
        return nil
    }

    /// `true` when `offer` can be accepted as-is: its size is within the limit
    /// and its name survives sanitising.
    public static func offerRejectionReason(for offer: FileOfferMessage) -> RejectReason? {
        if offer.size > maxFileByteCount { return .tooLarge }
        guard let name = sanitizeFileName(offer.name), !name.isEmpty else {
            return .invalidName
        }
        return nil
    }

    // MARK: - Hashing and progress

    /// Lowercase hex SHA-256 of `data`.
    public static func sha256Hex(_ data: Data) -> String {
        hexString(SHA256.hash(data: data))
    }

    /// Lowercase hex representation of any byte sequence, used for an
    /// incrementally updated `SHA256` digest.
    public static func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var out = ""
        out.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return out
    }

    /// Fraction completed in `0...1`. A zero-byte file is complete at once.
    /// Values beyond `total` clamp to 1 instead of reporting >100%.
    public static func progress(transferred: UInt64, total: UInt64) -> Double {
        guard total > 0 else { return 1 }
        let value = Double(transferred) / Double(total)
        return min(1, max(0, value))
    }

    // MARK: - Internals

    private static let hexDigits = Array("0123456789abcdef")

    /// Splits `name` into stem and extension (extension includes the dot).
    /// A leading dot is treated as part of the stem, so `.env` has no
    /// extension and `archive.tar.gz` grows to `archive.tar 2.gz`.
    private static func splitExtension(_ name: String) -> (base: String, extension: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// Builds `base + " N" + ext`, truncated to the byte budget without
    /// cutting a character. The suffix always survives, so two calls with
    /// different counters cannot collapse to the same string.
    private static func appending(counter: Int, to base: String, extension ext: String) -> String {
        let suffix = " \(counter)"
        let suffixBytes = suffix.utf8.count
        let extBytes = ext.utf8.count

        if extBytes + suffixBytes >= maxFileNameByteCount {
            // A pathologically long extension leaves no room for both. Drop it
            // and keep the distinguishing counter at the end.
            let stemBudget = max(1, maxFileNameByteCount - suffixBytes)
            let stem = truncateToUTF8Bytes(base + ext, maxBytes: stemBudget)
            return (stem.isEmpty ? "f" : stem) + suffix
        }

        let stemBudget = max(1, maxFileNameByteCount - suffixBytes - extBytes)
        var stem = truncateToUTF8Bytes(base, maxBytes: stemBudget)
        if stem.isEmpty { stem = "f" }
        return stem + suffix + ext
    }

    /// Prefixes `text` with at most `maxBytes` UTF-8 bytes, stopping on a
    /// character boundary. Returns an empty string when the budget is too
    /// small for the first character.
    public static func truncateToUTF8Bytes(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.utf8.count > maxBytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let bytes = String(character).utf8.count
            guard used + bytes <= maxBytes else { break }
            result.append(character)
            used += bytes
        }
        return result
    }
}

// MARK: - Chunk payload

/// One `fileChunk` payload: big-endian id, big-endian offset, raw bytes.
public struct FileChunk: Equatable, Sendable {
    public static let headerByteCount = FileTransfer.chunkHeaderByteCount

    public let id: UInt32
    /// Number of file bytes written before this chunk's `data`.
    public let offset: UInt64
    public let data: Data

    public init(id: UInt32, offset: UInt64, data: Data) {
        self.id = id
        self.offset = offset
        self.data = data
    }

    /// Header bytes followed by the payload bytes.
    public func encoded() -> Data {
        var out = Data(capacity: Self.headerByteCount + data.count)
        var bigID = id.bigEndian
        withUnsafeBytes(of: &bigID) { out.append(contentsOf: $0) }
        var bigOffset = offset.bigEndian
        withUnsafeBytes(of: &bigOffset) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }

    /// Structural decode. Returns `nil` when the payload is shorter than the
    /// 12-byte header; range and ordering checks belong to
    /// `FileTransfer.validateChunk`.
    public static func decode(_ payload: Data) -> FileChunk? {
        guard payload.count >= headerByteCount else { return nil }
        let id = payload.prefix(4).reduce(into: UInt32(0)) { value, byte in
            value = (value << 8) | UInt32(byte)
        }
        let offset = payload.dropFirst(4).prefix(8).reduce(into: UInt64(0)) { value, byte in
            value = (value << 8) | UInt64(byte)
        }
        let body = Data(payload.dropFirst(headerByteCount))
        return FileChunk(id: id, offset: offset, data: body)
    }
}

/// Why a chunk cannot be applied to the file being received.
public enum FileChunkError: Error, Equatable, LocalizedError {
    case wrongID(expected: UInt32, received: UInt32)
    case emptyChunk
    case chunkTooLarge(count: Int, limit: Int)
    case wrongOffset(expected: UInt64, received: UInt64)
    case exceedsFileSize(offset: UInt64, length: Int, fileSize: UInt64)

    public var errorDescription: String? {
        switch self {
        case .wrongID(let expected, let received):
            return "Chunk id \(received) does not match transfer \(expected)."
        case .emptyChunk:
            return "A file chunk carried no bytes."
        case .chunkTooLarge(let count, let limit):
            return "Chunk of \(count) bytes exceeds the \(limit)-byte limit."
        case .wrongOffset(let expected, let received):
            return "Chunk offset \(received) is not the expected \(expected)."
        case .exceedsFileSize(let offset, let length, let fileSize):
            return "Chunk at \(offset) with \(length) bytes exceeds the \(fileSize)-byte file."
        }
    }
}
