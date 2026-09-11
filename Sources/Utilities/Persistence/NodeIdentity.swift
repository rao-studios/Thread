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
