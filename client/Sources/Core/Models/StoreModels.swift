import Foundation

// Mirrors of the server's on-disk state.
//
// These types are `internal` to a single executable target on the server, so
// they cannot be imported and have to be redeclared. Two rules keep that
// manageable:
//
//  1. **Decode subsets.** `Decodable` ignores unknown keys, so each struct
//     declares only the fields the client actually shows. `PartitionIndex`
//     omits the PQ codebooks entirely — they are the bulk of the file.
//  2. **Match the server's key spelling exactly.** Only some of these types
//     declare CodingKeys server-side; the rest key off raw Swift property
//     names. Verified against real plists, noted per type below.
//
// Everything here is read-only. The server owns this state in memory and
// flushes on a ~1s debounce; a client write would be overwritten at best and
// corrupt the node at worst.

// MARK: - Registry

/// Server: `ThreadRegistry` — **no CodingKeys**, so keys are raw property names.
///
/// `ownersDocuments` and `ownersGroups` are deliberately omitted: they are
/// keyed by a struct (`Owner`), which Swift encodes as a flat alternating
/// key/value array rather than a dictionary. Owners are derived from
/// `documentOwners` and `groupOwners` instead, which are plain string-keyed.
struct StoreRegistry: Decodable {
    var documentOwners: [String: [OwnerRef]] = [:]
    var documentGroups: [String: [String]] = [:]
    var ownerDocumentGroup: [String: [String: String]] = [:]
    var groupOwners: [String: OwnerRef] = [:]
    var groups: [String: [String]] = [:]
    var documentAccess: [String: String] = [:]
    var groupAccess: [String: String] = [:]
    var availableDocumentIds: [String] = []
    var availableGroupIds: [String] = []
    var documentStats: [String: StoreDocumentStats] = [:]

    struct OwnerRef: Decodable, Hashable {
        let id: String
    }

    var documentIds: [String] {
        Array(Set(documentOwners.keys).union(documentAccess.keys)).sorted()
    }

    var owners: [String] {
        var set = Set(documentOwners.values.flatMap { $0 }.map(\.id))
        set.formUnion(groupOwners.values.map(\.id))
        set.formUnion(ownerDocumentGroup.keys)
        return set.sorted()
    }

    func access(forDocument id: String) -> String {
        documentAccess[id] ?? "unknown"
    }

    func owners(forDocument id: String) -> [String] {
        (documentOwners[id] ?? []).map(\.id).sorted()
    }
}

/// Server: `Database.DocumentStats` — **snake_case CodingKeys**.
///
/// Retrieval counts and sentiment are exposed nowhere over HTTP or gRPC, so
/// this is the only way to see them.
struct StoreDocumentStats: Decodable {
    var id: String?
    var totalEarned: Double?
    var retrievalCount: Int?
    var sentimentSum: Double?
    var lastRetrieved: Date?
    var partitionRetrievalCount: [String: Int]?
    var partitionSentiments: [String: PartitionSentiment]?

    struct PartitionSentiment: Decodable {
        var retrievalCount: Int?
        var sentimentSum: Double?
        var lastRetrieved: Date?

        enum CodingKeys: String, CodingKey {
            case retrievalCount = "retrieval_count"
            case sentimentSum = "sentiment_sum"
            case lastRetrieved = "last_retrieved"
        }
    }

    /// The server computes this rather than storing it: 0.5 when never retrieved.
    var averageSentiment: Double {
        let count = retrievalCount ?? 0
        guard count > 0, let sum = sentimentSum else { return 0.5 }
        return sum / Double(count)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case totalEarned = "total_earned"
        case retrievalCount = "retrieval_count"
        case sentimentSum = "sentiment_sum"
        case lastRetrieved = "last_retrieved"
        case partitionRetrievalCount = "partition_retrieval_count"
        case partitionSentiments = "partition_sentiments"
    }
}

// MARK: - Graph

/// Server: `GraphStore` — **no CodingKeys**. `adjacency` and
/// `predicateAdjacency` are rebuilt on decode server-side and never persisted,
/// so they are absent from the file.
///
/// Unlike `/v1/graph`, this is the *whole* graph — browse mode caps at `limit`.
struct StoreGraph: Decodable {
    var entities: [String: Entity] = [:]
    var relationships: [String: Relationship] = [:]
    var predicates: [String: Predicate] = [:]

    /// Server: `GraphStore.Entity` — no CodingKeys.
    struct Entity: Decodable {
        var id: String
        var name: String
        var kind: String
        var documentIds: [String]?
        var mentionCount: Int?
    }

    /// Server: `GraphStore.Relationship` — no CodingKeys. `embedding` is
    /// omitted here; it is a 1024-float vector per edge and nothing displays it.
    struct Relationship: Decodable {
        var id: String
        var subjectId: String
        var predicate: String
        var objectId: String
        var documentIds: [String]?
        var weight: Int?
    }

    /// Server: `GraphStore.Predicate`. Predicates are first-class state with
    /// their own embeddings and counts, but no HTTP response exposes them.
    struct Predicate: Decodable {
        var id: String
        var name: String
        var relationshipCount: Int?
    }
}

// MARK: - Partition table

/// Server: `PartitionTable` — no CodingKeys.
struct StoreTable: Decodable {
    var keys: [String] = []
    var indices: [String: Index] = [:]

    /// Server: `PartitionIndex`. `entity_ids` is snake_case; `pq` and `slots`
    /// are literal. `pq` is deliberately not decoded — the codebooks are the
    /// bulk of the file and nothing here renders them.
    struct Index: Decodable {
        var slots: [Slot]?
        var entityIds: [String]?
        var metadata: Data?

        enum CodingKeys: String, CodingKey {
            case slots, metadata
            case entityIds = "entity_ids"
        }
    }

    /// Server: `PartitionSlot` — no CodingKeys.
    struct Slot: Decodable {
        var id: String
        var documentId: String
    }
}

// MARK: - Documents

/// Server: `Database.Document` — snake_case CodingKeys. `url` is omitted: it
/// encodes as a nested `{relative: …}` dictionary and adds nothing here.
struct StoreDocument: Decodable {
    var id: String
    var ownerId: String?
    var name: String?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name
        case ownerId = "owner_id"
        case createdAt = "created_at"
    }
}

/// Server: `PartitionData` — the actual partition text, stored per document in
/// `documents/{id}-parts`. This is the only way to read back what was indexed;
/// no HTTP route reassembles a document.
struct StorePartition: Decodable, Identifiable {
    var id: String
    var data: String
    var ownerId: String?
    var mediaType: String?

    enum CodingKeys: String, CodingKey {
        case id, data
        case ownerId
        case mediaType = "media_type"
    }
}
