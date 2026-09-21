import Conduit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging

actor ThreadGRPCServer {
    private var serverTask: Task<Void, Error>?

    func start(
        database: Database,
        embeddingProvider: any EmbeddingProviding,
        graphExtractor: any GraphExtracting,
        host: String,
        grpcPort: Int
    ) {
        let query   = ThreadQueryServiceImpl(database: database, embeddingProvider: embeddingProvider,
                                            graphExtractor: graphExtractor)
        let library = ThreadLibraryServiceImpl(database: database)
        let graph   = ThreadGraphServiceImpl(database: database, embeddingProvider: embeddingProvider)
        let update  = ThreadUpdateServiceImpl(database: database)
        serverTask = Task {
            let transport = HTTP2ServerTransport.Posix(
                // Where the HTTP server binds (`--host`): loopback for a Thread an
                // app launched for itself, 0.0.0.0 only where a deployment asks.
                address: .ipv4(host: host, port: grpcPort),
                transportSecurity: .plaintext,
                config: .defaults {
                    // Direct-connect clients (Bonnie) push deposits and pull
                    // full document content here. The default 64 KiB receive
                    // window throttles anything sizeable to ~window/RTT —
                    // same congestion fix as the mothership session transport.
                    $0.rpc.maxRequestPayloadSize = 100 * 1024 * 1024
                    $0.http2.targetWindowSize = 16 * 1024 * 1024
                    $0.http2.maxFrameSize = 1 << 20
                    $0.compression.enabledAlgorithms = [.gzip, .none]
                }
            )
            let server = GRPCServer(
                transport: transport,
                services: [query, library, graph, update],
                // Local mode: the launcher's secret gates every RPC — Remove
                // and ExportCorpus among them — as StackSecretMiddleware does
                // for HTTP. Hosted (no env var): nothing is installed.
                interceptors: StackSecretServerInterceptor.forLocalMode(
                    secret: StackSecret.value,
                    logger: SwiftLogConduitLogger(database.logger.base)))
            database.logger.info("ThreadGRPCServer", "gRPC server listening on \(host):\(grpcPort)", service: .startup)
            do {
                try await server.serve()
            } catch is CancellationError {
                // stop() — a shutdown, not a failure.
            } catch {
                // Most often the port is taken. Dying loudly lets the launcher
                // see it, rather than a Thread nobody can query.
                database.logger.error("ThreadGRPCServer", "gRPC server on \(host):\(grpcPort) failed: \(error)", service: .startup)
                exit(EXIT_FAILURE)
            }
        }
    }

    func stop() {
        serverTask?.cancel()
        serverTask = nil
    }
}
