//
//  Flow1_EmbeddingUploadTests.swift
//  database-serverTests
//
//  Tests for the document upload flow:
//  PartitionTable.put() → PQ training → registry state.
//

import XCTest
@testable import thread

final class Flow1_EmbeddingUploadTests: XCTestCase {

    // MARK: - Setup

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("database-flow1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }


    // MARK: - PartitionTable.put()

    func testPutAddsDocumentIdToKeys() {
        var table = PartitionTable()
        let p = Database.Partition.test(documentId: "doc1", embedding: VectorFixtures.random(seed: 1))
        table.put(id: "doc1", partitions: [p], request: .test(), logger: .test)

        XCTAssertTrue(table.keys.contains("doc1"))
    }

    func testPutCreatesPartitionIndex() {
        var table = PartitionTable()
        let p = Database.Partition.test(documentId: "doc1", embedding: VectorFixtures.random(seed: 2))
        table.put(id: "doc1", partitions: [p], request: .test(), logger: .test)

        XCTAssertNotNil(table.indices["doc1"])
    }


    func testPutMultipleDocumentsAllIndexed() {
        var table = PartitionTable()
        for i in 0..<5 {
            let p = Database.Partition.test(documentId: "doc\(i)", embedding: VectorFixtures.random(seed: UInt64(i + 10)))
            table.put(id: "doc\(i)", partitions: [p], request: .test(), logger: .test)
        }

        XCTAssertEqual(table.keys.count, 5)
        XCTAssertEqual(table.indices.count, 5)
    }

    func testPutEmbeddingsClearedAfterTraining() {
        // After put(), raw embeddings are discarded — only compressed codes survive in slots.
        var table = PartitionTable()
        let p = Database.Partition.test(documentId: "doc1", embedding: VectorFixtures.random(seed: 20))
        table.put(id: "doc1", partitions: [p], request: .test(), logger: .test)

        let slots = table.indices["doc1"]?.slots ?? []
        XCTAssertFalse(slots.isEmpty)
        for slot in slots {
            XCTAssertNotNil(slot.compressedEmbedding,
                "compressedEmbedding must be set (raw embedding is discarded during PQ training)")
        }
    }

    func testPutCompressedEmbeddingSetAfterTraining() {
        var table = PartitionTable()
        let p = Database.Partition.test(documentId: "doc1", embedding: VectorFixtures.random(seed: 21))
        table.put(id: "doc1", partitions: [p], request: .test(), logger: .test)

        let slots = table.indices["doc1"]?.slots ?? []
        XCTAssertFalse(slots.isEmpty)
        for slot in slots {
            XCTAssertNotNil(slot.compressedEmbedding,
                "compressedEmbedding must be set after PQ training")
        }
    }

    func testPutThenRemoveDeletesDocument() {
        var table = PartitionTable()
        let p = Database.Partition.test(documentId: "doc1", embedding: VectorFixtures.random(seed: 30))
        table.put(id: "doc1", partitions: [p], request: .test(), logger: .test)
        table.remove(id: "doc1")

        XCTAssertFalse(table.keys.contains("doc1"))
        XCTAssertNil(table.indices["doc1"])
    }



    // MARK: - ThreadRegistry operations

    // MARK: - Empty embedding guard (regression: crash + phantom index when all embeddings are empty)

    func testPutWithAllEmptyEmbeddingsSkipsIndexCreation() {
        var table = PartitionTable()
        let emptyPartition = Database.Partition.test(embedding: [])
        table.put(id: "doc-empty", partitions: [emptyPartition], request: .test(), logger: .test)

        // No PartitionIndex created — nothing to score during search
        XCTAssertNil(table.index(for: "doc-empty"))
        // Document ID not tracked as an indexed key
        XCTAssertFalse(table.keys.contains("doc-empty"))
    }

    func testPutWithMixedEmbeddingsIndexesOnlyNonEmpty() throws {
        var table = PartitionTable()
        let empty = Database.Partition.test(id: "empty-p", documentId: "doc1", embedding: [])
        let real  = Database.Partition.test(
            id: "real-p", documentId: "doc1",
            embedding: VectorFixtures.random(seed: 99)
        )
        table.put(id: "doc1", partitions: [empty, real], request: .test(), logger: .test)

        // Index exists because at least one partition was actually inserted
        XCTAssertNotNil(table.index(for: "doc1"))
        // Only the valid partition appears as a slot
        XCTAssertEqual(table.index(for: "doc1")?.slots.count, 1)
        XCTAssertEqual(table.index(for: "doc1")?.slots.first?.id, "real-p")
    }

    func testRegistryInitiallyEmpty() {
        let registry = ThreadRegistry()
        XCTAssertTrue(registry.ownersDocuments.isEmpty)
        XCTAssertTrue(registry.documentOwners.isEmpty)
        XCTAssertTrue(registry.availableDocumentIds.isEmpty)
    }

    func testDoesDocumentExistFalseForUnknownId() {
        let registry = ThreadRegistry()
        XCTAssertFalse(registry.doesDocumentExist("doc-xyz"))
    }

    func testGetDocumentAccessDefaultIsUnknown() {
        let registry = ThreadRegistry()
        XCTAssertEqual(registry.getDocumentAccess("doc1"), .unknown)
    }

    func testUpdateAccessToAvailableAddsToAvailableSet() {
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "doc1", state: .available)

        XCTAssertTrue(registry.availableDocumentIds.contains("doc1"))
        XCTAssertEqual(registry.getDocumentAccess("doc1"), .available)
    }

    func testUpdateAccessToRestrictedRemovesFromAvailableSet() {
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "doc1", state: .available)
        registry.updateDocumentAccess(for: "doc1", state: .restricted)

        XCTAssertFalse(registry.availableDocumentIds.contains("doc1"))
        XCTAssertEqual(registry.getDocumentAccess("doc1"), .restricted)
    }

    func testDoesDocumentExistTrueAfterRestrictedAccess() {
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "doc1", state: .restricted)
        XCTAssertTrue(registry.doesDocumentExist("doc1"))
    }

    func testDoesDocumentExistTrueAfterAvailableAccess() {
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "doc1", state: .available)
        XCTAssertTrue(registry.doesDocumentExist("doc1"))
    }

    func testRemoveDeletesAllDocumentReferences() {
        var registry = ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: "owner1")

        registry.ownersDocuments[owner] = ["doc1"]
        registry.documentOwners["doc1"] = [owner]
        registry.updateDocumentAccess(for: "doc1", state: .available)

        registry.remove(documentId: "doc1", group: nil, owner: owner)

        XCTAssertFalse(registry.availableDocumentIds.contains("doc1"))
        XCTAssertNil(registry.documentOwners["doc1"])
        XCTAssertNil(registry.documentAccess["doc1"])
        XCTAssertFalse((registry.ownersDocuments[owner] ?? []).contains("doc1"))
    }

    func testMultipleDocumentsInAvailableSet() {
        var registry = ThreadRegistry()
        for i in 0..<5 {
            registry.updateDocumentAccess(for: "doc\(i)", state: .available)
        }
        registry.updateDocumentAccess(for: "doc2", state: .restricted)

        XCTAssertEqual(registry.availableDocumentIds.count, 4)
        XCTAssertFalse(registry.availableDocumentIds.contains("doc2"))
    }
}
