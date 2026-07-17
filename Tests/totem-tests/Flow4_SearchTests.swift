//
//  Flow4_SearchTests.swift
//  totem-tests
//
//  Entity pre-filter semantics, ADC scan correctness, one-hop graph expansion, and
//  table persistence round-trip.
//

import XCTest
@testable import totem

// MARK: - Helpers

private func ent(_ name: String, _ kind: String = "concept", _ emb: [Float]? = nil) -> Database.GraphPayload.EntityIn {
    .init(name: name, kind: kind, embedding: emb)
}

private func makeRegistry(owner: String, ownedDocs: [String], available: [String] = []) -> TotemRegistry {
    var r = TotemRegistry()
    let o = TotemRegistry.Owner(id: owner)
    r.ownersDocuments[o] = ownedDocs
    for d in ownedDocs { r.documentOwners[d, default: []].insert(o) }
    r.availableDocumentIds = Set(available)
    return r
}

private func makePartitions(center: [Float], doc: String, owner: String, count: Int = 16) -> [Database.Partition] {
    (0..<count).map { i in
        Database.Partition.test(
            id: "\(doc)-p\(i)", documentId: doc,
            embedding: VectorFixtures.near(center, seed: UInt64(i + 1)),
            ownerId: owner
        )
    }
}

private typealias SearchOutput = (partitions: [PartitionSearchResult], adjustments: [SinatraAdjustment], trace: GraphSearchTrace?)

private func resultDocs(_ r: SearchOutput) -> [String] {
    r.partitions.flatMap { $0.partitions.map { $0.documentId } }
}

private func bestScorePerDoc(_ r: SearchOutput) -> [String: Float] {
    var best: [String: Float] = [:]
    for psr in r.partitions {
        for (s, p) in zip(psr.scores, psr.partitions) {
            best[p.documentId] = min(best[p.documentId] ?? .infinity, s)
        }
    }
    return best
}

final class Flow4_SearchTests: XCTestCase {

    private let owner = "o"
    private lazy var a = VectorFixtures.unit(axis: 0)
    private lazy var b = VectorFixtures.unit(axis: 8)

    private func sinatra() -> Sinatra { Sinatra(logger: .test) }

    // MARK: - Entity pre-filter

    func test_unentitiedPasses_entitiedNonMatchingExcluded() {
        var t = PartitionTable()
        t.put(id: "d1", partitions: makePartitions(center: a, doc: "d1", owner: owner),
              entityIds: [], entityEmbedding: nil, request: .test(ownerId: owner), logger: .test)
        let catId = GraphStore.entityID(kind: "concept", name: "cat")
        t.put(id: "d2", partitions: makePartitions(center: a, doc: "d2", owner: owner),
              entityIds: [catId], entityEmbedding: VectorFixtures.unit(axis: 0),
              request: .test(ownerId: owner), logger: .test)
        let reg = makeRegistry(owner: owner, ownedDocs: ["d1", "d2"])

        let dogId = GraphStore.entityID(kind: "concept", name: "dog")
        let r = t.search(embedding: a, queryEntityEmbedding: nil, matchedEntityIds: [dogId],
                         graph: nil, sinatra: sinatra(), registry: reg,
                         request: .test(ownerId: owner), logger: .test)
        let docs = Set(resultDocs(r))
        XCTAssertTrue(docs.contains("d1"), "un-entitied doc always passes")
        XCTAssertFalse(docs.contains("d2"), "entitied doc with no matched entity is gated out")
    }

    func test_matchedEntityGatesLinkedDocIn() {
        var t = PartitionTable()
        let catId = GraphStore.entityID(kind: "concept", name: "cat")
        t.put(id: "d2", partitions: makePartitions(center: a, doc: "d2", owner: owner),
              entityIds: [catId], entityEmbedding: VectorFixtures.unit(axis: 0),
              request: .test(ownerId: owner), logger: .test)
        let reg = makeRegistry(owner: owner, ownedDocs: ["d2"])

        let r = t.search(embedding: a, matchedEntityIds: [catId], graph: nil,
                         sinatra: sinatra(), registry: reg, request: .test(ownerId: owner), logger: .test)
        XCTAssertTrue(Set(resultDocs(r)).contains("d2"))
    }

