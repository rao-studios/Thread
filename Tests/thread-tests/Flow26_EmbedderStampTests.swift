//
//  Flow26_EmbedderStampTests.swift
//  thread-tests
//
//  Which embedder wrote a node's vectors is kept beside the table, and a Thread
//  started with another one says so instead of searching garbage: an empty table
//  takes the running embedder's stamp, a different space is a mismatch, vectors
//  from before stamps are unstamped, and a clear re-stamps. /health carries it.
//

import XCTest
import Conduit
import GRPCCore
import Logging
@testable import thread

/// A provider that names a vector space and a load state, and embeds nothing real.
actor StampingProvider: EmbeddingProviding {
    nonisolated let vectorSpace: String?
    nonisolated let health: EmbedderHealth?

    init(space: String, phase: EmbedderHealth.Phase = .ready, progress: Double? = nil) {
        self.vectorSpace = space
        self.health = EmbedderHealth(
            model: "org/\(space)", revision: "abc", vectorSpace: space, phase: phase, progress: progress)
    }

    func acquirePreprocessSlot() async {}
    func releasePreprocessSlot() async {}
    func run(_ texts: [String], logger: Logger, role: EmbeddingRole)
        async throws -> (result: [EmbeddingData], usage: Requests.Embedding.Get.Result.Usage) {
        let result = texts.enumerated().map { i, text in
            EmbeddingData(embedding: .floats(RecordingEmbeddingProvider.vector(for: text)), index: i)
        }
        return (result, Requests.Embedding.Get.Result.Usage(
            promptAudioSeconds: nil, promptTokens: 0, totalTokens: 0,
            completionTokens: 0, requestCount: nil, promptTokenDetails: nil))
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class Flow26_EmbedderStampTests: XCTestCase {

    private var tempRoot: URL!
    private let nodeId = UUID(uuidString: "00000000-0000-0000-0000-00000000f26d")!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-stamp-\(UUID().uuidString)")
        FilePersistence.configure(dataDirectory: tempRoot.path)
    }

    override func tearDown() {
        FilePersistence.configure(dataDirectory: nil)
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func stamp(_ space: String) -> EmbedderStamp {
        EmbedderStamp(vectorSpace: space, model: "m", revision: nil, stampedAt: Date())
    }

    // MARK: - The rule

    func testAnEmptyTableAlwaysMatches() {
        XCTAssertEqual(Database.indexState(stored: nil, running: "voyage-4@1024", tableIsEmpty: true), .matches)
        XCTAssertEqual(Database.indexState(stored: stamp("mistral-embed@1024"), running: "voyage-4@1024", tableIsEmpty: true), .matches)
    }

    func testAFilledTableIsJudgedByItsStamp() {
        XCTAssertEqual(Database.indexState(stored: stamp("voyage-4@1024"), running: "voyage-4@1024", tableIsEmpty: false), .matches)
        XCTAssertEqual(Database.indexState(stored: stamp("mistral-embed@1024"), running: "voyage-4@1024", tableIsEmpty: false),
                       .mismatch(stamped: "mistral-embed@1024"))
        XCTAssertEqual(Database.indexState(stored: nil, running: "voyage-4@1024", tableIsEmpty: false), .unstamped)
    }

    // MARK: - On disk

    private func database() async -> Database {
        let database = Database(nodeId: nodeId)
        await database.initializationTask.value
        return database
    }

    private func fill(_ database: Database) async {
        let provider = StampingProvider(space: "voyage-4@1024")
        let query = ThreadQueryServiceImpl(database: database, embeddingProvider: provider,
                                           graphExtractor: KeywordGraphExtractionProvider())
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = "doc-stamp"
        item.texts = ["a stamped passage"]
        var request = Thread_V1_ThreadIndexRequest()
        request.ownerID = "stamp-owner"
        request.groupID = "g"
        request.items = [item]
        _ = try? await query.index(request: request, context: .init(
            descriptor: .init(service: .init(fullyQualifiedService: "test"), method: "test"),
            remotePeer: "test", localPeer: "local", cancellation: .init()))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, database.table?.keys.contains("doc-stamp") != true {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(database.table?.keys.contains("doc-stamp"), true)
    }

    func testTheSameEmbedderAfterARestartMatches() async {
        let first = await database()
        let state = await first.reconcileEmbedder(vectorSpace: "voyage-4@1024", model: "m", revision: "r")
        XCTAssertEqual(state, .matches, "empty: stamped for the running embedder")
        await fill(first)
        await first.shutdown()

        let second = await database()
        let again = await second.reconcileEmbedder(vectorSpace: "voyage-4@1024", model: "m", revision: "r")
        XCTAssertEqual(again, .matches)
        await second.shutdown()
    }

    func testAnotherEmbedderOverAFilledTableIsAMismatchUntilCleared() async {
        let first = await database()
        await first.reconcileEmbedder(vectorSpace: "mistral-embed@1024", model: "mistral-embed", revision: nil)
        await fill(first)
        await first.shutdown()

        let second = await database()
        let state = await second.reconcileEmbedder(vectorSpace: "voyage-4@1024", model: "m", revision: "r")
        XCTAssertEqual(state, .mismatch(stamped: "mistral-embed@1024"))
        let held = await second.indexState
        XCTAssertEqual(held, .mismatch(stamped: "mistral-embed@1024"))

        _ = await second.clearAll()
        let cleared = await second.indexState
        XCTAssertEqual(cleared, .matches, "a clear re-stamps for the running embedder")
        let written: EmbedderStamp? = second.embedderStampStore.restore()
        XCTAssertEqual(written?.vectorSpace, "voyage-4@1024")
        await second.shutdown()
    }

    func testVectorsFromBeforeStampsAreUnstamped() async {
        let first = await database()
        await fill(first)                       // no reconcile: an index from before stamps
        await first.shutdown()

        let second = await database()
        let state = await second.reconcileEmbedder(vectorSpace: "voyage-4@1024", model: "m", revision: "r")
        XCTAssertEqual(state, .unstamped)
        await second.shutdown()
    }

    // MARK: - A mismatched index is held still

    private var ctx: GRPCCore.ServerContext {
        .init(descriptor: .init(service: .init(fullyQualifiedService: "test"), method: "test"),
              remotePeer: "test", localPeer: "local", cancellation: .init())
    }

    /// Choosing the other model must not file into this index (switching back would
    /// find it mixed) nor search it (its vectors mean nothing to this model's query).
    func testAMismatchedIndexTakesNoFilingAndAnswersNoSearch() async throws {
        let first = await database()
        await first.reconcileEmbedder(vectorSpace: "voyage-4@1024", model: "m", revision: nil)
        await fill(first)
        await first.shutdown()

        let second = await database()
        await second.reconcileEmbedder(vectorSpace: "mistral-embed@1024", model: "mistral-embed", revision: nil)
        let refusal = await second.vectorRefusal()
        XCTAssertNotNil(refusal)
        let query = ThreadQueryServiceImpl(database: second, embeddingProvider: StampingProvider(space: "mistral-embed@1024"),
                                           graphExtractor: KeywordGraphExtractionProvider())
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = "doc-other-space"
        item.texts = ["filed while the other model runs"]
        var index = Thread_V1_ThreadIndexRequest()
        index.ownerID = "stamp-owner"
        index.groupID = "g"
        index.items = [item]
        do {
            _ = try await query.index(request: index, context: ctx)
            XCTFail("a filing into another model's index must be refused")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .failedPrecondition)
        }
        var search = Thread_V1_ThreadSearchRequest()
        search.ownerID = "stamp-owner"
        search.queryText = "a stamped passage"
        let hits = try await query.search(request: search, context: ctx).results
        XCTAssertTrue(hits.isEmpty, "no hits from vectors this model cannot compare with")
        XCTAssertEqual(second.table?.keys.contains("doc-other-space"), false)
        await second.shutdown()

        // Back to the model that built it: whole again, and searchable.
        let third = await database()
        let state = await third.reconcileEmbedder(vectorSpace: "voyage-4@1024", model: "m", revision: nil)
        XCTAssertEqual(state, .matches)
        let allowed = await third.vectorRefusal()
        XCTAssertNil(allowed)
        await third.shutdown()
    }

    // MARK: - /health

    func testHealthCarriesTheEmbedderAndTheIndexState() throws {
        let provider = StampingProvider(space: "voyage-4@1024", phase: .downloading, progress: 0.42)
        let block = HealthEmbedder(provider: provider, index: .mismatch(stamped: "mistral-embed@1024"))
        XCTAssertEqual(block.phase, "downloading")
        XCTAssertEqual(block.progress, 0.42)
        XCTAssertEqual(block.vectorSpace, "voyage-4@1024")
        XCTAssertEqual(block.index, "mismatch")
        XCTAssertEqual(block.indexedWith, "mistral-embed@1024")

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(block)) as? [String: Any]
        XCTAssertEqual(json?["phase"] as? String, "downloading")
        XCTAssertEqual(json?["indexedWith"] as? String, "mistral-embed@1024")
    }

    func testAHostedProviderReadsAsReady() {
        let block = HealthEmbedder(provider: EmbeddingModelProvider(logger: Logger(label: "t")), index: nil)
        XCTAssertEqual(block.phase, "ready")
        XCTAssertEqual(block.vectorSpace, "mistral-embed@1024")
        XCTAssertNil(block.index)
    }
}
