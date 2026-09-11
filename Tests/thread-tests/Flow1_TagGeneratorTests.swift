//
//  Flow1_TagGeneratorTests.swift
//  database-serverTests
//

import XCTest
@testable import thread

final class Flow1_TagGeneratorTests: XCTestCase {

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(TagGenerator.generate(from: []), [])
        XCTAssertEqual(TagGenerator.generate(from: [""]), [])
    }

    func testFrequencyOrdering() {
        // "alpha" appears 3×, "beta" appears 1× — alpha must rank first
        let texts = ["alpha alpha alpha beta"]
        let tags = TagGenerator.generate(from: texts)
        guard let alphaIdx = tags.firstIndex(of: "alpha"),
              let betaIdx  = tags.firstIndex(of: "beta") else {
            XCTFail("Expected both 'alpha' and 'beta' in tags: \(tags)")
            return
        }
        XCTAssertLessThan(alphaIdx, betaIdx, "'alpha' (3×) must rank before 'beta' (1×)")
    }

    func testStopwordsExcluded() {
        // Stopwords from the list: "that", "from", "with", "will"
        let texts = ["that from with will content words present here"]
        let tags = TagGenerator.generate(from: texts)
        XCTAssertFalse(tags.contains("that"), "stopword 'that' must be excluded")
        XCTAssertFalse(tags.contains("from"), "stopword 'from' must be excluded")
        XCTAssertFalse(tags.contains("with"), "stopword 'with' must be excluded")
        XCTAssertFalse(tags.contains("will"), "stopword 'will' must be excluded")
        XCTAssertTrue(tags.contains("content") || tags.contains("words") || tags.contains("present"),
            "content words must be present in tags: \(tags)")
    }

    func testMaxTagsLimit() {
        // 50 distinct long words — output must not exceed maxTags
        let words = (0..<50).map { "uniqueword\($0)" }.joined(separator: " ")
        let tags = TagGenerator.generate(from: [words])
        XCTAssertLessThanOrEqual(tags.count, TagGenerator.maxTags,
            "output must be capped at maxTags (\(TagGenerator.maxTags))")
    }

    func testShortTokensExcluded() {
        // Words ≤ 3 chars must be filtered (filter is > 3, so 4+ chars pass)
        let texts = ["the and or a an is are be do go big huge enormous"]
        let tags = TagGenerator.generate(from: texts)
        for tag in tags {
            XCTAssertGreaterThan(tag.count, 3, "tag '\(tag)' is too short (must be > 3 chars)")
        }
    }
}
