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
typealias PredicateID = String

struct Entity: Codable {
    let id: EntityID
    var name: String
    let kind: String
    var documentIds: Set<DocumentID>
    var mentionCount: Int
}

struct Relationship: Codable {
    let id: RelationshipID
    let subjectId: EntityID
    let predicate: String
    let objectId: EntityID
    /// The semantic vector for the complete subject → predicate → object assertion.
    var embedding: [Float]?
    var documentIds: Set<DocumentID>
    var weight: Int
}

struct Predicate: Codable {
    let id: PredicateID
    var name: String
    /// The vector for the relation type independent of a particular pair of entities.
    var embedding: [Float]?
    var relationshipCount: Int
}

struct GraphStore: Codable {
    var entities: [EntityID: Entity] = [:]
    var relationships: [RelationshipID: Relationship] = [:]
    var predicates: [PredicateID: Predicate] = [:]
    var adjacency: [EntityID: Set<RelationshipID>] = [:]
    var predicateAdjacency: [PredicateID: Set<RelationshipID>] = [:]

    static let relationshipMatchThreshold: Float = 0.15
    static let predicateMatchThreshold: Float = 0.15
    static let predicateScoreWeight: Float = 0.8

    init() {}

    // MARK: - Codable (adjacency omitted, rebuilt on decode)

    enum CodingKeys: String, CodingKey {
        case entities
        case relationships
        case predicates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entities      = try c.decodeIfPresent([EntityID: Entity].self, forKey: .entities) ?? [:]
        relationships = try c.decodeIfPresent([RelationshipID: Relationship].self, forKey: .relationships) ?? [:]
        predicates    = try c.decodeIfPresent([PredicateID: Predicate].self, forKey: .predicates) ?? [:]
        rebuildIndexes()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entities, forKey: .entities)
        try c.encode(relationships, forKey: .relationships)
        try c.encode(predicates, forKey: .predicates)
    }

    mutating func rebuildIndexes() {
        adjacency = [:]
        predicateAdjacency = [:]
        var predicateCounts: [PredicateID: Int] = [:]
        for (rid, rel) in relationships {
            adjacency[rel.subjectId, default: []].insert(rid)
            adjacency[rel.objectId, default: []].insert(rid)
            let predicateId = Self.predicateID(rel.predicate)
            predicateAdjacency[predicateId, default: []].insert(rid)
            predicateCounts[predicateId, default: 0] += rel.weight
            if predicates[predicateId] == nil {
                predicates[predicateId] = Predicate(
                    id: predicateId, name: rel.predicate, embedding: nil, relationshipCount: 0
                )
            }
        }
        predicates = predicates.compactMapValues { predicate in
            guard let count = predicateCounts[predicate.id], count > 0 else { return nil }
            var updated = predicate
            updated.relationshipCount = count
            return updated
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

    static func predicateID(_ predicate: String) -> PredicateID {
        Database.computeNumericHash(from: predicate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func predicateEmbedString(_ predicate: String) -> String {
        "Relationship predicate: \(predicate)"
    }

    // MARK: - Upsert

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
                entities[id] = existing
            } else {
                entities[id] = Entity(
                    id: id, name: trimmed, kind: kind, documentIds: [documentId], mentionCount: 1
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
                if existing.embedding == nil { existing.embedding = rel.embedding }
                relationships[rid] = existing
            } else {
                relationships[rid] = Relationship(
                    id: rid, subjectId: subjectId, predicate: predicate, objectId: objectId,
                    embedding: rel.embedding, documentIds: [documentId], weight: 1
                )
            }
            adjacency[subjectId, default: []].insert(rid)
            adjacency[objectId, default: []].insert(rid)

            let predicateId = Self.predicateID(predicate)
            if var existing = predicates[predicateId] {
                existing.relationshipCount += 1
                if existing.embedding == nil { existing.embedding = rel.predicateEmbedding }
                predicates[predicateId] = existing
            } else {
                predicates[predicateId] = Predicate(
                    id: predicateId, name: predicate, embedding: rel.predicateEmbedding, relationshipCount: 1
                )
            }
            predicateAdjacency[predicateId, default: []].insert(rid)
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
        rebuildIndexes()
    }

    // MARK: - Match

    func matchEntities(nameQuery: String?,
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

        return best.compactMap { id, score -> (entity: Entity, score: Float)? in
            guard let entity = entities[id] else { return nil }
            return (entity: entity, score: score)
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }

    func matchRelationships(embedding: [Float],
                            seededBy entityIds: Set<EntityID> = [],
                            limit: Int = 12)
        -> [(relationship: Relationship, score: Float, predicateId: PredicateID)] {
        guard !embedding.isEmpty else { return [] }

        var predicateScores: [PredicateID: Float] = [:]
        for predicate in predicates.values {
            guard let stored = predicate.embedding, stored.count == embedding.count else { continue }
            let score = Self.dot(stored, embedding)
            if score >= Self.predicateMatchThreshold { predicateScores[predicate.id] = score }
        }

        var matches: [(relationship: Relationship, score: Float, predicateId: PredicateID)] = []
        for relationship in relationships.values {
            let predicateId = Self.predicateID(relationship.predicate)
            let relationshipScore: Float
            if let stored = relationship.embedding, stored.count == embedding.count {
                relationshipScore = Self.dot(stored, embedding)
            } else {
                relationshipScore = -.infinity
            }
            let predicateScore = (predicateScores[predicateId] ?? -.infinity) * Self.predicateScoreWeight
            var score = max(relationshipScore, predicateScore)
            if entityIds.contains(relationship.subjectId) || entityIds.contains(relationship.objectId) {
                score = max(score, Self.relationshipMatchThreshold)
            }
            guard score >= Self.relationshipMatchThreshold else { continue }
            matches.append((relationship, score, predicateId))
        }
        return matches
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.relationship.weight > rhs.relationship.weight : lhs.score > rhs.score
            }
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
    func documents(linkedToEntities entityIds: Set<EntityID>) -> Set<DocumentID> {
        var docs = Set<DocumentID>()
        for eid in entityIds {
            if let e = entities[eid] { docs.formUnion(e.documentIds) }
        }
        return docs
    }

    func documents(linkedToRelationships relationshipIds: Set<RelationshipID>) -> Set<DocumentID> {
        relationshipIds.reduce(into: Set<DocumentID>()) { result, id in
            result.formUnion(relationships[id]?.documentIds ?? [])
        }
    }

    func endpointIds(for relationshipIds: Set<RelationshipID>) -> Set<EntityID> {
        relationshipIds.reduce(into: Set<EntityID>()) { result, id in
            guard let relationship = relationships[id] else { return }
            result.insert(relationship.subjectId)
            result.insert(relationship.objectId)
        }
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
            init(name: String, kind: String = "concept") {
                self.name = name
                self.kind = kind
            }
        }
        struct RelationIn: Codable, Sendable {
            var subject: String
            var predicate: String
            var object: String
            var embedding: [Float]?
            var predicateEmbedding: [Float]?

            init(subject: String,
                 predicate: String,
                 object: String,
                 embedding: [Float]? = nil,
                 predicateEmbedding: [Float]? = nil) {
                self.subject = subject
                self.predicate = predicate
                self.object = object
                self.embedding = embedding
                self.predicateEmbedding = predicateEmbedding
            }
        }
        var entities: [EntityIn]
        var relationships: [RelationIn]

        init(entities: [EntityIn] = [], relationships: [RelationIn] = []) {
            self.entities = entities
            self.relationships = relationships
        }

        var isEmpty: Bool { entities.isEmpty && relationships.isEmpty }

    }
}
