//
//  Flow11_GroupMetadataTests.swift
//  database-serverTests
//
//  Tests for Phase 1: Database.Group.Metadata codability, RegistryMutator.updateGroupMetadata
//  ownership enforcement, and metadata persistence through register/rename flows.
//

import XCTest
@testable import thread

final class Flow11_GroupMetadataTests: XCTestCase {

    // MARK: - Database.Group.Metadata Codable

    func testMetadataEncodesAndDecodes() throws {
        let meta = Database.Group.Metadata(description: "My public feed", tags: ["ai", "swift", "research"])
        let encoded = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(Database.Group.Metadata.self, from: encoded)

        XCTAssertEqual(decoded.description, "My public feed")
        XCTAssertEqual(decoded.tags, ["ai", "swift", "research"])
    }

    func testMetadataWithNilDescriptionRoundtrips() throws {
        let meta = Database.Group.Metadata(description: nil, tags: ["tag1"])
        let encoded = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(Database.Group.Metadata.self, from: encoded)

        XCTAssertNil(decoded.description)
        XCTAssertEqual(decoded.tags, ["tag1"])
    }

    func testMetadataWithEmptyTagsRoundtrips() throws {
        let meta = Database.Group.Metadata(description: "desc", tags: [])
        let encoded = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(Database.Group.Metadata.self, from: encoded)

        XCTAssertEqual(decoded.description, "desc")
        XCTAssertTrue(decoded.tags.isEmpty)
    }

    func testMetadataDecodesFromMissingTagsKey() throws {
        // Existing serialised metadata may not have a "tags" key.
        let json = #"{"description":"legacy"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Database.Group.Metadata.self, from: json)
        XCTAssertEqual(decoded.description, "legacy")
        XCTAssertTrue(decoded.tags.isEmpty, "missing tags key must decode to empty array")
    }

    // MARK: - Database.Group backward compatibility

    func testGroupWithoutMetadataDecodesCleanly() throws {
        // Simulate a registry entry persisted before the metadata field was introduced.
        let json = """
        {
            "id": "grp-old",
            "label": "Old Group",
            "owner_id": "owner-1",
            "documents": []
        }
        """.data(using: .utf8)!
        let group = try JSONDecoder().decode(Database.Group.self, from: json)
        XCTAssertNil(group.metadata, "groups without metadata key must decode with metadata == nil")
        XCTAssertEqual(group.label, "Old Group")
    }

    func testGroupWithMetadataDecodesCorrectly() throws {
        let json = """
        {
            "id": "grp-new",
            "label": "New Group",
            "owner_id": "owner-2",
            "documents": [],
            "metadata": {
                "description": "Curated AI notes",
                "tags": ["ai", "notes"]
            }
        }
        """.data(using: .utf8)!
        let group = try JSONDecoder().decode(Database.Group.self, from: json)
        XCTAssertNotNil(group.metadata)
        XCTAssertEqual(group.metadata?.description, "Curated AI notes")
        XCTAssertEqual(group.metadata?.tags, ["ai", "notes"])
    }

