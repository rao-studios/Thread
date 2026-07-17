//
//  PartitionIndex.swift
//  database-server
//
//  Created by Ritesh Pakala on 11/15/25.
//

import Foundation
import Logging
import MLXAccelerate

/// Each document creates a PartitionIndex. Multiple partitions are a reflection of
/// the chunking algorithm.
///
/// **Memory layout**
/// Only `pq` (codebooks), `slots` (lean PQ codes + IDs), `entityIds`, and
/// `entityEmbedding` are held in memory and persisted in the table plist.
/// Partition metadata lives in per-document files (`documents/{id}-parts`)
/// and is loaded on demand at content-resolution time.
struct PartitionIndex: Codable {
    var pq: PartitionQuantizer
    /// Lean records for PQ scoring — no content, no raw embedding.
    var slots: [PartitionSlot]
    /// Graph entity IDs this document contributes provenance to (resolved at upsert).
    var entityIds: [EntityID]
    /// Exact embedding of the joined entity names, stored for precise dot-product
    /// distance at search time. Nil when the document has no entities.
    var entityEmbedding: [Float]?

    var metadata: Data?

    /// Cosine similarity floor for the entity pre-filter (generous — coarse pass, not a hard gate).
    static let entitySimilarityThreshold: Float = 0.15

    init() {
        pq              = .init()
        slots           = []
        entityIds       = []
        entityEmbedding = nil
    }

    enum CodingKeys: String, CodingKey {
        case pq
        case slots
        case entityIds       = "entity_ids"
        case entityEmbedding = "entity_embedding"
        case metadata
    }

    // MARK: - Train

    /// Trains the quantizer on hint embeddings and fills `slots`.
    /// Partition metadata is NOT retained in memory — the caller (TableMutator)
    /// persists it to `documents/{id}-parts` before calling this method.
    mutating func train(
        _ partitions: [Database.Partition],
        entityIds: [EntityID] = [],
        entityEmbedding: [Float]? = nil,
        documentId: String,
        logger: TotemLogger
    ) {
        var partitions = partitions
        let embeddingVectors = partitions.map { $0.embedding }

        // train() returns each training vector's codes — no second encode pass.
        let codes = pq.train(vectors: embeddingVectors)

        for i in 0..<partitions.count {
            partitions[i].compressedEmbedding = codes[i]
            partitions[i].embedding = []
        }

        // Populate lean slots — no content retained in-memory.
        self.slots.append(contentsOf: partitions.map {
            PartitionSlot(id: $0.id, documentId: $0.documentId,
                          compressedEmbedding: $0.compressedEmbedding)
        })

        self.entityIds = entityIds
        self.entityEmbedding = entityEmbedding

        logger.info(
            "Index Train",
            "✨ PQ trained — \(partitions.count) partition(s) compressed (docId: \(documentId), total: \(self.slots.count), entities: \(entityIds.count))",
            service: .database,
            flow: .embed(documentId: documentId)
        )
    }

    // MARK: - Entity Distance

    /// Exact dot-product distance between the query embedding and this document's entity embedding.
    /// Returns nil when no entities were indexed for this document (caller should include the document).
    func entityDistance(queryEmbedding: [Float]) -> Float? {
        guard let stored = entityEmbedding,
              stored.count == queryEmbedding.count else { return nil }
        var dot: Float = 0
        vDSP_dotpr(stored, 1, queryEmbedding, 1, &dot, vDSP_Length(stored.count))
        return 1.0 - dot
    }

    // MARK: - Search

