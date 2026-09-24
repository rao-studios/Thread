//
//  Flow25_CodeSearchGRPCTests.swift
//  thread-tests
//
//  The contract as a client sees it over gRPC: `media_type = "code"` with bare
//  identifiers in `entities` boosts the document that names them, returns only code,
//  spends no second embedding, and echoes what it applied; an empty `media_type` is
//  the search as it was.
//

import XCTest
import Conduit
import GRPCCore
import Logging
@testable import thread

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class Flow25_CodeSearchGRPCTests: XCTestCase {

    private var tempRoot: URL!
    private let owner = "code-search-owner"
    private let group = "craft-code-flow25"
    private let ctx = GRPCCore.ServerContext(
        descriptor: .init(service: .init(fullyQualifiedService: "test"), method: "test"),
        remotePeer: "test", localPeer: "local", cancellation: .init()
    )

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-code-search-\(UUID().uuidString)")
        FilePersistence.configure(dataDirectory: tempRoot.path)
    }

    override func tearDown() {
        FilePersistence.configure(dataDirectory: nil)
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private let q = VectorFixtures.random(dim: VectorFixtures.embeddingDim, seed: 25_025)

    private func shifted(by amount: Float) -> [Float] {
        var v = q
        v[0] += amount
        return v
    }

    private func waitForIndexed(_ id: String, in database: Database, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if database.table?.keys.contains(id) == true { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("document \(id) was not indexed within \(timeout)s")
    }

    private func index(_ id: String, mediaType: String, text: String, vector: [Float],
                       entities: [(String, String)], query: ThreadQueryServiceImpl, database: Database) async throws {
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = id
        item.mediaType = mediaType
        item.texts = [text]
        var partition = Thread_V1_ThreadPartitionInput()
        partition.embedding = vector
        item.partitions = [partition]
        item.entities = entities.map { name, kind in
            var e = Thread_V1_ThreadGraphEntityIn()
            e.name = name
            e.kind = kind
            return e
        }
        var request = Thread_V1_ThreadIndexRequest()
        request.ownerID = owner
        request.groupID = group
        request.groupLabel = "Flow25"
        request.items = [item]
        _ = try await query.index(request: request, context: ctx)
        await waitForIndexed(id, in: database)
    }

    private func searchRequest(mediaType: String, topK: Int32 = 0) -> Thread_V1_ThreadSearchRequest {
        var search = Thread_V1_ThreadSearchRequest()
        search.ownerID = owner
        search.groupIds = [group]
        search.queryEmbedding = q
        search.queryText = "how does this project start a child flow25"
        search.entities = ["posix_spawn"]
        search.mediaType = mediaType
        search.topK = topK
        return search
    }

    func testACodeSearchBoostsTheDocumentThatNamesItsIdentifiers() async throws {
        let database = Database(nodeId: UUID(uuidString: "00000000-0000-0000-0000-00000000f25c")!)
        await database.initializationTask.value
        let provider = RecordingEmbeddingProvider()
        let query = ThreadQueryServiceImpl(database: database, embeddingProvider: provider,
                                           graphExtractor: KeywordGraphExtractionProvider())

        // The card that names posix_spawn is a little farther from the query than the notes.
        try await index("spawn.swift", mediaType: "code", text: "// craft:fn ProcessRunner.run()",
                        vector: shifted(by: 0.28), entities: [("type:posix_spawn", "function")],
                        query: query, database: database)
        try await index("notes.md", mediaType: "text", text: "prose notes about the week",
                        vector: shifted(by: 0.25), entities: [], query: query, database: database)
        try await index("far.swift", mediaType: "code", text: "// craft:type struct Other",
                        vector: VectorFixtures.random(dim: VectorFixtures.embeddingDim, seed: 91),
                        entities: [("sym:Other", "struct")], query: query, database: database)

        let code = try await query.search(request: searchRequest(mediaType: "code"), context: ctx)
        XCTAssertEqual(code.results.first?.documentID, "spawn.swift")
        XCTAssertFalse(code.results.contains { $0.documentID == "notes.md" }, "a code search returns only code")
        XCTAssertTrue(code.results.contains { $0.documentID == "far.swift" }, "a match boosts; it never gates")
        XCTAssertEqual(code.results.map(\.score), code.results.map(\.score).sorted())
        XCTAssertEqual(code.trace.mediaType, "code")
        XCTAssertEqual(code.trace.matchedEntityNames, ["type:posix_spawn"])
        XCTAssertEqual(code.trace.matchedEntityIds, [GraphStore.entityID(kind: "function", name: "type:posix_spawn")])
        let embedded = await provider.embedded
        XCTAssertFalse(embedded.contains { $0.hasPrefix("Relationship predicates:") },
                       "a code search's entities are identifiers, not predicates")

        let prose = try await query.search(request: searchRequest(mediaType: ""), context: ctx)
        XCTAssertEqual(prose.results.first?.documentID, "notes.md", "without the spec, nothing is boosted")
        XCTAssertEqual(prose.trace.mediaType, "")
        let afterProse = await provider.embedded
        XCTAssertTrue(afterProse.contains("Relationship predicates: posix_spawn"), "the prose path is unchanged")

        let cut = try await query.search(request: searchRequest(mediaType: "", topK: 2), context: ctx)
        XCTAssertEqual(cut.results.count, 2, "top_k is honoured")

        await database.shutdown()
    }
}
