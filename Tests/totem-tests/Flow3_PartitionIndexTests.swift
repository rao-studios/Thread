//
//  Flow3_PartitionIndexTests.swift
//  database-serverTests
//
//  Tests for PartitionIndex: PQ training, embedding compression,
//  and per-document search correctness.
//

import XCTest
@testable import totem

final class Flow3_PartitionIndexTests: XCTestCase {

    // MARK: - Helpers

    /// Build a trained PartitionIndex from N random partitions.
    private func makeTrainedIndex(
        count: Int = 5,
        docId: String = "doc1",
        ownerId: String = "owner1"
    ) -> (PartitionIndex, [Database.Partition]) {
        var index = PartitionIndex()
        let partitions = (0..<count).map { i -> Database.Partition in
            Database.Partition.test(
                id: "p\(i)",
                documentId: docId,
                embedding: VectorFixtures.random(seed: UInt64(i + 500)),
                text: "word\(i) more example text",
                ownerId: ownerId
            )
        }
        index.train(partitions, documentId: docId, logger: .test)
        return (index, partitions)
    }

    // MARK: - Training

    func testEmbeddingsClearedAfterTrain() {
        let (index, _) = makeTrainedIndex()
        // Slots store only compressed codes — raw embeddings are discarded during training.
        XCTAssertFalse(index.slots.isEmpty, "Slots must be populated after training")
        for slot in index.slots {
            XCTAssertNotNil(slot.compressedEmbedding,
                "compressedEmbedding must be set (raw embedding is discarded during PQ training)")
        }
    }

    func testCompressedEmbeddingSetAfterTrain() {
        let (index, _) = makeTrainedIndex()
        for slot in index.slots {
            XCTAssertNotNil(slot.compressedEmbedding,
                "compressedEmbedding must be populated after training")
            XCTAssertEqual(slot.compressedEmbedding!.count, index.pq.numSubvectors,
                "Compressed embedding length must equal numSubvectors")
        }
    }

    func testPartitionCountMatchesInput() {
        let count = 7
        let (index, _) = makeTrainedIndex(count: count)
        XCTAssertEqual(index.slots.count, count)
    }

    func testAdaptiveThresholdSetAfterTrain() {
        let (index, _) = makeTrainedIndex()
        XCTAssertNotNil(index.pq.adaptiveThreshold,
            "Adaptive threshold must be calibrated after training")
    }

    func testTrainingWithMinimalPartitions() {
        // Edge case: single partition — PQ falls back to k=2 codebook
        var index = PartitionIndex()
        let p = Database.Partition.test(
            id: "solo",
            documentId: "d",
            embedding: VectorFixtures.random(seed: 1)
        )
        // Should not crash with 1 partition
        index.train([p], documentId: "d", logger: .test)
        XCTAssertEqual(index.slots.count, 1)
    }

    // MARK: - searchWithScores (no Sinatra dependency)

    func testSearchWithScoresReturnsResults() {
        let (index, _) = makeTrainedIndex(count: 5)
        let query = VectorFixtures.random(seed: 100)
        let results = index.searchWithScores(queryEmbedding: query, k: 3)
        XCTAssertGreaterThan(results.count, 0)
        XCTAssertLessThanOrEqual(results.count, 3)
    }

    func testSearchWithScoresResultsSortedAscending() {
        let (index, _) = makeTrainedIndex(count: 10)
        let query = VectorFixtures.random(seed: 200)
        let results = index.searchWithScores(queryEmbedding: query, k: 5)

        for i in 1..<results.count {
            XCTAssertLessThanOrEqual(results[i-1].1, results[i].1,
                "Results must be sorted by ascending PQ distance")
        }
    }

