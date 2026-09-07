//
//  Database.Group.swift
//  database-server
//
//  Created by Ritesh Pakala Rao on 12/10/25.
//

import Foundation

/// A Database group object that stores a list of documents relative
/// to a group. Includes are media types in the future.
extension Database {
    struct Group: Codable {
        var id: String
        var label: String
        var ownerId: String
        var documents: [Database.Document]
        var access: ThreadRegistry.Access?
        /// Aggregate credits earned by all documents in this group across every
        /// inference where any of its partitions were retrieved and priced.
        /// Computed at response time by summing `document.totalEarned` — not stored
        /// in the registry, so it always reflects the latest persisted document state.
        var totalEarnings: Gita.Credits?
        /// Optional owner-supplied metadata. Nil for groups created before this field
        /// was introduced — all registry decoders use `decodeIfPresent`.
        var metadata: Metadata?

        init(id: String,
             label: String,
             ownerId: String,
             documents: [Database.Document],
             access: ThreadRegistry.Access? = nil,
             totalEarnings: Gita.Credits? = nil,
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
            case id
            case label
            case ownerId       = "owner_id"
            case documents
            case access
            case totalEarnings = "total_earnings"
            case metadata
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id           = try c.decode(String.self,                 forKey: .id)
            label        = try c.decode(String.self,                 forKey: .label)
            ownerId      = try c.decode(String.self,                 forKey: .ownerId)
            documents    = try c.decodeIfPresent([Database.Document].self, forKey: .documents) ?? []
            access       = try c.decodeIfPresent(ThreadRegistry.Access.self, forKey: .access)
            totalEarnings = try c.decodeIfPresent(Gita.Credits.self, forKey: .totalEarnings)
            metadata     = try c.decodeIfPresent(Metadata.self,      forKey: .metadata)
        }
    }
}

// MARK: - Metadata

extension Database.Group {
    /// Descriptive metadata an owner can attach to a group.
    /// Exposed via the leaderboard and search endpoints so external users
    /// can understand what a public group contains before querying it.
    struct Metadata: Codable {
        var description: String?
        var tags: [String]

        init(description: String? = nil, tags: [String] = []) {
            self.description = description
            self.tags = tags
        }

        enum CodingKeys: String, CodingKey {
            case description
            case tags
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            description = try c.decodeIfPresent(String.self,   forKey: .description)
            tags        = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        }
    }
}
