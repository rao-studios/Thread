//
//  Flow25_CodeInstrumentSearchTests.swift
//  thread-tests
//
//  `media_type = code` inside the table search: a match boosts, never gates; a named
//  media type keeps only its partitions; code does not expand; every search is ranked
//  and cut at top_k.
//

import XCTest
@testable import thread

private func ent(_ name: String, _ kind: String = "concept") -> Database.GraphPayload.EntityIn {
    .init(name: name, kind: kind)
}

private func makeRegistry(owner: String, ownedDocs: [String], available: [String] = []) -> ThreadRegistry {
    var r = ThreadRegistry()
    let o = ThreadRegistry.Owner(id: owner)
    r.ownersDocuments[o] = ownedDocs
    for d in ownedDocs { r.documentOwners[d, default: []].insert(o) }
    r.availableDocumentIds = Set(available)
    return r
}

private func makePartitions(center: [Float], doc: String, owner: String, count: Int = 16) -> [Database.Partition] {
    (0..<count).map { i in
        Database.Partition.test(id: "\(doc)-p\(i)", documentId: doc,
                                embedding: VectorFixtures.near(center, seed: UInt64(i + 1)), ownerId: owner)
    }
}

private typealias SearchOutput = (partitions: [PartitionSearchResult], adjustments: [SinatraAdjustment], trace: GraphSearchTrace?)

private func resultDocs(_ r: SearchOutput) -> [String] {
    var seen = Set<String>()
    return r.partitions.flatMap { $0.partitions.map { $0.documentId } }.filter { seen.insert($0).inserted }
}

private func bestScorePerDoc(_ r: SearchOutput) -> [String: Float] {
    var best: [String: Float] = [:]
    for psr in r.partitions {
        for (s, p) in zip(psr.scores, psr.partitions) { best[p.documentId] = min(best[p.documentId] ?? .infinity, s) }
    }
    return best
}

final class Flow25_CodeInstrumentSearchTests: XCTestCase {

    private let owner = "o"
    private let query = VectorFixtures.unit(axis: 0)

    private func sinatra() -> Sinatra { Sinatra(logger: .test) }

    private func shifted(axis: Int, by amount: Float) -> [Float] {
        var v = query
        v[axis] += amount
        return v
    }

    /// d1 names `type:posix_spawn` and sits slightly farther from the query than d2, which
    /// names nothing.
    private func fixture() -> (table: PartitionTable, graph: GraphStore, posix: EntityID, registry: ThreadRegistry) {
        var graph = GraphStore()
        let d1Entities = graph.upsert(.init(entities: [ent("type:posix_spawn", "function")]), documentId: "d1")
        var table = PartitionTable()
        table.put(id: "d1", partitions: makePartitions(center: shifted(axis: 4, by: 0.11), doc: "d1", owner: owner),
                  entityIds: d1Entities, request: .test(ownerId: owner), logger: .test)
        table.put(id: "d2", partitions: makePartitions(center: shifted(axis: 8, by: 0.10), doc: "d2", owner: owner),
                  request: .test(ownerId: owner), logger: .test)
        return (table, graph, d1Entities[0], makeRegistry(owner: owner, ownedDocs: ["d1", "d2"]))
    }

    private func search(_ f: (table: PartitionTable, graph: GraphStore, posix: EntityID, registry: ThreadRegistry),
                        mediaType: MediaType?, scores: [EntityID: Float] = [:],
                        matchedEntityIds: Set<EntityID> = [], matchedRelationshipIds: Set<RelationshipID> = [],
                        topK: Int? = nil, loader: PartitionDataLoader? = nil) -> SearchOutput {
        f.table.search(embedding: query, matchedEntityIds: matchedEntityIds,
                       matchedRelationshipIds: matchedRelationshipIds, identifierScores: scores,
                       graph: f.graph, sinatra: sinatra(), registry: f.registry,
                       request: .test(ownerId: owner, mediaType: mediaType, topK: topK),
                       metadataLoader: loader, logger: .test)
    }

