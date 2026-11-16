//
//  FileTransferRegression.swift
//  WireRegression
//
//  Coverage for the bidirectional file transfer protocol: stable kind bytes,
//  every JSON message, the binary chunk header, offset/size validation,
//  file-name sanitising and uniquing, size limits, hashing and progress.
//
//  Nothing here touches the file system or a network socket.
//

import CryptoKit
import Foundation
import XDRScreenWire

func testFileTransfer(_ report: Report) {
    print("\n[?] File transfer protocol")
    testFileTransferKinds(report)
    testFileTransferMessages(report)
    testFileChunkCodec(report)
    testFileChunkValidation(report)
    testFileNameSanitising(report)
    testUniqueFileNames(report)
    testFileTransferLimits(report)
    testFileTransferHashAndProgress(report)
}

// MARK: - Kinds

private func testFileTransferKinds(_ report: Report) {
    report.check(MessageKind.fileOffer.rawValue == 9, "fileOffer kind byte is 9")
    report.check(MessageKind.fileAccept.rawValue == 10, "fileAccept kind byte is 10")
    report.check(MessageKind.fileReject.rawValue == 11, "fileReject kind byte is 11")
    report.check(MessageKind.fileChunk.rawValue == 12, "fileChunk kind byte is 12")
    report.check(MessageKind.fileEnd.rawValue == 13, "fileEnd kind byte is 13")
    report.check(MessageKind.fileCancel.rawValue == 14, "fileCancel kind byte is 14")

    report.check(MessageKind(rawValue: 1) == .hello
                 && MessageKind(rawValue: 4) == .input
                 && MessageKind(rawValue: 8) == .clientSettings,
                 "existing kind bytes 1–8 are unchanged")

    let rawValues = Set(MessageKind.allCases.map { $0.rawValue })
    report.equal(rawValues.count, MessageKind.allCases.count,
                 "every message kind has a distinct kind byte")
    report.equal(MessageKind.allCases.count, 14, "14 message kinds are defined")
}

// MARK: - JSON messages

