//
//  Flow5_BatchIndexingTests.swift
//  database-serverTests
//
//  Tests for the bulk-write operations and caching layer added to eliminate
//  actor-queue congestion during batch embedding uploads:
//    DocumentCache.cacheBatch
//    RegistryMutator.registerBatch
//    TableMutator.putBatch
//    PersistenceActor  — serialized disk I/O safety
//    TotemCache<Value>  — lock-protected snapshot + off-actor persistence
//

import XCTest
@testable import totem

final class Flow5_BatchIndexingTests: XCTestCase {

    // MARK: - Setup

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("database-flow5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// Builds N (document, nil-group, ownerId) registration items for a single owner.
    private func registrationItems(
        count: Int,
        ownerId: String = "batch-owner"
    ) -> [(document: Database.Document, group: Database.Group?, ownerId: String)] {
        (0..<count).map { i in
            (Database.Document.test(id: "doc\(i)", ownerId: ownerId), nil, ownerId)
        }
    }

    /// Returns a `FilePersistence` backed by a unique temp-scoped file and
    /// registers a teardown block to delete that file after the test completes.
    private func tempPersistence(key: String) -> FilePersistence {
        let file = FilePersistence(key: "test/flow5/\(key)", kind: .basic, logger: .test)
        addTeardownBlock { [url = file.url] in
            try? FileManager.default.removeItem(at: url)
        }
        return file
    }

    // MARK: - DocumentCache.cacheBatch

    func testCacheBatchStoresAllDocuments() {
        let cache = DocumentCache()
        let docs = (0..<6).map { Database.Document.test(id: "d\($0)") }
        cache.cacheBatch(docs)

        for doc in docs {
            XCTAssertNotNil(cache.get(doc.id), "cacheBatch must store \(doc.id)")
        }
    }

    func testCacheBatchOverwritesExistingEntry() {
        let cache = DocumentCache()
        cache.cache(.test(id: "doc1", ownerId: "original"))
        cache.cacheBatch([.test(id: "doc1", ownerId: "replacement")])

        XCTAssertEqual(cache.get("doc1")?.ownerId, "replacement")
    }

    func testCacheBatchEmptyArrayIsNoOp() {
        let cache = DocumentCache()
        cache.cache(.test(id: "existing"))
        cache.cacheBatch([])

        XCTAssertNotNil(cache.get("existing"),
            "cacheBatch([]) must not evict existing entries")
    }

    func testCacheBatchEquivalentToNCacheCalls() {
        let single = DocumentCache()
        let batch  = DocumentCache()
        let docs = (0..<8).map { Database.Document.test(id: "doc\($0)") }

        for doc in docs { single.cache(doc) }
        batch.cacheBatch(docs)

        for doc in docs {
            XCTAssertEqual(single.get(doc.id)?.id, batch.get(doc.id)?.id)
        }
    }

    // MARK: - RegistryMutator.registerBatch

    func testRegisterBatchRegistersAllDocuments() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())

        await mutator.registerBatch(items: registrationItems(count: 5))

