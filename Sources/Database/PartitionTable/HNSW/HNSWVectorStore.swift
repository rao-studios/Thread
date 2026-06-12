//
//  HNSWVectorStore.swift
//  database-server
//
//  Created by Ritesh Pakala on 4/3/26.
//

import Foundation

// POSIX mmap / file APIs used below (available via Foundation's transitive includes
// on both Darwin and Linux).
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - VectorAccessor

/// A read-only view into the mmap'd vector file.
///
/// Valid only for the duration of the `HNSWVectorStore.withReadAccess` closure that
/// produced it — the read lock is held for that duration. Never store or escape this value.
struct VectorAccessor {
    fileprivate let ptr:       UnsafeRawPointer
    fileprivate let nodeCount: Int

    /// Unsafely returns a buffer pointer to node `index`'s 1024 Float32 values.
    ///
    /// - Precondition: `index < nodeCount` and the read lock must still be held
    ///   (guaranteed by the `withReadAccess` scope that produced this accessor).
    @inline(__always)
    func vector(at index: Int) -> UnsafeBufferPointer<Float> {
        precondition(index < nodeCount, "VectorAccessor.vector(at:) index \(index) out of range (\(nodeCount) nodes)")
        return UnsafeBufferPointer(
            start: ptr.advanced(by: index * HNSWVectorStore.vectorStride)
                       .assumingMemoryBound(to: Float.self),
            count: HNSWVectorStore.vectorDim
        )
    }

    /// Returns `true` when `index` is a valid slot for this accessor.
    /// Use this to skip nodes with a stale `vectorIndex` before calling `vector(at:)`.
    @inline(__always)
    func isValid(index: Int) -> Bool { index >= 0 && index < nodeCount }
}

// MARK: - HNSWVectorStore

/// Memory-mapped binary store for HNSW node embeddings.
///
/// Replaces the in-memory `vectorBuffer: Data` approach used in Phase 1+2.
/// Instead of loading the full 4 GB (at 1M nodes) vector file into RAM at
/// startup, the file is mapped into the process's virtual address space.
/// The OS page cache loads only the pages touched during traversal —
/// typically 1–5% of nodes per query = 40–200 MB of physical RAM.
///
/// **Concurrency model:**
///
/// - Multiple readers (searches) may hold a read lock simultaneously via
///   `withReadAccess`. The `VectorAccessor` they receive is valid for the
///   duration of the closure.
/// - Writers (insert append, compact rewrite) acquire the write lock to
///   remap the file. Appends only acquire the write lock when the current
///   capacity is exhausted; within-capacity appends are lock-free (they write
///   to a region no reader has a pointer into yet).
/// - Compact (`rewrite(order:)`) always acquires the write lock, blocking
///   until all active searches finish before remapping.
///
/// **Shared-reference semantics:**
///
/// `HNSWVectorStore` is a class held inside an `HNSWGraph` struct. Struct
/// copies (e.g., `PartitionTable` snapshots) share the same store reference.
/// This is intentional — reads from snapshots access the live mmap'd data.
/// Only mutators (`TableMutator`, `PersonalHNSWMutator`) ever call `append`
/// or `rewrite`; they are always actor-isolated so there is no concurrent
/// write contention.
final class HNSWVectorStore: @unchecked Sendable {

    // MARK: - Constants (mirrors HNSWGraph to avoid circular dependency)

    static let vectorDim    = 1024
    static let vectorStride = vectorDim * MemoryLayout<Float>.size   // 4 096 bytes

    // MARK: - State

    private var fd:            Int32
    private var ptr:           UnsafeMutableRawPointer
    private var mappedLength:  Int     // current mmap region size in bytes
    private(set) var nodeCount: Int    // number of live nodes (slots 0 ..< nodeCount are valid)
    private var capacity:      Int     // total mapped capacity in nodes (>= nodeCount)
    private let url:           URL
    private var rwlock = pthread_rwlock_t()

    /// `true` when the file did not exist before this `init` call.
    ///
    /// A freshly-created file is zero-filled by `ftruncate` — it contains no valid
    /// embedding data even though `isValidFor` returns `true` (the file is large enough).
    /// Callers that are attaching a store to an existing topology (e.g., personal HNSW
    /// migration from Phase 1+2) must check this flag and wipe the topology when `true`,
    /// rather than serving distances computed against zero vectors.
    let wasCreatedFresh: Bool

