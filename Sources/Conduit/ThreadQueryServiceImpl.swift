import Conduit
import Foundation
import GRPCCore
import GRPCProtobuf
import Logging

final class ThreadQueryServiceImpl: Thread_V1_ThreadQuery.SimpleServiceProtocol, Sendable {
    let database: Database
    let embeddingProvider: any EmbeddingProviding
    let graphExtractor: any GraphExtracting

    /// Search-scoped embedding cache (process-wide: the session dispatcher
    /// and direct gRPC each hold an impl, both should share hits). The model
    /// is fixed per process, so text → vector is stable.
    static let queryEmbeddingCache = QueryEmbeddingCache()

    init(database: Database, embeddingProvider: any EmbeddingProviding,
         graphExtractor: any GraphExtracting) {
        self.database = database
        self.embeddingProvider = embeddingProvider
        self.graphExtractor = graphExtractor
    }

    // MARK: - Search

    func search(
        request: Thread_V1_ThreadSearchRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Thread_V1_ThreadSearchResponse {
        // The scan is ~0.2ms; the real cost of a search RPC is the query
        // embedding round-trip(s) — timed here because the PartitionTable
        // timer starts after embedding and is structurally blind to it.
        let rpcStart = Date()
        let groups: [Database.Group]? = request.groupIds.isEmpty ? nil :
            request.groupIds.map { Database.Group(id: $0, label: "", ownerId: request.ownerID, documents: []) }

        let databaseReq = DatabaseRequest(
            ownerId: request.ownerID,
            groups: groups,
            entities: request.entities.isEmpty ? nil : Array(request.entities),
            aggregate: request.aggregate,
            scope: request.scope == "global" ? .global : .personal
        )

        var embedMs = 0
        var cacheHits = 0
        var queryFloats: [Float] = request.queryEmbedding.isEmpty ? [] : Array(request.queryEmbedding)
        var needsQuery = queryFloats.isEmpty && !request.queryText.isEmpty

        if needsQuery, let cached = Self.queryEmbeddingCache.get(request.queryText) {
            queryFloats = cached
            needsQuery = false
            cacheHits += 1
        }
        if needsQuery {
            let embedStart = Date()
            if let (embeds, _) = try? await embeddingProvider.run(
                [request.queryText], logger: database.baseLogger, priority: true
            ) {
                if let entry = embeds.first(where: { $0.index == 0 }),
                   case let .floats(v) = entry.embedding {
                    queryFloats = v
                    Self.queryEmbeddingCache.cache(request.queryText, vector: v)
                }
            }
            embedMs = Int(Date().timeIntervalSince(embedStart) * 1000)
        }

        // The user utterance remains the primary relation vector. Bonnie can
        // additionally send a few question-signature predicates (`contains`,
        // `part of`, `supports`, …); embed them separately so a broad phrase
        // such as "can you reword that" does not drown out the structural
        // relationship that identifies the right project or application fact.
        let predicateHint = Array(request.entities)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ", ")
        var predicateFloats: [Float] = []
        if !predicateHint.isEmpty {
            let embedStart = Date()
            if let (embeds, _) = try? await embeddingProvider.run(
                ["Relationship predicates: \(predicateHint)"],
                logger: database.baseLogger, priority: true
            ), let entry = embeds.first(where: { $0.index == 0 }),
              case let .floats(vector) = entry.embedding {
                predicateFloats = vector
            }
            embedMs += Int(Date().timeIntervalSince(embedStart) * 1000)
        }

        let queryData = [EmbeddingData(
            embedding: .floats(queryFloats),
            index: 0
        )]

        // Table restore is synchronous within startup; gate the first query on it.
        await database.initializationTask.value

        let matchedEntityIds: Set<EntityID>
        let matchedRelationshipIds: Set<RelationshipID>
        let matchedPredicateIds: Set<PredicateID>
        if let graph = database.graph, !graph.entities.isEmpty {
            let entityQuery = ([request.queryText] + request.entities).joined(separator: " ")
            matchedEntityIds = Set(graph.matchEntities(nameQuery: entityQuery).map { $0.entity.id })
            let primary = graph.matchRelationships(embedding: queryFloats, seededBy: matchedEntityIds)
            let hinted = predicateFloats.isEmpty
                ? []
                : graph.matchRelationships(embedding: predicateFloats)
            let relationships = primary + hinted
            matchedRelationshipIds = Set(relationships.map { $0.relationship.id })
            matchedPredicateIds = Set(relationships.map { $0.predicateId })
        } else {
            matchedEntityIds = []
            matchedRelationshipIds = []
            matchedPredicateIds = []
        }

        let result = await withCheckedContinuation { (cont: CheckedContinuation<Database.SearchResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [database, databaseReq, queryData] in
                cont.resume(returning: database.search(
                    queryData,
                    matchedEntityIds: matchedEntityIds,
                    matchedRelationshipIds: matchedRelationshipIds,
                    matchedPredicateIds: matchedPredicateIds,
                    database: databaseReq
                ))
            }
        }

        var response = Thread_V1_ThreadSearchResponse()
        response.results = result.partitionWithScores.map { score, partition in
            var r = Thread_V1_ThreadPartitionResult()
            r.threadID = database.nodeId.uuidString
            r.partitionID = partition.id
            r.documentID = partition.documentId
            r.ownerID = partition.ownerId
            r.text = partition.text
            r.score = score
            r.shardIndex = 0
            return r
        }
        if let trace = result.trace {
            var t = Thread_V1_ThreadGraphTrace()
            t.matchedEntityIds = trace.matchedEntityIds
            t.expansionEdgeIds = trace.expansionEdges
            t.expandedDocumentCount = Int32(trace.expandedDocumentCount)
            response.trace = t
        }
        let totalMs = Int(Date().timeIntervalSince(rpcStart) * 1000)
        database.logger.info(
            nil,
            "[timing] search rpc=\(totalMs)ms embed=\(embedMs)ms cache_hits=\(cacheHits) other=\(totalMs - embedMs)ms results=\(response.results.count)")
        return response
    }