        let registry = mutator.snapshot!
        let owner = TotemRegistry.Owner(id: "batch-owner")
        XCTAssertEqual(registry.ownersDocuments[owner]?.count, 5)
        for i in 0..<5 {
            XCTAssertNotNil(registry.documentOwners["doc\(i)"])
        }
    }

    func testRegisterBatchSetsDefaultRestrictedAccess() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())

        let items: [(document: Database.Document, group: Database.Group?, ownerId: String)] = [
            (.test(id: "doc1"), nil, "owner1"),
            (.test(id: "doc2"), nil, "owner1"),
        ]
        await mutator.registerBatch(items: items)

        let registry = mutator.snapshot!
        XCTAssertEqual(registry.documentAccess["doc1"], .restricted)
        XCTAssertEqual(registry.documentAccess["doc2"], .restricted)
    }

    func testRegisterBatchCreatesGroupEntries() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())

        let group = Database.Group.test(id: "grp1")
        let items = (0..<4).map { i -> (document: Database.Document, group: Database.Group?, ownerId: String) in
            (.test(id: "doc\(i)"), group, "owner1")
        }
        await mutator.registerBatch(items: items)

        let registry = mutator.snapshot!
        XCTAssertEqual(registry.groups["grp1"]?.count, 4,
            "All batch documents must appear in the group")
        XCTAssertEqual(registry.groupAccess["grp1"], .restricted,
            "Group access defaults to restricted")
        for i in 0..<4 {
            XCTAssertTrue(registry.documentGroups["doc\(i)"]?.contains("grp1") == true)
        }
    }

    func testRegisterBatchDeduplicatesGroupOwnerEntry() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())

        let group = Database.Group.test(id: "grp1")
        let items = (0..<5).map { i -> (document: Database.Document, group: Database.Group?, ownerId: String) in
            (.test(id: "d\(i)"), group, "owner1")
        }
        await mutator.registerBatch(items: items)

        let registry = mutator.snapshot!
        let owner = TotemRegistry.Owner(id: "owner1")
        let groupAppearances = (registry.ownersGroups[owner] ?? []).filter { $0.id == "grp1" }.count
        XCTAssertEqual(groupAppearances, 1,
            "Group must appear exactly once in ownersGroups even when shared by multiple docs")
    }

    func testRegisterBatchMultipleOwners() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())

        let items: [(document: Database.Document, group: Database.Group?, ownerId: String)] = [
            (.test(id: "a1"), nil, "alice"),
            (.test(id: "a2"), nil, "alice"),
            (.test(id: "b1"), nil, "bob"),
        ]
        await mutator.registerBatch(items: items)

        let registry = mutator.snapshot!
        XCTAssertEqual(registry.ownersDocuments[.init(id: "alice")]?.count, 2)
        XCTAssertEqual(registry.ownersDocuments[.init(id: "bob")]?.count, 1)
    }

    func testRegisterBatchEquivalentToNIndividualRegisters() async {
        let batchMutator    = RegistryMutator.test()
        let individualMutator = RegistryMutator.test()
        batchMutator.seed(.init())
        individualMutator.seed(.init())

        let group = Database.Group.test(id: "grp1")
        let docs  = (0..<5).map { Database.Document.test(id: "doc\($0)") }

        await batchMutator.registerBatch(items: docs.map { ($0, group, "owner1") })
        for doc in docs { await individualMutator.register(doc, group: group, ownerId: "owner1") }

        let bReg = batchMutator.snapshot!
        let iReg = individualMutator.snapshot!
        let owner = TotemRegistry.Owner(id: "owner1")

        XCTAssertEqual(
            Set(bReg.ownersDocuments[owner] ?? []),
            Set(iReg.ownersDocuments[owner] ?? []),
            "ownersDocuments must match"
        )
        XCTAssertEqual(bReg.documentOwners.keys.sorted(), iReg.documentOwners.keys.sorted())
        XCTAssertEqual(
            Set(bReg.groups["grp1"] ?? []),
            Set(iReg.groups["grp1"] ?? [])
        )
        XCTAssertEqual(bReg.groupAccess["grp1"], iReg.groupAccess["grp1"])
        for doc in docs {
            XCTAssertEqual(bReg.documentAccess[doc.id], iReg.documentAccess[doc.id])
        }
    }

    func testRegisterBatchEmptyIsNoOp() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())

        await mutator.registerBatch(items: [])

        let registry = mutator.snapshot!
        XCTAssertTrue(registry.ownersDocuments.isEmpty)
        XCTAssertTrue(registry.documentOwners.isEmpty)
    }

    // MARK: - TableMutator.putBatch

    func testPutBatchInsertsAllDocumentKeys() async {
        let mutator = TableMutator.test()
        mutator.seed(.init())

        let items = (0..<5).map { i -> (id: DocumentID, partitions: [Database.Partition], graph: Database.GraphPayload, metadata: Data?, request: DatabaseRequest) in
            let p = Database.Partition.test(id: "p\(i)", documentId: "doc\(i)",
                                        embedding: VectorFixtures.random(seed: UInt64(i + 200)))
            return ("doc\(i)", [p], .init(), nil, .test())
        }
        await mutator.putBatch(items: items)

        let table = mutator.snapshot!
        XCTAssertEqual(table.keys.count, 5)
        for i in 0..<5 { XCTAssertTrue(table.keys.contains("doc\(i)")) }
    }

    func testPutBatchIndexesAllPartitions() async {
        let mutator = TableMutator.test()
        mutator.seed(.init())

        // 3 documents × 2 partitions each = 6 total HNSW insertions
        let items = (0..<3).map { i -> (id: DocumentID, partitions: [Database.Partition], graph: Database.GraphPayload, metadata: Data?, request: DatabaseRequest) in
            let partitions = [
                Database.Partition.test(id: "p\(i)a", documentId: "doc\(i)",
                                    embedding: VectorFixtures.random(seed: UInt64(i * 2 + 400))),
                Database.Partition.test(id: "p\(i)b", documentId: "doc\(i)",
                                    embedding: VectorFixtures.random(seed: UInt64(i * 2 + 401))),
            ]
            return ("doc\(i)", partitions, .init(), nil, .test())
        }
        await mutator.putBatch(items: items)

        let table = mutator.snapshot!
        let totalSlots = table.indices.values.reduce(0) { $0 + $1.slots.count }
        XCTAssertEqual(totalSlots, 6)
    }

    func testPutBatchEmptyIsNoOp() async {
        let mutator = TableMutator.test()
        mutator.seed(.init())

        await mutator.putBatch(items: [])

        XCTAssertTrue(mutator.snapshot?.keys.isEmpty ?? true)
    }

    func testPutBatchEquivalentToNIndividualPuts() async {
        let batchMutator    = TableMutator.test()
        let individualMutator = TableMutator.test()
        batchMutator.seed(.init())
        individualMutator.seed(.init())

        let items = (0..<5).map { i -> (id: DocumentID, partitions: [Database.Partition], graph: Database.GraphPayload, metadata: Data?, request: DatabaseRequest) in
            let p = Database.Partition.test(id: "p\(i)", documentId: "doc\(i)",
                                        embedding: VectorFixtures.random(seed: UInt64(i + 600)))
            return ("doc\(i)", [p], .init(), nil, DatabaseRequest.test())
        }

        await batchMutator.putBatch(items: items)
        for item in items {
            await individualMutator.put(id: item.id, partitions: item.partitions, request: item.request)
        }

        let bTable = batchMutator.snapshot!
        let iTable = individualMutator.snapshot!

        XCTAssertEqual(bTable.keys.sorted(), iTable.keys.sorted(),
            "Batch and individual puts must produce identical key sets")
        let bSlots = bTable.indices.values.reduce(0) { $0 + $1.slots.count }
        let iSlots = iTable.indices.values.reduce(0) { $0 + $1.slots.count }
        XCTAssertEqual(bSlots, iSlots, "Total indexed slots must match")
        for i in 0..<5 {
            XCTAssertNotNil(bTable.indices["doc\(i)"])
            XCTAssertNotNil(iTable.indices["doc\(i)"])
        }
    }

    func testPutBatchSnapshotUpdatedImmediately() async {
        let mutator = TableMutator.test()
        mutator.seed(.init())

        let p = Database.Partition.test(id: "p0", documentId: "doc0",
                                    embedding: VectorFixtures.random(seed: 999))
        await mutator.putBatch(items: [("doc0", [p], .init(), nil, .test())])

        // snapshot must reflect the mutation synchronously — no disk round-trip needed
        XCTAssertTrue(mutator.snapshot?.keys.contains("doc0") ?? false,
            "snapshot must be updated immediately after putBatch")
    }

    // MARK: - PersistenceActor

    func testPersistenceActorSaveAndRestoreRoundtrip() async {
        let file = tempPersistence(key: "pa-roundtrip")
        let actor = PersistenceActor(persistence: file)

        var registry = TotemRegistry()
        registry.documentOwners["sentinel"] = [TotemRegistry.Owner(id: "actor-test")]
        await actor.save(registry)

        let restored: TotemRegistry? = await actor.restore()
        XCTAssertNotNil(restored)
        XCTAssertNotNil(restored?.documentOwners["sentinel"],
            "Restored registry must contain the saved document owner entry")
    }

    func testPersistenceActorRestoreReturnsNilForMissingFile() async {
        let file = tempPersistence(key: "pa-missing-\(UUID().uuidString)")
        let actor = PersistenceActor(persistence: file)
        let restored: TotemRegistry? = await actor.restore()
        XCTAssertNil(restored, "restore() must return nil when no backing file exists")
    }

    func testPersistenceActorConcurrentSavesProduceValidFile() async {
        let file = tempPersistence(key: "pa-concurrent")
        let actor = PersistenceActor(persistence: file)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                var registry = TotemRegistry()
                registry.documentOwners["doc-\(i)"] = [TotemRegistry.Owner(id: "owner-\(i)")]
                group.addTask { await actor.save(registry) }
            }
        }

        let restored: TotemRegistry? = await actor.restore()
        XCTAssertNotNil(restored,
            "File must be valid after concurrent saves — PersistenceActor must serialize writes")
    }

    func testPersistenceActorSaveIsSerializedWithRestore() async {
        let file = tempPersistence(key: "pa-serial")
        let actor = PersistenceActor(persistence: file)

        var before = TotemRegistry()
        before.documentOwners["before"] = [.init(id: "v0")]
        await actor.save(before)

        var after = TotemRegistry()
        after.documentOwners["after"] = [.init(id: "v1")]
        await actor.save(after)

        let restored: TotemRegistry? = await actor.restore()
        XCTAssertNotNil(restored?.documentOwners["after"],
            "Second save must be the committed state")
        XCTAssertNil(restored?.documentOwners["before"],
            "First save must be superseded by the second")
    }

    func testPersistenceActorPurgeRemovesFile() async {
        let file = tempPersistence(key: "pa-purge")
        let actor = PersistenceActor(persistence: file)

        var registry = TotemRegistry()
        registry.documentOwners["d1"] = [.init(id: "o1")]
        await actor.save(registry)

        let before: TotemRegistry? = await actor.restore()
        XCTAssertNotNil(before, "File must exist after save")

        await actor.purge()

        let after: TotemRegistry? = await actor.restore()
        XCTAssertNil(after, "restore() must return nil after purge()")
    }

    // MARK: - TotemCache

    func testTotemCacheSnapshotIsNilInitially() {
        let cache = TotemCache<TotemRegistry>(persistence: tempPersistence(key: "sc-nil"))
        XCTAssertNil(cache.snapshot)
    }

    func testTotemCacheSeedSetsSnapshotSynchronously() {
        let cache = TotemCache<TotemRegistry>(persistence: tempPersistence(key: "sc-seed"))
        XCTAssertNil(cache.snapshot, "snapshot must be nil before seed")
        cache.seed(.init())
        XCTAssertNotNil(cache.snapshot, "snapshot must be non-nil immediately after seed")
    }

    func testTotemCacheUpdateReflectsInSnapshot() {
        let cache = TotemCache<TotemRegistry>(persistence: tempPersistence(key: "sc-update"))
        cache.seed(.init())

        var updated = TotemRegistry()
        updated.documentOwners["d1"] = [.init(id: "o1")]
        cache.update(updated)

        XCTAssertNotNil(cache.snapshot?.documentOwners["d1"],
            "update() must reflect immediately in snapshot")
    }

    func testTotemCacheUpdateReplacesEntireSnapshot() {
        let cache = TotemCache<TotemRegistry>(persistence: tempPersistence(key: "sc-replace"))
        cache.seed(.init())

        var r1 = TotemRegistry()
        r1.documentOwners["a"] = [.init(id: "owner-a")]
        cache.update(r1)
        XCTAssertNotNil(cache.snapshot?.documentOwners["a"])

        var r2 = TotemRegistry()
        r2.documentOwners["b"] = [.init(id: "owner-b")]
        cache.update(r2)

        XCTAssertNotNil(cache.snapshot?.documentOwners["b"],
            "Second update must set the new value")
        XCTAssertNil(cache.snapshot?.documentOwners["a"],
            "update() replaces the entire snapshot — prior keys must not linger")
    }

    func testTotemCacheLoadReturnsSeededValueWithoutDiskRead() async {
        let cache = TotemCache<TotemRegistry>(persistence: tempPersistence(key: "sc-load-seeded"))

        var seeded = TotemRegistry()
        seeded.documentOwners["seeded-sentinel"] = [.init(id: "seeded-owner")]
        cache.seed(seeded)

        // Factory returns an empty registry; the seeded value must survive.
        let result = await cache.load { TotemRegistry() }

        XCTAssertNotNil(result.documentOwners["seeded-sentinel"],
            "load() must return the seeded value — the default factory must not override it")
    }

    func testTotemCacheLoadColdStartReadsFromDisk() async {
        let key = "sc-cold-\(UUID().uuidString)"
        let file = tempPersistence(key: key)

        var original = TotemRegistry()
        original.documentOwners["cold-sentinel"] = [.init(id: "disk-owner")]
        file.save(state: original)

        let cache = TotemCache<TotemRegistry>(persistence: tempPersistence(key: key))
        let loaded = await cache.load { TotemRegistry() }

        XCTAssertNotNil(loaded.documentOwners["cold-sentinel"],
            "load() must recover the pre-written registry from disk on cold start")
    }

    func testTotemCacheLoadEmptyFileReturnsDefault() async {
        let cache = TotemCache<TotemRegistry>(
            persistence: tempPersistence(key: "sc-load-default-\(UUID().uuidString)")
        )

        var sentinelBuilder = TotemRegistry()
        sentinelBuilder.documentOwners["factory-sentinel"] = [.init(id: "factory-owner")]
        let sentinel = sentinelBuilder
        let loaded = await cache.load { sentinel }

        XCTAssertNotNil(loaded.documentOwners["factory-sentinel"],
            "load() must call and return defaultFactory's value when no file exists")
    }

    func testTotemCacheSnapshotUpdatedBeforeDiskFlush() {
        let cache = TotemCache<TotemRegistry>(persistence: tempPersistence(key: "sc-immediate"))
        cache.seed(.init())

        var registry = TotemRegistry()
        registry.documentOwners["immediate"] = [.init(id: "fast-check")]

        cache.update(registry)
        cache.saveAsync(registry)

        XCTAssertNotNil(cache.snapshot?.documentOwners["immediate"],
            "snapshot must reflect update() synchronously, before the async disk write completes")
    }

    func testTotemCacheSaveAsyncThenLoadOnFreshCacheReturnsPersistedValue() async throws {
        let key = "sc-save-async-\(UUID().uuidString)"
        let writer = TotemCache<TotemRegistry>(persistence: tempPersistence(key: key))
        writer.seed(.init())

        var registry = TotemRegistry()
        registry.documentOwners["persisted"] = [.init(id: "async-owner")]
        writer.update(registry)
        writer.saveAsync(registry)

        try await Task.sleep(nanoseconds: 200_000_000)

        let reader = TotemCache<TotemRegistry>(persistence: tempPersistence(key: key))
        let loaded = await reader.load { TotemRegistry() }

        XCTAssertNotNil(loaded.documentOwners["persisted"],
            "saveAsync must eventually commit to disk; a fresh cache must load the persisted value")
    }

    func testTotemCacheLoadPopulatesSnapshotForSubsequentReads() async {
        let key = "sc-populate-\(UUID().uuidString)"
        let file = tempPersistence(key: key)

        var original = TotemRegistry()
        original.documentOwners["populated"] = [.init(id: "reader-owner")]
        file.save(state: original)

        let cache = TotemCache<TotemRegistry>(persistence: tempPersistence(key: key))
        XCTAssertNil(cache.snapshot, "snapshot must be nil before load")

        _ = await cache.load { TotemRegistry() }

        XCTAssertNotNil(cache.snapshot,
            "snapshot must be populated after the first load() so subsequent reads need no disk I/O")
        XCTAssertNotNil(cache.snapshot?.documentOwners["populated"])
    }
}
