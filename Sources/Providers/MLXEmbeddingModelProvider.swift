#if canImport(MLX)
import Foundation
import Logging
import Frigate

/// On-device embedding provider backed by an MLX model loaded via the Hub.
///
/// Activated with `--use-mlx` at server startup. Falls back to `EmbeddingModelProvider`
/// (Mistral API) when the flag is absent.
///
/// All GPU work (model load, tokenization scheduling, batching, allocator
/// hygiene) lives in `FrigateEmbedder` — one code path shared with every other
/// Frigate host. This provider adds Totem's `EmbeddingProviding` surface:
/// preprocess slots and the `EmbeddingData`/usage response shapes.
actor MLXEmbeddingModelProvider: EmbeddingProviding {
    private let embedder: FrigateEmbedder
    private var loggedModelReady = false
    private let modelId: String

    // MARK: - Preprocessing slots (mirrors EmbeddingModelProvider)

    private let maxPreprocessConcurrent = 30
    private var preprocessActiveCount = 0
    private var preprocessWaiters: [CheckedContinuation<Void, Never>] = []

    init(modelId: String = "mlx-community/snowflake-arctic-embed-m-v1.5") {
        self.modelId = modelId
        self.embedder = FrigateEmbedder(modelId: modelId)
    }

    // MARK: - EmbeddingProviding

    func run(
        _ texts: [String],
        logger: Logger,
        priority: Bool = false
    ) async throws -> (result: [EmbeddingData], usage: Requests.Embedding.Get.Result.Usage) {
        if !loggedModelReady {
            logger.info("Loading MLX embedding model: \(modelId)")
        }
        let (embeddings, promptTokens) = try await embedder.embedWithUsage(texts)
        if !loggedModelReady {
            loggedModelReady = true
            logger.info("MLX embedding model ready: \(modelId)")
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
