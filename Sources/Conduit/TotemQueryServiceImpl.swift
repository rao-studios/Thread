import Conduit
import Foundation
import GRPCCore
import GRPCProtobuf
import Logging

final class TotemQueryServiceImpl: Totem_V1_TotemQuery.SimpleServiceProtocol, Sendable {
    let database: Database
    let embeddingProvider: any EmbeddingProviding
    let graphExtractor: any GraphExtracting

    init(database: Database, embeddingProvider: any EmbeddingProviding,
         graphExtractor: any GraphExtracting) {
        self.database = database
        self.embeddingProvider = embeddingProvider
        self.graphExtractor = graphExtractor
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
            entities: request.entities.isEmpty ? nil : Array(request.entities),
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

        // Query-side entity embedding: explicit on the request, else embedded from the
        // caller's entity terms (mirrors the REST search path).
        var entityEmbedding: [Float]? = request.queryEntityEmbedding.isEmpty ? nil :
            Array(request.queryEntityEmbedding)
        if entityEmbedding == nil, !request.entities.isEmpty {
            let entityString = request.entities.sorted().joined(separator: " ")
            if let (embeds, _) = try? await embeddingProvider.run(
                [entityString], logger: database.baseLogger, priority: true
            ), case let .floats(v) = embeds.first?.embedding {
                entityEmbedding = v
            }
        }

        // Table restore is synchronous within startup; gate the first query on it.
        await database.initializationTask.value

        // Match query entities against the graph (name tokens + content-vector similarity).
        let matchedEntityIds: Set<EntityID>
        if let graph = database.graph, !graph.entities.isEmpty {
            let nameQuery = request.queryText.isEmpty ? nil : request.queryText
            matchedEntityIds = Set(
                graph.matchEntities(nameQuery: nameQuery,
                                    embedding: queryFloats.isEmpty ? nil : queryFloats)
                    .map { $0.entity.id }
            )
        } else {
            matchedEntityIds = []
        }

        let capturedEntityEmbedding = entityEmbedding
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Database.SearchResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [database, databaseReq, queryData] in
                cont.resume(returning: database.search(
                    queryData,
                    queryEntityEmbedding: capturedEntityEmbedding,
                    matchedEntityIds: matchedEntityIds,
                    database: databaseReq
                ))
            }
        }

        var response = Totem_V1_TotemSearchResponse()
        response.results = result.partitionWithScores.map { score, partition in
            var r = Totem_V1_TotemPartitionResult()
            r.totemID = database.nodeId.uuidString
            r.partitionID = partition.id
            r.documentID = partition.documentId
            r.ownerID = partition.ownerId
            r.text = partition.text
            r.score = score
            r.shardIndex = 0
            return r
        }
        if let trace = result.trace {
            var t = Totem_V1_TotemGraphTrace()
            t.matchedEntityIds = trace.matchedEntityIds
            t.expansionEdgeIds = trace.expansionEdges
            t.expandedDocumentCount = Int32(trace.expandedDocumentCount)
            response.trace = t
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

            // Provisional entities: caller-provided `entities`, else the legacy `tags`
            // alias as concept entities, else keyword fallback flagged for LLM extraction.
            var resolvedEntities: [Database.GraphPayload.EntityIn] = item.entities.map {
                .init(name: $0.name, kind: $0.kind.isEmpty ? "concept" : $0.kind)
            }
            if resolvedEntities.isEmpty {
                resolvedEntities = item.tags.map { .init(name: $0, kind: "concept") }
            }
            let needsExtraction = resolvedEntities.isEmpty
            if needsExtraction {
                resolvedEntities = TagGenerator.generate(from: texts).map { .init(name: $0, kind: "concept") }
            }
            let relations: [Database.GraphPayload.RelationIn] = item.relationships.map {
                .init(subject: $0.subject, predicate: $0.predicate, object: $0.object)
            }
            let graph = Database.GraphPayload(entities: resolvedEntities, relationships: relations)

            // Embed partitions + one joined-entity-names string (the doc-level entity embedding).
            var toEmbed = texts
            toEmbed.append(resolvedEntities.map { $0.name }.joined(separator: " "))
            let (embeddings, _) = try await embeddingProvider.run(
                toEmbed,
                logger: database.baseLogger,
                priority: false
            )
            let sorted = embeddings.sorted { $0.index < $1.index }
            let partitionEmbeddings = Array(sorted.dropLast()).enumerated()
                .map { EmbeddingData(embedding: $0.element.embedding, index: $0.offset) }
            let entityEmbedding: [Float]?
            if case .floats(let v) = sorted.last?.embedding { entityEmbedding = v } else { entityEmbedding = nil }

            let fullCID = item.documentID
            fullCIDs.append(fullCID)

            putItems.append(Database.BatchPutItem(
                id: fullCID,
                data: partitionEmbeddings,
                texts: texts,
                graph: graph,
                entityEmbedding: entityEmbedding,
                needsExtraction: needsExtraction,
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

        // Respond now; enrichment (LLM extraction + entity embedding) runs detached and
        // enqueues the put — identical shape to the REST ingest path.
        let capturedItems = putItems
        let capturedReq = databaseReq
        Task.detached(priority: .userInitiated) { [database, graphExtractor, embeddingProvider] in
            let enriched = await GraphEnrichment.run(
                items: capturedItems,
                extractor: graphExtractor,
                embedder: embeddingProvider,
                existingGraph: database.graph,
                logger: database.baseLogger
            )
            await database.enqueuePut(enriched, request: capturedReq)
        }

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
