//
//  Database+GraphMutations.swift
//  database-server
//
//  Command layer for granular graph editing and per-document re-extraction.
//

import Foundation

extension Database {

    @discardableResult
    func deleteEntity(id: EntityID) async -> EntityID? {
        await tableMutator.mutateGraph(.deleteEntity(id))
    }

    func deleteRelationship(id: RelationshipID) async {
        await tableMutator.mutateGraph(.deleteRelationship(id))
    }

    @discardableResult
    func renameEntity(id: EntityID, newName: String) async -> EntityID? {
        await tableMutator.mutateGraph(.renameEntity(id, newName: newName))
    }

    @discardableResult
    func mergeEntities(from: EntityID, into target: EntityID) async -> EntityID? {
        await tableMutator.mutateGraph(.mergeEntities(from: from, into: target))
    }

    @discardableResult
    func setEntityKind(id: EntityID, kind: String) async -> EntityID? {
        await tableMutator.mutateGraph(.setEntityKind(id, kind: kind))
    }

    func reExtract(
        documentId: DocumentID,
        extractor: any GraphExtracting,
        embedder: any EmbeddingProviding,
        request: DatabaseRequest
    ) async -> Int? {
        let parts: [PartitionData]? = partitionStore(for: documentId).restore()
        let texts = (parts ?? []).map { $0.data }.filter { !$0.isEmpty }
        guard !texts.isEmpty else { return nil }

        // Synthetic put item: extraction + embedding pipeline reused verbatim.
        let item = Database.BatchPutItem(
            id: documentId,
            data: [],
            texts: texts,
            graph: .init(),
            needsExtraction: true
        )
        let enriched = await GraphEnrichment.run(
            items: [item],
            extractor: extractor,
            embedder: embedder,
            existingGraph: graph,
            logger: baseLogger
        )
        guard let result = enriched.first, !result.graph.isEmpty else { return nil }

        await tableMutator.reapplyGraph(
            documentId: documentId,
            payload: result.graph,
            request: request
        )
        return result.graph.entities.count
    }
}
