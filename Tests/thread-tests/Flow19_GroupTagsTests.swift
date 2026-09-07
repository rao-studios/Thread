//
//  Flow19_GroupTagsTests.swift
//  database-serverTests
//
//  Tests the two-part group tag propagation fix:
//
//  §1  ThreadRegistry.applyRegister — new and existing group tag behaviour
//        • new group: tags from g.metadata are stored as-is
//        • existing group: new tags are unioned into stored metadata
//        • existing group: empty incoming tags leave stored tags untouched
//        • duplicate / overlapping tags are deduplicated and sorted
//
//  §2  DatabaseRequest tag merge — mirrors the capturedReq closure in BatchEmbeddings.swift
//        • no group → request returned unchanged
//        • group with nil metadata → batch tags set as initial metadata
//        • group with existing tags → merged with batch tags (union)
//        • group with existing tags, no batch tags → request returned unchanged
//        • tags already on request are never dropped even when batch adds more
//        • fully overlapping batch tags produce no duplicates
//

import XCTest
@testable import thread

final class Flow19_GroupTagsTests: XCTestCase {

    // MARK: - Helpers

    /// Mirrors the capturedReq closure in BatchEmbeddings.swift so it can be tested
    /// without the full HTTP stack.
    private func mergeBatchTags(
        into request: DatabaseRequest,
        batchTagsPerDoc: [[String]]
    ) -> DatabaseRequest {
        guard var g = request.group else { return request }
        let existingTags = g.metadata?.tags ?? []
        let flatBatch    = batchTagsPerDoc.flatMap { $0 }
        let mergedTags   = Array(Set(existingTags + flatBatch)).sorted()
        guard !mergedTags.isEmpty else { return request }
        var meta = g.metadata ?? Database.Group.Metadata()
        meta.tags = mergedTags
        g.metadata = meta
        return DatabaseRequest(ownerId: request.ownerId, group: g,
                           groups: request.groups, tags: request.tags,
                           aggregate: request.aggregate, scope: request.scope,
                           requestID: request.requestID)
    }

    private func groupTags(in registry: ThreadRegistry, owner: String, groupId: String) -> [String]? {
        registry.ownersGroups[ThreadRegistry.Owner(id: owner)]?
            .first { $0.id == groupId }?
            .metadata?.tags
    }

    // =========================================================================
    // MARK: - §1  ThreadRegistry.applyRegister
    // =========================================================================

    func testNewGroupReceivesBatchTags() {
        var registry = ThreadRegistry()
        let meta  = Database.Group.Metadata(tags: ["ml", "arxiv"])
        let group = Database.Group.test(id: "grp-new-tags", metadata: meta)

        registry.applyRegister(documentId: "doc-1", ownerId: "owner-1", group: group)

        let stored = groupTags(in: registry, owner: "owner-1", groupId: "grp-new-tags")
        XCTAssertEqual(Set(stored ?? []), Set(["arxiv", "ml"]),
            "New group must store the tags supplied in g.metadata")
    }

    func testNewGroupWithNoMetadataHasEmptyTags() {
        var registry = ThreadRegistry()
        let group = Database.Group.test(id: "grp-no-meta", metadata: nil)

        registry.applyRegister(documentId: "doc-1", ownerId: "owner-1", group: group)

        let stored = groupTags(in: registry, owner: "owner-1", groupId: "grp-no-meta")
        XCTAssertEqual(stored ?? [], [],
            "New group with no metadata must have empty tags")
    }

    func testExistingGroupMergesNewTags() {
        var registry = ThreadRegistry()
        let groupId  = "grp-merge"
        let ownerId  = "owner-merge"

        // First batch: creates the group with initial tags.
        let meta1 = Database.Group.Metadata(tags: ["physics", "optics"])
        registry.applyRegister(documentId: "doc-1", ownerId: ownerId,
                               group: .test(id: groupId, metadata: meta1))

        // Second batch: new tags must be unioned in.
        let meta2 = Database.Group.Metadata(tags: ["biology", "optics"])
        registry.applyRegister(documentId: "doc-2", ownerId: ownerId,
                               group: .test(id: groupId, metadata: meta2))

        let stored = groupTags(in: registry, owner: ownerId, groupId: groupId)
        XCTAssertEqual(stored, ["biology", "optics", "physics"],
            "Existing group must hold the sorted union of both tag sets")
    }

    func testExistingGroupTagsPreservedWhenIncomingTagsEmpty() {
        var registry = ThreadRegistry()
        let groupId  = "grp-preserve"
        let ownerId  = "owner-preserve"

        // First batch: creates the group with tags.
        let meta1 = Database.Group.Metadata(tags: ["cosmology"])
        registry.applyRegister(documentId: "doc-1", ownerId: ownerId,
                               group: .test(id: groupId, metadata: meta1))

        // Second batch: group has no new tags (metadata nil).
        registry.applyRegister(documentId: "doc-2", ownerId: ownerId,
                               group: .test(id: groupId, metadata: nil))

        let stored = groupTags(in: registry, owner: ownerId, groupId: groupId)
        XCTAssertEqual(stored, ["cosmology"],
            "Existing group tags must not be cleared when the second batch carries no tags")
    }

