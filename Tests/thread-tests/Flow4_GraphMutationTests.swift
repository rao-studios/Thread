//
//  Flow4_GraphMutationTests.swift
//  thread-tests
//
//  Invariants for granular graph editing: delete, rename/merge/set-kind re-keying
//  (no dangling relationship endpoints, weight merging on collision), and the
//  extraction-policy passes.
//

import XCTest
@testable import thread

final class Flow4_GraphMutationTests: XCTestCase {

    private func ent(_ name: String, _ kind: String = "concept") -> Database.GraphPayload.EntityIn {
        .init(name: name, kind: kind)
    }

    private func seeded() -> GraphStore {
        var g = GraphStore()
        _ = g.upsert(.init(
            entities: [ent("Ada", "person"), ent("Babbage", "person"), ent("Engine", "work")],
            relationships: [
                .init(subject: "Ada", predicate: "worked with", object: "Babbage"),
                .init(subject: "Ada", predicate: "programmed", object: "Engine"),
            ]
        ), documentId: "d1")
        return g
    }

    // MARK: - Delete

    func test_deleteEntity_removesIncidentEdges_andReportsDocs() {
        var g = seeded()
        let adaId = GraphStore.entityID(kind: "person", name: "Ada")

        let result = g.deleteEntity(id: adaId)

        XCTAssertNil(g.entities[adaId])
        XCTAssertTrue(g.relationships.isEmpty, "both edges touched Ada — all must be removed")
        XCTAssertEqual(result.affectedDocumentIds, ["d1"])
        // No dangling adjacency references either.
        for (_, rids) in g.adjacency {
            XCTAssertTrue(rids.isEmpty)
        }
    }

    func test_deleteRelationship_keepsEntities() {
        var g = seeded()
        let rid = g.relationships.values.first { $0.predicate == "worked with" }!.id

        g.deleteRelationship(id: rid)

        XCTAssertEqual(g.relationships.count, 1)
        XCTAssertEqual(g.entities.count, 3, "entities keep their provenance")
        XCTAssertFalse(g.adjacency.values.contains { $0.contains(rid) })
    }

    // MARK: - Rename (re-key)

    func test_renameEntity_rekeysEntityAndIncidentRelationships() {
        var g = seeded()
        let adaId = GraphStore.entityID(kind: "person", name: "Ada")

        let result = g.renameEntity(id: adaId, newName: "Ada Lovelace")
        let newId = GraphStore.entityID(kind: "person", name: "Ada Lovelace")

        XCTAssertEqual(result.survivingId, newId)
        XCTAssertNil(g.entities[adaId])
        XCTAssertEqual(g.entities[newId]?.name, "Ada Lovelace")
        XCTAssertEqual(g.relationships.count, 2)
        // Every relationship endpoint must reference a live entity.
        for rel in g.relationships.values {
            XCTAssertNotNil(g.entities[rel.subjectId], "dangling subject after rename")
            XCTAssertNotNil(g.entities[rel.objectId], "dangling object after rename")
        }
        // Relationship ids re-keyed consistently with adjacency.
        for (eid, rids) in g.adjacency {
            for rid in rids {
                XCTAssertNotNil(g.relationships[rid])
                let rel = g.relationships[rid]!
                XCTAssertTrue(rel.subjectId == eid || rel.objectId == eid)
            }
        }
        XCTAssertEqual(result.affectedDocumentIds, ["d1"])
    }

    func test_renameEntity_caseOnlyChange_keepsIdentity() {
        var g = seeded()
        let adaId = GraphStore.entityID(kind: "person", name: "Ada")

        let result = g.renameEntity(id: adaId, newName: "ADA")

        XCTAssertEqual(result.survivingId, adaId, "normalized identity unchanged")
        XCTAssertEqual(g.entities[adaId]?.name, "ADA", "display casing updated")
        XCTAssertTrue(result.affectedDocumentIds.isEmpty, "no index rewrite needed")
    }

    // MARK: - Merge

    func test_mergeEntities_unionsProvenance_andMergesCollidingEdgeWeights() {
        var g = GraphStore()
        _ = g.upsert(.init(
            entities: [ent("AI"), ent("ML"), ent("Data")],
            relationships: [
                .init(subject: "AI", predicate: "uses", object: "Data"),
                .init(subject: "ML", predicate: "uses", object: "Data"),
            ]
        ), documentId: "d1")
        _ = g.upsert(.init(entities: [ent("ML")]), documentId: "d2")

        let aiId = GraphStore.entityID(kind: "concept", name: "AI")
        let mlId = GraphStore.entityID(kind: "concept", name: "ML")

        let result = g.mergeEntities(from: aiId, into: mlId)

        XCTAssertEqual(result.survivingId, mlId)
        XCTAssertNil(g.entities[aiId])
        XCTAssertEqual(g.entities[mlId]?.documentIds, ["d1", "d2"], "provenance unioned")
        // "AI uses Data" re-keys onto "ML uses Data" → weights merge.
        XCTAssertEqual(g.relationships.count, 1)
        XCTAssertEqual(g.relationships.values.first?.weight, 2, "colliding edge weights must sum")
        XCTAssertEqual(result.affectedDocumentIds, ["d1", "d2"])
    }

