import Conduit
import Foundation
import GRPCCore

final class ThreadUpdateServiceImpl: Sendable {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    // MARK: - UpdateGroup

    func updateGroup(
        request: Thread_V1_ThreadUpdateGroupRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Thread_V1_ThreadUpdateGroupResponse {
        let ownerId = request.ownerID
        let groupId = request.groupID
        var didUpdate = false

        if !request.access.isEmpty,
           let access = ThreadRegistry.Access(rawValue: request.access) {
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

        var response = Thread_V1_ThreadUpdateGroupResponse()
        response.success = didUpdate
        response.groupID = groupId
        return response
    }

    // MARK: - UpdateDocument

    func updateDocument(
        request: Thread_V1_ThreadUpdateDocumentRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Thread_V1_ThreadUpdateDocumentResponse {
        let ownerId = request.ownerID
        let documentId = request.documentID
        var didUpdate = false

        if !request.access.isEmpty,
           let access = ThreadRegistry.Access(rawValue: request.access) {
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

        var response = Thread_V1_ThreadUpdateDocumentResponse()
        response.success = didUpdate
        response.documentID = documentId
        return response
    }

    // MARK: - Stats

    func stats(
        request: Thread_V1_ThreadStatsRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Thread_V1_ThreadStatsResponse {
        guard let registry = database.registry else {
            return Thread_V1_ThreadStatsResponse()
        }

        var response = Thread_V1_ThreadStatsResponse()
        response.documentCount = Int64(registry.documentOwners.count)
        response.groupCount = Int64(registry.groups.count)
        response.ownerCount = Int64(registry.ownersDocuments.count)
        response.availableDocumentCount = Int64(registry.availableDocumentIds.count)
        return response
    }
}
