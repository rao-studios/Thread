//
//  Database+Index.swift
//  database-server
//
//  Created by Ritesh Pakala on 11/15/25.
//

import Foundation

extension Database {
    /// A helper function to begin the index process after Database+Put.
    /// - Parameters:
    ///   - id: The DocumentID.
    ///   - partitions: The partitions related to the document.
    ///   - request: The DatabaseRequest with owner information.
    func index(
        id: DocumentID,
        partitions: [Database.Partition],
        tags: [String] = [],
        tagsEmbedding: [Float]? = nil,
        metadata: Data? = nil,
        request: DatabaseRequest
    ) async {
        await tableMutator.put(id: id, partitions: partitions, tags: tags, tagsEmbedding: tagsEmbedding, metadata: metadata, request: request)
    }

    /// Deletes or unlinks every document owned by a user.
    ///
    /// Documents where this owner was the last are fully purged (file + global table).
    /// Documents still held by other owners are only removed from this owner's personal HNSW.
    @discardableResult
    func _removeAll(ownerId: String, request: DatabaseRequest) async -> Int {
        let (fullyRemoved, allOwned) = await registryMutator.removeAll(ownerId: ownerId)

        for documentId in fullyRemoved { documentCache.evict(documentId) }
        let idsToDelete = fullyRemoved
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            for documentId in idsToDelete {
                self.documentStore(for: documentId).purge()
                self.partitionStore(for: documentId).purge()
            }
        }

        await tableMutator.removeAll(documentIds: fullyRemoved, request: request)

        return allOwned.count
    }

    /// Unlinks a batch of (documentId, ownerId) pairs.
    /// Fully removes documents where the given owner was the last.
    func _removeBatch(items: [(documentId: String, ownerId: String)]) async {
        guard !items.isEmpty else { return }

        let fullyRemovedIds = await registryMutator.removeBatch(items: items)

        for documentId in fullyRemovedIds { documentCache.evict(documentId) }
        let idsToDelete = fullyRemovedIds
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            for documentId in idsToDelete {
                self.documentStore(for: documentId).purge()
                self.partitionStore(for: documentId).purge()
            }
        }

        let dummyRequest = DatabaseRequest(ownerId: "", group: nil, aggregate: nil, scope: nil, requestID: nil)
        await tableMutator.removeAll(documentIds: fullyRemovedIds, request: dummyRequest)
    }

    /// Unlinks an owner from a document. Only purges the physical file and global table
    /// entry when this owner was the last — otherwise only the personal HNSW is updated.
    func remove(documentId: String,
                group: Database.Group? = nil,
                ownerId: String) async {
        let (authorized, fullyRemoved) = await registryMutator.remove(documentId: documentId, group: group, ownerId: ownerId)
        guard authorized else {
            logger.warning(
                "Owner \(ownerId) does not own document \(documentId) — removal rejected",
                service: .database
            )
            return
        }

        logger.info("Remove Document", "\(fullyRemoved ? "Fully removing" : "Unlinking") document: \(documentId)", service: .database)

        if fullyRemoved {
            documentCache.evict(documentId)
            await tableMutator.remove(id: documentId)
            documentStore(for: documentId).purge()
            partitionStore(for: documentId).purge()
        }
    }
}

