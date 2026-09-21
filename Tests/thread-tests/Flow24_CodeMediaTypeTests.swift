//
//  Flow24_CodeMediaTypeTests.swift
//  thread-tests
//
//  `media_type: "code"` is stored as `.code` and comes back as "code" from
//  `Documents`; it is embedded like text. Any other spelling a client sends
//  (a MIME type such as `text/x-swift`, or nothing) is text, as before.
//

import XCTest
import Conduit
import GRPCCore
import Logging
@testable import thread

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class Flow24_CodeMediaTypeTests: XCTestCase {

    private var tempRoot: URL!
    private let owner = "code-owner"
    private let ctx = GRPCCore.ServerContext(
        descriptor: .init(service: .init(fullyQualifiedService: "test"), method: "test"),
        remotePeer: "test", localPeer: "local", cancellation: .init()
    )

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-code-\(UUID().uuidString)")
        FilePersistence.configure(dataDirectory: tempRoot.path)
    }

    override func tearDown() {
        FilePersistence.configure(dataDirectory: nil)
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func waitForIndexed(_ id: String, in database: Database, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if database.table?.keys.contains(id) == true { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("document \(id) was not indexed within \(timeout)s")
    }

    private func index(_ id: String, mediaType: String, texts: [String],
                       query: ThreadQueryServiceImpl, database: Database) async throws {
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = id
        item.mediaType = mediaType
        item.texts = texts
        var request = Thread_V1_ThreadIndexRequest()
        request.ownerID = owner
        request.groupID = "craft-code-test"
        request.groupLabel = "Code"
        request.items = [item]
        _ = try await query.index(request: request, context: ctx)
        await waitForIndexed(id, in: database)
    }

    func testCodeIsStoredAsCodeAndEmbeddedLikeText() async throws {
        let database = Database(nodeId: UUID(uuidString: "00000000-0000-0000-0000-00000000f24c")!)
        await database.initializationTask.value
        let provider = RecordingEmbeddingProvider()
        let query = ThreadQueryServiceImpl(database: database, embeddingProvider: provider,
                                           graphExtractor: KeywordGraphExtractionProvider())
        let library = ThreadLibraryServiceImpl(database: database)

        let card = "// craft:fn Session.send(_:)\n// in class Session\npublic func send(_ input: String) {}"
        try await index("code-1", mediaType: "code", texts: [card], query: query, database: database)
        try await index("mime-1", mediaType: "text/x-swift", texts: ["let a = 1"], query: query, database: database)
        try await index("plain-1", mediaType: "", texts: ["prose"], query: query, database: database)

        let sent = await provider.embedded
        XCTAssertTrue(sent.contains(card), "code partitions go through the text embedder unchanged")

        XCTAssertEqual(database.partitionDatas(for: "code-1")?.map(\.mediaType), [.code])
        XCTAssertEqual(database.partitionDatas(for: "mime-1")?.map(\.mediaType), [.text])
        XCTAssertEqual(database.partitionDatas(for: "plain-1")?.map(\.mediaType), [.text])

        var request = Thread_V1_ThreadDocumentsRequest()
        request.ownerID = owner
        request.documentIds = ["code-1", "mime-1"]
        let documents = try await library.documents(request: request, context: ctx).documents
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.mediaType) })
        XCTAssertEqual(byID["code-1"], "code")
        XCTAssertEqual(byID["mime-1"], "text")
        await database.shutdown()
    }

    func testWireSpellings() {
        XCTAssertEqual(MediaType(wire: "code"), .code)
        XCTAssertEqual(MediaType(wire: "image"), .image)
        XCTAssertEqual(MediaType(wire: "text"), .text)
        XCTAssertEqual(MediaType(wire: "text/x-swift"), .text)
        XCTAssertEqual(MediaType(wire: ""), .text)
    }

    func testPartsWrittenBeforeCodeExistedStillDecode() throws {
        let legacy: [String: Any] = ["id": "p", "url": ["relative": "file:///d"], "media_type": "text", "data": "x", "ownerId": "o"]
        let data = try PropertyListSerialization.data(fromPropertyList: [legacy], format: .binary, options: 0)
        XCTAssertEqual(try PropertyListDecoder().decode([PartitionData].self, from: data).first?.mediaType, .text)
    }
}
