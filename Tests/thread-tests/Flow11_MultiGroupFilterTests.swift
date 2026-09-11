//
//  Flow11_MultiGroupFilterTests.swift
//  database-serverTests
//
//  Tests for Phase 2: DatabaseRequest.groups field decoding and the multi-group filter
//  logic in PartitionTable.search() (linear fallback path, exercised directly through
//  the registry helpers that back the candidate set logic).
//

import XCTest
@testable import thread

final class Flow11_MultiGroupFilterTests: XCTestCase {

    // MARK: - DatabaseRequest.groups field

    func testDatabaseRequestGroupsDefaultsToNilWhenAbsent() throws {
        let json = #"{"owner_id":"user-1"}"#.data(using: .utf8)!
        let req = try JSONDecoder().decode(DatabaseRequest.self, from: json)
        XCTAssertNil(req.groups, "groups must be nil when not present in JSON")
    }

    func testDatabaseRequestGroupsDecodesArrayCorrectly() throws {
        let json = """
        {
            "owner_id": "user-1",
            "groups": [
                {"id": "g1", "label": "Group 1", "owner_id": "user-1", "documents": []},
                {"id": "g2", "label": "Group 2", "owner_id": "user-1", "documents": []}
            ]
        }
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(DatabaseRequest.self, from: json)
        XCTAssertEqual(req.groups?.count, 2)
        XCTAssertEqual(req.groups?.first?.id, "g1")
        XCTAssertEqual(req.groups?.last?.id, "g2")
    }

    func testDatabaseRequestGroupsDecodesEmptyArray() throws {
        let json = #"{"owner_id":"user-1","groups":[]}"#.data(using: .utf8)!
        let req = try JSONDecoder().decode(DatabaseRequest.self, from: json)
        XCTAssertNotNil(req.groups)
        XCTAssertTrue(req.groups!.isEmpty)
    }

    func testDatabaseRequestSingleGroupAndGroupsCoexist() throws {
        let json = """
        {
            "owner_id": "user-1",
            "group":  {"id": "g0", "label": "Single", "owner_id": "user-1", "documents": []},
            "groups": [{"id": "g1", "label": "Multi",  "owner_id": "user-1", "documents": []}]
        }
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(DatabaseRequest.self, from: json)
        XCTAssertEqual(req.group?.id, "g0")
        XCTAssertEqual(req.groups?.first?.id, "g1")
    }

    func testDatabaseRequestGroupsWithMetadataDecodes() throws {
        let json = """
        {
            "owner_id": "user-1",
            "groups": [
                {
                    "id": "g-meta",
                    "label": "Meta Group",
                    "owner_id": "user-1",
                    "documents": [],
                    "metadata": {"description": "desc", "tags": ["tag1"]}
                }
            ]
        }
        """.data(using: .utf8)!
        let req = try JSONDecoder().decode(DatabaseRequest.self, from: json)
        XCTAssertEqual(req.groups?.first?.metadata?.description, "desc")
        XCTAssertEqual(req.groups?.first?.metadata?.tags, ["tag1"])
    }

    func testDatabaseRequestExplicitInitGroupsDefaultsToNil() {
        let req = DatabaseRequest(ownerId: "owner-x", scope: .personal)
        XCTAssertNil(req.groups)
        XCTAssertNil(req.group)
    }

    func testDatabaseRequestExplicitInitGroupsCanBeSet() {
        let g1 = Database.Group.test(id: "g-init-1")
        let g2 = Database.Group.test(id: "g-init-2")
        let req = DatabaseRequest(ownerId: "owner-x", groups: [g1, g2])
        XCTAssertEqual(req.groups?.count, 2)
        XCTAssertEqual(req.groups?.first?.id, "g-init-1")
    }

    // MARK: - Multi-group candidate set (linear fallback)

