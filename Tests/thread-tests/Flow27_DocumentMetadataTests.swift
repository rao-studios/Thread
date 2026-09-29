//
//  Flow27_DocumentMetadataTests.swift
//  thread-tests
//
//  A document's metadata comes back with it. `ThreadIndexItem.metadata` has
//  always been stored per document; `Documents` and `ExportCorpus` now return
//  it as `ThreadDocumentContent.metadata`, byte for byte, because it carries a
//  Rao Verified record whose seal signs bytes that must not change. A document
//  deposited without metadata comes back with none, and a document filed
//  again comes back with what it was filed with last.
//

import XCTest
import Conduit
import GRPCCore
import Logging
@testable import thread

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class Flow27_DocumentMetadataTests: XCTestCase {

    private var tempRoot: URL!
    private let owner = "metadata-owner"
    private let nodeID = UUID(uuidString: "00000000-0000-0000-0000-00000000f27d")!
    private let ctx = GRPCCore.ServerContext(
        descriptor: .init(service: .init(fullyQualifiedService: "test"), method: "test"),
        remotePeer: "test", localPeer: "local", cancellation: .init()
    )

    /// A record as Ambient stamps one: the body is a string inside a flat
    /// object, with escapes and non-ASCII that any re-encoding would disturb.
    private let stamped = Data(#"{"kind":"reading","rao_verified":"{\"tag\":\"rao-verified\",\"doc\":\"d\\\"é\/1\"}","rao_verified_seal":"ES256.se.0123456789abcdef.AAAA.BBBB"}"#.utf8)

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-metadata-\(UUID().uuidString)")
        FilePersistence.configure(dataDirectory: tempRoot.path)
    }

    override func tearDown() {
        FilePersistence.configure(dataDirectory: nil)
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Stack

    private struct Stack {
        let database: Database
        let query: ThreadQueryServiceImpl
        let library: ThreadLibraryServiceImpl
    }

    private func makeStack() async -> Stack {
        let database = Database(nodeId: nodeID)
        await database.initializationTask.value
        let provider = RecordingEmbeddingProvider()
        return Stack(database: database,
                     query: ThreadQueryServiceImpl(database: database, embeddingProvider: provider,
                                                   graphExtractor: KeywordGraphExtractionProvider()),
                     library: ThreadLibraryServiceImpl(database: database))
    }

    private func index(_ stack: Stack, id: String, texts: [String], metadata: Data) async throws {
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = id
        item.texts = texts
        item.metadata = metadata
        var request = Thread_V1_ThreadIndexRequest()
        request.ownerID = owner
        request.groupID = "reading"
        request.groupLabel = "Reading"
        request.items = [item]
        _ = try await stack.query.index(request: request, context: ctx)
    }

    /// `Index` returns before the detached put lands.
    private func waitFor(
        _ id: String, metadata: Data?, in database: Database, timeout: TimeInterval = 10
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let index = database.table?.index(for: id), index.metadata == metadata { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("document \(id) was not indexed with the expected metadata within \(timeout)s")
    }

    private func documents(_ stack: Stack, _ ids: [String]) async throws -> [Thread_V1_ThreadDocumentContent] {
        var request = Thread_V1_ThreadDocumentsRequest()
        request.ownerID = owner
        request.documentIds = ids
        return try await stack.library.documents(request: request, context: ctx).documents
    }

    // MARK: - Returned

    func testDocumentsAndTheExportReturnMetadataByteForByte() async throws {
        let stack = await makeStack()
        try await index(stack, id: "doc-stamped", texts: ["Summary: a card", "the page's words"], metadata: stamped)
        await waitFor("doc-stamped", metadata: stamped, in: stack.database)

        let fetched = try await documents(stack, ["doc-stamped"])
        XCTAssertEqual(fetched.first?.metadata, stamped)
        XCTAssertEqual(fetched.first?.texts, ["Summary: a card", "the page's words"])

        var export = Thread_V1_ThreadExportCorpusRequest()
        export.ownerID = owner
        export.groupIds = ["reading"]
        let corpus = try await stack.library.exportCorpus(request: export, context: ctx)
        XCTAssertEqual(corpus.documents.first?.metadata, stamped, "a training export carries the record")
        await stack.database.shutdown()
    }

    func testADocumentWithoutMetadataComesBackWithNone() async throws {
        let stack = await makeStack()
        try await index(stack, id: "doc-bare", texts: ["no record here"], metadata: Data())
        await waitFor("doc-bare", metadata: nil, in: stack.database)
        let fetched = try await documents(stack, ["doc-bare"])
        XCTAssertEqual(fetched.first?.metadata, Data())
        await stack.database.shutdown()
    }

    func testAFilingAgainReturnsTheNewestMetadata() async throws {
        let stack = await makeStack()
        try await index(stack, id: "doc-again", texts: ["first words"], metadata: Data(#"{"kind":"reading"}"#.utf8))
        await waitFor("doc-again", metadata: Data(#"{"kind":"reading"}"#.utf8), in: stack.database)
        try await index(stack, id: "doc-again", texts: ["newer words"], metadata: stamped)
        await waitFor("doc-again", metadata: stamped, in: stack.database)
        let fetched = try await documents(stack, ["doc-again"])
        XCTAssertEqual(fetched.first?.metadata, stamped)
        await stack.database.shutdown()
    }

    func testMetadataSurvivesARestart() async throws {
        let first = await makeStack()
        try await index(first, id: "doc-kept", texts: ["kept across a restart"], metadata: stamped)
        await waitFor("doc-kept", metadata: stamped, in: first.database)
        await first.database.shutdown()

        let second = await makeStack()
        let fetched = try await documents(second, ["doc-kept"])
        XCTAssertEqual(fetched.first?.metadata, stamped)
        await second.database.shutdown()
    }
}