    func test_merge_selfLoopCollapses() {
        var g = GraphStore()
        _ = g.upsert(.init(
            entities: [ent("A"), ent("B")],
            relationships: [.init(subject: "A", predicate: "near", object: "B")]
        ), documentId: "d1")
        let aId = GraphStore.entityID(kind: "concept", name: "A")
        let bId = GraphStore.entityID(kind: "concept", name: "B")

        _ = g.mergeEntities(from: aId, into: bId)

        XCTAssertTrue(g.relationships.isEmpty, "A→B collapses into a self-loop and is dropped")
        XCTAssertTrue(g.adjacency[bId]?.isEmpty ?? true)
    }

    // MARK: - Set kind

    func test_setEntityKind_rekeys() {
        var g = seeded()
        let engineId = GraphStore.entityID(kind: "work", name: "Engine")

        let result = g.setEntityKind(id: engineId, kind: "concept")
        let newId = GraphStore.entityID(kind: "concept", name: "Engine")

        XCTAssertEqual(result.survivingId, newId)
        XCTAssertNil(g.entities[engineId])
        XCTAssertEqual(g.entities[newId]?.kind, "concept")
        for rel in g.relationships.values {
            XCTAssertNotNil(g.entities[rel.subjectId])
            XCTAssertNotNil(g.entities[rel.objectId])
        }
    }

    // MARK: - TableMutator integration (entityIds rewrite)

    func test_mutateGraph_rewritesPartitionIndexEntityIds() async {
        let mutator = TableMutator.test()
        mutator.seed(PartitionTable())
        mutator.seedGraph(GraphStore())

        let p = Database.Partition.test(id: "p0", documentId: "doc0",
                                    embedding: VectorFixtures.random(seed: 9100))
        await mutator.put(id: "doc0", partitions: [p],
                          graph: .init(entities: [.init(name: "Ada", kind: "person")]),
                          request: .test())

        let oldId = GraphStore.entityID(kind: "person", name: "Ada")
        XCTAssertEqual(mutator.snapshot?.indices["doc0"]?.entityIds, [oldId])

        let survivingId = await mutator.mutateGraph(.renameEntity(oldId, newName: "Ada Lovelace"))

        let newId = GraphStore.entityID(kind: "person", name: "Ada Lovelace")
        XCTAssertEqual(survivingId, newId)
        XCTAssertEqual(mutator.snapshot?.indices["doc0"]?.entityIds, [newId],
            "PartitionIndex.entityIds must be rewritten in the same mutation")
        XCTAssertNil(mutator.graphSnapshot?.entities[oldId])
        XCTAssertNotNil(mutator.graphSnapshot?.entities[newId])
    }

    // MARK: - Extraction policy passes

    func test_policy_predicateAliases_normalize() {
        var policy = ExtractionPolicy()
        policy.predicateAliases = ["works for": "employed by"]

        let payload = GraphEnrichment.applyPolicyEdges(
            to: .init(entities: [ent("A"), ent("B")],
                      relationships: [.init(subject: "A", predicate: "Works For", object: "B")]),
            policy: policy,
            existingGraph: nil
        )
        XCTAssertEqual(payload.relationships.first?.predicate, "employed by")
    }

    func test_policy_coMention_addsAutoEdges_skippingExplicitPairs() {
        var policy = ExtractionPolicy()
        policy.coMention = .init(enabled: true, predicate: "appears with", skipExplicitlyLinked: true)

        let payload = GraphEnrichment.applyPolicyEdges(
            to: .init(entities: [ent("A"), ent("B"), ent("C")],
                      relationships: [.init(subject: "A", predicate: "knows", object: "B")]),
            policy: policy,
            existingGraph: nil
        )
        let auto = payload.relationships.filter { $0.predicate.hasPrefix("auto:") }
        // Pairs: AB (explicit — skipped), AC, BC.
        XCTAssertEqual(auto.count, 2)
        XCTAssertTrue(auto.allSatisfy { $0.predicate == "auto:appears with" })
    }

    func test_policy_effectivePrompt_expandsPlaceholders() {
        var policy = ExtractionPolicy()
        policy.kinds = [.init(name: "spell", description: "A magical incantation.")]
        policy.maxEntities = 5

        let prompt = policy.effectiveSystemPrompt
        XCTAssertTrue(prompt.contains("spell (A magical incantation.)"))
        XCTAssertTrue(prompt.contains("at most 5 entities"))
        XCTAssertFalse(prompt.contains("{{"))
    }
}
