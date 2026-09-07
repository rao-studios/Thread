//
//  Flow8_IndexQueueTests.swift
//  database-serverTests
//
//  Tests for the serialised index-write queue and TableMutator basics:
//
//    TableMutator
//      • replace() atomically supersedes any pending debounced flush
//      • remove() detaches the document from table + graph
//
//    IndexQueue — FIFO serialisation (integration, uses real Database)
//      • enqueuePut items appear in snapshot once the queue drains
//      • put → enqueueRemoveBatch ordering leaves document absent from registry
//      • Multiple concurrent enqueuePuts are all committed
//      • removeAll awaits completion and returns an accurate removed count
//      • removeAll for an owner with no documents returns 0
//

import XCTest
@testable import thread

final class Flow8_IndexQueueTests: XCTestCase {

    // =========================================================================
    // MARK: - Section 1: TableMutator basics
    // =========================================================================

    func testReplaceUpdatesSnapshotAtomically() async throws {
        let mutator = TableMutator.test()
        mutator.seed(PartitionTable())

        let p = Database.Partition.test(id: "p0", documentId: "before",
                                    embedding: VectorFixtures.random(seed: 6000))
        await mutator.put(id: "before", partitions: [p], request: .test())

        var replacement = PartitionTable()
        let newP = Database.Partition.test(id: "p1", documentId: "after",
                                       embedding: VectorFixtures.random(seed: 6001))
        replacement.put(id: "after", partitions: [newP], request: .test(), logger: .test)
        await mutator.replace(with: replacement)

        let snap = mutator.snapshot
        XCTAssertTrue(snap?.keys.contains("after") ?? false,
            "replace() must make the new table visible immediately")
        XCTAssertFalse(snap?.keys.contains("before") ?? true,
            "replace() must discard the previous table entirely")
    }

    func testRemoveDetachesGraphProvenance() async throws {
        let mutator = TableMutator.test()
        mutator.seed(PartitionTable())
        mutator.seedGraph(GraphStore())

        let p = Database.Partition.test(id: "p0", documentId: "doc0",
                                    embedding: VectorFixtures.random(seed: 6100))
        let graph = Database.GraphPayload(entities: [.init(name: "Ada Lovelace", kind: "person")])
        await mutator.put(id: "doc0", partitions: [p], graph: graph, request: .test())

        XCTAssertEqual(mutator.graphSnapshot?.entities.count, 1,
            "put must upsert the document's entities into the graph store")

        await mutator.remove(id: "doc0")

        XCTAssertFalse(mutator.snapshot?.keys.contains("doc0") ?? true,
            "remove must delete the document's table entry")
        XCTAssertEqual(mutator.graphSnapshot?.entities.count, 0,
            "remove must garbage-collect entities whose provenance became empty")
    }

    // =========================================================================
    // MARK: - Section 2: IndexQueue — FIFO ordering and serialisation
    // =========================================================================

    private func makeDatabase() async -> Database {
        // Wipe stale persistence files BEFORE constructing Database so that
        // the background init task completes without racing against test puts.
        wipeThreadPersistenceFiles()
        let database = Database()
        await database.initializationTask.value
        addTeardownBlock { wipeThreadPersistenceFiles() }
        return database
    }

    func testEnqueuePutItemAppearsInRegistryAfterDrain() async {
        let database = await makeDatabase()

        let item = Database.BatchPutItem(
            id: "iq-doc1",
            data: [EmbeddingData(embedding: .floats(VectorFixtures.random(seed: 20000)), index: 0)],
            texts: ["queue put test"]
        )
        await database.enqueuePut([item], request: .test(ownerId: "iq-owner"))
        _ = await database.removeAll(ownerId: "nonexistent-barrier-owner", request: .test())

        let registry = database.registry
        XCTAssertNotNil(registry?.documentOwners["iq-doc1"],
            "enqueuePut must register the document before the queue unblocks removeAll")
    }

