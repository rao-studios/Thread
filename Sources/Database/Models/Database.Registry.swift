//
//  Database.Registry.swift
//  database-server
//
//  Created by Ritesh Pakala on 11/8/25.
//

import Foundation

typealias DocumentID = String
typealias GroupID = String
typealias OwnerID = String

/// Registry for owners and their documents.
struct ThreadRegistry: Codable {
    // All documents under a owner.
    var ownersDocuments: [Owner : [DocumentID]] = [:]
    // All owners of a document (one-to-many CID ownership).
    var documentOwners: [DocumentID : Set<Owner>] = [:]
    // All groups a document belongs to — one per linked owner.
    // This is the union index used by search diversity injection.
    // Per-owner group assignment lives in `ownerDocumentGroup`.
    var documentGroups: [DocumentID : Set<GroupID>] = [:]
    // Per-owner group assignment: [OwnerID: [DocumentID: GroupID]].
    // Authoritative for owner-scoped operations (removal, updateGroup, GroupKind resolution).
    // Kept in sync with `documentGroups`.
    var ownerDocumentGroup: [OwnerID : [DocumentID : GroupID]] = [:]
    // All groups under a owner.
    // Database.Group in this scope will not have document values.
    var ownersGroups: [Owner : [Database.Group]] = [:]
    // Associated owner with a GroupID.
    var groupOwners: [GroupID : Owner] = [:]
    // Documents are stored in groups.
    var groups: [GroupID : [DocumentID]] = [:]
    // Files that are publicly available for aggregation
    // or earning royalties back to their relative owners.
    var documentAccess: [DocumentID : Access] = [:]
    // Groups that are publicly available for aggregation
    var groupAccess: [GroupID : Access] = [:]
    // Pre-computed set of document IDs whose access is `.available`.
    // Updated by `updateDocumentAccess(for:state:)` and `remove(documentId:)`.
    // Eliminates the O(D) scan of `documentAccess` on every global-scope query.
    var availableDocumentIds: Set<DocumentID> = []
    // Pre-computed set of group IDs whose access is `.available`.
    // Updated by `updateGroupAccess(for:state:)`.
    // Eliminates the O(G) scan of `groupAccess` on every libraryRequest.
    var availableGroupIds: Set<GroupID> = []
    // Billing and engagement stats per document.
    // Keyed by DocumentID — same identifier as the document itself.
    // Created when a document is registered; removed when it is deleted.
    var documentStats: [DocumentID : Database.DocumentStats] = [:]

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case ownersDocuments, documentOwners, documentGroups, ownerDocumentGroup
        case ownersGroups, groupOwners, groups
        case documentAccess, groupAccess, availableDocumentIds, availableGroupIds
        case documentStats
    }

    /// Custom decoder with two migration paths:
    /// - `documentOwners`: old `[DocumentID: Owner]` → `[DocumentID: Set<Owner>]`
    /// - `documentGroups`: old `[DocumentID: GroupID]` → `[DocumentID: Set<GroupID>]`
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ownersDocuments = try c.decode([Owner: [DocumentID]].self, forKey: .ownersDocuments)

        if let v = try? c.decode([DocumentID: Set<Owner>].self, forKey: .documentOwners) {
            documentOwners = v
        } else {
            let old = try c.decode([DocumentID: Owner].self, forKey: .documentOwners)
            documentOwners = old.mapValues { Set([$0]) }
        }

        if let v = try? c.decode([DocumentID: Set<GroupID>].self, forKey: .documentGroups) {
            documentGroups = v
        } else {
            let old = try c.decode([DocumentID: GroupID].self, forKey: .documentGroups)
            documentGroups = old.mapValues { Set([$0]) }
        }

        ownerDocumentGroup  = try c.decodeIfPresent([OwnerID: [DocumentID: GroupID]].self, forKey: .ownerDocumentGroup) ?? [:]
        ownersGroups        = try c.decode([Owner: [Database.Group]].self,     forKey: .ownersGroups)
        groupOwners         = try c.decode([GroupID: Owner].self,          forKey: .groupOwners)
        groups              = try c.decode([GroupID: [DocumentID]].self,   forKey: .groups)
        documentAccess      = try c.decode([DocumentID: Access].self,      forKey: .documentAccess)
        groupAccess         = try c.decode([GroupID: Access].self,         forKey: .groupAccess)
        availableDocumentIds  = try c.decodeIfPresent(Set<DocumentID>.self,                forKey: .availableDocumentIds)  ?? []
        availableGroupIds     = try c.decodeIfPresent(Set<GroupID>.self,                  forKey: .availableGroupIds)     ?? []
        documentStats         = try c.decodeIfPresent([DocumentID: Database.DocumentStats].self, forKey: .documentStats)       ?? [:]
    }

    init() {}
}

