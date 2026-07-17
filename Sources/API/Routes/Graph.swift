import Foundation
import Hummingbird

func registerGraphRoute(
    _ app: some RouterMethods<TotemRequestContext>,
    _ database: Database,
    embeddingModelProvider: any EmbeddingProviding
) {
    app.post("/v1/graph") { request, context async throws -> GraphResponse in
        let graphReq = try await request.decode(as: GraphRequest.self, context: context)
        let databaseReq = graphReq.totem.withRequestID(context.id)

        guard graphReq.entity != nil || graphReq.query != nil else {
            throw HTTPError(.badRequest, message: "Provide 'entity' and/or 'query'.")
        }

        // Embed the free-text query for entity similarity matching.
        var queryVector: [Float]?
        if let query = graphReq.query {
            let embeds = try await StandaloneGeneration.runEmbedding(
                [query], modelProvider: embeddingModelProvider, logger: database.logger.base, priority: true
            )
            if case .floats(let v) = embeds.first?.embedding { queryVector = v }
        }

        let result = database.graphQuery(
            Database.GraphQuery(
                entity: graphReq.entity,
                queryVector: queryVector,
                kinds: graphReq.kinds.map { Set($0.map { GraphStore.normalizeKind($0) }) },
                hops: graphReq.hops ?? 1,
                limit: graphReq.limit ?? 20,
                includeDocuments: graphReq.includeDocuments ?? true
            ),
            request: databaseReq
        )

        return GraphResponse(
            entities: result.entities,
            relationships: result.relationships,
            documents: result.documents,
            stats: GraphResponseStats(
                entityCount: result.entityCount,
                relationshipCount: result.relationshipCount
            )
        )
    }
}
