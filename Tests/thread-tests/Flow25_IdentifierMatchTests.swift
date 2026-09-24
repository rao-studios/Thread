//
//  Flow25_IdentifierMatchTests.swift
//  thread-tests
//
//  The code instrument's entity match: identifiers matched exactly against entity
//  names with their namespace stripped. Prose matching is untouched.
//

import XCTest
@testable import thread

final class Flow25_IdentifierMatchTests: XCTestCase {

    private func ent(_ name: String, _ kind: String) -> Database.GraphPayload.EntityIn { .init(name: name, kind: kind) }

    /// Craft's naming: declared symbols `sym:`, unresolved references `type:`, plus files,
    /// modules, a memory and one prose entity.
    private func graph() -> GraphStore {
        var g = GraphStore()
        _ = g.upsert(.init(entities: [ent("sym:Session", "struct"), ent("sym:Session.send", "function"),
                                      ent("file:Sources/A.swift", "file"), ent("module:Foundation", "module")]),
                     documentId: "d1")
        _ = g.upsert(.init(entities: [ent("sym:Session", "symbol")]), documentId: "d2")
        _ = g.upsert(.init(entities: [ent("sym:Session", "symbol")]), documentId: "d3")
        _ = g.upsert(.init(entities: [ent("sym:Session+ext@42", "extension")]), documentId: "d4")
        _ = g.upsert(.init(entities: [ent("type:posix_spawn", "function")]), documentId: "d5")
        _ = g.upsert(.init(entities: [ent("memory:2026-09-20-launch.md", "memory"),
                                      ent("sym:fn Repl.handle(_:)", "symbol")]), documentId: "m1")
        _ = g.upsert(.init(entities: [ent("Marie Curie", "person")]), documentId: "p1")
        for i in 0..<30 { _ = g.upsert(.init(entities: [ent("type:String", "type")]), documentId: "s\(i)") }
        return g
    }

    private func names(_ matches: [(entity: Entity, score: Float)]) -> [String] { matches.map(\.entity.name) }

    func test_exactIdentifierMatchesItsNamespacedEntity() {
        let m = graph().matchIdentifiers(["posix_spawn"], hubDegreeCap: 24)
        XCTAssertEqual(names(m), ["type:posix_spawn"])
        XCTAssertEqual(m.first?.score, 1.0)
    }

    func test_lastComponentAndDottedSuffix() {
        let g = graph()
        let bySend = g.matchIdentifiers(["send"], hubDegreeCap: 24)
        XCTAssertEqual(names(bySend), ["sym:Session.send"])
        XCTAssertEqual(bySend.first?.score, 0.6)
        XCTAssertEqual(g.matchIdentifiers(["Session.send"], hubDegreeCap: 24).first?.score, 1.0)

        var nested = GraphStore()
        _ = nested.upsert(.init(entities: [ent("sym:App.Session.send", "function")]), documentId: "n1")
        XCTAssertEqual(nested.matchIdentifiers(["Session.send"], hubDegreeCap: 24).first?.score, 0.8)
    }

    func test_declarationBeforeReferencesAcrossKinds() {
        let m = graph().matchIdentifiers(["Session"], hubDegreeCap: 24)
        // Every `sym:Session` entity and the extension match exactly; the declaration and the
        // extension live in one document each, the references in two.
        XCTAssertEqual(Set(names(m)), ["sym:Session", "sym:Session+ext@42"])
        XCTAssertEqual(m.count, 3, "struct, extension and the symbol-kind reference are three entities")
        XCTAssertEqual(m.last?.entity.kind, "symbol")
    }

    func test_hubsAreSkipped() {
        XCTAssertTrue(graph().matchIdentifiers(["String"], hubDegreeCap: 24).isEmpty)
        XCTAssertEqual(names(graph().matchIdentifiers(["String"], hubDegreeCap: 100)), ["type:String"])
    }

    func test_filesAndModulesAreNotIdentifiers() {
        let g = graph()
        XCTAssertTrue(g.matchIdentifiers(["Foundation"], hubDegreeCap: 24).isEmpty)
        XCTAssertTrue(g.matchIdentifiers(["Sources/A.swift", "A.swift"], hubDegreeCap: 24).isEmpty)
    }

    func test_aMemoryScopeWrittenWithItsKindMatchesItsName() {
        XCTAssertEqual(names(graph().matchIdentifiers(["Repl.handle"], hubDegreeCap: 24)), ["sym:fn Repl.handle(_:)"])
    }

    func test_caseSensitive() {
        XCTAssertTrue(graph().matchIdentifiers(["session", "POSIX_SPAWN"], hubDegreeCap: 24).isEmpty)
    }

    func test_proseEntitiesAreUntouched() {
        let g = graph()
        XCTAssertTrue(g.matchIdentifiers(["Curie", "Marie"], hubDegreeCap: 24).isEmpty)
        XCTAssertEqual(g.matchEntities(nameQuery: "curie").map(\.entity.name), ["Marie Curie"])
    }

    func test_identifierTermsFromEntitiesAndText() {
        let terms = GraphStore.identifierTerms(
            queryText: "How does `posix_spawn` get called from ProcessRunner.run(_:) when the NSApplication delegate fires? Session opens twice in 2026.",
            entities: ["kill", "  "])
        XCTAssertEqual(terms, ["kill", "posix_spawn", "ProcessRunner.run", "NSApplication"])
    }

    func test_identifierTermsIgnorePlainEnglish() {
        XCTAssertTrue(GraphStore.identifierTerms(queryText: "kill a child process group on timeout", entities: []).isEmpty)
    }
}
