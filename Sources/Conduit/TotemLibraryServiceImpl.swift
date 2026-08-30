import Conduit
import Foundation
import GRPCCore
import GRPCProtobuf

final class TotemLibraryServiceImpl: Totem_V1_TotemLibrary.SimpleServiceProtocol, Sendable {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    func library(
        request: Totem_V1_TotemLibraryRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemLibraryResponse {
        database.logger.info(nil, "libraryRequest — owner: \(request.ownerID) totem: \(request.totemID)")

        // Fast path: document_ids provided — use reverse map, no full library scan
        if !request.documentIds.isEmpty {
            guard let registry = database.registry else {
                return Totem_V1_TotemLibraryResponse()
            }
            let requestedIds = Set(request.documentIds)
            var groupIdSet = Set<String>()
            for docId in requestedIds {
                for groupId in registry.documentGroups[docId] ?? [] {
                    groupIdSet.insert(groupId)
                }
            }
            let matchedGroups = groupIdSet.compactMap {
                database.buildGroup(groupId: $0, registry: registry)
            }
            var resp = Totem_V1_TotemLibraryResponse()
            resp.groups = matchedGroups.map(toProto)
            return resp
        }

        // Standard path: slice on lightweight entries first, build documents only for the page
        guard let registry = database.registry else {
            return Totem_V1_TotemLibraryResponse()
        }

        let entries = database.groupEntries(for: request.ownerID)  // pre-sorted by ID
        let cursor  = request.afterID
        let limit   = request.limit > 0 ? Int(request.limit) : 0

        // Binary search for the first entry past the cursor — O(log n).
        var startIndex = 0
        if !cursor.isEmpty {
            var lo = 0, hi = entries.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if entries[mid].id <= cursor { lo = mid + 1 } else { hi = mid }
            }
            startIndex = lo
        }

        let needed = limit > 0 ? limit + 1 : Int.max

        var page: [Database.Group]
        if request.includeAvailable {
            // Deduplicate available entries against the sorted owner list via binary search
            // (avoids a full Set<String> over all owner groups).
            // Sort the small available slice, then lazy-merge with the owner slice.
            let sortedAvailable = database.availableGroupEntries()
                .filter { e in (cursor.isEmpty || e.id > cursor) && !binaryContains(entries, id: e.id) }
                .sorted { $0.id < $1.id }
            page = sortedMerge(entries, from: startIndex, available: sortedAvailable, limit: needed)
        } else {
            page = Array(entries[startIndex...].prefix(needed))
        }

        var hasMore = false
        if limit > 0 {
            hasMore = page.count > limit
            page = Array(page.prefix(limit))
        }

        let groups = page.compactMap { database.buildGroup(entry: $0, registry: registry) }

        var resp = Totem_V1_TotemLibraryResponse()
        resp.hasMore_p = hasMore
        resp.groups = groups.map(toProto)
        return resp
    }

