import Foundation

extension Database {
    nonisolated private func groupEntry(groupId: GroupID, in registry: ThreadRegistry) -> Database.Group? {
        guard let owner = registry.groupOwners[groupId] else { return nil }
        return registry.ownersGroups[owner]?.first { $0.id == groupId }
    }

    /// Builds a full `Database.Group` from an already-resolved entry (skips the
    /// ownersGroups re-scan done by the groupId overload).
    nonisolated func buildGroup(entry: Database.Group, registry: ThreadRegistry) -> Database.Group? {
        guard let owner = registry.groupOwners[entry.id] else { return nil }
        let docIds = registry.groups[entry.id] ?? []
        let documents = docIds.compactMap { document(for: $0) }
        let totalEarnings = registry.totalEarnings(for: entry.id)
        return Database.Group(
            id:            entry.id,
            label:         entry.label,
            ownerId:       owner.id,
            documents:     documents,
            access:        registry.groupAccess[entry.id],
            totalEarnings: totalEarnings,
            metadata:      entry.metadata
        )
    }

    nonisolated func buildGroup(groupId: GroupID, registry: ThreadRegistry) -> Database.Group? {
        guard let entry = groupEntry(groupId: groupId, in: registry) else { return nil }
        return buildGroup(entry: entry, registry: registry)
    }
}