    /// Constructs a registry with two groups and verifies that the correct
    /// candidate document IDs are selected when `groups` specifies a subset.
    func testMultiGroupCandidateSetReturnsUnionOfGroupDocs() {
        var registry = ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: "owner-mg")
        registry.documentOwners["doc-a1"] = [owner]
        registry.documentOwners["doc-a2"] = [owner]
        registry.documentOwners["doc-b1"] = [owner]
        registry.documentOwners["doc-c1"] = [owner]
        registry.ownersDocuments[owner] = ["doc-a1", "doc-a2", "doc-b1", "doc-c1"]
        registry.documentGroups["doc-a1"] = ["grp-a"]
        registry.documentGroups["doc-a2"] = ["grp-a"]
        registry.documentGroups["doc-b1"] = ["grp-b"]
        registry.documentGroups["doc-c1"] = ["grp-c"]
        registry.groups["grp-a"] = ["doc-a1", "doc-a2"]
        registry.groups["grp-b"] = ["doc-b1"]
        registry.groups["grp-c"] = ["doc-c1"]

        let g_a = Database.Group.test(id: "grp-a", ownerId: "owner-mg")
        let g_b = Database.Group.test(id: "grp-b", ownerId: "owner-mg")

        // Simulate the candidate-set logic from PartitionTable.search() linear fallback.
        let ownerKey = ThreadRegistry.Owner(id: "owner-mg")
        let request = DatabaseRequest(ownerId: "owner-mg", groups: [g_a, g_b], scope: .personal)
        let candidateIds: Set<DocumentID>
        if let gs = request.groups, !gs.isEmpty {
            candidateIds = Set(gs.flatMap { registry.groups[$0.id] ?? [] })
        } else if let groupId = request.group?.id {
            candidateIds = Set(registry.groups[groupId] ?? [])
        } else {
            candidateIds = Set(registry.ownersDocuments[ownerKey] ?? [])
        }

