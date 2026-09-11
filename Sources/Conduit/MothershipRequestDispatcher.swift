import Conduit
import Foundation
import GRPCCore
import Logging

// SessionRequestHandling lets Conduit's MothershipRegistrationClient route
// incoming session requests here; handle(_:) below is the witness.
final class MothershipRequestDispatcher: SessionRequestHandling, Sendable {
    private let queryImpl: ThreadQueryServiceImpl
    private let libraryImpl: ThreadLibraryServiceImpl
    private let graphImpl: ThreadGraphServiceImpl
    private let updateImpl: ThreadUpdateServiceImpl
    private let logger: Logger

    init(database: Database, embeddingProvider: any EmbeddingProviding,
         graphExtractor: any GraphExtracting, logger: Logger) {
        queryImpl   = ThreadQueryServiceImpl(database: database, embeddingProvider: embeddingProvider,
                                            graphExtractor: graphExtractor)
        libraryImpl = ThreadLibraryServiceImpl(database: database)
        graphImpl   = ThreadGraphServiceImpl(database: database, embeddingProvider: embeddingProvider)
        updateImpl  = ThreadUpdateServiceImpl(database: database)
        self.logger = logger
    }

    func handle(_ msg: Thread_V1_ThreadSessionMessage) async -> Thread_V1_ThreadSessionMessage? {
        var response = Thread_V1_ThreadSessionMessage()
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
                // Embedding queue is saturated — signal backpressure to Sewn so it can
                // retry. Always return a response so Sewn's continuation resolves and
                // the drain loop does not freeze.
                logger.warning("MothershipRequestDispatcher: [\(tag)] indexRequest — embedding queue full, signalling backpressure")
                var failResp = Thread_V1_ThreadIndexResponse()
                failResp.success = false
                failResp.indexedCount = 0
                response.payload = .indexResponse(failResp)
            } catch {
                // Unexpected error — still return a failure response so Sewn's
                // continuation always resolves. Returning nil would leave Sewn's
                // write queue frozen until the session drops.
                logger.warning("MothershipRequestDispatcher: [\(tag)] indexRequest — dispatch failed: \(error)")
                var failResp = Thread_V1_ThreadIndexResponse()
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

        case .documentsRequest(let req):
            logger.info("MothershipRequestDispatcher: [\(tag)] documentsRequest — \(req.documentIds.count) id(s) for owner \(req.ownerID)")
            guard let r = try? await libraryImpl.documents(request: req, context: ctx) else {
                logger.warning("MothershipRequestDispatcher: [\(tag)] documentsRequest — dispatch failed")
                return nil
            }
            logger.info("MothershipRequestDispatcher: [\(tag)] documentsRequest — done, \(r.documents.count) document(s)")
            response.payload = .documentsResponse(r)

        case .graphRequest(let req):
            logger.info("MothershipRequestDispatcher: [\(tag)] graphRequest — dispatching")
            guard let r = try? await graphImpl.query(request: req, context: ctx) else {
                logger.warning("MothershipRequestDispatcher: [\(tag)] graphRequest — dispatch failed")
                return nil
            }
            logger.info("MothershipRequestDispatcher: [\(tag)] graphRequest — done, \(r.entities.count) entity(ies)")
            response.payload = .graphResponse(r)

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
