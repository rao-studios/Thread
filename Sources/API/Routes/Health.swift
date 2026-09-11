import Foundation
import Hummingbird

struct HealthResponse: ResponseCodable {
    let status: String
    let timestamp: String
}

func registerHealthRoute(_ app: some RouterMethods<ThreadRequestContext>) {
    app.get("/health") { _, _ async throws -> HealthResponse in
        return HealthResponse(
            status: "healthy",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }
}
