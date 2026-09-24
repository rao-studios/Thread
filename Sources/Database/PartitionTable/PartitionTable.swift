//
//  PartitionTable.swift
//  database-server
//
//  Created by Ritesh Pakala on 11/15/25.
//

import Foundation

typealias PartitionSearchResult = (scores: [Float], partitions: [Database.Partition])

struct GraphSearchTrace {
    var matchedEntityIds: [EntityID] = []
    var matchedRelationshipIds: [RelationshipID] = []
    var matchedPredicateIds: [PredicateID] = []
    var expansionEdges: [RelationshipID] = []
    var expandedDocumentCount: Int = 0
    /// Stored names of `matchedEntityIds`, parallel by index.
    var matchedEntityNames: [String] = []
    /// The media type the search applied; empty when the request named none.
    var mediaType: String = ""
    /// Documents whose distance the code instrument lowered.
    var boostedDocumentCount: Int = 0
}

/// A table stores documents as per-document PQ indices. Vector search is a parallel ADC
/// linear scan over the candidate documents; there is no HNSW graph, no sharding, and no WAL.
///
struct PartitionTable: Codable {
    /// All indexed document IDs.
    var keys: Set<DocumentID> = []
    /// Per-document PQ indices, keyed by document ID.
    var indices: [DocumentID: PartitionIndex] = [:]

    init() {}

    // MARK: - Index access

    func index(for docId: DocumentID) -> PartitionIndex? { indices[docId] }

    // MARK: - Mutations

    /// Puts a document and its partitions into the table, training a fresh PQ index.
    /// Partitions with empty embeddings are skipped; a document with none is not indexed
    /// (regression guard: a phantom index with no scorable slots would also poison the
    /// dedup gate against re-ingesting the document).
    mutating func put(id: DocumentID,
                      partitions: [Database.Partition],
                      entityIds: [EntityID] = [],
                      metadata: Data? = nil,
                      request: DatabaseRequest,
                      logger: ThreadLogger) {
        let valid = partitions.filter { !$0.embedding.isEmpty }
        guard !valid.isEmpty else {
            logger.warning(
                "PartitionTable.put: no partitions with embeddings for \(id) — skipping index creation",
                service: .database,
                request: request,
                flow: .embed(documentId: id)
            )
            return
        }
        var index = PartitionIndex()
        index.train(valid, entityIds: entityIds, documentId: id, logger: logger)
        index.metadata = metadata
        indices[id] = index
        keys.insert(id)
    }

    /// Removes a document's index.
    mutating func remove(id: DocumentID) {
        keys.remove(id)
        indices.removeValue(forKey: id)
    }

    // MARK: - Search

