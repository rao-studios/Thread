import Foundation
import Hummingbird

func registerSearchRoute(
    _ app: some RouterMethods<TotemRequestContext>,
    _ database: Database,
    embeddingModelProvider: any EmbeddingProviding
) {
    app.post("/v1/search") { request, context async throws -> SearchResponse in
        let searchRequest = try await request.decode(as: SearchRequest.self, context: context)
        let searchReqId = "search-\(UUID().uuidString)"

        context.logger.info("Received search request (ID: \(searchReqId)) for model: \(searchRequest.model ?? "Default")")

        let result = try await database.search(
            searchRequest.query,
            request: searchRequest.totem.withRequestID(context.id),
            embeddingModelProvider: embeddingModelProvider,
            expand: searchRequest.expand
        )

        return .init(
            texts: result.context,
            references: result.references,
            graph: buildGraphBlock(from: result.trace, graph: database.graph)
        )
    }
}

/// Resolves a search's graph trace (entity/relationship IDs) into display objects using the
/// current graph snapshot. Returns nil when there is no trace or graph.
func buildGraphBlock(from trace: GraphSearchTrace?, graph: GraphStore?) -> SearchResponseGraph? {
    guard let trace, let graph, !graph.entities.isEmpty else { return nil }

    let entities: [SearchGraphEntity] = trace.matchedEntityIds.compactMap { id in
        guard let e = graph.entities[id] else { return nil }
        return SearchGraphEntity(id: e.id, name: e.name, kind: e.kind)
    }

    let relationships: [SearchGraphRelationship] = trace.expansionEdges.compactMap { rid in
        guard let rel = graph.relationships[rid],
              let subject = graph.entities[rel.subjectId]?.name,
              let object = graph.entities[rel.objectId]?.name else { return nil }
        return SearchGraphRelationship(
            subject: subject, predicate: rel.predicate, object: object, weight: rel.weight
        )
    }

    guard !entities.isEmpty || !relationships.isEmpty || trace.expandedDocumentCount > 0 else { return nil }
    return SearchResponseGraph(
        entities: entities,
        relationships: relationships,
        expandedDocuments: trace.expandedDocumentCount
    )
}
