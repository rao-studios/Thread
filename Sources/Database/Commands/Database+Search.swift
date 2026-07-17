import Foundation

extension Database {
    nonisolated func search(_ queryData: [EmbeddingData],
                queryEntityEmbedding: [Float]? = nil,
                matchedEntityIds: Set<EntityID> = [],
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
                                          queryEntityEmbedding: queryEntityEmbedding,
                                          matchedEntityIds: matchedEntityIds,
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
                expand: Bool = true,
                topK: Int = 3) async throws -> SearchChatResult {
        guard let query else {
            logger.info("Search", "No query to search.", service: .database, request: request, flow: .chat)
            return SearchChatResult(context: [], adjustments: [], references: [])
        }

        // Effective entity terms: explicit `entities`, falling back to the legacy `tags` alias.
        let requestEntities = request.entities ?? request.tags ?? []
        let queryEmbedding: [EmbeddingData]
        let queryEntityEmbedding: [Float]?

        if requestEntities.isEmpty {
            queryEmbedding = try await embed([query], provider: embeddingModelProvider)
            queryEntityEmbedding = nil
        } else {
            let queryEntityString = requestEntities.sorted().joined(separator: " ")
            let allQueryData = try await embed([query, queryEntityString], provider: embeddingModelProvider)
            queryEmbedding = Array(allQueryData.prefix(1))
            queryEntityEmbedding = allQueryData.dropFirst().first.flatMap {
                if case .floats(let v) = $0.embedding { return v }
                return nil
            }
        }

        // Match query entities against the graph: exact name-token hits plus embedding
        // similarity over the query's content vector.
        let matchedEntityIds: Set<EntityID>
        if let graph = self.graph, !graph.entities.isEmpty {
            let queryVector: [Float]? = queryEmbedding.first.flatMap {
                if case .floats(let v) = $0.embedding { return v }
                return nil
            }
            matchedEntityIds = Set(
                graph.matchEntities(nameQuery: query, embedding: queryVector).map { $0.entity.id }
            )
        } else {
            matchedEntityIds = []
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<SearchResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let r = self.search(queryEmbedding,
                                    queryEntityEmbedding: queryEntityEmbedding,
                                    matchedEntityIds: matchedEntityIds,
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
