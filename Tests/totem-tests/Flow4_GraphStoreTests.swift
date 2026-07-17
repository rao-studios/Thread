//
//  Flow4_GraphStoreTests.swift
//  totem-tests
//
//  Entity/relationship merge, traversal, detach GC, and Codable round-trip.
//

import XCTest
@testable import totem

final class Flow4_GraphStoreTests: XCTestCase {

    private func entity(_ name: String, _ kind: String = "concept", _ emb: [Float]? = nil) -> Database.GraphPayload.EntityIn {
        .init(name: name, kind: kind, embedding: emb)
    }

    // MARK: - Identity

    func test_entityID_isCaseAndWhitespaceInsensitive_kindScoped() {
        let a = GraphStore.entityID(kind: "Person", name: "Marie Curie")
        let b = GraphStore.entityID(kind: "person", name: "  marie   curie ")
        XCTAssertEqual(a, b, "id normalizes kind + name")

        let c = GraphStore.entityID(kind: "concept", name: "Marie Curie")
        XCTAssertNotEqual(a, c, "different kind → different entity")
    }

    // MARK: - Upsert / merge

    func test_upsert_mergesSameEntityAcrossDocuments() {
        var g = GraphStore()
        _ = g.upsert(.init(entities: [entity("Radium")]), documentId: "d1")
        let ids = g.upsert(.init(entities: [entity("radium")]), documentId: "d2")

        XCTAssertEqual(g.entities.count, 1)
        let e = g.entities[ids[0]]!
        XCTAssertEqual(e.documentIds, ["d1", "d2"])
        XCTAssertEqual(e.mentionCount, 2)
    }

    func test_upsert_sameName_differentKind_staysDistinct() {
        var g = GraphStore()
        _ = g.upsert(.init(entities: [entity("Mercury", "planet"), entity("Mercury", "element")]), documentId: "d1")
        XCTAssertEqual(g.entities.count, 2)
    }

    func test_upsert_relationshipWeightIncrementsOnRepeat() {
        var g = GraphStore()
        let payload = Database.GraphPayload(
            entities: [entity("Curie", "person"), entity("Radium")],
            relationships: [.init(subject: "Curie", predicate: "discovered", object: "Radium")]
        )
        _ = g.upsert(payload, documentId: "d1")
        _ = g.upsert(payload, documentId: "d2")

        XCTAssertEqual(g.relationships.count, 1)
        XCTAssertEqual(g.relationships.values.first?.weight, 2)
        XCTAssertEqual(g.relationships.values.first?.documentIds, ["d1", "d2"])
    }

    // MARK: - Traversal

    func test_neighborhood_oneAndTwoHops() {
        var g = GraphStore()
        _ = g.upsert(.init(
            entities: [entity("A"), entity("B"), entity("C")],
            relationships: [
                .init(subject: "A", predicate: "to", object: "B"),
                .init(subject: "B", predicate: "to", object: "C"),
            ]
        ), documentId: "d1")

        let aid = GraphStore.entityID(kind: "concept", name: "A")
        let bid = GraphStore.entityID(kind: "concept", name: "B")
        let cid = GraphStore.entityID(kind: "concept", name: "C")

        let oneHop = g.neighborhood(of: [aid], hops: 1)
        XCTAssertTrue(oneHop.entities.contains(bid))
        XCTAssertFalse(oneHop.entities.contains(cid), "C is two hops away")

        let twoHop = g.neighborhood(of: [aid], hops: 2)
        XCTAssertTrue(twoHop.entities.contains(cid))
    }

    // MARK: - Detach GC

    func test_detach_gcsOrphanEntitiesAndEdges_keepsSharedEntities() {
        var g = GraphStore()
        let d1Ids = g.upsert(.init(
            entities: [entity("A"), entity("B")],
            relationships: [.init(subject: "A", predicate: "rel", object: "B")]
        ), documentId: "d1")
        _ = g.upsert(.init(entities: [entity("A")]), documentId: "d2")   // A shared with d2

        g.detach(documentId: "d1", entityIds: d1Ids)

        let aid = GraphStore.entityID(kind: "concept", name: "A")
        let bid = GraphStore.entityID(kind: "concept", name: "B")
        XCTAssertNotNil(g.entities[aid], "A still present (owned by d2)")
        XCTAssertNil(g.entities[bid], "B garbage-collected (only d1)")
        XCTAssertTrue(g.relationships.isEmpty, "A→B edge GC'd with B")
        XCTAssertNil(g.adjacency[bid])
    }

    // MARK: - Codable

    func test_codableRoundTrip_rebuildsAdjacency() throws {
        var g = GraphStore()
        _ = g.upsert(.init(
            entities: [entity("A"), entity("B")],
            relationships: [.init(subject: "A", predicate: "to", object: "B")]
        ), documentId: "d1")

        let data = try PropertyListEncoder().encode(g)
        let decoded = try PropertyListDecoder().decode(GraphStore.self, from: data)

        XCTAssertEqual(decoded.entities.count, 2)
        XCTAssertEqual(decoded.relationships.count, 1)
        XCTAssertFalse(decoded.adjacency.isEmpty, "adjacency rebuilt on decode")

        let aid = GraphStore.entityID(kind: "concept", name: "A")
        XCTAssertEqual(decoded.neighborhood(of: [aid], hops: 1).entities.count, 2)
    }

    // MARK: - Match

    func test_matchEntities_byName() {
        var g = GraphStore()
        _ = g.upsert(.init(entities: [entity("Marie Curie", "person")]), documentId: "d1")
        let hits = g.matchEntities(nameQuery: "curie", embedding: nil)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.score, 1.0)
    }

    func test_matchEntities_byEmbeddingThreshold() {
        var g = GraphStore()
        let emb = VectorFixtures.unit(axis: 3)
        _ = g.upsert(.init(entities: [entity("Radium", "concept", emb)]), documentId: "d1")

        let close = g.matchEntities(nameQuery: nil, embedding: emb)
        XCTAssertEqual(close.count, 1, "self dot = 1.0 ≥ threshold")

        let far = g.matchEntities(nameQuery: nil, embedding: VectorFixtures.unit(axis: 10))
        XCTAssertTrue(far.isEmpty, "orthogonal dot = 0 < 0.15 threshold")
    }

    func test_matchEntities_kindFilter() {
        var g = GraphStore()
        _ = g.upsert(.init(entities: [entity("Curie", "person"), entity("Curie", "place")]), documentId: "d1")
        let hits = g.matchEntities(nameQuery: "curie", embedding: nil, kinds: ["person"])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.entity.kind, "person")
    }
}
