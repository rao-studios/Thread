import Foundation
import Hummingbird

struct HealthResponse: ResponseCodable {
    let status: String
    let timestamp: String
    /// Whether the caller holds this server's stack secret — "matched",
    /// "mismatched", or "open" when it asks for none. How Ambient tells its
    /// own server from something else on the port.
    let stack: String
}

func registerHealthRoute(_ app: some RouterMethods<ThreadRequestContext>) {
    app.get("/health") { request, _ async throws -> HealthResponse in
        return HealthResponse(
            status: "healthy",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            stack: StackSecret.verdict(of: request.headers[StackSecret.headerName])
        )
    }
}
