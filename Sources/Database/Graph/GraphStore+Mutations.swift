//
//  GraphStore+Mutations.swift
//  database-server
//
//  Granular graph editing: delete/rename/merge entities, delete relationships.
//  Entities are content-addressed by (kind|normalized name), so rename, merge,
//  and kind changes are all re-keying operations sharing one primitive.
//

import Foundation

extension GraphStore {

    /// Result of a mutation: the surviving entity id (nil for deletes) and the
    /// documents whose `PartitionIndex.entityIds` must be rewritten.
    struct MutationResult {
        var survivingId: EntityID?
        var affectedDocumentIds: Set<DocumentID>
    }

    // MARK: - Delete

    /// Removes an entity and every relationship touching it.
    mutating func deleteEntity(id: EntityID) -> MutationResult {
        guard let entity = entities.removeValue(forKey: id) else {
            return MutationResult(survivingId: nil, affectedDocumentIds: [])
        }
        for rid in adjacency[id] ?? [] {
            if let rel = relationships.removeValue(forKey: rid) {
                adjacency[rel.subjectId]?.remove(rid)
                adjacency[rel.objectId]?.remove(rid)
            }
        }
        adjacency.removeValue(forKey: id)
        return MutationResult(survivingId: nil, affectedDocumentIds: entity.documentIds)
    }

    /// Removes one relationship (entities keep their provenance).
    mutating func deleteRelationship(id: RelationshipID) {
        guard let rel = relationships.removeValue(forKey: id) else { return }
        adjacency[rel.subjectId]?.remove(id)
        adjacency[rel.objectId]?.remove(id)
    }

    // MARK: - Rename / kind change / merge (all re-keys)

    /// Renames an entity, re-keying its content-addressed id. If the new
    /// identity already exists this becomes a merge into it.
    mutating func renameEntity(id: EntityID, newName: String) -> MutationResult {
        guard let entity = entities[id] else {
            return MutationResult(survivingId: nil, affectedDocumentIds: [])
        }
        return rekey(id: id, newKind: entity.kind, newName: newName)
    }

    /// Changes an entity's kind (part of the content address → re-key).
    mutating func setEntityKind(id: EntityID, kind: String) -> MutationResult {
        guard let entity = entities[id] else {
            return MutationResult(survivingId: nil, affectedDocumentIds: [])
        }
        return rekey(id: id, newKind: kind, newName: entity.name)
    }

    /// Merges `from` into `into` — provenance unions, relationships re-point.
    mutating func mergeEntities(from: EntityID, into target: EntityID) -> MutationResult {
        guard from != target,
              entities[from] != nil,
              let targetEntity = entities[target] else {
            return MutationResult(survivingId: entities[target] != nil ? target : nil,
                                  affectedDocumentIds: [])
        }
        return rekey(id: from, newKind: targetEntity.kind, newName: targetEntity.name)
    }

    // MARK: - Rekey primitive

    /// Moves an entity to a new (kind, name) identity. When the target identity
    /// already exists the two entities merge (provenance union, mention sum).
    /// Every incident relationship is rewritten — their ids re-key too since a
    /// relationship id hashes (subject|predicate|object) — with weight/provenance
    /// merged on collision.
    private mutating func rekey(id oldId: EntityID, newKind: String, newName: String) -> MutationResult {
        guard let old = entities[oldId] else {
            return MutationResult(survivingId: nil, affectedDocumentIds: [])
        }
        let kind = Self.normalizeKind(newKind)
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return MutationResult(survivingId: oldId, affectedDocumentIds: [])
        }
        let newId = Self.entityID(kind: kind, name: trimmedName)

        // Affected docs: everything that referenced either identity.
        var affectedDocs = old.documentIds

        if newId == oldId {
            // Same identity — only the display casing changed.
            var updated = old
            updated.name = trimmedName
            entities[oldId] = updated
            return MutationResult(survivingId: oldId, affectedDocumentIds: [])
        }

        // Build/merge the surviving entity.
        if var existing = entities[newId] {
            affectedDocs.formUnion(existing.documentIds)
            existing.documentIds.formUnion(old.documentIds)
            existing.mentionCount += old.mentionCount
            if existing.embedding == nil { existing.embedding = old.embedding }
            entities[newId] = existing
        } else {
            entities[newId] = Entity(
                id: newId, name: trimmedName, kind: kind,
                // The embedding encodes "kind: name" — stale after a re-key.
                // Cleared so the next enrichment pass re-embeds it; name-token
                // matching keeps working meanwhile.
                embedding: nil,
                documentIds: old.documentIds,
                mentionCount: old.mentionCount
            )
        }
        entities.removeValue(forKey: oldId)

        // Rewrite incident relationships (their ids re-key with the endpoint).
        let incident = adjacency[oldId] ?? []
        for rid in incident {
            guard let rel = relationships.removeValue(forKey: rid) else { continue }
            adjacency[rel.subjectId]?.remove(rid)
            adjacency[rel.objectId]?.remove(rid)

            let subjectId = rel.subjectId == oldId ? newId : rel.subjectId
            let objectId = rel.objectId == oldId ? newId : rel.objectId
            // A self-loop created by a merge collapses away.
            guard subjectId != objectId else { continue }

            let newRid = Self.relationshipID(subjectId: subjectId, predicate: rel.predicate, objectId: objectId)
            if var existing = relationships[newRid] {
                existing.weight += rel.weight
                existing.documentIds.formUnion(rel.documentIds)
                relationships[newRid] = existing
            } else {
                relationships[newRid] = Relationship(
                    id: newRid, subjectId: subjectId, predicate: rel.predicate,
                    objectId: objectId, embedding: rel.embedding,
                    documentIds: rel.documentIds, weight: rel.weight
                )
            }
            adjacency[subjectId, default: []].insert(newRid)
            adjacency[objectId, default: []].insert(newRid)
        }
        adjacency.removeValue(forKey: oldId)

        return MutationResult(survivingId: newId, affectedDocumentIds: affectedDocs)
    }
}
