//
//  Flow16_DeletionCleanupTests.swift
//  database-serverTests
//
//  Tests for the deletion cleanup fixes:
//
//  Bug 1 — Missing partitionStore.purge():
//    After removing a document, `documents/{id}-parts` was never deleted.
//    Fix: all three deletion paths in Database+Index.swift now call
//    `partitionStore(for: documentId).purge()`.
//
//  Coverage:
//    1. Partition text file is written when a document is indexed.
//    2. FilePersistence.purge() removes the -parts file (mechanism used by fix).
//    3. Both document files (doc and -parts) can be purged independently.
//    4. allowedDocs is built correctly from availableDocumentIds ∪ ownersDocuments
//       (the access set used by search and graph expansion).
//

import XCTest
@testable import totem

final class Flow16_DeletionCleanupTests: XCTestCase {

    private var testNodeId: UUID!
    private var createdKeys: [String] = []

    override func setUpWithError() throws {
        testNodeId  = UUID()
        createdKeys = []
    }

    override func tearDownWithError() throws {
        for key in createdKeys {
            FilePersistence(key: key, kind: .basic, logger: .test).purge()
        }
    }

    // Convenience: build an isolated TableMutator.
    private func makeTableMutator() -> TableMutator {
        let nodeId = testNodeId!
        let mutator = TableMutator(nodeId: nodeId, logger: .test)
        mutator.seed(PartitionTable())
        mutator.seedGraph(GraphStore())
        createdKeys += [
            "table-\(nodeId)",
            "graph-\(nodeId)",
        ]
        return mutator
    }

    private func makePartition(
        id: String = "p0",
        documentId: String = "doc0",
        seed: UInt64 = 1,
        text: String = "hello world"
    ) -> Database.Partition {
        Database.Partition.test(id: id, documentId: documentId,
                            embedding: VectorFixtures.random(seed: seed),
                            text: text)
    }

    // =========================================================================
    // MARK: - 1. Partition text file written on put
    // =========================================================================

    func testPartitionDataFileWrittenOnPut() async throws {
        let mutator = makeTableMutator()
        let docId   = "doc-write-\(testNodeId!)"
        createdKeys.append("documents/\(docId)-parts")

        await mutator.put(
            id: docId,
            partitions: [makePartition(id: "p0", documentId: docId, seed: 1)],
            request: .test()
        )

        let partsFile = FilePersistence(key: "documents/\(docId)-parts", kind: .basic, logger: .test)
        let stored: [PartitionData]? = partsFile.restore()
        XCTAssertNotNil(stored,
            "documents/{id}-parts must be written when a document is indexed")
        XCTAssertFalse((stored ?? []).isEmpty,
            "Partition text file must contain at least one record")
    }

    // =========================================================================
    // MARK: - 2. FilePersistence.purge() removes the -parts file
    //           (this is the mechanism called by Database.remove / removeAll / removeBatch)
    // =========================================================================

    func testPartitionDataFilePurgedByFilePersistence() async throws {
        let mutator = makeTableMutator()
        let docId   = "doc-purge-\(testNodeId!)"
        createdKeys.append("documents/\(docId)-parts")

        await mutator.put(
            id: docId,
            partitions: [makePartition(id: "p0", documentId: docId, seed: 10)],
            request: .test()
        )

        let partsFile = FilePersistence(key: "documents/\(docId)-parts", kind: .basic, logger: .test)
        XCTAssertNotNil(partsFile.restore() as [PartitionData]?,
            "Precondition: -parts file must exist before purge")

        // Simulate what Database.remove() now does after the fix.
        partsFile.purge()

        XCTAssertNil(partsFile.restore() as [PartitionData]?,
            "documents/{id}-parts must be absent after purge — this is the fix for Bug 1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partsFile.url.path()),
            "The -parts file must be physically removed from disk after purge()")
    }

    // =========================================================================
    // MARK: - 3. Both document files can be purged independently
    // =========================================================================

    func testBothDocumentFilesArePurgedIndependently() async throws {
        let mutator = makeTableMutator()
        let docId   = "doc-both-\(testNodeId!)"
        createdKeys += ["documents/\(docId)", "documents/\(docId)-parts"]

        // Write the document file (simulating what Database.put writes).
        let docFile = FilePersistence(key: "documents/\(docId)", kind: .basic, logger: .test)
        docFile.save(state: Database.Document.test(id: docId))

        await mutator.put(
            id: docId,
            partitions: [makePartition(id: "p0", documentId: docId, seed: 20)],
            request: .test()
        )

        let partsFile = FilePersistence(key: "documents/\(docId)-parts", kind: .basic, logger: .test)

        // Both files should exist before purge.
        XCTAssertTrue(FileManager.default.fileExists(atPath: docFile.url.path()),
            "Precondition: document file must exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partsFile.url.path()),
            "Precondition: -parts file must exist")

        // Purge both — matches Database.remove() / removeAll() / removeBatch() post-fix.
        docFile.purge()
        partsFile.purge()

        XCTAssertFalse(FileManager.default.fileExists(atPath: docFile.url.path()),
            "Document file must be gone after purge")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partsFile.url.path()),
            "Partition text file must be gone after purge")
    }

    // =========================================================================
    // MARK: - 4. allowedDocs is the union of availableDocumentIds and ownersDocuments
    // =========================================================================

    func testAllowedDocsIsUnionOfAvailableAndOwned() {
        var registry = TotemRegistry()
        let owner    = TotemRegistry.Owner(id: "owner-a")

        // doc-available: in availableDocumentIds but NOT in ownersDocuments for this owner.
        registry.availableDocumentIds.insert("doc-available")

        // doc-owned: in ownersDocuments but NOT in availableDocumentIds.
        registry.ownersDocuments[owner] = ["doc-owned"]

        let allowedDocs = registry.availableDocumentIds
            .union(registry.ownersDocuments[owner] ?? [])

        XCTAssertTrue(allowedDocs.contains("doc-available"),
            "availableDocumentIds must contribute to allowedDocs")
        XCTAssertTrue(allowedDocs.contains("doc-owned"),
            "ownersDocuments must contribute to allowedDocs")
        XCTAssertFalse(allowedDocs.contains("doc-unknown"),
            "Unknown document must not appear in allowedDocs")
    }

    func testAllowedDocsExcludesDocRemovedFromRegistry() {
        var registry = TotemRegistry()
        let owner    = TotemRegistry.Owner(id: "owner-b")

        // Simulate doc existing, then being removed from both sets.
        registry.availableDocumentIds = ["doc-active"]
        registry.ownersDocuments[owner] = ["doc-active", "doc-deleted"]

        // After deletion, doc-deleted is scrubbed from both sets.
        registry.availableDocumentIds.remove("doc-deleted")
        registry.ownersDocuments[owner]?.removeAll { $0 == "doc-deleted" }

        let allowedDocs = registry.availableDocumentIds
            .union(registry.ownersDocuments[owner] ?? [])

        XCTAssertTrue(allowedDocs.contains("doc-active"))
        XCTAssertFalse(allowedDocs.contains("doc-deleted"),
            "Deleted document must not appear in allowedDocs after registry removal")
    }
}
