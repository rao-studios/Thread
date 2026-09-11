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

    enum CodingKeys: String, CodingKey {
        case id, url, ownerId, data
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

    init(from partition: Database.Partition) {
        id        = partition.id
        url       = partition.url
        mediaType = partition.mediaType
        data      = partition.text
        ownerId   = partition.ownerId
    }
}

// MARK: - PartitionDataLoader

/// Resolves a partition's data record by (documentId, partitionId).
/// Provided by `Database` to search paths; nil in admin/debug contexts where data is optional.
typealias PartitionDataLoader = (DocumentID, String) -> PartitionData?
