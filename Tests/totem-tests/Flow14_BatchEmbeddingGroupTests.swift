//
//  Flow14_BatchEmbeddingGroupTests.swift
//  database-serverTests
//
//  Tests that batch embedding uploads with a fresh group produce:
//    1. EmbeddingInput.array expansion — each array element becomes a separate document
//    2. Fresh group creation in the registry on the first put
//    3. All N documents land as distinct entries in the group
//    4. Documents are attributed to the requesting owner
//
//  Covers:
//    §1  Input expansion   — .array / .string / mixed / order / empty
//    §2  RegistryMutator   — group creation, document count, ownership, access inheritance
//    §3  IndexQueue (real) — end-to-end: enqueuePut → group created, N docs registered
//

import XCTest
@testable import totem

final class Flow14_BatchEmbeddingGroupTests: XCTestCase {

    // MARK: - Helpers

    private static func wipeDatabasePersistenceFiles() {
        let db = FilePersistence.getDefaultURL()
        for key in ["table", "registry", "sinatra/registry"] {
            try? FileManager.default.removeItem(at: db.appendingPathComponent(key))
        }
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: db, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) {
            for url in contents where url.lastPathComponent.hasPrefix("shard-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? FileManager.default.removeItem(at: db.appendingPathComponent("personal"))
    }

    private func makeDatabase() async -> Database {
        Self.wipeDatabasePersistenceFiles()
        let database = Database()
        await database.initializationTask.value
        addTeardownBlock { Flow14_BatchEmbeddingGroupTests.wipeDatabasePersistenceFiles() }
        return database
    }

    /// Mirrors the expansion logic from registerBatchEmbeddingsRoute — keeps §1 tests
    /// in sync with the route's behaviour without importing its private scope.
    private func expand(_ inputs: [EmbeddingInput]) -> [String] {
        inputs.flatMap { input -> [String] in
            switch input {
            case .string(let s):  return [s]
            case .array(let arr): return arr
            }
        }
    }

    private func makeItem(id: String, text: String, seed: UInt64) -> Database.BatchPutItem {
        Database.BatchPutItem(
            id: id,
            data: [EmbeddingData(embedding: .floats(VectorFixtures.random(seed: seed)), index: 0)],
            texts: [text]
        )
    }

    private func makeRequest(ownerId: String, groupId: String) -> DatabaseRequest {
        let group = Database.Group.test(id: groupId, ownerId: ownerId)
        return DatabaseRequest(ownerId: ownerId, group: group, aggregate: nil, scope: .personal, requestID: nil)
    }

    // =========================================================================
    // MARK: - §1 Input expansion
    // =========================================================================

    func testArrayInputExpandsEachElementToSeparateEntry() {
        let expanded = expand([.array(["alpha", "beta", "gamma"])])
        XCTAssertEqual(expanded.count, 3)
        XCTAssertEqual(expanded, ["alpha", "beta", "gamma"])
    }

    func testStringInputExpandsToSingleEntry() {
        let expanded = expand([.string("single document")])
        XCTAssertEqual(expanded.count, 1)
        XCTAssertEqual(expanded[0], "single document")
    }

    func testMixedInputsTotalCount() {
        // .string → 1 entry, .array(3) → 3 entries = 4 expanded documents total
        let expanded = expand([.string("one"), .array(["two", "three", "four"])])
        XCTAssertEqual(expanded.count, 4)
    }

    func testArrayExpansionPreservesOrder() {
        let texts = (1...5).map { "doc \($0)" }
        XCTAssertEqual(expand([.array(texts)]), texts,
            "Expansion must preserve the original ordering of array elements")
    }

    func testEmptyArrayExpandsToNoEntries() {
        XCTAssertTrue(expand([.array([])]).isEmpty,
            "An empty array input must produce no expanded document entries")
    }

    func testMultipleArrayInputsFlattenInOrder() {
        let expanded = expand([.array(["a", "b"]), .array(["c", "d", "e"])])
        XCTAssertEqual(expanded, ["a", "b", "c", "d", "e"],
            "Multiple array inputs must concatenate in input order")
    }

    // =========================================================================
    // MARK: - §2 RegistryMutator — fresh group creation and membership
    // =========================================================================

    func testRegisterBatchWithFreshGroupCreatesGroupOwnerEntry() async {
        let mutator = RegistryMutator.test()
        let group   = Database.Group.test(id: "fresh-group")
        let docs    = (0..<3).map { Database.Document.test(id: "fd\($0)") }

        await mutator.registerBatch(items: docs.map { ($0, group, "owner1") })

        XCTAssertNotNil(mutator.snapshot?.groupOwners["fresh-group"],
            "A fresh group must be written to groupOwners on the first batch put")
    }

    func testRegisterBatchMultipleDocumentsAllAppearInGroup() async {
        let mutator = RegistryMutator.test()
        let group   = Database.Group.test(id: "multi-group")
        let docs    = (0..<4).map { Database.Document.test(id: "md\($0)") }

        await mutator.registerBatch(items: docs.map { ($0, group, "owner1") })

        XCTAssertEqual(mutator.snapshot?.groups["multi-group"]?.count, 4,
            "All 4 documents must be registered as distinct entries in the group")
    }

    func testRegisterBatchGroupDocumentSetMatchesInputDocumentSet() async {
        let mutator     = RegistryMutator.test()
        let group       = Database.Group.test(id: "set-group")
        let docs        = (0..<5).map { Database.Document.test(id: "sd\($0)") }

        await mutator.registerBatch(items: docs.map { ($0, group, "owner1") })

        let groupDocIds = Set(mutator.snapshot?.groups["set-group"] ?? [])
        let expectedIds = Set(docs.map { $0.id })
        XCTAssertEqual(groupDocIds, expectedIds,
            "The group's document set must equal the set of input document IDs exactly")
    }

    func testRegisterBatchGroupAppearsExactlyOnceInOwnersGroups() async {
        let mutator    = RegistryMutator.test()
        let group      = Database.Group.test(id: "dedup-group")
        let docs       = (0..<5).map { Database.Document.test(id: "dup\($0)") }

        await mutator.registerBatch(items: docs.map { ($0, group, "owner1") })

        let owner      = TotemRegistry.Owner(id: "owner1")
        let appearances = (mutator.snapshot?.ownersGroups[owner] ?? [])
            .filter { $0.id == "dedup-group" }.count
        XCTAssertEqual(appearances, 1,
            "The group must appear exactly once in ownersGroups regardless of how many documents share it")
    }

    func testRegisterBatchGroupOwnerIsRequestingOwner() async {
        let mutator = RegistryMutator.test()
        let group   = Database.Group.test(id: "owned-group", ownerId: "alice")
        let doc     = Database.Document.test(id: "od1", ownerId: "alice")

        await mutator.registerBatch(items: [(doc, group, "alice")])

        XCTAssertEqual(mutator.snapshot?.groupOwners["owned-group"]?.id, "alice",
            "groupOwners must record the requesting owner when a fresh group is created")
    }

    func testRegisterBatchDocumentsInGroupInheritGroupAccess() async {
        let mutator = RegistryMutator.test()
        let group   = Database.Group.test(id: "access-group")
        let docs    = (0..<3).map { Database.Document.test(id: "ac\($0)") }

        await mutator.registerBatch(items: docs.map { ($0, group, "owner1") })

        for doc in docs {
            XCTAssertEqual(mutator.snapshot?.documentAccess[doc.id], .restricted,
                "\(doc.id) must inherit the group's default .restricted access")
        }
    }

    // =========================================================================
    // MARK: - §3 IndexQueue integration — end-to-end group creation
    // =========================================================================

    func testEnqueuePutCreatesGroupInRegistry() async {
        let database    = await makeDatabase()
        let request = makeRequest(ownerId: "iq-owner", groupId: "iq-fresh-group")

        let items = (0..<3).map { i in
            makeItem(id: "iq-doc\(i)", text: "content \(i)", seed: UInt64(40000 + i))
        }
        await database.enqueuePut(items, request: request)
        _ = await database.removeAll(ownerId: "barrier", request: .test())

        XCTAssertNotNil(database.registry?.groupOwners["iq-fresh-group"],
            "enqueuePut with a fresh group must create the group in the registry")
    }

    func testEnqueuePutAllDocumentsRegisteredInGroup() async {
        let database    = await makeDatabase()
        let request = makeRequest(ownerId: "iq-owner2", groupId: "iq-multi-group")

        let items = (0..<5).map { i in
            makeItem(id: "iq-multi-\(i)", text: "text \(i)", seed: UInt64(41000 + i))
        }
        await database.enqueuePut(items, request: request)
        _ = await database.removeAll(ownerId: "barrier", request: .test())

        XCTAssertEqual(database.registry?.groups["iq-multi-group"]?.count, 5,
            "All 5 documents must appear in the group after enqueuePut")
    }

    func testEnqueuePutGroupDocumentIdsMatchPutItemIds() async {
        let database    = await makeDatabase()
        let request = makeRequest(ownerId: "iq-owner3", groupId: "iq-exact-group")

        let docIds = (0..<4).map { "exact-doc-\($0)" }
        let items  = docIds.enumerated().map { i, id in
            makeItem(id: id, text: "exact \(i)", seed: UInt64(42000 + i))
        }
        await database.enqueuePut(items, request: request)
        _ = await database.removeAll(ownerId: "barrier", request: .test())

        let groupDocIds = Set(database.registry?.groups["iq-exact-group"] ?? [])
        XCTAssertEqual(groupDocIds, Set(docIds),
            "The group must contain exactly the document IDs from the put batch — each as a distinct entry")
    }

    // =========================================================================
    // MARK: - §4 Same document, multiple groups (regression)
    // =========================================================================
    //
    // A document with the same content (same hash / documentId) sent twice by the
    // same owner with different groups must be linked to BOTH groups.
    // Previously the second put was silently dropped because isOwnerLinked returned
    // true without checking whether the requested group was new.

    func testSameDocumentInTwoGroupsBothGroupsContainDocument() async {
        let database  = await makeDatabase()
        let docId = "mg-shared-doc"

        let item = makeItem(id: docId, text: "shared content across groups", seed: 99_001)
        await database.enqueuePut([item], request: makeRequest(ownerId: "mg-owner", groupId: "mg-grp-alpha"))
        _ = await database.removeAll(ownerId: "barrier-1", request: .test())

        await database.enqueuePut([item], request: makeRequest(ownerId: "mg-owner", groupId: "mg-grp-beta"))
        _ = await database.removeAll(ownerId: "barrier-2", request: .test())

        let registry = database.registry!
        XCTAssertTrue(registry.groups["mg-grp-alpha"]?.contains(docId) == true,
            "mg-grp-alpha must contain the document after the first put")
        XCTAssertTrue(registry.groups["mg-grp-beta"]?.contains(docId) == true,
            "mg-grp-beta must contain the same document after the second put with a different group")
        XCTAssertTrue(registry.documentGroups[docId]?.contains("mg-grp-alpha") == true,
            "documentGroups must include mg-grp-alpha")
        XCTAssertTrue(registry.documentGroups[docId]?.contains("mg-grp-beta") == true,
            "documentGroups must include mg-grp-beta")
    }

    func testSameDocumentInTwoGroupsBothGroupsAppearInOwnersGroups() async {
        let database    = await makeDatabase()
        let ownerId = "mg-owner-og"
        let owner   = TotemRegistry.Owner(id: ownerId)

        let item = makeItem(id: "mg-og-doc", text: "owners groups content", seed: 99_002)
        await database.enqueuePut([item], request: makeRequest(ownerId: ownerId, groupId: "mg-og-grp-1"))
        _ = await database.removeAll(ownerId: "barrier-1", request: .test())

        await database.enqueuePut([item], request: makeRequest(ownerId: ownerId, groupId: "mg-og-grp-2"))
        _ = await database.removeAll(ownerId: "barrier-2", request: .test())

        let groups = database.registry?.ownersGroups[owner] ?? []
        XCTAssertTrue(groups.contains(where: { $0.id == "mg-og-grp-1" }),
            "mg-og-grp-1 must appear in ownersGroups")
        XCTAssertTrue(groups.contains(where: { $0.id == "mg-og-grp-2" }),
            "mg-og-grp-2 must appear in ownersGroups after the second put")
    }

    func testSameDocumentInTwoGroupsOwnerLinkedExactlyOnce() async {
        let database    = await makeDatabase()
        let ownerId = "mg-owner-ol"

        let item = makeItem(id: "mg-ol-doc", text: "owner link dedup content", seed: 99_003)
        await database.enqueuePut([item], request: makeRequest(ownerId: ownerId, groupId: "mg-ol-grp-1"))
        _ = await database.removeAll(ownerId: "barrier-1", request: .test())

        await database.enqueuePut([item], request: makeRequest(ownerId: ownerId, groupId: "mg-ol-grp-2"))
        _ = await database.removeAll(ownerId: "barrier-2", request: .test())

        let owners = database.registry?.documentOwners["mg-ol-doc"]
        XCTAssertEqual(owners?.count, 1,
            "owner must appear exactly once in documentOwners even after linking to a second group")
    }

    // =========================================================================
    // MARK: - §5 Existing owner attribute
    // =========================================================================

    func testEnqueuePutAllDocumentsAttributedToRequestOwner() async {
        let database    = await makeDatabase()
        let ownerId = "iq-owner4"
        let request = makeRequest(ownerId: ownerId, groupId: "iq-owner-group")
        let owner   = TotemRegistry.Owner(id: ownerId)

        let items = (0..<3).map { i in
            makeItem(id: "owned-\(i)", text: "owned \(i)", seed: UInt64(43000 + i))
        }
        await database.enqueuePut(items, request: request)
        _ = await database.removeAll(ownerId: "barrier", request: .test())

        let registry = database.registry!
        for i in 0..<3 {
            XCTAssertTrue(registry.documentOwners["owned-\(i)"]?.contains(owner) == true,
                "owned-\(i) must be attributed to owner '\(ownerId)'")
        }
    }
}
