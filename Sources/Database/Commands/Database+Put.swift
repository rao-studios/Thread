import Foundation
import Logging

extension Database {
    struct BatchPutItem {
        let id: String
        let data: [EmbeddingData]
        let texts: [String]
        let tags: [String]
        let tagsEmbedding: [Float]?
        let mediaType: MediaType
        let update: DatabaseUpdate?
        let name: String?
        let metadata: Data?
    }
}

extension Database {
    func put(_ key: String, document: Database.Document) {
        let storage = FilePersistence(key: key, kind: .basic, logger: logger.base)
        storage.save(state: document)
    }

    @discardableResult
    func put(id: String,
             data: [EmbeddingData],
             texts: [String],
             tags: [String] = [],
             tagsEmbedding: [Float]? = nil,
             mediaType: MediaType = .text,
             update: DatabaseUpdate? = nil,
             name: String? = nil,
             metadata: Data? = nil,
             request: DatabaseRequest) async -> Database.Document {
        let storage = documentStore(for: id)
        var partitions: [Database.Partition] = []

        for (i, d) in data.enumerated() {
            guard case let .floats(array) = d.embedding, !array.isEmpty else { continue }
            partitions.append(Database.Partition(
                id: computeNumericHash(from: array, documentId: id),
                documentId: id,
                url: storage.url,
                embedding: array,
                mediaType: mediaType,
                text: texts[i],
                ownerId: request.ownerId
            ))
        }

        let document = Database.Document(id: id, url: storage.url, ownerId: request.ownerId, name: name)
        storage.save(state: document)
        documentCache.cache(document)

        await register(document, group: request.group, update: update, ownerId: request.ownerId)
        logger.info("Put", "Registered document (docId: \(id), partitions: \(partitions.count))", service: .embedding, request: request, flow: .embed(documentId: id))
        await index(id: id, partitions: partitions, tags: tags, tagsEmbedding: tagsEmbedding, metadata: metadata, request: request)
        logger.info("Put", "Indexed document (docId: \(id)) → partition table + HNSW", service: .embedding, request: request, flow: .embed(documentId: id))

        return document
    }

    func linkOwner(documentId: String, request: DatabaseRequest) async {
        await registryMutator.linkOwner(documentId: documentId, group: request.group, ownerId: request.ownerId)
        logger.info("Link Owner", "Linked owner \(request.ownerId) to existing document (docId: \(documentId))", service: .embedding, request: request, flow: .embed(documentId: documentId))
    }

    func linkOwnerBatch(documentIds: [String], request: DatabaseRequest) async {
        guard !documentIds.isEmpty else { return }
        let items = documentIds.map { (documentId: $0, group: request.group, ownerId: request.ownerId) }
        await registryMutator.linkOwnerBatch(items: items)
        logger.info("Link Owner Batch", "Linked owner \(request.ownerId) to \(documentIds.count) existing document(s)", service: .embedding, request: request)
    }

    func putBatch(_ items: [BatchPutItem], request: DatabaseRequest) async {
        logger.info(
            "Put Batch",
            "Starting batch index (\(items.count) doc(s), \(items.reduce(0) { $0 + $1.data.count }) partition(s))",
            service: .embedding, request: request
        )

        struct Prepared {
            let document: Database.Document
            let partitions: [Database.Partition]
            let update: DatabaseUpdate?
        }

        var prepared: [Prepared] = []
        prepared.reserveCapacity(items.count)

        for item in items {
            let storage = documentStore(for: item.id)
            let partitions: [Database.Partition] = item.data.enumerated().compactMap { i, d in
                guard case let .floats(array) = d.embedding, !array.isEmpty else { return nil }
                return Database.Partition(
                    id: computeNumericHash(from: array, documentId: item.id),
                    documentId: item.id,
                    url: storage.url,
                    embedding: array,
                    mediaType: item.mediaType,
                    text: item.texts[i],
                    ownerId: request.ownerId
                )
            }
            let document = Database.Document(id: item.id, url: storage.url, ownerId: request.ownerId, name: item.name)
            prepared.append(Prepared(document: document, partitions: partitions, update: item.update))
        }

        // Persist document + partition-content files in a bounded parallel task
        // group, off this actor, BEFORE indexing — the `documents/{id}-parts`
        // file must be durable before the document becomes searchable (the
        // search path resolves partition text from it), and TableMutator is told
        // below (persistPartitionData: false) not to repeat these writes.
        let loggerBase = logger.base
        await withTaskGroup(of: Void.self) { group in
            let writeWidth = 8
            var inFlight = 0
            for item in prepared {
                if inFlight >= writeWidth {
                    await group.next()
                    inFlight -= 1
                }
                let document = item.document
                let partitionData = item.partitions.map { PartitionData(from: $0) }
                group.addTask {
                    FilePersistence(key: "documents/\(document.id)", kind: .basic, logger: loggerBase)
                        .save(state: document)
                    FilePersistence(key: "documents/\(document.id)-parts", kind: .basic, logger: loggerBase)
                        .save(state: partitionData)
                }
                inFlight += 1
            }
        }

        documentCache.cacheBatch(prepared.map { $0.document })

        await registryMutator.registerBatch(
            items: prepared.map { ($0.document, request.group, request.ownerId) }
        )

        var removedIds = Set<String>()
        for item in prepared {
            if let update = item.update,
               update.operation == .remove,
               removedIds.insert(update.documentId).inserted {
                await remove(documentId: update.documentId, group: request.group, ownerId: request.ownerId)
            }
        }

        let indexItems = prepared
        let batchItems: [(id: DocumentID, partitions: [Database.Partition], tags: [String], tagsEmbedding: [Float]?, metadata: Data?, request: DatabaseRequest)] = zip(indexItems, items).map { prepared, item in
            (prepared.document.id, prepared.partitions, item.tags, item.tagsEmbedding, item.metadata, request)
        }
        // Parts files were pre-written above — skip the per-document synchronous
        // plist writes on the TableMutator actor.
        await tableMutator.putBatch(items: batchItems, persistPartitionData: false)

        for item in prepared {
            logger.info(
                "Put Batch",
                "Indexed document (docId: \(item.document.id), partitions: \(item.partitions.count)) → partition table + HNSW",
                service: .embedding,
                request: request,
                flow: .embed(documentId: item.document.id)
            )
        }
    }
}