    func testEnqueuePutItemAppearsInTableSnapshotAfterDrain() async {
        let database = await makeDatabase()

        let item = Database.BatchPutItem(
            id: "iq-table-doc",
            data: [EmbeddingData(embedding: .floats(VectorFixtures.random(seed: 20100)), index: 0)],
            texts: ["table snapshot test"]
        )
        await database.enqueuePut([item], request: .test(ownerId: "iq-table-owner"))
        _ = await database.removeAll(ownerId: "barrier", request: .test())

        XCTAssertTrue(database.table?.keys.contains("iq-table-doc") ?? false,
            "enqueuePut must insert the document into the partition table")
    }

    func testMultipleConcurrentEnqueuePutsAllCommitted() async {
        let database = await makeDatabase()

        let docCount = 5

        // Fire all enqueues concurrently so they race to enter the queue,
        // exercising the FIFO serialisation under actual concurrent pressure.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<docCount {
                group.addTask {
                    let item = Database.BatchPutItem(
                        id: "multi-doc\(i)",
                        data: [EmbeddingData(embedding: .floats(VectorFixtures.random(seed: UInt64(i + 21000))), index: 0)],
                        texts: ["multi put \(i)"]
                    )
                    await database.enqueuePut([item], request: .test(ownerId: "multi-owner"))
                }
            }
        }

        _ = await database.removeAll(ownerId: "barrier", request: .test())

        let registry = database.registry
        for i in 0..<docCount {
            XCTAssertNotNil(registry?.documentOwners["multi-doc\(i)"],
                "multi-doc\(i) must be registered — all \(docCount) concurrent enqueuePut jobs must complete")
        }
    }

    func testPutThenEnqueueRemoveBatchDocumentIsAbsent() async {
        let database = await makeDatabase()
        let ownerId = "order-owner"

        let item = Database.BatchPutItem(
            id: "order-doc",
            data: [EmbeddingData(embedding: .floats(VectorFixtures.random(seed: 22000)), index: 0)],
            texts: ["ordering test"]
        )
        await database.enqueuePut([item], request: .test(ownerId: ownerId))
        await database.enqueueRemoveBatch([(documentId: "order-doc", ownerId: ownerId)])
        _ = await database.removeAll(ownerId: "barrier", request: .test())

        let registry = database.registry
        XCTAssertNil(registry?.documentOwners["order-doc"],
            "Document must be absent after put → removeBatch drains in FIFO order")
    }

    func testRemoveAllAwaitsAndReturnsAccurateCount() async {
        let database = await makeDatabase()
        let ownerId = "count-owner"

        for i in 0..<3 {
            let item = Database.BatchPutItem(
                id: "count-doc\(i)",
                data: [EmbeddingData(embedding: .floats(VectorFixtures.random(seed: UInt64(i + 56000))), index: 0)],
                texts: ["count test \(i)"]
            )
            await database.enqueuePut([item], request: .test(ownerId: ownerId))
        }
        // Barrier: ensure all puts complete before removeAll measures the count.
        _ = await database.removeAll(ownerId: "count-barrier", request: .test())

        let removedCount = await database.removeAll(ownerId: ownerId, request: .test(ownerId: ownerId))

        XCTAssertEqual(removedCount, 3,
            "removeAll must await the job and return the exact number of removed documents")
    }

    func testRemoveAllReturnsZeroForOwnerWithNoDocuments() async {
        let database = await makeDatabase()

        let count = await database.removeAll(ownerId: "no-docs-owner", request: .test())

        XCTAssertEqual(count, 0,
            "removeAll for an owner with no documents must return 0")
    }

    func testEnqueueRemoveBatchEmptyListIsNoOp() async {
        let database = await makeDatabase()

        let item = Database.BatchPutItem(
            id: "noop-doc",
            data: [EmbeddingData(embedding: .floats(VectorFixtures.random(seed: 23000)), index: 0)],
            texts: ["noop test"]
        )
        await database.enqueuePut([item], request: .test(ownerId: "noop-owner"))
        await database.enqueueRemoveBatch([])
        _ = await database.removeAll(ownerId: "barrier", request: .test())

        XCTAssertNotNil(database.registry?.documentOwners["noop-doc"],
            "enqueueRemoveBatch([]) must be a no-op — pre-existing document must survive")
    }

    // MARK: Group-ID coalescing isolation

    /// Regression guard for the bug where `drain()` coalesced all same-owner `.put`
    /// jobs regardless of group ID, causing every document to land in the first group.
    ///
    /// Four concurrent requests for the same owner but different groups must each
    /// produce a distinct group containing only its own document.
    func testConcurrentPutsWithDifferentGroupIDsAreNotCoalesced() async {
        let database = await makeDatabase()
        let ownerId = "group-isolation-owner"

        let groupIds = ["group-alice", "group-bob", "group-carol", "group-dave"]

        await withTaskGroup(of: Void.self) { group in
            for (i, groupId) in groupIds.enumerated() {
                group.addTask {
                    let groupObj = Database.Group.test(id: groupId, ownerId: ownerId)
                    let request = DatabaseRequest(ownerId: ownerId, group: groupObj,
                                              aggregate: nil, scope: .personal, requestID: nil)
                    let item = Database.BatchPutItem(
                        id: "doc-\(groupId)",
                        data: [EmbeddingData(embedding: .floats(VectorFixtures.random(seed: UInt64(i + 30000))), index: 0)],
                        texts: ["text for \(groupId)"]
                    )
                    await database.enqueuePut([item], request: request)
                }
            }
        }

        _ = await database.removeAll(ownerId: "barrier", request: .test())

        let registry = database.registry
        let owner = ThreadRegistry.Owner(id: ownerId)

        for groupId in groupIds {
            let storedGroup = registry?.ownersGroups[owner]?.first { $0.id == groupId }
            XCTAssertNotNil(storedGroup,
                "Group '\(groupId)' must be created — same-owner puts with different " +
                "group IDs must not be coalesced under the first group's request")

            // ownersGroups stores groups without document lists (by design — see ThreadRegistry
            // comment: "Database.Group in this scope will not have document values").
            // Use registry.groups[groupId] for the authoritative document membership check.
            let groupDocIds = registry?.groups[groupId] ?? []
            XCTAssertEqual(groupDocIds.count, 1,
                "Group '\(groupId)' must have exactly 1 document — cross-group " +
                "coalescing would inflate this count with documents for other groups")

            XCTAssertTrue(groupDocIds.contains("doc-\(groupId)"),
                "doc-\(groupId) must be registered under group '\(groupId)', not another group")
        }
    }

    // MARK: Link-only entity propagation (simultaneous-request race)

    /// Regression guard for the race where two requests submit the same document
    /// simultaneously.  Request A completes first and registers the document;
    /// Request B's Phase 1 then sees it as already-existing → link-only.  Because
    /// B's `prepared` list is empty, the old code used `databaseReq` (nil metadata) for
    /// `linkOwnerBatch`, creating B's group with no tags.
    ///
    /// The fix: Phase 1 preserves texts for link-only results so that
    /// `groupEnrichedReq` can still derive entity names and attach them as group tags.
    func testLinkOnlyDocumentCreatesGroupWithTagsWhenEnrichedRequestUsed() async {
        let database = await makeDatabase()
        let ownerId = "link-race-owner"

        // ── Step 1: Request A indexes doc under group-A (normal path) ────────────
        let groupA = Database.Group.test(id: "link-race-group-a", ownerId: ownerId)
        let reqA = DatabaseRequest(ownerId: ownerId, group: groupA,
                               aggregate: nil, scope: .personal, requestID: nil)
        let item = Database.BatchPutItem(
            id: "link-race-doc",
            data: [EmbeddingData(embedding: .floats(VectorFixtures.random(seed: 42000)), index: 0)],
            texts: ["gauge theory fiber bundle connections"],
            graph: .init(entities: [
                .init(name: "gauge"), .init(name: "fiber"), .init(name: "bundle"),
            ])
        )
        await database.enqueuePut([item], request: reqA)
        _ = await database.removeAll(ownerId: "barrier", request: .test())

        let owner = ThreadRegistry.Owner(id: ownerId)
        XCTAssertNotNil(
            database.registry?.ownersGroups[owner]?.first { $0.id == "link-race-group-a" },
            "Prerequisite: group-A must exist before the link-only race test proceeds")

        // ── Step 2: Request B — same doc, new group, arrives after A completed ───
        // BatchEmbeddings would classify "link-race-doc" as link-only (exists in
        // registry), derive entity names from its preserved texts, and call
        // linkOwnerBatch with a groupEnrichedReq that carries those names as tags.
        let computedTags = ["bundle", "fiber", "gauge"]   // entity names (sorted)
        let metaB = Database.Group.Metadata(tags: computedTags)
        let groupB = Database.Group.test(id: "link-race-group-b", ownerId: ownerId, metadata: metaB)
        let enrichedReq = DatabaseRequest(ownerId: ownerId, group: groupB,
                                      aggregate: nil, scope: .personal, requestID: nil)

        await database.linkOwnerBatch(documentIds: ["link-race-doc"], request: enrichedReq)

        let registryAfter = database.registry
        let groupBStored = registryAfter?.ownersGroups[owner]?.first { $0.id == "link-race-group-b" }
        XCTAssertNotNil(groupBStored,
            "Group B must be created when linkOwnerBatch is called for a new group")
        XCTAssertFalse(groupBStored?.metadata?.tags.isEmpty ?? true,
            "Group B must have tags — linkOwnerBatch must receive the tag-enriched " +
            "request built from the link-only document's preserved texts")
        XCTAssertEqual(Set(groupBStored?.metadata?.tags ?? []), Set(computedTags),
            "Group B tags must exactly match the tags computed from the link-only document")
    }

    /// Contrast test: documents what happens when `linkOwnerBatch` is called with
    /// a bare request (nil group metadata) — the old behavior before the fix.
    func testLinkOnlyDocumentCreatesGroupWithoutTagsWhenBareRequestUsed() async {
        let database = await makeDatabase()
        let ownerId = "bare-req-owner"

        let groupA = Database.Group.test(id: "bare-req-group-a", ownerId: ownerId)
        let reqA = DatabaseRequest(ownerId: ownerId, group: groupA,
                               aggregate: nil, scope: .personal, requestID: nil)
        let item = Database.BatchPutItem(
            id: "bare-req-doc",
            data: [EmbeddingData(embedding: .floats(VectorFixtures.random(seed: 43000)), index: 0)],
            texts: ["quantum mechanics wave function"],
            graph: .init(entities: [.init(name: "quantum"), .init(name: "wave")])
        )
        await database.enqueuePut([item], request: reqA)
        _ = await database.removeAll(ownerId: "barrier", request: .test())

        // linkOwnerBatch with nil metadata — the old databaseReq with no tags.
        let groupB = Database.Group.test(id: "bare-req-group-b", ownerId: ownerId, metadata: nil)
        let bareReq = DatabaseRequest(ownerId: ownerId, group: groupB,
                                  aggregate: nil, scope: .personal, requestID: nil)
        await database.linkOwnerBatch(documentIds: ["bare-req-doc"], request: bareReq)

        let owner = ThreadRegistry.Owner(id: ownerId)
        let groupBStored = database.registry?.ownersGroups[owner]?
            .first { $0.id == "bare-req-group-b" }
        XCTAssertNotNil(groupBStored, "Group B must still be created even with nil metadata")
        let tags = groupBStored?.metadata?.tags ?? []
        XCTAssertTrue(tags.isEmpty,
            "With a bare nil-metadata request, group B has no tags — " +
            "this is exactly what the fix prevents by using groupEnrichedReq")
    }

    func testMetadataPreservedAfterEnqueuePut() async {
        let database = await makeDatabase()
        let payload = Data("meta-test".utf8)

        let item = Database.BatchPutItem(
            id: "meta-doc",
            data: [EmbeddingData(embedding: .floats(VectorFixtures.random(seed: 24000)), index: 0)],
            texts: ["metadata preservation test"],
            metadata: payload
        )
        await database.enqueuePut([item], request: .test(ownerId: "meta-owner"))
        _ = await database.removeAll(ownerId: "barrier", request: .test())

        let index = database.table?.indices["meta-doc"]
        XCTAssertNotNil(index, "PartitionIndex must exist after enqueuePut")
        XCTAssertEqual(index?.metadata, payload,
            "metadata payload must be preserved in PartitionIndex after enqueuePut")
    }
}