extension ThreadRegistry {
    struct Owner: Codable, Hashable {
        let id: String
    }
}

// MARK: - Modifications

extension ThreadRegistry {
    /// Removes an orphaned DocumentID — one whose file is missing on disk — from all
    /// registry collections without requiring a pre-fetched owner or group object.
    /// Safe to call during startup before the document cache is populated.
    mutating func removeOrphaned(documentId: DocumentID) {
        let owners = documentOwners[documentId] ?? []
        for owner in owners {
            ownersDocuments[owner]?.removeAll(where: { $0 == documentId })
            ownerDocumentGroup[owner.id]?.removeValue(forKey: documentId)
        }
        for groupId in documentGroups[documentId] ?? [] {
            groups[groupId]?.removeAll(where: { $0 == documentId })
        }
        documentOwners.removeValue(forKey: documentId)
        documentGroups.removeValue(forKey: documentId)
        documentAccess.removeValue(forKey: documentId)
        documentStats.removeValue(forKey: documentId)
        availableDocumentIds.remove(documentId)
    }

    /// Unlinks one owner from a document.
    /// Returns `true` when the document was fully removed (no owners remain)
    /// and the caller should delete the physical file, partition table entry, and HNSW nodes.
    /// Returns `false` when other owners still hold the document — only the personal
    /// HNSW entries for the removed owner should be cleaned up.
    @discardableResult
    mutating func remove(
        documentId: DocumentID,
        group: Database.Group?,
        owner: Owner
    ) -> Bool {
        var ownerDocuments = self.ownersDocuments[owner] ?? []
        ownerDocuments.removeAll(where: { $0 == documentId })
        self.ownersDocuments[owner] = ownerDocuments

        // Resolve this owner's group from the per-owner map, falling back to any
        // entry in the Set index for registries migrated before ownerDocumentGroup
        // was introduced, then to the caller-supplied hint.
        let resolvedGroupId = ownerDocumentGroup[owner.id]?[documentId]
            ?? documentGroups[documentId]?.first
            ?? group?.id
        ownerDocumentGroup[owner.id]?.removeValue(forKey: documentId)

        if let groupId = resolvedGroupId {
            // Remove the document from the group's list but keep the group itself —
            // groups are only removed when the user explicitly deletes them.
            var groupDocuments = self.groups[groupId] ?? []
            groupDocuments.removeAll(where: { $0 == documentId })
            self.groups[groupId] = groupDocuments

            // Remove this group from the document's group Set index.
            documentGroups[documentId]?.remove(groupId)
            if documentGroups[documentId]?.isEmpty == true {
                documentGroups.removeValue(forKey: documentId)
            }
        }

        documentOwners[documentId]?.remove(owner)

        guard documentOwners[documentId]?.isEmpty != false else {
            return false  // other owners still hold this document
        }

        // Last owner removed — purge all remaining document-level state.
        documentOwners.removeValue(forKey: documentId)
        documentGroups.removeValue(forKey: documentId)
        documentAccess.removeValue(forKey: documentId)
        documentStats.removeValue(forKey: documentId)
        availableDocumentIds.remove(documentId)
        return true
    }