    // MARK: - Index

    func index(
        request: Thread_V1_ThreadIndexRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Thread_V1_ThreadIndexResponse {
        let group: Database.Group? = request.groupID.isEmpty ? nil :
            Database.Group(id: request.groupID, label: request.groupLabel, ownerId: request.ownerID, documents: [])

        let resolvedOwner = request.ownerID.isEmpty ? "\(database.nodeId.uuidString)-thread" : request.ownerID
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

            // A caller may describe partitions itself (`partitions`, parallel to
            // `texts`): a supplied embedding is used as-is and kept, a supplied url
            // replaces the document's. Only texts without an embedding are sent to
            // this node's embedder.
            let described = Array(item.partitions)
            guard described.isEmpty || described.count == texts.count else {
                throw RPCError(code: .invalidArgument,
                               message: "document \(item.documentID): \(described.count) partitions for \(texts.count) texts")
            }
            var vectors = [[Float]?](repeating: nil, count: texts.count)
            for (i, partition) in described.enumerated() where !partition.embedding.isEmpty {
                vectors[i] = Array(partition.embedding)
            }
            let missing = vectors.indices.filter { vectors[$0] == nil }
            if !missing.isEmpty {
                let (embeddings, _) = try await embeddingProvider.run(
                    missing.map { texts[$0] },
                    logger: database.baseLogger,
                    priority: false
                )
                for entry in embeddings where entry.index < missing.count {
                    if case let .floats(v) = entry.embedding { vectors[missing[entry.index]] = v }
                }
            }
            // One PQ codebook covers every partition of a document and slices each
            // vector the same way, so they must agree on a dimensionality it divides.
            let dimensions = Set(vectors.compactMap { $0?.count }.filter { $0 > 0 })
            guard dimensions.count <= 1 else {
                throw RPCError(code: .invalidArgument,
                               message: "document \(item.documentID): partitions disagree on dimensionality \(dimensions.sorted())")
            }
            if let dim = dimensions.first, dim % PartitionQuantizer.defaultNumSubvectors != 0 {
                throw RPCError(code: .invalidArgument,
                               message: "document \(item.documentID): dimensionality \(dim) is not a multiple of \(PartitionQuantizer.defaultNumSubvectors)")
            }
            let partitionEmbeddings = vectors.enumerated()
                .map { EmbeddingData(embedding: .floats($0.element ?? []), index: $0.offset) }
            let overrides: [Database.BatchPutItem.PartitionOverride]? = described.isEmpty ? nil :
                described.map { .init(url: $0.url.isEmpty ? nil : URL(string: $0.url),
                                      keepEmbedding: !$0.embedding.isEmpty) }

            let fullCID = item.documentID
            fullCIDs.append(fullCID)

            putItems.append(Database.BatchPutItem(
                id: fullCID,
                data: partitionEmbeddings,
                texts: texts,
                graph: graph,
                needsExtraction: needsExtraction,
                mediaType: item.mediaType == "image" ? .image : .text,
                update: nil,
                name: item.name.isEmpty ? nil : item.name,
                metadata: item.metadata.isEmpty ? nil : item.metadata,
                partitions: overrides
            ))
        }

        guard !putItems.isEmpty else {
            var response = Thread_V1_ThreadIndexResponse()
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

        var response = Thread_V1_ThreadIndexResponse()
        response.success = true
        response.indexedCount = Int32(putItems.count)
        response.fullCids = fullCIDs
        return response
    }

    // MARK: - Remove

    func remove(
        request: Thread_V1_ThreadRemoveRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Thread_V1_ThreadRemoveResponse {
        let ownerId = request.ownerID

        if request.documentIds.isEmpty {
            let databaseReq = DatabaseRequest(ownerId: ownerId)
            let count = await database.removeAll(ownerId: ownerId, request: databaseReq)
            var response = Thread_V1_ThreadRemoveResponse()
            response.success = true
            response.removedCount = Int32(count)
            return response
        } else {
            let items = request.documentIds.map { (documentId: $0, ownerId: ownerId) }
            await database.enqueueRemoveBatch(items)
            var response = Thread_V1_ThreadRemoveResponse()
            response.success = true
            response.removedCount = Int32(items.count)
            return response
        }
    }
}
