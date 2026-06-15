//
//  TableMutator.swift
//  database-server
//
//  Created by Ritesh Pakala on 3/7/26.
//

import Foundation

/// Serializes all read-modify-write operations on the PartitionTable file.
///
/// `PartitionTable` is loaded from disk, mutated, and saved on every `index`,
/// `remove`, and `removeAll` call. Without serialization, concurrent embedding
/// requests each load the same table state, apply their own mutations locally,
/// and save — last write wins, clobbering all other concurrent updates.
///
/// Wrapping these operations in an actor guarantees serial execution: each
/// mutation sees the full result of the previous one before it reads.
actor TableMutator {
    private let nodeId: UUID
    private let cache:  TotemCache<PartitionTable>
    private let logger: TotemLogger

    /// Maximum nodes per HNSW shard before a new shard is spawned.
    /// Passed in from `DatabaseConfig.shardSizeThreshold` at init time.
    let shardSizeThreshold: Int

    // MARK: - Indices persistence (split from topology — Phase 5)

    nonisolated(unsafe) private let indicesPersistence: FilePersistence
    private let indicesTotemLogger: TotemLogger
    /// Serializes all shard-indices saves so concurrent `saveIndicesAsync()` calls
    /// (from `scheduleSave`, `flushIndicesIfDirty`, `checkpoint`, `remove`, etc.)
    /// never race on the same per-shard plist files. Racing writes caused
    /// simultaneous `PropertyListEncoder` allocations (~500 KB × 59 shards × N tasks)
    /// that triggered OOM crashes inside `data.write(to:options:.atomic)`.
    private let indicesIO: IndicesPersistenceActor

    // MARK: - WAL (Phase 4 — one WAL file per shard)
    //
    // Shard 0 uses the legacy filename `shard-<nodeId>-topology-wal`.
    // Shard N (N≥1) uses `shard-<nodeId>-<N>-topology-wal`.

    private var wals:          [Int: HNSWTopologyWAL] = [:]
    private var walByteCounts: [Int: Int]             = [:]
    /// Maximum WAL file size per shard before a checkpoint is forced (default: 64 MB).
    static let walCheckpointThreshold = 64 * 1024 * 1024

    // MARK: - PQ index WALs (one per shard, opened lazily)
    //
    // Each document put appends its single encoded PartitionIndex to its shard's
    // `shard-<nodeId>-<i>-indices-wal` in the same actor turn as the topology-WAL
    // drain — replacing the previous full all-shards indices rewrite per put.
    // Startup replays these on top of the last full indices checkpoint.

    private var indexWALs: [Int: PartitionIndexWAL] = [:]
    /// Index-WAL size above which a full indices checkpoint (and WAL truncation)
    /// is scheduled.
    static let indexWALCheckpointThreshold = 16 * 1024 * 1024

    // MARK: - Debounced disk saves / checkpoints

    private var tableDirty = false
    private var flushTask:  Task<Void, Never>?

    // MARK: - Debounced indices saves

    private var indicesDirty = false
    private var indicesFlushTask: Task<Void, Never>?

    // MARK: - Indices-ready gate

    private var _indicesReady = false
    private var _indicesWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Deferred compaction

    private var compactTask: Task<Void, Never>?
    /// Fraction of deleted nodes above which a background compact is scheduled.
    static let compactThreshold: Double = 0.35

    // MARK: - Vector stores (Phase 3 — one mmap'd file per shard)
    //
    // Shard 0 uses the legacy filename `shard-<nodeId>-vectors`.
    // Shard N (N≥1) uses `shard-<nodeId>-<N>-vectors`.
    //
    // `ReadWriteValue` allows nonisolated access from `initializeTable()` (which
    // runs before the actor queue is active) to seed stores synchronously.

    private let _vectorStores: ReadWriteValue<[Int: HNSWVectorStore]> = .init([:])

    /// The vector store for shard 0 (backward-compat accessor).
    nonisolated var vectorStore: HNSWVectorStore? {
        _vectorStores.withReadLock { $0[0] }
    }

    nonisolated func vectorStore(for shardIndex: Int) -> HNSWVectorStore? {
        _vectorStores.withReadLock { $0[shardIndex] }
    }

    /// Seeds the vector store for a given shard. Called from `initializeTable()` before
    /// the actor queue is active — safe because no actor method touches `_vectorStores` until after.
    nonisolated func seedVectorStore(_ store: HNSWVectorStore, for shardIndex: Int = 0) {
        _vectorStores.withWriteLock { $0[shardIndex] = store }
    }

    // MARK: - Init

    init(nodeId: UUID, logger: TotemLogger, shardSizeThreshold: Int = 10_000) {
        self.nodeId               = nodeId
        self.shardSizeThreshold   = shardSizeThreshold
        self.cache  = TotemCache(
            persistence: FilePersistence(
                key:    "shard-\(nodeId)-topology",
                kind:   .basic,
                logger: logger.base
            )
        )
        let ip = FilePersistence(
            key:    "shard-\(nodeId)-indices",
            kind:   .basic,
            logger: logger.base
        )
        self.indicesPersistence = ip
        self.indicesTotemLogger  = logger
        self.logger = logger
        self.indicesIO = IndicesPersistenceActor(nodeId: nodeId, logger: logger.base)
        // Open (or create) the WAL file for shard 0. Additional shards' WALs are opened
        // lazily in putBatch when those shards are spawned.
        let walURL = FilePersistence.getDefaultURL()
            .appendingPathComponent("shard-\(nodeId)-topology-wal")
        if let w = try? HNSWTopologyWAL(url: walURL) {
            wals[0]          = w
            walByteCounts[0] = w.byteSize
        }
    }

    // MARK: - Startup seeding

    nonisolated func seed(_ initial: PartitionTable) { cache.seed(initial) }

    /// Loads each shard's indices checkpoint plist, then replays that shard's
    /// PQ index WAL on top (put = upsert, removed = delete). Returns the result
    /// keyed by source shard so `mergeIndices` can prefer the entry recorded by
    /// the shard that currently owns each document.
    nonisolated func loadIndicesFromDisk() -> [Int: [DocumentID: PartitionIndex]]? {
        var byShard = [Int: [DocumentID: PartitionIndex]]()
        var foundAny = false
        let decoder = PropertyListDecoder()
        var i = 0
        while true {
            let fp = FilePersistence(key: "shard-\(nodeId)-\(i)-indices", kind: .basic, logger: indicesTotemLogger.base)
            let walURL = FilePersistence.getDefaultURL()
                .appendingPathComponent("shard-\(nodeId)-\(i)-indices-wal")
            let plistExists = FileManager.default.fileExists(atPath: fp.url.path())
            let walExists   = FileManager.default.fileExists(atPath: walURL.path)
            guard plistExists || walExists else { break }

            var shardDict = [DocumentID: PartitionIndex]()
            if plistExists, let dict: [DocumentID: PartitionIndex] = fp.restore() {
                shardDict = dict
                foundAny = true
            }
            if walExists,
               let wal = try? PartitionIndexWAL(url: walURL),
               let records = try? wal.readAll() {
                for record in records {
                    switch record {
                    case .indexPut(let docId, let payload):
                        if let index = try? decoder.decode(PartitionIndex.self, from: payload) {
                            shardDict[docId] = index
                            foundAny = true
                        }
                    case .indexRemoved(let docId):
                        shardDict.removeValue(forKey: docId)
                    case .commit:
                        break
                    }
                }
            }
            byShard[i] = shardDict
            i += 1
        }
        if foundAny { return byShard }
        // Legacy single-file fallback (pre-per-shard checkpoints).
        if let legacy: [DocumentID: PartitionIndex] = indicesPersistence.restore() { return [0: legacy] }
        return nil
    }

    func mergeIndices(_ indicesByShard: [Int: [DocumentID: PartitionIndex]]) async {
        guard var table = cache.snapshot else { return }
        // Documents indexed after startup (before Phase 5 completed) have fresher
        // in-memory indices than anything on disk — never overwrite those.
        let inMemory = Set(table.shards.flatMap { $0.indices.keys })
        // Cross-shard upserts can leave stale entries in a previous shard's
        // checkpoint; the entry recorded by the document's current shard wins.
        var fromOwningShard = Set<DocumentID>()
        for (sourceShard, indices) in indicesByShard {
            for (docId, index) in indices {
                guard !inMemory.contains(docId),
                      let si = table.documentShardIndex[docId], si < table.shards.count else { continue }
                let isOwner = sourceShard == si
                if fromOwningShard.contains(docId) && !isOwner { continue }
                if table.shards[si].indices[docId] == nil || isOwner {
                    table.shards[si].indices[docId] = index
                    if isOwner { fromOwningShard.insert(docId) }
                }
            }
        }
        cache.update(table)
    }

    func markIndicesReady() {
        guard !_indicesReady else { return }

        // Report — but never delete — documents whose PQ index isn't loaded yet.
        //
        // An "orphan" here is a key in the graph with no resolvable PQ index. This is
        // NOT proof of permanent loss: the index may simply not have replayed yet, or
        // the indices checkpoint may lag the topology WAL after an upgrade/unclean
        // shutdown. The document's raw vector (mmap vector store) and partition text
        // (`documents/{id}-parts`) are still on disk, so the entry is recoverable by
        // re-indexing. Deleting it here is destructive and irreversible — the previous
        // `table.remove(id:)` tombstoning silently wiped recoverable data on the first
        // restart after the index-persistence rewrite.
        //
        // Leaving orphans in place is safe for search: HNSWShard resolution skips any
        // candidate whose `indices[documentId]` is nil (HNSWShard.swift), so an
        // unresolved node is simply omitted from results until its index is present.
        //
        // Guard: only inspect once at least one shard has indices loaded — if indices
        // are entirely empty while keys are non-empty, the guardian deadline fired
        // before mergeIndices() ran and every key would look orphaned. Skip the report
        // in that case; the real markIndicesReady() call logs once mergeIndices completes.
        if let table = cache.snapshot, table.shards.contains(where: { !$0.indices.isEmpty }) {
            let orphanedIds = table.keys.filter { table.index(for: $0) == nil }
            if !orphanedIds.isEmpty {
                logger.warning(
                    "⚠️ [Table Init] \(orphanedIds.count) HNSW node(s) have no loaded PQ index — preserved, not deleted; will resolve once indices load or after re-index: \(orphanedIds.prefix(5))",
                    service: .database
                )
            }
        }

        _indicesReady = true
        let waiters = _indicesWaiters
        _indicesWaiters = []
        waiters.forEach { $0.resume() }
    }

    func waitForIndices() async {
        if _indicesReady { return }
        await withCheckedContinuation { continuation in
            _indicesWaiters.append(continuation)
        }
    }

    private func savePartitionData(documentId: DocumentID, partitions: [Database.Partition]) {
        let metadata = partitions.map { PartitionData(from: $0) }
        FilePersistence(key: "documents/\(documentId)-parts", kind: .basic,
                        logger: logger.base).save(state: metadata)
    }

    private func saveIndicesAsync(_ table: PartitionTable, truncateIndexWALs: Bool = false) {
        let shards = table.shards
        // Capture WAL sizes with the snapshot: a WAL that grew during the async
        // save holds records newer than the checkpoint and must not be truncated
        // (the next checkpoint will catch it).
        let walSizes: [Int: Int] = truncateIndexWALs ? indexWALs.mapValues { $0.byteSize } : [:]
        Task.detached { [indicesIO] in
            // `indicesIO` is an actor — this await serializes all concurrent callers so
            // only one save runs at a time. Previously bare Task.detached calls from
            // scheduleSave, flushIndicesIfDirty, checkpoint, remove, etc. would all
            // spawn concurrently, each encoding ~500 KB × 59 shards simultaneously,
            // causing OOM crashes inside FilePersistence.save → data.write(to:options:.atomic).
            await indicesIO.save(shards: shards)
            if truncateIndexWALs {
                await self.truncateIndexWALs(ifSizesMatch: walSizes)
            }
        }
    }

    /// Truncate index WALs whose size is unchanged since the checkpoint snapshot.
    private func truncateIndexWALs(ifSizesMatch sizes: [Int: Int]) {
        for (i, w) in indexWALs where sizes[i] == w.byteSize {
            try? w.truncate()
        }
    }

    /// Lazily open (or return) the PQ index WAL for a shard.
    private func indexWAL(for shardIndex: Int) -> PartitionIndexWAL? {
        if let w = indexWALs[shardIndex] { return w }
        let url = FilePersistence.getDefaultURL()
            .appendingPathComponent("shard-\(nodeId)-\(shardIndex)-indices-wal")
        guard let w = try? PartitionIndexWAL(url: url) else { return nil }
        indexWALs[shardIndex] = w
        return w
    }

    /// Append one document's PQ index mutation to its shard's index WAL (and an
    /// `indexRemoved` to the previous shard on a cross-shard upsert). Schedules a
    /// full indices checkpoint when any WAL crosses the size threshold.
    private func appendIndexWAL(documentId: DocumentID, table: PartitionTable,
                                targetShard: Int, previousShard: Int?) {
        guard targetShard < table.shards.count,
              let index = table.shards[targetShard].indices[documentId] else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let payload = try? encoder.encode(index) else { return }
        if let w = indexWAL(for: targetShard) {
            try? w.append(.indexPut(documentId: documentId, payload: payload))
            try? w.append(.commit)
        }
        if let prev = previousShard, prev != targetShard, let w = indexWAL(for: prev) {
            try? w.append(.indexRemoved(documentId: documentId))
            try? w.append(.commit)
        }
        if indexWALs.values.contains(where: { $0.byteSize >= Self.indexWALCheckpointThreshold }) {
            scheduleIndicesSave()
        }
    }

    // MARK: - Snapshot

    nonisolated var snapshot: PartitionTable? { cache.snapshot }

    // MARK: - Private

    private func loadedTable() async -> PartitionTable {
        await cache.load { .init() }
    }

    /// Drain WAL records from all shards, appending each shard's records to its own WAL file.
    /// Schedules a checkpoint if any WAL has grown large; falls back to debounced full save.
    private func scheduleSave(draining table: inout PartitionTable) {
        var anyWALAppended = false
        for i in table.shards.indices {
            let records = table.shards[i].pendingWALRecords
            table.shards[i].pendingWALRecords = []
            guard !records.isEmpty else { continue }
            if let w = wals[i] {
                records.forEach { try? w.append($0) }
                walByteCounts[i] = w.byteSize
                anyWALAppended = true
            } else {
                tableDirty = true
            }
        }
        if anyWALAppended {
            let anyOverThreshold = wals.contains { _, w in w.byteSize >= Self.walCheckpointThreshold }
            if anyOverThreshold { scheduleCheckpoint() }
            // Index durability at put cadence is handled by appendIndexWAL —
            // one small append per document instead of the full all-shards
            // indices rewrite that used to live here.
        } else if tableDirty {
            guard flushTask == nil else { return }
            flushTask = Task {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                self.flushIfDirty()
            }
        }
    }

    private func scheduleIndicesSave() {
        indicesDirty = true
        guard indicesFlushTask == nil else { return }
        indicesFlushTask = Task {
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            self.flushIndicesIfDirty()
        }
    }

    private func flushIndicesIfDirty() {
        guard indicesDirty, let table = cache.snapshot else {
            indicesFlushTask = nil; return
        }
        saveIndicesAsync(table, truncateIndexWALs: true)
        indicesDirty      = false
        indicesFlushTask  = nil
    }

    private func scheduleCheckpoint() {
        tableDirty = true
        guard flushTask == nil else { return }
        flushTask = Task {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            self.checkpoint()
        }
    }

    private func scheduleCompactIfNeeded() {
        guard compactTask == nil, let table = cache.snapshot else { return }
        let needsCompact = table.shards.contains { shard in
            let stats = shard.graphStats
            let total = stats.liveNodes + stats.deletedNodes
            guard total > 0, stats.deletedNodes > 0 else { return false }
            return Double(stats.deletedNodes) / Double(total) >= Self.compactThreshold
        }
        guard needsCompact else { return }

        compactTask = Task {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            _ = await self.compact()
            self.compactTask = nil
        }
    }

    // MARK: - Graceful Shutdown

    func flushAllForShutdown() async {
        flushTask?.cancel()
        flushTask = nil
        indicesFlushTask?.cancel()
        indicesFlushTask = nil

        guard let table = cache.snapshot else { return }

        // Sync all per-shard vector stores and truncate all WALs.
        _vectorStores.withReadLock { stores in stores.values.forEach { $0.sync() } }
        await cache.saveNow(table)
        for (i, w) in wals { try? w.truncate(); walByteCounts[i] = 0 }
        tableDirty   = false

        for i in table.shards.indices {
            FilePersistence(
                key:    "shard-\(nodeId)-\(i)-indices",
                kind:   .basic,
                logger: indicesTotemLogger.base
            ).save(state: table.shards[i].indices)
        }
        // All shard indices are checkpointed synchronously above; index WALs are
        // fully covered and safe to truncate (no concurrent appends — we're on
        // the actor and shutting down).
        for (_, w) in indexWALs { try? w.truncate() }
        indicesDirty = false
    }

    /// Full checkpoint: sync all vector stores, save topology, truncate all WALs, flush indices.
    /// WAL truncation is deferred until after saveNow completes to avoid data loss
    /// if the server dies between truncation and the async save completing.
    private func checkpoint() {
        guard let table = cache.snapshot else { flushTask = nil; return }
        tableDirty = false
        flushTask  = nil
        _vectorStores.withReadLock { stores in stores.values.forEach { $0.sync() } }
        let capturedWals = wals
        Task {
            await self.cache.saveNow(table)
            for (i, w) in capturedWals {
                try? w.truncate()
                self.walByteCounts[i] = 0
            }
        }
        if indicesDirty {
            saveIndicesAsync(table, truncateIndexWALs: true)
            indicesDirty     = false
            indicesFlushTask?.cancel()
            indicesFlushTask = nil
        }
    }

    private func flushIfDirty() {
        guard tableDirty, let table = cache.snapshot else {
            flushTask = nil
            return
        }
        tableDirty = false
        flushTask  = nil
        _vectorStores.withReadLock { stores in stores.values.forEach { $0.sync() } }
        let capturedWals = wals
        Task {
            await self.cache.saveNow(table)
            for (i, w) in capturedWals {
                try? w.truncate()
                self.walByteCounts[i] = 0
            }
        }
        if indicesDirty {
            saveIndicesAsync(table, truncateIndexWALs: true)
            indicesDirty     = false
            indicesFlushTask?.cancel()
            indicesFlushTask = nil
        }
    }

    // MARK: - Shard spawn helper

    /// Spawns a new shard by appending it to `table.shards`, creating a fresh vector store
    /// and WAL file. Must be called BEFORE any put targeting the new shard.
    private func spawnShard(in table: inout PartitionTable) {
        let newSI    = table.shards.count
        var newShard = HNSWShard()

        let vName = "shard-\(nodeId)-\(newSI)-vectors"
        let vURL  = FilePersistence.getDefaultURL().appendingPathComponent(vName)
        if let store = try? HNSWVectorStore(url: vURL, nodeCount: 0) {
            newShard.vectorStore = store
            _vectorStores.withWriteLock { $0[newSI] = store }
        }

        let wName = "shard-\(nodeId)-\(newSI)-topology-wal"
        let wURL  = FilePersistence.getDefaultURL().appendingPathComponent(wName)
        if let w = try? HNSWTopologyWAL(url: wURL) {
            wals[newSI]          = w
            walByteCounts[newSI] = 0
        }

        table.shards.append(newShard)
        logger.info(
            "Multi-Shard",
            "Spawned global shard \(newSI) (shard \(newSI - 1) reached \(shardSizeThreshold) nodes)",
            service: .database
        )
    }

    /// Registers a pre-existing WAL for a shard that was spawned after the last checkpoint
    /// (i.e., the shard exists only as a WAL file with no entry in the base topology file).
    /// Called from `initializeTable()` during startup shard recovery.
    func registerOrphanedShardWAL(_ w: HNSWTopologyWAL, byteCount: Int, for shardIndex: Int) {
        wals[shardIndex]          = w
        walByteCounts[shardIndex] = byteCount
    }

    // MARK: - Shard selection

    /// Returns the index of the oldest shard (lowest index) whose `nodes.count` is below
    /// `shardSizeThreshold` — i.e. a shard that has physical capacity freed by compaction.
    /// Returns `nil` when every shard is at capacity, signalling that a new shard must be spawned.
    ///
    /// Uses `nodes.count` (the physical array length) rather than `liveNodes` so only
    /// compacted shards qualify — inserting into a shard with soft-deleted but un-compacted
    /// nodes would grow its WAL unnecessarily and doesn't reclaim vector file space.
    private func oldestAvailableShard(in table: PartitionTable) -> Int? {
        table.shards.indices.first { table.shards[$0].nodes.count < shardSizeThreshold }
    }

    // MARK: - Mutations

    func put(id: DocumentID, partitions: [Database.Partition], tags: [String] = [], tagsEmbedding: [Float]? = nil, metadata: Data? = nil, request: DatabaseRequest, persistPartitionData: Bool = true) async {
        await putBatch(items: [(id, partitions, tags, tagsEmbedding, metadata, request)],
                       persistPartitionData: persistPartitionData)
    }

    /// - Parameter persistPartitionData: When true (default), writes each document's
    ///   `documents/{id}-parts` file before indexing it. `Database.putBatch` passes
    ///   false — it pre-writes all parts files in a bounded parallel task group
    ///   *before* calling in, keeping the synchronous plist encode off this actor
    ///   while preserving the invariant that the parts file is durable before the
    ///   document becomes searchable.
    func putBatch(items: [(id: DocumentID, partitions: [Database.Partition], tags: [String], tagsEmbedding: [Float]?, metadata: Data?, request: DatabaseRequest)], persistPartitionData: Bool = true) async {
        _ = await loadedTable()
        // Process one document per actor turn.
        //
        // Old design held the actor exclusively for the entire batch — no await between
        // items. For large documents (135 partitions × ~8 ms HNSW each = 1100 ms) this
        // starved the cooperative thread pool for seconds, silencing all log output and
        // blocking pending flush / checkpoint tasks.
        //
        // Safety: `Database.drain()` is strictly sequential — only one putBatch runs at
        // a time from the Database actor. By reloading `cache.snapshot` at the top of
        // each iteration we incorporate any mutation that interleaved at the previous
        // yield (single-doc put, remove, compact), keeping `nodes.count` in sync with
        // `store.nodeCount` before each `hnswInsert()`.
        for (id, partitions, tags, tagsEmbedding, metadata, request) in items {
            // Reload from cache each iteration so nodes.count == store.nodeCount.
            // Any mutation that ran during the previous yield is now visible.
            var table = cache.snapshot ?? PartitionTable()

            // Route to the oldest shard with physical capacity (post-compaction nodes.count
            // below threshold). Only spawn when every shard is genuinely full.
            let targetSI: Int
            if let si = oldestAvailableShard(in: table) {
                targetSI = si
            } else {
                spawnShard(in: &table)
                targetSI = table.activeShardIndex
            }
            if persistPartitionData {
                savePartitionData(documentId: id, partitions: partitions)
            }
            // Capture the document's previous shard before the put — a cross-shard
            // upsert needs an indexRemoved record appended to the old shard's WAL.
            let prevSI = table.documentShardIndex[id]
            table.put(id: id, partitions: partitions, tags: tags, tagsEmbedding: tagsEmbedding,
                      metadata: metadata, request: request, logger: logger, targetShard: targetSI)

            // Drain WAL records incrementally (keeps per-yield write count small) and
            // commit this document's state to the cache before releasing the actor.
            scheduleSave(draining: &table)
            // Persist this document's PQ index durably in the same actor turn as
            // the topology WAL drain — closes the crash window that used to span
            // the 3-second indices debounce.
            appendIndexWAL(documentId: id, table: table, targetShard: targetSI, previousShard: prevSI)
            cache.update(table)

            // Yield the cooperative thread so flush tasks, checkpoints, and other
            // actor work can interleave between documents.
            await Task.yield()
        }
        scheduleCompactIfNeeded()
    }

    func remove(id: DocumentID) async {
        FilePersistence(key: "documents/\(id)-parts", kind: .basic, logger: logger.base).purge()
        var table = await loadedTable()
        // Durably record the index removal before the full save below; replay
        // applies it even if the crash lands between the two.
        if let si = table.documentShardIndex[id], let w = indexWAL(for: si) {
            try? w.append(.indexRemoved(documentId: id))
            try? w.append(.commit)
        }
        table.remove(id: id)
        // Drain WAL records from all shards (only the affected shard emits non-empty records).
        for i in table.shards.indices {
            let records = table.shards[i].pendingWALRecords
            table.shards[i].pendingWALRecords = []
            records.forEach { try? wals[i]?.append($0) }
        }
        cache.update(table)
        _vectorStores.withReadLock { stores in stores.values.forEach { $0.sync() } }
        let capturedWalsRemove = wals
        Task {
            await self.cache.saveNow(table)
            for (i, w) in capturedWalsRemove {
                try? w.truncate()
                self.walByteCounts[i] = 0
            }
        }
        saveIndicesAsync(table, truncateIndexWALs: true)
    }

    func removeAll(documentIds: [DocumentID], request: DatabaseRequest) async {
        for documentId in documentIds {
            FilePersistence(key: "documents/\(documentId)-parts", kind: .basic, logger: logger.base).purge()
        }
        var table = await loadedTable()
        for documentId in documentIds {
            if let si = table.documentShardIndex[documentId], let w = indexWAL(for: si) {
                try? w.append(.indexRemoved(documentId: documentId))
                try? w.append(.commit)
            }
            table.remove(id: documentId)
        }
        // Drain WAL records from all shards before checkpoint.
        for i in table.shards.indices {
            let records = table.shards[i].pendingWALRecords
            table.shards[i].pendingWALRecords = []
            records.forEach { try? wals[i]?.append($0) }
        }
        cache.update(table)
        _vectorStores.withReadLock { stores in stores.values.forEach { $0.sync() } }
        let capturedWalsRemoveAll = wals
        Task {
            await self.cache.saveNow(table)
            for (i, w) in capturedWalsRemoveAll {
                try? w.truncate()
                self.walByteCounts[i] = 0
            }
        }
        saveIndicesAsync(table, truncateIndexWALs: true)
        logger.info(
            "Remove All",
            "Purged \(documentIds.count) document(s) from partition table",
            service: .database,
            request: request
        )
    }

    func syncEf(efSearch: Int, emaExplored: Float) {
        guard var table = cache.snapshot else { return }
        for i in table.shards.indices {
            table.shards[i].efSearch    = efSearch
            table.shards[i].emaExplored = emaExplored
        }
        cache.update(table)
    }

    /// Finds documents that appear as live nodes in more than one shard — a symptom of
    /// the pre-fix cross-shard upsert bug — and marks the older copies as deleted.
    /// Returns the number of document-shard pairs removed. Call compact() afterwards
    /// to reclaim vector file space. Idempotent: returns 0 when no duplicates exist.
    @discardableResult
    func deduplicateCrossShardNodes() async -> Int {
        var table = await loadedTable()

        var shardsByDoc: [String: [Int]] = [:]
        for (si, shard) in table.shards.enumerated() {
            let docIds = Set(shard.graph.nodes.lazy.filter { !$0.isDeleted }.map(\.documentId))
            for docId in docIds { shardsByDoc[docId, default: []].append(si) }
        }

        let duplicates = shardsByDoc.filter { $0.value.count > 1 }
        guard !duplicates.isEmpty else { return 0 }

        var removedCount = 0
        for (docId, shardIndices) in duplicates {
            let keep = shardIndices.max()!
            for si in shardIndices where si != keep {
                table.shards[si].graph.remove(documentId: docId)
                removedCount += 1
            }
        }

        for i in table.shards.indices {
            let records = table.shards[i].pendingWALRecords
            table.shards[i].pendingWALRecords = []
            records.forEach { try? wals[i]?.append($0) }
        }
        // Re-apply indices that Phase 5 may have written while we were suspended.
        if let live = cache.snapshot {
            for i in table.shards.indices where i < live.shards.count {
                if table.shards[i].indices.isEmpty && !live.shards[i].indices.isEmpty {
                    table.shards[i].indices = live.shards[i].indices
                }
            }
        }
        cache.update(table)
        return removedCount
    }

    /// Compacts each shard independently and rewrites its vector file to match.
    @discardableResult
    func compact() async -> HNSWGraph.CompactionResult {
        var table          = await loadedTable()
        var anyChanged     = false
        var aggregated     = HNSWGraph.CompactionResult.zero

        for i in table.shards.indices {
            let result = table.shards[i].compact()
            guard result.removedNodes > 0 || result.demotedEmptyHubs > 0 else { continue }
            vectorStore(for: i)?.rewrite(order: result.survivingVectorIndices)
            table.shards[i].pendingWALRecords = []
            aggregated.removedNodes          += result.removedNodes
            aggregated.demotedEmptyHubs      += result.demotedEmptyHubs
            aggregated.beforeNodes           += result.beforeNodes
            aggregated.afterNodes            += result.afterNodes
            aggregated.survivingVectorIndices = result.survivingVectorIndices  // last shard wins; OK for logging
            anyChanged = true
        }

        if anyChanged {
            // Re-apply indices from the live snapshot to avoid clobbering any indices
            // that Phase 5 (mergeIndices) wrote to the cache while we were suspended
            // at the `await loadedTable()` suspension point above.
            if let live = cache.snapshot {
                for i in table.shards.indices where i < live.shards.count {
                    if table.shards[i].indices.isEmpty && !live.shards[i].indices.isEmpty {
                        table.shards[i].indices = live.shards[i].indices
                    }
                }
            }
            cache.update(table)
            // Compaction must always flush indices and truncate index WALs so a
            // post-compaction restart replays nothing stale (indices are
            // docId-keyed, but removed documents' WAL records must not outlive
            // the checkpoint that reflects their removal).
            indicesDirty = true
            checkpoint()
        }
        return aggregated
    }

    /// Replaces the entire in-memory cache and persists topology immediately.
    func replace(with table: PartitionTable) {
        cache.update(table)
        tableDirty = false
        flushTask?.cancel()
        flushTask = nil
        compactTask?.cancel()
        compactTask = nil
        checkpoint()
        saveIndicesAsync(table, truncateIndexWALs: true)
    }
}
