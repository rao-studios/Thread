//
//  PartitionData.swift
//  database-server
//
//  Created by Ritesh Pakala Rao on 5/7/26.
//

import Foundation

enum MediaType: String, Codable {
    case text
    case image
}

/// Full content and metadata for one partition, stored per-document in
/// `documents/{id}-parts`. Loaded on demand during content resolution after
/// HNSW/PQ scoring — never held in the main indices dict.
struct PartitionData: Codable {
    var id: String
    var url: URL
    var mediaType: MediaType
    var data: String
    var ownerId: String
    /// The partition's full-precision embedding (little-endian fp32), kept only
    /// when the caller supplied it at index time. The table holds PQ codes, which
    /// are enough to rank but not to reproduce the vector; a caller that brought
    /// its own vector can read it back exactly from here. Absent for partitions
    /// Thread embedded itself, so their files are unchanged.
    var embedding: Data?

    enum CodingKeys: String, CodingKey {
        case id, url, ownerId, data, embedding
        case mediaType = "media_type"
    }

    init(
        id: String,
        url: URL,
        mediaType: MediaType,
        data: String,
        ownerId: String
    ) {
        self.id        = id
        self.url       = url
        self.mediaType = mediaType
        self.data      = data
        self.ownerId   = ownerId
    }

    init(from partition: Database.Partition, keepEmbedding: Bool = false) {
        id        = partition.id
        url       = partition.url
        mediaType = partition.mediaType
        data      = partition.text
        ownerId   = partition.ownerId
        embedding = keepEmbedding && !partition.embedding.isEmpty
            ? partition.embedding.withUnsafeBufferPointer { Data(buffer: $0) }
            : nil
    }

    /// The kept embedding as floats, or nil when none was kept.
    var embeddingFloats: [Float]? {
        guard let embedding, embedding.count % MemoryLayout<Float>.size == 0 else { return nil }
        return embedding.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

// MARK: - PartitionDataLoader

/// Resolves a partition's data record by (documentId, partitionId).
/// Provided by `Database` to search paths; nil in admin/debug contexts where data is optional.
typealias PartitionDataLoader = (DocumentID, String) -> PartitionData?
