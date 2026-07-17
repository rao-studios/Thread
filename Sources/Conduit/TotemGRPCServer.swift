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
                transportSecurity: .plaintext
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
