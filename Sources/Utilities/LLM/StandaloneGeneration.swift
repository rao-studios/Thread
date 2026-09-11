import Foundation
import Logging

class StandaloneGeneration {
    static func runEmbedding(
        _ texts: [String],
        modelProvider: any EmbeddingProviding,
        logger: Logger,
        priority: Bool = false
    ) async throws -> [EmbeddingData] {
        return try await modelProvider.run(texts, logger: logger, priority: priority).result
    }

    static func runAPIEmbedding(
        _ texts: [String],
        logger: Logger
    ) async throws -> [EmbeddingData] {
        var allData: [EmbeddingData] = []
        let network = NetworkService(logger: logger)
        let response = try await network.request(
            Requests.Embedding.Get(input: texts, model: "mistral-embed", encodingFormat: "float")
        )
        for data in response.data {
            allData.append(.init(embedding: .floats(data.embedding), index: data.index))
        }
        return allData
    }
}
