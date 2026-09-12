import Foundation

// Wire types for the Thread HTTP API.
//
// These mirror the server's request/response structs byte-for-byte. Two traps
// are load-bearing here and easy to undo by accident:
//
//  1. The request wrapper key is "thread". It was "sewn", then "database", and
//     the client was left behind on the middle spelling — which is why search
//     and indexing returned 400. Spelled once, in ThreadScope.
//  2. Only structs that declare CodingKeys on the server are snake_case.
//     Everything else is literal camelCase on the wire. Each type below notes
//     which it is.

// MARK: - Shared

/// The `thread` wrapper carried by /v1/search, /v1/batch/embeddings, /v1/graph
/// and /v1/graph/re-extract. Server: `DatabaseRequest` (snake_case).
struct ThreadScope: Codable {
    var ownerId: String
    var group: WireGroup?
    var groups: [WireGroup]?
    var entities: [String]?
    var tags: [String]?
    var aggregate: Bool?
    var scope: String?

    init(ownerId: String,
         group: WireGroup? = nil,
         groups: [WireGroup]? = nil,
         entities: [String]? = nil,
         tags: [String]? = nil,
         aggregate: Bool? = nil,
         scope: String? = nil) {
        self.ownerId = ownerId
        self.group = group
        self.groups = groups
        self.entities = entities
        self.tags = tags
        self.aggregate = aggregate
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case ownerId = "owner_id"
        case group, groups, entities, tags, aggregate, scope
    }
}

/// Server: `Database.Group` (snake_case). `documents` is absent on request.
struct WireGroup: Codable {
    var id: String
    var label: String
    var ownerId: String
    var documents: [WireDocument]?
    var access: String?
    var totalEarnings: Double?
    var metadata: Metadata?

    struct Metadata: Codable {
        var description: String?
        var tags: [String]?
    }

    init(id: String,
         label: String,
         ownerId: String,
         documents: [WireDocument]? = nil,
         access: String? = nil,
         totalEarnings: Double? = nil,
         metadata: Metadata? = nil) {
        self.id = id
        self.label = label
        self.ownerId = ownerId
        self.documents = documents
        self.access = access
        self.totalEarnings = totalEarnings
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case id, label, documents, access, metadata
        case ownerId = "owner_id"
        case totalEarnings = "total_earnings"
    }
}

/// Server: `Database.Document` (snake_case). `createdAt` arrives as ISO-8601.
struct WireDocument: Codable {
    var id: String
    var url: URL?
    var ownerId: String?
    var name: String?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, url, name
        case ownerId = "owner_id"
        case createdAt = "created_at"
    }
}

// MARK: - Health

/// Server: `HealthResponse`. `timestamp` is a String, not a Date.
struct HealthDTO: Decodable {
    let status: String
    let timestamp: String?
}

// MARK: - Search

/// Server: `SearchRequest` — **no CodingKeys, so every key is literal**.
struct SearchRequestDTO: Encodable {
    var query: String
    var model: String?
    var train: Bool?
    var expand: Bool?
    var thread: ThreadScope
}

/// Server: `SearchResponse`.
struct SearchResponseDTO: Decodable {
    var object: String?
    var texts: [String]
    var references: [WireReference]
    var graph: SearchGraphDTO?
}

/// Server: `Database.DocumentReference` (snake_case).
struct WireReference: Decodable {
    var id: String
    var partitionId: String
    var ownerId: String
    var threadId: String?
    var shardIndex: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case partitionId = "partition_id"
        case ownerId = "owner_id"
        case threadId = "thread_id"
        case shardIndex = "shard_index"
    }
}

/// Server: `SearchResponseGraph`. The nested entity/relationship types have no
/// CodingKeys, so their keys are literal.
struct SearchGraphDTO: Decodable {
    var entities: [Entity]
    var relationships: [Relationship]
    var expandedDocuments: Int

    struct Entity: Decodable {
        var id: String
        var name: String
        var kind: String
    }

    struct Relationship: Decodable {
        var subject: String
        var predicate: String
        var object: String
        var weight: Int
    }

    enum CodingKeys: String, CodingKey {
        case entities, relationships
        case expandedDocuments = "expanded_documents"
    }
}

// MARK: - Indexing

/// `inputs[i]` is a union on the wire: a bare string, or an array of strings.
enum EmbeddingInput: Encodable {
    case string(String)
    case array([String])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        }
    }
}

struct WireEntityInput: Encodable {
    var name: String
    var kind: String?
}

struct WireRelationInput: Encodable {
    var subject: String
    var predicate: String
    var object: String
}

/// Server: `DatabaseUpdate` (snake_case).
struct WireUpdate: Encodable {
    var documentId: String
    var operation: String

    enum CodingKeys: String, CodingKey {
        case documentId = "document_id"
        case operation
    }
}

/// Server: `EmbeddingBatchRequest` (snake_case).
///
/// Every per-document array aligns 1:1 with `inputs` by index.
struct IndexRequestDTO: Encodable {
    var inputs: [EmbeddingInput]
    var sanitize: Bool?
    var names: [String?]?
    var tags: [[String]]?
    var entities: [[WireEntityInput]]?
    var relationships: [[WireRelationInput]]?
    var metadata: [Data?]?
    var mediaType: String?
    var update: WireUpdate?
    var thread: ThreadScope

    enum CodingKeys: String, CodingKey {
        case inputs, sanitize, names, tags, entities, relationships, metadata, update, thread
        case mediaType = "media_type"
    }
}

/// Server: `EmbeddingBatchResponse` — **no CodingKeys**. `usage`'s snake_case
/// keys come from the Swift property names themselves, not a key strategy.
struct IndexResponseDTO: Decodable {
    var object: String?
    var model: String?
    var usage: Usage?
    var success: Bool
    var user: User?

