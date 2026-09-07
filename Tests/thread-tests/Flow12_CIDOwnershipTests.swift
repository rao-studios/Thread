//
//  Flow12_CIDOwnershipTests.swift
//  database-serverTests
//
//  Tests for the one-to-many CID ownership model:
//    ThreadRegistry.linkOwner        — adds an owner to an existing document's Set
//    ThreadRegistry.isOwnerLinked    — query-side checks
//    ThreadRegistry.remove()         — unlink vs full-remove semantics
//    ThreadRegistry.removeOrphaned   — must iterate all owners in the Set
//    RegistryMutator.linkOwner/linkOwnerBatch  — actor-serialized link ops
//    RegistryMutator.remove()      — (authorized, fullyRemoved) return tuple
//    RegistryMutator.removeAll()   — split between fullyRemoved and allOwned
//    documentGroups Set            — grows on link, shrinks on unlink, key removed when empty
//    documentStats                 — preserved while co-owners exist; purged on full deletion
//

import XCTest
@testable import thread

final class Flow12_CIDOwnershipTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a minimal single-owner registry entry for `documentId`.
    private func makeRegistry(documentId: String = "doc-1", ownerId: String = "owner-a") -> ThreadRegistry {
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: documentId, state: .restricted)
        registry.documentOwners[documentId] = [ThreadRegistry.Owner(id: ownerId)]
        registry.ownersDocuments[.init(id: ownerId)] = [documentId]
        registry.documentStats[documentId] = .init(id: documentId)
        return registry
    }

    // MARK: - ThreadRegistry.linkOwner

    func testLinkOwnerAddsNewOwnerToSet() {
        var registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        registry.linkOwner(documentId: "doc-1", ownerId: "bob", group: nil)

        let owners = registry.documentOwners["doc-1"]
        XCTAssertEqual(owners?.count, 2)
        XCTAssertTrue(owners?.contains(.init(id: "alice")) == true)
        XCTAssertTrue(owners?.contains(.init(id: "bob")) == true)
    }

    func testLinkOwnerIsIdempotent() {
        var registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        registry.linkOwner(documentId: "doc-1", ownerId: "alice", group: nil)
        registry.linkOwner(documentId: "doc-1", ownerId: "alice", group: nil)

        XCTAssertEqual(registry.documentOwners["doc-1"]?.count, 1,
            "linking the same owner twice must not add a duplicate")
    }

    func testLinkOwnerPopulatesOwnersDocuments() {
        var registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        registry.linkOwner(documentId: "doc-1", ownerId: "bob", group: nil)

        XCTAssertTrue(registry.ownersDocuments[.init(id: "bob")]?.contains("doc-1") == true)
    }

    func testLinkOwnerWithGroupUpdatesDocumentGroupsSet() {
        var registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        let group = Database.Group.test(id: "grp-bob", ownerId: "bob")
        registry.linkOwner(documentId: "doc-1", ownerId: "bob", group: group)

        XCTAssertTrue(registry.documentGroups["doc-1"]?.contains("grp-bob") == true,
            "linking with a group must add the group to the documentGroups Set")
    }

    func testLinkOwnerWithGroupSetsOwnerDocumentGroup() {
        var registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        let group = Database.Group.test(id: "grp-bob", ownerId: "bob")
        registry.linkOwner(documentId: "doc-1", ownerId: "bob", group: group)

        XCTAssertEqual(registry.ownerDocumentGroup["bob"]?["doc-1"], "grp-bob")
    }

    func testLinkOwnerWithGroupAddsToGroups() {
        var registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        let group = Database.Group.test(id: "grp-bob", ownerId: "bob")
        registry.linkOwner(documentId: "doc-1", ownerId: "bob", group: group)

        XCTAssertTrue(registry.groups["grp-bob"]?.contains("doc-1") == true)
    }

    func testLinkOwnerPreservesExistingOwnerGroup() {
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "doc-1", state: .restricted)
        registry.documentOwners["doc-1"] = [.init(id: "alice")]
        registry.ownersDocuments[.init(id: "alice")] = ["doc-1"]
        registry.ownerDocumentGroup["alice"] = ["doc-1": "grp-alice"]
        registry.documentGroups["doc-1"] = ["grp-alice"]

        let group = Database.Group.test(id: "grp-bob", ownerId: "bob")
        registry.linkOwner(documentId: "doc-1", ownerId: "bob", group: group)

        XCTAssertTrue(registry.documentGroups["doc-1"]?.contains("grp-alice") == true,
            "alice's group must be preserved after bob links")
        XCTAssertTrue(registry.documentGroups["doc-1"]?.contains("grp-bob") == true,
            "bob's group must be added when bob links")
        XCTAssertEqual(registry.ownerDocumentGroup["alice"]?["doc-1"], "grp-alice",
            "per-owner maps must remain independent")
        XCTAssertEqual(registry.ownerDocumentGroup["bob"]?["doc-1"], "grp-bob")
    }

    // MARK: - linkOwner: same owner, new group (regression — was silently dropped)

    func testLinkOwnerAlreadyLinkedOwnerAddsNewGroup() {
        // Owner is already linked via grp-a. Calling linkOwner again with grp-b must
        // add grp-b without duplicating the owner in documentOwners.
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "doc-1", state: .restricted)
        registry.documentOwners["doc-1"] = [.init(id: "alice")]
        registry.ownersDocuments[.init(id: "alice")] = ["doc-1"]
        registry.ownerDocumentGroup["alice"] = ["doc-1": "grp-a"]
        registry.documentGroups["doc-1"] = ["grp-a"]
        registry.groups["grp-a"] = ["doc-1"]
        registry.groupOwners["grp-a"] = .init(id: "alice")
        registry.ownersGroups[.init(id: "alice")] = [.test(id: "grp-a", ownerId: "alice")]

        registry.linkOwner(documentId: "doc-1", ownerId: "alice",
                           group: .test(id: "grp-b", ownerId: "alice"))

        XCTAssertEqual(registry.documentOwners["doc-1"]?.count, 1,
            "owner must not be duplicated when linking to a second group")
        XCTAssertTrue(registry.documentGroups["doc-1"]?.contains("grp-a") == true,
            "original group must remain in documentGroups")
        XCTAssertTrue(registry.documentGroups["doc-1"]?.contains("grp-b") == true,
            "new group must be added to documentGroups")
        XCTAssertTrue(registry.groups["grp-b"]?.contains("doc-1") == true,
            "groups[grp-b] must list the document")
    }

    func testLinkOwnerAlreadyLinkedOwnerPreservesPrimaryGroup() {
        // ownerDocumentGroup tracks the primary (first-registered) group for removal
        // resolution — it must not be overwritten when a second group is linked.
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "doc-1", state: .restricted)
        registry.documentOwners["doc-1"] = [.init(id: "alice")]
        registry.ownersDocuments[.init(id: "alice")] = ["doc-1"]
        registry.ownerDocumentGroup["alice"] = ["doc-1": "grp-a"]
        registry.documentGroups["doc-1"] = ["grp-a"]
        registry.groupOwners["grp-a"] = .init(id: "alice")

        registry.linkOwner(documentId: "doc-1", ownerId: "alice",
                           group: .test(id: "grp-b", ownerId: "alice"))

        XCTAssertEqual(registry.ownerDocumentGroup["alice"]?["doc-1"], "grp-a",
            "ownerDocumentGroup must keep grp-a as the primary group — must not be overwritten")
    }

    func testLinkOwnerAlreadyLinkedOwnerAddsToOwnersGroups() {
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "doc-1", state: .restricted)
        registry.documentOwners["doc-1"] = [.init(id: "alice")]
        registry.ownersDocuments[.init(id: "alice")] = ["doc-1"]
        registry.ownerDocumentGroup["alice"] = ["doc-1": "grp-a"]
        registry.documentGroups["doc-1"] = ["grp-a"]
        registry.groupOwners["grp-a"] = .init(id: "alice")
        registry.ownersGroups[.init(id: "alice")] = [.test(id: "grp-a", ownerId: "alice")]

        registry.linkOwner(documentId: "doc-1", ownerId: "alice",
                           group: .test(id: "grp-b", ownerId: "alice"))

        let aliceGroups = registry.ownersGroups[.init(id: "alice")] ?? []
        XCTAssertEqual(aliceGroups.count, 2,
            "ownersGroups must have exactly 2 entries after linking a second group")
        XCTAssertTrue(aliceGroups.contains(where: { $0.id == "grp-b" }),
            "grp-b must appear in ownersGroups")
    }

    func testMutatorLinkOwnerAlreadyLinkedOwnerAddsNewGroup() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())

        let groupA = Database.Group.test(id: "mg-grp-a", ownerId: "alice")
        await mutator.register(.test(id: "mg-doc"), group: groupA, ownerId: "alice")

        // Same owner, same document, new group — must create the group.
        let groupB = Database.Group.test(id: "mg-grp-b", ownerId: "alice")
        await mutator.linkOwner(documentId: "mg-doc", group: groupB, ownerId: "alice")

        let registry = mutator.snapshot!
        XCTAssertEqual(registry.documentOwners["mg-doc"]?.count, 1,
            "owner count must not increase when linking the same owner to a new group")
        XCTAssertTrue(registry.documentGroups["mg-doc"]?.contains("mg-grp-a") == true)
        XCTAssertTrue(registry.documentGroups["mg-doc"]?.contains("mg-grp-b") == true,
            "both groups must be tracked in documentGroups after the second link")
        XCTAssertTrue(registry.groups["mg-grp-b"]?.contains("mg-doc") == true,
            "mg-grp-b must list mg-doc in the groups map")
        XCTAssertTrue(registry.ownersGroups[.init(id: "alice")]?.contains(where: { $0.id == "mg-grp-b" }) == true,
            "mg-grp-b must appear in alice's ownersGroups")
    }

    // MARK: - ThreadRegistry.isOwnerLinked

    func testIsOwnerLinkedTrueForRegisteredOwner() {
        let registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        XCTAssertTrue(registry.isOwnerLinked("doc-1", ownerId: "alice"))
    }

    func testIsOwnerLinkedFalseForUnrelatedOwner() {
        let registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        XCTAssertFalse(registry.isOwnerLinked("doc-1", ownerId: "bob"))
    }

    func testIsOwnerLinkedFalseForUnknownDocument() {
        let registry = ThreadRegistry()
        XCTAssertFalse(registry.isOwnerLinked("no-such-doc", ownerId: "alice"))
    }

    func testIsOwnerLinkedTrueAfterLinkOwner() {
        var registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        XCTAssertFalse(registry.isOwnerLinked("doc-1", ownerId: "bob"))
        registry.linkOwner(documentId: "doc-1", ownerId: "bob", group: nil)
        XCTAssertTrue(registry.isOwnerLinked("doc-1", ownerId: "bob"))
    }

    // MARK: - ThreadRegistry.remove — unlink when a co-owner remains

    func testRemoveWithCoOwnerReturnsFalse() {
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "doc-1", state: .restricted)
        registry.documentOwners["doc-1"] = [.init(id: "alice"), .init(id: "bob")]
        registry.ownersDocuments[.init(id: "alice")] = ["doc-1"]
        registry.ownersDocuments[.init(id: "bob")] = ["doc-1"]

        let fullyRemoved = registry.remove(documentId: "doc-1", group: nil, owner: .init(id: "alice"))
        XCTAssertFalse(fullyRemoved, "remove must return false when a co-owner remains")
    }

    func testRemoveWithCoOwnerDocumentStillExists() {
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "doc-1", state: .restricted)
        registry.documentOwners["doc-1"] = [.init(id: "alice"), .init(id: "bob")]
        registry.ownersDocuments[.init(id: "alice")] = ["doc-1"]
        registry.ownersDocuments[.init(id: "bob")] = ["doc-1"]

        registry.remove(documentId: "doc-1", group: nil, owner: .init(id: "alice"))

        XCTAssertNotNil(registry.documentOwners["doc-1"],
            "documentOwners entry must persist while bob still holds the document")
        XCTAssertTrue(registry.documentOwners["doc-1"]?.contains(.init(id: "bob")) == true)
        XCTAssertFalse(registry.documentOwners["doc-1"]?.contains(.init(id: "alice")) == true,
            "alice must be removed from the owners Set")
        XCTAssertNotNil(registry.documentAccess["doc-1"],
            "documentAccess must be preserved while a co-owner holds the document")
    }

    func testRemoveWithCoOwnerRemovesFromOwnersDocuments() {
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "doc-1", state: .restricted)
        registry.documentOwners["doc-1"] = [.init(id: "alice"), .init(id: "bob")]
        registry.ownersDocuments[.init(id: "alice")] = ["doc-1"]
        registry.ownersDocuments[.init(id: "bob")] = ["doc-1"]

        registry.remove(documentId: "doc-1", group: nil, owner: .init(id: "alice"))

        XCTAssertFalse(registry.ownersDocuments[.init(id: "alice")]?.contains("doc-1") == true,
            "alice's ownersDocuments must not list the document after she unlinks")
    }

    // MARK: - ThreadRegistry.remove — last owner fully removes document

    func testRemoveLastOwnerReturnsTrue() {
        var registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        let fullyRemoved = registry.remove(documentId: "doc-1", group: nil, owner: .init(id: "alice"))
        XCTAssertTrue(fullyRemoved, "remove must return true when the last owner is removed")
    }

    func testRemoveLastOwnerPurgesDocumentOwners() {
        var registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        registry.remove(documentId: "doc-1", group: nil, owner: .init(id: "alice"))
        XCTAssertNil(registry.documentOwners["doc-1"])
    }

    func testRemoveLastOwnerPurgesDocumentAccess() {
        var registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        registry.remove(documentId: "doc-1", group: nil, owner: .init(id: "alice"))
        XCTAssertNil(registry.documentAccess["doc-1"])
    }

    func testRemoveLastOwnerPurgesDocumentStats() {
        var registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        registry.remove(documentId: "doc-1", group: nil, owner: .init(id: "alice"))
        XCTAssertNil(registry.documentStats["doc-1"],
            "documentStats must be removed when the last owner is gone")
    }

    func testRemoveLastOwnerPurgesAvailableDocumentIds() {
        var registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        registry.updateDocumentAccess(for: "doc-1", state: .available)
        registry.remove(documentId: "doc-1", group: nil, owner: .init(id: "alice"))
        XCTAssertFalse(registry.availableDocumentIds.contains("doc-1"))
    }

    // MARK: - documentGroups Set lifecycle

    func testDocumentGroupsGrowsOnEachLink() {
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "doc-1", state: .restricted)
        registry.documentOwners["doc-1"] = [.init(id: "alice")]
        registry.ownersDocuments[.init(id: "alice")] = ["doc-1"]
        registry.documentGroups["doc-1"] = ["grp-alice"]

        registry.linkOwner(documentId: "doc-1", ownerId: "bob",
                           group: .test(id: "grp-bob", ownerId: "bob"))
        registry.linkOwner(documentId: "doc-1", ownerId: "charlie",
                           group: .test(id: "grp-charlie", ownerId: "charlie"))

        XCTAssertEqual(registry.documentGroups["doc-1"]?.count, 3,
            "each linked owner contributes their group to the Set")
    }

    func testDocumentGroupsSetShrinksonUnlink() {
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "doc-1", state: .restricted)
        registry.documentOwners["doc-1"] = [.init(id: "alice"), .init(id: "bob")]
        registry.ownersDocuments[.init(id: "alice")] = ["doc-1"]
        registry.ownersDocuments[.init(id: "bob")] = ["doc-1"]
        registry.ownerDocumentGroup["alice"] = ["doc-1": "grp-alice"]
        registry.ownerDocumentGroup["bob"]   = ["doc-1": "grp-bob"]
        registry.documentGroups["doc-1"] = ["grp-alice", "grp-bob"]
        registry.groups["grp-alice"] = ["doc-1"]
        registry.groups["grp-bob"]   = ["doc-1"]

        registry.remove(documentId: "doc-1", group: nil, owner: .init(id: "alice"))

        XCTAssertFalse(registry.documentGroups["doc-1"]?.contains("grp-alice") == true,
            "alice's group must be removed from the Set after she unlinks")
        XCTAssertTrue(registry.documentGroups["doc-1"]?.contains("grp-bob") == true,
            "bob's group must remain in the Set while he still holds the document")
    }

    func testDocumentGroupsKeyRemovedWhenNoGroupsRemain() {
        var registry = makeRegistry(documentId: "doc-1", ownerId: "alice")
        registry.ownerDocumentGroup["alice"] = ["doc-1": "grp-alice"]
        registry.documentGroups["doc-1"] = ["grp-alice"]
        registry.groups["grp-alice"] = ["doc-1"]

        registry.remove(documentId: "doc-1", group: nil, owner: .init(id: "alice"))

        XCTAssertNil(registry.documentGroups["doc-1"],
            "documentGroups key must be removed when no groups remain after full deletion")
    }

    // MARK: - Stats preserved / removed lifecycle

    func testStatsPreservedWhileCoOwnerExists() {
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "doc-1", state: .restricted)
        registry.documentOwners["doc-1"] = [.init(id: "alice"), .init(id: "bob")]
        registry.ownersDocuments[.init(id: "alice")] = ["doc-1"]
        registry.ownersDocuments[.init(id: "bob")] = ["doc-1"]
        registry.documentStats["doc-1"] = .init(id: "doc-1")

        registry.remove(documentId: "doc-1", group: nil, owner: .init(id: "alice"))

        XCTAssertNotNil(registry.documentStats["doc-1"],
            "documentStats must be preserved while bob still holds the document")
    }

    func testStatsRemovedWithLastOwner() {
        var registry = makeRegistry(documentId: "doc-1", ownerId: "alice")

        registry.remove(documentId: "doc-1", group: nil, owner: .init(id: "alice"))

        XCTAssertNil(registry.documentStats["doc-1"],
            "documentStats must be purged when the last owner removes the document")
    }

    // MARK: - removeOrphaned iterates all owners in the Set

    func testRemoveOrphanedClearsAllOwnersFromOwnersDocuments() {
        var registry = ThreadRegistry()
        registry.updateDocumentAccess(for: "orphan", state: .restricted)
        registry.documentOwners["orphan"] = [.init(id: "alice"), .init(id: "bob")]
        registry.ownersDocuments[.init(id: "alice")] = ["orphan", "other"]
        registry.ownersDocuments[.init(id: "bob")] = ["orphan"]

        registry.removeOrphaned(documentId: "orphan")

        XCTAssertNil(registry.documentOwners["orphan"])
        XCTAssertFalse(registry.ownersDocuments[.init(id: "alice")]?.contains("orphan") == true,
            "orphan must be removed from alice's ownersDocuments")
        XCTAssertTrue(registry.ownersDocuments[.init(id: "alice")]?.contains("other") == true,
            "other documents owned by alice must not be affected")
        XCTAssertFalse(registry.ownersDocuments[.init(id: "bob")]?.contains("orphan") == true)
    }

    // MARK: - RegistryMutator.linkOwner (through actor)

    func testMutatorLinkOwnerLinksNewOwner() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())

        await mutator.register(.test(id: "doc-1", ownerId: "alice"), group: nil, ownerId: "alice")
        await mutator.linkOwner(documentId: "doc-1", group: nil, ownerId: "bob")

        let registry = mutator.snapshot!
        XCTAssertTrue(registry.isOwnerLinked("doc-1", ownerId: "bob"))
        XCTAssertEqual(registry.documentOwners["doc-1"]?.count, 2)
    }

    func testMutatorLinkOwnerIsIdempotent() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())

        await mutator.register(.test(id: "doc-1", ownerId: "alice"), group: nil, ownerId: "alice")
        await mutator.linkOwner(documentId: "doc-1", group: nil, ownerId: "alice")
        await mutator.linkOwner(documentId: "doc-1", group: nil, ownerId: "alice")

        let registry = mutator.snapshot!
        XCTAssertEqual(registry.documentOwners["doc-1"]?.count, 1,
            "idempotent linkOwner must not add duplicates")
    }

    func testMutatorLinkOwnerWithGroupPopulatesAllMaps() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())

        await mutator.register(.test(id: "doc-1", ownerId: "alice"), group: nil, ownerId: "alice")
        let group = Database.Group.test(id: "grp-bob", ownerId: "bob")
        await mutator.linkOwner(documentId: "doc-1", group: group, ownerId: "bob")

        let registry = mutator.snapshot!
        XCTAssertEqual(registry.ownerDocumentGroup["bob"]?["doc-1"], "grp-bob")
        XCTAssertTrue(registry.documentGroups["doc-1"]?.contains("grp-bob") == true)
        XCTAssertTrue(registry.groups["grp-bob"]?.contains("doc-1") == true)
    }

    // MARK: - RegistryMutator.linkOwnerBatch

    func testMutatorLinkOwnerBatchLinksMultipleDocuments() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())

        await mutator.registerBatch(items: [
            (.test(id: "doc-a"), nil, "alice"),
            (.test(id: "doc-b"), nil, "alice"),
            (.test(id: "doc-c"), nil, "alice"),
        ])
        await mutator.linkOwnerBatch(items: [
            (documentId: "doc-a", group: nil, ownerId: "bob"),
            (documentId: "doc-b", group: nil, ownerId: "bob"),
        ])

        let registry = mutator.snapshot!
        XCTAssertTrue(registry.isOwnerLinked("doc-a", ownerId: "bob"))
        XCTAssertTrue(registry.isOwnerLinked("doc-b", ownerId: "bob"))
        XCTAssertFalse(registry.isOwnerLinked("doc-c", ownerId: "bob"),
            "doc-c was not in the batch and must not be linked to bob")
    }

    func testMutatorLinkOwnerBatchEmptyIsNoOp() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())
        await mutator.register(.test(id: "doc-1", ownerId: "alice"), group: nil, ownerId: "alice")

        await mutator.linkOwnerBatch(items: [])

        let registry = mutator.snapshot!
        XCTAssertEqual(registry.documentOwners["doc-1"]?.count, 1,
            "empty batch must not alter existing ownership")
    }

    // MARK: - RegistryMutator.remove — (authorized, fullyRemoved) tuple

    func testMutatorRemoveUnauthorizedReturnsFalse() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())
        await mutator.register(.test(id: "doc-1", ownerId: "alice"), group: nil, ownerId: "alice")

        let result = await mutator.remove(documentId: "doc-1", group: nil, ownerId: "not-an-owner")
        XCTAssertFalse(result.authorized, "non-owner removal must be unauthorized")
        XCTAssertFalse(result.fullyRemoved)
    }

    func testMutatorRemoveUnlinkOnlyWhenCoOwnerExists() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())
        await mutator.register(.test(id: "doc-1", ownerId: "alice"), group: nil, ownerId: "alice")
        await mutator.linkOwner(documentId: "doc-1", group: nil, ownerId: "bob")

        let result = await mutator.remove(documentId: "doc-1", group: nil, ownerId: "alice")
        XCTAssertTrue(result.authorized)
        XCTAssertFalse(result.fullyRemoved,
            "must not fully remove while bob co-owns the document")

        let registry = mutator.snapshot!
        XCTAssertTrue(registry.isOwnerLinked("doc-1", ownerId: "bob"),
            "bob must still own the document after alice unlinks")
        XCTAssertFalse(registry.isOwnerLinked("doc-1", ownerId: "alice"))
    }

    func testMutatorRemoveFullyRemovesLastOwner() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())
        await mutator.register(.test(id: "doc-1", ownerId: "alice"), group: nil, ownerId: "alice")

        let result = await mutator.remove(documentId: "doc-1", group: nil, ownerId: "alice")
        XCTAssertTrue(result.authorized)
        XCTAssertTrue(result.fullyRemoved,
            "sole owner removal must fully remove the document")

        let registry = mutator.snapshot!
        XCTAssertNil(registry.documentOwners["doc-1"])
        XCTAssertNil(registry.documentAccess["doc-1"])
    }

    // MARK: - RegistryMutator.removeAll — fullyRemoved vs allOwned split

    func testMutatorRemoveAllReturnsSplitLists() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())

        // alice owns doc-a and doc-b; bob co-owns doc-b
        await mutator.register(.test(id: "doc-a"), group: nil, ownerId: "alice")
        await mutator.register(.test(id: "doc-b"), group: nil, ownerId: "alice")
        await mutator.linkOwner(documentId: "doc-b", group: nil, ownerId: "bob")

        let (fullyRemoved, allOwned) = await mutator.removeAll(ownerId: "alice")

        XCTAssertEqual(Set(allOwned), Set(["doc-a", "doc-b"]),
            "allOwned must include every document alice held")
        XCTAssertEqual(Set(fullyRemoved), Set(["doc-a"]),
            "only doc-a (sole-owner) must be in fullyRemoved")
        XCTAssertFalse(fullyRemoved.contains("doc-b"),
            "doc-b must not be in fullyRemoved since bob still owns it")
    }

    func testMutatorRemoveAllClearsOwnerRecords() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())
        await mutator.register(.test(id: "doc-a"), group: nil, ownerId: "alice")
        await mutator.register(.test(id: "doc-b"), group: nil, ownerId: "alice")

        _ = await mutator.removeAll(ownerId: "alice")

        let registry = mutator.snapshot!
        let aliceKey = ThreadRegistry.Owner(id: "alice")
        XCTAssertNil(registry.ownersDocuments[aliceKey],
            "ownersDocuments entry for alice must be removed after removeAll")
        XCTAssertNil(registry.ownersGroups[aliceKey])
        XCTAssertNil(registry.ownerDocumentGroup["alice"])
    }

    func testMutatorRemoveAllCoOwnedDocumentSurvives() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())

        await mutator.register(.test(id: "shared"), group: nil, ownerId: "alice")
        await mutator.linkOwner(documentId: "shared", group: nil, ownerId: "bob")

        _ = await mutator.removeAll(ownerId: "alice")

        let registry = mutator.snapshot!
        XCTAssertNotNil(registry.documentOwners["shared"],
            "shared document must persist in registry since bob still owns it")
        XCTAssertTrue(registry.isOwnerLinked("shared", ownerId: "bob"))
        XCTAssertFalse(registry.isOwnerLinked("shared", ownerId: "alice"))
    }

    // MARK: - Full CID deduplication lifecycle

    func testCIDDeduplicationLifecycle() async {
        let mutator = RegistryMutator.test()
        mutator.seed(.init())

        // Step 1: alice uploads the document — it gets embedded and registered.
        await mutator.register(.test(id: "doc-cid"), group: nil, ownerId: "alice")
        XCTAssertTrue(mutator.snapshot!.doesDocumentExist("doc-cid"))

        // Step 2: bob uploads identical content — CID matches, so link instead of re-embed.
        await mutator.linkOwner(documentId: "doc-cid", group: nil, ownerId: "bob")
        XCTAssertEqual(mutator.snapshot!.documentOwners["doc-cid"]?.count, 2)
        XCTAssertTrue(mutator.snapshot!.isOwnerLinked("doc-cid", ownerId: "alice"))
        XCTAssertTrue(mutator.snapshot!.isOwnerLinked("doc-cid", ownerId: "bob"))

        // Step 3: alice deletes her copy — bob still owns it, no physical deletion.
        let removeAlice = await mutator.remove(documentId: "doc-cid", group: nil, ownerId: "alice")
        XCTAssertTrue(removeAlice.authorized)
        XCTAssertFalse(removeAlice.fullyRemoved,
            "alice's deletion must not trigger physical removal while bob co-owns")
        XCTAssertTrue(mutator.snapshot!.isOwnerLinked("doc-cid", ownerId: "bob"),
            "bob must still own the document after alice unlinks")
        XCTAssertTrue(mutator.snapshot!.doesDocumentExist("doc-cid"),
            "document must still exist in the registry")

        // Step 4: bob deletes — last owner gone, physical deletion is now required.
        let removeBob = await mutator.remove(documentId: "doc-cid", group: nil, ownerId: "bob")
        XCTAssertTrue(removeBob.authorized)
        XCTAssertTrue(removeBob.fullyRemoved,
            "bob's deletion must signal that the physical document should be purged")
        XCTAssertNil(mutator.snapshot!.documentOwners["doc-cid"])
        XCTAssertNil(mutator.snapshot!.documentAccess["doc-cid"])
        XCTAssertFalse(mutator.snapshot!.doesDocumentExist("doc-cid"))
    }
}