    /// Scores all slots with ADC, applies Sinatra, and resolves the top-k results
    /// into full `Database.Partition` objects via `metadataLoader`.
    func search(queryEmbedding: [Float],
                k: Int,
                sinatra: Sinatra,
                sinatraRegistry: SinatraRegistry?,
                documentStats: [DocumentID: Database.DocumentStats] = [:],
                request: DatabaseRequest,
                metadataLoader: PartitionDataLoader? = nil,
                adjustWithSinatra: Bool = true,
                logger: TotemLogger) -> (result: PartitionSearchResult, adjustment: SinatraAdjustment?) {

        let distanceTable = pq.buildDistanceTable(queryVector: queryEmbedding)
        let topK = topKSlotsByDistance(table: distanceTable, k: k)

        let candidates: [(slot: PartitionSlot, distance: Float)]
        let adjustment: SinatraAdjustment?

        if adjustWithSinatra {
            let adjusted: [(slot: PartitionSlot, distance: Float)] = topK.map { result in
                let inference = SinatraInference(
                    partitionId: result.slot.id,
                    documentId:  result.slot.documentId,
                    distance:    result.distance
                )
                let prediction = sinatra.infer(inference, registry: sinatraRegistry,
                                               documentStats: documentStats, request: request)
                return (result.slot, prediction.adjustedDistance)
            }
            candidates = adjusted.sorted { $0.distance < $1.distance }

            let original    = topK.map     { String(format: "%.4f", $0.distance) }
            let inferred    = candidates.map { String(format: "%.4f", $0.distance) }
            let pqThreshold = pq.effectiveThreshold
            let adjById: [String: Float] = Dictionary(
                adjusted.map { ($0.slot.id, $0.distance) },
                uniquingKeysWith: min
            )
            let entries: [SinatraAdjustment.Entry] = topK.map { orig in
                SinatraAdjustment.Entry(
                    partitionId:      orig.slot.id,
                    originalDistance: orig.distance,
                    adjustedDistance: adjById[orig.slot.id] ?? orig.distance,
                    threshold:        pqThreshold
                )
            }
            adjustment = SinatraAdjustment(
                partitionCount:      topK.count,
                original:            original,
                inferred:            inferred,
                pqDistanceThreshold: pqThreshold,
                entries:             entries
            )
        } else {
            candidates = topK
            adjustment = nil
        }

        let threshold       = pq.effectiveThreshold
        let filtered        = candidates.filter { $0.distance < threshold }
        let finalCandidates = filtered.isEmpty ? candidates : filtered

        let scores     = finalCandidates.map { $0.distance }
        let partitions = finalCandidates.map { r in
            r.slot.toPartition(metadata: metadataLoader?(r.slot.documentId, r.slot.id), indexMetadata: self.metadata)
        }

        return (result: (scores, partitions), adjustment: adjustment)
    }

    /// Scores all slots with ADC and returns the top-k with their distances.
    func searchWithScores(queryEmbedding: [Float],
                          k: Int,
                          metadataLoader: PartitionDataLoader? = nil) -> [(Database.Partition, Float)] {
        let distanceTable = pq.buildDistanceTable(queryVector: queryEmbedding)
        return topKSlotsByDistance(table: distanceTable, k: k).map { r in
            (r.slot.toPartition(metadata: metadataLoader?(r.slot.documentId, r.slot.id)), r.distance)
        }
    }

    /// ADC-scores every slot and returns the k nearest, distance-ascending.
    /// Bounded insertion (O(n·log k + k) moves) instead of sorting all n slots —
    /// k is small (search budget) while documents can hold hundreds of slots.
    private func topKSlotsByDistance(table: [[Float]], k: Int) -> [(slot: PartitionSlot, distance: Float)] {
        guard k > 0 else { return [] }
        var best: [(slot: PartitionSlot, distance: Float)] = []
        best.reserveCapacity(min(k, slots.count))

        for slot in slots {
            guard let compressed = slot.compressedEmbedding else { continue }
            let distance = pq.computeDistance(table: table, documentCodes: compressed)
            if best.count == k, distance >= best[best.count - 1].distance { continue }

            // Binary search for the insertion point (distance-ascending).
            var lo = 0, hi = best.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if best[mid].distance < distance { lo = mid + 1 } else { hi = mid }
            }
            best.insert((slot, distance), at: lo)
            if best.count > k { best.removeLast() }
        }
        return best
    }
}