    /// Full document content by id: the partition texts from
    /// `documents/{id}-parts`, reassembled in stored order (there is no other
    /// content store). Access mirrors search/graph — caller-owned or publicly
    /// available; anything else is silently omitted.
    func documents(
        request: Totem_V1_TotemDocumentsRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemDocumentsResponse {
        database.logger.info(nil, "documentsRequest — owner: \(request.ownerID) ids: \(request.documentIds.count)")
        var resp = Totem_V1_TotemDocumentsResponse()
        guard let registry = database.registry else { return resp }
        for documentId in request.documentIds {
            if let content = assembleContent(
                documentId: documentId, ownerID: request.ownerID, registry: registry)
            {
                resp.documents.append(content)
            }
        }
        return resp
    }

    func exportCorpus(
        request: Totem_V1_TotemExportCorpusRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_TotemExportCorpusResponse {
        database.logger.info(
            nil,
            "exportCorpus — owner: \(request.ownerID) groups: \(request.groupIds.count) prefix: \(request.documentIDPrefix)")
        var resp = Totem_V1_TotemExportCorpusResponse()
        guard let registry = database.registry else { return resp }

        let wantedGroups: Set<String>? = request.groupIds.isEmpty ? nil : Set(request.groupIds)
        var ids = Set<String>()
        for entry in database.groupEntries(for: request.ownerID) {
            if let wantedGroups, !wantedGroups.contains(entry.id) { continue }
            for documentId in registry.groups[entry.id] ?? [] {
                if !request.documentIDPrefix.isEmpty,
                   !documentId.hasPrefix(request.documentIDPrefix)
                {
                    continue
                }
                ids.insert(documentId)
            }
        }
        var sorted = ids.sorted()
        if !request.afterID.isEmpty {
            sorted = sorted.filter { $0 > request.afterID }
        }
        let limit = request.limit > 0 ? Int(request.limit) : sorted.count
        let hasMore = sorted.count > limit
        let page = Array(sorted.prefix(limit))
        for documentId in page {
            if let content = assembleContent(
                documentId: documentId, ownerID: request.ownerID, registry: registry)
            {
                resp.documents.append(content)
            }
        }
        resp.hasMore_p = hasMore
        return resp
    }

    private func assembleContent(
        documentId: String, ownerID: String, registry: TotemRegistry
    ) -> Totem_V1_TotemDocumentContent? {
        guard registry.isOwnerLinked(documentId, ownerId: ownerID)
                || registry.availableDocumentIds.contains(documentId) else {
            return nil
        }
        guard let parts = database.partitionDatas(for: documentId), !parts.isEmpty else {
            return nil
        }

        var content = Totem_V1_TotemDocumentContent()
        content.id = documentId
        content.texts = parts.map(\.data)
        content.mediaType = parts.first?.mediaType.rawValue ?? MediaType.text.rawValue

        if let document = database.document(for: documentId) {
            content.name = document.name ?? ""
            content.ownerID = document.ownerId
            content.createdAt = Int64(document.createdAt.timeIntervalSince1970)
        } else {
            content.ownerID = parts.first?.ownerId ?? ""
        }

        let groupId = registry.ownerDocumentGroup[ownerID]?[documentId]
            ?? registry.documentGroups[documentId]?.sorted().first
        if let groupId {
            content.groupID = groupId
            if let groupOwner = registry.groupOwners[groupId],
               let entry = registry.ownersGroups[groupOwner]?.first(where: { $0.id == groupId }) {
                content.groupLabel = entry.label
            }
        }
        return content
    }
}

private func binaryContains(_ entries: [Database.Group], id: String) -> Bool {
    var lo = 0, hi = entries.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if entries[mid].id < id { lo = mid + 1 }
        else if entries[mid].id > id { hi = mid }
        else { return true }
    }
    return false
}

private func sortedMerge(
    _ owner: [Database.Group], from start: Int,
    available: [Database.Group],
    limit: Int
) -> [Database.Group] {
    var result: [Database.Group] = []
    var oi = start, ai = 0
    while result.count < limit {
        let hasO = oi < owner.count, hasA = ai < available.count
        guard hasO || hasA else { break }
        if hasO && (!hasA || owner[oi].id < available[ai].id) {
            result.append(owner[oi]); oi += 1
        } else {
            result.append(available[ai]); ai += 1
        }
    }
    return result
}

private func toProto(_ g: Database.Group) -> Totem_V1_TotemGroup {
    var pg = Totem_V1_TotemGroup()
    pg.id = g.id
    pg.label = g.label
    pg.ownerID = g.ownerId
    pg.access = g.access?.rawValue ?? ""
    pg.totalEarnings = g.totalEarnings ?? 0
    pg.groupDescription = g.metadata?.description ?? ""
    pg.tags = g.metadata?.tags ?? []
    pg.documents = g.documents.map { doc in
        var pd = Totem_V1_TotemDocument()
        pd.id = doc.id
        pd.url = doc.url.absoluteString
        pd.ownerID = doc.ownerId
        pd.name = doc.name ?? ""
        pd.createdAt = Int64(doc.createdAt.timeIntervalSince1970)
        return pd
    }
    return pg
}