    func test_embeddingGate_closeIncluded_farExcluded() {
        var t = PartitionTable()
        t.put(id: "d1", partitions: makePartitions(center: a, doc: "d1", owner: owner),
              entityIds: [], entityEmbedding: nil, request: .test(ownerId: owner), logger: .test)
        let catId = GraphStore.entityID(kind: "concept", name: "cat")
        t.put(id: "d2", partitions: makePartitions(center: a, doc: "d2", owner: owner),
              entityIds: [catId], entityEmbedding: VectorFixtures.unit(axis: 0),
              request: .test(ownerId: owner), logger: .test)
        let reg = makeRegistry(owner: owner, ownedDocs: ["d1", "d2"])

        let close = t.search(embedding: a, queryEntityEmbedding: VectorFixtures.unit(axis: 0),
                             matchedEntityIds: [], graph: nil, sinatra: sinatra(), registry: reg,
                             request: .test(ownerId: owner), logger: .test)
        XCTAssertTrue(Set(resultDocs(close)).contains("d2"), "close entity embedding includes doc")

        let far = t.search(embedding: a, queryEntityEmbedding: VectorFixtures.unit(axis: 10),
                           matchedEntityIds: [], graph: nil, sinatra: sinatra(), registry: reg,
                           request: .test(ownerId: owner), logger: .test)
        let farDocs = Set(resultDocs(far))
        XCTAssertFalse(farDocs.contains("d2"), "far entity embedding excludes doc")
        XCTAssertTrue(farDocs.contains("d1"), "un-entitied still passes")
    }

    func test_skipFilter_whenNoMatchedAndNilEmbedding() {
        var t = PartitionTable()
        let catId = GraphStore.entityID(kind: "concept", name: "cat")
        t.put(id: "d1", partitions: makePartitions(center: a, doc: "d1", owner: owner),
              entityIds: [catId], entityEmbedding: VectorFixtures.unit(axis: 0),
              request: .test(ownerId: owner), logger: .test)
        t.put(id: "d2", partitions: makePartitions(center: a, doc: "d2", owner: owner),
              entityIds: [], entityEmbedding: nil, request: .test(ownerId: owner), logger: .test)
        let reg = makeRegistry(owner: owner, ownedDocs: ["d1", "d2"])

        let r = t.search(embedding: a, queryEntityEmbedding: nil, matchedEntityIds: [],
                         graph: nil, sinatra: sinatra(), registry: reg,
                         request: .test(ownerId: owner), logger: .test)
        let docs = Set(resultDocs(r))
        XCTAssertTrue(docs.contains("d1"))
        XCTAssertTrue(docs.contains("d2"), "no entity signal → filter skipped entirely")
    }

    // MARK: - ADC correctness

    func test_adc_nearestDocumentHasLowestDistance() {
        var t = PartitionTable()
        t.put(id: "d1", partitions: makePartitions(center: a, doc: "d1", owner: owner),
              request: .test(ownerId: owner), logger: .test)
        t.put(id: "d2", partitions: makePartitions(center: b, doc: "d2", owner: owner),
              request: .test(ownerId: owner), logger: .test)
        let reg = makeRegistry(owner: owner, ownedDocs: ["d1", "d2"])

        let r = t.search(embedding: a, sinatra: sinatra(), registry: reg,
                         request: .test(ownerId: owner), logger: .test)
        let best = bestScorePerDoc(r)
        XCTAssertNotNil(best["d1"])
        XCTAssertNotNil(best["d2"])
        XCTAssertLessThan(best["d1"]!, best["d2"]!, "query near d1's center scores it closer")
    }

    // MARK: - Graph expansion

