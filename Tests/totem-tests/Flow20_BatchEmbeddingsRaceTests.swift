//
//  Flow20_BatchEmbeddingsRaceTests.swift
//  database-serverTests
//
//  Tests the link-only simultaneous-request race condition in the batch
//  embeddings route end-to-end using a real Hummingbird application, a real
//  Database instance, and a MockEmbeddingProvider (no network calls).
//
//  Race scenario
//  ─────────────
//  Two requests submit the same document simultaneously.  Request A completes
//  Phase 1 first (doc not in registry → prepared), calls enqueuePut, and the
//  IndexQueue registers the document.  Request B's Phase 1 then runs and sees
//  the document as already existing → classified as link-only, prepared is
//  empty.
//
//  Old behaviour: groupEnrichedReq guarded on `!prepared.isEmpty`, so when
//  prepared was empty the bare databaseReq (nil group metadata) was passed to
//  linkOwnerBatch → group created with no tags.
//
//  Fix: Phase 1 now preserves texts for link-only results. groupEnrichedReq
//  runs TagGenerator on both prepared AND link-only items, so even an all-
//  link-only request produces a tag-enriched group.
//

import XCTest
import Hummingbird
import HummingbirdTesting
import Logging
@testable import totem

final class Flow20_BatchEmbeddingsRaceTests: XCTestCase {

    // MARK: - Helpers

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("database-flow20-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        wipeTotemPersistenceFiles()
    }

    /// Builds a minimal Hummingbird Application with just the batch embeddings
    /// route registered, backed by a real Database instance and MockEmbeddingProvider.
    /// Totem has no auth middleware — ownerId comes directly from the request body.
    private func makeApp(database: Database) -> Application<RouterResponder<TotemRequestContext>> {
        let router = Router(context: TotemRequestContext.self)
        let mock = MockEmbeddingProvider()
        registerBatchEmbeddingsRoute(router, database, embeddingModelProvider: mock,
                                     graphExtractor: KeywordGraphExtractionProvider())
        return Application(router: router)
    }

    private func makeDatabase() async -> Database {
        wipeTotemPersistenceFiles()
        let database = Database()
        await database.initializationTask.value
        return database
    }

