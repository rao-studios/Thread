//
//  DatabaseDocument.swift
//  database-server
//
//  Created by Ritesh Pakala on 11/1/25.
//

import Foundation

/// Base document object for text-embeddings stored on the
/// Database network.
extension Database {
    struct Document: Codable {
        var id: String
        var url: URL

        // Ties with Gita owners on-chain.
        var ownerId: String

        /// Original filename supplied by the client at embed time. Optional for
        /// backward compatibility — absent on documents indexed before this field.
        var name: String?

        var createdAt: Date = .now

        enum CodingKeys: String, CodingKey {
            case id
            case url
            case ownerId = "owner_id"
            case name
            case createdAt = "created_at"
        }

        init(id: String, url: URL, ownerId: String, name: String? = nil, createdAt: Date = .now) {
            self.id = id
            self.url = url
            self.ownerId = ownerId
            self.name = name
            self.createdAt = createdAt
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id        = try c.decode(String.self, forKey: .id)
            url       = try c.decode(URL.self,    forKey: .url)
            ownerId   = try c.decode(String.self, forKey: .ownerId)
            name      = try c.decodeIfPresent(String.self, forKey: .name)
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        }
    }
    
    struct DocumentReference: Codable {
        var id: String
        var partitionId: String
        var ownerId: String
        var threadId: String? = nil
        var shardIndex: Int? = nil

        enum CodingKeys: String, CodingKey {
            case id
            case partitionId = "partition_id"
            case ownerId     = "owner_id"
            case threadId     = "thread_id"
            case shardIndex  = "shard_index"
        }
    }
}

extension Database {
    // MARK: - Partition text store

    /// Per-document file holding `[PartitionData]` — written at index time and
    /// loaded on demand during content resolution.
    nonisolated func partitionStore(for id: DocumentID) -> FilePersistence {
        FilePersistence(key: "documents/\(id)-parts", kind: .basic, logger: logger.base)
    }

    /// Load all partition metadata records for a document. Returns nil when the file
    /// doesn't exist (fresh install before the first write).
    nonisolated func partitionDatas(for documentId: DocumentID) -> [PartitionData]? {
        partitionStore(for: documentId).restore()
    }

    /// Find a single partition metadata record by ID. Used as the `PartitionDataLoader`
    /// closure passed into `PartitionTable.search()` and related paths.
    nonisolated func partitionData(documentId: DocumentID, partitionId: String) -> PartitionData? {
        partitionDatas(for: documentId)?.first(where: { $0.id == partitionId })
    }

    /// Build a `PartitionDataLoader` that loads each document's parts file once,
    /// then serves all partition lookups from the in-memory cache.
    /// Use this in batch paths (e.g. HNSW visualization) where many nodes from
    /// the same document would otherwise each trigger a full disk read.
    nonisolated func makePartitionDataLoader(for documentIds: some Collection<DocumentID>) -> PartitionDataLoader {
        var cache: [DocumentID: [PartitionData]] = [:]
        for docId in documentIds {
            cache[docId] = partitionDatas(for: docId)
        }
        return { docId, partId in cache[docId]?.first(where: { $0.id == partId }) }
    }

    // MARK: - Document store

    /// Helper to retrieve the `FilePersistence` instance of the document.
    /// - Parameter id: The `DocumentID`.
    /// - Returns: The `FilePersistence` object.
    nonisolated func documentStore(for id: DocumentID) -> FilePersistence {
        FilePersistence(key: "documents/\(id)",
                        kind: .basic,
                        logger: logger.base)
    }
    /// Retrieve the `Database.Document` for a `DocumentID`.
    /// Returns the in-memory cached copy if available; falls back to disk.
    nonisolated func document(for id: DocumentID) -> Database.Document? {
        documentCache.get(id) ?? documentStore(for: id).restore()
    }
    /// Helper to retrieve the `FilePersistence` instance of the document.
    /// - Parameter id: The `DocumentID`.
    /// - Returns: The `FilePersistence` object.
    func conversationDocumentStore(for id: DocumentID) -> FilePersistence {
        FilePersistence(key: "conversations/\(id)",
                        kind: .basic,
                        logger: logger.base)
    }
    /// Retrieve the conversation `Database.Document` for a `DocumentID` via `FilePersistence`.
    /// - Parameter id: The `DocumentID`.
    /// - Returns: The `Database.Document` object.
    func conversationDocument(for id: DocumentID) -> Database.Document? {
        conversationDocumentStore(for: id).restore()
    }
}
