//
//  Database+Graph.swift
//  database-server
//
//  Created by Ritesh Pakala on 7/16/26.
//

import Foundation

extension Database {
    /// A knowledge-graph query: resolve seed entities by name and/or embedding similarity,
    /// then traverse up to `hops` edges. Shared by the REST route and the gRPC service.
    struct GraphQuery {
        var entity: String?
        /// Pre-embedded free-text query vector (callers embed the raw query themselves).
        var queryVector: [Float]?
        var kinds: Set<String>?
        /// Traversal depth, clamped to 0–3.
        var hops: Int = 1
        /// Max seed entities matched.
        var limit: Int = 20
        var includeDocuments: Bool = true
    }

    struct GraphQueryResult {
        var entities: [GraphResponseEntity] = []
        var relationships: [GraphResponseRelationship] = []
        var documents: [GraphResponseDocument] = []
        var entityCount: Int = 0
        var relationshipCount: Int = 0
    }

    /// Runs a graph query against the current graph snapshot, access-filtered to the
    /// requesting owner's documents plus publicly available ones.
    nonisolated func graphQuery(_ query: GraphQuery, request: DatabaseRequest) -> GraphQueryResult {
        guard let graph = self.graph, !graph.entities.isEmpty else { return GraphQueryResult() }

        let scoreById: [EntityID: Float]
        let reachedEntities: Set<EntityID>
        let reachedEdges: Set<RelationshipID>

        let browsing = (query.entity?.isEmpty ?? true)
            && (query.queryVector?.isEmpty ?? true)
        if browsing {
            // Browse mode — no seeds given: show the whole graph, kind-filtered
            // and capped by mention count so dense graphs stay renderable.
            let filtered = graph.entities.values.filter { entity in
                guard let kinds = query.kinds, !kinds.isEmpty else { return true }
                return kinds.contains(entity.kind)
            }
            let top = filtered
                .sorted { ($0.mentionCount, $0.name) > ($1.mentionCount, $1.name) }
                .prefix(max(query.limit, 1))
            reachedEntities = Set(top.map(\.id))
            reachedEdges = Set(graph.relationships.values.filter {
                reachedEntities.contains($0.subjectId) && reachedEntities.contains($0.objectId)
            }.map(\.id))
            scoreById = [:]
        } else {
            let matches = graph.matchEntities(
                nameQuery: query.entity, embedding: query.queryVector,
                kinds: query.kinds, limit: query.limit
            )
            scoreById = Dictionary(matches.map { ($0.entity.id, $0.score) }, uniquingKeysWith: max)
            let seeds = Set(matches.map { $0.entity.id })

            let hops = min(max(query.hops, 0), 3)
            (reachedEntities, reachedEdges) = graph.neighborhood(of: seeds, hops: hops)
        }

        // Access filter: owner docs + publicly available docs.
        let ownerKey = TotemRegistry.Owner(id: request.ownerId)
        let accessible: Set<DocumentID> = {
            guard let registry = self.registry else { return [] }
            return registry.availableDocumentIds.union(Set(registry.ownersDocuments[ownerKey] ?? []))
        }()

        let responseEntities: [GraphResponseEntity] = reachedEntities.compactMap { id in
            guard let e = graph.entities[id] else { return nil }
            return GraphResponseEntity(
                id: e.id, name: e.name, kind: e.kind,
                score: scoreById[id] ?? 0,
                mentionCount: e.mentionCount,
                documentIds: Array(e.documentIds.intersection(accessible)).sorted()
            )
        }.sorted { $0.score > $1.score }

        let responseRelationships: [GraphResponseRelationship] = reachedEdges.compactMap { rid in
            guard let rel = graph.relationships[rid] else { return nil }
            return GraphResponseRelationship(
                id: rel.id, subjectId: rel.subjectId, predicate: rel.predicate, objectId: rel.objectId,
                weight: rel.weight,
                documentIds: Array(rel.documentIds.intersection(accessible)).sorted()
            )
        }

        var documents: [GraphResponseDocument] = []
        if query.includeDocuments {
            let docIds = graph.documents(linkedTo: reachedEntities).intersection(accessible)
            documents = docIds.sorted().map { id in
                let doc = self.document(for: id)
                return GraphResponseDocument(id: id, name: doc?.name, ownerId: doc?.ownerId)
            }
        }

        return GraphQueryResult(
            entities: responseEntities,
            relationships: responseRelationships,
            documents: documents,
            entityCount: graph.entities.count,
            relationshipCount: graph.relationships.count
        )
    }
}
