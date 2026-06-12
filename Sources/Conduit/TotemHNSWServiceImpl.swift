import Conduit
import Foundation
import GRPCCore
import GRPCProtobuf

final class TotemHNSWServiceImpl: Totem_V1_TotemHNSW.SimpleServiceProtocol, Sendable {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    // MARK: - Stats

    func stats(
        request: Totem_V1_TotemHNSWStatsRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemHNSWStatsResponse {
        let table = database.table ?? PartitionTable()

        if !request.documentID.isEmpty {
            // Per-document stats
            let docId = request.documentID
            var liveNodes = 0, maxLevel = 0, isTrained = false
            for shard in table.shards {
                for node in shard.nodes where node.documentId == docId && !node.isDeleted {
                    liveNodes += 1
                    maxLevel   = max(maxLevel, node.level)
                    isTrained  = true
                }
            }
            let stats = makeHNSWGraphStats(liveNodes: liveNodes, maxLevel: maxLevel,
                                           isTrained: isTrained, shardCount: table.shards.count)
            var resp = Totem_V1_TotemHNSWStatsResponse()
            resp.personal = stats
            resp.global   = stats
            return resp
        }

        // Per-owner stats
        let ownerDocIds = Set(database.registry?.ownersDocuments[.init(id: request.ownerID)] ?? [])
        var personalLive = 0, globalLive = 0, personalMaxLevel = 0, globalMaxLevel = 0
        var personalTrained = false, globalTrained = false

        for shard in table.shards {
            let s = shard.graphStats
            globalLive    += s.liveNodes
            globalMaxLevel = max(globalMaxLevel, s.maxLevel)
            globalTrained  = globalTrained || shard.isTrained

            for node in shard.nodes where !node.isDeleted && ownerDocIds.contains(node.documentId) {
                personalLive    += 1
                personalMaxLevel = max(personalMaxLevel, node.level)
                personalTrained  = true
            }
        }

        var resp = Totem_V1_TotemHNSWStatsResponse()
        resp.personal = makeHNSWGraphStats(liveNodes: personalLive, maxLevel: personalMaxLevel,
                                           isTrained: personalTrained, shardCount: table.shards.count)
        resp.global   = makeHNSWGraphStats(liveNodes: globalLive, maxLevel: globalMaxLevel,
                                           isTrained: globalTrained, shardCount: table.shards.count)
        return resp
    }

    // MARK: - Graph

    func graph(
        request: Totem_V1_TotemHNSWGraphRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemHNSWGraphResponse {
        guard let table = database.table else { return emptyGraphResponse() }

        let shardFilter: Int? = request.shardIndex >= 0 ? Int(request.shardIndex) : nil
        let hubsOnly = request.hubsOnly

        let filter: (HNSWGraph.Node) -> Bool
        switch request.scope {
        case "global":
            let registry = database.registry
            let ownerIds = Set(registry?.ownersDocuments[.init(id: request.ownerID)] ?? [])
            let availIds = Set(registry?.availableDocumentIds ?? [])
            filter = { !$0.isDeleted && (ownerIds.contains($0.documentId) || availIds.contains($0.documentId))
                       && (!hubsOnly || $0.level > 0) }

        case "documents":
            let targetIds = Set(request.documentIds)
            filter = { targetIds.contains($0.documentId) && (!hubsOnly || $0.level > 0) }

        default: // "personal"
            let ownerDocIds = Set(database.registry?.ownersDocuments[.init(id: request.ownerID)] ?? [])
            if !request.documentID.isEmpty {
                let docId = request.documentID
                guard ownerDocIds.contains(docId) else { return emptyGraphResponse() }
                filter = { $0.documentId == docId && (!hubsOnly || $0.level > 0) }
            } else if !request.documentIds.isEmpty {
                let targetIds = ownerDocIds.intersection(request.documentIds)
                guard !targetIds.isEmpty else { return emptyGraphResponse() }
                filter = { targetIds.contains($0.documentId) && (!hubsOnly || $0.level > 0) }
            } else {
                filter = { ownerDocIds.contains($0.documentId) && (!hubsOnly || $0.level > 0) }
            }
        }

        return buildGraphResponse(table: table, shardIndexFilter: shardFilter, filter: filter)
    }

    // MARK: - NodeBatch

    func nodeBatch(
        request: Totem_V1_TotemHNSWNodeBatchRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemHNSWNodeBatchResponse {
        guard let table = database.table else {
            return Totem_V1_TotemHNSWNodeBatchResponse()
        }
        let targetIds = Set(request.partitionIds)
        var nodes: [Totem_V1_TotemHNSWNode] = []
        for shard in table.shards {
            for pid in targetIds {
                guard let idx = shard.partitionLookup[pid], idx < shard.nodes.count else { continue }
                nodes.append(makeProtoNode(shard.nodes[idx], inShard: shard))
            }
        }
        var resp = Totem_V1_TotemHNSWNodeBatchResponse()
        resp.nodes = nodes
        return resp
    }

    // MARK: - Node

    func node(
        request: Totem_V1_TotemHNSWNodeRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemHNSWNodeResponse {
        let pid = request.partitionID
        guard let table = database.table else {
            throw GRPCCore.RPCError(code: .notFound, message: "No HNSW table initialized")
        }
        for shard in table.shards {
            guard let idx = shard.partitionLookup[pid], idx < shard.nodes.count else { continue }
            var resp = Totem_V1_TotemHNSWNodeResponse()
            resp.node = makeProtoNode(shard.nodes[idx], inShard: shard, fullText: true, allLayers: true)
            return resp
        }
        throw GRPCCore.RPCError(code: .notFound, message: "Partition \(pid) not found in HNSW graph")
    }

    // MARK: - DeleteNode

    func deleteNode(
        request: Totem_V1_TotemHNSWDeleteNodeRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemHNSWDeleteNodeResponse {
        let pid = request.partitionID
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
            await database.removeNode(partitionId: pid, ownerId: request.ownerID)
        }
        var resp = Totem_V1_TotemHNSWDeleteNodeResponse()
        resp.removed     = found
        resp.documentID  = documentId
        return resp
    }

    // MARK: - Private helpers

    private func makeHNSWGraphStats(
        liveNodes: Int, maxLevel: Int, isTrained: Bool, shardCount: Int
    ) -> Totem_V1_TotemHNSWGraphStats {
        var s = Totem_V1_TotemHNSWGraphStats()
        s.liveNodes  = Int32(liveNodes)
        s.maxLevel   = Int32(maxLevel)
        s.isTrained  = isTrained
        s.shardCount = Int32(shardCount)
        return s
    }

    private func makeProtoNode(
        _ node: HNSWGraph.Node,
        inShard shard: HNSWShard,
        fullText: Bool = false,
        allLayers: Bool = false
    ) -> Totem_V1_TotemHNSWNode {
        let doc = database.document(for: node.documentId)
        let rawText = database.partitionData(documentId: node.documentId, partitionId: node.partitionId)?.data ?? ""

        let neighborIds: [String]
        if allLayers {
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

        var n = Totem_V1_TotemHNSWNode()
        n.partitionID      = node.partitionId
        n.documentID       = node.documentId
        n.documentURL      = doc?.url.absoluteString ?? ""
        n.documentOwnerID  = doc?.ownerId ?? ""
        n.text             = fullText ? rawText : String(rawText.prefix(200))
        n.level            = Int32(node.level)
        n.neighborIds      = neighborIds
        n.isDeleted        = node.isDeleted
        if fullText {
            n.metadata = database.table?.index(for: node.documentId)?.metadata ?? Data()
        }
        return n
    }

    private func buildGraphResponse(
        table: PartitionTable,
        shardIndexFilter: Int?,
        filter: (HNSWGraph.Node) -> Bool
    ) -> Totem_V1_TotemHNSWGraphResponse {
        let shardsToScan: [(Int, HNSWShard)]
        if let si = shardIndexFilter, si >= 0, si < table.shards.count {
            shardsToScan = [(si, table.shards[si])]
        } else {
            shardsToScan = table.shards.enumerated().map { ($0.offset, $0.element) }
        }

        var allNodes: [Totem_V1_TotemHNSWNode] = []
        for (_, shard) in shardsToScan {
            for node in shard.nodes where filter(node) {
                allNodes.append(makeProtoNode(node, inShard: shard))
            }
        }

        let liveCount = allNodes.filter { !$0.isDeleted }.count
        var resp = Totem_V1_TotemHNSWGraphResponse()
        resp.nodes      = allNodes
        resp.totalNodes = Int32(allNodes.count)
        resp.liveNodes  = Int32(liveCount)
        resp.maxLevel   = Int32(allNodes.map { Int($0.level) }.max() ?? 0)
        resp.shardIndex = Int32(shardIndexFilter ?? -1)
        resp.shardCount = Int32(table.shards.count)
        return resp
    }

    private func emptyGraphResponse() -> Totem_V1_TotemHNSWGraphResponse {
        var resp = Totem_V1_TotemHNSWGraphResponse()
        resp.shardIndex = -1
        return resp
    }
}