    struct Usage: Decodable {
        var prompt_tokens: Int?
        var total_tokens: Int?
    }

    struct User: Decodable {
        var groups: [WireGroup]?
    }
}

// MARK: - Library

struct LibraryRequestDTO: Encodable {
    var ownerId: String
    var includeAvailable: Bool?

    enum CodingKeys: String, CodingKey {
        case ownerId = "owner_id"
        case includeAvailable = "include_available"
    }
}

struct LibraryDocumentRequestDTO: Encodable {
    var documentId: String

    enum CodingKeys: String, CodingKey {
        case documentId = "document_id"
    }
}

struct LibraryResponseDTO: Decodable {
    var groups: [WireGroup]
}

// MARK: - Graph

/// Server: `GraphRequest`. Leaving both `entity` and `query` nil is browse
/// mode — the server returns top entities by mention count.
struct GraphRequestDTO: Encodable {
    var thread: ThreadScope
    var entity: String?
    var query: String?
    var kinds: [String]?
    var hops: Int?
    var limit: Int?
    var includeDocuments: Bool?

    enum CodingKeys: String, CodingKey {
        case thread, entity, query, kinds, hops, limit
        case includeDocuments = "include_documents"
    }
}

struct GraphResponseDTO: Decodable {
    var object: String?
    var entities: [Entity]
    var relationships: [Relationship]
    var documents: [Document]
    var stats: Stats?

    struct Entity: Decodable {
        var id: String
        var name: String
        var kind: String
        var score: Float
        var mentionCount: Int
        var documentIds: [String]

        enum CodingKeys: String, CodingKey {
            case id, name, kind, score
            case mentionCount = "mention_count"
            case documentIds = "document_ids"
        }
    }

    struct Relationship: Decodable {
        var id: String
        var subjectId: String
        var predicate: String
        var objectId: String
        var weight: Int
        var documentIds: [String]

        enum CodingKeys: String, CodingKey {
            case id, predicate, weight
            case subjectId = "subject_id"
            case objectId = "object_id"
            case documentIds = "document_ids"
        }
    }

    struct Document: Decodable {
        var id: String
        var name: String?
        var ownerId: String?

        enum CodingKeys: String, CodingKey {
            case id, name
            case ownerId = "owner_id"
        }
    }

    struct Stats: Decodable {
        var entityCount: Int
        var relationshipCount: Int

        enum CodingKeys: String, CodingKey {
            case entityCount = "entity_count"
            case relationshipCount = "relationship_count"
        }
    }
}

// MARK: - Graph mutation

/// Server: `GraphEntityMutationRequest` — **no CodingKeys**, keys are literal.
struct GraphEntityMutationDTO: Encodable {
    var id: String
    var name: String?
    var kind: String?
}

/// Server: `GraphMergeRequest` — **no CodingKeys**.
struct GraphMergeDTO: Encodable {
    var from: String
    var into: String
}

/// Server: `GraphRelationshipDeleteRequest` — **no CodingKeys**.
struct GraphRelationshipDeleteDTO: Encodable {
    var id: String
}

/// Server: `GraphReExtractRequest` (snake_case).
struct GraphReExtractDTO: Encodable {
    var documentId: String
    var thread: ThreadScope

    enum CodingKeys: String, CodingKey {
        case documentId = "document_id"
        case thread
    }
}

/// Server: `GraphMutationResponse` (snake_case).
///
/// `survivingId` is the entity id *after* a re-key — rename, merge and set-kind
/// all change the id, so callers must adopt this rather than reusing the id
/// they sent.
struct GraphMutationResponseDTO: Decodable {
    var success: Bool
    var survivingId: String?
    var entityCount: Int?

    enum CodingKeys: String, CodingKey {
        case success
        case survivingId = "surviving_id"
        case entityCount = "entity_count"
    }
}

// MARK: - Extraction policy

/// Server: `ExtractionPolicy` (snake_case) — except `CoMentionRule`, which has
/// no CodingKeys, so `skipExplicitlyLinked` stays camelCase on the wire.
///
/// The server decodes this with the synthesized initializer, so Swift property
/// defaults do NOT apply: every non-optional key must be present on PUT or it
/// 400s with "Coding key `max_entities` not found."
struct ExtractionPolicyDTO: Codable {
    var kinds: [KindDef]
    var promptTemplate: String?
    var predicateAliases: [String: String]
    var maxEntities: Int
    var maxRelationships: Int
    var coMention: CoMentionRule?
    var hubDegreeCap: Int?

    struct KindDef: Codable, Identifiable {
        var name: String
        var description: String
        var id: String { name }
    }

    struct CoMentionRule: Codable {
        var enabled: Bool
        var predicate: String
        var skipExplicitlyLinked: Bool
    }

    enum CodingKeys: String, CodingKey {
        case kinds
        case promptTemplate = "prompt_template"
        case predicateAliases = "predicate_aliases"
        case maxEntities = "max_entities"
        case maxRelationships = "max_relationships"
        case coMention = "co_mention"
        case hubDegreeCap = "hub_degree_cap"
    }
}

// MARK: - Clear

/// Server: `ClearRequest`/`ClearResponse` — **no CodingKeys**.
struct ClearRequestDTO: Encodable {
    var confirm: Bool
}

struct ClearResponseDTO: Decodable {
    var cleared: Bool
    var documents: Int
    var entities: Int
}

// MARK: - Errors

/// Hummingbird's error envelope. Present on 4xx; **absent on 500**, which
/// returns an empty body.
struct WireErrorEnvelope: Decodable {
    struct Inner: Decodable { let message: String }
    let error: Inner
}
