//
//  ReadWriteValue.swift
//  database-server
//

import Foundation

/// A cross-platform, thread-safe wrapper that protects a value with a POSIX
/// reader-writer lock (`pthread_rwlock_t`).
///
/// Unlike `LockedValue` (which uses `NSLock` — exclusive for every access),
/// this type allows **concurrent reads** while keeping **writes exclusive**.
/// This is the correct primitive for any value that is read far more often
/// than it is written — e.g. the partition table, registry, and HNSW snapshot
/// caches which are read on every search request but written only on index/delete.
///
/// API contract enforced at the type level:
/// - `withReadLock`  receives `T` (immutable) — multiple callers run simultaneously.
/// - `withWriteLock` receives `inout T` (mutable) — caller has exclusive access.
///
/// Available on both Apple platforms and Linux via swift-corelibs-foundation.
final class ReadWriteValue<T>: @unchecked Sendable {
    private var lock = pthread_rwlock_t()
    private var value: T

    init(_ value: T) {
        self.value = value
        pthread_rwlock_init(&lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(&lock)
    }

    /// Acquires a **shared** read lock. Multiple callers may hold this simultaneously.
    /// The closure receives an immutable view of the value — mutation is not possible.
    @discardableResult
    func withReadLock<R>(_ body: (T) -> R) -> R {
        pthread_rwlock_rdlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return body(value)
    }

    /// Acquires an **exclusive** write lock. Blocks until all active readers and any
    /// concurrent writer have released. The closure receives an `inout` reference.
    @discardableResult
    func withWriteLock<R>(_ body: (inout T) -> R) -> R {
        pthread_rwlock_wrlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return body(&value)
    }
}