    /// Builds a table + graph where d1 owns entities {A,B} with edge A→B, and d2 owns {B}.
    /// A query gated to entity A returns only d1 directly; expansion should reach d2 via B.
    private func makeExpansionFixture(ownedDocs: [String]) -> (PartitionTable, GraphStore, TotemRegistry, EntityID) {
        var g = GraphStore()
        let d1Ids = g.upsert(.init(entities: [ent("A"), ent("B")],
                                   relationships: [.init(subject: "A", predicate: "to", object: "B")]),
                             documentId: "d1")
        let d2Ids = g.upsert(.init(entities: [ent("B")]), documentId: "d2")

        var t = PartitionTable()
        t.put(id: "d1", partitions: makePartitions(center: a, doc: "d1", owner: owner),
              entityIds: d1Ids, request: .test(ownerId: owner), logger: .test)
        t.put(id: "d2", partitions: makePartitions(center: b, doc: "d2", owner: owner),
              entityIds: d2Ids, request: .test(ownerId: owner), logger: .test)

        let reg = makeRegistry(owner: owner, ownedDocs: ownedDocs)
        let aId = GraphStore.entityID(kind: "concept", name: "A")
        return (t, g, reg, aId)
    }

    func test_expansion_pullsNeighborDoc_afterDirectHits() {
        let (t, g, reg, aId) = makeExpansionFixture(ownedDocs: ["d1", "d2"])
        let r = t.search(embedding: a, matchedEntityIds: [aId], graph: g, expand: true,
                         sinatra: sinatra(), registry: reg, request: .test(ownerId: owner), logger: .test)
        let docs = resultDocs(r)
        XCTAssertTrue(docs.contains("d1"), "direct hit")
        XCTAssertTrue(docs.contains("d2"), "graph-expanded neighbor")
        XCTAssertEqual(r.trace?.expandedDocumentCount, 1)
        // d2 arrives via the expansion array, appended after direct results.
        XCTAssertEqual(docs.firstIndex(of: "d1")! < docs.lastIndex(of: "d2")!, true)
    }

    func test_expansion_respectsAccessFilter() {
        // d2 is neither owned nor available → expansion must not surface it.
        let (t, g, reg, aId) = makeExpansionFixture(ownedDocs: ["d1"])
        let r = t.search(embedding: a, matchedEntityIds: [aId], graph: g, expand: true,
                         sinatra: sinatra(), registry: reg, request: .test(ownerId: owner), logger: .test)
        XCTAssertFalse(resultDocs(r).contains("d2"))
        XCTAssertEqual(r.trace?.expandedDocumentCount ?? 0, 0)
    }

    func test_expansion_disabledByFlag() {
        let (t, g, reg, aId) = makeExpansionFixture(ownedDocs: ["d1", "d2"])
        let r = t.search(embedding: a, matchedEntityIds: [aId], graph: g, expand: false,
                         sinatra: sinatra(), registry: reg, request: .test(ownerId: owner), logger: .test)
        XCTAssertFalse(resultDocs(r).contains("d2"), "expansion off → only gated direct hits")
    }

    // MARK: - Persistence

    func test_table_codableRoundTrip_yieldsIdenticalSearch() throws {
        var t = PartitionTable()
        t.put(id: "d1", partitions: makePartitions(center: a, doc: "d1", owner: owner),
              request: .test(ownerId: owner), logger: .test)
        t.put(id: "d2", partitions: makePartitions(center: b, doc: "d2", owner: owner),
              request: .test(ownerId: owner), logger: .test)

        let data = try PropertyListEncoder().encode(t)
        let decoded = try PropertyListDecoder().decode(PartitionTable.self, from: data)
        XCTAssertEqual(decoded.keys, t.keys)

        let reg = makeRegistry(owner: owner, ownedDocs: ["d1", "d2"])
        let r1 = t.search(embedding: a, sinatra: sinatra(), registry: reg,
                          request: .test(ownerId: owner), logger: .test)
        let r2 = decoded.search(embedding: a, sinatra: sinatra(), registry: reg,
                                request: .test(ownerId: owner), logger: .test)
        XCTAssertEqual(resultDocs(r1).sorted(), resultDocs(r2).sorted())
    }
}
