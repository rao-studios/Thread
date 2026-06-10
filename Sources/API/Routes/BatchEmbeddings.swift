import Foundation
import Hummingbird

private struct PreparedInput {
    let index: Int
    let texts: [String]
    let documentId: String
    let tags: [String]
    let name: String?
    let metadata: Data?
}

private struct LinkOnlyInput {
    let documentId: String
    let texts: [String]
    let tags: [String]
}

private struct DocumentEmbed {
    let preparedInput: PreparedInput
    let toEmbed: [String]
    let allTags: [String]
}

func registerBatchEmbeddingsRoute(
    _ app: some RouterMethods<TotemRequestContext>,
    _ database: Database,
    embeddingModelProvider: some EmbeddingProviding
) {
    app.post("/v1/batch/embeddings") { request, context async throws -> EmbeddingBatchResponse in
        let embeddingRequest = try await request.decode(as: EmbeddingBatchRequest.self, context: context)
        let baseReq = embeddingRequest.totem.withRequestID(context.id)
        let databaseReq: DatabaseRequest = baseReq.ownerId.isEmpty
            ? DatabaseRequest(ownerId: "\(database.nodeId.uuidString)-totem", group: baseReq.group, groups: baseReq.groups, tags: baseReq.tags, aggregate: baseReq.aggregate, scope: baseReq.scope, requestID: baseReq.requestID)
            : baseReq
        let logger = database.logger
        let embeddingReqId = "emb-\(UUID().uuidString)"
        let modelName = "mistral-embed"
        let mediaType = embeddingRequest.mediaType ?? .text

        // Remote address not available without RemoteAddressRequestContext; log "unknown" for now.
        let ipAddress: String = "unknown"

        logger.info(
            "Batch Embedding",
            "Received batch embedding request (ID: \(embeddingReqId)) for model: \(embeddingRequest.model ?? "Default") | group: \(embeddingRequest.totem.group?.id ?? "") | ip: \(ipAddress)",
            service: .embedding
        )

        let inputs = embeddingRequest.inputs

        // ── Phase 1: Sanitize + dedup ─────────────────────────────────────────────
        let ownerId = databaseReq.ownerId
        let requestedGroupId = databaseReq.group?.id
        let preprocessResults = try await withThrowingTaskGroup(
            of: (index: Int, texts: [String]?, documentId: String?, linkOnly: Bool).self
        ) { group in
            for (idx, input) in inputs.enumerated() {
                group.addTask {
                    // Slot held for the whole preprocess body; released on every
                    // exit path by withPreprocessSlot (no unstructured release task).
                    await embeddingModelProvider.withPreprocessSlot {
                        let values: [String] = input.values.filter { !$0.isEmpty }

                        let texts: [String]
                        if embeddingRequest.sanitize == true {
                            texts = TextChunker.chunk(values)
                            logger.info("Batch Embedding", "Chunked into \(texts.count) segment(s) (sanitize=true)", service: .embedding)
                        } else {
                            texts = values
                        }

                        guard !texts.isEmpty, texts.allSatisfy({ !$0.isEmpty }) else {
                            logger.info(
                                "Batch Embedding",
                                "⚠️ Dropping input[\(idx)] — all text values are empty (ID: \(embeddingReqId))",
                                service: .embedding
                            )
                            return (idx, nil, nil, false)
                        }

                        let documentId = database.computeHash(from: texts)
                        // Partition table is the single source of truth for "is this document indexed."
                        // registry.doesDocumentExist is NOT used as the skip gate — it can be true
                        // for tombstoned documents (crash victims whose PQ index was lost before the
                        // indices flush), permanently preventing re-indexing under the old check.
                        // table.keys only contains a document after both HNSW nodes and PQ index are
                        // stored (PartitionTable.put inserts keys AFTER indices), so this check is
                        // atomic with respect to a complete, valid index entry.
                        if database.table?.keys.contains(documentId) == true {
                            let registry = database.registry
                            let ownerLinked = registry?.isOwnerLinked(documentId, ownerId: ownerId) ?? true
                            let groupLinked = requestedGroupId.flatMap { gid in
                                registry.map { ($0.documentGroups[documentId]?.contains(gid)) ?? false }
                            } ?? true
                            if !ownerLinked || !groupLinked {
                                logger.info("Batch Embedding", "Document indexed, linking owner/group (ID: \(embeddingReqId))", service: .embedding)
                                return (idx, texts, documentId, true)
                            }
                            logger.info("Batch Embedding", "Document indexed, skipping (ID: \(embeddingReqId))", service: .embedding)
                            return (idx, nil, documentId, false)
                        }
                        return (idx, texts, documentId, false)
                    }
                }
            }

            var results: [(index: Int, texts: [String]?, documentId: String?, linkOnly: Bool)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.index < $1.index }
        }
        var skippedCount = 0
        var failedCount = 0
        var prepared: [PreparedInput] = []
        var linkOnlyItems: [LinkOnlyInput] = []

        for result in preprocessResults {
            if result.linkOnly, let documentId = result.documentId {
                linkOnlyItems.append(LinkOnlyInput(
                    documentId: documentId,
                    texts: result.texts ?? [],
                    tags: embeddingRequest.tags?[result.index] ?? []
                ))
            } else if result.texts != nil, let documentId = result.documentId {
                let docTags = embeddingRequest.tags?[result.index] ?? []
                let docName: String? = {
                    guard let names = embeddingRequest.names, result.index < names.count else { return nil }
                    return names[result.index]
                }()
                prepared.append(PreparedInput(
                    index: result.index,
                    texts: result.texts!,
                    documentId: documentId,
                    tags: docTags,
                    name: docName,
                    metadata: embeddingRequest.metadata?[result.index]
                ))
            } else if result.documentId != nil {
                skippedCount += 1
            } else {
                failedCount += 1
            }
        }

        let groupEnrichedReq: DatabaseRequest = {
            guard var g = databaseReq.group else { return databaseReq }
            let existingTags = g.metadata?.tags ?? []
            let preparedTags = prepared.flatMap { item in
                item.tags.isEmpty ? TagGenerator.generate(from: item.texts) : item.tags
            }
            let linkOnlyTags = linkOnlyItems.flatMap { item in
                item.tags.isEmpty ? TagGenerator.generate(from: item.texts) : item.tags
            }
            let mergedTags = Array(Set(existingTags + preparedTags + linkOnlyTags)).sorted()
            guard !mergedTags.isEmpty else { return databaseReq }
            var meta = g.metadata ?? Database.Group.Metadata()
            meta.tags = mergedTags
            g.metadata = meta
            return DatabaseRequest(ownerId: databaseReq.ownerId, group: g,
                               groups: databaseReq.groups, tags: databaseReq.tags,
                               aggregate: databaseReq.aggregate, scope: databaseReq.scope,
                               requestID: databaseReq.requestID)
        }()

        if !linkOnlyItems.isEmpty {
            await database.linkOwnerBatch(
                documentIds: linkOnlyItems.map { $0.documentId },
                request: groupEnrichedReq
            )
        }

        // ── Phase 2: Generate tags + embed texts ─────────────────────────────────
        var totalPromptTokens = 0

        if !prepared.isEmpty {
            let docEmbeds: [DocumentEmbed] = prepared.map { item in
                let allTags = item.tags.isEmpty
                    ? TagGenerator.generate(from: item.texts)
                    : item.tags
                var toEmbed = item.texts
                toEmbed.append(allTags.joined(separator: " "))
                return DocumentEmbed(preparedInput: item, toEmbed: toEmbed, allTags: allTags)
            }

            let allToEmbed = docEmbeds.flatMap { $0.toEmbed }
            let embedCounts = docEmbeds.map { $0.toEmbed.count }

            logger.debug(
                "Batch Embedding",
                "Processing \(prepared.count) document(s), \(allToEmbed.count) string(s) for embedding (ID: \(embeddingReqId)). Batch size: \(embeddingRequest.batchSize ?? allToEmbed.count), Format: \(embeddingRequest.encodingFormat ?? "float")",
                service: .embedding
            )

            let (allEmbeddings, usage) = try await embeddingModelProvider.run(
                allToEmbed, logger: context.logger, priority: false
            )
            totalPromptTokens += usage.promptTokens

            let sortedEmbeddings = allEmbeddings.sorted { $0.index < $1.index }

            // ── Phase 3: Build BatchPutItems ──────────────────────────────────────
            var batchItems: [Database.BatchPutItem] = []
            batchItems.reserveCapacity(prepared.count)
            var offset = 0
            for (i, docEmbed) in docEmbeds.enumerated() {
                let count = embedCounts[i]
                let slice = sortedEmbeddings[offset ..< (offset + count)]

                let partitionEmbeddings: [EmbeddingData] = Array(slice.dropLast()).enumerated()
                    .map { EmbeddingData(embedding: $0.element.embedding, index: $0.offset) }
                let tagsEmbedding: [Float]?
                if case .floats(let v) = slice.last?.embedding { tagsEmbedding = v } else { tagsEmbedding = nil }

                batchItems.append(Database.BatchPutItem(
                    id: docEmbed.preparedInput.documentId,
                    data: partitionEmbeddings,
                    texts: docEmbed.preparedInput.texts,
                    tags: docEmbed.allTags,
                    tagsEmbedding: tagsEmbedding,
                    mediaType: mediaType,
                    update: embeddingRequest.update,
                    name: docEmbed.preparedInput.name,
                    metadata: docEmbed.preparedInput.metadata
                ))
                offset += count
            }

            for item in batchItems {
                logger.info(
                    "Batch Embedding",
                    "Enqueuing for index (docId: \(item.id), partitions: \(item.data.count))",
                    service: .embedding,
                    flow: .embed(documentId: item.id)
                )
            }

            let capturedReq = groupEnrichedReq
            let capturedItems = batchItems
            Task.detached(priority: .userInitiated) {
                await database.enqueuePut(capturedItems, request: capturedReq)
            }
        }

        let totalEmbeds = prepared.count + skippedCount + linkOnlyItems.count
        let success = totalEmbeds == inputs.count
        let usageData = UsageData(prompt_tokens: totalPromptTokens, total_tokens: totalPromptTokens)

        return EmbeddingBatchResponse(
            model: modelName,
            usage: success ? usageData : .empty,
            success: success,
            user: database.user(for: databaseReq.ownerId)
        )
    }
}
