//
//  PartitionSlot.swift
//  database-server
//
//  Created by Ritesh Pakala Rao on 5/5/26.
//

import Foundation

/// Lean in-memory record for PQ scoring — compressed codes and IDs only, no content.
/// Replaces the full `Database.Partition` inside `PartitionIndex.slots` so the in-memory
/// indices dict stays small and CoW copies during `putBatch` are cheap.
struct PartitionSlot: Codable {
    var id: String
    var documentId: String
    var compressedEmbedding: [UInt16]?

    /// Reconstruct a full `Database.Partition` from this slot and the on-disk metadata record.
    /// When `metadata` is nil (e.g. HNSW rebuild), content fields are empty and url defaults
    /// to a blank path — callers that only need id/documentId/embedding are unaffected.
    func toPartition(metadata: PartitionData?, indexMetadata: Data? = nil) -> Database.Partition {
        Database.Partition(
            id: id,
            documentId: documentId,
            url: metadata?.url ?? URL(fileURLWithPath: ""),
            embedding: [],
            compressedEmbedding: compressedEmbedding,
            mediaType: metadata?.mediaType ?? .text,
            text: metadata?.data ?? "",
            ownerId: metadata?.ownerId ?? "",
            metadata: indexMetadata
        )
    }
}
