//
//  GraphEnrichment.swift
//  database-server
//
//  Created by Ritesh Pakala on 7/16/26.
//

import Foundation
import Logging

/// Runs in the detached indexing task, off the request's critical path. It (1) replaces
/// keyword-placeholder graphs with LLM-extracted ones, (2) embeds every entity that is new to
/// the graph in a single batch, and (3) refreshes the document-level entity embedding for docs
/// whose entity set changed. Request latency is unaffected because ingest already ran detached.
enum GraphEnrichment {
    /// Embedding string for a single entity — must match `GraphStore`'s `embed("\(kind): \(name)")`.
    static func entityEmbedString(kind: String, name: String) -> String { "\(kind): \(name)" }

    static func run(items: [Database.BatchPutItem],
                    extractor: (any GraphExtracting)?,
                    embedder: any EmbeddingProviding,
                    existingGraph: GraphStore?,
                    logger: Logger) async -> [Database.BatchPutItem] {
        var result = items
        let policy = ExtractionPolicyStore.current

        // ── 1. LLM extraction for flagged items ──────────────────────────────────
        var extractedDocIndices = Set<Int>()
        if let extractor {
            for i in result.indices where result[i].needsExtraction {
                do {
                    let payload = try await extractor.extract(from: result[i].texts, logger: logger)
                    if !payload.isEmpty {
                        result[i].graph = payload
                        result[i].needsExtraction = false
                        extractedDocIndices.insert(i)
                    }
                } catch {
                    logger.warning("Graph extraction failed for doc \(result[i].id): \(error) — keeping keyword entities")
                }
            }
        }

        // ── 1b. Policy passes: predicate aliases + co-mention auto-edges ─────────
        for i in result.indices {
            result[i].graph = applyPolicyEdges(
                to: result[i].graph, policy: policy, existingGraph: existingGraph
            )
        }

        // ── 2. Batch-embed new entity strings + doc-level strings for extracted docs ──
        var batchStrings: [String] = []
        var entityKeyToIdx: [String: Int] = [:]     // "kind: name" → batch index
        var docIdxToBatchIdx: [Int: Int] = [:]      // extracted doc index → batch index

        func enqueueEntity(kind: String, name: String) {
            let key = entityEmbedString(kind: kind, name: name)
            guard entityKeyToIdx[key] == nil else { return }
            let id = GraphStore.entityID(kind: kind, name: name)
            if existingGraph?.entities[id]?.embedding != nil { return }   // already embedded
            entityKeyToIdx[key] = batchStrings.count
            batchStrings.append(key)
        }

        for item in result {
            for e in item.graph.entities { enqueueEntity(kind: e.kind, name: e.name) }
        }
        for i in extractedDocIndices {
            docIdxToBatchIdx[i] = batchStrings.count
            batchStrings.append(result[i].graph.entityNames.joined(separator: " "))
        }

        guard !batchStrings.isEmpty else { return result }

        var embeddingByKey: [String: [Float]] = [:]
        var embeddingByBatchIdx: [Int: [Float]] = [:]
        do {
            let embeds = try await embedder.run(batchStrings, logger: logger, priority: false).result
            let sorted = embeds.sorted { $0.index < $1.index }
            for (key, idx) in entityKeyToIdx {
                if idx < sorted.count, case .floats(let v) = sorted[idx].embedding { embeddingByKey[key] = v }
            }
            for (_, batchIdx) in docIdxToBatchIdx {
                if batchIdx < sorted.count, case .floats(let v) = sorted[batchIdx].embedding {
                    embeddingByBatchIdx[batchIdx] = v
                }
            }
        } catch {
            logger.warning("Entity embedding failed: \(error) — entities indexed without embeddings")
            return result
        }

        // ── 3. Attach entity embeddings + refresh doc-level embeddings ────────────
        for i in result.indices {
            var entities = result[i].graph.entities
            for j in entities.indices where entities[j].embedding == nil {
                let key = entityEmbedString(kind: entities[j].kind, name: entities[j].name)
                entities[j].embedding = embeddingByKey[key]
                    ?? existingGraph?.entities[GraphStore.entityID(kind: entities[j].kind, name: entities[j].name)]?.embedding
            }
            result[i].graph.entities = entities
            if let batchIdx = docIdxToBatchIdx[i], let v = embeddingByBatchIdx[batchIdx] {
                result[i].entityEmbedding = v
            }
        }

        // ── 4. Similarity auto-edges (needs the fresh embeddings from step 3) ────
        if let rule = policy.similarity, rule.enabled, let existingGraph {
            for i in result.indices {
                result[i].graph = addSimilarityEdges(
                    to: result[i].graph, rule: rule,
                    hubCap: policy.hubDegreeCap, existingGraph: existingGraph
                )
            }
        }

        return result
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

    /// Bridges a document's new entities to semantically-close existing entities
    /// (`auto:related to`) using cosine over the "kind: name" embeddings.
    static func addSimilarityEdges(
        to payload: Database.GraphPayload,
        rule: ExtractionPolicy.SimilarityRule,
        hubCap: Int?,
        existingGraph: GraphStore
    ) -> Database.GraphPayload {
        var payload = payload
        let autoPredicate = ExtractionPolicy.autoPredicatePrefix + rule.predicate
        let cap = hubCap ?? Int.max

        for entity in payload.entities {
            guard let embedding = entity.embedding else { continue }
            let selfId = GraphStore.entityID(kind: entity.kind, name: entity.name)
            if (existingGraph.adjacency[selfId]?.count ?? 0) >= cap { continue }

            var scored: [(name: String, score: Float)] = []
            for existing in existingGraph.entities.values {
                guard existing.id != selfId,
                      let stored = existing.embedding,
                      stored.count == embedding.count,
                      (existingGraph.adjacency[existing.id]?.count ?? 0) < cap else { continue }
                let score = GraphStore.dot(stored, embedding)
                if score >= rule.cosineThreshold {
                    scored.append((existing.name, score))
                }
            }
            for match in scored.sorted(by: { $0.score > $1.score }).prefix(rule.maxEdgesPerEntity) {
                payload.relationships.append(.init(
                    subject: entity.name, predicate: autoPredicate, object: match.name
                ))
            }
        }
        return payload
    }
}
