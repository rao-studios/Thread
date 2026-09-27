#if canImport(MLX)
import Foundation
import Logging
import Frigate

/// On-device embedding provider backed by an MLX model loaded via the Hub.
///
/// Activated with `--use-mlx` at server startup. Falls back to `EmbeddingModelProvider`
/// (Mistral API) when the flag is absent.
///
/// All GPU work (download, model load, prompts, tokenization, batching, allocator
/// hygiene) lives in `FrigateEmbedder` — one code path shared with every other
/// Frigate host. This provider adds Thread's `EmbeddingProviding` surface:
/// preprocess slots, the `EmbeddingData`/usage response shapes, and readiness.
///
/// Queries do not wait behind indexing here: `FrigateEmbedder` takes its model
/// lock per sub-batch, so a query lands between two sub-batches of a long filing.
actor MLXEmbeddingModelProvider: EmbeddingProviding {
    private let embedder: FrigateEmbedder
    private var loggedModelReady = false

    // MARK: - Preprocessing slots (mirrors EmbeddingModelProvider)

    private let maxPreprocessConcurrent = 30
    private var preprocessActiveCount = 0
    private var preprocessWaiters: [CheckedContinuation<Void, Never>] = []

    /// `org/repo`, `org/repo@<revision>` or a snapshot directory; see `FrigateEmbedder.Profile`.
    init(modelId: String = FrigateEmbedder.Profile.voyage4NanoRepo) {
        self.embedder = FrigateEmbedder(modelId: modelId)
    }

    nonisolated var vectorSpace: String? { embedder.profile.vectorSpace }

    nonisolated var health: EmbedderHealth? {
        let status = embedder.status
        return EmbedderHealth(
            model: status.model,
            revision: status.revision,
            vectorSpace: status.vectorSpace,
            phase: EmbedderHealth.Phase(rawValue: status.phase.rawValue) ?? .idle,
            progress: status.fraction,
            error: status.error)
    }

    func warmup() async {
        do {
            try await embedder.warmup()
        } catch {
            // Reported through `health`; the next request tries again.
        }
    }

    // MARK: - EmbeddingProviding

    func run(
        _ texts: [String],
        logger: Logger,
        role: EmbeddingRole
    ) async throws -> (result: [EmbeddingData], usage: Requests.Embedding.Get.Result.Usage) {
        // Not ready: say so now rather than holding the caller through a download.
        // A load that failed (offline on first run) is tried again in the background.
        if let health, health.phase != .ready {
            if health.phase == .failed || health.phase == .idle {
                Task { await self.warmup() }
            }
            throw EmbedderNotReady(health: health)
        }
        let (embeddings, promptTokens) = try await embedder.embedWithUsage(
            texts, role: role == .query ? .query : .document)
        if !loggedModelReady {
            loggedModelReady = true
            logger.info("MLX embedding model ready: \(embedder.profile.model) (\(embedder.profile.vectorSpace))")
        }

        let result = embeddings.enumerated().map { i, vector in
            EmbeddingData(embedding: .floats(vector), index: i)
        }
        let usage = Requests.Embedding.Get.Result.Usage(
            promptAudioSeconds: nil,
            promptTokens: promptTokens,
            totalTokens: promptTokens,
            completionTokens: 0,
            requestCount: nil,
            promptTokenDetails: nil
        )
        return (result, usage)
    }

    func acquirePreprocessSlot() async {
        if preprocessActiveCount < maxPreprocessConcurrent {
            preprocessActiveCount += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            preprocessWaiters.append(c)
        }
    }

    func releasePreprocessSlot() {
        if let waiter = preprocessWaiters.first {
            preprocessWaiters.removeFirst()
            waiter.resume()
        } else {
            preprocessActiveCount -= 1
        }
    }
}
#endif
