//
//  Fixtures.swift
//  totem-tests
//

import Foundation
import Logging
@testable import totem

// MARK: - Persistence cleanup

func wipeTotemPersistenceFiles() {
    let db = FilePersistence.getDefaultURL()
    for key in ["table", "registry"] {
        try? FileManager.default.removeItem(at: db.appendingPathComponent(key))
    }
    if let contents = try? FileManager.default.contentsOfDirectory(
        at: db, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
    ) {
        for url in contents where url.lastPathComponent.hasPrefix("shard-")
            || url.lastPathComponent.hasPrefix("table-")
            || url.lastPathComponent.hasPrefix("graph-") {
            try? FileManager.default.removeItem(at: url)
        }
    }
    try? FileManager.default.removeItem(at: db.appendingPathComponent("personal"))
}

// MARK: - Logger

extension Logger {
    static var test: Logger {
        var logger = Logger(label: "test-totem")
        logger.logLevel = .critical
        return logger
    }
}

extension TotemLogger {
    static var test: TotemLogger { TotemLogger(.test) }
}

// MARK: - DatabaseRequest

extension DatabaseRequest {
    static func test(
        ownerId: String = "test-owner",
        scope: DatabaseRequestScope? = .personal
    ) -> DatabaseRequest {
        DatabaseRequest(ownerId: ownerId, group: nil, aggregate: nil, scope: scope, requestID: nil)
    }
}

// MARK: - Database.Partition

extension Database.Partition {
    static func test(
        id: String = UUID().uuidString,
        documentId: String = "test-doc",
        url: URL = URL(string: "https://example.com")!,
        embedding: [Float] = [],
        text: String = "test text here",
        ownerId: String = "test-owner"
    ) -> Database.Partition {
        Database.Partition(
            id: id,
            documentId: documentId,
            url: url,
            embedding: embedding,
            text: text,
            ownerId: ownerId
        )
    }
}

// MARK: - TableMutator

extension TableMutator {
    static func test() -> TableMutator {
        TableMutator(nodeId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, logger: .test)
    }
}

// MARK: - RegistryMutator

extension RegistryMutator {
    static func test() -> RegistryMutator {
        let m = RegistryMutator(
            nodeId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            logger: .test
        )
        m.seed(TotemRegistry())
        return m
    }
}

// MARK: - Database.Document

extension Database.Document {
    static func test(
        id: String = UUID().uuidString,
        ownerId: String = "test-owner"
    ) -> Database.Document {
        Database.Document(id: id, url: URL(string: "https://example.com")!, ownerId: ownerId)
    }
}

// MARK: - Database.Group

extension Database.Group {
    static func test(
        id: String = "test-group",
        label: String = "Test Group",
        ownerId: String = "test-owner",
        metadata: Database.Group.Metadata? = nil
    ) -> Database.Group {
        Database.Group(id: id, label: label, ownerId: ownerId, documents: [], metadata: metadata)
    }
}

// MARK: - Database.Group.Metadata

extension Database.Group.Metadata {
    static func test(
        description: String? = "A test group description",
        tags: [String] = ["swift", "test"]
    ) -> Database.Group.Metadata {
        Database.Group.Metadata(description: description, tags: tags)
    }
}

// MARK: - MockEmbeddingProvider

actor MockEmbeddingProvider: EmbeddingProviding {
    private var callCount = 0

    func acquirePreprocessSlot() async {}
    func releasePreprocessSlot() async {}

    func run(
        _ texts: [String],
        logger: Logger,
        priority: Bool
    ) async throws -> (result: [EmbeddingData], usage: Requests.Embedding.Get.Result.Usage) {
        let embeddings = texts.enumerated().map { (i, _) -> EmbeddingData in
            let seed = UInt64(i + callCount * 1000 + 99000)
            return EmbeddingData(
                embedding: .floats(VectorFixtures.random(dim: VectorFixtures.embeddingDim, seed: seed)),
                index: i
            )
        }
        callCount += texts.count
        let usage = Requests.Embedding.Get.Result.Usage(
            promptAudioSeconds: nil,
            promptTokens: texts.count,
            totalTokens: texts.count,
            completionTokens: 0,
            requestCount: nil,
            promptTokenDetails: nil
        )
        return (embeddings, usage)
    }
}

// MARK: - Vector Fixtures

/// Deterministic vector helpers for reproducible test cases.
/// All vectors use `dim = 32` — divisible by 16 (PartitionQuantizer.numSubvectors).
enum VectorFixtures {
    static let dim = 32
    /// Full production embedding dimension (mistral-embed).
    static let embeddingDim = 1024

    /// All-zero vector.
    static func zeros() -> [Float] { [Float](repeating: 0, count: dim) }

    /// Unit vector along a single axis.
    static func unit(axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[axis % dim] = 1.0
        return v
    }

    /// Seeded pseudo-random vector — deterministic across runs.
    static func random(seed: UInt64) -> [Float] {
        random(dim: dim, seed: seed)
    }

    /// Seeded pseudo-random vector at an explicit dimension.
    static func random(dim: Int, seed: UInt64) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<dim).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int(bitPattern: UInt(state >> 33)) % 1000) / 500.0 - 1.0
        }
    }

    /// Vector very close to `center` (small perturbation).
    static func near(_ center: [Float], seed: UInt64) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        return center.map { c in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int(bitPattern: UInt(state >> 33)) % 100) / 100000.0
            return c + noise
        }
    }

    /// L2 distance between two vectors.
    static func l2(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { d in let e = d.0 - d.1; return e * e }.reduce(0, +).squareRoot()
    }
}
