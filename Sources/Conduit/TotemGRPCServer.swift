import Conduit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging

actor TotemGRPCServer {
    private var serverTask: Task<Void, Error>?

    func start(
        database: Database,
        embeddingProvider: any EmbeddingProviding,
        graphExtractor: any GraphExtracting,
        grpcPort: Int
    ) {
        let query   = TotemQueryServiceImpl(database: database, embeddingProvider: embeddingProvider,
                                            graphExtractor: graphExtractor)
        let library = TotemLibraryServiceImpl(database: database)
        let graph   = TotemGraphServiceImpl(database: database, embeddingProvider: embeddingProvider)
        serverTask = Task {
            let transport = HTTP2ServerTransport.Posix(
                address: .ipv4(host: "0.0.0.0", port: grpcPort),
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
            let server = GRPCServer(transport: transport, services: [query, library, graph])
            database.logger.info("TotemGRPCServer", "gRPC server listening on port \(grpcPort)", service: .startup)
            try await server.serve()
        }
    }

    func stop() {
        serverTask?.cancel()
        serverTask = nil
    }
}