    func testSearchWithScoresNearestPartitionIsCorrect() {
        // Build index with known vectors plus one "close" vector.
        var index = PartitionIndex()
        let query = VectorFixtures.random(seed: 7)
        let closeVec = VectorFixtures.near(query, seed: 77)

        var partitions: [Database.Partition] = []
        for i in 0..<8 {
            // Orthogonal unit vectors — far from the query
            partitions.append(Database.Partition.test(
                id: "far\(i)",
                documentId: "doc",
                embedding: VectorFixtures.unit(axis: i % VectorFixtures.dim)
            ))
        }
        partitions.append(Database.Partition.test(
            id: "near",
            documentId: "doc",
            embedding: closeVec
        ))
        index.train(partitions, documentId: "doc", logger: .test)

        let results = index.searchWithScores(queryEmbedding: query, k: 1)
        XCTAssertEqual(results.first?.0.id, "near",
            "The partition closest to the query must rank first")
    }

    func testSearchWithScoresReturnAllWhenKExceedsPartitions() {
        let (index, _) = makeTrainedIndex(count: 3)
        let results = index.searchWithScores(queryEmbedding: VectorFixtures.random(seed: 300), k: 10)
        XCTAssertEqual(results.count, 3, "Should return all available partitions when k > count")
    }

    func testSearchWithScoresDistancesAreNonNegative() {
        let (index, _) = makeTrainedIndex(count: 5)
        let results = index.searchWithScores(queryEmbedding: VectorFixtures.random(seed: 400), k: 5)
        for (_, distance) in results {
            XCTAssertGreaterThanOrEqual(distance, 0.0)
        }
    }

    // MARK: - Minimum-results fallback

    func testSearchFallsBackWhenThresholdRejectsAll() {
        var (index, _) = makeTrainedIndex(count: 5)
        // Force threshold to near-zero so every candidate fails the filter
        index.pq.adaptiveThreshold = 0.0001
        let query = VectorFixtures.random(seed: 999)
        let sinatra = Sinatra(logger: .test)
        let (result, _) = index.search(
            queryEmbedding: query, k: 3,
            sinatra: sinatra, sinatraRegistry: nil,
            request: .test(), logger: .test)
        XCTAssertFalse(result.partitions.isEmpty,
            "search must return best-effort top-k when all candidates exceed the threshold")
    }

    // MARK: - tagsEmbedding + tagDistance()

    func testTagsEmbeddingStoredAfterTrainWithTags() {
        var index = PartitionIndex()
        let partitions = (0..<5).map { i -> Database.Partition in
            Database.Partition.test(id: "p\(i)", documentId: "doc", embedding: VectorFixtures.random(seed: UInt64(i)))
        }
        let tagsEmbedding = VectorFixtures.random(seed: 777)
        index.train(partitions, tags: ["swift", "server"], tagsEmbedding: tagsEmbedding, documentId: "doc", logger: .test)

        XCTAssertNotNil(index.tagsEmbedding, "tagsEmbedding must be set after train with tags")
        XCTAssertEqual(index.tagsEmbedding?.count, tagsEmbedding.count)
    }

    func testTagsEmbeddingNilWhenNoTagsProvided() {
        var index = PartitionIndex()
        let partitions = [Database.Partition.test(id: "p0", documentId: "doc", embedding: VectorFixtures.random(seed: 1))]
        index.train(partitions, documentId: "doc", logger: .test)
        XCTAssertNil(index.tagsEmbedding, "tagsEmbedding must be nil when no tags are supplied")
    }

    func testTagDistanceReturnsNilWithoutTagsEmbedding() {
        let (index, _) = makeTrainedIndex()
        let result = index.tagDistance(queryEmbedding: VectorFixtures.random(seed: 10))
        XCTAssertNil(result, "tagDistance() must return nil when tagsEmbedding is nil")
    }

    func testTagDistanceReturnsLowValueForIdenticalUnitVectors() {
        var index = PartitionIndex()
        // unit(axis:) returns a vector with exactly one component = 1.0 → L2 norm = 1
        // dot(v, v) = 1 → tagDistance = 0
        let vec = VectorFixtures.unit(axis: 0)
        let partitions = [Database.Partition.test(id: "p0", documentId: "doc", embedding: vec)]
        index.train(partitions, tags: ["test"], tagsEmbedding: vec, documentId: "doc", logger: .test)

        let dist = index.tagDistance(queryEmbedding: vec)
        XCTAssertNotNil(dist)
        XCTAssertEqual(Double(dist!), 0.0, accuracy: 0.01,
            "identical unit vectors must produce tag distance ≈ 0")
    }

