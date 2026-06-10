import Foundation
import Hummingbird

// MARK: - Private helpers

private func makeNodeResponse(
    _ node: HNSWGraph.Node,
    inShard shard: HNSWShard,
    database: Database,
    fullText: Bool = false,
    allLayerNeighbors: Bool = false,
    dataLoader: PartitionDataLoader? = nil
) -> HNSWNodeResponse {
    let doc = database.document(for: node.documentId)
        ?? Database.Document(id: node.documentId, url: URL(string: "file://unknown")!, ownerId: "")
    // Batch paths pass a loader (one parts-file decode per document); the
    // single-node path falls back to a direct read.
    let rawText = (dataLoader?(node.documentId, node.partitionId)
        ?? database.partitionData(documentId: node.documentId, partitionId: node.partitionId))?.data ?? ""
    let text = fullText ? rawText : String(rawText.prefix(200))

    let neighborIds: [String]
    if allLayerNeighbors {
        var seen = Set<String>()
        var ids: [String] = []
        for layer in node.neighbors {
            for idx in layer where idx < shard.nodes.count {
                let pid = shard.nodes[idx].partitionId
                if seen.insert(pid).inserted { ids.append(pid) }
            }
        }
        neighborIds = ids
    } else {
        neighborIds = (node.neighbors.first ?? []).compactMap { idx -> String? in
            guard idx < shard.nodes.count else { return nil }
            return shard.nodes[idx].partitionId
        }
    }

    return HNSWNodeResponse(
        partitionId: node.partitionId,
        document: doc,
        text: text,
        url: doc.url,
        level: node.level,
        neighborIds: neighborIds,
        isDeleted: node.isDeleted
    )
}

private func buildGraphResponse(
    table: PartitionTable,
    shardIndexFilter: Int?,
    database: Database,
    filter: (HNSWGraph.Node) -> Bool
) -> HNSWGraphResponse {
    let shardsToScan: [(Int, HNSWShard)]
    if let si = shardIndexFilter, si >= 0, si < table.shards.count {
        shardsToScan = [(si, table.shards[si])]
    } else {
        shardsToScan = table.shards.enumerated().map { ($0.offset, $0.element) }
    }

    // Collect matches first, then resolve text through a per-request loader so
    // each document's parts file is decoded once — not once per node.
    var matched: [(shardIndex: Int, node: HNSWGraph.Node)] = []
    for (si, shard) in shardsToScan {
        for node in shard.nodes where filter(node) {
            matched.append((si, node))
        }
    }
    let shardByIndex = Dictionary(uniqueKeysWithValues: shardsToScan)
    let dataLoader = database.makePartitionDataLoader(for: Set(matched.map { $0.node.documentId }))
    var allNodes: [HNSWNodeResponse] = []
    allNodes.reserveCapacity(matched.count)
    for (si, node) in matched {
        guard let shard = shardByIndex[si] else { continue }
        allNodes.append(makeNodeResponse(node, inShard: shard, database: database, dataLoader: dataLoader))
    }

    let liveCount = allNodes.filter { !$0.isDeleted }.count
    return HNSWGraphResponse(
        nodes: allNodes,
        totalNodes: allNodes.count,
        liveNodes: liveCount,
        maxLevel: allNodes.map(\.level).max() ?? 0,
        shardIndex: shardIndexFilter,
        shardCount: table.shards.count
    )
}

private func computeStats(table: PartitionTable, ownerDocIds: Set<String>) -> HNSWStatsResponse {
    var personalLive = 0, globalLive = 0, personalMaxLevel = 0, globalMaxLevel = 0
    var personalTrained = false, globalTrained = false

    for shard in table.shards {
        let stats = shard.graphStats
        globalLive    += stats.liveNodes
        globalMaxLevel = max(globalMaxLevel, stats.maxLevel)
        globalTrained  = globalTrained || shard.isTrained

        for node in shard.nodes where !node.isDeleted && ownerDocIds.contains(node.documentId) {
            personalLive    += 1
            personalMaxLevel = max(personalMaxLevel, node.level)
            personalTrained  = true
        }
    }

    let shardCount = table.shards.count
    return HNSWStatsResponse(
        personal: .init(liveNodes: personalLive,  maxLevel: personalMaxLevel, isTrained: personalTrained, shardCount: shardCount),
        global:   .init(liveNodes: globalLive,    maxLevel: globalMaxLevel,   isTrained: globalTrained,   shardCount: shardCount)
    )
}

private let emptyGraph = HNSWGraphResponse(nodes: [], totalNodes: 0, liveNodes: 0, maxLevel: 0, shardIndex: nil, shardCount: 0)

// MARK: - Route registration

