//
//  PartitionIndexWAL.swift
//  database-server
//
//  Append-only WAL for per-document PQ indices (Phase: indices crash-consistency).
//
//  Before this WAL, PQ indices were persisted only by full plist rewrites of every
//  shard's indices dictionary — once per document put (write amplification) with a
//  3-second debounced fallback. A crash between an HNSW insert and that flush lost
//  the document's PQ index permanently: startup tombstoned the orphaned HNSW nodes
//  and the document required re-indexing.
//
//  With the WAL, each put appends one record (the single document's encoded
//  PartitionIndex) to its shard's `shard-<nodeId>-<i>-indices-wal` file in the same
//  actor turn as the HNSW topology-WAL drain. Startup replays these records on top
//  of the last full indices checkpoint, closing the crash window to a single append.
//

import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - PartitionIndexWALRecord

/// One mutation to a shard's PQ indices dictionary.
enum PartitionIndexWALRecord: Equatable {
    /// A document's PartitionIndex was stored (insert or upsert).
    /// `payload` is the binary-plist encoding of the `PartitionIndex` value —
    /// the same Codable layout as the full indices checkpoint files.
    case indexPut(documentId: String, payload: Data)
    /// A document's PartitionIndex was removed from this shard.
    case indexRemoved(documentId: String)
    /// Marks the end of one atomic mutation group; `readAll()` discards any
    /// uncommitted tail left by a crash mid-append.
    case commit
}

extension PartitionIndexWALRecord {
    fileprivate enum TypeCode: UInt8 {
        case indexPut     = 0x01
        case indexRemoved = 0x02
        case commit       = 0x05
    }

    var typeCode: UInt8 {
        switch self {
        case .indexPut:     return TypeCode.indexPut.rawValue
        case .indexRemoved: return TypeCode.indexRemoved.rawValue
        case .commit:       return TypeCode.commit.rawValue
        }
    }

    /// Encodes the record payload (excludes the type byte, length, and checksum).
    func encodePayload() -> Data {
        var buf = Data()
        switch self {
        case .indexPut(let documentId, let payload):
            buf.walString(documentId)
            buf.walUInt32(UInt32(payload.count))
            buf.append(payload)
        case .indexRemoved(let documentId):
            buf.walString(documentId)
        case .commit:
            break
        }
        return buf
    }

    static func decodePayload(typeCode: UInt8, data: Data) throws -> PartitionIndexWALRecord {
        var r = BinaryReader(data: data)
        switch typeCode {
        case TypeCode.indexPut.rawValue:
            let documentId = try r.string()
            let length = Int(try r.uint32())
            let payload = try r.bytes(length)
            return .indexPut(documentId: documentId, payload: payload)
        case TypeCode.indexRemoved.rawValue:
            return .indexRemoved(documentId: try r.string())
        case TypeCode.commit.rawValue:
            return .commit
        default:
            throw PartitionIndexWAL.WALError.unknownTypeCode(typeCode)
        }
    }
}

// MARK: - PartitionIndexWAL

/// Append-only WAL file for one shard's PQ index mutations.
///
/// **Format (per record)** — identical framing to `HNSWTopologyWAL`:
/// ```
/// [typeCode: UInt8][payloadLen: UInt32 LE][payload: bytes][checksum: UInt32 LE]
/// ```
/// Adler-32 checksum over the payload detects truncation and bit-flip corruption;
/// `readAll()` stops at the first invalid record and discards any uncommitted tail.
///
/// **Concurrency:** All writes happen from within the TableMutator actor, so no
/// additional locking is needed. `O_APPEND` keeps writes position-independent.
final class PartitionIndexWAL: @unchecked Sendable {

    enum WALError: Error {
        case openFailed(Int32)
        case writeFailed(Int32)
        case truncateFailed(Int32)
        case truncatedRecord
        case unknownTypeCode(UInt8)
    }

    private let fd: Int32
    /// Current byte length of the WAL file. Updated after every successful append.
    private(set) var byteSize: Int

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rawFd = open(url.path, O_RDWR | O_CREAT | O_APPEND,
                         S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard rawFd >= 0 else { throw WALError.openFailed(errno) }
        fd = rawFd

        var s = stat()
        fstat(fd, &s)
        byteSize = Int(s.st_size)
    }

    deinit { close(fd) }

    // MARK: - Write

