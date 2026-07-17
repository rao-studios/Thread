import Conduit
import Foundation
import GRPCCore
import GRPCProtobuf
import Logging

final class TotemGraphServiceImpl: Totem_V1_TotemGraph.SimpleServiceProtocol, Sendable {
    let database: Database
    let embeddingProvider: any EmbeddingProviding

    init(database: Database, embeddingProvider: any EmbeddingProviding) {
        self.database = database
        self.embeddingProvider = embeddingProvider
    }

    func query(
        request: Totem_V1_TotemGraphQueryRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemGraphQueryResponse {
        let databaseReq = DatabaseRequest(ownerId: request.ownerID)

        // Embed the free-text query for entity similarity matching (Totem embeds server-side).
        var queryVector: [Float]?
        if !request.query.isEmpty {
            let (embeds, _) = try await embeddingProvider.run(
                [request.query], logger: database.baseLogger, priority: true
            )
            if case .floats(let v) = embeds.first?.embedding { queryVector = v }
        }

        await database.initializationTask.value

        let result = database.graphQuery(
            Database.GraphQuery(
                entity: request.entity.isEmpty ? nil : request.entity,
                queryVector: queryVector,
                kinds: request.kinds.isEmpty ? nil : Set(request.kinds.map { GraphStore.normalizeKind($0) }),
                hops: request.hops == 0 ? 1 : Int(request.hops),
                limit: request.limit == 0 ? 20 : Int(request.limit),
                includeDocuments: request.includeDocuments
            ),
            request: databaseReq
        )

        var response = Totem_V1_TotemGraphQueryResponse()
        response.entities = result.entities.map { e in
            var out = Totem_V1_TotemGraphEntity()
            out.id = e.id
            out.name = e.name
            out.kind = e.kind
            out.score = e.score
            out.mentionCount = Int32(e.mentionCount)
            out.documentIds = e.documentIds
            return out
        }
        response.relationships = result.relationships.map { r in
            var out = Totem_V1_TotemGraphRelationship()
            out.id = r.id
            out.subjectID = r.subjectId
            out.predicate = r.predicate
            out.objectID = r.objectId
            out.weight = Int32(r.weight)
            out.documentIds = r.documentIds
            return out
        }
        response.documents = result.documents.map { d in
            var out = Totem_V1_TotemGraphDocument()
            out.id = d.id
            out.name = d.name ?? ""
            out.ownerID = d.ownerId ?? ""
            return out
        }
        var stats = Totem_V1_TotemGraphStats()
        stats.entityCount = Int64(result.entityCount)
        stats.relationshipCount = Int64(result.relationshipCount)
        response.stats = stats
        return response
    }
}
