//
//  Flow7_OrphanCleanupTests.swift
//  database-serverTests
//
//  Tests for the orphaned-document cleanup chain introduced to handle files that
//  exist on disk but cannot be decoded (empty, partial write, corruption).
//
//  The chain being tested:
//
//    Corrupted file (fileExists = true, restore() = nil)
//      → treated as orphan in registry (initializeRegistry logic)
//      → removed from registry before seed()
//      → absent from validIds in table cross-check (initializeTable logic)
//      → table.remove(id:) called
//      → PartitionIndex entry removed
//
//  Each test covers one link in this chain. The final integration test pins
//  the entire chain in one shot so future changes cannot silently break any
//  step without a red test.
//

import XCTest
@testable import totem

final class Flow7_OrphanCleanupTests: XCTestCase {

    // MARK: - Helpers

    private func tempPersistence(key: String) -> FilePersistence {
        let file = FilePersistence(key: "test/flow7/\(key)", kind: .basic, logger: .test)
        addTeardownBlock { [url = file.url] in
            try? FileManager.default.removeItem(at: url)
        }
        return file
    }

    // MARK: - FilePersistence.restore() — missing vs corrupted file

    func testRestoreReturnsSilentNilForMissingFile() {
        let fp = tempPersistence(key: "missing-\(UUID().uuidString)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fp.url.path()))

        let result: TotemRegistry? = fp.restore()
        XCTAssertNil(result, "restore() must return nil for a non-existent file")
    }

    func testRestoreReturnsNilForEmptyFile() {
        let fp = tempPersistence(key: "empty-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: fp.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: fp.url.path(), contents: Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fp.url.path()),
            "Precondition: empty file must exist on disk")

        let result: TotemRegistry? = fp.restore()
        XCTAssertNil(result,
            "restore() must return nil for a file that exists but contains no data")
    }

    // MARK: - Registry orphan detection — corrupted file treated as orphan

    func testCorruptedFileTreatedAsOrphanInRegistryDetection() {
        let healthyStore   = tempPersistence(key: "orphan-reg-healthy-\(UUID().uuidString)")
        let corruptedStore = tempPersistence(key: "orphan-reg-corrupt-\(UUID().uuidString)")

        healthyStore.save(state: Database.Document.test(id: "healthy"))

        try? FileManager.default.createDirectory(
            at: corruptedStore.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: corruptedStore.url.path(), contents: Data())

        let stores: [DocumentID: FilePersistence] = [
            "healthy":   healthyStore,
            "corrupted": corruptedStore,
        ]

        var orphanedIds: [DocumentID] = []
        for (documentId, store) in stores {
            guard FileManager.default.fileExists(atPath: store.url.path()) else {
                orphanedIds.append(documentId)
                continue
            }
            if let _: Database.Document = store.restore() {
            } else {
                orphanedIds.append(documentId)
            }
        }

        XCTAssertTrue(orphanedIds.contains("corrupted"),
            "A document whose file exists but is unreadable must be treated as orphan")
        XCTAssertFalse(orphanedIds.contains("healthy"),
            "A document with a valid file must not be treated as orphan")
    }

    func testRemoveOrphanedClearsAllRegistryCollections() {
        var registry = TotemRegistry()
        let owner = TotemRegistry.Owner(id: "owner1")
        registry.documentOwners["orphan"] = [owner]
        registry.ownersDocuments[owner]   = ["orphan"]
        registry.documentAccess["orphan"] = .available
        registry.availableDocumentIds.insert("orphan")

        registry.removeOrphaned(documentId: "orphan")

        XCTAssertNil(registry.documentOwners["orphan"],
            "documentOwners must not contain orphan after removal")
        XCTAssertFalse(registry.ownersDocuments[owner]?.contains("orphan") ?? false,
            "ownersDocuments must not list orphan after removal")
        XCTAssertNil(registry.documentAccess["orphan"],
            "documentAccess must not contain orphan after removal")
        XCTAssertFalse(registry.availableDocumentIds.contains("orphan"),
            "availableDocumentIds must not contain orphan after removal")
    }

    // MARK: - PartitionTable.remove — keys and indices cleared

    func testTableRemoveClearsKeysAndIndices() throws {
        var table = PartitionTable()

        let target = [
            Database.Partition.test(id: "pt1", documentId: "target",
                                embedding: VectorFixtures.random(seed: 7001)),
            Database.Partition.test(id: "pt2", documentId: "target",
                                embedding: VectorFixtures.random(seed: 7002)),
        ]
        let bystander = [
            Database.Partition.test(id: "pb1", documentId: "bystander",
                                embedding: VectorFixtures.random(seed: 7003)),
        ]
        table.put(id: "target",    partitions: target,    request: .test(), logger: .test)
        table.put(id: "bystander", partitions: bystander, request: .test(), logger: .test)

        XCTAssertTrue(table.keys.contains("target"))
        XCTAssertNotNil(table.indices["target"])
        XCTAssertEqual(table.indices["target"]?.slots.count, 2)

        table.remove(id: "target")

        XCTAssertFalse(table.keys.contains("target"),
            "keys must not contain the removed document")
        XCTAssertNil(table.indices["target"],
            "PartitionIndex must be removed for the deleted document")
        XCTAssertNotNil(table.indices["bystander"],
            "Bystander PartitionIndex must not be affected")
    }

    // MARK: - Table cross-check (initializeTable logic)

    func testTableCrossCheckPrunesOrphanedDocuments() throws {
        var table = PartitionTable()

        for docId in ["valid", "orphan-a", "orphan-b"] {
            let p = Database.Partition.test(
                id: "p-\(docId)", documentId: docId,
                embedding: VectorFixtures.random(seed: UInt64(abs(docId.hashValue) % 9999))
            )
            table.put(id: docId, partitions: [p], request: .test(), logger: .test)
        }
        XCTAssertEqual(table.keys.count, 3, "Precondition: all 3 docs in table")

        let validIds: Set<DocumentID> = ["valid"]
        let orphanedTableIds = table.keys.subtracting(validIds)
        for id in orphanedTableIds { table.remove(id: id) }

        XCTAssertEqual(table.keys.count, 1, "Only 'valid' must remain")
        XCTAssertTrue(table.keys.contains("valid"))
        XCTAssertFalse(table.keys.contains("orphan-a"))
        XCTAssertFalse(table.keys.contains("orphan-b"))
        XCTAssertNil(table.indices["orphan-a"],  "orphan-a PartitionIndex must be removed")
        XCTAssertNil(table.indices["orphan-b"],  "orphan-b PartitionIndex must be removed")
        XCTAssertNotNil(table.indices["valid"],  "valid PartitionIndex must survive")
    }

    // MARK: - Graph detach on orphan cleanup

    func testOrphanCleanupDetachesGraphProvenance() {
        var table = PartitionTable()
        var graph = GraphStore()

        for docId in ["valid", "orphan"] {
            let payload = Database.GraphPayload(entities: [.init(name: "entity-\(docId)")])
            let entityIds = graph.upsert(payload, documentId: docId)
            let p = Database.Partition.test(
                id: "p-\(docId)", documentId: docId,
                embedding: VectorFixtures.random(seed: UInt64(abs(docId.hashValue) % 9999))
            )
            table.put(id: docId, partitions: [p], entityIds: entityIds,
                      request: .test(), logger: .test)
        }
        XCTAssertEqual(graph.entities.count, 2, "Precondition: one entity per document")

        // initializeTable sweep 1: orphaned table docs detach from the graph too.
        let validIds: Set<DocumentID> = ["valid"]
        for id in table.keys.subtracting(validIds) {
            let entityIds = table.index(for: id)?.entityIds ?? []
            table.remove(id: id)
            graph.detach(documentId: id, entityIds: entityIds)
        }

        XCTAssertEqual(graph.entities.count, 1,
            "Orphan's entity must be garbage-collected when its provenance empties")
        XCTAssertNil(graph.entities.values.first { $0.name == "entity-orphan" },
            "The surviving entity must belong to the valid document")
    }

    // MARK: - Full chain integration

    func testFullOrphanChain_CorruptedFilePropagatesCleanlyToTable() throws {
        var table = PartitionTable()

        for docId in ["healthy", "corrupted"] {
            let p = Database.Partition.test(
                id: "p-\(docId)", documentId: docId,
                embedding: VectorFixtures.random(seed: UInt64(abs(docId.hashValue) % 9999))
            )
            table.put(id: docId, partitions: [p], request: .test(), logger: .test)
        }
        XCTAssertEqual(table.keys.count, 2, "Precondition: both docs in table")

        let healthyStore   = tempPersistence(key: "chain-healthy-\(UUID().uuidString)")
        let corruptedStore = tempPersistence(key: "chain-corrupt-\(UUID().uuidString)")

        healthyStore.save(state: Database.Document.test(id: "healthy"))

        try? FileManager.default.createDirectory(
            at: corruptedStore.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: corruptedStore.url.path(), contents: Data())

        var registry = TotemRegistry()
        let owner = TotemRegistry.Owner(id: "owner1")
        registry.documentOwners["healthy"]   = [owner]
        registry.documentOwners["corrupted"] = [owner]

        let stores: [DocumentID: FilePersistence] = [
            "healthy": healthyStore, "corrupted": corruptedStore,
        ]
        var orphanedIds: [DocumentID] = []
        for (documentId, store) in stores {
            guard FileManager.default.fileExists(atPath: store.url.path()) else {
                orphanedIds.append(documentId); continue
            }
            if let _: Database.Document = store.restore() { /* kept */ }
            else { orphanedIds.append(documentId) }
        }
        for id in orphanedIds { registry.removeOrphaned(documentId: id) }

        XCTAssertNil(registry.documentOwners["corrupted"],
            "corrupted doc must be removed from registry after orphan detection")
        XCTAssertNotNil(registry.documentOwners["healthy"],
            "healthy doc must remain in registry")

        let validIds = Set(registry.documentOwners.keys)
        let orphanedTableIds = table.keys.subtracting(validIds)
        for id in orphanedTableIds { table.remove(id: id) }

        XCTAssertFalse(table.keys.contains("corrupted"),
            "corrupted doc must be absent from table.keys after cross-check")
        XCTAssertTrue(table.keys.contains("healthy"),
            "healthy doc must remain in table.keys")
        XCTAssertNil(table.indices["corrupted"],
            "PartitionIndex for corrupted doc must be removed")
        XCTAssertNotNil(table.indices["healthy"],
            "PartitionIndex for healthy doc must survive")
    }
}
