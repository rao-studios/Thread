//
//  Flow23_CallerDescribedPartitionsTests.swift
//  thread-tests
//
//  A caller may describe the partitions of a document itself through
//  `ThreadIndexItem.partitions`: a supplied embedding is used as-is and kept in
//  `-parts`, a supplied url replaces the document's, and both come back through
//  `Documents` / `ExportCorpus` with `include_embeddings`. Nothing here is about
//  images — the same holds for any medium — and a document indexed without
//  `partitions` must be exactly what it was before.
//

import XCTest
import Conduit
import GRPCCore
import Logging
@testable import thread

/// Records every text it is asked to embed.
actor RecordingEmbeddingProvider: EmbeddingProviding {
    private(set) var embedded: [String] = []

    func acquirePreprocessSlot() async {}
    func releasePreprocessSlot() async {}

    func run(_ texts: [String], logger: Logger, priority: Bool)
        async throws -> (result: [EmbeddingData], usage: Requests.Embedding.Get.Result.Usage) {
        embedded += texts
        let result = texts.enumerated().map { i, text in
            EmbeddingData(embedding: .floats(Self.vector(for: text)), index: i)
        }
        let usage = Requests.Embedding.Get.Result.Usage(promptAudioSeconds: nil, promptTokens: texts.count,
                                                        totalTokens: texts.count, completionTokens: 0,
                                                        requestCount: nil, promptTokenDetails: nil)
        return (result, usage)
    }

    static func vector(for text: String, dim: Int = VectorFixtures.embeddingDim) -> [Float] {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return VectorFixtures.random(dim: dim, seed: hash)
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class Flow23_CallerDescribedPartitionsTests: XCTestCase {

    private var tempRoot: URL!
    private let owner = "partition-owner"
    private let dim = VectorFixtures.embeddingDim
    private let ctx = GRPCCore.ServerContext(
        descriptor: .init(service: .init(fullyQualifiedService: "test"), method: "test"),
        remotePeer: "test", localPeer: "local", cancellation: .init()
    )

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-described-\(UUID().uuidString)")
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
        let provider: RecordingEmbeddingProvider
        let query: ThreadQueryServiceImpl
        let library: ThreadLibraryServiceImpl
    }

    private func makeStack() async -> Stack {
        let database = Database(nodeId: UUID(uuidString: "00000000-0000-0000-0000-00000000f23d")!)
        await database.initializationTask.value
        let provider = RecordingEmbeddingProvider()
        return Stack(database: database, provider: provider,
                     query: ThreadQueryServiceImpl(database: database, embeddingProvider: provider,
                                                   graphExtractor: KeywordGraphExtractionProvider()),
                     library: ThreadLibraryServiceImpl(database: database))
    }

    /// `Index` returns before the detached put lands.
    private func waitForIndexed(_ id: String, in database: Database, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if database.table?.keys.contains(id) == true { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("document \(id) was not indexed within \(timeout)s")
    }

    private func vector(_ seed: UInt64, dim: Int? = nil) -> [Float] {
        VectorFixtures.random(dim: dim ?? self.dim, seed: 50_000 &+ seed)
    }

    private func described(_ embedding: [Float], url: String = "") -> Thread_V1_ThreadPartitionInput {
        var p = Thread_V1_ThreadPartitionInput()
        p.embedding = embedding
        p.url = url
        return p
    }

    private func indexRequest(_ item: Thread_V1_ThreadIndexItem, group: String = "identity") -> Thread_V1_ThreadIndexRequest {
        var r = Thread_V1_ThreadIndexRequest()
        r.ownerID = owner
        r.groupID = group
        r.groupLabel = "Identity"
        r.items = [item]
        return r
    }

    private func documents(_ stack: Stack, _ ids: [String], embeddings: Bool) async throws -> [Thread_V1_ThreadDocumentContent] {
        var r = Thread_V1_ThreadDocumentsRequest()
        r.ownerID = owner
        r.documentIds = ids
        r.includeEmbeddings = embeddings
        return try await stack.library.documents(request: r, context: ctx).documents
    }

    // MARK: - Supplied partitions

    func testSuppliedEmbeddingsAreStoredAndReadBackExactly() async throws {
        let stack = await makeStack()
        let vectors = (0..<4).map { vector(UInt64($0)) }
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = "img-1"
        item.name = "img-1.png"
        item.mediaType = "image"
        item.texts = ["a caption", "", "", ""]
        item.partitions = [described(vectors[0])] + (1..<4).map {
            described(vectors[$0], url: "file:///data/img-1#xywh=pixel:\(($0 - 1) * 32),0,32,32")
        }
        _ = try await stack.query.index(request: indexRequest(item), context: ctx)
        await waitForIndexed("img-1", in: stack.database)

        let sent = await stack.provider.embedded
        XCTAssertTrue(sent.isEmpty, "every partition brought its own vector — nothing was embedded")
        XCTAssertEqual(stack.database.table?.indices["img-1"]?.slots.count, 4)

        let docDocs = try await documents(stack, ["img-1"], embeddings: true)
        let doc = try XCTUnwrap(docDocs.first)
        XCTAssertEqual(doc.texts, ["a caption", "", "", ""])
        XCTAssertEqual(doc.mediaType, "image")
        XCTAssertEqual(doc.partitions.count, 4, "one entry per partition, in the order of texts")
        for (i, partition) in doc.partitions.enumerated() {
            XCTAssertEqual(partition.embedding, vectors[i], "partition \(i) comes back bit-exact")
        }
        XCTAssertEqual(doc.partitions[0].url, stack.database.documentStore(for: "img-1").url.absoluteString,
                       "no url supplied → the document's own")
        XCTAssertEqual(doc.partitions[2].url, "file:///data/img-1#xywh=pixel:32,0,32,32",
                       "a supplied url is the partition's address")

        // Without the flag the response is what it always was.
        let plainDocs = try await documents(stack, ["img-1"], embeddings: false)
        let plain = try XCTUnwrap(plainDocs.first)
        XCTAssertTrue(plain.partitions.isEmpty)
        XCTAssertEqual(plain.texts, ["a caption", "", "", ""])
        await stack.database.shutdown()
    }

    func testOnlyTextsWithoutAVectorAreEmbedded() async throws {
        let stack = await makeStack()
        let tile = vector(9)
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = "img-2"
        item.texts = ["let Thread embed this caption", ""]
        item.partitions = [described([]), described(tile, url: "file:///data/img-2#xywh=pixel:0,0,32,32")]
        _ = try await stack.query.index(request: indexRequest(item), context: ctx)
        await waitForIndexed("img-2", in: stack.database)

        let sent = await stack.provider.embedded
        XCTAssertEqual(sent, ["let Thread embed this caption"])

        let docDocs = try await documents(stack, ["img-2"], embeddings: true)
        let doc = try XCTUnwrap(docDocs.first)
        XCTAssertTrue(doc.partitions[0].embedding.isEmpty, "Thread embedded it, so it was not kept")
        XCTAssertEqual(doc.partitions[1].embedding, tile)
        await stack.database.shutdown()
    }

    func testExportCorpusCarriesPartitionsWhenAsked() async throws {
        let stack = await makeStack()
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = "img-3"
        item.texts = ["caption", ""]
        item.partitions = [described(vector(1)), described(vector(2), url: "file:///x#xywh=pixel:0,0,32,32")]
        _ = try await stack.query.index(request: indexRequest(item), context: ctx)
        await waitForIndexed("img-3", in: stack.database)

        var r = Thread_V1_ThreadExportCorpusRequest()
        r.ownerID = owner
        r.groupIds = ["identity"]
        r.includeEmbeddings = true
        let corpus = try await stack.library.exportCorpus(request: r, context: ctx)
        XCTAssertEqual(corpus.documents.first?.partitions.map(\.embedding), [vector(1), vector(2)])
        await stack.database.shutdown()
    }

    // MARK: - Validation

    func testMalformedPartitionsAreRejected() async throws {
        let stack = await makeStack()
        func expectInvalid(_ item: Thread_V1_ThreadIndexItem, _ why: String) async {
            do {
                _ = try await stack.query.index(request: indexRequest(item), context: ctx)
                XCTFail("expected invalidArgument: \(why)")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .invalidArgument, why)
            } catch {
                XCTFail("unexpected \(error)")
            }
        }

        var count = Thread_V1_ThreadIndexItem()
        count.documentID = "bad-count"
        count.texts = ["a", "b"]
        count.partitions = [described(vector(1))]
        await expectInvalid(count, "fewer partitions than texts")

        var mixed = Thread_V1_ThreadIndexItem()
        mixed.documentID = "bad-dims"
        mixed.texts = ["", ""]
        mixed.partitions = [described(vector(1)), described(vector(2, dim: 512))]
        await expectInvalid(mixed, "partitions disagree on dimensionality")

        var odd = Thread_V1_ThreadIndexItem()
        odd.documentID = "bad-width"
        odd.texts = [""]
        odd.partitions = [described(vector(1, dim: 1000))]
        await expectInvalid(odd, "1000 is not a multiple of 16")

        XCTAssertTrue(stack.database.table?.keys.isEmpty ?? true, "nothing was written")
        await stack.database.shutdown()
    }

    // MARK: - Nothing changes for callers that do not describe partitions

    func testAnItemWithoutPartitionsIsIndexedExactlyAsBefore() async throws {
        let stack = await makeStack()
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = "doc-text"
        item.texts = ["first passage", "second passage"]
        _ = try await stack.query.index(request: indexRequest(item), context: ctx)
        await waitForIndexed("doc-text", in: stack.database)

        let sent = await stack.provider.embedded
        XCTAssertEqual(sent, ["first passage", "second passage"])

        let parts = try XCTUnwrap(stack.database.partitionDatas(for: "doc-text"))
        let documentURL = stack.database.documentStore(for: "doc-text").url
        XCTAssertEqual(parts.map(\.url), [documentURL, documentURL])
        XCTAssertEqual(parts.map(\.embedding), [nil, nil], "nothing is kept for a Thread-embedded partition")
        XCTAssertEqual(parts.map(\.id), [
            stack.database.computeNumericHash(from: RecordingEmbeddingProvider.vector(for: "first passage"), documentId: "doc-text"),
            stack.database.computeNumericHash(from: RecordingEmbeddingProvider.vector(for: "second passage"), documentId: "doc-text"),
        ], "ids are the same hash of (vector, document id) they always were")

        let docDocs = try await documents(stack, ["doc-text"], embeddings: true)
        let doc = try XCTUnwrap(docDocs.first)
        XCTAssertEqual(doc.partitions.map(\.embedding), [[], []])
        await stack.database.shutdown()
    }

    func testPartsWrittenBeforeKeptEmbeddingsStillDecode() throws {
        // A `-parts` record from before `embedding` existed.
        let legacy: [String: Any] = ["id": "p", "url": ["relative": "file:///d"], "media_type": "text", "data": "hello", "ownerId": "o"]
        let data = try PropertyListSerialization.data(fromPropertyList: [legacy], format: .binary, options: 0)
        let decoded = try PropertyListDecoder().decode([PartitionData].self, from: data)
        XCTAssertEqual(decoded.first?.data, "hello")
        XCTAssertNil(decoded.first?.embedding)
        XCTAssertNil(decoded.first?.embeddingFloats)
    }

    // MARK: - Mixed dimensionality in one table

    func testATextSearchSkipsADocumentStoredAtAnotherDimensionality() async throws {
        let stack = await makeStack()
        // A text document embedded by this node (1024-d) …
        var text = Thread_V1_ThreadIndexItem()
        text.documentID = "doc-1024"
        text.texts = ["a dragon over a castle"]
        _ = try await stack.query.index(request: indexRequest(text), context: ctx)
        // … and a caller-described one at 512-d, which a 1024-d query cannot be compared with.
        var other = Thread_V1_ThreadIndexItem()
        other.documentID = "doc-512"
        other.texts = [""]
        other.partitions = [described(vector(3, dim: 512))]
        _ = try await stack.query.index(request: indexRequest(other), context: ctx)
        await waitForIndexed("doc-1024", in: stack.database)
        await waitForIndexed("doc-512", in: stack.database)

        var search = Thread_V1_ThreadSearchRequest()
        search.ownerID = owner
        search.queryText = "a dragon over a castle"
        search.groupIds = ["identity"]
        let results = try await stack.query.search(request: search, context: ctx).results
        XCTAssertEqual(Set(results.map(\.documentID)), ["doc-1024"],
                       "the 512-d document is not comparable, so it scores nothing rather than reading past its codebook")
        await stack.database.shutdown()
    }

    // MARK: - ThreadUpdate is served directly

    func testUpdateServiceConformsForDirectServing() async throws {
        let stack = await makeStack()
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = "doc-a"
        item.texts = ["hello"]
        _ = try await stack.query.index(request: indexRequest(item), context: ctx)
        await waitForIndexed("doc-a", in: stack.database)

        // Registered on the direct port through this conformance.
        let update: any Thread_V1_ThreadUpdate.SimpleServiceProtocol = ThreadUpdateServiceImpl(database: stack.database)
        var rename = Thread_V1_ThreadUpdateGroupRequest()
        rename.ownerID = owner
        rename.groupID = "identity"
        rename.label = "Renamed"
        let response = try await update.updateGroup(request: rename, context: ctx)
        XCTAssertTrue(response.success)
        XCTAssertEqual(stack.database.groups(for: owner).first?.label, "Renamed")
        await stack.database.shutdown()
    }
}