    func search(embedding: [Float],
                matchedEntityIds: Set<EntityID> = [],
                matchedRelationshipIds: Set<RelationshipID> = [],
                matchedPredicateIds: Set<PredicateID> = [],
                identifierScores: [EntityID: Float] = [:],
                graph: GraphStore? = nil,
                expand: Bool = true,
                k: Int = 3,
                sinatra: Sinatra,
                registry: ThreadRegistry,
                request: DatabaseRequest,
                metadataLoader: PartitionDataLoader? = nil,
                logger: ThreadLogger)
        -> (partitions: [PartitionSearchResult], adjustments: [SinatraAdjustment], trace: GraphSearchTrace?) {

        var aggregated: [PartitionSearchResult] = []
        var adjustments: [SinatraAdjustment] = []
        let sinatraRegistry = sinatra.registry
        let startTime = Date()

        let ownerKey = ThreadRegistry.Owner(id: request.ownerId)

        var candidateIds: Set<DocumentID>
        var scopedIds: Set<DocumentID>?
        switch request.scope {
        case .global:
            candidateIds = registry.availableDocumentIds.union(
                Set(registry.ownersDocuments[ownerKey] ?? [])
            )
        default:
            if request.aggregate == true {
                candidateIds = Set(registry.ownersDocuments[ownerKey] ?? [])
            } else if let gs = request.groups, !gs.isEmpty {
                candidateIds = Set(gs.flatMap { registry.groups[$0.id] ?? [] })
                scopedIds = candidateIds
            } else if let groupId = request.group?.id {
                candidateIds = Set(registry.groups[groupId] ?? [])
            } else {
                candidateIds = Set(registry.ownersDocuments[ownerKey] ?? [])
            }
        }

        // The prose instrument gates: only documents linked to what matched are scanned.
        // The code instrument never gates — a match is evidence, not a precondition — so
        // a memory or a card that names nothing is still ranked by its distance.
        if !request.isCode {
            if let graph, !matchedRelationshipIds.isEmpty {
                candidateIds.formIntersection(graph.documents(linkedToRelationships: matchedRelationshipIds))
            } else if !matchedEntityIds.isEmpty {
                let entityDocuments = Set(indices.compactMap { docId, index in
                    Set(index.entityIds).isDisjoint(with: matchedEntityIds) ? nil : docId
                })
                candidateIds.formIntersection(entityDocuments)
            }
        }

        // Code: every document an identifier names gets its distance lowered, the more
        // identifiers the further, down to a floor.
        var boost: [DocumentID: Float] = [:]
        if request.isCode, let graph, !identifierScores.isEmpty {
            var weight: [DocumentID: Float] = [:]
            for (entityId, score) in identifierScores {
                for docId in graph.entities[entityId]?.documentIds ?? [] where candidateIds.contains(docId) {
                    weight[docId, default: 0] += score
                }
            }
            boost = weight.mapValues { max(Self.identifierBoostFloor, pow(Self.identifierBoostStep, $0)) }
        }

        let directResults = scan(candidateIds, embedding: embedding, k: k, sinatra: sinatra,
                                 sinatraRegistry: sinatraRegistry, registry: registry,
                                 request: request, metadataLoader: metadataLoader, logger: logger)
        for (result, adjustment) in directResults {
            var result = result
            if let docId = result.partitions.first?.documentId, let factor = boost[docId] {
                result.scores = result.scores.map { $0 * factor }
            }
            aggregated.append(result)
            if let adjustment { adjustments.append(adjustment) }
        }

        let orderedEntityIds = Array(matchedEntityIds)
        func makeTrace(expansionEdges: [RelationshipID] = [], expandedDocumentCount: Int = 0) -> GraphSearchTrace {
            GraphSearchTrace(
                matchedEntityIds: orderedEntityIds,
                matchedRelationshipIds: Array(matchedRelationshipIds),
                matchedPredicateIds: Array(matchedPredicateIds),
                expansionEdges: expansionEdges,
                expandedDocumentCount: expandedDocumentCount,
                matchedEntityNames: orderedEntityIds.map { graph?.entities[$0]?.name ?? "" },
                mediaType: request.mediaType?.rawValue ?? "",
                boostedDocumentCount: boost.count
            )
        }
        // A code search always says what it applied, even when nothing matched: that echo
        // is how a client tells this node from one that ignored the spec.
        var trace: GraphSearchTrace? = (matchedEntityIds.isEmpty && matchedRelationshipIds.isEmpty && !request.isCode)
            ? nil
            : makeTrace()
        // Expansion reaches whatever the result documents' entities touch; for code that is
        // every file importing the same module, so the code instrument does not expand.
        if expand, !request.isCode, let graph, !graph.entities.isEmpty {
            let resultDocs = Set(aggregated.flatMap { $0.partitions.map { $0.documentId } })
            var seedEntities = matchedEntityIds.union(graph.endpointIds(for: matchedRelationshipIds))
            for docId in resultDocs {
                if let idx = index(for: docId) { seedEntities.formUnion(idx.entityIds) }
            }
            if !seedEntities.isEmpty {
                let (nbrEntities, nbrEdges) = graph.neighborhood(of: seedEntities, hops: 1)
                var accessible = registry.availableDocumentIds.union(
                    Set(registry.ownersDocuments[ownerKey] ?? [])
                )
                if let scopedIds { accessible.formIntersection(scopedIds) }
                let neighborDocs = graph.documents(linkedToEntities: nbrEntities)
                    .subtracting(resultDocs)
                    .intersection(accessible)
                // Rank neighbor docs by summed incident-edge weight, take up to 2*k.
                let rankedNeighbors = neighborDocs.sorted { a, b in
                    edgeWeight(for: a, graph: graph, edges: nbrEdges) >
                    edgeWeight(for: b, graph: graph, edges: nbrEdges)
                }.prefix(2 * k)

                let expansionPenalty: Float = 1.1
                var expandedScores: [Float] = []
                var expandedPartitions: [Database.Partition] = []
                var seenPartitionIds = Set(aggregated.flatMap { $0.partitions.map { $0.id } })
                for docId in rankedNeighbors {
                    guard let idx = index(for: docId),
                          let best = idx.searchWithScores(queryEmbedding: embedding, k: 1,
                                                          metadataLoader: metadataLoader).first,
                          seenPartitionIds.insert(best.0.id).inserted else { continue }
                    expandedScores.append(best.1 * expansionPenalty)
                    expandedPartitions.append(best.0)
                }
                if !expandedPartitions.isEmpty {
                    aggregated.append((scores: expandedScores, partitions: expandedPartitions))
                }
                trace = makeTrace(expansionEdges: Array(nbrEdges), expandedDocumentCount: expandedPartitions.count)
            }
        }

        // A named media type keeps only its own partitions. The scan has already read
        // each partition's type, so this costs nothing; without a loader the type is
        // unknown and nothing is dropped.
        if let wanted = request.mediaType, metadataLoader != nil {
            aggregated = aggregated.compactMap { block in
                let kept = zip(block.scores, block.partitions).filter { $0.1.mediaType == wanted }
                return kept.isEmpty ? nil : (scores: kept.map(\.0), partitions: kept.map(\.1))
            }
        }

        // One ranking for the whole search, closest first, cut at top_k when one was asked.
        aggregated = Self.ranked(aggregated, limit: request.resultLimit)

        let elapsedTime = Date().timeIntervalSince(startTime) * 1000
        let totalPartitions = aggregated.reduce(0) { $0 + $1.partitions.count }
        logger.info(
            "Table Search",
            "Search completed in \(String(format: "%.1f", elapsedTime))ms — \(totalPartitions) partitions retrieved",
            service: .database,
            request: request,
            flow: .chat
        )

        if !adjustments.isEmpty {
            let totalAdjusted = adjustments.reduce(0) { $0 + $1.partitionCount }
            let details = adjustments.map { "\($0.original) → \($0.inferred)" }.joined(separator: " | ")
            logger.info(
                "Infer",
                "⚜️ Adjusted \(totalAdjusted) partitions across \(adjustments.count) indices — distances: \(details)",
                service: .sinatra,
                request: request,
                externalOnly: true,
                flow: .chat
            )
        }

        return (aggregated, adjustments, trace)
    }

