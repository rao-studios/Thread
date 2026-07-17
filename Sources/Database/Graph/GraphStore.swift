//
//  GraphStore.swift
//  database-server
//
//  Created by Ritesh Pakala on 7/16/26.
//

import Foundation
import MLXAccelerate

typealias EntityID = String
typealias RelationshipID = String

/// A node in the knowledge graph. Entities are content-addressed by `(kind, normalized name)`
/// so the same concept mentioned across documents merges into one record. Provenance
/// (`documentIds`) is the inverted index that links the graph back to the vector store.
struct Entity: Codable {
    let id: EntityID
    /// First-seen display casing.
    var name: String
    /// Normalized lowercase type label; defaults to `"concept"`.
    let kind: String
    /// Raw embedding of `"\(kind): \(name)"`. No PQ — entity count ≪ partition count.
    var embedding: [Float]?
    /// Documents this entity was extracted from (entity → docs inverted index).
    var documentIds: Set<DocumentID>
    /// Number of documents that observed this entity.
    var mentionCount: Int
}

/// A directed, typed edge between two entities. Weight increments each time the same
/// triple is observed, so repeatedly-stated relationships rank above one-off mentions.
struct Relationship: Codable {
    let id: RelationshipID
    let subjectId: EntityID
    /// Normalized lowercase verb phrase.
    let predicate: String
    let objectId: EntityID
    /// Reserved for triple verbalization embeddings; nil in v1.
    var embedding: [Float]?
    var documentIds: Set<DocumentID>
    var weight: Int
}

/// A Spanner-Graph-style projection over the corpus: entities and relationships are plain
/// records, and the graph is an in-memory structure with inverted indexes. It is not a
/// separate engine — it shares document IDs with the `PartitionTable` and is persisted as
/// one plist alongside it.
struct GraphStore: Codable {
    var entities: [EntityID: Entity] = [:]
    var relationships: [RelationshipID: Relationship] = [:]
    /// Derived index (entity → incident relationships). NOT persisted — rebuilt from
    /// `relationships` in `init(from:)`, so it can never go stale on disk.
    var adjacency: [EntityID: Set<RelationshipID>] = [:]

    /// Cosine similarity floor for embedding-based entity matching (mirrors the old tag threshold).
    static let entityMatchThreshold: Float = 0.15

    init() {}

    // MARK: - Codable (adjacency omitted, rebuilt on decode)

