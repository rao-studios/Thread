//
//  Database.Partition.swift
//  database-server
//
//  Created by Ritesh Pakala Rao on 1/5/26.
//

import Foundation

/// Database Partitions, they are basically chunks of a document. That
/// are stored in an index in relation to a document for searching.
extension Database {
    struct Partition: Codable {
        let id: String
        let documentId: String
        // Document URL.
        var url: URL
        var embedding: [Float]
        var compressedEmbedding: [UInt16]? = nil
        var mediaType: MediaType = .text
        var text: String

        // Ties with Gita owners on-chain.
        var ownerId: String
        /// Opaque payload attached at index time; returned verbatim in search/chat results.
        var metadata: Data?

        enum CodingKeys: String, CodingKey {
            case id
            case documentId = "document_id"
            case url
            case embedding
            case compressedEmbedding = "compressed_embedding"
            case mediaType = "media_type"
            case text
            case ownerId = "owner_id"
            case metadata
        }

        init(
            id: String,
            documentId: String,
            url: URL,
            embedding: [Float],
            compressedEmbedding: [UInt16]? = nil,
            mediaType: MediaType = .text,
            text: String,
            ownerId: String,
            metadata: Data? = nil
        ) {
            self.id                  = id
            self.documentId          = documentId
            self.url                 = url
            self.embedding           = embedding
            self.compressedEmbedding = compressedEmbedding
            self.mediaType           = mediaType
            self.text                = text
            self.ownerId             = ownerId.lowercased()
            self.metadata            = metadata
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id                  = try c.decode(String.self, forKey: .id)
            documentId          = try c.decode(String.self, forKey: .documentId)
            url                 = try c.decode(URL.self, forKey: .url)
            embedding           = try c.decode([Float].self, forKey: .embedding)
            compressedEmbedding = try c.decodeIfPresent([UInt16].self, forKey: .compressedEmbedding)
            mediaType           = try c.decodeIfPresent(MediaType.self, forKey: .mediaType) ?? .text
            text                = try c.decode(String.self, forKey: .text)
            ownerId             = (try c.decode(String.self, forKey: .ownerId)).lowercased()
            metadata            = try c.decodeIfPresent(Data.self, forKey: .metadata)
        }
    }
}
