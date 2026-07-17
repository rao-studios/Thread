//
//  PerfBaselineTests.swift
//  totem-tests
//
//  Baseline benchmarks for the indexing hot paths. Run in release mode:
//
//      swift test -c release --filter PerfBaselineTests
//
//  Re-run after each optimization phase to quantify wins.
//
//  Scalar-implementation baselines (release, Apple Silicon, 2026-06-09):
//    QuantizerTrain_3     ~66 µs
//    QuantizerTrain_50    ~1.6 ms
//    QuantizerTrain_200   ~7 ms
//    QuantizerTrain_1000  ~124 ms
//    QuantizerEncode_200  ~2.9 ms   (k=16 codebooks)
//    ADC_Table_Plus_10kLookups ~0.4 ms
//    PutBatch_20Docs_10Partitions ~86 ms
//

import XCTest
@testable import totem

final class PerfBaselineTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixtures

    private static let dim = VectorFixtures.embeddingDim  // 1024

    private func vectors(_ count: Int, seedBase: UInt64) -> [[Float]] {
        (0..<count).map { VectorFixtures.random(dim: Self.dim, seed: seedBase &+ UInt64($0)) }
    }

    // MARK: - PartitionQuantizer.train

    /// Tiny per-document index (social-post scale): v=3 → k=2.
    func testPerf_QuantizerTrain_3() {
        let vecs = vectors(3, seedBase: 100)
        measure {
            var pq = PartitionQuantizer()
            pq.train(vectors: vecs)
        }
    }

    /// Mid-size document: v=50 → k=2 (50/39 = 1 → clamped to min 2).
    func testPerf_QuantizerTrain_50() {
        let vecs = vectors(50, seedBase: 200)
        measure {
            var pq = PartitionQuantizer()
            pq.train(vectors: vecs)
        }
    }

    /// Large document: v=200 → k=4.
    func testPerf_QuantizerTrain_200() {
        let vecs = vectors(200, seedBase: 300)
        measure {
            var pq = PartitionQuantizer()
            pq.train(vectors: vecs)
        }
    }

    /// Corpus-scale training: v=1000 → k=16.
    func testPerf_QuantizerTrain_1000() {
        let vecs = vectors(1000, seedBase: 400)
        measure {
            var pq = PartitionQuantizer()
            pq.train(vectors: vecs)
        }
    }

    // MARK: - PartitionQuantizer.encode

    /// Encode 200 vectors against a corpus-trained quantizer (k=16).
    func testPerf_QuantizerEncode_200() {
        var pq = PartitionQuantizer()
        pq.train(vectors: vectors(1000, seedBase: 500))
        let toEncode = vectors(200, seedBase: 600)
        measure {
            for v in toEncode {
                _ = pq.encode(vector: v)
            }
        }
    }

    // MARK: - ADC: buildDistanceTable + computeDistance

    /// One distance-table build plus 10k ADC lookups — the per-query PQ search cost.
    func testPerf_ADC_Table_Plus_10kLookups() {
        var pq = PartitionQuantizer()
        pq.train(vectors: vectors(1000, seedBase: 700))
        let query = VectorFixtures.random(dim: Self.dim, seed: 999)
        let codes = vectors(100, seedBase: 800).map { pq.encode(vector: $0) }
        measure {
            let table = pq.buildDistanceTable(queryVector: query)
            var acc: Float = 0
            for _ in 0..<100 {
                for c in codes {
                    acc += pq.computeDistance(table: table, documentCodes: c)
                }
            }
            XCTAssertGreaterThan(acc, 0)
        }
    }

    // MARK: - End-to-end TableMutator.putBatch

    /// 20 docs × 10 partitions per measured iteration: PQ train + graph upsert
    /// + persistence scheduling. Fresh mutator per iteration so cost isn't
    /// skewed by growth across iterations. (Re-baseline: linear ADC engine.)
    func testPerf_PutBatch_20Docs_10Partitions() throws {
        let docCount = 20
        let partitionsPerDoc = 10
        let allEmbeddings = vectors(docCount * partitionsPerDoc, seedBase: 1_000)

        let items = (0..<docCount).map { d -> (id: DocumentID, partitions: [Database.Partition], graph: Database.GraphPayload, entityEmbedding: [Float]?, metadata: Data?, request: DatabaseRequest) in
            let parts = (0..<partitionsPerDoc).map { p in
                Database.Partition.test(
                    id: "perf-p\(d)-\(p)",
                    documentId: "perf-doc\(d)",
                    embedding: allEmbeddings[d * partitionsPerDoc + p]
                )
            }
            return ("perf-doc\(d)", parts, .init(), nil, nil, .test())
        }

        measure {
            let exp = expectation(description: "putBatch")
            Task {
                let mutator = TableMutator.test()
                mutator.seed(PartitionTable())
                mutator.seedGraph(GraphStore())

                await mutator.putBatch(items: items)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 120)
        }
    }
}