    /// Links a new owner (or a new group) to an already-indexed document without re-embedding.
    /// Idempotent — calling it twice for the same (documentId, ownerId, group) triple is safe.
    /// When the owner is already linked but the group is new, only the group associations are
    /// written — owner-level maps are left unchanged.
    mutating func linkOwner(documentId: DocumentID, ownerId: OwnerID, group: Database.Group?) {
        let owner = Owner(id: ownerId)
        let alreadyOwner = documentOwners[documentId]?.contains(owner) == true

        if !alreadyOwner {
            documentOwners[documentId, default: []].insert(owner)

            var hashes = ownersDocuments[owner] ?? []
            if !hashes.contains(documentId) { hashes.append(documentId) }
            ownersDocuments[owner] = hashes
        }

        // Drop the group entirely if another owner already holds it — don't write any
        // group-keyed state (groups, ownerDocumentGroup, documentGroups, ownersGroups).
        guard let group, groupOwners[group.id] == nil || groupOwners[group.id] == owner else { return }
        let groupId = group.id

        // Preserve the primary (first-registered) group in ownerDocumentGroup; additional
        // groups for the same (owner, document) pair are tracked only in documentGroups.
        if ownerDocumentGroup[ownerId]?[documentId] == nil {
            ownerDocumentGroup[ownerId, default: [:]][documentId] = groupId
        }
        documentGroups[documentId, default: []].insert(groupId)

        var groupHashes = groups[groupId] ?? []
        if !groupHashes.contains(documentId) { groupHashes.append(documentId) }
        groups[groupId] = groupHashes

        var groupOwnersHashes = ownersGroups[owner] ?? []
        if !groupOwnersHashes.contains(where: { $0.id == groupId }) {
            sortedGroupInsert(
                .init(id: group.id, label: group.label, ownerId: ownerId, documents: [], metadata: group.metadata),
                into: &groupOwnersHashes
            )
        }
        ownersGroups[owner] = groupOwnersHashes
        if groupOwners[groupId] == nil { groupOwners[groupId] = owner }

        if groupAccess[groupId] == nil { updateGroupAccess(for: groupId, state: group.access ?? .restricted) }
    }
}

// MARK: - Document Stats

extension ThreadRegistry {
    /// Returns the stats for a given document, or a zero-value default if absent.
    func stats(for documentId: DocumentID) -> Database.DocumentStats {
        documentStats[documentId] ?? .init(id: documentId)
    }

    /// Accumulates credits earned into the stats entry for each document.
    /// Creates a new stats entry when one does not yet exist.
    mutating func addEarnings(_ earnings: [DocumentID: Gita.Credits]) {
        for (documentId, credits) in earnings where credits > 0 {
            documentStats[documentId, default: .init(id: documentId)].totalEarned += credits
        }
    }

    /// Additively merges per-document performance updates from a `Sinatra.PrepareResult`
    /// into the registry's `documentStats` map.
    mutating func addPerformance(_ updates: [DocumentID: Database.DocumentStats]) {
        for (documentId, updated) in updates {
            var entry = documentStats[documentId, default: .init(id: documentId)]
            entry.retrievalCount += updated.retrievalCount
            entry.sentimentSum   += updated.sentimentSum
            if let t = updated.lastRetrieved {
                entry.lastRetrieved = t
            }
            for (partitionId, count) in updated.partitionRetrievalCount {
                entry.partitionRetrievalCount[partitionId, default: 0] += count
            }
            for (partitionId, ps) in updated.partitionSentiments {
                entry.partitionSentiments[partitionId, default: .init()].retrievalCount += ps.retrievalCount
                entry.partitionSentiments[partitionId, default: .init()].sentimentSum   += ps.sentimentSum
                if let t = ps.lastRetrieved {
                    entry.partitionSentiments[partitionId, default: .init()].lastRetrieved = t
                }
            }
            documentStats[documentId] = entry
        }
    }

    /// Returns the total credits earned across all documents in a group.
    func totalEarnings(for groupId: GroupID) -> Gita.Credits {
        let documentIds = groups[groupId] ?? []
        return documentIds.reduce(0) { $0 + (documentStats[$1]?.totalEarned ?? 0) }
    }
}

// MARK: - Access

extension ThreadRegistry {
    enum Access: String, Codable {
        case available
        case restricted
        case unknown
    }

    func getDocumentAccess(_ id: DocumentID) -> Access {
        documentAccess[id] ?? .unknown
    }

    /// Updates the availability/access state for a document.
    /// Also keeps `availableDocumentIds` in sync so global-scope queries
    /// never need to scan `documentAccess`.
    mutating func updateDocumentAccess(for id: DocumentID, state: Access) {
        documentAccess[id] = state
        if state == .available {
            availableDocumentIds.insert(id)
        } else {
            availableDocumentIds.remove(id)
        }
    }