    enum CodingKeys: String, CodingKey {
        case entities
        case relationships
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entities      = try c.decodeIfPresent([EntityID: Entity].self, forKey: .entities) ?? [:]
        relationships = try c.decodeIfPresent([RelationshipID: Relationship].self, forKey: .relationships) ?? [:]
        rebuildAdjacency()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entities, forKey: .entities)
        try c.encode(relationships, forKey: .relationships)
    }

    mutating func rebuildAdjacency() {
        adjacency = [:]
        for (rid, rel) in relationships {
            adjacency[rel.subjectId, default: []].insert(rid)
            adjacency[rel.objectId, default: []].insert(rid)
        }
    }

    // MARK: - Identity

    static func normalizeName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalizeKind(_ kind: String) -> String {
        let k = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return k.isEmpty ? "concept" : k
    }

    static func entityID(kind: String, name: String) -> EntityID {
        Database.computeNumericHash(from: "\(normalizeKind(kind))|\(normalizeName(name))")
    }

    static func relationshipID(subjectId: EntityID, predicate: String, objectId: EntityID) -> RelationshipID {
        let p = predicate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Database.computeNumericHash(from: "\(subjectId)|\(p)|\(objectId)")
    }

    // MARK: - Upsert

    /// Merges a document's extracted graph into the store and returns the resolved entity IDs
    /// (the document-level provenance the caller stores in `PartitionIndex.entityIds`).
    ///
    /// Merge rule: same `(kind, normalized name)` maps to the same id → union `documentIds`,
    /// increment `mentionCount`, fill a missing embedding but never overwrite an existing one
    /// (input text is deterministic, so re-embedding is a no-op).
    mutating func upsert(_ payload: Database.GraphPayload, documentId: DocumentID) -> [EntityID] {
        var resolvedIds: [EntityID] = []
        var nameToId: [String: EntityID] = [:]   // normalized name → id, for relationship resolution

        for input in payload.entities {
            let trimmed = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let kind = Self.normalizeKind(input.kind)
            let id = Self.entityID(kind: kind, name: trimmed)

            if var existing = entities[id] {
                existing.documentIds.insert(documentId)
                existing.mentionCount += 1
                if existing.embedding == nil, let e = input.embedding { existing.embedding = e }
                entities[id] = existing
            } else {
                entities[id] = Entity(
                    id: id, name: trimmed, kind: kind,
                    embedding: input.embedding,
                    documentIds: [documentId], mentionCount: 1
                )
            }
            nameToId[Self.normalizeName(trimmed)] = id
            if !resolvedIds.contains(id) { resolvedIds.append(id) }
        }

        for rel in payload.relationships {
            let subjectKey = Self.normalizeName(rel.subject)
            let objectKey  = Self.normalizeName(rel.object)
            let predicate  = rel.predicate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !predicate.isEmpty,
                  let subjectId = nameToId[subjectKey] ?? entityIdByName(subjectKey),
                  let objectId  = nameToId[objectKey]  ?? entityIdByName(objectKey),
                  subjectId != objectId else { continue }

            let rid = Self.relationshipID(subjectId: subjectId, predicate: predicate, objectId: objectId)
            if var existing = relationships[rid] {
                existing.documentIds.insert(documentId)
                existing.weight += 1
                relationships[rid] = existing
            } else {
                relationships[rid] = Relationship(
                    id: rid, subjectId: subjectId, predicate: predicate, objectId: objectId,
                    embedding: nil, documentIds: [documentId], weight: 1
                )
            }
            adjacency[subjectId, default: []].insert(rid)
            adjacency[objectId, default: []].insert(rid)
        }

        return resolvedIds
    }

    /// Removes a document's provenance from the given entities and their incident relationships,
    /// garbage-collecting any entity or edge whose provenance becomes empty.
    mutating func detach(documentId: DocumentID, entityIds: [EntityID]) {
        // Collect edges incident to the detached entities and drop this document's provenance.
        var candidateEdges = Set<RelationshipID>()
        for eid in entityIds { candidateEdges.formUnion(adjacency[eid] ?? []) }
        for rid in candidateEdges {
            guard var rel = relationships[rid] else { continue }
            rel.documentIds.remove(documentId)
            rel.weight = max(0, rel.weight - 1)
            if rel.documentIds.isEmpty {
                relationships.removeValue(forKey: rid)
                adjacency[rel.subjectId]?.remove(rid)
                adjacency[rel.objectId]?.remove(rid)
            } else {
                relationships[rid] = rel
            }
        }

        for eid in entityIds {
            guard var entity = entities[eid] else { continue }
            entity.documentIds.remove(documentId)
            entity.mentionCount = max(0, entity.mentionCount - 1)
            if entity.documentIds.isEmpty {
                entities.removeValue(forKey: eid)
                // Drop any remaining incident edges (edges shared with still-live docs are
                // already handled above; this cleans dangling references).
                for rid in adjacency[eid] ?? [] {
                    if let rel = relationships.removeValue(forKey: rid) {
                        adjacency[rel.subjectId]?.remove(rid)
                        adjacency[rel.objectId]?.remove(rid)
                    }
                }
                adjacency.removeValue(forKey: eid)
            } else {
                entities[eid] = entity
            }
        }
    }

    // MARK: - Match

    /// Resolves query terms to entities by name-token containment and/or embedding similarity.
    /// Returns up to `limit` entities, highest score first.
    func matchEntities(nameQuery: String?,
                       embedding: [Float]?,
                       kinds: Set<String>? = nil,
                       limit: Int = 8) -> [(entity: Entity, score: Float)] {
        var best: [EntityID: Float] = [:]

        if let nameQuery {
            let queryTokens = Set(GraphStore.normalizeName(nameQuery)
                .components(separatedBy: " ").filter { !$0.isEmpty })
            if !queryTokens.isEmpty {
                for entity in entities.values {
                    if let kinds, !kinds.contains(entity.kind) { continue }
                    let nameTokens = Set(GraphStore.normalizeName(entity.name)
                        .components(separatedBy: " ").filter { !$0.isEmpty })
                    if !nameTokens.isDisjoint(with: queryTokens) {
                        best[entity.id] = max(best[entity.id] ?? 0, 1.0)
                    }
                }
            }
        }

        if let embedding, !embedding.isEmpty {
            for entity in entities.values {
                if let kinds, !kinds.contains(entity.kind) { continue }
                guard let stored = entity.embedding, stored.count == embedding.count else { continue }
                let score = GraphStore.dot(stored, embedding)
                if score >= GraphStore.entityMatchThreshold {
                    best[entity.id] = max(best[entity.id] ?? 0, score)
                }
            }
        }

        return best.compactMap { id, score -> (entity: Entity, score: Float)? in
            guard let entity = entities[id] else { return nil }
            return (entity: entity, score: score)
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }

    // MARK: - Traversal

    /// Breadth-first expansion from `seeds` up to `hops` edges away.
    /// Returns the reached entities (including seeds) and the traversed relationships.
    func neighborhood(of seeds: Set<EntityID>, hops: Int) -> (entities: Set<EntityID>, relationships: Set<RelationshipID>) {
        var reached = seeds
        var edges = Set<RelationshipID>()
        var frontier = seeds
        var remaining = max(0, hops)
        while remaining > 0, !frontier.isEmpty {
            var next = Set<EntityID>()
            for eid in frontier {
                for rid in adjacency[eid] ?? [] {
                    guard let rel = relationships[rid] else { continue }
                    edges.insert(rid)
                    let other = rel.subjectId == eid ? rel.objectId : rel.subjectId
                    if !reached.contains(other) { next.insert(other) }
                }
            }
            reached.formUnion(next)
            frontier = next
            remaining -= 1
        }
        return (reached, edges)
    }

    /// Union of documents linked to any of the given entities.
    func documents(linkedTo entityIds: Set<EntityID>) -> Set<DocumentID> {
        var docs = Set<DocumentID>()
        for eid in entityIds {
            if let e = entities[eid] { docs.formUnion(e.documentIds) }
        }
        return docs
    }

    // MARK: - Private

    private func entityIdByName(_ normalizedName: String) -> EntityID? {
        entities.values.first { GraphStore.normalizeName($0.name) == normalizedName }?.id
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }
}

extension Database {
    /// The extracted-graph payload for a single document, produced at ingest by an explicit
    /// API contribution and/or LLM extraction, then merged into the `GraphStore`.
    struct GraphPayload: Codable, Sendable {
        struct EntityIn: Codable, Sendable {
            var name: String
            var kind: String
            var embedding: [Float]?
            init(name: String, kind: String = "concept", embedding: [Float]? = nil) {
                self.name = name
                self.kind = kind
                self.embedding = embedding
            }
        }
        struct RelationIn: Codable, Sendable {
            var subject: String
            var predicate: String
            var object: String
        }
        var entities: [EntityIn]
        var relationships: [RelationIn]

        init(entities: [EntityIn] = [], relationships: [RelationIn] = []) {
            self.entities = entities
            self.relationships = relationships
        }

        var isEmpty: Bool { entities.isEmpty && relationships.isEmpty }

        /// The entity display names, used to build the document-level entity embedding string
        /// (the entity analogue of the old `tags.joined(" ")`).
        var entityNames: [String] { entities.map { $0.name } }
    }
}
