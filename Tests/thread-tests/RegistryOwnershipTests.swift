//
//  RegistryOwnershipTests.swift
//  database-serverTests
//
//  Tests covering ownership ID case normalization and registry integrity for
//  remove / modify operations.
//
//  Why these tests exist:
//    UUID.uuidString returns uppercase on all Swift platforms, but Supabase
//    auth.uid() is always lowercase. Without normalization at the request
//    boundary, registry ownership checks silently fail for any user whose ID
//    was stored in a different case.
//
//    DatabaseRequest.from(_:) lowercases the ownerId at the entry point so all
//    registry keys are consistently lowercase. These tests pin that behaviour
//    and the group-cleanup logic added to ThreadRegistry.remove and
//    RegistryMutator.updateGroup.
//

import XCTest
@testable import thread

final class RegistryOwnershipTests: XCTestCase {

    // MARK: - Helpers

    private func registryWithDocument(
        documentId: String,
        ownerId: String,
        groupId: String? = nil
    ) -> ThreadRegistry {
        var registry = ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: ownerId)

        registry.documentOwners[documentId] = [owner]
        var ownerDocs = registry.ownersDocuments[owner] ?? []
        ownerDocs.append(documentId)
        registry.ownersDocuments[owner] = ownerDocs
        registry.documentAccess[documentId] = .restricted

        if let groupId {
            registry.documentGroups[documentId] = [groupId]
            registry.ownerDocumentGroup[ownerId] = [documentId: groupId]
            registry.groupOwners[groupId] = owner
            registry.groupAccess[groupId] = .restricted
            registry.groups[groupId] = [documentId]

            var ownerGroups = registry.ownersGroups[owner] ?? []
            ownerGroups.append(
                .init(id: groupId, label: "Test Group", ownerId: ownerId, documents: [])
            )
            registry.ownersGroups[owner] = ownerGroups
        }