    /// Checks if document exists in the registry (has at least one owner).
    func doesDocumentExist(_ documentId: DocumentID) -> Bool {
        if let state = documentAccess[documentId] {
            return state != .unknown
        } else {
            return false
        }
    }

    /// Returns `true` when `ownerId` is among the linked owners of `documentId`.
    func isOwnerLinked(_ documentId: DocumentID, ownerId: OwnerID) -> Bool {
        documentOwners[documentId]?.contains(Owner(id: ownerId)) == true
    }
}

extension ThreadRegistry {
    func getGroupAccess(_ id: GroupID) -> Access {
        groupAccess[id] ?? .unknown
    }

    mutating func updateGroupAccess(for id: GroupID, state: Access) {
        groupAccess[id] = state
        if state == .available {
            availableGroupIds.insert(id)
        } else {
            availableGroupIds.remove(id)
        }
    }
}

// MARK: - Helpers

private func sortedGroupInsert(_ group: Database.Group, into list: inout [Database.Group]) {
    var lo = 0, hi = list.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if list[mid].id < group.id { lo = mid + 1 } else { hi = mid }
    }
    list.insert(group, at: lo)
}

extension ThreadRegistry {
    /// Returns a `Database.Group` for a document using the first group in the Set index.
    /// Prefer `ownerDocumentGroup[ownerId]?[documentId]` for owner-scoped lookups.
    func group(for documentId: DocumentID) -> Database.Group? {
        guard let groupId = documentGroups[documentId]?.first else { return nil }
        guard let owner = groupOwners[groupId] else { return nil }
        return ownersGroups[owner]?.first(where: { $0.id == groupId })
    }
}

// MARK: - WAL-replayable mutations

extension ThreadRegistry {
    /// Registers `documentId` under `ownerId` with an optional group association.
    ///
    /// Extracted from `RegistryMutator.register` so the same logic is used both
    /// on the live path and during WAL replay at startup. Does not touch caches,
    /// actors, or persistence — pure in-memory mutation.
    mutating func applyRegister(documentId: DocumentID, ownerId: OwnerID, group: Database.Group?) {
        let owner = Owner(id: ownerId)

        documentOwners[documentId, default: []].insert(owner)

        var hashes = ownersDocuments[owner] ?? []
        if !hashes.contains(documentId) { hashes.append(documentId) }
        ownersDocuments[owner] = hashes

        if documentStats[documentId] == nil {
            documentStats[documentId] = .init(id: documentId)
        }

        let effectiveGroup: Database.Group? = {
            guard let g = group else { return nil }
            let existing = groupOwners[g.id]
            return (existing == nil || existing == owner) ? g : nil
        }()

        if let g = effectiveGroup {
            let groupId = g.id
            var groupHashes = groups[groupId] ?? []
            if !groupHashes.contains(documentId) { groupHashes.append(documentId) }
            groups[groupId] = groupHashes
            ownerDocumentGroup[ownerId, default: [:]][documentId] = groupId
            documentGroups[documentId, default: []].insert(groupId)

            var ownerGroupList = ownersGroups[owner] ?? []
            if let existingIdx = ownerGroupList.firstIndex(where: { $0.id == groupId }) {
                // Merge new tags into an existing group's metadata.
                if let newTags = g.metadata?.tags, !newTags.isEmpty {
                    var existingMeta = ownerGroupList[existingIdx].metadata ?? Database.Group.Metadata()
                    existingMeta.tags = Array(Set(existingMeta.tags + newTags)).sorted()
                    ownerGroupList[existingIdx].metadata = existingMeta
                    ownersGroups[owner] = ownerGroupList
                }
            } else {
                sortedGroupInsert(
                    .init(id: g.id, label: g.label, ownerId: ownerId, documents: [], metadata: g.metadata),
                    into: &ownerGroupList
                )
                ownersGroups[owner] = ownerGroupList
            }
            if groupOwners[groupId] == nil { groupOwners[groupId] = owner }
            if groupAccess[groupId] == nil { updateGroupAccess(for: groupId, state: g.access ?? .restricted) }
            if let access = groupAccess[groupId] { updateDocumentAccess(for: documentId, state: access) }
        } else {
            updateDocumentAccess(for: documentId, state: .restricted)
        }
    }
}
