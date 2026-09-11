//
//  Flow1_NumericHashTests.swift
//  thread-tests
//
//  computeNumericHash output is a persisted document/partition ID. The
//  optimized implementation (single buffer copy + lookup-table decimal
//  encoding) must remain byte-identical to the historical
//  `String(format: "%02d", byte)` SHA-256 encoding forever.
//

import XCTest
import Crypto
@testable import thread

final class Flow1_NumericHashTests: XCTestCase {

    // MARK: - Historical reference implementations (do not modify)

    private func referenceHash(from text: String) -> String {
        let data = text.data(using: .utf8)!
        let hash = SHA256.hash(data: data)
        return Array(hash).map { String(format: "%02d", $0) }.joined()
    }

    private func referenceHash(from embeddings: [Float], documentId: String?) -> String {
        var byteArray = [UInt8]()
        for float in embeddings {
            byteArray.append(contentsOf: withUnsafeBytes(of: float) { Array($0) })
        }
        if let docId = documentId, let docIdBytes = docId.data(using: .utf8) {
            byteArray.append(contentsOf: docIdBytes)
        }
        let hash = SHA256.hash(data: Data(byteArray))
        return Array(hash).map { String(format: "%02d", $0) }.joined()
    }

    private var database: Database!

    override func setUp() {
        super.setUp()
        database = Database()
    }

    // MARK: - Tests

    func testTextHashMatchesHistoricalEncoding() {
        for text in ["", "a", "hello world", "πßé emoji 🚀", String(repeating: "x", count: 10_000)] {
            XCTAssertEqual(Database.computeNumericHash(from: text), referenceHash(from: text),
                "Text hash diverged for input prefix: \(text.prefix(20))")
        }
    }

    func testEmbeddingHashMatchesHistoricalEncoding() {
        let cases: [([Float], String?)] = [
            ([], nil),
            ([0.0], nil),
            ([1.5, -2.25, 3.75], nil),
            (VectorFixtures.random(dim: 1024, seed: 42), nil),
            (VectorFixtures.random(dim: 1024, seed: 43), "doc-abc"),
            ([Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, .ulpOfOne], "doc-π"),
        ]
        for (embeddings, docId) in cases {
            XCTAssertEqual(
                database.computeNumericHash(from: embeddings, documentId: docId),
                referenceHash(from: embeddings, documentId: docId),
                "Embedding hash diverged (dim: \(embeddings.count), docId: \(docId ?? "nil"))"
            )
        }
    }

    /// Bytes ≥ 100 encode as three digits — make sure a hash containing them
    /// round-trips identically (every SHA-256 output virtually guarantees some).
    func testThreeDigitBytesPreserved() {
        let hash = Database.computeNumericHash(from: "three-digit-bytes")
        XCTAssertEqual(hash, referenceHash(from: "three-digit-bytes"))
        XCTAssertGreaterThan(hash.count, 64, "Expected some 3-digit bytes in SHA-256 output")
    }
}
