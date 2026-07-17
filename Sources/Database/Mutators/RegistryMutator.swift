//
//  RegistryMutator.swift
//  database-server
//
//  Created by Ritesh Pakala Rao on 3/13/26.
//

import Foundation

/// Serializes all read-modify-write operations on the TotemRegistry file.
///
/// Without this actor, concurrent embedding requests each load the same registry
/// state, apply their mutations locally, and save — last write wins, silently
/// dropping every other concurrent registration. Groups and documents registered
/// in the "lost" writes disappear without any purge being called.
///
/// Mirrors `TableMutator`: every method that mutates the registry must go through
/// this actor so each operation sees the full result of the previous one.
actor RegistryMutator {
    private let cache: TotemCache<TotemRegistry>
    private let logger: TotemLogger

    // MARK: - Debounced disk saves

    private var registryDirty = false
    private var flushTask: Task<Void, Never>?

    init(logger: TotemLogger) {
        self.cache = TotemCache(
            persistence: FilePersistence(key: "registry", kind: .basic, logger: logger.base)
        )
        self.logger = logger
    }

    // MARK: - Startup seeding

    /// Seeds the lock-protected snapshot synchronously at startup — no actor hop required.
    nonisolated func seed(_ initial: TotemRegistry) { cache.seed(initial) }

    // MARK: - Snapshot

    /// Synchronous, lock-protected read of the latest registry state.
    /// Never hops the actor queue — safe to call from any context.
    nonisolated var snapshot: TotemRegistry? { cache.snapshot }

    // MARK: - Private

    private func loadedRegistry() async -> TotemRegistry {
        return await cache.load { .init() }
    }

    /// Persists the complete registry to disk now. Cold-path mutations (remove, access
    /// update, group rename) call this so their durability does not wait on the debounce.
    private func persistNow() {
        guard let registry = cache.snapshot else { return }
        registryDirty = false
        flushTask?.cancel()
        flushTask     = nil
        Task { await self.cache.saveNow(registry) }
    }

    /// Durably flushes the registry to disk. Call from `Database.shutdown()`.
    func flushForShutdown() async {
        guard let registry = cache.snapshot else { return }
        await cache.saveNow(registry)
        registryDirty = false
        flushTask?.cancel()
        flushTask     = nil
    }

    private func scheduleSave() {
        registryDirty = true
        guard flushTask == nil else { return }
        flushTask = Task {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            self.flushIfDirty()
        }
    }

    private func flushIfDirty() {
        guard registryDirty, let registry = cache.snapshot else {
            flushTask = nil
            return
        }
        cache.saveAsync(registry)
        registryDirty = false
        flushTask = nil
    }

    // MARK: - Register

    func register(
        _ document: Database.Document,
        group: Database.Group?,
        ownerId: String
    ) async {
        var registry = await loadedRegistry()
        registry.applyRegister(documentId: document.id, ownerId: ownerId, group: group)
        cache.update(registry)
        scheduleSave()
    }

    /// Registers multiple documents in a single actor invocation.
    /// Loads the registry once, applies all mutations, then schedules one debounced save.
    func registerBatch(items: [(document: Database.Document, group: Database.Group?, ownerId: String)]) async {
        var registry = await loadedRegistry()
        for (document, group, ownerId) in items {
            registry.applyRegister(documentId: document.id, ownerId: ownerId, group: group)
        }
        cache.update(registry)
        scheduleSave()
    }

    // MARK: - Link Owner

    /// Links a new owner to an already-indexed document without re-embedding.
    /// The physical document, vectors, and partition table entry are shared as-is.
    func linkOwner(documentId: DocumentID, group: Database.Group?, ownerId: String) async {
        var registry = await loadedRegistry()
        registry.linkOwner(documentId: documentId, ownerId: ownerId, group: group)
        cache.update(registry)
        scheduleSave()
    }

    /// Links multiple new owners to existing documents in a single actor invocation.
    func linkOwnerBatch(items: [(documentId: DocumentID, group: Database.Group?, ownerId: String)]) async {
        guard !items.isEmpty else { return }
        var registry = await loadedRegistry()
        for (documentId, group, ownerId) in items {
            registry.linkOwner(documentId: documentId, ownerId: ownerId, group: group)
        }
        cache.update(registry)
        scheduleSave()
    }

    // MARK: - Remove

    /// Unlinks one owner from a document.
    /// Returns `(authorized: true, fullyRemoved: true)` when the caller was the last
    /// owner and the document should be physically deleted (file, table, HNSW).
    /// Returns `(authorized: true, fullyRemoved: false)` when other owners remain —
    /// only the caller's personal HNSW entries need to be cleaned up.
    /// Returns `(authorized: false, ...)` when the caller does not own the document.
    func remove(
        documentId: DocumentID,
        group: Database.Group?,
        ownerId: String
    ) async -> (authorized: Bool, fullyRemoved: Bool) {
        var registry = await loadedRegistry()
        let owner = TotemRegistry.Owner(id: ownerId)
        guard registry.documentOwners[documentId]?.contains(owner) == true else {
            return (false, false)
        }
        let fullyRemoved = registry.remove(documentId: documentId, group: group, owner: owner)
        cache.update(registry)
        persistNow()
        return (true, fullyRemoved)
    }

    // MARK: - Remove All

    /// Unlinks `ownerId` from all their documents.
    /// Returns:
    ///   - `fullyRemoved`: document IDs where this owner was the last — callers should
    ///     delete the physical file and partition table entry.
    ///   - `allOwned`: every document ID the owner had (superset of `fullyRemoved`) —
    ///     callers should remove all from the personal HNSW.
    func removeAll(ownerId: String) async -> (fullyRemoved: [DocumentID], allOwned: [DocumentID]) {
        var registry = await loadedRegistry()
        let owner = TotemRegistry.Owner(id: ownerId)
        let documentIds = registry.ownersDocuments[owner] ?? []
        let ownedGroupIds = (registry.ownersGroups[owner] ?? []).map { $0.id }

        var fullyRemoved: [DocumentID] = []
        for documentId in documentIds {
            let wasLast = registry.remove(documentId: documentId, group: nil, owner: owner)
            if wasLast { fullyRemoved.append(documentId) }
        }

        for groupId in ownedGroupIds {
            registry.groups.removeValue(forKey: groupId)
            registry.groupOwners.removeValue(forKey: groupId)
            registry.groupAccess.removeValue(forKey: groupId)
            registry.availableGroupIds.remove(groupId)
        }

        registry.ownersDocuments.removeValue(forKey: owner)
        registry.ownersGroups.removeValue(forKey: owner)
        registry.ownerDocumentGroup.removeValue(forKey: ownerId)

        cache.update(registry)
        persistNow()
        return (fullyRemoved, documentIds)
    }

    /// Unlinks a specific set of (documentId, ownerId) pairs in a single actor
    /// invocation. Returns the IDs that were fully removed (last owner gone).
    @discardableResult
    func removeBatch(
        items: [(documentId: DocumentID, ownerId: String)]
    ) async -> [DocumentID] {
        _ = await loadedRegistry()
        var registry = cache.snapshot ?? TotemRegistry()
        var fullyRemoved: [DocumentID] = []
        for (documentId, ownerId) in items {
            let owner = TotemRegistry.Owner(id: ownerId)
            guard registry.documentOwners[documentId]?.contains(owner) == true else { continue }
            let wasLast = registry.remove(documentId: documentId, group: nil, owner: owner)
            if wasLast { fullyRemoved.append(documentId) }
        }
        cache.update(registry)
        persistNow()
        return fullyRemoved
    }

    // MARK: - Document Stats

    /// Accumulates credit earnings into the `documentStats` map for each document in
    /// `earnings`. Appends a WAL record so the full registry is not rewritten.
    func accumulateEarnings(_ earnings: [DocumentID: Gita.Credits]) async {
        guard !earnings.isEmpty else { return }
        var registry = await loadedRegistry()
        registry.addEarnings(earnings)
        cache.update(registry)
        scheduleSave()
    }

    /// Merges per-document performance updates from a `Sinatra.PrepareResult` into
    /// `documentStats`, then schedules a debounced save.
    func accumulatePerformance(_ updates: [DocumentID: Database.DocumentStats]) async {
        guard !updates.isEmpty else { return }
        var registry = await loadedRegistry()
        registry.addPerformance(updates)
        cache.update(registry)
        scheduleSave()
    }

    // MARK: - Access

    @discardableResult
    func updateDocumentAccess(id: String, ownerId: String, access: TotemRegistry.Access) async -> Bool {
        var registry = await loadedRegistry()
        guard registry.documentOwners[id]?.contains(TotemRegistry.Owner(id: ownerId)) == true else { return false }
        registry.updateDocumentAccess(for: id, state: access)
        cache.update(registry)
        persistNow()
        return true
    }

    @discardableResult
    func updateGroupAccess(id: String, ownerId: String, access: TotemRegistry.Access) async -> Bool {
        var registry = await loadedRegistry()
        guard registry.groupOwners[id]?.id == ownerId else { return false }
        registry.updateGroupAccess(for: id, state: access)
        let documents = registry.groups[id] ?? []
        for documentId in documents {
            registry.updateDocumentAccess(for: documentId, state: access)
        }
        cache.update(registry)
        persistNow()
        return true
    }

    /// Replaces the entire in-memory cache and checkpoints immediately.
    func replace(with registry: TotemRegistry) {
        cache.update(registry)
        persistNow()
    }

    @discardableResult
    func updateGroup(_ group: Database.Group, documentId: String, ownerId: String) async -> Bool {
        let id = group.id
        var registry = await loadedRegistry()
        let owner = TotemRegistry.Owner(id: ownerId)
        guard registry.documentOwners[documentId]?.contains(owner) == true else { return false }

        let oldGroupId = registry.ownerDocumentGroup[ownerId]?[documentId]
            ?? registry.documentGroups[documentId]?.first

        registry.ownerDocumentGroup[ownerId, default: [:]][documentId] = id
        if let oldGroupId {
            registry.documentGroups[documentId]?.remove(oldGroupId)
            if registry.documentGroups[documentId]?.isEmpty == true {
                registry.documentGroups.removeValue(forKey: documentId)
            }
        }
        registry.documentGroups[documentId, default: []].insert(id)

        if let oldGroupId {
            var oldGroupHashes = registry.groups[oldGroupId] ?? []
            oldGroupHashes.removeAll(where: { $0 == documentId })
            registry.groups[oldGroupId] = oldGroupHashes
        }
        let isNewGroup = registry.groupOwners[id] == nil
        var newGroupHashes = registry.groups[id] ?? []
        if !newGroupHashes.contains(documentId) { newGroupHashes.append(documentId) }
        registry.groups[id] = newGroupHashes

        if isNewGroup {
            registry.groupOwners[id] = owner
            registry.groupAccess[id] = group.access ?? .restricted
            var ownerGroups = registry.ownersGroups[owner] ?? []
            var lo = 0, hi = ownerGroups.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ownerGroups[mid].id < group.id { lo = mid + 1 } else { hi = mid }
            }
            ownerGroups.insert(
                .init(id: group.id, label: group.label, ownerId: group.ownerId, documents: [], metadata: group.metadata),
                at: lo
            )
            registry.ownersGroups[owner] = ownerGroups
            logger.info("Registry", "New group detected, creating records.", service: .database)
        }

        cache.update(registry)
        persistNow()
        return true
    }

    /// Updates the metadata for a group. Returns `false` if the caller does not own the group.
    @discardableResult
    func updateGroupMetadata(id: String, ownerId: OwnerID, metadata: Database.Group.Metadata) async -> Bool {
        var registry = await loadedRegistry()
        let owner = TotemRegistry.Owner(id: ownerId)
        guard registry.groupOwners[id]?.id == ownerId else { return false }

        var ownerGroups = registry.ownersGroups[owner] ?? []
        guard let idx = ownerGroups.firstIndex(where: { $0.id == id }) else { return false }
        ownerGroups[idx].metadata = metadata
        registry.ownersGroups[owner] = ownerGroups

        cache.update(registry)
        persistNow()
        return true
    }

    /// Renames a group. Returns `false` if the caller does not own the group.
    @discardableResult
    func renameGroup(id: String, ownerId: String, label: String) async -> Bool {
        var registry = await loadedRegistry()
        let owner = TotemRegistry.Owner(id: ownerId)
        guard registry.groupOwners[id]?.id == ownerId else { return false }

        var ownerGroups = registry.ownersGroups[owner] ?? []
        guard let idx = ownerGroups.firstIndex(where: { $0.id == id }) else { return false }
        ownerGroups[idx].label = label
        registry.ownersGroups[owner] = ownerGroups

        cache.update(registry)
        persistNow()
        return true
    }

    /// Removes registry metadata for a set of groups that the caller explicitly
    /// deleted. Called by the groups-purge route after document removal completes.
    func removeGroupEntries(_ groupIds: [GroupID], ownerId: String) async {
        guard !groupIds.isEmpty else { return }
        var registry = await loadedRegistry()
        let owner = TotemRegistry.Owner(id: ownerId)
        for groupId in groupIds {
            guard registry.groupOwners[groupId]?.id == ownerId else { continue }
            registry.groups.removeValue(forKey: groupId)
            registry.groupOwners.removeValue(forKey: groupId)
            registry.groupAccess.removeValue(forKey: groupId)
            registry.availableGroupIds.remove(groupId)
            var ownerGroups = registry.ownersGroups[owner] ?? []
            ownerGroups.removeAll(where: { $0.id == groupId })
            registry.ownersGroups[owner] = ownerGroups
        }
        cache.update(registry)
        persistNow()
    }
}