    func testExistingGroupDeduplicatesOverlappingTags() {
        var registry = ThreadRegistry()
        let groupId  = "grp-dedup"
        let ownerId  = "owner-dedup"

        let meta1 = Database.Group.Metadata(tags: ["ai", "robotics"])
        registry.applyRegister(documentId: "doc-1", ownerId: ownerId,
                               group: .test(id: groupId, metadata: meta1))

        // Second batch has a fully-overlapping tag set.
        let meta2 = Database.Group.Metadata(tags: ["robotics", "ai"])
        registry.applyRegister(documentId: "doc-2", ownerId: ownerId,
                               group: .test(id: groupId, metadata: meta2))

        let stored = groupTags(in: registry, owner: ownerId, groupId: groupId)
        XCTAssertEqual(stored, ["ai", "robotics"],
            "Overlapping tags must be deduplicated — no duplicate entries in the stored set")
    }

    func testMultipleBatchesAccumulateDistinctTags() {
        var registry = ThreadRegistry()
        let groupId  = "grp-accum"
        let ownerId  = "owner-accum"

        for (docId, tags) in [
            ("doc-1", ["quantum"]),
            ("doc-2", ["relativity"]),
            ("doc-3", ["quantum", "thermodynamics"]),
        ] {
            registry.applyRegister(documentId: docId, ownerId: ownerId,
                                   group: .test(id: groupId,
                                                metadata: .init(tags: tags)))
        }

        let stored = groupTags(in: registry, owner: ownerId, groupId: groupId)
        XCTAssertEqual(stored, ["quantum", "relativity", "thermodynamics"],
            "Three sequential batches must accumulate into one deduplicated sorted set")
    }

    // =========================================================================
    // MARK: - §2  DatabaseRequest tag merge (capturedReq closure)
    // =========================================================================

    func testNoGroupReturnsSameRequest() {
        let request = DatabaseRequest.test(ownerId: "owner-x")
        let result  = mergeBatchTags(into: request, batchTagsPerDoc: [["ai", "ml"]])

        XCTAssertNil(result.group, "Request without a group must be returned unchanged")
        XCTAssertEqual(result.ownerId, request.ownerId)
    }

    func testGroupWithNilMetadataGetsBatchTagsAsInitialMetadata() {
        let group   = Database.Group.test(id: "grp-init", metadata: nil)
        let request = DatabaseRequest(ownerId: "owner-init", group: group, aggregate: nil, scope: .personal, requestID: nil)

        let result = mergeBatchTags(into: request, batchTagsPerDoc: [["nlp"], ["vision", "nlp"]])

        XCTAssertEqual(result.group?.metadata?.tags, ["nlp", "vision"],
            "Group with no metadata must receive sorted-unique batch tags as initial metadata")
    }

    func testGroupWithExistingTagsMergedWithBatchTags() {
        let meta    = Database.Group.Metadata(tags: ["physics"])
        let group   = Database.Group.test(id: "grp-merge-req", metadata: meta)
        let request = DatabaseRequest(ownerId: "owner-merge-req", group: group, aggregate: nil, scope: .personal, requestID: nil)

        let result = mergeBatchTags(into: request, batchTagsPerDoc: [["chemistry"], ["biology", "physics"]])

        XCTAssertEqual(result.group?.metadata?.tags, ["biology", "chemistry", "physics"],
            "Existing group tags must be merged with batch tags into a sorted-unique set")
    }

    func testGroupWithExistingTagsAndNoBatchTagsReturnsSameRequest() {
        let meta    = Database.Group.Metadata(tags: ["original"])
        let group   = Database.Group.test(id: "grp-no-batch", metadata: meta)
        let request = DatabaseRequest(ownerId: "owner-no-batch", group: group, aggregate: nil, scope: .personal, requestID: nil)

        let result = mergeBatchTags(into: request, batchTagsPerDoc: [[], []])

        XCTAssertEqual(result.group?.metadata?.tags, ["original"],
            "When batch produces no tags, existing request tags must be preserved unchanged")
    }

    func testFullyOverlappingBatchTagsProduceNoDuplicates() {
        let meta    = Database.Group.Metadata(tags: ["ml", "ai"])
        let group   = Database.Group.test(id: "grp-overlap", metadata: meta)
        let request = DatabaseRequest(ownerId: "owner-overlap", group: group, aggregate: nil, scope: .personal, requestID: nil)

        let result = mergeBatchTags(into: request, batchTagsPerDoc: [["ai"], ["ml"], ["ai", "ml"]])

        XCTAssertEqual(result.group?.metadata?.tags, ["ai", "ml"],
            "Fully overlapping batch tags must not introduce duplicates")
    }

    func testGroupDescriptionPreservedThroughTagMerge() {
        let meta    = Database.Group.Metadata(description: "Keep me", tags: ["a"])
        let group   = Database.Group.test(id: "grp-desc", metadata: meta)
        let request = DatabaseRequest(ownerId: "owner-desc", group: group, aggregate: nil, scope: .personal, requestID: nil)

        let result = mergeBatchTags(into: request, batchTagsPerDoc: [["b"]])

        XCTAssertEqual(result.group?.metadata?.description, "Keep me",
            "Tag merge must not clobber the group metadata description")
        XCTAssertEqual(result.group?.metadata?.tags, ["a", "b"])
    }
}
