//
//  PersistenceActor.swift
//  database-server
//
//  Created by Ritesh Pakala on 3/20/26.
//

import Foundation
import Logging

/// Serializes all disk I/O for a single file through Swift's actor model.
///
/// `FilePersistence.save` is not thread-safe: two concurrent calls writing to
/// the same URL race on `data.write(to:)` and on the `fileExists → createFile`
/// branch. Wrapping it in an actor guarantees serial execution per file without
/// blocking any thread — callers simply `await` the actor method and the Swift
/// runtime handles the hop.
///
/// One `PersistenceActor` is created per logical file:
///   - `TotemCache<Value>` owns one each for the table, graph, and registry.
actor PersistenceActor {
    private let persistence: FilePersistence

    init(persistence: FilePersistence) {
        self.persistence = persistence
    }

    /// Serialized write. Runs on this actor's executor; no two saves overlap.
    func save<T: Codable>(_ value: T) {
        persistence.save(state: value)
    }

    /// Serialized read. Waits for any in-flight save to complete before reading,
    /// so the caller always sees the latest committed state.
    func restore<T: Codable>() -> T? {
        persistence.restore()
    }

    /// Removes the backing file from disk.
    func purge() {
        persistence.purge()
    }
}
