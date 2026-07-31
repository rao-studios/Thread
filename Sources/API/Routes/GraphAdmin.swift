//
//  GraphAdmin.swift
//  database-server
//
//  Granular knowledge-graph editing + extraction-policy management:
//    POST /v1/graph/entity/rename        {id, name}
//    POST /v1/graph/entity/merge         {from, into}
//    POST /v1/graph/entity/delete        {id}
//    POST /v1/graph/entity/set-kind      {id, kind}
//    POST /v1/graph/relationship/delete  {id}
//    POST /v1/graph/re-extract           {document_id, totem: {owner_id}}
//    GET  /v1/graph/policy
//    PUT  /v1/graph/policy               ExtractionPolicy JSON
//

import Foundation
import Hummingbird

// MARK: - Request/response models

struct GraphEntityMutationRequest: Codable {
    let id: String
    let name: String?
    let kind: String?
}

struct GraphMergeRequest: Codable {
    let from: String
    let into: String
}

struct GraphRelationshipDeleteRequest: Codable {
    let id: String
}

struct GraphReExtractRequest: Codable {
    let documentId: String
    let totem: DatabaseRequest

    enum CodingKeys: String, CodingKey {
        case documentId = "document_id"
        case totem
    }
}

struct GraphMutationResponse: Codable, ResponseCodable {
    let success: Bool
    /// The surviving entity id after a re-key (rename/merge/set-kind).
    let survivingId: String?
    /// Entity count after re-extraction.
    let entityCount: Int?

    enum CodingKeys: String, CodingKey {
        case success
        case survivingId = "surviving_id"
        case entityCount = "entity_count"
    }

    init(success: Bool, survivingId: String? = nil, entityCount: Int? = nil) {
        self.success = success
        self.survivingId = survivingId
        self.entityCount = entityCount
    }
}

extension ExtractionPolicy: ResponseCodable {}

// MARK: - Routes

func registerGraphAdminRoutes(
    _ app: some RouterMethods<TotemRequestContext>,
    _ database: Database,
    embeddingModelProvider: any EmbeddingProviding,
    graphExtractor: any GraphExtracting
) {
    app.post("/v1/graph/entity/rename") { request, context async throws -> GraphMutationResponse in
        let body = try await request.decode(as: GraphEntityMutationRequest.self, context: context)
        guard let name = body.name, !name.isEmpty else {
            throw HTTPError(.badRequest, message: "Provide 'name'.")
        }
        let survivingId = await database.renameEntity(id: body.id, newName: name)
        return GraphMutationResponse(success: survivingId != nil, survivingId: survivingId)
    }

    app.post("/v1/graph/entity/merge") { request, context async throws -> GraphMutationResponse in
        let body = try await request.decode(as: GraphMergeRequest.self, context: context)
        let survivingId = await database.mergeEntities(from: body.from, into: body.into)
        return GraphMutationResponse(success: survivingId != nil, survivingId: survivingId)
    }

    app.post("/v1/graph/entity/delete") { request, context async throws -> GraphMutationResponse in
        let body = try await request.decode(as: GraphEntityMutationRequest.self, context: context)
        _ = await database.deleteEntity(id: body.id)
        return GraphMutationResponse(success: true)
    }

    app.post("/v1/graph/entity/set-kind") { request, context async throws -> GraphMutationResponse in
        let body = try await request.decode(as: GraphEntityMutationRequest.self, context: context)
        guard let kind = body.kind, !kind.isEmpty else {
            throw HTTPError(.badRequest, message: "Provide 'kind'.")
        }
        let survivingId = await database.setEntityKind(id: body.id, kind: kind)
        return GraphMutationResponse(success: survivingId != nil, survivingId: survivingId)
    }

    app.post("/v1/graph/relationship/delete") { request, context async throws -> GraphMutationResponse in
        let body = try await request.decode(as: GraphRelationshipDeleteRequest.self, context: context)
        await database.deleteRelationship(id: body.id)
        return GraphMutationResponse(success: true)
    }

    app.post("/v1/graph/re-extract") { request, context async throws -> GraphMutationResponse in
        let body = try await request.decode(as: GraphReExtractRequest.self, context: context)
        let count = await database.reExtract(
            documentId: body.documentId,
            extractor: graphExtractor,
            embedder: embeddingModelProvider,
            request: body.totem.withRequestID(context.id)
        )
        return GraphMutationResponse(success: count != nil, entityCount: count)
    }

    app.get("/v1/graph/policy") { _, _ async throws -> ExtractionPolicy in
        ExtractionPolicyStore.current
    }

    app.put("/v1/graph/policy") { request, context async throws -> ExtractionPolicy in
        let policy = try await request.decode(as: ExtractionPolicy.self, context: context)
        ExtractionPolicyStore.update(policy, logger: database.baseLogger)
        context.logger.info("Extraction policy updated — \(policy.kinds.count) kind(s), coMention=\(policy.coMention?.enabled ?? false)")
        return ExtractionPolicyStore.current
    }
}
