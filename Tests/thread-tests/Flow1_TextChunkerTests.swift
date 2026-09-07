//
//  Flow1_TextChunkerTests.swift
//  database-serverTests
//

import XCTest
@testable import thread

final class Flow1_TextChunkerTests: XCTestCase {

    private let max = 100  // small limit so tests don't need large strings

    func testEmptyStringReturnsEmpty() {
        XCTAssertEqual(TextChunker.chunk("", maxChars: max), [])
    }

    func testShortTextReturnsSingleChunk() {
        let text = "Hello world"
        let result = TextChunker.chunk(text, maxChars: max)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], text)
    }

    func testShortParagraphsMergedUnderLimit() {
        // Two short paragraphs that together fit within max
        let text = "First para.\n\nSecond para."
        XCTAssertLessThanOrEqual(text.count, max)
        let result = TextChunker.chunk(text, maxChars: max)
        XCTAssertEqual(result.count, 1, "Two short paragraphs must be merged into one chunk")
    }

    func testParagraphsExceedingLimitSplit() {
        // Build two paragraphs whose combined length exceeds max
        let para = String(repeating: "x", count: 60)
        let text = para + "\n\n" + para
        XCTAssertGreaterThan(text.count, max)
        let result = TextChunker.chunk(text, maxChars: max)
        XCTAssertGreaterThanOrEqual(result.count, 2, "Paragraphs exceeding limit must be split into multiple chunks")
        for chunk in result {
            XCTAssertLessThanOrEqual(chunk.count, max, "Every chunk must be ≤ maxChars")
        }
    }

    func testOversizedParagraphSplitBySentence() {
        // One paragraph with two sentences, total > max but each sentence ≤ max
        let s1 = String(repeating: "a", count: 60) + ". "
        let s2 = String(repeating: "b", count: 60) + "."
        let para = s1 + s2
        XCTAssertGreaterThan(para.count, max)
        let result = TextChunker.chunk(para, maxChars: max)
        XCTAssertGreaterThanOrEqual(result.count, 2, "Oversized paragraph must be split at sentence boundary")
        for chunk in result {
            XCTAssertLessThanOrEqual(chunk.count, max)
        }
    }

    func testOversizedSentenceHardSplit() {
        // One long string with no sentence or paragraph boundaries
        let text = String(repeating: "z", count: max * 3)
        let result = TextChunker.chunk(text, maxChars: max)
        XCTAssertGreaterThanOrEqual(result.count, 3, "No-boundary text must be hard-split")
        for chunk in result {
            XCTAssertLessThanOrEqual(chunk.count, max)
        }
    }

    func testArrayOverloadFlatMapsElements() {
        let a = "Hello"
        let b = "World"
        let combined = TextChunker.chunk([a, b], maxChars: max)
        let individual = TextChunker.chunk(a, maxChars: max) + TextChunker.chunk(b, maxChars: max)
        XCTAssertEqual(combined, individual, "Array overload must equal flatMap of individual chunk calls")
    }

    func testAllChunksRespectMaxChars() {
        let input = (0..<20).map { "Paragraph \($0): " + String(repeating: "word ", count: 30) }.joined(separator: "\n\n")
        let result = TextChunker.chunk(input, maxChars: max)
        XCTAssertFalse(result.isEmpty)
        for chunk in result {
            XCTAssertLessThanOrEqual(chunk.count, max, "Chunk '\(chunk.prefix(20))…' exceeds maxChars")
        }
    }

    func testWhitespaceOnlyParagraphsDropped() {
        let text = "First.\n\n   \n\nSecond."
        let result = TextChunker.chunk(text, maxChars: max)
        XCTAssertFalse(result.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
            "Whitespace-only paragraphs must be dropped")
    }
}
