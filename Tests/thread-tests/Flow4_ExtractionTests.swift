//
//  Flow4_ExtractionTests.swift
//  thread-tests
//
//  Keyword fallback + the pure LLM-output parser (no MLX required).
//

import XCTest
import Logging
@testable import thread

final class Flow4_ExtractionTests: XCTestCase {

    func test_keywordFallback_producesConceptEntities_noRelationships() async throws {
        let provider = KeywordGraphExtractionProvider()
        let payload = try await provider.extract(
            from: ["radioactivity research radium polonium radioactivity research radium"],
            logger: .test
        )
        XCTAssertFalse(payload.entities.isEmpty)
        XCTAssertTrue(payload.entities.allSatisfy { $0.kind == "concept" })
        XCTAssertTrue(payload.relationships.isEmpty)
    }

    func test_parser_acceptsBareJSON() throws {
        let json = """
        {"entities":[{"name":"Marie Curie","kind":"person"},{"name":"Radium","kind":"concept"}],\
        "relationships":[{"subject":"Marie Curie","predicate":"discovered","object":"Radium"}]}
        """
        let payload = try GraphExtractionParser.parse(json)
        XCTAssertEqual(payload.entities.count, 2)
        XCTAssertEqual(payload.relationships.count, 1)
        XCTAssertEqual(payload.relationships.first?.predicate, "discovered")
    }

    func test_parser_acceptsProseAndFencedJSON() throws {
        let fenced = """
        Sure, here is the graph:
        ```json
        {"entities":[{"name":"Alpha","kind":"concept"}],"relationships":[]}
        ```
        Hope that helps!
        """
        let payload = try GraphExtractionParser.parse(fenced)
        XCTAssertEqual(payload.entities.count, 1)
        XCTAssertEqual(payload.entities.first?.name, "Alpha")
    }

    func test_parser_dropsRelationshipsReferencingUnknownEntities() throws {
        let json = """
        {"entities":[{"name":"A","kind":"concept"}],\
        "relationships":[{"subject":"A","predicate":"rel","object":"Ghost"}]}
        """
        let payload = try GraphExtractionParser.parse(json)
        XCTAssertEqual(payload.entities.count, 1)
        XCTAssertTrue(payload.relationships.isEmpty, "object 'Ghost' not among entities")
    }

    func test_parser_defaultsMissingKindToConcept_dropsEmptyNames() throws {
        let json = """
        {"entities":[{"name":"NoKind"},{"name":"  "}],"relationships":[]}
        """
        let payload = try GraphExtractionParser.parse(json)
        XCTAssertEqual(payload.entities.count, 1)
        XCTAssertEqual(payload.entities.first?.kind, "concept")
    }

    func test_parser_throwsOnMalformedInput() {
        XCTAssertThrowsError(try GraphExtractionParser.parse("there is no json object here"))
    }
}