    /// Sends a POST to `/v1/batch/embeddings` and returns the decoded response.
    private func embed(
        app: some ApplicationProtocol,
        ownerId: String,
        groupId: String,
        groupLabel: String,
        texts: [String]
    ) async throws -> EmbeddingBatchResponse {
        let body: [String: Any] = [
            "inputs": texts,
            "totem": [
                "owner_id": ownerId,
                "group": ["id": groupId, "label": groupLabel, "owner_id": ownerId],
                "scope": "personal"
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        // nonisolated(unsafe): written once inside the awaited test closure then
        // immediately read after — sequentially ordered, no actual data race.
        nonisolated(unsafe) var result: EmbeddingBatchResponse?
        try await app.test(.live) { client in
            let response = try await client.execute(
                uri: "/v1/batch/embeddings",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(data: bodyData)
            )
            XCTAssertEqual(response.status, .ok, "Route must return 200 OK")
            // Hummingbird's responseEncoder uses .iso8601 for Date fields.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            result = try decoder.decode(
                EmbeddingBatchResponse.self,
                from: Data(buffer: response.body)
            )
        }
        return result!
    }

    /// The ingest route responds before the detached enrichment task enqueues the
    /// put — poll until `predicate` holds (or fail after `timeout`).
    private func waitFor(_ what: String, timeout: TimeInterval = 10,
                         predicate: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("\(what) did not become true within \(timeout)s")
    }

    // =========================================================================
    // MARK: - Race condition: same document in two sequential requests
    // =========================================================================

    /// Verifies that a group created via the link-only path still receives tags.
    ///
    /// Steps:
    ///  1. Request A: submit text T under group G1 → prepared path, IndexQueue
    ///     registers doc D and creates group G1 with tags.
    ///  2. Drain the IndexQueue so the registry snapshot is up to date.
    ///  3. Request B: submit the same text T under group G2 → Phase 1 sees D as
    ///     existing, classifies it as link-only, prepared is empty.
    ///  4. Drain the IndexQueue (barrier for any pending linkOwnerBatch work).
    ///  5. Assert group G2 exists and has tags derived from T.
    func testLinkOnlyPathPropagatesTagsToNewGroup() async throws {
        let database = await makeDatabase()
        let app = makeApp(database: database)

        let ownerId     = "race-route-owner"
        let sharedTexts = ["loop quantum gravity gauge connection fiber bundle"]

        // ── Request A: new document → prepared path ───────────────────────────
        let resA = try await embed(app: app, ownerId: ownerId,
                                   groupId: "race-group-a", groupLabel: "Group A",
                                   texts: sharedTexts)
        XCTAssertTrue(resA.success, "Request A must succeed")

        // The route responds before the detached enrichment enqueues the put —
        // wait until the document is fully registered before B's Phase 1.
        let owner = TotemRegistry.Owner(id: ownerId)
        await waitFor("Group A registered") {
            database.registry?.ownersGroups[owner]?.contains { $0.id == "race-group-a" } ?? false
        }
        _ = await database.removeAll(ownerId: "barrier", request: .test())

        let groupA = database.registry?.ownersGroups[owner]?
            .first { $0.id == "race-group-a" }
        XCTAssertNotNil(groupA, "Group A must be registered after Request A drains")
        XCTAssertFalse(groupA?.metadata?.tags.isEmpty ?? true,
            "Group A must have tags from the prepared-path document")

        // ── Request B: same document → link-only path ─────────────────────────
        // The registry now has the document; Phase 1 will classify it as
        // link-only (exists + owner linked + only group-a linked → new group).
        let resB = try await embed(app: app, ownerId: ownerId,
                                   groupId: "race-group-b", groupLabel: "Group B",
                                   texts: sharedTexts)
        XCTAssertTrue(resB.success, "Request B must succeed")

        // Give linkOwnerBatch (background Task) time to execute.
        await waitFor("Group B registered") {
            database.registry?.ownersGroups[owner]?.contains { $0.id == "race-group-b" } ?? false
        }
        _ = await database.removeAll(ownerId: "barrier", request: .test())

        // ── Assert: group B has tags from the link-only enriched request ──────
        let groupB = database.registry?.ownersGroups[owner]?
            .first { $0.id == "race-group-b" }
        XCTAssertNotNil(groupB,
            "Group B must be created by linkOwnerBatch even when prepared is empty")
        XCTAssertFalse(groupB?.metadata?.tags.isEmpty ?? true,
            "Group B must have tags — the fixed groupEnrichedReq must include " +
            "tags computed from the link-only document's preserved texts, even " +
            "when prepared is empty")
    }

    /// Contrast: when the same document is submitted for the first time under
    /// group G, the normal prepared path runs and the group receives tags.
    /// This confirms the mock and test harness are working correctly.
    func testPreparedPathAlwaysProducesTags() async throws {
        let database = await makeDatabase()
        let app = makeApp(database: database)

        let ownerId = "prepared-route-owner"
        let res = try await embed(app: app, ownerId: ownerId,
                                  groupId: "prepared-group", groupLabel: "Physics",
                                  texts: ["quantum field theory gauge boson interactions"])
        XCTAssertTrue(res.success, "Request must succeed")
        let owner = TotemRegistry.Owner(id: ownerId)
        await waitFor("Group registered") {
            database.registry?.ownersGroups[owner]?.contains { $0.id == "prepared-group" } ?? false
        }
        _ = await database.removeAll(ownerId: "barrier", request: .test())

        let group = database.registry?.ownersGroups[owner]?
            .first { $0.id == "prepared-group" }
        XCTAssertNotNil(group, "Group must be registered")
        XCTAssertFalse(group?.metadata?.tags.isEmpty ?? true,
            "Prepared-path group must have tags from TagGenerator")
    }

    // MARK: - Preprocess slot accounting

    /// Counts every acquire/release so the balance can be asserted after
    /// throwing and non-throwing bodies.
    private actor SlotCountingProvider: EmbeddingProviding {
        var acquired = 0
        var released = 0

        func acquirePreprocessSlot() async { acquired += 1 }
        func releasePreprocessSlot() async { released += 1 }
        func run(_ texts: [String], logger: Logger, priority: Bool) async throws
            -> (result: [EmbeddingData], usage: Requests.Embedding.Get.Result.Usage) {
            ([], Requests.Embedding.Get.Result.Usage(
                promptAudioSeconds: nil, promptTokens: 0, totalTokens: 0,
                completionTokens: 0, requestCount: nil, promptTokenDetails: nil))
        }
    }

    private struct SlotTestError: Error {}

    /// withPreprocessSlot must release exactly once per acquire — including when
    /// the body throws. The old `defer { Task { await release } }` pattern could
    /// leak slots when the unstructured release task was never scheduled.
    func testWithPreprocessSlotReleasesOnEveryPath() async {
        let provider = SlotCountingProvider()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    do {
                        try await provider.withPreprocessSlot {
                            if i % 2 == 0 { throw SlotTestError() }
                        }
                    } catch {}
                }
            }
        }

        let acquired = await provider.acquired
        let released = await provider.released
        XCTAssertEqual(acquired, 50)
        XCTAssertEqual(released, 50,
            "Every acquired slot must be released — throwing bodies included")
    }
}
