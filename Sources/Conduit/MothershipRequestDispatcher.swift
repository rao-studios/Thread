import Conduit
import Foundation
import GRPCCore
import Logging

// SessionRequestHandling lets Conduit's MothershipRegistrationClient route
// incoming session requests here; handle(_:) below is the witness.
final class MothershipRequestDispatcher: SessionRequestHandling, Sendable {
    private let queryImpl: TotemQueryServiceImpl
    private let libraryImpl: TotemLibraryServiceImpl
    private let hnswImpl: TotemHNSWServiceImpl
    private let updateImpl: TotemUpdateServiceImpl
    private let logger: Logger

    init(database: Database, embeddingProvider: any EmbeddingProviding, logger: Logger) {
        queryImpl   = TotemQueryServiceImpl(database: database, embeddingProvider: embeddingProvider)
        libraryImpl = TotemLibraryServiceImpl(database: database)
        hnswImpl    = TotemHNSWServiceImpl(database: database)
        updateImpl  = TotemUpdateServiceImpl(database: database)
        self.logger = logger
    }

    func handle(_ msg: Totem_V1_TotemSessionMessage) async -> Totem_V1_TotemSessionMessage? {
        var response = Totem_V1_TotemSessionMessage()
        response.correlationID = msg.correlationID

        // Dummy context — none of the service impls use ServerContext fields.
        let ctx = GRPCCore.ServerContext(
            descriptor: .init(service: .init(fullyQualifiedService: "dispatch"), method: "dispatch"),
            remotePeer: "session",
            localPeer: "local",
            cancellation: .init()
        )

        let tag = "\(msg.correlationID.prefix(8))"

        switch msg.payload {
        case .searchRequest(let req):
            logger.info("MothershipRequestDispatcher: [\(tag)] searchRequest — dispatching")
            guard let r = try? await queryImpl.search(request: req, context: ctx) else {
                logger.warning("MothershipRequestDispatcher: [\(tag)] searchRequest — dispatch failed")
                return nil
            }
            logger.info("MothershipRequestDispatcher: [\(tag)] searchRequest — done, \(r.results.count) result(s)")
            response.payload = .searchResponse(r)

        case .indexRequest(let req):
            logger.info("MothershipRequestDispatcher: [\(tag)] indexRequest — dispatching \(req.items.count) item(s)")
            do {
                let r = try await queryImpl.index(request: req, context: ctx)
                logger.info("MothershipRequestDispatcher: [\(tag)] indexRequest — done, indexed \(r.indexedCount)")
                response.payload = .indexResponse(r)
            } catch EmbeddingBackpressureError.normalWaiterQueueFull {
                // Embedding queue is saturated — signal backpressure to Seer so it can
                // retry. Always return a response so Seer's continuation resolves and
                // the drain loop does not freeze.
                logger.warning("MothershipRequestDispatcher: [\(tag)] indexRequest — embedding queue full, signalling backpressure")
                var failResp = Totem_V1_TotemIndexResponse()
                failResp.success = false
                failResp.indexedCount = 0
                response.payload = .indexResponse(failResp)
            } catch {
                // Unexpected error — still return a failure response so Seer's
                // continuation always resolves. Returning nil would leave Seer's
                // write queue frozen until the session drops.
                logger.warning("MothershipRequestDispatcher: [\(tag)] indexRequest — dispatch failed: \(error)")
                var failResp = Totem_V1_TotemIndexResponse()
                failResp.success = false
                failResp.indexedCount = 0
                response.payload = .indexResponse(failResp)
            }

        case .removeRequest(let req):
            logger.info("MothershipRequestDispatcher: [\(tag)] removeRequest — dispatching")
            guard let r = try? await queryImpl.remove(request: req, context: ctx) else {
                logger.warning("MothershipRequestDispatcher: [\(tag)] removeRequest — dispatch failed")
                return nil
            }
            logger.info("MothershipRequestDispatcher: [\(tag)] removeRequest — done, removed \(r.removedCount)")
            response.payload = .removeResponse(r)

        case .libraryRequest(let req):
            logger.info("MothershipRequestDispatcher: [\(tag)] libraryRequest — dispatching for owner \(req.ownerID)")
            guard let r = try? await libraryImpl.library(request: req, context: ctx) else {
                logger.warning("MothershipRequestDispatcher: [\(tag)] libraryRequest — dispatch failed")
                return nil
            }
            logger.info("MothershipRequestDispatcher: [\(tag)] libraryRequest — done, \(r.groups.count) group(s)")
            response.payload = .libraryResponse(r)

        case .hnswStatsRequest(let req):
            logger.info("MothershipRequestDispatcher: [\(tag)] hnswStatsRequest — dispatching")
            guard let r = try? await hnswImpl.stats(request: req, context: ctx) else {
                logger.warning("MothershipRequestDispatcher: [\(tag)] hnswStatsRequest — dispatch failed")
                return nil
            }
            logger.info("MothershipRequestDispatcher: [\(tag)] hnswStatsRequest — done")
            response.payload = .hnswStatsResponse(r)

        case .hnswGraphRequest(let req):
            logger.info("MothershipRequestDispatcher: [\(tag)] hnswGraphRequest — dispatching")
            guard let r = try? await hnswImpl.graph(request: req, context: ctx) else {
                logger.warning("MothershipRequestDispatcher: [\(tag)] hnswGraphRequest — dispatch failed")
                return nil
            }
            logger.info("MothershipRequestDispatcher: [\(tag)] hnswGraphRequest — done, \(r.nodes.count) node(s)")
            response.payload = .hnswGraphResponse(r)

        case .hnswNodeBatchRequest(let req):
            logger.info("MothershipRequestDispatcher: [\(tag)] hnswNodeBatchRequest — dispatching \(req.partitionIds.count) id(s)")
            guard let r = try? await hnswImpl.nodeBatch(request: req, context: ctx) else {
                logger.warning("MothershipRequestDispatcher: [\(tag)] hnswNodeBatchRequest — dispatch failed")
                return nil
            }
            logger.info("MothershipRequestDispatcher: [\(tag)] hnswNodeBatchRequest — done, \(r.nodes.count) node(s)")
            response.payload = .hnswNodeBatchResponse(r)

        case .hnswNodeRequest(let req):
            logger.info("MothershipRequestDispatcher: [\(tag)] hnswNodeRequest — dispatching partition \(req.partitionID)")
            guard let r = try? await hnswImpl.node(request: req, context: ctx) else {
                logger.warning("MothershipRequestDispatcher: [\(tag)] hnswNodeRequest — dispatch failed (partition not found?)")
                return nil
            }
            logger.info("MothershipRequestDispatcher: [\(tag)] hnswNodeRequest — done")
            response.payload = .hnswNodeResponse(r)

        case .hnswDeleteNodeRequest(let req):
            logger.info("MothershipRequestDispatcher: [\(tag)] hnswDeleteNodeRequest — dispatching partition \(req.partitionID)")
            guard let r = try? await hnswImpl.deleteNode(request: req, context: ctx) else {
                logger.warning("MothershipRequestDispatcher: [\(tag)] hnswDeleteNodeRequest — dispatch failed")
                return nil
            }
            logger.info("MothershipRequestDispatcher: [\(tag)] hnswDeleteNodeRequest — done, removed=\(r.removed)")
            response.payload = .hnswDeleteNodeResponse(r)

        case .updateGroupRequest(let req):
            logger.info("MothershipRequestDispatcher: [\(tag)] updateGroupRequest — group \(req.groupID)")
            guard let r = try? await updateImpl.updateGroup(request: req, context: ctx) else {
                logger.warning("MothershipRequestDispatcher: [\(tag)] updateGroupRequest — dispatch failed")
                return nil
            }
            logger.info("MothershipRequestDispatcher: [\(tag)] updateGroupRequest — done, success=\(r.success)")
            response.payload = .updateGroupResponse(r)

        case .updateDocumentRequest(let req):
            logger.info("MothershipRequestDispatcher: [\(tag)] updateDocumentRequest — doc \(req.documentID)")
            guard let r = try? await updateImpl.updateDocument(request: req, context: ctx) else {
                logger.warning("MothershipRequestDispatcher: [\(tag)] updateDocumentRequest — dispatch failed")
                return nil
            }
            logger.info("MothershipRequestDispatcher: [\(tag)] updateDocumentRequest — done, success=\(r.success)")
            response.payload = .updateDocumentResponse(r)

        case .statsRequest(let req):
            logger.info("MothershipRequestDispatcher: [\(tag)] statsRequest — fetching registry stats")
            guard let r = try? await updateImpl.stats(request: req, context: ctx) else {
                logger.warning("MothershipRequestDispatcher: [\(tag)] statsRequest — dispatch failed")
                return nil
            }
            logger.info("MothershipRequestDispatcher: [\(tag)] statsRequest — docs=\(r.documentCount) groups=\(r.groupCount)")
            response.payload = .statsResponse(r)

        default:
            logger.warning("MothershipRequestDispatcher: [\(tag)] unhandled payload type — ignoring")
            return nil
        }

        return response
    }
}