    /// Nodes per growth step (~4 MB per step at 4 096 B/node).
    private static let growChunk = 1_000

    // MARK: - Init / deinit

    /// Open or create the vector file and map it.
    ///
    /// - Parameter nodeCount: Expected number of live nodes (from the matching topology).
    ///   The file is extended to at least `capacity * vectorStride` bytes.
    ///   If the file is larger than needed (e.g., leftover after a failed compact),
    ///   the extra bytes are mapped but ignored; `nodeCount` is authoritative.
    ///
    /// - Throws: `VectorStoreError` if the file cannot be opened, truncated, or mapped.
    init(url: URL, nodeCount: Int) throws {
        self.url       = url
        self.nodeCount = nodeCount
        self.capacity  = Self.roundUpToChunk(nodeCount)

        pthread_rwlock_init(&rwlock, nil)

        // Ensure the parent directory exists (e.g. totem-db/personal/).
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // O_RDWR | O_CREAT: open existing or create new.
        let flags: Int32 = O_RDWR | O_CREAT
        let mode:  mode_t = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        fd = open(url.path, flags, mode)
        guard fd >= 0 else { throw VectorStoreError.openFailed(errno) }

        let targetSize = capacity * Self.vectorStride

        // Capture fd as a local to avoid an implicit self reference before
        // wasCreatedFresh is assigned (Swift requires all stored properties to
        // be initialised before self can be used).
        let openedFd = fd
        var fileStat = stat()
        fstat(openedFd, &fileStat)
        let currentSize = Int(fileStat.st_size)

        // Record whether this is a brand-new file before any ftruncate extension.
        // A file with size 0 means it was just created by O_CREAT — its bytes are
        // not valid embedding data even after ftruncate zero-fills it to capacity.
        wasCreatedFresh = currentSize == 0

        // Extend the file if it is smaller than the required capacity.
        if currentSize < targetSize {
            guard ftruncate(fd, off_t(targetSize)) == 0 else {
                close(fd)
                throw VectorStoreError.truncateFailed(errno)
            }
        }

        // Map the larger of {current file, required capacity}.
        mappedLength = max(currentSize, targetSize)
        let raw = mmap(nil, mappedLength, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let raw, raw != MAP_FAILED else {
            close(fd)
            throw VectorStoreError.mmapFailed(errno)
        }
        ptr = raw
    }

    deinit {
        pthread_rwlock_wrlock(&rwlock)
        msync(ptr, mappedLength, MS_SYNC)
        munmap(ptr, mappedLength)
        close(fd)
        pthread_rwlock_unlock(&rwlock)
        pthread_rwlock_destroy(&rwlock)
    }

    // MARK: - Errors

    enum VectorStoreError: Error {
        case openFailed(Int32)
        case truncateFailed(Int32)
        case mmapFailed(Int32)
    }

    // MARK: - Validity check

    /// Returns `true` if the file contains at least `nodeCount` complete vector slots.
    func isValidFor(nodeCount: Int) -> Bool {
        guard nodeCount > 0 else { return true }
        var s = stat()
        fstat(fd, &s)
        return Int(s.st_size) >= nodeCount * Self.vectorStride
    }

    // MARK: - Read path

    /// Acquires the read lock and calls `body` with a `VectorAccessor` valid for the
    /// duration of the closure. Multiple callers may hold the read lock simultaneously.
    ///
    /// - Important: Do NOT call `withReadAccess` recursively from within `body` —
    ///   POSIX rwlocks are not recursive and will deadlock.
    @inline(__always)
    @discardableResult
    func withReadAccess<R>(_ body: (VectorAccessor) -> R) -> R {
        pthread_rwlock_rdlock(&rwlock)
        defer { pthread_rwlock_unlock(&rwlock) }
        return body(VectorAccessor(ptr: UnsafeRawPointer(ptr), nodeCount: nodeCount))
    }

    // MARK: - Write path — append

    /// Appends one node's 1024-float embedding to the file.
    ///
    /// Does **not** acquire the write lock if there is remaining capacity — the new
    /// slot is outside the range any reader has an index into (`nodeCount` hasn't
    /// been incremented yet when the bytes are written). The write lock is acquired
    /// only when the file must grow to accommodate the new node.
    ///
    /// - Precondition: `embedding.count == vectorDim`. Mismatched count is a
    ///   programmer error and will silently produce a corrupted slot.
    func append(embedding: [Float]) {
        let slot = nodeCount
        if slot >= capacity {
            // Capacity exhausted — remap under write lock (blocks active readers).
            remapUnderWriteLock(toCapacity: capacity + Self.growChunk)
        }
        // Write bytes to the new slot. No lock needed: the slot at offset
        // `slot * vectorStride` was zero-initialised by ftruncate and is beyond
        // any reader's accessible range (nodeCount hasn't been incremented yet).
        let offset = slot * Self.vectorStride
        embedding.withUnsafeBytes {
            ptr.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: Self.vectorStride)
        }
        nodeCount += 1
    }