        return registry
    }

    // MARK: - Case Normalization

    func testMutatorRemoveFailsWhenOwnerIdCaseMismatches() async {
        let mutator = RegistryMutator.test()
        let doc = Database.Document.test(id: "doc-case", ownerId: "aabbccdd-0000-0000-0000-000000000001")
        await mutator.register(doc, group: nil, ownerId: "aabbccdd-0000-0000-0000-000000000001")

        let result = await mutator.remove(
            documentId: "doc-case",
            group: nil,
            ownerId: "AABBCCDD-0000-0000-0000-000000000001"
        )

        XCTAssertFalse(result.authorized, "remove must reject a caller whose ownerId differs only in case")
        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNotNil(snapshot.documentOwners["doc-case"],
            "document must still be present after rejected removal")
    }

    func testMutatorRemoveSucceedsWithMatchingLowercaseOwnerId() async {
        let mutator = RegistryMutator.test()
        let ownerId = "aabbccdd-0000-0000-0000-000000000001"
        let doc = Database.Document.test(id: "doc-lower", ownerId: ownerId)
        await mutator.register(doc, group: nil, ownerId: ownerId)

        let result = await mutator.remove(documentId: "doc-lower", group: nil, ownerId: ownerId)

        XCTAssertTrue(result.authorized)
        XCTAssertTrue(result.fullyRemoved, "sole owner removal must fully remove the document")
        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNil(snapshot.documentOwners["doc-lower"], "documentOwners must be cleared")
        XCTAssertNil(snapshot.documentAccess["doc-lower"], "documentAccess must be cleared")
    }

    // MARK: - Empty Group Cleanup on Remove

    func testRemoveLastDocumentLeavesEmptyGroupIntact() {
        let ownerId = "owner-a"
        var registry = registryWithDocument(
            documentId: "doc-1",
            ownerId: ownerId,
            groupId: "group-x"
        )
        let owner = ThreadRegistry.Owner(id: ownerId)

        registry.remove(documentId: "doc-1", group: nil, owner: owner)

        XCTAssertEqual(registry.groups["group-x"], [],
            "groups entry must be kept as empty — groups survive until explicitly deleted")
        XCTAssertNotNil(registry.groupOwners["group-x"],
            "groupOwners must be preserved for an empty group")
        XCTAssertNotNil(registry.groupAccess["group-x"],
            "groupAccess must be preserved for an empty group")
        XCTAssertTrue(
            registry.ownersGroups[owner]?.contains(where: { $0.id == "group-x" }) ?? false,
            "ownersGroups must still list the group after all its documents are removed"
        )
    }

    func testRemoveNonLastDocumentInGroupLeavesGroupIntact() {
        var registry = registryWithDocument(
            documentId: "doc-1",
            ownerId: "owner-a",
            groupId: "group-x"
        )
        let owner = ThreadRegistry.Owner(id: "owner-a")
        registry.documentOwners["doc-2"] = [owner]
        registry.documentGroups["doc-2"] = ["group-x"]
        registry.documentAccess["doc-2"] = .restricted
        var ownerDocs = registry.ownersDocuments[owner] ?? []
        ownerDocs.append("doc-2")
        registry.ownersDocuments[owner] = ownerDocs
        registry.groups["group-x"]?.append("doc-2")

        registry.remove(documentId: "doc-1", group: nil, owner: owner)

        XCTAssertNotNil(registry.groups["group-x"],
            "group must survive when it still has remaining documents")
        XCTAssertEqual(registry.groups["group-x"], ["doc-2"],
            "only the removed document must be absent from groups[groupId]")
        XCTAssertNotNil(registry.groupOwners["group-x"],
            "groupOwners must be preserved for a non-empty group")
        XCTAssertNotNil(registry.groupAccess["group-x"],
            "groupAccess must be preserved for a non-empty group")
    }

    func testRemoveWithGroupResolvedFromDocumentGroups() {
        let ownerId = "owner-b"
        var registry = registryWithDocument(
            documentId: "doc-3",
            ownerId: ownerId,
            groupId: "group-y"
        )
        let owner = ThreadRegistry.Owner(id: ownerId)

        let fullyRemoved = registry.remove(documentId: "doc-3", group: nil, owner: owner)

        XCTAssertTrue(fullyRemoved, "sole owner removal must be a full removal")
        XCTAssertNil(registry.documentOwners["doc-3"], "document must be removed")
        XCTAssertEqual(registry.groups["group-y"], [],
            "group must survive as empty even when the last document is removed without passing the group explicitly")
    }

    // MARK: - RegistryMutator: renameGroup ownership check

    func testRenameGroupRejectsNonOwner() async {
        let mutator = RegistryMutator.test()
        let doc = Database.Document.test(id: "doc-rename", ownerId: "real-owner")
        await mutator.register(doc, group: .test(id: "grp-1", ownerId: "real-owner"), ownerId: "real-owner")

        let renamed = await mutator.renameGroup(id: "grp-1", ownerId: "other-owner", label: "Hacked")

        XCTAssertFalse(renamed, "renameGroup must reject a caller who does not own the group")

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: "real-owner")
        let label = snapshot.ownersGroups[owner]?.first(where: { $0.id == "grp-1" })?.label
        XCTAssertEqual(label, "Test Group", "label must be unchanged after rejected rename")
    }

    func testRenameGroupSucceedsForOwner() async {
        let mutator = RegistryMutator.test()
        let doc = Database.Document.test(id: "doc-rename-ok", ownerId: "real-owner")
        await mutator.register(doc, group: .test(id: "grp-2", ownerId: "real-owner"), ownerId: "real-owner")

        let renamed = await mutator.renameGroup(id: "grp-2", ownerId: "real-owner", label: "New Name")

        XCTAssertTrue(renamed)
        let snapshot = mutator.snapshot ?? ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: "real-owner")
        let label = snapshot.ownersGroups[owner]?.first(where: { $0.id == "grp-2" })?.label
        XCTAssertEqual(label, "New Name")
    }

    // MARK: - DocumentStats: seeding and removal

    func testDocumentStatsSeededOnRegister() async {
        let mutator = RegistryMutator.test()
        let doc     = Database.Document.test(id: "doc-stats-seed", ownerId: "owner-stats")
        await mutator.register(doc, group: nil, ownerId: "owner-stats")

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNotNil(snapshot.documentStats["doc-stats-seed"],
            "documentStats must contain an entry for the document after registration")
    }

    func testDocumentStatsZeroEarningsOnFirstRegister() async {
        let mutator = RegistryMutator.test()
        let doc     = Database.Document.test(id: "doc-stats-zero", ownerId: "owner-stats")
        await mutator.register(doc, group: nil, ownerId: "owner-stats")

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        let stats    = snapshot.documentStats["doc-stats-zero"]
        XCTAssertEqual(stats?.totalEarned, 0,
            "totalEarned must be 0 immediately after registration")
    }

    func testDocumentStatsNotDuplicatedOnReRegister() async {
        let mutator = RegistryMutator.test()
        let doc     = Database.Document.test(id: "doc-stats-dup", ownerId: "owner-stats")
        await mutator.register(doc, group: nil, ownerId: "owner-stats")
        await mutator.accumulateEarnings(["doc-stats-dup": 5.0])
        await mutator.register(doc, group: nil, ownerId: "owner-stats")

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.documentStats["doc-stats-dup"]?.totalEarned, 5.0,
            "re-registering must not reset existing earnings")
    }

    func testDocumentStatsRemovedWhenDocumentIsRemoved() async {
        let mutator = RegistryMutator.test()
        let doc     = Database.Document.test(id: "doc-stats-del", ownerId: "owner-del")
        await mutator.register(doc, group: nil, ownerId: "owner-del")
        let result = await mutator.remove(documentId: "doc-stats-del", group: nil, ownerId: "owner-del")

        XCTAssertTrue(result.authorized)
        XCTAssertTrue(result.fullyRemoved)
        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNil(snapshot.documentStats["doc-stats-del"],
            "documentStats must be cleared when the document is removed")
    }

    func testDocumentStatsRemovedViaRegistryRemoveOrphaned() {
        var registry = ThreadRegistry()
        let owner    = ThreadRegistry.Owner(id: "owner-orphan")
        registry.documentOwners["doc-orphan"]  = [owner]
        registry.documentAccess["doc-orphan"]  = .restricted
        registry.documentStats["doc-orphan"]   = .init(id: "doc-orphan", totalEarned: 3.5)

        registry.removeOrphaned(documentId: "doc-orphan")

        XCTAssertNil(registry.documentStats["doc-orphan"],
            "removeOrphaned must clean up documentStats")
    }

    func testDocumentStatsRemovedViaRegistryRemove() {
        var registry  = ThreadRegistry()
        let owner     = ThreadRegistry.Owner(id: "owner-rm")
        registry.documentOwners["doc-rm"] = [owner]
        registry.ownersDocuments[owner]   = ["doc-rm"]
        registry.documentAccess["doc-rm"] = .restricted
        registry.documentStats["doc-rm"]  = .init(id: "doc-rm", totalEarned: 1.0)

        registry.remove(documentId: "doc-rm", group: nil, owner: owner)

        XCTAssertNil(registry.documentStats["doc-rm"],
            "registry.remove must delete the documentStats entry")
    }

    // MARK: - DocumentStats: accumulation

    func testAccumulateEarningsUpdatesStats() async {
        let mutator = RegistryMutator.test()
        let doc     = Database.Document.test(id: "doc-earn-1", ownerId: "owner-earn")
        await mutator.register(doc, group: nil, ownerId: "owner-earn")
        await mutator.accumulateEarnings(["doc-earn-1": 2.5])

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.documentStats["doc-earn-1"]?.totalEarned ?? -1, 2.5, accuracy: 1e-9)
    }

    func testAccumulateEarningsIsAdditive() async {
        let mutator = RegistryMutator.test()
        let doc     = Database.Document.test(id: "doc-earn-add", ownerId: "owner-earn")
        await mutator.register(doc, group: nil, ownerId: "owner-earn")
        await mutator.accumulateEarnings(["doc-earn-add": 1.0])
        await mutator.accumulateEarnings(["doc-earn-add": 2.0])

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.documentStats["doc-earn-add"]?.totalEarned ?? -1, 3.0, accuracy: 1e-9,
            "accumulateEarnings must add to the existing totalEarned, not replace it")
    }

    func testAccumulateEarningsIgnoresZeroCredits() async {
        let mutator = RegistryMutator.test()
        let doc     = Database.Document.test(id: "doc-earn-zero", ownerId: "owner-earn")
        await mutator.register(doc, group: nil, ownerId: "owner-earn")
        await mutator.accumulateEarnings(["doc-earn-zero": 0.0])

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.documentStats["doc-earn-zero"]?.totalEarned ?? 0, 0,
            "zero-credit accumulation must not change totalEarned")
    }

    func testAccumulateEarningsCreatesEntryForUnregisteredDocument() async {
        let mutator = RegistryMutator.test()
        await mutator.accumulateEarnings(["doc-unregistered": 7.0])

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.documentStats["doc-unregistered"]?.totalEarned ?? -1, 7.0, accuracy: 1e-9,
            "accumulateEarnings must create a stats entry even if the document was not registered")
    }

    func testAccumulateEarningsMultipleDocumentsInOneCall() async {
        let mutator = RegistryMutator.test()
        await mutator.accumulateEarnings(["doc-multi-a": 3.0, "doc-multi-b": 1.5, "doc-multi-c": 0.75])

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.documentStats["doc-multi-a"]?.totalEarned ?? -1, 3.0,   accuracy: 1e-9)
        XCTAssertEqual(snapshot.documentStats["doc-multi-b"]?.totalEarned ?? -1, 1.5,   accuracy: 1e-9)
        XCTAssertEqual(snapshot.documentStats["doc-multi-c"]?.totalEarned ?? -1, 0.75,  accuracy: 1e-9)
    }

    // MARK: - DocumentStats: group total earnings

    func testTotalEarningsForGroupSumsDocumentStats() {
        var registry = ThreadRegistry()
        registry.groups["grp-earn"] = ["doc-x", "doc-y", "doc-z"]
        registry.documentStats["doc-x"] = .init(id: "doc-x", totalEarned: 1.0)
        registry.documentStats["doc-y"] = .init(id: "doc-y", totalEarned: 2.5)
        registry.documentStats["doc-z"] = .init(id: "doc-z", totalEarned: 0.5)

        let total = registry.totalEarnings(for: "grp-earn")
        XCTAssertEqual(total, 4.0, accuracy: 1e-9,
            "totalEarnings must sum all document stats in the group")
    }

    func testTotalEarningsForGroupWithMissingStatsCountsAsZero() {
        var registry = ThreadRegistry()
        registry.groups["grp-partial"] = ["doc-has-stats", "doc-no-stats"]
        registry.documentStats["doc-has-stats"] = .init(id: "doc-has-stats", totalEarned: 3.0)

        let total = registry.totalEarnings(for: "grp-partial")
        XCTAssertEqual(total, 3.0, accuracy: 1e-9,
            "missing stats entry must count as 0, not crash")
    }

    func testTotalEarningsForUnknownGroupIsZero() {
        let registry = ThreadRegistry()
        XCTAssertEqual(registry.totalEarnings(for: "nonexistent-group"), 0,
            "unknown group must return 0 total earnings")
    }

    func testAddEarningsOnRegistryUpdatesExistingEntry() {
        var registry = ThreadRegistry()
        registry.documentStats["doc-add"] = .init(id: "doc-add", totalEarned: 2.0)

        registry.addEarnings(["doc-add": 1.5])

        XCTAssertEqual(registry.documentStats["doc-add"]?.totalEarned ?? -1, 3.5, accuracy: 1e-9)
    }

    func testAddEarningsOnRegistryCreatesNewEntry() {
        var registry = ThreadRegistry()
        registry.addEarnings(["doc-new": 4.0])

        XCTAssertNotNil(registry.documentStats["doc-new"])
        XCTAssertEqual(registry.documentStats["doc-new"]?.totalEarned ?? -1, 4.0, accuracy: 1e-9)
    }

    func testAddEarningsSkipsZeroValues() {
        var registry = ThreadRegistry()
        registry.addEarnings(["doc-skip": 0.0])
        XCTAssertEqual(registry.documentStats["doc-skip"]?.totalEarned ?? 0, 0)
    }

    // MARK: - RegistryMutator: updateGroup cleans up empty old group

    func testUpdateGroupPreservesEmptyOldGroup() async {
        let mutator = RegistryMutator.test()
        let ownerId = "owner-update"
        let doc = Database.Document.test(id: "doc-move", ownerId: ownerId)
        await mutator.register(doc, group: .test(id: "old-grp", ownerId: ownerId), ownerId: ownerId)

        let moved = await mutator.updateGroup(
            .test(id: "new-grp", ownerId: ownerId),
            documentId: "doc-move",
            ownerId: ownerId
        )
        XCTAssertTrue(moved)

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: ownerId)

        // Old group is preserved as empty — groups survive until explicitly deleted.
        XCTAssertEqual(snapshot.groups["old-grp"], [],
            "old group must be kept as empty after the last document moves out")
        XCTAssertNotNil(snapshot.groupOwners["old-grp"],
            "groupOwners must be preserved for the emptied old group")
        XCTAssertNotNil(snapshot.groupAccess["old-grp"],
            "groupAccess must be preserved for the emptied old group")
        XCTAssertTrue(
            snapshot.ownersGroups[owner]?.contains(where: { $0.id == "old-grp" }) ?? false,
            "ownersGroups must still list the old group after it empties"
        )

        // Document-level indices must point to the new group.
        XCTAssertTrue(
            snapshot.documentGroups["doc-move"]?.contains("new-grp") == true,
            "document must be recorded under new group in the Set index"
        )
        XCTAssertFalse(
            snapshot.documentGroups["doc-move"]?.contains("old-grp") == true,
            "old group must be absent from the document's group Set"
        )
        XCTAssertEqual(
            snapshot.ownerDocumentGroup[ownerId]?["doc-move"], "new-grp",
            "ownerDocumentGroup must reflect the new group for this owner"
        )
    }

    // MARK: - removeGroupEntries

    // Regression: POST /v1/modify/group/remove returned HTTP 200 and logged
    // "removed with 0 document(s)" but the group persisted in the registry
    // because removeBatch([]) never triggered group-key cleanup.
    // Fix: the route now calls removeGroupEntries after removeBatch so the
    // group-level keys are always purged regardless of document count.

    func testRemoveGroupEntriesEmptyGroupClearsAllKeys() async {
        let mutator = RegistryMutator.test()
        let ownerId = "owner-a"
        let owner = ThreadRegistry.Owner(id: ownerId)

        await mutator.register(
            .test(id: "doc-1", ownerId: ownerId),
            group: .test(id: "grp-1", ownerId: ownerId),
            ownerId: ownerId
        )

        // Simulate the remove-doc step: doc is unlinked, group becomes empty.
        await mutator.removeBatch(items: [("doc-1", ownerId)])

        // Group is intentionally preserved after removeBatch (84d5bc5).
        let afterRemove = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNotNil(afterRemove.groupOwners["grp-1"],
            "precondition: group must survive removeBatch (groups persist until explicitly deleted)")

        // Now simulate the route calling removeGroupEntries after removeBatch.
        await mutator.removeGroupEntries(["grp-1"], ownerId: ownerId)

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNil(snapshot.groups["grp-1"],
            "groups entry must be absent after removeGroupEntries")
        XCTAssertNil(snapshot.groupOwners["grp-1"],
            "groupOwners entry must be absent after removeGroupEntries")
        XCTAssertNil(snapshot.groupAccess["grp-1"],
            "groupAccess entry must be absent after removeGroupEntries")
        XCTAssertFalse(
            snapshot.ownersGroups[owner]?.contains(where: { $0.id == "grp-1" }) ?? false,
            "ownersGroups must not list grp-1 after removeGroupEntries")
    }

    func testRemoveGroupEntriesAlreadyEmptyGroupClearsAllKeys() async {
        // The exact production scenario: group has 0 docs when remove-group is called
        // (docs were removed in an earlier request). removeBatch([]) is a no-op, so
        // removeGroupEntries must still clean up.
        let mutator = RegistryMutator.test()
        let ownerId = "owner-a"
        let owner = ThreadRegistry.Owner(id: ownerId)

        await mutator.register(
            .test(id: "doc-1", ownerId: ownerId),
            group: .test(id: "grp-1", ownerId: ownerId),
            ownerId: ownerId
        )
        await mutator.removeBatch(items: [("doc-1", ownerId)])

        // removeBatch with empty items (simulates the route calling it with 0 docs)
        await mutator.removeBatch(items: [])
        await mutator.removeGroupEntries(["grp-1"], ownerId: ownerId)

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNil(snapshot.groupOwners["grp-1"],
            "groupOwners must be cleared even when removeBatch was called with 0 items")
        XCTAssertNil(snapshot.groups["grp-1"],
            "groups must be cleared even when removeBatch was called with 0 items")
        XCTAssertFalse(
            snapshot.ownersGroups[owner]?.contains(where: { $0.id == "grp-1" }) ?? false,
            "ownersGroups must not list the group after removeGroupEntries")
    }

    func testRemoveGroupEntriesNonOwnerRejected() async {
        let mutator = RegistryMutator.test()

        await mutator.register(
            .test(id: "doc-1", ownerId: "owner-a"),
            group: .test(id: "grp-a", ownerId: "owner-a"),
            ownerId: "owner-a"
        )

        // owner-b attempts to delete owner-a's group.
        await mutator.removeGroupEntries(["grp-a"], ownerId: "owner-b")

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNotNil(snapshot.groupOwners["grp-a"],
            "groupOwners must not be cleared when the caller does not own the group")
        XCTAssertNotNil(snapshot.groups["grp-a"],
            "groups entry must survive a foreign removeGroupEntries call")
    }

    func testRemoveGroupEntriesPreservesOtherOwnersGroups() async {
        let mutator = RegistryMutator.test()

        await mutator.register(
            .test(id: "doc-a", ownerId: "owner-a"),
            group: .test(id: "grp-a", ownerId: "owner-a"),
            ownerId: "owner-a"
        )
        await mutator.register(
            .test(id: "doc-b", ownerId: "owner-b"),
            group: .test(id: "grp-b", ownerId: "owner-b"),
            ownerId: "owner-b"
        )

        await mutator.removeBatch(items: [("doc-a", "owner-a")])
        await mutator.removeGroupEntries(["grp-a"], ownerId: "owner-a")

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        // owner-a's group gone
        XCTAssertNil(snapshot.groupOwners["grp-a"])
        // owner-b's group untouched
        XCTAssertNotNil(snapshot.groupOwners["grp-b"],
            "owner-b's group must be unaffected by owner-a's removeGroupEntries call")
        XCTAssertEqual(snapshot.groups["grp-b"], ["doc-b"],
            "owner-b's document list must be unaffected")
    }
}