    func test_codeBoostsWithoutGating() {
        let f = fixture()
        let prose = search(f, mediaType: nil)
        XCTAssertEqual(resultDocs(prose).first, "d2", "unboosted, the entity-less d2 is closer")

        let code = search(f, mediaType: .code, scores: [f.posix: 1.0], matchedEntityIds: [f.posix])
        XCTAssertEqual(resultDocs(code), ["d1", "d2"], "d1 is boosted past d2, and d2 is still returned")
        XCTAssertEqual(bestScorePerDoc(code)["d1"]!, bestScorePerDoc(prose)["d1"]! * 0.85, accuracy: 1e-5)
        XCTAssertEqual(code.trace?.matchedEntityNames, ["type:posix_spawn"])
        XCTAssertEqual(code.trace?.mediaType, "code")
        XCTAssertEqual(code.trace?.boostedDocumentCount, 1)
    }

    func test_theBoostHasAFloor() {
        let f = fixture()
        var graph = f.graph
        let more = graph.upsert(.init(entities: [ent("type:kill", "function"), ent("type:waitpid", "function"),
                                                 ent("type:SIGTERM", "type")]), documentId: "d1")
        let scores = Dictionary(uniqueKeysWithValues: ([f.posix] + more).map { ($0, Float(1.0)) })
        let boosted = (f.table, graph, f.posix, f.registry)
        let code = search(boosted, mediaType: .code, scores: scores)
        let prose = search(boosted, mediaType: nil)
        XCTAssertEqual(bestScorePerDoc(code)["d1"]! / bestScorePerDoc(prose)["d1"]!, 0.6, accuracy: 1e-5)
    }

    func test_proseStillGates() {
        let f = fixture()
        XCTAssertEqual(resultDocs(search(f, mediaType: nil, matchedEntityIds: [f.posix])), ["d1"])
        XCTAssertEqual(resultDocs(search(f, mediaType: .text, matchedEntityIds: [f.posix])), ["d1"])
    }

    func test_codeIgnoresARelationshipGate() {
        let f = fixture()
        let code = search(f, mediaType: .code, matchedRelationshipIds: ["no-such-relationship"])
        XCTAssertEqual(Set(resultDocs(code)), ["d1", "d2"])
        XCTAssertEqual(code.trace?.mediaType, "code", "a code search always says what it applied")
    }

    func test_aNamedMediaTypeKeepsOnlyItsPartitions() {
        let f = fixture()
        let loader: PartitionDataLoader = { doc, part in
            PartitionData(id: part, url: URL(fileURLWithPath: "/\(doc)"), mediaType: doc == "d1" ? .code : .text,
                          data: part, ownerId: "o")
        }
        XCTAssertEqual(resultDocs(search(f, mediaType: .code, loader: loader)), ["d1"])
        XCTAssertEqual(resultDocs(search(f, mediaType: .text, loader: loader)), ["d2"])
        XCTAssertEqual(Set(resultDocs(search(f, mediaType: nil, loader: loader))), ["d1", "d2"])
    }

    func test_everySearchIsRankedAndCutAtTopK() {
        let f = fixture()
        for mediaType in [nil, MediaType.code] {
            let all = search(f, mediaType: mediaType)
            XCTAssertEqual(all.partitions.count, 1, "one ranked block")
            let scores = all.partitions.first?.scores ?? []
            XCTAssertEqual(scores, scores.sorted())
            XCTAssertEqual(search(f, mediaType: mediaType, topK: 2).partitions.first?.scores.count, 2)
        }
    }

    func test_codeDoesNotExpand() {
        var graph = GraphStore()
        let d1Entities = graph.upsert(.init(entities: [ent("sym:Parser", "struct")]), documentId: "d1")
        _ = graph.upsert(.init(entities: [ent("sym:Parser", "struct"), ent("sym:Lexer", "struct")],
                               relationships: [.init(subject: "sym:Parser", predicate: "calls", object: "sym:Lexer")]),
                         documentId: "d3")
        var table = PartitionTable()
        table.put(id: "d1", partitions: makePartitions(center: query, doc: "d1", owner: owner),
                  entityIds: d1Entities, request: .test(ownerId: owner), logger: .test)
        table.put(id: "d3", partitions: makePartitions(center: shifted(axis: 3, by: 0.5), doc: "d3", owner: owner),
                  request: .test(ownerId: owner), logger: .test)
        // d3 is readable but not the owner's, so only expansion can reach it.
        let registry = makeRegistry(owner: owner, ownedDocs: ["d1"], available: ["d3"])
        let f = (table, graph, d1Entities[0], registry)

        XCTAssertEqual(resultDocs(search(f, mediaType: nil)), ["d1", "d3"], "prose expands one hop to d3")
        XCTAssertEqual(resultDocs(search(f, mediaType: .code)), ["d1"], "code does not expand")
    }
}
