import Foundation
import Hummingbird
import RaoStack

struct HealthResponse: ResponseCodable {
    let status: String
    let timestamp: String
    /// "proof" when this server holds a stack secret it can prove, "open"
    /// when it asks for none. How a launcher tells its own server from
    /// something else on the port, without ever sending the secret.
    let stack: String
    /// HMAC-SHA256 over the caller's X-Ambient-Nonce, keyed by the secret;
    /// absent unless a well-formed nonce came in and a secret is configured.
    let proof: String?
    /// The app this Thread belongs to, when its launcher said (RAO_APP).
    let app: String?
    /// The shared-stack contract this build speaks; absent when open.
    let contract: Int?
}

func registerHealthRoute(_ app: some RouterMethods<ThreadRequestContext>, stack: StackMode) {
    app.get("/health") { request, _ async throws -> HealthResponse in
        // X-Rao-App is ignored: a Thread proves the one secret it was given.
        let answer = stack.healthAnswer(nonce: request.headers[.ambientNonce], requestedApp: nil)
        return HealthResponse(
            status: "healthy",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            stack: answer.stack,
            proof: answer.proof,
            app: answer.app?.rawValue,
            contract: answer.contract
        )
    }
}
