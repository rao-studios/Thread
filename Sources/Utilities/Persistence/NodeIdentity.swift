//
//  NodeIdentity.swift
//  database-server
//
//  Created by Ritesh Pakala on 3/30/26.
//

import Foundation
import Logging

/// Persistent node identity. Generated once on first startup, then loaded from disk.
///
/// The UUID is stable across restarts and serves two purposes:
///
///   1. **Shard-scoped file naming**: topology and vector files are named
///      `shard-{nodeId}-topology` and `shard-{nodeId}-vectors`, making shards
///      portable and enabling multi-shard coexistence on the same host.
///
///   2. **Oracle identity**: `Oracle.localNodeId` will read this same UUID so
///      the storage identity and the network identity are always the same value —
///      no coordination required between the persistence layer and the mesh overlay.
///
/// The identity file lives at `<data-dir>/node-id` (default `~/Documents/thread-db`).
struct NodeIdentity {
    let nodeId: UUID

    /// The variable a launcher hands the node id in. Ambient sets it: the id
    /// is the handle on the mothership session, and argv is visible to every
    /// local user in `ps`. `--node-id` still wins for a hand launch.
    static let environmentKey = "THREAD_NODE_ID"

    /// The fixed id, if any: argv first, the environment as fallback. A value
    /// that is not a UUID is returned in `rejected` so the caller can say so,
    /// and the persisted (or fresh) id is used instead.
    static func override(argument: String?, environment: [String: String]) -> (uuid: UUID?, rejected: String?) {
        for candidate in [argument, environment[environmentKey]] {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let uuid = UUID(uuidString: trimmed) { return (uuid, nil) }
            return (nil, trimmed)
        }
        return (nil, nil)
    }

    /// Load (or create) the node identity from `<data-dir>/node-id`.
    /// Synchronous — safe to call from a non-async context at server startup,
    /// before the cooperative thread pool is active.
    ///
    /// - Parameter override: When non-nil, this UUID is written to the node-id
    ///   file and returned directly, replacing any previously persisted identity.
    ///   Useful for `--node-id` CLI deployments where a stable, human-chosen UUID
    ///   is required (e.g. a fixed personal-thread setup).
    static func load(override: UUID? = nil, logger: Logger) -> NodeIdentity {
        let dir = FilePersistence.getDefaultURL()
        let url = dir.appendingPathComponent("node-id")

        if let fixed = override {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "\(fixed)".data(using: .utf8)?.write(to: url, options: .atomic)
            logger.info("NodeIdentity: using fixed node-id \(fixed)")
            return NodeIdentity(nodeId: fixed)
        }

        if let data = try? Data(contentsOf: url),
           let str = String(data: data, encoding: .utf8),
           let uuid = UUID(uuidString: str.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return NodeIdentity(nodeId: uuid)
        }
        // First launch: generate a fresh UUID and persist it atomically.
        // NodeIdentity.load() is called before TableMutator.init() which normally
        // creates the data directory via FilePersistence.init(). Create it
        // explicitly here so the write doesn't fail silently on the very first run.
        let fresh = UUID()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(fresh)".data(using: .utf8)?.write(to: url, options: .atomic)
        logger.info("NodeIdentity: generated node-id \(fresh)")
        return NodeIdentity(nodeId: fresh)
    }
}
