//
//  GraphEnrichment.swift
//  database-server
//
//  Created by Ritesh Pakala on 7/16/26.
//

import Foundation
import Logging

enum GraphEnrichment {
    static func run(items: [Database.BatchPutItem],
                    extractor: (any GraphExtracting)?,
                    embedder: any EmbeddingProviding,
                    existingGraph: GraphStore?,
                    logger: Logger) async -> [Database.BatchPutItem] {
        var result = items
        let policy = ExtractionPolicyStore.current

        if let extractor {
            for i in result.indices where result[i].needsExtraction {
                do {
                    let payload = try await extractor.extract(from: result[i].texts, logger: logger)
                    if !payload.isEmpty {
                        result[i].graph = payload
                        result[i].needsExtraction = false
                    }
                } catch {
                    logger.warning("Graph extraction failed for doc \(result[i].id): \(error) — keeping keyword entities")
                }
            }
        }

        for i in result.indices {
            result[i].graph = applyPolicyEdges(
                to: result[i].graph, policy: policy, existingGraph: existingGraph
            )
        }

        var batchStrings: [String] = []
        var relationshipKeyToIndex: [RelationshipID: Int] = [:]
        var predicateKeyToIndex: [PredicateID: Int] = [:]

        for item in result {
            for relation in item.graph.relationships {
                guard let input = relationshipInput(
                    relation, entities: item.graph.entities, existingGraph: existingGraph
                ) else { continue }
                if relation.embedding == nil,
                   existingGraph?.relationships[input.relationshipID]?.embedding == nil,
                   relationshipKeyToIndex[input.relationshipID] == nil {
                    relationshipKeyToIndex[input.relationshipID] = batchStrings.count
                    batchStrings.append(input.relationshipText)
                }
                if relation.predicateEmbedding == nil,
                   existingGraph?.predicates[input.predicateID]?.embedding == nil,
                   predicateKeyToIndex[input.predicateID] == nil {
                    predicateKeyToIndex[input.predicateID] = batchStrings.count
                    batchStrings.append(GraphStore.predicateEmbedString(input.predicate))
                }
            }
        }

        guard !batchStrings.isEmpty else { return result }

        var relationshipEmbeddings: [RelationshipID: [Float]] = [:]
        var predicateEmbeddings: [PredicateID: [Float]] = [:]
        do {
            let embeds = try await embedder.run(batchStrings, logger: logger, priority: false).result
            let sorted = embeds.sorted { $0.index < $1.index }
            for (key, index) in relationshipKeyToIndex
            where index < sorted.count {
                if case .floats(let vector) = sorted[index].embedding { relationshipEmbeddings[key] = vector }
            }
            for (key, index) in predicateKeyToIndex
            where index < sorted.count {
                if case .floats(let vector) = sorted[index].embedding { predicateEmbeddings[key] = vector }
            }
        } catch {
            logger.warning("Relationship embedding failed: \(error) — graph remains navigable by exact lookup")
            return result
        }

        for i in result.indices {
            for j in result[i].graph.relationships.indices {
                guard let input = relationshipInput(
                    result[i].graph.relationships[j],
                    entities: result[i].graph.entities,
                    existingGraph: existingGraph
                ) else { continue }
                if result[i].graph.relationships[j].embedding == nil {
                    result[i].graph.relationships[j].embedding = relationshipEmbeddings[input.relationshipID]
                        ?? existingGraph?.relationships[input.relationshipID]?.embedding
                }
                if result[i].graph.relationships[j].predicateEmbedding == nil {
                    result[i].graph.relationships[j].predicateEmbedding = predicateEmbeddings[input.predicateID]
                        ?? existingGraph?.predicates[input.predicateID]?.embedding
                }
            }
        }

        return result
    }

    private static func relationshipInput(
        _ relation: Database.GraphPayload.RelationIn,
        entities: [Database.GraphPayload.EntityIn],
        existingGraph: GraphStore?
    ) -> (relationshipID: RelationshipID, predicateID: PredicateID, predicate: String, relationshipText: String)? {
        let subjectName = GraphStore.normalizeName(relation.subject)
        let objectName = GraphStore.normalizeName(relation.object)
        let predicate = relation.predicate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !subjectName.isEmpty, !objectName.isEmpty, !predicate.isEmpty else { return nil }

        func resolve(_ normalizedName: String) -> (name: String, kind: String)? {
            if let entity = entities.first(where: { GraphStore.normalizeName($0.name) == normalizedName }) {
                return (entity.name, entity.kind)
            }
            if let entity = existingGraph?.entities.values.first(where: {
                GraphStore.normalizeName($0.name) == normalizedName
            }) {
                return (entity.name, entity.kind)
            }
            return nil
        }

        let subject = resolve(subjectName)
        let object = resolve(objectName)
        guard let subject, let object else { return nil }

        let subjectId = GraphStore.entityID(kind: subject.kind, name: subject.name)
        let objectId = GraphStore.entityID(kind: object.kind, name: object.name)
        guard subjectId != objectId else { return nil }
        return (
            GraphStore.relationshipID(subjectId: subjectId, predicate: predicate, objectId: objectId),
            GraphStore.predicateID(predicate),
            predicate,
            "\(GraphStore.normalizeKind(subject.kind)): \(subject.name) \(predicate) \(GraphStore.normalizeKind(object.kind)): \(object.name)"
        )
    }

    // MARK: - Policy passes

    /// Applies predicate aliases and (when enabled) co-mention auto-edges: every
    /// pair of entities extracted from the same document gets a weighted
    /// `auto:<predicate>` edge unless already explicitly linked or hub-capped.
    static func applyPolicyEdges(
        to payload: Database.GraphPayload,
        policy: ExtractionPolicy,
        existingGraph: GraphStore?
    ) -> Database.GraphPayload {
        var payload = payload

        // Predicate normalization (skip already-namespaced auto edges).
        if !policy.predicateAliases.isEmpty {
            for i in payload.relationships.indices
            where !payload.relationships[i].predicate.hasPrefix(ExtractionPolicy.autoPredicatePrefix) {
                payload.relationships[i].predicate =
                    policy.normalizePredicate(payload.relationships[i].predicate)
            }
        }

        guard let rule = policy.coMention, rule.enabled, payload.entities.count > 1 else {
            return payload
        }

        let autoPredicate = ExtractionPolicy.autoPredicatePrefix + rule.predicate
        let explicitPairs: Set<String> = Set(payload.relationships.map { rel in
            [GraphStore.normalizeName(rel.subject), GraphStore.normalizeName(rel.object)]
                .sorted().joined(separator: "|")
        })

        func degree(_ entity: Database.GraphPayload.EntityIn) -> Int {
            guard let graph = existingGraph else { return 0 }
            let id = GraphStore.entityID(kind: entity.kind, name: entity.name)
            return graph.adjacency[id]?.count ?? 0
        }

        let cap = policy.hubDegreeCap ?? Int.max
        for a in 0..<(payload.entities.count - 1) {
            for b in (a + 1)..<payload.entities.count {
                let first = payload.entities[a]
                let second = payload.entities[b]
                let pairKey = [GraphStore.normalizeName(first.name), GraphStore.normalizeName(second.name)]
                    .sorted().joined(separator: "|")
                if rule.skipExplicitlyLinked, explicitPairs.contains(pairKey) { continue }
                if degree(first) >= cap || degree(second) >= cap { continue }
                payload.relationships.append(.init(
                    subject: first.name, predicate: autoPredicate, object: second.name
                ))
            }
        }
        return payload
    }

}
