//
//  TableMutator.swift
//  database-server
//
//  Created by Ritesh Pakala on 3/7/26.
//

import Foundation

/// Serializes all read-modify-write operations on the PartitionTable and its companion
/// GraphStore.
///
/// Both stores mutate together on every `put`/`remove` (a document's partitions and the
/// entities it contributes are one logical unit), so a single actor owns both — no
/// cross-store coordination is possible to get wrong. Each is persisted to its own plist
/// (`table-<nodeId>`, `graph-<nodeId>`) with a shared 1-second debounce; removes and
/// shutdown save immediately.
actor TableMutator {
    private let nodeId: UUID
    private let cache:      TotemCache<PartitionTable>
    private let graphCache: TotemCache<GraphStore>
    private let logger: TotemLogger

    // MARK: - Debounced disk saves

    private var dirty = false
    private var flushTask: Task<Void, Never>?

    // MARK: - Init

    init(nodeId: UUID, logger: TotemLogger) {
        self.nodeId = nodeId
        self.cache = TotemCache(
            persistence: FilePersistence(key: "table-\(nodeId)", kind: .basic, logger: logger.base)
        )
        self.graphCache = TotemCache(
            persistence: FilePersistence(key: "graph-\(nodeId)", kind: .basic, logger: logger.base)
        )
        self.logger = logger
    }

    // MARK: - Startup seeding

    nonisolated func seed(_ initial: PartitionTable) { cache.seed(initial) }
    nonisolated func seedGraph(_ initial: GraphStore) { graphCache.seed(initial) }

    // MARK: - Snapshots

    nonisolated var snapshot: PartitionTable? { cache.snapshot }
    nonisolated var graphSnapshot: GraphStore? { graphCache.snapshot }

    // MARK: - Mutations

    func put(id: DocumentID,
             partitions: [Database.Partition],
             graph: Database.GraphPayload = .init(),
             entityEmbedding: [Float]? = nil,
             metadata: Data? = nil,
             request: DatabaseRequest,
             persistPartitionData: Bool = true) async {
        await putBatch(items: [(id, partitions, graph, entityEmbedding, metadata, request)],
                       persistPartitionData: persistPartitionData)
    }

    /// - Parameter persistPartitionData: When true (default), writes each document's
    ///   `documents/{id}-parts` file before indexing it. `Database.putBatch` passes
    ///   false — it pre-writes all parts files in a bounded parallel task group
    ///   *before* calling in, keeping the synchronous plist encode off this actor
    ///   while preserving the invariant that the parts file is durable before the
    ///   document becomes searchable.
    func putBatch(items: [(id: DocumentID, partitions: [Database.Partition], graph: Database.GraphPayload, entityEmbedding: [Float]?, metadata: Data?, request: DatabaseRequest)],
                  persistPartitionData: Bool = true) async {
        _ = await loadedTable()
        _ = await loadedGraph()

        // Process one document per actor turn. PQ training for a large document can
        // take a while; reloading the snapshot each iteration and yielding lets other
        // actor work (removes, flushes, shutdown) interleave between documents.
        for (id, partitions, graph, entityEmbedding, metadata, request) in items {
            var table = cache.snapshot ?? PartitionTable()
            var graphStore = graphCache.snapshot ?? GraphStore()

            if persistPartitionData {
                savePartitionData(documentId: id, partitions: partitions)
            }
            let entityIds = graphStore.upsert(graph, documentId: id)
            table.put(id: id, partitions: partitions, entityIds: entityIds,
                      entityEmbedding: entityEmbedding, metadata: metadata,
                      request: request, logger: logger)

            cache.update(table)
            graphCache.update(graphStore)
            await Task.yield()
        }
        scheduleSave()
    }

    func remove(id: DocumentID) async {
        FilePersistence(key: "documents/\(id)-parts", kind: .basic, logger: logger.base).purge()
        var table = await loadedTable()
        var graphStore = await loadedGraph()
        let entityIds = table.index(for: id)?.entityIds ?? []
        table.remove(id: id)
        graphStore.detach(documentId: id, entityIds: entityIds)
        cache.update(table)
        graphCache.update(graphStore)
        await saveBoth(table, graphStore)
    }

    func removeAll(documentIds: [DocumentID], request: DatabaseRequest) async {
        for documentId in documentIds {
            FilePersistence(key: "documents/\(documentId)-parts", kind: .basic, logger: logger.base).purge()
        }
        var table = await loadedTable()
        var graphStore = await loadedGraph()
        for documentId in documentIds {
            let entityIds = table.index(for: documentId)?.entityIds ?? []
            table.remove(id: documentId)
            graphStore.detach(documentId: documentId, entityIds: entityIds)
        }
        cache.update(table)
        graphCache.update(graphStore)
        await saveBoth(table, graphStore)
        logger.info(
            "Remove All",
            "Purged \(documentIds.count) document(s) from partition table + graph",
            service: .database,
            request: request
        )
    }

    // MARK: - Graph mutations

    enum GraphMutation {
        case deleteEntity(EntityID)
        case deleteRelationship(RelationshipID)
        case renameEntity(EntityID, newName: String)
        case mergeEntities(from: EntityID, into: EntityID)
        case setEntityKind(EntityID, kind: String)
    }

    /// Applies a granular graph edit atomically with the `PartitionIndex.entityIds`
    /// rewrite for every affected document, then persists both stores immediately.
    /// Returns the surviving entity id for re-key operations.
    @discardableResult
    func mutateGraph(_ mutation: GraphMutation) async -> EntityID? {
        var table = await loadedTable()
        var graphStore = await loadedGraph()

        let oldId: EntityID?
        let result: GraphStore.MutationResult
        switch mutation {
        case .deleteEntity(let id):
            oldId = id
            result = graphStore.deleteEntity(id: id)
        case .deleteRelationship(let id):
            oldId = nil
            graphStore.deleteRelationship(id: id)
            result = .init(survivingId: nil, affectedDocumentIds: [])
        case .renameEntity(let id, let newName):
            oldId = id
            result = graphStore.renameEntity(id: id, newName: newName)
        case .mergeEntities(let from, let into):
            oldId = from
            result = graphStore.mergeEntities(from: from, into: into)
        case .setEntityKind(let id, let kind):
            oldId = id
            result = graphStore.setEntityKind(id: id, kind: kind)
        }

        // Rewrite entity linkage on every affected document's index.
        if let oldId, !result.affectedDocumentIds.isEmpty {
            for documentId in result.affectedDocumentIds {
                guard var index = table.indices[documentId] else { continue }
                if let survivingId = result.survivingId {
                    index.entityIds = index.entityIds.map { $0 == oldId ? survivingId : $0 }
                    // Dedup while preserving order (merge can collapse two ids into one).
                    var seen = Set<EntityID>()
                    index.entityIds = index.entityIds.filter { seen.insert($0).inserted }
                } else {
                    index.entityIds.removeAll { $0 == oldId }
                }
                table.indices[documentId] = index
            }
        }

        cache.update(table)
        graphCache.update(graphStore)
        await saveBoth(table, graphStore)
        return result.survivingId
    }

    /// Replaces a document's graph contribution: detaches its old entity linkage,
    /// upserts the freshly extracted payload, and updates the index's entity ids
    /// and doc-level entity embedding. Used by re-extraction.
    func reapplyGraph(documentId: DocumentID,
                      payload: Database.GraphPayload,
                      entityEmbedding: [Float]?,
                      request: DatabaseRequest) async {
        var table = await loadedTable()
        var graphStore = await loadedGraph()
        guard var index = table.indices[documentId] else { return }

        graphStore.detach(documentId: documentId, entityIds: index.entityIds)
        let entityIds = graphStore.upsert(payload, documentId: documentId)
        index.entityIds = entityIds
        if let entityEmbedding { index.entityEmbedding = entityEmbedding }
        table.indices[documentId] = index

        cache.update(table)
        graphCache.update(graphStore)
        await saveBoth(table, graphStore)
        logger.info(
            "Graph Re-extract",
            "Re-applied graph for \(documentId) — \(entityIds.count) entity(ies), \(payload.relationships.count) relationship(s)",
            service: .database,
            request: request,
            flow: .embed(documentId: documentId)
        )
    }

    /// Replaces the entire in-memory table and persists immediately.
    func replace(with table: PartitionTable) async {
        cache.update(table)
        dirty = false
        flushTask?.cancel()
        flushTask = nil
        await cache.saveNow(table)
    }

    /// Wipes this node's partition table and graph and persists the empty
    /// stores immediately. Shared `documents/` files are untouched — they are
    /// content-addressed and may be referenced by co-located nodes.
    func clearAll() async {
        flushTask?.cancel()
        flushTask = nil
        dirty = false
        let table = PartitionTable()
        let graphStore = GraphStore()
        cache.update(table)
        graphCache.update(graphStore)
        await saveBoth(table, graphStore)
    }

    // MARK: - Graceful shutdown

    func flushAllForShutdown() async {
        flushTask?.cancel()
        flushTask = nil
        dirty = false
        if let table = cache.snapshot { await cache.saveNow(table) }
        if let graphStore = graphCache.snapshot { await graphCache.saveNow(graphStore) }
    }

    // MARK: - Private

    private func loadedTable() async -> PartitionTable {
        await cache.load { .init() }
    }

    private func loadedGraph() async -> GraphStore {
        await graphCache.load { .init() }
    }

    private func savePartitionData(documentId: DocumentID, partitions: [Database.Partition]) {
        let metadata = partitions.map { PartitionData(from: $0) }
        FilePersistence(key: "documents/\(documentId)-parts", kind: .basic,
                        logger: logger.base).save(state: metadata)
    }

    private func saveBoth(_ table: PartitionTable, _ graphStore: GraphStore) async {
        await cache.saveNow(table)
        await graphCache.saveNow(graphStore)
    }

    private func scheduleSave() {
        dirty = true
        guard flushTask == nil else { return }
        flushTask = Task {
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            self.flushIfDirty()
        }
    }

    private func flushIfDirty() {
        flushTask = nil
        guard dirty else { return }
        dirty = false
        if let table = cache.snapshot { cache.saveAsync(table) }
        if let graphStore = graphCache.snapshot { graphCache.saveAsync(graphStore) }
    }
}
