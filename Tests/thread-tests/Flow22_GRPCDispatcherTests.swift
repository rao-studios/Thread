//
//  Flow22_GRPCDispatcherTests.swift
//  thread-tests
//
//  Tests for MothershipRequestDispatcher.handle(_:) — the session-stream router
//  that maps incoming ThreadSessionMessage payloads to the correct service impl.
//
//  No network or running gRPC server is needed: the dispatcher wraps the
//  service impls directly and the ServerContext is constructed with dummy values.
//

import XCTest
import Conduit
@testable import thread

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class Flow22_GRPCDispatcherTests: XCTestCase {

    // MARK: - Setup

    override func setUp() async throws {
        wipeThreadPersistenceFiles()
    }

    override func tearDown() async throws {
        wipeThreadPersistenceFiles()
    }

    // MARK: - Helpers

    private func makeDatabase() async -> Database {
        wipeThreadPersistenceFiles()
        let database = Database()
        await database.initializationTask.value
        return database
    }

    private func makeDispatcher(database: Database) -> MothershipRequestDispatcher {
        MothershipRequestDispatcher(
            database: database,
            embeddingProvider: MockEmbeddingProvider(),
            graphExtractor: KeywordGraphExtractionProvider(),
            logger: .test
        )
    }

    private func makeMsg(
        _ payload: Thread_V1_ThreadSessionMessage.OneOf_Payload,
        correlationId: String = "corr-1"
    ) -> Thread_V1_ThreadSessionMessage {
        var msg = Thread_V1_ThreadSessionMessage()
        msg.correlationID = correlationId
        msg.payload = payload
        return msg
    }

    /// Index responses return before the detached enrichment task enqueues the put.
    /// Poll until the document is visible in the table (or fail after `timeout`).
    private func waitForIndexed(_ documentId: String, in db: Database,
                                timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if db.table?.keys.contains(documentId) == true { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Document \(documentId) was not indexed within \(timeout)s")
    }

    // MARK: - Routing & correlation

    func testUnhandledPayloadReturnsNil() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        let ping = Thread_V1_ThreadSessionPing()
        let msg = makeMsg(.ping(ping))
        let response = await dispatcher.handle(msg)
        XCTAssertNil(response)
    }

    func testCorrelationIdIsPreserved() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Thread_V1_ThreadGraphQueryRequest()
        req.ownerID = "owner-corr"
        req.entity = "anything"
        let response = await dispatcher.handle(makeMsg(.graphRequest(req), correlationId: "abc-123"))
        XCTAssertEqual(response?.correlationID, "abc-123")
    }

    // MARK: - Search

    func testSearchRequestRoutesToSearchResponse() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Thread_V1_ThreadSearchRequest()
        req.ownerID = "alice"
        req.queryText = "test query"
        req.scope = "personal"
        req.topK = 3

        let response = await dispatcher.handle(makeMsg(.searchRequest(req)))
        XCTAssertNotNil(response)
        if case .searchResponse(let r) = response?.payload {
            XCTAssertTrue(r.results.count >= 0)
        } else {
            XCTFail("Expected .searchResponse, got \(String(describing: response?.payload))")
        }
    }

    func testSearchOnEmptyIndexReturnsEmptyResults() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Thread_V1_ThreadSearchRequest()
        req.ownerID = "nobody"
        req.queryText = "anything"
        req.scope = "personal"
        req.topK = 5

        let response = await dispatcher.handle(makeMsg(.searchRequest(req)))
        if case .searchResponse(let r) = response?.payload {
            XCTAssertEqual(r.results.count, 0)
        } else {
            XCTFail("Expected .searchResponse")
        }
    }

    // MARK: - Index

    func testIndexRequestRoutesToIndexResponse() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var item1 = Thread_V1_ThreadIndexItem()
        item1.documentID = "doc-a"
        item1.texts = ["Hello world"]

        var item2 = Thread_V1_ThreadIndexItem()
        item2.documentID = "doc-b"
        item2.texts = ["Swift actors are great"]

        var req = Thread_V1_ThreadIndexRequest()
        req.ownerID = "alice"
        req.groupID = "grp1"
        req.scope = "personal"
        req.items = [item1, item2]

        let response = await dispatcher.handle(makeMsg(.indexRequest(req)))
        XCTAssertNotNil(response)
        if case .indexResponse(let r) = response?.payload {
            XCTAssertEqual(r.indexedCount, 2)
        } else {
            XCTFail("Expected .indexResponse, got \(String(describing: response?.payload))")
        }
        // Let the detached enrichment finish so teardown doesn't race the put.
        await waitForIndexed("doc-a", in: db)
        await waitForIndexed("doc-b", in: db)
    }

    func testIndexRequestWithEmptyItemsSucceeds() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Thread_V1_ThreadIndexRequest()
        req.ownerID = "alice"
        req.items = []

        let response = await dispatcher.handle(makeMsg(.indexRequest(req)))
        if case .indexResponse(let r) = response?.payload {
            XCTAssertEqual(r.indexedCount, 0)
        } else {
            XCTFail("Expected .indexResponse")
        }
    }

    // MARK: - Remove

    func testRemoveRequestRoutesToRemoveResponse() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Thread_V1_ThreadRemoveRequest()
        req.ownerID = "alice"
        req.documentIds = ["nonexistent-doc"]

        let response = await dispatcher.handle(makeMsg(.removeRequest(req)))
        XCTAssertNotNil(response)
        if case .removeResponse = response?.payload {
            // success — remove of an unknown doc is a no-op, not an error
        } else {
            XCTFail("Expected .removeResponse, got \(String(describing: response?.payload))")
        }
    }

    // MARK: - Library

    func testLibraryRequestRoutesToLibraryResponse() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Thread_V1_ThreadLibraryRequest()
        req.ownerID = "unknown-owner"
        req.includeAvailable = false
        req.limit = 20

        let response = await dispatcher.handle(makeMsg(.libraryRequest(req)))
        XCTAssertNotNil(response)
        if case .libraryResponse(let r) = response?.payload {
            XCTAssertTrue(r.groups.isEmpty)
            XCTAssertFalse(r.hasMore_p)
        } else {
            XCTFail("Expected .libraryResponse, got \(String(describing: response?.payload))")
        }
    }

    // MARK: - Graph

    func testGraphRequestOnEmptyGraphReturnsEmptyResponse() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Thread_V1_ThreadGraphQueryRequest()
        req.ownerID = "alice"
        req.entity = "anything"
        req.hops = 1

        let response = await dispatcher.handle(makeMsg(.graphRequest(req)))
        XCTAssertNotNil(response)
        if case .graphResponse(let r) = response?.payload {
            XCTAssertTrue(r.entities.isEmpty)
            XCTAssertTrue(r.relationships.isEmpty)
        } else {
            XCTFail("Expected .graphResponse, got \(String(describing: response?.payload))")
        }
    }

    func testGraphRequestResolvesIndexedEntities() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        // Index a document with an explicit entity + relationship payload.
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = "graph-doc"
        item.texts = ["Ada Lovelace worked with Charles Babbage on the analytical engine."]
        var ada = Thread_V1_ThreadGraphEntityIn()
        ada.name = "Ada Lovelace"; ada.kind = "person"
        var babbage = Thread_V1_ThreadGraphEntityIn()
        babbage.name = "Charles Babbage"; babbage.kind = "person"
        item.entities = [ada, babbage]
        var rel = Thread_V1_ThreadGraphRelationIn()
        rel.subject = "Ada Lovelace"; rel.predicate = "worked with"; rel.object = "Charles Babbage"
        item.relationships = [rel]

        var indexReq = Thread_V1_ThreadIndexRequest()
        indexReq.ownerID = "graph-owner"
        indexReq.scope = "personal"
        indexReq.items = [item]

        _ = await dispatcher.handle(makeMsg(.indexRequest(indexReq)))
        await waitForIndexed("graph-doc", in: db)

        var req = Thread_V1_ThreadGraphQueryRequest()
        req.ownerID = "graph-owner"
        req.entity = "Ada Lovelace"
        req.hops = 1
        req.includeDocuments = true

        let response = await dispatcher.handle(makeMsg(.graphRequest(req)))
        if case .graphResponse(let r) = response?.payload {
            XCTAssertTrue(r.entities.contains { $0.name == "Ada Lovelace" },
                "Graph query must resolve the indexed entity by name")
            XCTAssertTrue(r.entities.contains { $0.name == "Charles Babbage" },
                "One-hop traversal must reach the related entity")
            XCTAssertTrue(r.relationships.contains { $0.predicate == "worked with" },
                "The traversed relationship must be returned")
            XCTAssertEqual(r.stats.entityCount, 2)
        } else {
            XCTFail("Expected .graphResponse, got \(String(describing: response?.payload))")
        }
    }

    // MARK: - End-to-end: index then search via dispatcher

    func testIndexThenSearchViaDispatcher() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        // Index a document via the session stream
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = "e2e-doc"
        item.texts = ["Swift structured concurrency uses tasks and actors."]

        var indexReq = Thread_V1_ThreadIndexRequest()
        indexReq.ownerID = "e2e-owner"
        indexReq.groupID = "e2e-group"
        indexReq.scope = "personal"
        indexReq.items = [item]

        let indexResp = await dispatcher.handle(makeMsg(.indexRequest(indexReq)))
        if case .indexResponse(let r) = indexResp?.payload {
            XCTAssertEqual(r.indexedCount, 1)
        } else {
            XCTFail("Index failed: \(String(describing: indexResp?.payload))")
            return
        }

        // The index response returns before the detached enrichment enqueues the put —
        // wait until the document is actually searchable.
        await waitForIndexed("e2e-doc", in: db)

        // Search for the indexed content
        var searchReq = Thread_V1_ThreadSearchRequest()
        searchReq.ownerID = "e2e-owner"
        searchReq.queryText = "Swift concurrency"
        searchReq.scope = "personal"
        searchReq.topK = 3

        let searchResp = await dispatcher.handle(makeMsg(.searchRequest(searchReq)))
        if case .searchResponse(let r) = searchResp?.payload {
            XCTAssertFalse(r.results.isEmpty, "Expected at least one result after indexing")
            XCTAssertFalse(r.results.first?.text.isEmpty ?? true)
        } else {
            XCTFail("Search failed: \(String(describing: searchResp?.payload))")
        }
    }
}