private func testFileTransferMessages(_ report: Report) {
    do {
        let offer = FileOfferMessage(id: 42, name: "报告.pdf", size: 12_345)
        let data = try WireJSON.encode(offer)
        report.equal(try WireJSON.decode(FileOfferMessage.self, from: data), offer,
                     "fileOffer round trips through WireJSON")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        report.equal(Set((object ?? [:]).keys), ["id", "name", "size"],
                     "fileOffer encodes exactly id, name and size")
        report.equal((object?["id"] as? NSNumber)?.uint32Value, 42,
                     "fileOffer id is a JSON number")
        report.equal((object?["size"] as? NSNumber)?.uint64Value, 12_345,
                     "fileOffer size is a JSON number")
    } catch {
        report.check(false, "fileOffer encoding", "\(error)")
    }

    do {
        let accept = FileAcceptMessage(id: UInt32.max)
        let data = try WireJSON.encode(accept)
        report.equal(try WireJSON.decode(FileAcceptMessage.self, from: data), accept,
                     "fileAccept round trips through WireJSON")
    } catch {
        report.check(false, "fileAccept encoding", "\(error)")
    }

    do {
        let reject = FileRejectMessage(id: 7, reason: .tooLarge)
        let data = try WireJSON.encode(reject)
        let decoded = try WireJSON.decode(FileRejectMessage.self, from: data)
        report.equal(decoded, reject, "fileReject round trips through WireJSON")
        report.equal(decoded.reason, "tooLarge", "reject reason uses the fixed short code")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        report.equal(Set((object ?? [:]).keys), ["id", "reason"],
                     "fileReject encodes exactly id and reason")
    } catch {
        report.check(false, "fileReject encoding", "\(error)")
    }

    do {
        let end = FileEndMessage(id: 9,
                                 sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let data = try WireJSON.encode(end)
        report.equal(try WireJSON.decode(FileEndMessage.self, from: data), end,
                     "fileEnd round trips through WireJSON")
    } catch {
        report.check(false, "fileEnd encoding", "\(error)")
    }

    do {
        let cancel = FileCancelMessage(id: 11, reason: .cancelled)
        let data = try WireJSON.encode(cancel)
        report.equal(try WireJSON.decode(FileCancelMessage.self, from: data), cancel,
                     "fileCancel round trips through WireJSON")
        report.equal(cancel.reason, "cancelled", "cancel reason uses the fixed short code")
    } catch {
        report.check(false, "fileCancel encoding", "\(error)")
    }

    // All six codes survive as plain JSON strings.
    let codes = FileTransfer.RejectReason.allCases.map { $0.rawValue }
    report.equal(Set(codes), ["busy", "tooLarge", "invalidName", "io", "cancelled", "unsupported"],
                 "reject/cancel reasons are exactly the six short codes")

    // The new kinds travel inside the authenticated envelope unchanged.
    do {
        let key = SymmetricKey(size: .bits256)
        let payload = Data([0x00, 0x01, 0x02, 0x03])
        let body = try WireCrypto.sealBody(kind: .fileChunk, payload: payload, key: key)
        let packet = try WireCrypto.openBody(body, key: key)
        report.equal(packet.kind, .fileChunk, "fileChunk kind survives AES-GCM sealing")
        report.equal(packet.payload, payload, "fileChunk payload survives AES-GCM sealing")
    } catch {
        report.check(false, "fileChunk envelope round trip", "\(error)")
    }
}

// MARK: - Chunk header

private func testFileChunkCodec(_ report: Report) {
    report.equal(FileTransfer.chunkByteCount, 64 * 1024, "chunk payload limit is 64 KiB")
    report.equal(FileChunk.headerByteCount, 12, "chunk header is 4 + 8 bytes")

    let data = Data([0xAA, 0xBB, 0xCC])
    let chunk = FileChunk(id: 0x0102_0304, offset: 0x0102_0304_0506_0708, data: data)
    let encoded = chunk.encoded()

    report.equal(encoded.count, 12 + data.count, "encoded chunk is header plus payload")
    report.equal(Array(encoded.prefix(4)), [0x01, 0x02, 0x03, 0x04],
                 "transfer id is 4-byte big-endian")
    report.equal(Array(encoded.dropFirst(4).prefix(8)),
                 [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08],
                 "offset is 8-byte big-endian")
    report.equal(Array(encoded.suffix(3)), [0xAA, 0xBB, 0xCC],
                 "raw bytes follow the header untouched")
    report.equal(FileChunk.decode(encoded), chunk, "chunk header and body decode back")

    report.check(FileChunk.decode(Data()) == nil, "an empty payload has no chunk header")
    report.check(FileChunk.decode(Data(count: 11)) == nil,
                 "an 11-byte payload is too short for the header")
    report.equal(FileChunk.decode(Data(count: 12)),
                 FileChunk(id: 0, offset: 0, data: Data()),
                 "a header-only payload decodes with empty data")

    let maxOffset = FileChunk(id: UInt32.max, offset: UInt64.max, data: Data([1]))
    report.equal(FileChunk.decode(maxOffset.encoded()), maxOffset,
                 "maximum id and offset survive the header")

    // A full-size chunk adds exactly 12 bytes of overhead.
    let full = FileChunk(id: 1, offset: 0, data: Data(repeating: 0x5A,
                                                     count: FileTransfer.chunkByteCount))
    let fullEncoded = full.encoded()
    report.equal(fullEncoded.count, FileTransfer.chunkByteCount + 12,
                 "a full chunk is 64 KiB plus the 12-byte header")
    report.equal(FileChunk.decode(fullEncoded), full, "a full-size chunk round trips")
}

// MARK: - Chunk validation

private func testFileChunkValidation(_ report: Report) {
    func validate(id: UInt32 = 1,
                  offset: UInt64 = 0,
                  bytes: Int = 100,
                  expectedID: UInt32 = 1,
                  expectedOffset: UInt64 = 0,
                  fileSize: UInt64 = 1_000) -> FileChunkError? {
        FileTransfer.validateChunk(
            FileChunk(id: id, offset: offset, data: Data(repeating: 0x41, count: bytes)),
            expectedID: expectedID,
            expectedOffset: expectedOffset,
            fileSize: fileSize
        )
    }

    report.check(validate() == nil, "a contiguous in-range chunk is accepted")
    report.check(validate(offset: 900, bytes: 100, expectedOffset: 900) == nil,
                 "a final chunk that ends exactly at the file size is accepted")
    report.check(validate(bytes: FileTransfer.chunkByteCount,
                          fileSize: UInt64(FileTransfer.chunkByteCount)) == nil,
                 "a full 64 KiB chunk is accepted at the limit")

    report.equal(validate(id: 2), .wrongID(expected: 1, received: 2),
                 "a chunk for another transfer id is rejected")
    report.equal(validate(offset: 50), .wrongOffset(expected: 0, received: 50),
                 "a chunk that skips ahead is rejected")
    report.equal(validate(offset: 0, expectedOffset: 100),
                 .wrongOffset(expected: 100, received: 0),
                 "an overlapping chunk is rejected")
    report.equal(validate(bytes: 0), .emptyChunk,
                 "an empty chunk is rejected")
    report.equal(validate(bytes: FileTransfer.chunkByteCount + 1,
                          fileSize: UInt64(FileTransfer.chunkByteCount + 1)),
                 .chunkTooLarge(count: FileTransfer.chunkByteCount + 1,
                                limit: FileTransfer.chunkByteCount),
                 "a chunk larger than 64 KiB is rejected")
    report.equal(validate(offset: 950, bytes: 100, expectedOffset: 950),
                 .exceedsFileSize(offset: 950, length: 100, fileSize: 1_000),
                 "a chunk that would run past the offered size is rejected")
    report.equal(validate(offset: 0, bytes: 1, fileSize: 0),
                 .exceedsFileSize(offset: 0, length: 1, fileSize: 0),
                 "no data chunk fits a zero-byte offer")
    report.equal(validate(offset: UInt64.max, bytes: 1, expectedOffset: UInt64.max,
                          fileSize: UInt64.max),
                 .exceedsFileSize(offset: UInt64.max, length: 1, fileSize: UInt64.max),
                 "offset + length overflow is rejected instead of wrapping")

    // Walking a file in order is accepted at every step.
    var offset: UInt64 = 0
    var allAccepted = true
    for index in 0 ..< 5 {
        let size = index == 4 ? 37 : FileTransfer.chunkByteCount
        let error = FileTransfer.validateChunk(
            FileChunk(id: 3, offset: offset, data: Data(repeating: 0, count: size)),
            expectedID: 3,
            expectedOffset: offset,
            fileSize: 4 * UInt64(FileTransfer.chunkByteCount) + 37
        )
        if error != nil { allAccepted = false }
        offset += UInt64(size)
    }
    report.check(allAccepted, "a normal chunk sequence validates at every offset")
    report.equal(offset, 4 * UInt64(FileTransfer.chunkByteCount) + 37,
                 "the chunk sequence covers the whole file exactly")

    for error in [FileChunkError.emptyChunk,
                  .wrongID(expected: 1, received: 9),
                  .wrongOffset(expected: 0, received: 4),
                  .chunkTooLarge(count: 70_000, limit: 65_536),
                  .exceedsFileSize(offset: 1, length: 2, fileSize: 2)] {
        report.check((error.errorDescription?.isEmpty == false),
                     "chunk error \(error) has a description")
    }
}

// MARK: - Names

private func testFileNameSanitising(_ report: Report) {
    report.equal(FileTransfer.sanitizeFileName("photos/cat.jpg"), "cat.jpg",
                 "leading path components are dropped")
    report.equal(FileTransfer.sanitizeFileName("a\\b.txt"), "ab.txt",
                 "backslashes are removed")
    report.equal(FileTransfer.sanitizeFileName("bad\u{0}name.txt"), "badname.txt",
                 "NUL bytes are removed")
    report.equal(FileTransfer.sanitizeFileName("line\nbreak\t.txt"), "linebreak.txt",
                 "control characters are removed")
    report.equal(FileTransfer.sanitizeFileName("a/b/c/"), "c",
                 "a trailing separator keeps the last component")
    report.equal(FileTransfer.sanitizeFileName(""), "file",
                 "an empty name falls back to file")
    report.equal(FileTransfer.sanitizeFileName("/"), "file",
                 "a separator-only name falls back to file")
    report.equal(FileTransfer.sanitizeFileName("\u{7}\u{1}"), "file",
                 "a control-only name falls back to file")
    report.check(FileTransfer.sanitizeFileName(".") == nil,
                 "a single dot is rejected")
    report.check(FileTransfer.sanitizeFileName("..") == nil,
                 "a double dot is rejected")
    report.check(FileTransfer.sanitizeFileName("a/..") == nil,
                 "a trailing double dot is rejected after lastPathComponent")
    report.equal(FileTransfer.sanitizeFileName("../secret"), "secret",
                 "a parent traversal keeps only the file name")

    let exact = String(repeating: "x", count: FileTransfer.maxFileNameByteCount)
    report.equal(FileTransfer.sanitizeFileName(exact), exact,
                 "a name at exactly 200 UTF-8 bytes is kept")

    let longASCII = String(repeating: "x", count: 250)
    let truncatedASCII = FileTransfer.sanitizeFileName(longASCII)
    report.equal(truncatedASCII?.utf8.count, 200,
                 "an overlong ASCII name is truncated to 200 bytes")

    let longCJK = String(repeating: "文", count: 100)
    let truncatedCJK = FileTransfer.sanitizeFileName(longCJK)
    report.equal(truncatedCJK?.utf8.count, 198,
                 "CJK truncation stops at a 3-byte character boundary")
    report.check((truncatedCJK?.unicodeScalars.allSatisfy { $0 == "文" }) == true,
                 "CJK truncation never splits a scalar")

    let emoji = String(repeating: "😀", count: 60)
    let truncatedEmoji = FileTransfer.sanitizeFileName(emoji)
    report.equal(truncatedEmoji?.utf8.count, 200,
                 "4-byte emoji truncate at exactly 200 bytes")
    report.equal(truncatedEmoji?.count, 50,
                 "emoji truncation keeps whole characters")
}

private func testUniqueFileNames(_ report: Report) {
    report.equal(FileTransfer.uniqueFileName("a.txt", existing: []), "a.txt",
                 "a free name is returned unchanged")
    report.equal(FileTransfer.uniqueFileName("a.txt", existing: ["a.txt"]), "a 2.txt",
                 "a taken name gets a 2 suffix before the extension")
    report.equal(FileTransfer.uniqueFileName("a.txt", existing: ["a.txt", "a 2.txt"]), "a 3.txt",
                 "the next free number is chosen")
    report.equal(FileTransfer.uniqueFileName("a.txt", existing: ["A.TXT"]), "a 2.txt",
                 "name comparison is case-insensitive")
    report.equal(FileTransfer.uniqueFileName("file", existing: ["file"]), "file 2",
                 "a name without an extension gets the suffix at the end")
    report.equal(FileTransfer.uniqueFileName(".env", existing: [".env"]), ".env 2",
                 "a dotfile is treated as having no extension")
    report.equal(FileTransfer.uniqueFileName("archive.tar.gz", existing: ["archive.tar.gz"]),
                 "archive.tar 2.gz",
                 "only the final extension is kept behind the suffix")
    report.equal(FileTransfer.uniqueFileName("a.", existing: ["a."]), "a 2.",
                 "a trailing dot still acts as an extension separator")
    report.equal(FileTransfer.uniqueFileName("", existing: []), "file",
                 "an empty desired name becomes file")

    let longBase = String(repeating: "y", count: 196) + ".txt"
    report.equal(longBase.utf8.count, 200, "test fixture is exactly 200 bytes")
    let uniqueLong = FileTransfer.uniqueFileName(longBase, existing: [longBase])
    report.check(uniqueLong.utf8.count <= FileTransfer.maxFileNameByteCount,
                 "an appended suffix never exceeds 200 bytes",
                 "got \(uniqueLong.utf8.count) bytes")
    report.check(uniqueLong.hasSuffix(".txt"),
                 "the extension survives truncation")
    report.check(uniqueLong != longBase,
                 "the uniqued long name differs from the taken one")
}

// MARK: - Limits

private func testFileTransferLimits(_ report: Report) {
    report.equal(FileTransfer.maxFileByteCount, 4 * 1024 * 1024 * 1024,
                 "the per-file limit is 4 GiB")
    report.equal(FileTransfer.maxFileNameByteCount, 200,
                 "the name limit is 200 UTF-8 bytes")
    report.equal(FileTransfer.acceptTimeout, 30,
                 "the sender waits 30 seconds for an accept")
    report.equal(FileTransfer.maxInFlightChunks, 4,
                 "the sender keeps at most four chunks in flight")

    let atLimit = FileOfferMessage(id: 1, name: "big.bin", size: FileTransfer.maxFileByteCount)
    report.check(FileTransfer.offerRejectionReason(for: atLimit) == nil,
                 "an offer at exactly 4 GiB is accepted")

    let overLimit = FileOfferMessage(id: 1, name: "big.bin", size: FileTransfer.maxFileByteCount + 1)
    report.equal(FileTransfer.offerRejectionReason(for: overLimit), .tooLarge,
                 "an offer one byte over 4 GiB is rejected as tooLarge")

    let emptyFile = FileOfferMessage(id: 2, name: "empty.txt", size: 0)
    report.check(FileTransfer.offerRejectionReason(for: emptyFile) == nil,
                 "a zero-byte file is a valid offer")

    let dot = FileOfferMessage(id: 3, name: ".", size: 10)
    report.equal(FileTransfer.offerRejectionReason(for: dot), .invalidName,
                 "an offer named . is rejected as invalidName")

    let dotdot = FileOfferMessage(id: 4, name: "..", size: 10)
    report.equal(FileTransfer.offerRejectionReason(for: dotdot), .invalidName,
                 "an offer named .. is rejected as invalidName")

    let blank = FileOfferMessage(id: 5, name: "", size: 10)
    report.check(FileTransfer.offerRejectionReason(for: blank) == nil,
                 "an empty offer name falls back to file instead of being rejected")
}

// MARK: - Hashing and progress

private func testFileTransferHashAndProgress(_ report: Report) {
    report.equal(FileTransfer.sha256Hex(Data()),
                 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                 "SHA-256 of empty data is the known vector")
    report.equal(FileTransfer.sha256Hex(Data("abc".utf8)),
                 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                 "SHA-256 of abc is the known vector")
    report.equal(FileTransfer.hexString([0x00, 0x0F, 0xFF] as [UInt8]),
                 "000fff", "hex output is lowercase and zero padded")
    report.equal(FileTransfer.hexString([UInt8]()), "", "hex of no bytes is empty")

    var hasher = SHA256()
    hasher.update(data: Data("a".utf8))
    hasher.update(data: Data("bc".utf8))
    report.equal(FileTransfer.hexString(hasher.finalize()),
                 FileTransfer.sha256Hex(Data("abc".utf8)),
                 "incremental hashing matches one-shot hashing")

    report.equal(FileTransfer.progress(transferred: 0, total: 100), 0,
                 "progress starts at 0")
    report.equal(FileTransfer.progress(transferred: 50, total: 100), 0.5,
                 "progress is transferred / total")
    report.equal(FileTransfer.progress(transferred: 100, total: 100), 1,
                 "progress reaches 1 at completion")
    report.equal(FileTransfer.progress(transferred: 150, total: 100), 1,
                 "progress clamps above 1")
    report.equal(FileTransfer.progress(transferred: 0, total: 0), 1,
                 "a zero-byte file is complete immediately")
    report.equal(FileTransfer.progress(transferred: UInt64.max, total: UInt64.max), 1,
                 "maximum counters still produce a valid fraction")
}
