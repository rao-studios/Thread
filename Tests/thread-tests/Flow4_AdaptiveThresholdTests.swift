//
//  Flow4_AdaptiveThresholdTests.swift
//  database-serverTests
//
//  Tests for the AdaptiveThreshold system:
//  - Per-document PQ threshold calibration from reconstruction errors
//  - Document size effect on threshold tightness
//

import XCTest
@testable import thread

final class Flow4_AdaptiveThresholdTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("database-flow4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }


    // MARK: - PQ Adaptive Threshold (per-document)

    func testPQAdaptiveThresholdIsNilBeforeTraining() {
        let pq = PartitionQuantizer()
        XCTAssertNil(pq.adaptiveThreshold)
    }

    func testPQEffectiveThresholdFallsBackToStaticWhenNil() {
        let pq = PartitionQuantizer()
        XCTAssertNil(pq.adaptiveThreshold)
        XCTAssertEqual(pq.effectiveThreshold, pq.distanceThreshold,
            "effectiveThreshold must equal static distanceThreshold when adaptiveThreshold is nil")
    }

    func testPQAdaptiveThresholdSetAfterTraining() {
        var pq = PartitionQuantizer()
        pq.train(vectors: (0..<10).map { VectorFixtures.random(seed: UInt64($0 + 600)) })
        XCTAssertNotNil(pq.adaptiveThreshold)
    }

    func testPQAdaptiveThresholdAtLeastStaticThreshold() {
        // Formula: max(mean + 1.5σ, distanceThreshold) — must never go below static
        var pq = PartitionQuantizer()
        pq.train(vectors: (0..<10).map { VectorFixtures.random(seed: UInt64($0 + 610)) })
        XCTAssertGreaterThanOrEqual(pq.adaptiveThreshold!, pq.distanceThreshold)
    }

    func testPQEffectiveThresholdEqualsAdaptiveWhenSet() {
        var pq = PartitionQuantizer()
        pq.train(vectors: (0..<10).map { VectorFixtures.random(seed: UInt64($0 + 620)) })
        XCTAssertEqual(pq.effectiveThreshold, pq.adaptiveThreshold!)
    }

    func testPQTightClusterHasLowerThresholdThanSpreadCluster() {
        // Tight cluster: all vectors near one center → low reconstruction error → low threshold
        var pqTight = PartitionQuantizer()
        let center = VectorFixtures.random(seed: 99)
        let tightVectors = (0..<20).map { VectorFixtures.near(center, seed: UInt64($0 + 700)) }
        pqTight.train(vectors: tightVectors)

        // Spread cluster: random diverse vectors → high reconstruction error → high threshold
        var pqSpread = PartitionQuantizer()
        let spreadVectors = (0..<20).map { VectorFixtures.random(seed: UInt64($0 + 800)) }
        pqSpread.train(vectors: spreadVectors)

        XCTAssertLessThanOrEqual(pqTight.adaptiveThreshold!, pqSpread.adaptiveThreshold!,
            "Tight cluster must produce a lower (tighter) adaptive threshold than a spread cluster")
    }

    func testPQAdaptiveThresholdFormulaCorrectness() {
        // Independently compute the expected threshold and compare with pq.adaptiveThreshold
        var pq = PartitionQuantizer()
        let vectors = (0..<10).map { VectorFixtures.random(seed: UInt64($0 + 900)) }
        pq.train(vectors: vectors)

        let errors = vectors.map {
            pq.computeDistance(queryVector: $0, documentCodes: pq.encode(vector: $0))
        }
        let mean = errors.reduce(0, +) / Float(errors.count)
        let variance = errors.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(errors.count)
        let expected = max(mean + 1.5 * variance.squareRoot(), pq.distanceThreshold)

        XCTAssertEqual(pq.adaptiveThreshold!, expected, accuracy: 1e-4,
            "Adaptive threshold must match the formula: max(mean + 1.5σ, distanceThreshold)")
    }
}