    /// Appends one record. PQ index payloads are typically a few KB (codebooks
    /// for small per-document k plus lean slots).
    func append(_ record: PartitionIndexWALRecord) throws {
        let payload  = record.encodePayload()
        let checksum = adler32(payload)

        var buf = Data(capacity: 9 + payload.count)
        buf.walUInt8(record.typeCode)
        buf.walUInt32(UInt32(payload.count))
        buf.append(payload)
        buf.walUInt32(checksum)

        let n = buf.withUnsafeBytes { ptr -> Int in
            Foundation.write(fd, ptr.baseAddress!, ptr.count)
        }
        guard n == buf.count else { throw WALError.writeFailed(errno) }
        byteSize += buf.count
    }

    // MARK: - Read

    /// Reads all committed records in insertion order; discards any uncommitted
    /// or corrupt tail (normal result of a crash mid-append).
    func readAll() throws -> [PartitionIndexWALRecord] {
        guard byteSize > 0 else { return [] }

        var fileData = Data(count: byteSize)
        let n = fileData.withUnsafeMutableBytes { ptr -> Int in
            pread(fd, ptr.baseAddress!, byteSize, 0)
        }
        guard n > 0 else { return [] }
        let available = n

        var committed: [PartitionIndexWALRecord] = []
        var pending:   [PartitionIndexWALRecord] = []
        var offset = 0

        while offset + 9 <= available {
            let typeCode   = fileData[offset]
            let payloadLen = Int(
                UInt32(fileData[offset + 1])        |
                (UInt32(fileData[offset + 2]) << 8) |
                (UInt32(fileData[offset + 3]) << 16) |
                (UInt32(fileData[offset + 4]) << 24)
            )
            offset += 5

            guard offset + payloadLen + 4 <= available else { break }  // truncated

            let payload = fileData[offset ..< (offset + payloadLen)]
            offset += payloadLen

            let stored = UInt32(fileData[offset])        |
                        (UInt32(fileData[offset + 1]) << 8)  |
                        (UInt32(fileData[offset + 2]) << 16) |
                        (UInt32(fileData[offset + 3]) << 24)
            offset += 4

            guard adler32(payload) == stored else { break }
            guard let rec = try? PartitionIndexWALRecord.decodePayload(typeCode: typeCode, data: payload)
            else { break }

            if rec == .commit {
                committed.append(contentsOf: pending)
                pending = []
            } else {
                pending.append(rec)
            }
        }

        return committed
    }

    // MARK: - Checkpoint truncation

    /// Truncates the WAL to zero bytes after a full indices checkpoint is durable.
    func truncate() throws {
        guard ftruncate(fd, 0) == 0 else { throw WALError.truncateFailed(errno) }
        byteSize = 0
    }
}

// MARK: - Private helpers

private func adler32(_ data: Data) -> UInt32 {
    var a: UInt32 = 1
    var b: UInt32 = 0
    for byte in data {
        a = (a &+ UInt32(byte)) % 65521
        b = (b &+ a) % 65521
    }
    return (b << 16) | a
}

private struct BinaryReader {
    private let data: Data
    private var offset: Int = 0

    init(data: Data) { self.data = data }

    mutating func uint16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw PartitionIndexWAL.WALError.truncatedRecord }
        defer { offset += 2 }
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    mutating func uint32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw PartitionIndexWAL.WALError.truncatedRecord }
        defer { offset += 4 }
        let i = data.startIndex + offset
        return UInt32(data[i]) | (UInt32(data[i+1]) << 8) | (UInt32(data[i+2]) << 16) | (UInt32(data[i+3]) << 24)
    }

    mutating func bytes(_ length: Int) throws -> Data {
        guard offset + length <= data.count else { throw PartitionIndexWAL.WALError.truncatedRecord }
        defer { offset += length }
        let i = data.startIndex + offset
        return Data(data[i ..< (i + length)])
    }

    mutating func string() throws -> String {
        let len = Int(try uint16())
        guard offset + len <= data.count else { throw PartitionIndexWAL.WALError.truncatedRecord }
        defer { offset += len }
        let i = data.startIndex + offset
        return String(data: data[i ..< (i + len)], encoding: .utf8) ?? ""
    }
}

private extension Data {
    mutating func walUInt8(_ v: UInt8)  { append(v) }
    mutating func walUInt16(_ v: UInt16) {
        append(UInt8(v & 0xff)); append(UInt8((v >> 8) & 0xff))
    }
    mutating func walUInt32(_ v: UInt32) {
        append(UInt8( v        & 0xff))
        append(UInt8((v >>  8) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 24) & 0xff))
    }
    mutating func walString(_ s: String) {
        let bytes = Array(s.utf8.prefix(65535))
        walUInt16(UInt16(bytes.count))
        append(contentsOf: bytes)
    }
}
