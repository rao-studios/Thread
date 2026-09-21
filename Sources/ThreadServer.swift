import ArgumentParser
import Conduit
import Foundation
import GRPCCore
import Logging
import Hummingbird
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension ThreadServer {
    /// The launcher's secret rides only to the loopback mothership the
    /// launcher started — never to a remote one, and never to Fleet.
    static func mothershipInterceptors(secret: String?, mothershipHost: String) -> [any ClientInterceptor] {
        guard let secret, !secret.isEmpty, StackSecret.isLoopback(authority: mothershipHost) else { return [] }
        return [StackSecretClientInterceptor(secret: secret)]
    }
}

func configureRoutes(
    _ router: Router<ThreadRequestContext>,
    _ database: Database,
    embeddingModelProvider: any EmbeddingProviding,
    graphExtractor: any GraphExtracting
) {
    registerHealthRoute(router)
    registerSearchRoute(router, database, embeddingModelProvider: embeddingModelProvider)
    registerBatchEmbeddingsRoute(router, database, embeddingModelProvider: embeddingModelProvider,
                                 graphExtractor: graphExtractor)
    registerLibraryRoute(router, database)
    registerGraphRoute(router, database, embeddingModelProvider: embeddingModelProvider)
    registerGraphAdminRoutes(router, database, embeddingModelProvider: embeddingModelProvider,
                             graphExtractor: graphExtractor)
}

@main
struct ThreadServer: AsyncParsableCommand {
    @ArgumentParser.Option(name: .long, help: "Host address.")
    var host: String = AppConstants.defaultHost

    @ArgumentParser.Option(name: .long, help: "Port number.")
    var port: Int = AppConstants.defaultPort

    @ArgumentParser.Flag(name: .long, help: "Disable LLM graph extraction (keyword entities only).")
    var noGraphExtraction: Bool = false

    @ArgumentParser.Option(name: .long, help: "Graph extraction backend: mlx (on-device, default) | mistral (API) | keyword.")
    var graphBackend: String = "mlx"

    @ArgumentParser.Option(name: .long, help: "Mistral model for API graph extraction.")
    var graphMistralModel: String = "mistral-tiny"

    #if canImport(MLX)
    @ArgumentParser.Flag(name: .long, help: "Use on-device MLX embedding model instead of Mistral API.")
    var useMLX: Bool = false

    @ArgumentParser.Option(name: .long, help: "MLX Hub model ID for on-device embeddings.")
    var mlxModel: String = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

    @ArgumentParser.Option(name: .long, help: "MLX Hub model ID for on-device graph extraction.")
    var graphModel: String = "mlx-community/Qwen3-1.7B-4bit"
    #endif

    @ArgumentParser.Option(name: .long, help: "gRPC server port for Database fan-out calls.")
    var grpcPort: Int = 9090

    @ArgumentParser.Option(name: .long, help: "Mothership (Database) host. Leave empty to run standalone.")
    var mothershipHost: String = ""

    @ArgumentParser.Option(name: .long, help: "Mothership (Database) gRPC port.")
    var mothershipGrpcPort: Int = 9091

    @ArgumentParser.Option(name: .long, help: "Fleet destination host (for dataset import). Leave empty to skip.")
    var fleetHost: String = ""

    @ArgumentParser.Option(name: .long, help: "Fleet destination gRPC port.")
    var fleetGrpcPort: Int = 9092

    @ArgumentParser.Option(name: .long, help: "Fixed node UUID (env THREAD_NODE_ID). Overrides any persisted node-id on disk.")
    var nodeId: String?

    @ArgumentParser.Option(name: .long, help: "Directory for on-disk state (default ~/Documents/thread-db; env THREAD_DATA_DIR).")
    var dataDir: String?

    enum CodingKeys: CodingKey {
        case host, port, grpcPort, mothershipHost, mothershipGrpcPort, fleetHost, fleetGrpcPort, nodeId, dataDir
        case noGraphExtraction, graphBackend, graphMistralModel
        #if canImport(MLX)
        case useMLX, mlxModel, graphModel
        #endif
    }

