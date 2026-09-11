//
//  Flow4_GraphStoreTests.swift
//  thread-tests
//
//  Entity/relationship merge, traversal, detach GC, and Codable round-trip.
//

import XCTest
@testable import thread

final class Flow4_GraphStoreTests: XCTestCase {

    private func entity(_ name: String, _ kind: String = "concept") -> Database.GraphPayload.EntityIn {
        .init(name: name, kind: kind)
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

    func test_legacyEntityVectorsDecodeAsPureEntityRecords() throws {
        struct LegacyEntity: Codable {
            let id: EntityID
            var name: String
            let kind: String
            var embedding: [Float]?
            var documentIds: Set<DocumentID>
            var mentionCount: Int
        }
        struct LegacyGraph: Codable {
            let entities: [EntityID: LegacyEntity]
            let relationships: [RelationshipID: Relationship]
        }

        let subjectId = GraphStore.entityID(kind: "person", name: "Ada")
        let objectId = GraphStore.entityID(kind: "work", name: "Analytical Engine")
        let relationshipId = GraphStore.relationshipID(
            subjectId: subjectId, predicate: "programmed", objectId: objectId
        )
        let legacy = LegacyGraph(
            entities: [
                subjectId: .init(id: subjectId, name: "Ada", kind: "person", embedding: VectorFixtures.unit(axis: 1), documentIds: ["d1"], mentionCount: 1),
                objectId: .init(id: objectId, name: "Analytical Engine", kind: "work", embedding: VectorFixtures.unit(axis: 2), documentIds: ["d1"], mentionCount: 1),
            ],
            relationships: [
                relationshipId: .init(id: relationshipId, subjectId: subjectId, predicate: "programmed", objectId: objectId, embedding: nil, documentIds: ["d1"], weight: 1)
            ]
        )

        let decoded = try PropertyListDecoder().decode(GraphStore.self, from: PropertyListEncoder().encode(legacy))
        XCTAssertEqual(decoded.entities[subjectId]?.name, "Ada")
        XCTAssertEqual(decoded.predicates[GraphStore.predicateID("programmed")]?.relationshipCount, 1)
        XCTAssertEqual(decoded.adjacency[subjectId], Set([relationshipId]))
    }

    // MARK: - Match

    func test_matchEntities_byName() {
        var g = GraphStore()
        _ = g.upsert(.init(entities: [entity("Marie Curie", "person")]), documentId: "d1")
        let hits = g.matchEntities(nameQuery: "curie")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.score, 1.0)
    }

    func test_matchRelationships_byRelationshipAndPredicateEmbedding() {
        var g = GraphStore()
        let relationshipEmbedding = VectorFixtures.unit(axis: 3)
        let predicateEmbedding = VectorFixtures.unit(axis: 8)
        _ = g.upsert(.init(
            entities: [entity("Marie Curie", "person"), entity("Radium")],
            relationships: [.init(
                subject: "Marie Curie", predicate: "discovered", object: "Radium",
                embedding: relationshipEmbedding, predicateEmbedding: predicateEmbedding
            )]
        ), documentId: "d1")

        let direct = g.matchRelationships(embedding: relationshipEmbedding)
        XCTAssertEqual(direct.count, 1)
        XCTAssertEqual(direct.first?.relationship.predicate, "discovered")

        let predicate = g.matchRelationships(embedding: predicateEmbedding)
        XCTAssertEqual(predicate.count, 1)
        XCTAssertEqual(predicate.first?.predicateId, GraphStore.predicateID("discovered"))
    }

    func test_enrichmentEmbedsRelationshipsAndPredicates() async {
        let item = Database.BatchPutItem(
            id: "d1",
            data: [],
            texts: ["Ada programmed the Analytical Engine."],
            graph: .init(
                entities: [entity("Ada", "person"), entity("Analytical Engine", "work")],
                relationships: [.init(subject: "Ada", predicate: "programmed", object: "Analytical Engine")]
            )
        )

        let enriched = await GraphEnrichment.run(
            items: [item], extractor: nil, embedder: MockEmbeddingProvider(), existingGraph: nil, logger: .test
        )
        let relation = enriched.first?.graph.relationships.first
        XCTAssertNotNil(relation?.embedding)
        XCTAssertNotNil(relation?.predicateEmbedding)

        var graph = GraphStore()
        _ = graph.upsert(enriched.first!.graph, documentId: "d1")
        XCTAssertNotNil(graph.relationships.values.first?.embedding)
        XCTAssertNotNil(graph.predicates[GraphStore.predicateID("programmed")]?.embedding)
    }

    func test_matchEntities_kindFilter() {
        var g = GraphStore()
        _ = g.upsert(.init(entities: [entity("Curie", "person"), entity("Curie", "place")]), documentId: "d1")
        let hits = g.matchEntities(nameQuery: "curie", kinds: ["person"])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.entity.kind, "person")
    }
}
