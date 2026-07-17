//
//  EmbeddingRequest.swift
//  database-server
//
//  Created by Ritesh Pakala on 10/26/25.
//  Based on: https://github.com/mzbac/swift-mlx-server

import Foundation

/// A caller-supplied entity for a document at ingest time. `kind` defaults to `"concept"`.
struct GraphEntityInput: Codable {
    let name: String
    let kind: String?
}

/// A caller-supplied relationship. `subject`/`object` reference entity names in the same document.
struct GraphRelationInput: Codable {
    let subject: String
    let predicate: String
    let object: String
}

struct EmbeddingRequest: Codable {
    let input: EmbeddingInput
    let model: String?
    let encodingFormat: String?
    let dimensions: Int?
    let user: String?
    let batchSize: Int?
    let sanitize: Bool?
    let update: DatabaseUpdate?
    let totem: DatabaseRequest
    let tags: [String]?
    let mediaType: MediaType?
    let metadata: Data?

    enum CodingKeys: String, CodingKey {
        case input
        case model
        case encodingFormat = "encoding_format"
        case dimensions
        case user
        case batchSize = "batch_size"
        case sanitize
        case update
        case totem
        case tags
        case mediaType = "media_type"
        case metadata
    }
}

struct EmbeddingBatchRequest: Codable {
    let inputs: [EmbeddingInput]
    let model: String?
    let encodingFormat: String?
    let dimensions: Int?
    let user: String?
    let batchSize: Int?
    let sanitize: Bool?
    let update: DatabaseUpdate?
    let totem: DatabaseRequest
    /// Per-document entities; outer index aligns 1:1 with `inputs`.
    let entities: [[GraphEntityInput]]?
    /// Per-document relationships; outer index aligns 1:1 with `inputs`.
    let relationships: [[GraphRelationInput]]?
    /// Legacy per-document tags; outer index aligns 1:1 with `inputs`. Mapped to `concept` entities.
    let tags: [[String]]?
    let mediaType: MediaType?
    /// Per-document metadata payloads; outer index aligns 1:1 with `inputs`.
    let metadata: [Data?]?
    /// Per-document original filenames; outer index aligns 1:1 with `inputs`.
    let names: [String?]?

    enum CodingKeys: String, CodingKey {
        case inputs
        case model
        case encodingFormat = "encoding_format"
        case dimensions
        case user
        case batchSize = "batch_size"
        case sanitize
        case update
        case totem
        case entities
        case relationships
        case tags
        case mediaType = "media_type"
        case metadata
        case names
    }
}

enum EmbeddingInput: Codable {
    case string(String)
    case array([String])

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let arr = try? container.decode([String].self) {
            self = .array(arr)
        } else {
            throw DecodingError.typeMismatch(
                EmbeddingInput.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "Expected String or [String]"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str):
            try container.encode(str)
        case .array(let arr):
            try container.encode(arr)
        }
    }

    var values: [String] {
        switch self {
        case .string(let str): return [str]
        case .array(let arr): return arr
        }
    }
}