    @MainActor
    func run() async throws {
        // ── Load .env before anything reads ProcessInfo.environment ──────────────
        loadDotEnv()

        // ── Storage root: --data-dir beats THREAD_DATA_DIR beats ~/Documents/thread-db
        let dataRoot = FilePersistence.configure(
            dataDirectory: dataDir ?? ProcessInfo.processInfo.environment["THREAD_DATA_DIR"])

        // ── Logging ──────────────────────────────────────────────────────────────
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .debug
            return handler
        }
        var logger = Logger(label: "thread")
        logger.logLevel = .debug
        logger.info("Storage root: \(dataRoot.path)")

        // ── Core services ─────────────────────────────────────────────────────────
        let (fixedNodeId, rejectedNodeId) = NodeIdentity.override(
            argument: nodeId, environment: ProcessInfo.processInfo.environment)
        if let rejectedNodeId {
            logger.warning("NodeIdentity: ignoring a node id that is not a UUID (\(rejectedNodeId.prefix(16))…); using the persisted one")
        }
        let database = Database(nodeId: fixedNodeId)
        let embeddingModelProvider: any EmbeddingProviding = makeEmbeddingProvider()
        let graphExtractor: any GraphExtracting = makeGraphExtractor()

        // ── Router + middleware ───────────────────────────────────────────────────
        let router = Router(context: ThreadRequestContext.self)
        if StackSecret.isLocalMode {
            // Launched by an app for itself: no browser is a client, so no
            // CORS — and every request must carry the app's secret. Nothing
            // else guards these routes (/v1/clear among them). Added before
            // any route: Hummingbird binds middleware at registration.
            router.middlewares.add(StackSecretMiddleware<ThreadRequestContext>())
        } else {
            router.middlewares.add(CORSMiddleware(
                allowOrigin: .all,
                allowHeaders: [.accept, .authorization, .contentType, .origin],
                allowMethods: [.get, .post, .options]
            ))
        }

        // ── Register ALL routes before Application.init freezes the responder ────
        configureRoutes(router, database, embeddingModelProvider: embeddingModelProvider,
                        graphExtractor: graphExtractor)

        // ── GRPC Server ────────────────────
        let grpcServer = ThreadGRPCServer()
        await grpcServer.start(database: database, embeddingProvider: embeddingModelProvider,
                               graphExtractor: graphExtractor, host: host, grpcPort: grpcPort)

        // A Thread can dial a Sewn mothership and/or a Fleet destination. Both reuse
        // the same destination-agnostic dispatcher (it serves search/library/graph).
        // Strong owners that must outlive `app.runService()`. The registration
        // clients spawn their heartbeat/session loops with `[weak self]`, so
        // without an owner here the actor is deallocated the moment its first
        // session ends — after which the reconnect loop sees a nil `self` and
        // silently stops. The mothership client happened to survive only because
        // the availability route closure retained it; the Fleet client had no
        // such owner and so never reconnected.
        var registrationClients: [MothershipRegistrationClient] = []

        if !mothershipHost.isEmpty || !fleetHost.isEmpty {
            let dispatcher = MothershipRequestDispatcher(
                database: database,
                embeddingProvider: embeddingModelProvider,
                graphExtractor: graphExtractor,
                logger: logger
            )

            if !mothershipHost.isEmpty {
                let client = MothershipRegistrationClient(
                    mothershipHost: mothershipHost,
                    mothershipGRPCPort: mothershipGrpcPort,
                    threadId: database.nodeId,
                    threadHost: host,
                    threadGRPCPort: grpcPort,
                    threadHTTPPort: port,
                    requestDispatcher: dispatcher,
                    logger: SwiftLogConduitLogger(logger),
                    interceptors: Self.mothershipInterceptors(
                        secret: StackSecret.value, mothershipHost: mothershipHost)
                )
                await client.startHeartbeatLoop()
                registerAvailabilityRoute(router, registrationClient: client)
                registrationClients.append(client)
            }

            if !fleetHost.isEmpty {
                let fleetClient = MothershipRegistrationClient(
                    mothershipHost: fleetHost,
                    mothershipGRPCPort: fleetGrpcPort,
                    threadId: database.nodeId,
                    threadHost: host,
                    threadGRPCPort: grpcPort,
                    threadHTTPPort: port,
                    requestDispatcher: dispatcher,
                    logger: SwiftLogConduitLogger(logger)
                )
                await fleetClient.startHeartbeatLoop()
                registrationClients.append(fleetClient)
                logger.info("Thread: connecting to Fleet destination \(fleetHost):\(fleetGrpcPort)")
            }
        }

