//
//  Flow4_SearchTests.swift
//  totem-tests
// Relationship-first retrieval, ADC scan correctness, graph expansion, and persistence.

import XCTest
@testable import totem

// MARK: - Helpers

private func ent(_ name: String, _ kind: String = "concept") -> Database.GraphPayload.EntityIn {
    .init(name: name, kind: kind)
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

    // MARK: - Relationship-first candidate selection

    func test_matchedRelationshipGatesToRelationshipEvidence() {
        var graph = GraphStore()
        let relationshipVector = VectorFixtures.unit(axis: 0)
        _ = graph.upsert(.init(
            entities: [ent("Cat"), ent("Mouse")],
            relationships: [.init(subject: "Cat", predicate: "chases", object: "Mouse", embedding: relationshipVector)]
        ), documentId: "d2")
        let relationshipId = graph.relationships.values.first!.id

        var t = PartitionTable()
        t.put(id: "d2", partitions: makePartitions(center: a, doc: "d2", owner: owner),
              entityIds: Array(graph.entities.keys),
              request: .test(ownerId: owner), logger: .test)
        t.put(id: "d1", partitions: makePartitions(center: a, doc: "d1", owner: owner),
              request: .test(ownerId: owner), logger: .test)
        let reg = makeRegistry(owner: owner, ownedDocs: ["d1", "d2"])

        let r = t.search(embedding: a, matchedRelationshipIds: [relationshipId], graph: graph,
                         sinatra: sinatra(), registry: reg,
                         request: .test(ownerId: owner), logger: .test)
        let docs = Set(resultDocs(r))
        XCTAssertEqual(docs, Set(["d2"]))
    }

    func test_matchedEntityGatesLinkedDocIn() {
        var t = PartitionTable()
        let catId = GraphStore.entityID(kind: "concept", name: "cat")
        t.put(id: "d2", partitions: makePartitions(center: a, doc: "d2", owner: owner),
              entityIds: [catId],
              request: .test(ownerId: owner), logger: .test)
        let reg = makeRegistry(owner: owner, ownedDocs: ["d2"])

        let r = t.search(embedding: a, matchedEntityIds: [catId], graph: nil,
                         sinatra: sinatra(), registry: reg, request: .test(ownerId: owner), logger: .test)
        XCTAssertTrue(Set(resultDocs(r)).contains("d2"))
    }

    func test_skipRelationshipFilter_whenNoGraphSignal() {
        var t = PartitionTable()
        let catId = GraphStore.entityID(kind: "concept", name: "cat")
        t.put(id: "d1", partitions: makePartitions(center: a, doc: "d1", owner: owner),
              entityIds: [catId],
              request: .test(ownerId: owner), logger: .test)
        t.put(id: "d2", partitions: makePartitions(center: a, doc: "d2", owner: owner),
              request: .test(ownerId: owner), logger: .test)
        let reg = makeRegistry(owner: owner, ownedDocs: ["d1", "d2"])

        let r = t.search(embedding: a, graph: nil, sinatra: sinatra(), registry: reg,
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

    /// A `groups` request is containment: d2 is owned and accessible, and sits exactly one
    /// hop from the matched entity, but it is outside the requested group — expansion must
    /// not re-admit it. The unscoped half of the same fixture proves the guard is the group
    /// filter and nothing else (d2 is reachable when no groups are named).
    func test_expansion_confinedToScopedGroups() {
        let (t, g, baseRegistry, aId) = makeExpansionFixture(ownedDocs: ["d1", "d2"])
        var reg = baseRegistry
        reg.groups["grp-in"] = ["d1"]
        reg.groups["grp-out"] = ["d2"]
        reg.documentGroups["d1"] = ["grp-in"]
        reg.documentGroups["d2"] = ["grp-out"]

        let scoped = DatabaseRequest(
            ownerId: owner,
            groups: [.test(id: "grp-in", ownerId: owner)],
            scope: .personal
        )
        let r = t.search(embedding: a, matchedEntityIds: [aId], graph: g, expand: true,
                         sinatra: sinatra(), registry: reg, request: scoped, logger: .test)
        let docs = Set(resultDocs(r))
        XCTAssertTrue(docs.contains("d1"), "in-group direct hit still returned")
        XCTAssertFalse(docs.contains("d2"), "out-of-group neighbor must not leak through expansion")
        XCTAssertEqual(r.trace?.expandedDocumentCount ?? 0, 0)

        // No-regression half: same table, graph and registry, no groups named.
        let unscoped = t.search(embedding: a, matchedEntityIds: [aId], graph: g, expand: true,
                                sinatra: sinatra(), registry: reg,
                                request: .test(ownerId: owner), logger: .test)
        XCTAssertTrue(resultDocs(unscoped).contains("d2"),
                      "unscoped search still reaches the neighbor via the graph")
        XCTAssertEqual(unscoped.trace?.expandedDocumentCount, 1)
    }

    /// `aggregate: true` outranks `groups` for the direct scan, so it must outrank it for the
    /// expansion too — the aggregate path is unscoped and expands over all owner documents.
    func test_expansion_ignoresGroups_whenAggregating() {
        let (t, g, baseRegistry, aId) = makeExpansionFixture(ownedDocs: ["d1", "d2"])
        var reg = baseRegistry
        reg.groups["grp-in"] = ["d1"]

        let aggregated = DatabaseRequest(
            ownerId: owner,
            groups: [.test(id: "grp-in", ownerId: owner)],
            aggregate: true,
            scope: .personal
        )
        let r = t.search(embedding: a, matchedEntityIds: [aId], graph: g, expand: true,
                         sinatra: sinatra(), registry: reg, request: aggregated, logger: .test)
        XCTAssertTrue(resultDocs(r).contains("d2"), "aggregate ignores groups on both paths")
        XCTAssertEqual(r.trace?.expandedDocumentCount, 1)
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
