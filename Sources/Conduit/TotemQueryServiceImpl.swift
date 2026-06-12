import Conduit
import Foundation
import GRPCCore
import GRPCProtobuf
import Logging

final class TotemQueryServiceImpl: Totem_V1_TotemQuery.SimpleServiceProtocol, Sendable {
    let database: Database
    let embeddingProvider: any EmbeddingProviding

    init(database: Database, embeddingProvider: any EmbeddingProviding) {
        self.database = database
        self.embeddingProvider = embeddingProvider
    }

    // MARK: - Search

    func search(
        request: Totem_V1_TotemSearchRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemSearchResponse {
        let groups: [Database.Group]? = request.groupIds.isEmpty ? nil :
            request.groupIds.map { Database.Group(id: $0, label: "", ownerId: request.ownerID, documents: []) }

        let databaseReq = DatabaseRequest(
            ownerId: request.ownerID,
            groups: groups,
            aggregate: request.aggregate,
            scope: request.scope == "global" ? .global : .personal
        )

        let queryFloats: [Float]
        if !request.queryEmbedding.isEmpty {
            queryFloats = Array(request.queryEmbedding)
        } else if !request.queryText.isEmpty {
            let (embeds, _) = try await embeddingProvider.run(
                [request.queryText],
                logger: database.baseLogger,
                priority: true
            )
            if case let .floats(v) = embeds.first?.embedding { queryFloats = v } else { queryFloats = [] }
        } else {
            queryFloats = []
        }

        let queryData = [EmbeddingData(
            embedding: .floats(queryFloats),
            index: 0
        )]
        let tagEmbedding: [Float]? = request.queryTagEmbedding.isEmpty ? nil :
            Array(request.queryTagEmbedding)

        await database.nonisolatedTableMutator.waitForIndices()

        let result = await withCheckedContinuation { (cont: CheckedContinuation<Database.SearchResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [database, databaseReq, queryData, tagEmbedding] in
                cont.resume(returning: database.search(queryData, queryTagEmbedding: tagEmbedding, database: databaseReq))
            }
        }

        let shardLookup = database.table?.documentShardIndex ?? [:]
        var response = Totem_V1_TotemSearchResponse()
        response.results = result.partitionWithScores.map { score, partition in
            var r = Totem_V1_TotemPartitionResult()
            r.totemID = database.nodeId.uuidString
            r.partitionID = partition.id
            r.documentID = partition.documentId
            r.ownerID = partition.ownerId
            r.text = partition.text
            r.score = score
            r.shardIndex = Int32(shardLookup[partition.documentId] ?? 0)
            return r
        }
        return response
    }

    // MARK: - Index

    func index(
        request: Totem_V1_TotemIndexRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemIndexResponse {
        let group: Database.Group? = request.groupID.isEmpty ? nil :
            Database.Group(id: request.groupID, label: request.groupLabel, ownerId: request.ownerID, documents: [])

        let resolvedOwner = request.ownerID.isEmpty ? "\(database.nodeId.uuidString)-totem" : request.ownerID
        let databaseReq = DatabaseRequest(
            ownerId: resolvedOwner,
            group: group,
            scope: request.scope == "global" ? .global : .personal
        )

        var putItems: [Database.BatchPutItem] = []
        var fullCIDs: [String] = []

        for item in request.items {
            let texts = Array(item.texts)
            guard !texts.isEmpty else { continue }

            let (embeddings, _) = try await embeddingProvider.run(
                texts,
                logger: database.baseLogger,
                priority: false
            )

            let fullCID = item.documentID
            fullCIDs.append(fullCID)

            putItems.append(Database.BatchPutItem(
                id: fullCID,
                data: embeddings,
                texts: texts,
                tags: Array(item.tags),
                tagsEmbedding: nil,
                mediaType: item.mediaType == "image" ? .image : .text,
                update: nil,
                name: item.name.isEmpty ? nil : item.name,
                metadata: item.metadata.isEmpty ? nil : item.metadata
            ))
        }

        guard !putItems.isEmpty else {
            var response = Totem_V1_TotemIndexResponse()
            response.success = true
            response.indexedCount = 0
            return response
        }

        await database.enqueuePut(putItems, request: databaseReq)

        var response = Totem_V1_TotemIndexResponse()
        response.success = true
        response.indexedCount = Int32(putItems.count)
        response.fullCids = fullCIDs
        return response
    }

    // MARK: - Remove

    func remove(
        request: Totem_V1_TotemRemoveRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemRemoveResponse {
        let ownerId = request.ownerID

        if request.documentIds.isEmpty {
            let databaseReq = DatabaseRequest(ownerId: ownerId)
            let count = await database.removeAll(ownerId: ownerId, request: databaseReq)
            var response = Totem_V1_TotemRemoveResponse()
            response.success = true
            response.removedCount = Int32(count)
            return response
        } else {
            let items = request.documentIds.map { (documentId: $0, ownerId: ownerId) }
            await database.enqueueRemoveBatch(items)
            var response = Totem_V1_TotemRemoveResponse()
            response.success = true
            response.removedCount = Int32(items.count)
            return response
        }
    }
}