        // ── Build Application AFTER all routes are registered ────────────────────
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(host, port: port),
                serverName: "Thread"
            ),
            logger: logger
        )

        let threadLogger = ThreadLogger(logger)
        threadLogger.info("Startup", "Thread starting on http://\(host):\(port)", service: .startup)

        do {
            try await app.runService()
        } catch {
            await database.shutdown()
            throw error
        }
        await database.shutdown()

        // Keep the registration clients alive across the whole serve loop above;
        // their session/heartbeat tasks hold only `[weak self]`.
        withExtendedLifetime(registrationClients) {}
    }

    /// Reads the `.env` file from the working directory and injects any
    /// `KEY=VALUE` pairs into the process environment via `setenv`.
    /// Existing OS-level env vars are never overwritten (overwrite flag = 0),
    /// so a value already exported in the shell always wins.
    /// Hummingbird has no built-in dotenv support unlike Vapor's
    /// `Environment.dotenv()`; this replaces that functionality.
    private func loadDotEnv() {
        let path = FileManager.default.currentDirectoryPath + "/.env"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  let eqRange = trimmed.range(of: "=") else { continue }
            let key   = String(trimmed[..<eqRange.lowerBound])
                            .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[eqRange.upperBound...])
                            .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            setenv(key, value, 0) // 0 = don't overwrite an already-exported var
        }
    }

    private func makeEmbeddingProvider() -> any EmbeddingProviding {
        var logger = Logger(label: "thread")
        logger.logLevel = .debug
        #if canImport(MLX)
        if useMLX {
            if MLXRuntimeProbe.metalKernelLibraryAvailable() {
                logger.info("Embedding backend: MLX (\(mlxModel))")
                return MLXEmbeddingModelProvider(modelId: mlxModel)
            }
            logger.warning("Embedding backend: MLX requested but this build has no Metal kernel library (default.metallib) — MLX would abort the process. Falling back to Mistral API.")
        }
        #endif
        logger.info("Embedding backend: Mistral API (mistral-embed)")
        return EmbeddingModelProvider(logger: logger)
    }

    /// LLM extraction backend selection: on-device MLX (default), Mistral API,
    /// or keyword-only. Extraction failures never fail ingest — GraphEnrichment
    /// keeps the keyword entities.
    private func makeGraphExtractor() -> any GraphExtracting {
        var logger = Logger(label: "thread")
        logger.logLevel = .debug

        guard !noGraphExtraction else {
            logger.info("Graph extraction: disabled — keyword entities only")
            return KeywordGraphExtractionProvider()
        }

        switch graphBackend {
        case "mistral":
            let key = ProcessInfo.processInfo.environment["MISTRAL_API_KEY"] ?? ""
            guard !key.isEmpty else {
                logger.warning("Graph extraction: Mistral backend requested but MISTRAL_API_KEY is not set — falling back to keyword extraction.")
                return KeywordGraphExtractionProvider()
            }
            logger.info("Graph extraction: Mistral API (\(graphMistralModel))")
            return MistralGraphExtractionProvider(model: graphMistralModel, logger: logger)

        case "mlx":
            #if canImport(MLX)
            if MLXRuntimeProbe.metalKernelLibraryAvailable() {
                logger.info("Graph extraction: MLX (\(graphModel))")
                return MLXGraphExtractionProvider(modelId: graphModel)
            }
            logger.warning("Graph extraction: MLX requested but this build has no Metal kernel library (default.metallib) — MLX would abort the process on first use. Falling back to keyword extraction; use --graph-backend mistral for API extraction, or rebuild Frigate with its metallib step.")
            #else
            logger.warning("Graph extraction: MLX backend requested but this build has no MLX support — falling back to keyword extraction (use --graph-backend mistral for API extraction).")
            #endif
            return KeywordGraphExtractionProvider()

        default:
            logger.info("Graph extraction: keyword backend")
            return KeywordGraphExtractionProvider()
        }
    }
}