    // MARK: - Ranking

    /// One identifier multiplies a document's distance by this; each further one again.
    static let identifierBoostStep: Float = 0.85
    /// However many identifiers name a document, its distance keeps at least this share.
    static let identifierBoostFloor: Float = 0.6

    /// Every block flattened into one, ascending by distance, ties in arrival order, cut
    /// at `limit`.
    static func ranked(_ blocks: [PartitionSearchResult], limit: Int?) -> [PartitionSearchResult] {
        var all = blocks.flatMap { zip($0.scores, $0.partitions) }.enumerated().map { ($0.offset, $0.element) }
        all.sort { lhs, rhs in
            lhs.1.0 == rhs.1.0 ? lhs.0 < rhs.0 : lhs.1.0 < rhs.1.0
        }
        if let limit { all = Array(all.prefix(limit)) }
        guard !all.isEmpty else { return [] }
        return [(scores: all.map { $0.1.0 }, partitions: all.map { $0.1.1 })]
    }

    // MARK: - Private

    /// Parallel per-document ADC scan over a candidate set.
    private func scan(_ candidateIds: Set<DocumentID>,
                      embedding: [Float],
                      k: Int,
                      sinatra: Sinatra,
                      sinatraRegistry: SinatraRegistry?,
                      registry: ThreadRegistry,
                      request: DatabaseRequest,
                      metadataLoader: PartitionDataLoader?,
                      logger: ThreadLogger) -> [(PartitionSearchResult, SinatraAdjustment?)] {
        let candidateArray = Array(candidateIds)
        var raw = [(PartitionSearchResult, SinatraAdjustment?)?](repeating: nil, count: candidateArray.count)
        let tableSnapshot = self
        let sendableLoader = SendableValue(metadataLoader)
        raw.withUnsafeMutableBufferPointer { buffer in
            let sendableBuffer = SendableValue(buffer)
            DispatchQueue.concurrentPerform(iterations: candidateArray.count) { i in
                let id = candidateArray[i]
                guard let index = tableSnapshot.index(for: id) else { return }
                sendableBuffer.value[i] = index.search(
                    queryEmbedding: embedding,
                    k: k,
                    sinatra: sinatra,
                    sinatraRegistry: sinatraRegistry,
                    documentStats: registry.documentStats,
                    request: request,
                    metadataLoader: sendableLoader.value,
                    logger: logger
                )
            }
        }
        return raw.compactMap { $0 }
    }

    private func edgeWeight(for docId: DocumentID, graph: GraphStore, edges: Set<RelationshipID>) -> Int {
        edges.reduce(0) { sum, rid in
            guard let rel = graph.relationships[rid], rel.documentIds.contains(docId) else { return sum }
            return sum + rel.weight
        }
    }
}