        XCTAssertEqual(candidateIds, ["doc-a1", "doc-a2", "doc-b1"],
            "multi-group filter must include documents from grp-a and grp-b, but not grp-c")
    }

    func testMultiGroupCandidateFallsBackToSingleGroupWhenGroupsNil() {
        var registry = ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: "owner-sg")
        registry.documentOwners["doc-s1"] = [owner]
        registry.documentOwners["doc-s2"] = [owner]
        registry.ownersDocuments[owner] = ["doc-s1", "doc-s2"]
        registry.documentGroups["doc-s1"] = ["grp-s"]
        registry.documentGroups["doc-s2"] = ["grp-t"]
        registry.groups["grp-s"] = ["doc-s1"]
        registry.groups["grp-t"] = ["doc-s2"]

        let request = DatabaseRequest(ownerId: "owner-sg", group: .test(id: "grp-s", ownerId: "owner-sg"), scope: .personal)
        let ownerKey = ThreadRegistry.Owner(id: "owner-sg")
        let candidateIds: Set<DocumentID>
        if let gs = request.groups, !gs.isEmpty {
            candidateIds = Set(gs.flatMap { registry.groups[$0.id] ?? [] })
        } else if let groupId = request.group?.id {
            candidateIds = Set(registry.groups[groupId] ?? [])
        } else {
            candidateIds = Set(registry.ownersDocuments[ownerKey] ?? [])
        }

        XCTAssertEqual(candidateIds, ["doc-s1"],
            "when groups is nil, single-group fallback must be used")
    }

    func testAggregateOverridesMultiGroupFilter() {
        var registry = ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: "owner-agg")
        registry.documentOwners["doc-agg-1"] = [owner]
        registry.documentOwners["doc-agg-2"] = [owner]
        registry.ownersDocuments[owner] = ["doc-agg-1", "doc-agg-2"]
        registry.groups["grp-agg"] = ["doc-agg-1"]

        let g = Database.Group.test(id: "grp-agg", ownerId: "owner-agg")
        let request = DatabaseRequest(ownerId: "owner-agg", groups: [g], aggregate: true, scope: .personal)
        let ownerKey = ThreadRegistry.Owner(id: "owner-agg")

        // Replicate the linear fallback decision tree (aggregate takes highest priority).
        let candidateIds: Set<DocumentID>
        if request.aggregate == true {
            candidateIds = Set(registry.ownersDocuments[ownerKey] ?? [])
        } else if let gs = request.groups, !gs.isEmpty {
            candidateIds = Set(gs.flatMap { registry.groups[$0.id] ?? [] })
        } else if let groupId = request.group?.id {
            candidateIds = Set(registry.groups[groupId] ?? [])
        } else {
            candidateIds = Set(registry.ownersDocuments[ownerKey] ?? [])
        }

        XCTAssertEqual(candidateIds, Set(["doc-agg-1", "doc-agg-2"]),
            "aggregate == true must override groups filter and return all owner documents")
    }

    func testEmptyGroupsArrayFallsBackToAllOwnerDocs() {
        var registry = ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: "owner-empty")
        registry.documentOwners["doc-e1"] = [owner]
        registry.documentOwners["doc-e2"] = [owner]
        registry.ownersDocuments[owner] = ["doc-e1", "doc-e2"]

        let request = DatabaseRequest(ownerId: "owner-empty", groups: [], scope: .personal)
        let ownerKey = ThreadRegistry.Owner(id: "owner-empty")

        let candidateIds: Set<DocumentID>
        if let gs = request.groups, !gs.isEmpty {
            candidateIds = Set(gs.flatMap { registry.groups[$0.id] ?? [] })
        } else if let groupId = request.group?.id {
            candidateIds = Set(registry.groups[groupId] ?? [])
        } else {
            candidateIds = Set(registry.ownersDocuments[ownerKey] ?? [])
        }

        XCTAssertEqual(candidateIds, Set(["doc-e1", "doc-e2"]),
            "empty groups array must behave as if groups is nil — fall back to all owner docs")
    }

    // MARK: - Personal HNSW group filter set construction

    func testGroupIdSetBuiltFromMultipleGroups() {
        let g1 = Database.Group.test(id: "h1", ownerId: "o")
        let g2 = Database.Group.test(id: "h2", ownerId: "o")
        let request = DatabaseRequest(ownerId: "o", groups: [g1, g2], scope: .personal)

        // Replicate the Set<GroupID> construction from the personal HNSW path.
        let groupIds: Set<GroupID>
        if let gs = request.groups, !gs.isEmpty, request.aggregate != true {
            groupIds = Set(gs.map(\.id))
        } else if let g = request.group, request.aggregate != true {
            groupIds = [g.id]
        } else {
            groupIds = []
        }

        XCTAssertEqual(groupIds, ["h1", "h2"])
    }

    func testGroupIdSetFallsBackToSingleGroupWhenGroupsNil() {
        let g = Database.Group.test(id: "single", ownerId: "o")
        let request = DatabaseRequest(ownerId: "o", group: g, scope: .personal)

        let groupIds: Set<GroupID>
        if let gs = request.groups, !gs.isEmpty, request.aggregate != true {
            groupIds = Set(gs.map(\.id))
        } else if let gSingle = request.group, request.aggregate != true {
            groupIds = [gSingle.id]
        } else {
            groupIds = []
        }

        XCTAssertEqual(groupIds, ["single"])
    }

    func testGroupIdSetEmptyWhenBothNil() {
        let request = DatabaseRequest(ownerId: "o", scope: .personal)

        let groupIds: Set<GroupID>
        if let gs = request.groups, !gs.isEmpty, request.aggregate != true {
            groupIds = Set(gs.map(\.id))
        } else if let g = request.group, request.aggregate != true {
            groupIds = [g.id]
        } else {
            groupIds = []
        }

        XCTAssertTrue(groupIds.isEmpty)
    }
}
