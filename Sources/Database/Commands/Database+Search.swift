import Foundation

extension Database {
    nonisolated func search(_ queryData: [EmbeddingData],
                matchedEntityIds: Set<EntityID> = [],
                matchedRelationshipIds: Set<RelationshipID> = [],
                matchedPredicateIds: Set<PredicateID> = [],
                identifierScores: [EntityID: Float] = [:],
                expand: Bool = true,
                database: DatabaseRequest) -> SearchResult {
        guard let table = self.table else {
            logger.debug("Search", "Index could not be retrieved to search for partitions.", service: .database, request: database)
            return .init(data: [], adjustments: [], trace: nil)
        }

        let compiled = queryData.map {
            if case let .floats(array) = $0.embedding {
                return array
            } else {
                return []
            }
        }

        var data: [PartitionSearchResult] = []
        var adjustments: [SinatraAdjustment] = []
        var trace: GraphSearchTrace?

        if let registry = self.registry {
            let graphStore = self.graph
            let loader: PartitionDataLoader = { [self] docId, partId in
                self.partitionData(documentId: docId, partitionId: partId)
            }
            for embedding in compiled {
                let result = table.search(embedding: embedding,
                                          matchedEntityIds: matchedEntityIds,
                                          matchedRelationshipIds: matchedRelationshipIds,
                                          matchedPredicateIds: matchedPredicateIds,
                                          identifierScores: identifierScores,
                                          graph: graphStore,
                                          expand: expand,
                                          sinatra: sinatra,
                                          registry: registry,
                                          request: database,
                                          metadataLoader: loader,
                                          logger: logger)
                data.append(contentsOf: result.partitions)
                adjustments.append(contentsOf: result.adjustments)
                if let t = result.trace { trace = t }
            }
        }

        return SearchResult(data: data, adjustments: adjustments, trace: trace)
    }

    nonisolated func search(_ query: String?,
                request: DatabaseRequest,
                embeddingModelProvider: (any EmbeddingProviding)?,
                expand: Bool = true) async throws -> SearchChatResult {
        guard let query else {
            logger.info("Search", "No query to search.", service: .database, request: request, flow: .chat)
            return SearchChatResult(context: [], adjustments: [], references: [])
        }

        let requestEntities = request.entities ?? request.tags ?? []
        let queryEmbedding = try await embed([query], provider: embeddingModelProvider)

        let matchedEntityIds: Set<EntityID>
        let matchedRelationshipIds: Set<RelationshipID>
        let matchedPredicateIds: Set<PredicateID>
        var identifierScores: [EntityID: Float] = [:]
        if request.isCode {
            identifierScores = self.identifierScores(queryText: query, entities: requestEntities)
            matchedEntityIds = Set(identifierScores.keys)
            matchedRelationshipIds = []
            matchedPredicateIds = []
        } else if let graph = self.graph, !graph.entities.isEmpty {
            let queryVector: [Float]? = queryEmbedding.first.flatMap {
                if case .floats(let v) = $0.embedding { return v }
                return nil
            }
            let entityQuery = ([query] + requestEntities).joined(separator: " ")
            matchedEntityIds = Set(graph.matchEntities(nameQuery: entityQuery).map { $0.entity.id })
            let relationships = queryVector.map {
                graph.matchRelationships(embedding: $0, seededBy: matchedEntityIds)
            } ?? []
            matchedRelationshipIds = Set(relationships.map { $0.relationship.id })
            matchedPredicateIds = Set(relationships.map { $0.predicateId })
        } else {
            matchedEntityIds = []
            matchedRelationshipIds = []
            matchedPredicateIds = []
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<SearchResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let r = self.search(queryEmbedding,
                                    matchedEntityIds: matchedEntityIds,
                                    matchedRelationshipIds: matchedRelationshipIds,
                                    matchedPredicateIds: matchedPredicateIds,
                                    identifierScores: identifierScores,
                                    expand: expand,
                                    database: request)
                continuation.resume(returning: r)
            }
        }
        let partitions = result.partitions

        logger.info(
            "Search",
            "Retrieved \(partitions.count) partition(s) for query",
            service: .database,
            request: request,
            flow: .chat
        )

        return SearchChatResult(
            context: partitions.map { $0.text },
            adjustments: result.adjustments,
            references: result.asDocumentReference,
            partitions: partitions,
            trace: result.trace
        )
    }

    /// The code instrument's graph signal: the identifiers a query names, matched exactly
    /// against entity names, as a score per matched entity. Hubs are skipped: an entity in
    /// more documents than the extraction policy's hub cap, or a twentieth of the node,
    /// names nothing in particular.
    nonisolated func identifierScores(queryText: String, entities: [String]) -> [EntityID: Float] {
        guard let graph = self.graph, !graph.entities.isEmpty else { return [:] }
        let terms = GraphStore.identifierTerms(queryText: queryText, entities: entities)
        guard !terms.isEmpty else { return [:] }
        let documentCount = self.table?.keys.count ?? 0
        let hubDegreeCap = max(ExtractionPolicyStore.current.hubDegreeCap ?? 24, documentCount / 20)
        let matches = graph.matchIdentifiers(terms, hubDegreeCap: hubDegreeCap)
        return Dictionary(matches.map { ($0.entity.id, $0.score) }, uniquingKeysWith: max)
    }

    /// Embeds a batch of strings using the on-device / API provider, or the direct Mistral
    /// fallback when no provider is configured.
    private nonisolated func embed(_ texts: [String],
                                   provider: (any EmbeddingProviding)?) async throws -> [EmbeddingData] {
        if let provider {
            return try await StandaloneGeneration
                .runEmbedding(texts, modelProvider: provider, logger: logger.base, priority: true)
        } else {
            return try await StandaloneGeneration
                .runAPIEmbedding(texts, logger: logger.base)
        }
    }
}
