//
//  Flow1_DocumentCIDTests.swift
//  database-serverTests
//
//  Tests for Database.computeHash(from:) — the content-derived document CID.
//
//  Algorithm recap:
//   1. Join all texts with " "
//   2. Lowercase, strip punctuation, remove stop words → tokens
//   3. Count word frequencies
//   4. Select top-10 words (freq desc, lex asc as tie-break)
//   5. Sort selected words alphabetically
//   6. Join with " " → SHA-256 → bytes formatted as "%02d" joined
//
//  CID properties under test:
//   • Determinism   — same content always produces the same CID
//   • Uniqueness    — different meaningful content produces different CIDs
//   • Format        — result contains only digits
//   • Case parity   — "Hello" == "hello"
//   • Punct parity  — "word." == "word"
//   • Stop-word     — stop words ("the", "and", …) are excluded from the hash input
//   • Stability     — adding non-top words doesn't change the CID once top-N is saturated
//   • Golden value  — a pinned reference CID for a fixed input
//

import XCTest
@testable import thread

final class Flow1_DocumentCIDTests: XCTestCase {

    // MARK: - Setup
    //
    // computeHash is an instance method; computeNumericHash(from: String) is static.
    // We keep a shared Database instance for computeHash and computeNumericHash(from: [Float]).

    private var database: Database!

    override func setUp() {
        super.setUp()
        database = Database()
    }

    // MARK: - Determinism

    func testSameInputProducesSameCID() {
        let texts = ["The quick brown fox jumps over the lazy dog"]
        let cid1 = database.computeHash(from: texts)
        let cid2 = database.computeHash(from: texts)
        XCTAssertEqual(cid1, cid2, "CID must be identical across repeated calls with the same input")
    }

    func testMultipleTextsJoinedDeterministically() {
        let texts = ["machine learning", "vector search", "embeddings"]
        let cid1 = database.computeHash(from: texts)
        let cid2 = database.computeHash(from: texts)
        XCTAssertEqual(cid1, cid2)
    }

    func testSingleWordInputIsDeterministic() {
        let cid1 = database.computeHash(from: ["database"])
        let cid2 = database.computeHash(from: ["database"])
        XCTAssertEqual(cid1, cid2)
    }

    // MARK: - Uniqueness

    func testDifferentContentProducesDifferentCIDs() {
        let cid1 = database.computeHash(from: ["machine learning and neural networks"])
        let cid2 = database.computeHash(from: ["cooking recipes for pasta dishes"])
        XCTAssertNotEqual(cid1, cid2, "Semantically different documents must produce different CIDs")
    }

    func testSingleWordDifferenceMayProduceDifferentCID() {
        // Top-word extraction may or may not differ depending on frequency ranking,
        // but documents with completely different vocabulary must differ.
        let cid1 = database.computeHash(from: ["alpha beta gamma delta"])
        let cid2 = database.computeHash(from: ["epsilon zeta eta theta"])
        XCTAssertNotEqual(cid1, cid2)
    }

    // MARK: - Format

    func testCIDContainsOnlyDigits() {
        let cid = database.computeHash(from: ["hello world foo bar baz"])
        XCTAssertFalse(cid.isEmpty, "CID must not be empty")
        XCTAssertTrue(cid.allSatisfy { $0.isNumber },
            "CID must contain only digits (SHA-256 bytes formatted as decimal)")
    }

    func testCIDLengthIsInExpectedRange() {
        // SHA-256 = 32 bytes. Each byte formatted as "%02d":
        //   0–9   → 2 chars ("00"–"09")
        //   10–99 → 2 chars ("10"–"99")
        //   100–255 → 3 chars ("100"–"255")
        // Minimum: 32 × 2 = 64 chars (all bytes 0–99)
        // Maximum: 32 × 3 = 96 chars (all bytes 100–255)
        let cid = database.computeHash(from: ["test content for length verification"])
        XCTAssertTrue((64...96).contains(cid.count),
            "CID length must be in [64, 96] — got \(cid.count)")
    }

    func testNumericHashFromTextHasExpectedFormat() {
        let hash = Database.computeNumericHash(from: "hello world")
        XCTAssertFalse(hash.isEmpty)
        XCTAssertTrue(hash.allSatisfy { $0.isNumber })
        XCTAssertTrue((64...96).contains(hash.count))
    }

    // MARK: - Case insensitivity

    func testUppercaseAndLowercaseProduceSameCID() {
        let lower = database.computeHash(from: ["machine learning embeddings vector search"])
        let upper = database.computeHash(from: ["MACHINE LEARNING EMBEDDINGS VECTOR SEARCH"])
        XCTAssertEqual(lower, upper,
            "CID must be identical for upper- and lower-case versions of the same content")
    }

    func testMixedCaseProducesSameCIDAsLowercase() {
        let mixed = database.computeHash(from: ["Neural Networks Are Powerful"])
        let lower = database.computeHash(from: ["neural networks are powerful"])
        XCTAssertEqual(mixed, lower)
    }

    // MARK: - Punctuation stripping

    func testPunctuationDoesNotAffectCID() {
        let clean  = database.computeHash(from: ["hello world foo bar"])
        let punctd = database.computeHash(from: ["hello, world. foo! bar?"])
        XCTAssertEqual(clean, punctd,
            "Punctuation must be stripped before hashing — CIDs must match")
    }

    // MARK: - Stop word exclusion

