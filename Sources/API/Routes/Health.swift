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
    /// The embedding model and the index it writes. Absent when unknown. Launchers
    /// read it to show a first-run download and a model change.
    let embedder: HealthEmbedder?
}

/// What `/health` says about embedding: the model, whether it can answer yet, and
/// whether the stored index was written by it (EmbedderStamp.swift).
struct HealthEmbedder: Codable, Sendable, Equatable {
    let model: String?
    let revision: String?
    let vectorSpace: String?
    /// idle · downloading · loading · ready · failed ("ready" for a hosted API).
    let phase: String
    /// 0…1 while downloading.
    let progress: Double?
    let error: String?
    /// matches · mismatch · unstamped; absent before the table is reconciled.
    let index: String?
    /// The space the index was built with, when it is not this one.
    let indexedWith: String?

    init(provider: any EmbeddingProviding, index: IndexState?) {
        let health = provider.health
        self.model = health?.model
        self.revision = health?.revision
        self.vectorSpace = health?.vectorSpace ?? provider.vectorSpace
        self.phase = health?.phase.rawValue ?? EmbedderHealth.Phase.ready.rawValue
        self.progress = health?.progress
        self.error = health?.error
        self.index = index?.label
        self.indexedWith = index?.stampedSpace
    }
}

func registerHealthRoute(
    _ app: some RouterMethods<ThreadRequestContext>,
    stack: StackMode,
    embedder: @escaping @Sendable () async -> HealthEmbedder? = { nil }
) {
    app.get("/health") { request, _ async throws -> HealthResponse in
        // X-Rao-App is ignored: a Thread proves the one secret it was given.
        let answer = stack.healthAnswer(nonce: request.headers[.ambientNonce], requestedApp: nil)
        return HealthResponse(
            status: "healthy",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            stack: answer.stack,
            proof: answer.proof,
            app: answer.app?.rawValue,
            contract: answer.contract,
            embedder: await embedder()
        )
    }
}
