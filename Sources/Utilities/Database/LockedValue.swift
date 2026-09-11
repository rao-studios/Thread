//
//  LockedValue.swift
//  database-server
//
//  Created by Ritesh Pakala on 3/19/26.
//

import Foundation

/// A cross-platform, thread-safe wrapper that protects a value with an `NSLock`.
///
/// API mirrors `OSAllocatedUnfairLock` so call sites are identical — only the
/// declaration changes. `NSLock` is available on both Apple platforms and Linux
/// via swift-corelibs-foundation.
final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    @discardableResult
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
