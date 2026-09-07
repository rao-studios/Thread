import Foundation
import Logging

struct DatabaseConfig {}

actor Database {
    internal let logger: ThreadLogger
    internal let baseLogger: Logger
    nonisolated internal let sinatra: Sinatra
    internal let tableMutator: TableMutator
    internal let registryMutator: RegistryMutator
    let documentCache: DocumentCache

    let nodeId: UUID

    nonisolated(unsafe) var initializationTask: Task<Void, Never>!

    private enum WriteJob {
        case put([Database.BatchPutItem], DatabaseRequest)
        case removeBatch([(documentId: String, ownerId: String)])
        case removeAll(ownerId: String, request: DatabaseRequest, CheckedContinuation<Int, Never>)
    }
    private var pending: [WriteJob] = []
    private var isProcessing = false

    init(nodeId: UUID? = nil, config: DatabaseConfig = DatabaseConfig()) {
        var baseLogger = Logger(label: "thread-logger")
        baseLogger.logLevel = .debug
        self.baseLogger = baseLogger
        self.logger = ThreadLogger(baseLogger)
        self.sinatra = Sinatra(logger: baseLogger)
        self.documentCache = DocumentCache()

        let identity = NodeIdentity.load(override: nodeId, logger: baseLogger)
        self.nodeId = identity.nodeId

        self.tableMutator = TableMutator(nodeId: identity.nodeId, logger: ThreadLogger(baseLogger))
        self.registryMutator = RegistryMutator(nodeId: identity.nodeId, logger: ThreadLogger(baseLogger))
        self.initializationTask = Task { [self] in
            await self.startup()
        }
    }

    func shutdown() async {
        // Drain any pending puts before flushing to disk. shutdown() and drain() share
        // the Database actor; yielding here lets drain() process its queue so
        // flushAllForShutdown() saves the fully up-to-date snapshot.
        while isProcessing || !pending.isEmpty {
            await Task.yield()
        }
        await tableMutator.flushAllForShutdown()
        await registryMutator.flushForShutdown()
    }

    /// Clears this node's entire database — partition table, graph, registry,
    /// and document cache — persisting the empty stores immediately. Shared
    /// content-addressed files under `documents/` are left in place (other
    /// co-located nodes may reference them; re-ingest reuses or rewrites them).
    /// Returns the removed counts for the caller's response.
    func clearAll() async -> (documents: Int, entities: Int) {
        // Drain pending writes first so nothing re-populates after the wipe.
        while isProcessing || !pending.isEmpty {
            await Task.yield()
        }
        let documentCount = table?.keys.count ?? 0
        let entityCount = graph?.entities.count ?? 0
        await tableMutator.clearAll()
        await registryMutator.clearAll()
        documentCache.seed([:])
        logger.info(
            "Clear",
            "🧹 Cleared node database — \(documentCount) document(s), \(entityCount) entity(ies) removed",
            service: .database
        )
        return (documentCount, entityCount)
    }
}

extension Database {
    func startup() async {
        initializeRegistry()
        initializeTable()
    }
}

extension Database {
    nonisolated func user(for id: String) -> Database.User {
        Database.User(groups: groups(for: id))
    }
}

extension Database {
    nonisolated var nonisolatedRegistryMutator: RegistryMutator { registryMutator }
    nonisolated var nonisolatedTableMutator: TableMutator { tableMutator }
}

extension Database {
    private static let maxCoalesceItems = 100

    func enqueuePut(_ items: [Database.BatchPutItem], request: DatabaseRequest) {
        enqueue(.put(items, request))
    }

    func enqueueRemoveBatch(_ items: [(documentId: String, ownerId: String)]) {
        enqueue(.removeBatch(items))
    }

    func removeAll(ownerId: String, request: DatabaseRequest) async -> Int {
        await withCheckedContinuation { continuation in
            enqueue(.removeAll(ownerId: ownerId, request: request, continuation))
        }
    }

    private func enqueue(_ job: WriteJob) {
        pending.append(job)
        guard !isProcessing else { return }
        isProcessing = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            if case .put(let firstItems, let baseReq) = pending[0] {
                var merged   = firstItems
                var consumed = 1
                while consumed < pending.count && merged.count < Self.maxCoalesceItems {
                    guard case .put(let nextItems, let nextReq) = pending[consumed],
                          nextReq.ownerId == baseReq.ownerId,
                          nextReq.group?.id == baseReq.group?.id else { break }
                    merged.append(contentsOf: nextItems)
                    consumed += 1
                }
                pending.removeFirst(consumed)
                await execute(.put(merged, baseReq))
            } else {
                let job = pending.removeFirst()
                await execute(job)
            }
        }
        isProcessing = false
    }

    private func execute(_ job: WriteJob) async {
        switch job {
        case .put(let items, let request):
            await putBatch(items, request: request)
        case .removeBatch(let items):
            await _removeBatch(items: items)
        case .removeAll(let ownerId, let request, let continuation):
            let count = await _removeAll(ownerId: ownerId, request: request)
            continuation.resume(returning: count)
        }
    }
}
