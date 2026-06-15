import ArgumentParser
import Conduit
import Foundation
import Logging
import Hummingbird
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func configureRoutes(
    _ router: Router<TotemRequestContext>,
    _ database: Database,
    embeddingModelProvider: any EmbeddingProviding
) {
    registerHealthRoute(router)
    registerSearchRoute(router, database, embeddingModelProvider: embeddingModelProvider)
    registerBatchEmbeddingsRoute(router, database, embeddingModelProvider: embeddingModelProvider)
    registerLibraryRoute(router, database)
    registerHNSWRoutes(router, database)
}

@main
struct TotemServer: AsyncParsableCommand {
    @ArgumentParser.Option(name: .long, help: "Host address.")
    var host: String = AppConstants.defaultHost

    @ArgumentParser.Option(name: .long, help: "Port number.")
    var port: Int = AppConstants.defaultPort

    #if canImport(MLX)
    @ArgumentParser.Flag(name: .long, help: "Use on-device MLX embedding model instead of Mistral API.")
    var useMLX: Bool = false

    @ArgumentParser.Option(name: .long, help: "MLX Hub model ID for on-device embeddings.")
    var mlxModel: String = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
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

    @ArgumentParser.Option(name: .long, help: "Fixed node UUID. Overrides any persisted node-id on disk.")
    var nodeId: String?

    enum CodingKeys: CodingKey {
        case host, port, grpcPort, mothershipHost, mothershipGrpcPort, fleetHost, fleetGrpcPort, nodeId
        #if canImport(MLX)
        case useMLX, mlxModel
        #endif
    }

    @MainActor
    func run() async throws {
        // ── Load .env before anything reads ProcessInfo.environment ──────────────
        loadDotEnv()

        // ── Logging ──────────────────────────────────────────────────────────────
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .debug
            return handler
        }
        var logger = Logger(label: "totem")
        logger.logLevel = .debug

        // ── Core services ─────────────────────────────────────────────────────────
        let fixedNodeId = nodeId.flatMap { UUID(uuidString: $0) }
        let database = Database(nodeId: fixedNodeId)
        let embeddingModelProvider: any EmbeddingProviding = makeEmbeddingProvider()

        // ── Router + middleware ───────────────────────────────────────────────────
        let router = Router(context: TotemRequestContext.self)
        router.middlewares.add(CORSMiddleware(
            allowOrigin: .all,
            allowHeaders: [.accept, .authorization, .contentType, .origin],
            allowMethods: [.get, .post, .options]
        ))

        // ── Register ALL routes before Application.init freezes the responder ────
        configureRoutes(router, database, embeddingModelProvider: embeddingModelProvider)

        // ── GRPC Server ────────────────────
        let grpcServer = TotemGRPCServer()
        await grpcServer.start(database: database, embeddingProvider: embeddingModelProvider, grpcPort: grpcPort)

        // A Totem can dial a Seer mothership and/or a Fleet destination. Both reuse
        // the same destination-agnostic dispatcher (it serves search/library/HNSW).
        if !mothershipHost.isEmpty || !fleetHost.isEmpty {
            let dispatcher = MothershipRequestDispatcher(
                database: database,
                embeddingProvider: embeddingModelProvider,
                logger: logger
            )

            if !mothershipHost.isEmpty {
                let client = MothershipRegistrationClient(
                    mothershipHost: mothershipHost,
                    mothershipGRPCPort: mothershipGrpcPort,
                    totemId: database.nodeId,
                    totemHost: host,
                    totemGRPCPort: grpcPort,
                    totemHTTPPort: port,
                    requestDispatcher: dispatcher,
                    logger: SwiftLogConduitLogger(logger)
                )
                await client.startHeartbeatLoop()
                registerAvailabilityRoute(router, registrationClient: client)
            }

            if !fleetHost.isEmpty {
                let fleetClient = MothershipRegistrationClient(
                    mothershipHost: fleetHost,
                    mothershipGRPCPort: fleetGrpcPort,
                    totemId: database.nodeId,
                    totemHost: host,
                    totemGRPCPort: grpcPort,
                    totemHTTPPort: port,
                    requestDispatcher: dispatcher,
                    logger: SwiftLogConduitLogger(logger)
                )
                await fleetClient.startHeartbeatLoop()
                logger.info("Totem: connecting to Fleet destination \(fleetHost):\(fleetGrpcPort)")
            }
        }

        // ── Build Application AFTER all routes are registered ────────────────────
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(host, port: port),
                serverName: "Totem"
            ),
            logger: logger
        )

        let totemLogger = TotemLogger(logger)
        totemLogger.info("Startup", "Totem starting on http://\(host):\(port)", service: .startup)

        do {
            try await app.runService()
        } catch {
            await database.shutdown()
            throw error
        }
        await database.shutdown()
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
        var logger = Logger(label: "totem")
        logger.logLevel = .debug
        #if canImport(MLX)
        if useMLX {
            logger.info("Embedding backend: MLX (\(mlxModel))")
            return MLXEmbeddingModelProvider(modelId: mlxModel)
        }
        #endif
        logger.info("Embedding backend: Mistral API (mistral-embed)")
        return EmbeddingModelProvider(logger: logger)
    }

}
