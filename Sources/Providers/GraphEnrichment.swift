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

        return result
    }
}
