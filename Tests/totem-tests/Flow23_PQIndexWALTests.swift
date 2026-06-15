//
//  Flow23_PQIndexWALTests.swift
//  totem-tests
//
//  Crash-consistency for PQ indices. Before the index WAL, a crash between an
//  HNSW insert and the (debounced) full indices flush lost the document's PQ
//  index until re-indexed. The WAL closes that window to a single append per
//  put. markIndicesReady() no longer tombstones missing-index nodes — they are
//  preserved (recoverable from raw vectors + `-parts`) and reported only. These
//  tests cover the record format, crash replay, non-destructive recovery, and
//  removal semantics.
//

import XCTest
@testable import totem

final class Flow23_PQIndexWALTests: XCTestCase {

    private var tempDir: URL!
    private var testNodeId: UUID!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pq-wal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        testNodeId = UUID()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        // Remove all persistence files created under this test's nodeId.
        let db = FilePersistence.getDefaultURL()
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: db, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) {
            for url in contents where url.lastPathComponent.contains(testNodeId.uuidString) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Helpers

    private func makeMutator() throws -> TableMutator {
        let store = try HNSWVectorStore(
            url: tempDir.appendingPathComponent("vec-\(UUID().uuidString)"),
            nodeCount: 0
        )
        var table = PartitionTable()
        table.shards[0].vectorStore = store
        let mutator = TableMutator(nodeId: testNodeId, logger: .test)
        mutator.seed(table)
        mutator.seedVectorStore(store)
        return mutator
    }

    private func makeItems(_ count: Int, partitionsPerDoc: Int = 2, seedBase: UInt64 = 7000)
        -> [(id: DocumentID, partitions: [Database.Partition], tags: [String], tagsEmbedding: [Float]?, metadata: Data?, request: DatabaseRequest)] {
        (0..<count).map { d in
            let parts = (0..<partitionsPerDoc).map { p in
                Database.Partition.test(
                    id: "wal-p\(d)-\(p)",
                    documentId: "wal-doc\(d)",
                    embedding: VectorFixtures.random(dim: HNSWVectorStore.vectorDim,
                                                     seed: seedBase &+ UInt64(d * 100 + p))
                )
            }
            return ("wal-doc\(d)", parts, ["tag\(d)"], nil, nil, .test())
        }
    }

    // MARK: - 1. Record round-trip + tail discard

    func testRecordRoundTrip() throws {
        let url = tempDir.appendingPathComponent("roundtrip-wal")
        let wal = try PartitionIndexWAL(url: url)

        let payload = Data([0x01, 0x02, 0xff, 0x00, 0x42])
        try wal.append(.indexPut(documentId: "doc-α", payload: payload))
        try wal.append(.indexRemoved(documentId: "doc-β"))
        try wal.append(.commit)

        let records = try wal.readAll()
        XCTAssertEqual(records, [
            .indexPut(documentId: "doc-α", payload: payload),
            .indexRemoved(documentId: "doc-β"),
        ])
    }

    func testUncommittedTailDiscarded() throws {
        let url = tempDir.appendingPathComponent("tail-wal")
        let wal = try PartitionIndexWAL(url: url)

        try wal.append(.indexPut(documentId: "committed", payload: Data([1])))
        try wal.append(.commit)
        try wal.append(.indexPut(documentId: "uncommitted", payload: Data([2])))
        // No .commit — simulates a crash mid-mutation-group.

        let records = try wal.readAll()
        XCTAssertEqual(records, [.indexPut(documentId: "committed", payload: Data([1]))],
            "Records after the last .commit must be discarded")
    }

    func testCorruptTailDiscarded() throws {
        let url = tempDir.appendingPathComponent("corrupt-wal")
        let wal = try PartitionIndexWAL(url: url)

        try wal.append(.indexPut(documentId: "good", payload: Data([1, 2, 3])))
        try wal.append(.commit)

        // Append garbage bytes directly (simulates torn write / bit rot).
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x01, 0xff, 0xff, 0xff, 0x7f, 0xde, 0xad]))
        try handle.close()

        let reopened = try PartitionIndexWAL(url: url)
        let records = try reopened.readAll()
        XCTAssertEqual(records, [.indexPut(documentId: "good", payload: Data([1, 2, 3]))],
            "Corrupt tail must not poison previously committed records")
    }

    // MARK: - 2. Crash simulation — indices survive without any checkpoint

    /// The user-facing consistency scenario: documents indexed, server dies
    /// before any full indices flush. A fresh mutator over the same node files
    /// must recover every PQ index from the WAL, and markIndicesReady must
    /// tombstone nothing.
    func testIndicesSurviveCrashWithoutCheckpoint() async throws {
        let mutatorA = try makeMutator()
        let docCount = 5
        await mutatorA.putBatch(items: makeItems(docCount))

        // Snapshot for the "post-WAL-replay" topology; deliberately NO
        // flushAllForShutdown / checkpoint — the only index durability is the WAL.
        guard var crashedTable = mutatorA.snapshot else {
            return XCTFail("Snapshot must exist after putBatch")
        }
        XCTAssertEqual(crashedTable.keys.count, docCount)

        // Simulate the crash: in-memory indices are gone; topology survives
        // (in production it is restored via the topology WAL replay).
        for i in crashedTable.shards.indices {
            crashedTable.shards[i].indices = [:]
        }

        let mutatorB = TableMutator(nodeId: testNodeId, logger: .test)
        mutatorB.seed(crashedTable)

        let recovered = mutatorB.loadIndicesFromDisk()
        XCTAssertNotNil(recovered, "Index WAL must be discovered with no plist checkpoint present")
        let totalRecovered = (recovered ?? [:]).values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(totalRecovered, docCount,
            "Every document indexed before the crash must be recovered from the index WAL")

        await mutatorB.mergeIndices(recovered ?? [:])
        await mutatorB.markIndicesReady()

        guard let restored = mutatorB.snapshot else {
            return XCTFail("Snapshot must exist after merge")
        }
        XCTAssertEqual(restored.keys.count, docCount,
            "markIndicesReady must tombstone zero documents — all PQ indices were recovered")
        for d in 0..<docCount {
            XCTAssertNotNil(restored.index(for: "wal-doc\(d)"),
                "PQ index for wal-doc\(d) must be restored from the WAL")
        }
        let deleted = restored.shards.reduce(0) { $0 + $1.graphStats.deletedNodes }
        XCTAssertEqual(deleted, 0, "No HNSW nodes may be tombstoned after WAL recovery")
    }

    // MARK: - 2b. markIndicesReady never deletes unrecoverable orphans

    /// Regression guard: if a PQ index is genuinely missing at startup (no
    /// checkpoint, no WAL to recover it), markIndicesReady() must PRESERVE the
    /// HNSW node — its raw vector and `-parts` text are still on disk, so it is
    /// recoverable by re-indexing. The old behavior tombstoned these nodes via
    /// `table.remove(id:)`, silently and irreversibly destroying recoverable data
    /// on the first restart after the index-persistence rewrite.
    func testMarkIndicesReadyPreservesUnrecoverableOrphans() async throws {
        let mutator = try makeMutator()
        await mutator.putBatch(items: makeItems(3))

        guard var table = mutator.snapshot else {
            return XCTFail("Snapshot must exist after putBatch")
        }
        XCTAssertEqual(table.keys.count, 3)

        // Drop one document's PQ index but leave its key + HNSW nodes intact, and
        // keep at least one other index present so the empty-indices guard doesn't
        // short-circuit the inspection.
        let victim = "wal-doc1"
        for i in table.shards.indices {
            table.shards[i].indices.removeValue(forKey: victim)
        }
        XCTAssertNil(table.index(for: victim), "Victim index must be absent for the test setup")
        XCTAssertTrue(table.keys.contains(victim), "Victim key must remain in the graph")
        mutator.seed(table)

        await mutator.markIndicesReady()

        guard let after = mutator.snapshot else {
            return XCTFail("Snapshot must exist after markIndicesReady")
        }
        XCTAssertEqual(after.keys.count, 3,
            "markIndicesReady must not remove orphaned keys — data is recoverable")
        XCTAssertTrue(after.keys.contains(victim),
            "Orphaned document must be preserved, not tombstoned")
        let deleted = after.shards.reduce(0) { $0 + $1.graphStats.deletedNodes }
        XCTAssertEqual(deleted, 0,
            "No HNSW nodes may be tombstoned for a missing-but-recoverable PQ index")
    }

    // MARK: - 3. Removal — no resurrection on restart

    func testRemovedDocumentNotResurrectedOnReplay() async throws {
        let mutator = try makeMutator()
        await mutator.putBatch(items: makeItems(3))
        await mutator.remove(id: "wal-doc1")

        let recovered = mutator.loadIndicesFromDisk() ?? [:]
        let allDocs = Set(recovered.values.flatMap { $0.keys })
        XCTAssertFalse(allDocs.contains("wal-doc1"),
            "indexRemoved WAL record must prevent resurrection of removed documents")
        XCTAssertTrue(allDocs.isSuperset(of: ["wal-doc0", "wal-doc2"]),
            "Other documents' indices must survive the removal")
    }

    // MARK: - 4. Upsert — last write wins

    func testReindexAfterRemoveReplaysLatest() async throws {
        let mutator = try makeMutator()
        await mutator.putBatch(items: makeItems(1))
        await mutator.remove(id: "wal-doc0")
        // Re-index the same document with different content (new partition ids).
        await mutator.putBatch(items: makeItems(1, partitionsPerDoc: 3, seedBase: 9000))

        let recovered = mutator.loadIndicesFromDisk() ?? [:]
        let entry = recovered.values.compactMap { $0["wal-doc0"] }.first
        XCTAssertNotNil(entry, "Re-indexed document must be present after replay")
        XCTAssertEqual(entry?.slots.count, 3,
            "Replay must yield the latest index (3 partitions), not the removed 2-partition one")
    }
}