extension Database {
    func initializeTable() {
        // ── Path 1: shard-scoped topology file ────────────────────────────────────────────
        let shardStorage = FilePersistence(key: "shard-\(nodeId)-topology", kind: .basic, logger: logger.base)
        if var table: PartitionTable = shardStorage.restore() {

            // ── Phase 3 + 4: Open vector store and replay WAL for each shard ──────────────
            // Shard 0 uses legacy filenames; shard N (N≥1) uses indexed names.
            for i in table.shards.indices {
                let vName = i == 0 ? "shard-\(nodeId)-vectors" : "shard-\(nodeId)-\(i)-vectors"
                let vURL  = FilePersistence.getDefaultURL().appendingPathComponent(vName)

                let openedStore = try? HNSWVectorStore(url: vURL, nodeCount: table.shards[i].nodes.count)
                let nodeCount   = table.shards[i].nodes.count
                if let store = openedStore, !store.wasCreatedFresh, store.isValidFor(nodeCount: nodeCount) {
                    table.shards[i].vectorStore = store
                    tableMutator.seedVectorStore(store, for: i)
                    logger.info(
                        "Table Init",
                        "✅ Shard \(i) vector store OK — nodeCount=\(nodeCount) entryPoint=\(table.shards[i].entryPoint)",
                        service: .database
                    )
                } else {
                    // Vector file missing or too small — disable HNSW for this shard until rebuild.
                    table.shards[i].entryPoint = -1
                    table.shards[i].maxLevel   = -1
                    let reason: String
                    if openedStore == nil {
                        reason = "could not open file"
                    } else if openedStore!.wasCreatedFresh {
                        reason = "file was absent/empty (created fresh)"
                    } else {
                        reason = "file too small for nodeCount=\(nodeCount)"
                    }
                    logger.warning(
                        "⚠️ \(vName) — shard \(i) HNSW disabled (\(reason)). Run POST /v1/admin/hnsw/rebuild.",
                        service: .database
                    )
                }

                // Phase 4: Replay WAL for this shard.
                let wName = i == 0 ? "shard-\(nodeId)-topology-wal" : "shard-\(nodeId)-\(i)-topology-wal"
                let wURL  = FilePersistence.getDefaultURL().appendingPathComponent(wName)
                if let w = try? HNSWTopologyWAL(url: wURL),
                   let records = try? w.readAll(),
                   !records.isEmpty {
                    for record in records { table.shards[i].apply(record) }
                    logger.info(
                        "Table Init",
                        "Replayed \(records.count) WAL record(s) for shard \(i)",
                        service: .database
                    )
                    // Re-open the vector store with the post-WAL node count.
                    if let existingStore = table.shards[i].vectorStore,
                       table.shards[i].nodes.count > existingStore.nodeCount,
                       let refreshed = try? HNSWVectorStore(url: vURL, nodeCount: table.shards[i].nodes.count) {
                        table.shards[i].vectorStore = refreshed
                        tableMutator.seedVectorStore(refreshed, for: i)
                    }
                }
            }

            // ── Orphaned shard recovery ───────────────────────────────────────────────────
            // Shards spawned after the last checkpoint have no entry in the base topology
            // file (which was saved before they existed), but they DO have WAL files.
            // Scan for shard-<nodeId>-N-topology-wal files starting beyond the last known
            // shard index and reconstruct each orphaned shard from its WAL.
            // WALs are collected here and registered with the actor in the async Task below.
            var orphanedWals: [(shardIndex: Int, wal: HNSWTopologyWAL)] = []
            var extraShardIdx = table.shards.count
            while true {
                let wName = "shard-\(nodeId)-\(extraShardIdx)-topology-wal"
                let wURL  = FilePersistence.getDefaultURL().appendingPathComponent(wName)
                guard FileManager.default.fileExists(atPath: wURL.path()),
                      let w       = try? HNSWTopologyWAL(url: wURL),
                      let records = try? w.readAll(),
                      !records.isEmpty else { break }

                var orphan = HNSWShard()
                for record in records { orphan.apply(record) }

                let vName = "shard-\(nodeId)-\(extraShardIdx)-vectors"
                let vURL  = FilePersistence.getDefaultURL().appendingPathComponent(vName)
                if let store = try? HNSWVectorStore(url: vURL, nodeCount: orphan.nodes.count),
                   !store.wasCreatedFresh,
                   store.isValidFor(nodeCount: orphan.nodes.count) {
                    orphan.vectorStore = store
                    tableMutator.seedVectorStore(store, for: extraShardIdx)
                } else {
                    orphan.entryPoint = -1
                    orphan.maxLevel   = -1
                    logger.warning(
                        "⚠️ \(vName) missing for orphaned shard \(extraShardIdx) — HNSW disabled. Run POST /v1/admin/hnsw/rebuild.",
                        service: .database
                    )
                }
                table.shards.append(orphan)
                orphanedWals.append((extraShardIdx, w))
                logger.info(
                    "Table Init",
                    "⚜️ Recovered orphaned shard \(extraShardIdx) from WAL (\(records.count) record(s), \(orphan.nodes.count) node(s))",
                    service: .database
                )
                extraShardIdx += 1
            }

            // Orphan cleanup: remove documents absent from the registry.
            let validIds         = Set(registryMutator.snapshot.map { Array($0.documentOwners.keys) } ?? [])
            let orphanedTableIds = table.keys.subtracting(validIds)
            if !orphanedTableIds.isEmpty {
                for id in orphanedTableIds { table.remove(id: id) }
                shardStorage.save(state: table)
                logger.info(
                    "Table Init",
                    "⚠️ Removed \(orphanedTableIds.count) orphaned document(s) from partition table",
                    service: .database
                )
            }

            // Duplicate-node sweep per shard: mark stale phantom nodes deleted.
            var totalPhantoms = 0
            for i in table.shards.indices {
                var seen: [String: Int] = [:]
                var phantomCount = 0
                for (idx, node) in table.shards[i].nodes.enumerated() where !node.isDeleted {
                    if let canonical = seen[node.partitionId] {
                        if table.shards[i].partitionLookup[node.partitionId] == idx {
                            table.shards[i].nodes[canonical].isDeleted = true
                        } else {
                            table.shards[i].nodes[idx].isDeleted = true
                        }
                        phantomCount += 1
                    } else {
                        seen[node.partitionId] = idx
                    }
                }
                if phantomCount > 0 {
                    let result = table.shards[i].compact()
                    table.shards[i].vectorStore?.rewrite(order: result.survivingVectorIndices)
                    totalPhantoms += phantomCount
                }
            }
            if totalPhantoms > 0 {
                shardStorage.save(state: table)
                // Truncate all shard WALs — the snapshot just saved is authoritative.
                // Pre-compaction WAL records use old node indices; replaying them on the
                // renumbered post-compact graph would corrupt entryPoint and neighbor refs.
                for i in table.shards.indices {
                    let wName = i == 0
                        ? "shard-\(nodeId)-topology-wal"
                        : "shard-\(nodeId)-\(i)-topology-wal"
                    let wURL = FilePersistence.getDefaultURL().appendingPathComponent(wName)
                    if let w = try? HNSWTopologyWAL(url: wURL) { try? w.truncate() }
                }
                logger.warning(
                    "⚠️ Removed \(totalPhantoms) phantom node(s) across \(table.shards.count) shard(s)",
                    service: .database
                )
            }

            // Rebuild documentShardIndex and keys from the live HNSW nodes.
            // documentShardIndex is persisted in the base topology checkpoint only —
            // WAL records restore graph topology (nodes/edges) but never update it.
            // If the server was killed before the first checkpoint, documentShardIndex
            // is empty even though nodes were replayed from the WAL. mergeIndices() uses
            // documentShardIndex to route each PartitionIndex to the correct shard; an
            // empty map causes it to skip every document → indices stay empty →
            // every HNSW candidate fails the guard at HNSWShard.search line 214 → 0 results.
            table.documentShardIndex = [:]
            table.keys = []
            for (i, shard) in table.shards.enumerated() {
                for node in shard.nodes where !node.isDeleted {
                    table.documentShardIndex[node.documentId] = i
                    table.keys.insert(node.documentId)
                }
            }

            tableMutator.seed(table)
            let shardSummary = table.shards.enumerated().map { i, s in
                "shard\(i)[nodes=\(s.nodes.count) trained=\(s.isTrained) ep=\(s.entryPoint) vectorStore=\(s.vectorStore != nil)]"
            }.joined(separator: " ")
            logger.info("Table Restored", "⚜️ Restore Table [shard-\(nodeId)] — \(table.shards.count) shard(s): \(shardSummary)", service: .database)

            // ── Phase 5: Indices file + orphaned WAL registration ────────────────────────
            let capturedNodeId   = self.nodeId
            let capturedOrphans  = orphanedWals
            let capturedMutator  = tableMutator
            let capturedLogger   = logger
            Task {
                // Register WAL handles for orphaned shards (those recovered above that were
                // absent from the base topology file). Must happen before any puts so that
                // new WAL records for those shards go to the right file.
                for (shardIndex, w) in capturedOrphans {
                    await capturedMutator.registerOrphanedShardWAL(w, byteCount: w.byteSize, for: shardIndex)
                }
                if let existing: [Int: [DocumentID: PartitionIndex]] = capturedMutator.loadIndicesFromDisk() {
                    await capturedMutator.mergeIndices(existing)
                    let total = existing.values.reduce(0) { $0 + $1.count }
                    capturedLogger.info(
                        "Table Init",
                        "⚜️ Merged \(total) PQ indices (incl. index-WAL replay) for shard-\(capturedNodeId)",
                        service: .database
                    )
                }
                // Always fire — unblocks waitForIndices() regardless of which
                // path ran (including the no-op path for a fresh install with no indices).
                await capturedMutator.markIndicesReady()
            }

            // Guardian: last-resort unblock if loadIndicesFromDisk hangs indefinitely
            // (e.g., corrupt plist, I/O stall). 300 s is conservative — normal decoding
            // of even very large indices files completes well within this window.
            Task { [tableMutator] in
                try? await Task.sleep(for: .seconds(300))
                await tableMutator.markIndicesReady()
            }

            return
        }

        // ── Path 2: no file found — fresh install ─────────────────────────────────────────
        if !FileManager.default.fileExists(atPath: shardStorage.url.path()) {
            // Create the vector store for shard 0 (empty graph).
            let vectorURL = FilePersistence.getDefaultURL()
                .appendingPathComponent("shard-\(nodeId)-vectors")
            if let store = try? HNSWVectorStore(url: vectorURL, nodeCount: 0) {
                tableMutator.seedVectorStore(store, for: 0)
            }
            var empty = PartitionTable()
            empty.shards[0].vectorStore = tableMutator.vectorStore
            shardStorage.save(state: empty)
            tableMutator.seed(empty)
            logger.info("Table Created", "⚜️ Table Initialized [shard-\(nodeId)]", service: .database)
        } else {
            // Corrupt or schema-incompatible topology file — overwrite it with a clean empty
            // table so the next restart doesn't hit the same decode failure again.
            logger.warning(
                "⚠️ Partition table exists but failed to decode — overwriting with fresh empty table. Re-ingest documents to rebuild the index.",
                service: .database
            )
            let vectorURL = FilePersistence.getDefaultURL()
                .appendingPathComponent("shard-\(nodeId)-vectors")
            if let store = try? HNSWVectorStore(url: vectorURL, nodeCount: 0) {
                tableMutator.seedVectorStore(store, for: 0)
            }
            var empty = PartitionTable()
            empty.shards[0].vectorStore = tableMutator.vectorStore
            shardStorage.save(state: empty)
            tableMutator.seed(empty)
            logger.info("Table Created", "⚜️ Table Re-initialized [shard-\(nodeId)] after decode failure", service: .database)
        }

        // Path 2 never starts the Phase 5 Task, so markIndicesReady() would never fire.
        // Unblock any waitForIndices() callers immediately — nothing to load on a fresh table.
        Task { [tableMutator] in
            await tableMutator.markIndicesReady()
        }
    }

    nonisolated var tableStore: FilePersistence {
        FilePersistence(key: "shard-\(nodeId)-topology", kind: .basic, logger: logger.base)
    }

    nonisolated var table: PartitionTable? { tableMutator.snapshot }
}
