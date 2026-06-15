//
//  Flow22_GRPCDispatcherTests.swift
//  totem-tests
//
//  Tests for MothershipRequestDispatcher.handle(_:) — the session-stream router
//  that maps incoming TotemSessionMessage payloads to the correct service impl.
//
//  No network or running gRPC server is needed: the dispatcher wraps the three
//  service impls directly and the ServerContext is constructed with dummy values.
//

import XCTest
import Conduit
@testable import totem

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class Flow22_GRPCDispatcherTests: XCTestCase {

    // MARK: - Setup

    override func setUp() async throws {
        wipeTotemPersistenceFiles()
    }

    override func tearDown() async throws {
        wipeTotemPersistenceFiles()
    }

    // MARK: - Helpers

    private func makeDatabase() async -> Database {
        wipeTotemPersistenceFiles()
        let database = Database()
        await database.initializationTask.value
        return database
    }

    private func makeDispatcher(database: Database) -> MothershipRequestDispatcher {
        MothershipRequestDispatcher(
            database: database,
            embeddingProvider: MockEmbeddingProvider(),
            logger: .test
        )
    }

    private func makeMsg(
        _ payload: Totem_V1_TotemSessionMessage.OneOf_Payload,
        correlationId: String = "corr-1"
    ) -> Totem_V1_TotemSessionMessage {
        var msg = Totem_V1_TotemSessionMessage()
        msg.correlationID = correlationId
        msg.payload = payload
        return msg
    }

    // MARK: - Routing & correlation

    func testUnhandledPayloadReturnsNil() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var ping = Totem_V1_TotemSessionPing()
        let msg = makeMsg(.ping(ping))
        let response = await dispatcher.handle(msg)
        XCTAssertNil(response)
    }

    func testCorrelationIdIsPreserved() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Totem_V1_TotemHNSWStatsRequest()
        req.ownerID = "owner-corr"
        let response = await dispatcher.handle(makeMsg(.hnswStatsRequest(req), correlationId: "abc-123"))
        XCTAssertEqual(response?.correlationID, "abc-123")
    }

    // MARK: - Search

    func testSearchRequestRoutesToSearchResponse() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Totem_V1_TotemSearchRequest()
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

        var req = Totem_V1_TotemSearchRequest()
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

        var item1 = Totem_V1_TotemIndexItem()
        item1.documentID = "doc-a"
        item1.texts = ["Hello world"]

        var item2 = Totem_V1_TotemIndexItem()
        item2.documentID = "doc-b"
        item2.texts = ["Swift actors are great"]

        var req = Totem_V1_TotemIndexRequest()
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
    }

    func testIndexRequestWithEmptyItemsSucceeds() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Totem_V1_TotemIndexRequest()
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

        var req = Totem_V1_TotemRemoveRequest()
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

        var req = Totem_V1_TotemLibraryRequest()
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

    // MARK: - HNSW Stats

    func testHNSWStatsRequestRoutesToStatsResponse() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Totem_V1_TotemHNSWStatsRequest()
        req.ownerID = "alice"

        let response = await dispatcher.handle(makeMsg(.hnswStatsRequest(req)))
        XCTAssertNotNil(response)
        if case .hnswStatsResponse(let r) = response?.payload {
            XCTAssertEqual(r.personal.liveNodes, 0)
            XCTAssertEqual(r.global.liveNodes, 0)
        } else {
            XCTFail("Expected .hnswStatsResponse, got \(String(describing: response?.payload))")
        }
    }

    // MARK: - HNSW Graph

    func testHNSWGraphRequestRoutesToGraphResponse() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Totem_V1_TotemHNSWGraphRequest()
        req.ownerID = "alice"
        req.scope = "personal"
        req.shardIndex = -1

        let response = await dispatcher.handle(makeMsg(.hnswGraphRequest(req)))
        XCTAssertNotNil(response)
        if case .hnswGraphResponse(let r) = response?.payload {
            XCTAssertTrue(r.nodes.isEmpty)
        } else {
            XCTFail("Expected .hnswGraphResponse, got \(String(describing: response?.payload))")
        }
    }

    // MARK: - HNSW NodeBatch

    func testHNSWNodeBatchRequestRoutesToNodeBatchResponse() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Totem_V1_TotemHNSWNodeBatchRequest()
        req.partitionIds = ["unknown-partition-1", "unknown-partition-2"]

        let response = await dispatcher.handle(makeMsg(.hnswNodeBatchRequest(req)))
        XCTAssertNotNil(response)
        if case .hnswNodeBatchResponse(let r) = response?.payload {
            XCTAssertTrue(r.nodes.isEmpty)
        } else {
            XCTFail("Expected .hnswNodeBatchResponse, got \(String(describing: response?.payload))")
        }
    }

    // MARK: - HNSW Node (not found)

    func testHNSWNodeRequestForUnknownPartitionReturnsNil() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Totem_V1_TotemHNSWNodeRequest()
        req.partitionID = "does-not-exist"

        // Service throws .notFound; dispatcher catches and returns nil
        let response = await dispatcher.handle(makeMsg(.hnswNodeRequest(req)))
        XCTAssertNil(response)
    }

    // MARK: - HNSW DeleteNode

    func testHNSWDeleteNodeRequestRoutesToDeleteNodeResponse() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        var req = Totem_V1_TotemHNSWDeleteNodeRequest()
        req.ownerID = "alice"
        req.partitionID = "nonexistent-partition"

        let response = await dispatcher.handle(makeMsg(.hnswDeleteNodeRequest(req)))
        XCTAssertNotNil(response)
        if case .hnswDeleteNodeResponse(let r) = response?.payload {
            XCTAssertFalse(r.removed)
            XCTAssertTrue(r.documentID.isEmpty)
        } else {
            XCTFail("Expected .hnswDeleteNodeResponse, got \(String(describing: response?.payload))")
        }
    }

    // MARK: - End-to-end: index then search via dispatcher

    func testIndexThenSearchViaDispatcher() async {
        let db = await makeDatabase()
        let dispatcher = makeDispatcher(database: db)

        // Index a document via the session stream
        var item = Totem_V1_TotemIndexItem()
        item.documentID = "e2e-doc"
        item.texts = ["Swift structured concurrency uses tasks and actors."]

        var indexReq = Totem_V1_TotemIndexRequest()
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

        // Drain the async write queue: removeAll on an unknown owner awaits the
        // CheckedContinuation and only returns after all preceding puts have committed.
        _ = await db.removeAll(ownerId: "drain-barrier", request: .test())

        // Search for the indexed content
        var searchReq = Totem_V1_TotemSearchRequest()
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
