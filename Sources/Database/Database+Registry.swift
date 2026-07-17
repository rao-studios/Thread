import Foundation

extension Database {
    func initializeRegistry() {
        let storage = registryStore
        var registry: TotemRegistry = storage.restore() ?? .init()

        if registry.availableDocumentIds.isEmpty && !registry.documentAccess.isEmpty {
            registry.availableDocumentIds = Set(
                registry.documentAccess.compactMap { $0.value == .available ? $0.key : nil }
            )
            storage.save(state: registry)
        }

        if registry.availableGroupIds.isEmpty && !registry.groupAccess.isEmpty {
            registry.availableGroupIds = Set(
                registry.groupAccess.compactMap { $0.value == .available ? $0.key : nil }
            )
            storage.save(state: registry)
        }

        let allDocumentIds = Array(registry.documentOwners.keys)
        var initial: [DocumentID: Database.Document] = [:]
        var orphanedIds: [DocumentID] = []

        for documentId in allDocumentIds {
            let store = documentStore(for: documentId)
            guard FileManager.default.fileExists(atPath: store.url.path()) else {
                orphanedIds.append(documentId)
                continue
            }
            if let document: Database.Document = store.restore() {
                initial[documentId] = document
            } else {
                orphanedIds.append(documentId)
            }
        }

        if !orphanedIds.isEmpty {
            for id in orphanedIds { registry.removeOrphaned(documentId: id) }
            storage.save(state: registry)
            logger.info(
                "Registry Init",
                "⚠️ Removed \(orphanedIds.count) orphaned document(s)",
                service: .database
            )
        }

        var staleGroupCount = 0
        for (owner, ownerGroups) in registry.ownersGroups {
            let cleaned = ownerGroups.filter { registry.groupOwners[$0.id] == owner }
            if cleaned.count != ownerGroups.count {
                staleGroupCount += ownerGroups.count - cleaned.count
                registry.ownersGroups[owner] = cleaned
            }
        }
        if staleGroupCount > 0 {
            storage.save(state: registry)
            logger.warning(
                "⚠️ Removed \(staleGroupCount) stale group reference(s) from ownersGroups",
                service: .database
            )
        }

        // Enforce sorted invariant on load. Write paths maintain this order, so
        // Timsort detects the existing runs in O(n) after the first startup.
        // Keeping it here also self-heals registries restored from older backups.
        for key in registry.ownersGroups.keys {
            registry.ownersGroups[key]?.sort { $0.id < $1.id }
        }

        registryMutator.seed(registry)
        documentCache.seed(initial)
        logger.debug(
            "Registry Init",
            "⚜️ Database Registry initialized — \(allDocumentIds.count - orphanedIds.count) document(s) pre-cached",
            service: .database
        )
    }

    var registryStore: FilePersistence {
        FilePersistence(key: "registry", kind: .basic, logger: logger.base)
    }
}

extension Database {
    func register(_ document: Database.Document,
                  group: Database.Group?,
                  update: DatabaseUpdate? = nil,
                  ownerId: String) async {
        await registryMutator.register(document, group: group, ownerId: ownerId)

        if let update, update.operation == .remove {
            await remove(documentId: update.documentId, group: group, ownerId: ownerId)
        }
    }

    @discardableResult
    func updateDocumentAccess(_ id: String,
                              ownerId: String,
                              access: TotemRegistry.Access) async -> Bool {
        let updated = await registryMutator.updateDocumentAccess(id: id, ownerId: ownerId, access: access)
        if !updated {
            logger.info("Registry", "Owner does not own this document.", service: .database)
        }
        return updated
    }
}

extension Database {
    nonisolated func groups(for ownerId: OwnerID) -> [Database.Group] {
        guard let registry else { return [] }
        let owner = TotemRegistry.Owner(id: ownerId)
        return (registry.ownersGroups[owner] ?? []).compactMap { entry in
            guard entry.ownerId == owner.id else { return nil }
            return buildGroup(entry: entry, registry: registry)
        }
    }

    nonisolated func availableGroups() -> [Database.Group] {
        guard let registry else { return [] }
        return registry.availableGroupIds
            .compactMap { buildGroup(groupId: $0, registry: registry) }
    }

    /// Returns lightweight group entries (documents NOT loaded) for the given owner.
    /// Useful for pagination: apply cursor/limit to the entries, then buildGroup only on the page.
    nonisolated func groupEntries(for ownerId: OwnerID) -> [Database.Group] {
        guard let registry else { return [] }
        let owner = TotemRegistry.Owner(id: ownerId)
        return (registry.ownersGroups[owner] ?? []).filter { $0.ownerId == owner.id }
    }

    /// Returns lightweight group entries for all available (public) groups.
    nonisolated func availableGroupEntries() -> [Database.Group] {
        guard let registry else { return [] }
        return registry.availableGroupIds.compactMap { id in
            guard let owner = registry.groupOwners[id],
                  let list = registry.ownersGroups[owner] else { return nil }
            var lo = 0, hi = list.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if list[mid].id < id { lo = mid + 1 }
                else if list[mid].id > id { hi = mid }
                else { return list[mid] }
            }
            return nil
        }
    }

    func stats(for documentId: DocumentID) -> Database.DocumentStats? {
        registry?.documentStats[documentId]
    }

    @discardableResult
    func updateGroupAccess(_ id: String,
                           ownerId: String,
                           access: TotemRegistry.Access) async -> Bool {
        let updated = await registryMutator.updateGroupAccess(id: id, ownerId: ownerId, access: access)
        if !updated {
            logger.info("Registry", "Owner does not own this group.", service: .database)
        }
        return updated
    }

    @discardableResult
    func renameGroup(id: String, ownerId: String, label: String) async -> Bool {
        await registryMutator.renameGroup(id: id, ownerId: ownerId, label: label)
    }

    @discardableResult
    func updateGroupMetadata(id: String, ownerId: String, metadata: Database.Group.Metadata) async -> Bool {
        await registryMutator.updateGroupMetadata(id: id, ownerId: ownerId, metadata: metadata)
    }

    @discardableResult
    func updateGroup(_ group: Database.Group, documentId: String, ownerId: String) async -> Bool {
        await registryMutator.updateGroup(group, documentId: documentId, ownerId: ownerId)
    }

    nonisolated var registry: TotemRegistry? { registryMutator.snapshot }

    nonisolated func coOwners(for documentIds: some Collection<DocumentID>) -> [DocumentID: Set<OwnerID>] {
        guard let reg = registry else { return [:] }
        return documentIds.reduce(into: [:]) { result, docId in
            var owners = Set(reg.documentOwners[docId]?.map(\.id) ?? [])
            for groupId in reg.documentGroups[docId] ?? [] {
                if let groupOwner = reg.groupOwners[groupId] {
                    owners.insert(groupOwner.id)
                }
            }
            guard owners.count > 1 else { return }
            result[docId] = owners
        }
    }
}