    func testTagDistanceReturnsOneForOrthogonalUnitVectors() {
        var index = PartitionIndex()
        let tagsVec  = VectorFixtures.unit(axis: 0)   // [1, 0, 0, …]
        let queryVec = VectorFixtures.unit(axis: 1)   // [0, 1, 0, …]
        let partitions = [Database.Partition.test(id: "p0", documentId: "doc", embedding: tagsVec)]
        index.train(partitions, tags: ["a"], tagsEmbedding: tagsVec, documentId: "doc", logger: .test)

        let dist = index.tagDistance(queryEmbedding: queryVec)
        XCTAssertNotNil(dist)
        // dot(orthogonal unit vectors) = 0 → tagDistance = 1.0
        XCTAssertEqual(Double(dist!), 1.0, accuracy: 0.01,
            "orthogonal unit vectors must produce tag distance = 1.0")
    }

    func testTagSimilarityThresholdConstantIsReasonable() {
        XCTAssertGreaterThan(PartitionIndex.tagSimilarityThreshold, 0.0)
        XCTAssertLessThan(PartitionIndex.tagSimilarityThreshold, 1.0)
    }

    // MARK: - Metadata

    func testMetadataNilByDefault() {
        let (index, _) = makeTrainedIndex()
        XCTAssertNil(index.metadata, "metadata must be nil when not set")
    }

    func testMetadataStoredViaDirectAssignment() {
        var (index, _) = makeTrainedIndex()
        let payload = Data("test-payload".utf8)
        index.metadata = payload
        XCTAssertEqual(index.metadata, payload, "metadata must equal the assigned payload")
    }

    func testMetadataPersistsRoundTrip() throws {
        var (index, _) = makeTrainedIndex()
        let payload = Data("round-trip".utf8)
        index.metadata = payload

        let encoded = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(PartitionIndex.self, from: encoded)
        XCTAssertEqual(decoded.metadata, payload, "metadata must survive JSON encode/decode round-trip")
    }

    func testMetadataRoundTripNilPreserved() throws {
        let (index, _) = makeTrainedIndex()
        XCTAssertNil(index.metadata)

        let encoded = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(PartitionIndex.self, from: encoded)
        XCTAssertNil(decoded.metadata, "nil metadata must remain nil after round-trip")
    }

    // MARK: - Top-k selection equivalence

    /// The bounded-insertion top-k selection must return exactly the full-sort
    /// prefix (same slots, same order) for arbitrary k and slot counts.
    func testTopKSelectionEqualsFullSortPrefix() {
        let (index, _) = makeTrainedIndex(count: 60)

        for (qSeed, k) in [(UInt64(1), 1), (2, 3), (3, 10), (4, 59), (5, 60), (6, 200)] {
            let query = VectorFixtures.random(seed: qSeed)

            // Reference: score every slot, full sort, prefix k.
            let table = index.pq.buildDistanceTable(queryVector: query)
            var reference: [(id: String, distance: Float)] = []
            for slot in index.slots {
                guard let codes = slot.compressedEmbedding else { continue }
                reference.append((slot.id, index.pq.computeDistance(table: table, documentCodes: codes)))
            }
            reference.sort { $0.distance < $1.distance }
            let expected = Array(reference.prefix(k))

            let got = index.searchWithScores(queryEmbedding: query, k: k)
            XCTAssertEqual(got.count, expected.count, "k=\(k)")
            for (g, e) in zip(got, expected) {
                XCTAssertEqual(g.1, e.distance, accuracy: 1e-6,
                    "k=\(k): selection distance must equal full-sort prefix")
            }
        }
    }
}
