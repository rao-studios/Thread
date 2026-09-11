//
//  ThreadCache.swift
//  database-server
//
//  Created by Ritesh Pakala on 3/20/26.
//

import Foundation

/// Generic read-through cache with synchronous lock-protected reads and off-actor,
/// race-safe disk persistence.
///
/// Encapsulates the repeated `LockedValue<Value?> + FilePersistence` pattern shared
/// by `TableMutator` and `RegistryMutator`:
///
///  - **Read**: `cache.snapshot` is synchronous and never hops an actor.
///  - **Mutate**: call `cache.update(newValue)` inside the owning actor after
///    modifying the value, then `cache.saveAsync(newValue)` to persist off-actor.
///  - **First load**: `await cache.load { .init() }` suspends the calling actor
///    during the disk read so other work can proceed concurrently.
///
/// All disk I/O is routed through a `PersistenceActor` — one per cache instance —
/// so concurrent `saveAsync` calls are guaranteed never to race on the backing file.
final class ThreadCache<Value: Codable & Sendable>: @unchecked Sendable {
    private let _store: ReadWriteValue<Value?>
    private let persistence: FilePersistence
    private let io: PersistenceActor

    init(persistence: FilePersistence) {
        self._store = ReadWriteValue<Value?>(nil)
        self.persistence = persistence
        self.io = PersistenceActor(persistence: persistence)
    }

    // MARK: - Read

    /// Synchronous, concurrent-read snapshot. Multiple callers may read simultaneously —
    /// only writes are exclusive. Safe to call from any context without an actor hop.
    /// Returns `nil` until `seed` or `load` has been called.
    var snapshot: Value? { _store.withReadLock { $0 } }

    // MARK: - Write

    /// Seeds the snapshot synchronously at startup. Safe to call from a `nonisolated`
    /// context — no actor hop required.
    func seed(_ value: Value) {
        _store.withWriteLock { $0 = value }
    }

    /// Updates the in-memory snapshot. Call from inside the owning actor after
    /// mutating the value; the write lock is held for microseconds.
    func update(_ value: Value) {
        _store.withWriteLock { $0 = value }
    }

    /// Kicks off a serialized off-actor disk write. The calling actor is freed
    /// immediately — the write runs in a detached task that hops to `PersistenceActor`,
    /// guaranteeing writes are never concurrent on the same file.
    func saveAsync(_ value: Value) {
        Task.detached { [io] in await io.save(value) }
    }

    /// Awaits a serialized disk write — use at graceful shutdown where the write
    /// must complete before the caller returns.
    func saveNow(_ value: Value) async {
        await io.save(value)
    }

    // MARK: - Load

    /// Returns the cached value if available; otherwise loads from disk through
    /// `PersistenceActor` — suspending the calling actor during I/O — then caches
    /// and returns the result.
    ///
    /// Race-safe: if a concurrent actor invocation populates the cache while this
    /// call is suspended, the first-written value wins. The `PersistenceActor` also
    /// ensures the load waits for any in-flight save to complete before reading.
    func load(makeDefault: @Sendable () -> Value) async -> Value {
        if let hit = _store.withReadLock({ $0 }) { return hit }
        let restored: Value? = await io.restore()
        let loaded = restored ?? makeDefault()
        return _store.withWriteLock {
            if $0 == nil { $0 = loaded }
            return $0!
        }
    }

    // MARK: - Atomic Modify

    /// Atomically read-modify-write the cached value under the store lock.
    /// Returns the mutated value so the caller can pass it to `saveAsync`.
    ///
    /// - Parameters:
    ///   - makeDefault: Produces the initial value when the cache is empty.
    ///   - mutate: Closure that mutates the value in place.
    @discardableResult
    func modify(makeDefault: () -> Value, _ mutate: (inout Value) -> Void) -> Value {
        // Exclusive write lock for the full read-modify-write — cannot be split.
        _store.withWriteLock {
            var value = $0 ?? makeDefault()
            mutate(&value)
            $0 = value
            return value
        }
    }

    // MARK: - Sync Startup Seed

    /// Seeds the snapshot from disk synchronously — call once at startup before
    /// any async context is available (e.g. from a synchronous `init`).
    /// Safe because no concurrent writes can exist before the owning object is fully initialised.
    ///
    /// - Returns: The value that was seeded (from disk, or `makeDefault()` if absent).
    @discardableResult
    func seedFromDisk(makeDefault: () -> Value) -> Value {
        let restored: Value? = persistence.restore()
        let initial = restored ?? makeDefault()
        _store.withWriteLock { $0 = initial }
        return initial
    }
}