    // MARK: - Write path — compact rewrite

    /// Rewrites the vector file so that new slot `i` contains the vector that was
    /// previously at slot `oldIndices[i]`. Called by mutators after `HNSWGraph.compact()`
    /// to reorder the file to match the compacted node array.
    ///
    /// Acquires the write lock — blocks until all active searches finish.
    ///
    /// Uses a single `vectorStride`-byte scratch buffer to copy one slot at a time,
    /// avoiding any aliasing between source and destination even when `oldIndices`
    /// contains out-of-order or overlapping mappings.
    func rewrite(order oldIndices: [Int]) {
        pthread_rwlock_wrlock(&rwlock)
        defer { pthread_rwlock_unlock(&rwlock) }

        let newCount   = oldIndices.count
        let scratch    = UnsafeMutableRawPointer.allocate(byteCount: Self.vectorStride, alignment: MemoryLayout<Float>.alignment)
        defer { scratch.deallocate() }

        // Copy each surviving vector into a scratch buffer first, then write to
        // its new position. This is safe regardless of source/dest overlap order.
        for (newIdx, oldIdx) in oldIndices.enumerated() {
            guard oldIdx < nodeCount else { continue }
            let src = ptr.advanced(by: oldIdx * Self.vectorStride)
            let dst = ptr.advanced(by: newIdx * Self.vectorStride)
            scratch.copyMemory(from: src, byteCount: Self.vectorStride)
            dst.copyMemory(from: scratch, byteCount: Self.vectorStride)
        }

        // Flush dirty pages, then shrink the file and remap.
        msync(ptr, mappedLength, MS_SYNC)
        munmap(ptr, mappedLength)

        // Close and reopen so the fd reflects the renamed file after atomic replace.
        close(fd)
        fd = open(url.path, O_RDWR, mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH))

        let newCapacity  = Self.roundUpToChunk(newCount)
        let newSize      = newCapacity * Self.vectorStride
        _ = ftruncate(fd, off_t(newSize))

        mappedLength = newSize
        capacity     = newCapacity
        nodeCount    = newCount

        let raw = mmap(nil, mappedLength, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        // If remap fails, ptr points to an invalid region. The caller (compact) logs
        // this path; subsequent searches degrade to empty results via the nil vectorStore
        // guard in HNSWGraph.search.
        ptr = (raw == MAP_FAILED) ? UnsafeMutableRawPointer.allocate(byteCount: 0, alignment: 1) : raw!
    }

    // MARK: - Flush

    /// Asynchronously flushes dirty mmap pages to disk.
    /// Call before saving the topology file to ensure vector data reaches disk first.
    func sync() {
        pthread_rwlock_rdlock(&rwlock)
        defer { pthread_rwlock_unlock(&rwlock) }
        msync(ptr, nodeCount * Self.vectorStride, MS_ASYNC)
    }

    // MARK: - Private

    private func remapUnderWriteLock(toCapacity newCapacity: Int) {
        pthread_rwlock_wrlock(&rwlock)
        defer { pthread_rwlock_unlock(&rwlock) }

        let newSize = newCapacity * Self.vectorStride
        guard ftruncate(fd, off_t(newSize)) == 0 else { return }

        msync(ptr, mappedLength, MS_SYNC)
        munmap(ptr, mappedLength)

        mappedLength = newSize
        capacity     = newCapacity

        let raw = mmap(nil, mappedLength, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        ptr = (raw == MAP_FAILED) ? UnsafeMutableRawPointer.allocate(byteCount: 0, alignment: 1) : raw!
    }

    private static func roundUpToChunk(_ n: Int) -> Int {
        max(n == 0 ? growChunk : ((n + growChunk - 1) / growChunk) * growChunk, growChunk)
    }
}