    func testGroupRoundtripsWithMetadata() throws {
        let original = Database.Group(
            id: "grp-rt",
            label: "Roundtrip",
            ownerId: "owner-rt",
            documents: [],
            metadata: .init(description: "some desc", tags: ["x", "y"])
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Database.Group.self, from: encoded)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.metadata?.description, "some desc")
        XCTAssertEqual(decoded.metadata?.tags, ["x", "y"])
    }

    // MARK: - RegistryMutator.updateGroupMetadata ownership

    func testUpdateGroupMetadataSucceedsForOwner() async {
        let mutator = RegistryMutator.test()
        let doc = Database.Document.test(id: "doc-meta-ok", ownerId: "owner-meta")
        await mutator.register(doc, group: .test(id: "grp-meta-ok", ownerId: "owner-meta"), ownerId: "owner-meta")

        let meta = Database.Group.Metadata(description: "Updated desc", tags: ["a", "b"])
        let updated = await mutator.updateGroupMetadata(id: "grp-meta-ok", ownerId: "owner-meta", metadata: meta)

        XCTAssertTrue(updated, "updateGroupMetadata must succeed when called by the group owner")

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: "owner-meta")
        let stored = snapshot.ownersGroups[owner]?.first { $0.id == "grp-meta-ok" }
        XCTAssertEqual(stored?.metadata?.description, "Updated desc")
        XCTAssertEqual(stored?.metadata?.tags, ["a", "b"])
    }

    func testUpdateGroupMetadataRejectsNonOwner() async {
        let mutator = RegistryMutator.test()
        let doc = Database.Document.test(id: "doc-meta-rej", ownerId: "real-owner")
        await mutator.register(doc, group: .test(id: "grp-meta-rej", ownerId: "real-owner"), ownerId: "real-owner")

        let updated = await mutator.updateGroupMetadata(
            id: "grp-meta-rej",
            ownerId: "impostor",
            metadata: .init(description: "Hacked", tags: [])
        )

        XCTAssertFalse(updated, "updateGroupMetadata must reject a caller who does not own the group")

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: "real-owner")
        let stored = snapshot.ownersGroups[owner]?.first { $0.id == "grp-meta-rej" }
        XCTAssertNil(stored?.metadata, "metadata must remain nil after rejected update")
    }

    func testUpdateGroupMetadataPreservesLabel() async {
        let mutator = RegistryMutator.test()
        let doc = Database.Document.test(id: "doc-meta-lbl", ownerId: "owner-lbl")
        await mutator.register(doc, group: .test(id: "grp-meta-lbl", label: "My Label", ownerId: "owner-lbl"), ownerId: "owner-lbl")

        await mutator.updateGroupMetadata(id: "grp-meta-lbl", ownerId: "owner-lbl", metadata: .init(description: "desc"))

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: "owner-lbl")
        let stored = snapshot.ownersGroups[owner]?.first { $0.id == "grp-meta-lbl" }
        XCTAssertEqual(stored?.label, "My Label", "updateGroupMetadata must not clobber the group label")
    }

    func testUpdateGroupMetadataCanBeOverwritten() async {
        let mutator = RegistryMutator.test()
        let doc = Database.Document.test(id: "doc-meta-ovr", ownerId: "owner-ovr")
        await mutator.register(doc, group: .test(id: "grp-meta-ovr", ownerId: "owner-ovr"), ownerId: "owner-ovr")

        await mutator.updateGroupMetadata(id: "grp-meta-ovr", ownerId: "owner-ovr",
                                          metadata: .init(description: "v1", tags: ["a"]))
        await mutator.updateGroupMetadata(id: "grp-meta-ovr", ownerId: "owner-ovr",
                                          metadata: .init(description: "v2", tags: ["b", "c"]))

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: "owner-ovr")
        let stored = snapshot.ownersGroups[owner]?.first { $0.id == "grp-meta-ovr" }
        XCTAssertEqual(stored?.metadata?.description, "v2")
        XCTAssertEqual(stored?.metadata?.tags, ["b", "c"])
    }

    func testMetadataPreservedThroughGroupRegister() async {
        // When a new document is registered into an existing group, the group's
        // metadata (previously set) must not be clobbered in ownersGroups.
        let mutator = RegistryMutator.test()
        let ownerId = "owner-persist"

        // Register first doc and set metadata.
        let doc1 = Database.Document.test(id: "doc-persist-1", ownerId: ownerId)
        await mutator.register(doc1, group: .test(id: "grp-persist", ownerId: ownerId), ownerId: ownerId)
        await mutator.updateGroupMetadata(id: "grp-persist", ownerId: ownerId,
                                          metadata: .init(description: "keep me", tags: ["tag"]))

        // Register a second doc into the same group — the group already exists.
        let doc2 = Database.Document.test(id: "doc-persist-2", ownerId: ownerId)
        await mutator.register(doc2, group: .test(id: "grp-persist", ownerId: ownerId), ownerId: ownerId)

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: ownerId)
        let stored = snapshot.ownersGroups[owner]?.first { $0.id == "grp-persist" }
        // The second register call hits the `!groupOwnersHashes.contains(where:)` guard —
        // it must not overwrite the existing entry.
        XCTAssertEqual(stored?.metadata?.description, "keep me",
            "metadata must not be clobbered when a second document is added to an existing group")
    }
}