func registerHNSWRoutes(_ app: some RouterMethods<TotemRequestContext>, _ database: Database) {
    // POST /v1/hnsw/stats — this Totem's contribution to the fleet-wide aggregate
    app.post("/v1/hnsw/stats") { request, context async throws -> HNSWStatsResponse in
        let body = try await request.decode(as: HNSWRequest.self, context: context)
        let ownerId = body.seer.ownerId
        let table = database.table ?? PartitionTable()
        let ownerDocIds = Set(database.registry?.ownersDocuments[.init(id: ownerId)] ?? [])
        return computeStats(table: table, ownerDocIds: ownerDocIds)
    }

    // POST /v1/hnsw/document/stats — stats for a specific document on this Totem
    app.post("/v1/hnsw/document/stats") { request, context async throws -> HNSWStatsResponse in
        let body = try await request.decode(as: HNSWRequest.self, context: context)
        let docId = body.documentId ?? ""
        let table = database.table ?? PartitionTable()
        var liveNodes = 0, maxLevel = 0, isTrained = false
        for shard in table.shards {
            for node in shard.nodes where node.documentId == docId && !node.isDeleted {
                liveNodes += 1
                maxLevel   = max(maxLevel, node.level)
                isTrained  = true
            }
        }
        let stats = HNSWGraphStats(liveNodes: liveNodes, maxLevel: maxLevel, isTrained: isTrained, shardCount: table.shards.count)
        return HNSWStatsResponse(personal: stats, global: stats)
    }

    // POST /v1/hnsw/personal/stats — owner's live-node count on this Totem
    app.post("/v1/hnsw/personal/stats") { request, context async throws -> HNSWStatsResponse in
        let body = try await request.decode(as: HNSWRequest.self, context: context)
        let ownerId = body.seer.ownerId
        let table = database.table ?? PartitionTable()
        let ownerDocIds = Set(database.registry?.ownersDocuments[.init(id: ownerId)] ?? [])
        return computeStats(table: table, ownerDocIds: ownerDocIds)
    }

    // POST /v1/hnsw/personal — all HNSW nodes for owner's documents (optional shard filter)
    app.post("/v1/hnsw/personal") { request, context async throws -> HNSWGraphResponse in
        let body = try await request.decode(as: HNSWRequest.self, context: context)
        let ownerId = body.seer.ownerId
        let ownerDocIds = Set(database.registry?.ownersDocuments[.init(id: ownerId)] ?? [])
        guard let table = database.table else { return emptyGraph }
        return buildGraphResponse(table: table, shardIndexFilter: body.shardIndex, database: database) {
            ownerDocIds.contains($0.documentId)
        }
    }

    // POST /v1/hnsw/personal/document — nodes for a single document owned by this user
    app.post("/v1/hnsw/personal/document") { request, context async throws -> HNSWGraphResponse in
        let body = try await request.decode(as: HNSWRequest.self, context: context)
        let ownerId = body.seer.ownerId
        let docId = body.documentId ?? ""
        let ownerDocIds = Set(database.registry?.ownersDocuments[.init(id: ownerId)] ?? [])
        guard let table = database.table, ownerDocIds.contains(docId) else { return emptyGraph }
        return buildGraphResponse(table: table, shardIndexFilter: body.shardIndex, database: database) {
            $0.documentId == docId
        }
    }

    // POST /v1/hnsw/personal/documents — nodes for a set of documents owned by this user
    app.post("/v1/hnsw/personal/documents") { request, context async throws -> HNSWGraphResponse in
        let body = try await request.decode(as: HNSWRequest.self, context: context)
        let ownerId = body.seer.ownerId
        let ownerDocIds = Set(database.registry?.ownersDocuments[.init(id: ownerId)] ?? [])
        let targetIds = ownerDocIds.intersection(body.documentIds ?? [])
        guard let table = database.table, !targetIds.isEmpty else { return emptyGraph }
        return buildGraphResponse(table: table, shardIndexFilter: body.shardIndex, database: database) {
            targetIds.contains($0.documentId)
        }
    }

    // POST /v1/hnsw/personal/hubs — owner's nodes at level > 0
    app.post("/v1/hnsw/personal/hubs") { request, context async throws -> HNSWGraphResponse in
        let body = try await request.decode(as: HNSWRequest.self, context: context)
        let ownerId = body.seer.ownerId
        let ownerDocIds = Set(database.registry?.ownersDocuments[.init(id: ownerId)] ?? [])
        guard let table = database.table else { return emptyGraph }
        return buildGraphResponse(table: table, shardIndexFilter: body.shardIndex, database: database) {
            ownerDocIds.contains($0.documentId) && $0.level > 0
        }
    }

    // POST /v1/hnsw/global — all live nodes visible to owner (owned + globally available)
    app.post("/v1/hnsw/global") { request, context async throws -> HNSWGraphResponse in
        let body = try await request.decode(as: HNSWRequest.self, context: context)
        let ownerId = body.seer.ownerId
        let registry = database.registry
        let ownerDocIds = Set(registry?.ownersDocuments[.init(id: ownerId)] ?? [])
        let availableIds = registry?.availableDocumentIds ?? []
        guard let table = database.table else { return emptyGraph }
        return buildGraphResponse(table: table, shardIndexFilter: nil, database: database) {
            !$0.isDeleted && (ownerDocIds.contains($0.documentId) || availableIds.contains($0.documentId))
        }
    }

    // POST /v1/hnsw/global/hubs — visible hub nodes (level > 0)
    app.post("/v1/hnsw/global/hubs") { request, context async throws -> HNSWGraphResponse in
        let body = try await request.decode(as: HNSWRequest.self, context: context)
        let ownerId = body.seer.ownerId
        let registry = database.registry
        let ownerDocIds = Set(registry?.ownersDocuments[.init(id: ownerId)] ?? [])
        let availableIds = registry?.availableDocumentIds ?? []
        guard let table = database.table else { return emptyGraph }
        return buildGraphResponse(table: table, shardIndexFilter: nil, database: database) {
            !$0.isDeleted && $0.level > 0 && (ownerDocIds.contains($0.documentId) || availableIds.contains($0.documentId))
        }
    }

    // POST /v1/hnsw/documents — nodes for given documentIds (cross-owner)
    app.post("/v1/hnsw/documents") { request, context async throws -> HNSWGraphResponse in
        let body = try await request.decode(as: HNSWRequest.self, context: context)
        let targetIds = Set(body.documentIds ?? [])
        guard let table = database.table, !targetIds.isEmpty else { return emptyGraph }
        return buildGraphResponse(table: table, shardIndexFilter: body.shardIndex, database: database) {
            targetIds.contains($0.documentId)
        }
    }

    // POST /v1/hnsw/documents/hubs — hub nodes for given documentIds
    app.post("/v1/hnsw/documents/hubs") { request, context async throws -> HNSWGraphResponse in
        let body = try await request.decode(as: HNSWRequest.self, context: context)
        let targetIds = Set(body.documentIds ?? [])
        guard let table = database.table, !targetIds.isEmpty else { return emptyGraph }
        return buildGraphResponse(table: table, shardIndexFilter: nil, database: database) {
            targetIds.contains($0.documentId) && $0.level > 0
        }
    }

    // POST /v1/hnsw/nodes/batch — nodes matching a list of partitionIds
    app.post("/v1/hnsw/nodes/batch") { request, context async throws -> HNSWNodeBatchResponse in
        let body = try await request.decode(as: HNSWRequest.self, context: context)
        let targetPartitionIds = Set(body.partitionIds ?? [])
        guard let table = database.table, !targetPartitionIds.isEmpty else {
            return HNSWNodeBatchResponse(nodes: [])
        }
        var matched: [(shard: HNSWShard, node: HNSWGraph.Node)] = []
        for shard in table.shards {
            for pid in targetPartitionIds {
                guard let idx = shard.partitionLookup[pid], idx < shard.nodes.count else { continue }
                matched.append((shard, shard.nodes[idx]))
            }
        }
        let dataLoader = database.makePartitionDataLoader(for: Set(matched.map { $0.node.documentId }))
        let nodes = matched.map {
            makeNodeResponse($0.node, inShard: $0.shard, database: database, dataLoader: dataLoader)
        }
        return HNSWNodeBatchResponse(nodes: nodes)
    }

    // POST /v1/hnsw/node — single-node full-text inspect by partitionId
    app.post("/v1/hnsw/node") { request, context async throws -> HNSWNodeResponse in
        let body = try await request.decode(as: HNSWRequest.self, context: context)
        let pid = body.partitionId ?? ""
        guard let table = database.table else {
            throw HTTPError(.notFound, message: "No HNSW table initialized")
        }
        for shard in table.shards {
            guard let idx = shard.partitionLookup[pid], idx < shard.nodes.count else { continue }
            return makeNodeResponse(shard.nodes[idx], inShard: shard, database: database,
                                    fullText: true, allLayerNeighbors: true)
        }
        throw HTTPError(.notFound, message: "Partition \(pid) not found in HNSW graph")
    }

    // DELETE /v1/hnsw/node — soft-delete a node by partitionId
    app.delete("/v1/hnsw/node") { request, context async throws -> HNSWNodeDeleteResponse in
        let body = try await request.decode(as: HNSWRequest.self, context: context)
        let ownerId = body.seer.ownerId
        let pid = body.partitionId ?? ""
        var documentId = ""
        if let table = database.table {
            outer: for shard in table.shards {
                if let idx = shard.partitionLookup[pid], idx < shard.nodes.count {
                    documentId = shard.nodes[idx].documentId
                    break outer
                }
            }
        }
        let found = !documentId.isEmpty
        if found {
            await database.removeNode(partitionId: pid, ownerId: ownerId)
        }
        return HNSWNodeDeleteResponse(removed: found, documentId: documentId)
    }
}