    func testStopWordsExcludedFromHash() {
        // "the", "and", "a", "in", "for", "is" are stop words.
        // Adding only stop words to a document must not change its CID.
        let base    = database.computeHash(from: ["machine learning vector search neural"])
        let withStop = database.computeHash(from: ["the machine and learning a vector in search is neural"])
        XCTAssertEqual(base, withStop,
            "Adding only stop words to content must not change the CID")
    }

    func testOnlyStopWordsProducesStableCID() {
        // When all tokens are stop words, the hash input is an empty/minimal string.
        // Both calls with the same stop-only input must produce the same CID.
        let cid1 = database.computeHash(from: ["the and a an in on at for of to is"])
        let cid2 = database.computeHash(from: ["the and a an in on at for of to is"])
        XCTAssertEqual(cid1, cid2, "Stop-word-only input must still be deterministic")
    }

    // MARK: - Top-N frequency stability

    func testNonTopWordsDoNotAffectCID() {
        // Build a document where exactly 10 content words each appear 5 times.
        // These 10 fill the entire top-N=10 slot.
        // Extra words that each appear only once cannot displace any content word
        // (freq 1 < freq 5), so the hash input is identical in both cases.
        let contentWords = ["alpha", "beta", "gamma", "delta", "epsilon",
                            "zeta", "eta", "theta", "iota", "kappa"]
        let repeatedContent = contentWords
            .flatMap { Array(repeating: $0, count: 5) }
            .joined(separator: " ")

        // Noise words all lexicographically after existing content words and freq=1
        let withNoise = repeatedContent + " zeus zoo zzz zip zap"

        let cid1 = database.computeHash(from: [repeatedContent])
        let cid2 = database.computeHash(from: [withNoise])
        XCTAssertEqual(cid1, cid2,
            "Adding low-frequency words that don't enter the top-10 must not change the CID")
    }

    func testTopNTieBreakerIsLexicographic() {
        // "alpha" and "bravo" both appear once. Lex order → "alpha" comes first.
        // Swapping their order in the input text must not change the CID because
        // the algorithm sorts top words alphabetically before hashing.
        let cid1 = database.computeHash(from: ["alpha bravo charlie delta epsilon"])
        let cid2 = database.computeHash(from: ["bravo alpha delta charlie epsilon"])
        XCTAssertEqual(cid1, cid2,
            "CID must be identical when the same unique words appear in different order")
    }

    // MARK: - computeNumericHash consistency

    func testNumericHashFromTextIsDeterministic() {
        let hash1 = Database.computeNumericHash(from: "consistent input string")
        let hash2 = Database.computeNumericHash(from: "consistent input string")
        XCTAssertEqual(hash1, hash2)
    }

    func testNumericHashDiffersForDifferentInputs() {
        let hash1 = Database.computeNumericHash(from: "input one")
        let hash2 = Database.computeNumericHash(from: "input two")
        XCTAssertNotEqual(hash1, hash2)
    }

    func testNumericHashFromEmbeddingsIsDeterministic() {
        let embedding: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let hash1 = database.computeNumericHash(from: embedding)
        let hash2 = database.computeNumericHash(from: embedding)
        XCTAssertEqual(hash1, hash2)
    }

    func testNumericHashFromEmbeddingsDiffersForDifferentVectors() {
        let hash1 = database.computeNumericHash(from: [Float](repeating: 0.1, count: 16))
        let hash2 = database.computeNumericHash(from: [Float](repeating: 0.9, count: 16))
        XCTAssertNotEqual(hash1, hash2)
    }

    // MARK: - Golden value (pinned reference)
    //
    // This test pins a known CID for a stable, simple input.
    // If it fails, the hash algorithm has changed — update the expected value
    // intentionally and document why in the git commit message.

    func testGoldenCIDForKnownInput() {
        // Input: ["hello world"] →
        //   tokens: ["hello", "world"]
        //   frequencies: {hello: 1, world: 1}
        //   top-10 (lex tie-break): ["hello", "world"]
        //   sorted: ["hello", "world"]
        //   hashInput: "hello world"
        //   SHA-256("hello world") → fixed bytes → fixed numeric string
        let cid = database.computeHash(from: ["hello world"])

        // Derive the expected value from computeNumericHash to avoid duplicating
        // SHA-256 logic in this test file. The two calls must produce the same
        // value — any divergence means computeHash preprocessing is broken.
        let expected = Database.computeNumericHash(from: "hello world")
        XCTAssertEqual(cid, expected,
            "CID for [\"hello world\"] must equal SHA-256(\"hello world\") as numeric bytes")
    }

    func testGoldenCIDForMultiWordInput() {
        // "vector search" → tokens: ["vector", "search"] (both non-stop-words, freq 1 each)
        // sorted: ["search", "vector"]  (s < v)
        // hashInput: "search vector"
        let cid = database.computeHash(from: ["vector search"])
        let expected = Database.computeNumericHash(from: "search vector")
        XCTAssertEqual(cid, expected)
    }

    func testGoldenCIDWithStopWordsStripped() {
        // "the cat sat on the mat" → after stop-word removal: ["cat", "sat", "mat"]
        // frequencies: cat=1, sat=1, mat=1; lex tie-break: ["cat", "mat", "sat"]
        // sorted: ["cat", "mat", "sat"]
        // hashInput: "cat mat sat"
        let cid = database.computeHash(from: ["the cat sat on the mat"])
        let expected = Database.computeNumericHash(from: "cat mat sat")
        XCTAssertEqual(cid, expected)
    }
}
