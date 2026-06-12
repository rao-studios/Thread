import Conduit
import Foundation
import GRPCCore

final class TotemUpdateServiceImpl: Sendable {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    // MARK: - UpdateGroup

    func updateGroup(
        request: Totem_V1_TotemUpdateGroupRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemUpdateGroupResponse {
        let ownerId = request.ownerID
        let groupId = request.groupID
        var didUpdate = false

        if !request.access.isEmpty,
           let access = TotemRegistry.Access(rawValue: request.access) {
            let ok = await database.updateGroupAccess(groupId, ownerId: ownerId, access: access)
            didUpdate = didUpdate || ok
        }

        if !request.label.isEmpty {
            let ok = await database.renameGroup(id: groupId, ownerId: ownerId, label: request.label)
            didUpdate = didUpdate || ok
        }

        if request.updateMetadata {
            let meta = Database.Group.Metadata(
                description: request.groupDescription.isEmpty ? nil : request.groupDescription,
                tags: Array(request.tags)
            )
            let ok = await database.updateGroupMetadata(id: groupId, ownerId: ownerId, metadata: meta)
            didUpdate = didUpdate || ok
        }

        var response = Totem_V1_TotemUpdateGroupResponse()
        response.success = didUpdate
        response.groupID = groupId
        return response
    }

    // MARK: - UpdateDocument

    func updateDocument(
        request: Totem_V1_TotemUpdateDocumentRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemUpdateDocumentResponse {
        let ownerId = request.ownerID
        let documentId = request.documentID
        var didUpdate = false

        if !request.access.isEmpty,
           let access = TotemRegistry.Access(rawValue: request.access) {
            let ok = await database.updateDocumentAccess(documentId, ownerId: ownerId, access: access)
            didUpdate = didUpdate || ok
        }

        if !request.groupID.isEmpty {
            let group = database.groups(for: ownerId).first { $0.id == request.groupID }
            if let group {
                let ok = await database.updateGroup(group, documentId: documentId, ownerId: ownerId)
                didUpdate = didUpdate || ok
            }
        }

        var response = Totem_V1_TotemUpdateDocumentResponse()
        response.success = didUpdate
        response.documentID = documentId
        return response
    }

    // MARK: - Stats

    func stats(
        request: Totem_V1_TotemStatsRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemStatsResponse {
        guard let registry = database.registry else {
            return Totem_V1_TotemStatsResponse()
        }

        var response = Totem_V1_TotemStatsResponse()
        response.documentCount = Int64(registry.documentOwners.count)
        response.groupCount = Int64(registry.groups.count)
        response.ownerCount = Int64(registry.ownersDocuments.count)
        response.availableDocumentCount = Int64(registry.availableDocumentIds.count)
        return response
    }
}
