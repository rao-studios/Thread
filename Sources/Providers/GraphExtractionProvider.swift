//
//  GraphExtractionProvider.swift
//  database-server
//
//  Created by Ritesh Pakala on 7/16/26.
//

import Foundation
import Logging

/// Extracts a knowledge-graph payload (entities + relationships) from document text at ingest.
protocol GraphExtracting: Sendable {
    func extract(from texts: [String], logger: Logger) async throws -> Database.GraphPayload
}

/// Fallback extractor: high-frequency keywords as untyped `concept` entities, no relationships.
/// Always available (pure Swift, no MLX), used when on-device extraction is disabled or fails.
struct KeywordGraphExtractionProvider: GraphExtracting {
    func extract(from texts: [String], logger: Logger) async throws -> Database.GraphPayload {
        Database.GraphPayload(
            entities: TagGenerator.generate(from: texts).map { .init(name: $0, kind: "concept") }
        )
    }
}

/// Pure, MLX-free parser for the LLM's JSON output. Isolated here so it is unit-testable
/// without loading a model.
enum GraphExtractionParser {
    static let maxEntities = 12
    static let maxRelationships = 15

    enum ParseError: Error { case noJSONObject, decodeFailed }

    private struct Raw: Decodable {
        struct Entity: Decodable { let name: String; let kind: String? }
        struct Relation: Decodable { let subject: String; let predicate: String; let object: String }
        let entities: [Entity]?
        let relationships: [Relation]?
    }

    /// Parses and validates the model's response into a `GraphPayload`.
    /// Accepts bare JSON or JSON wrapped in prose / code fences (extracts the outermost braces).
    /// Throws when no JSON object is present or it cannot be decoded.
    static func parse(_ response: String) throws -> Database.GraphPayload {
        guard let first = response.firstIndex(of: "{"),
              let last = response.lastIndex(of: "}"),
              first < last else {
            throw ParseError.noJSONObject
        }
        let jsonSlice = String(response[first...last])
        guard let data = jsonSlice.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            throw ParseError.decodeFailed
        }

        // Validate + normalize entities.
        var entities: [Database.GraphPayload.EntityIn] = []
        var seenEntityKeys = Set<String>()
        var nameSet = Set<String>()   // normalized names, for relationship validation
        for e in raw.entities ?? [] {
            let name = e.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let kind = GraphStore.normalizeKind(e.kind ?? "concept")
            let key = "\(kind)|\(GraphStore.normalizeName(name))"
            guard seenEntityKeys.insert(key).inserted else { continue }
            entities.append(.init(name: name, kind: kind))
            nameSet.insert(GraphStore.normalizeName(name))
            if entities.count >= maxEntities { break }
        }

        // Validate relationships — subject/object must reference a known entity name.
        var relationships: [Database.GraphPayload.RelationIn] = []
        var seenRelKeys = Set<String>()
        for r in raw.relationships ?? [] {
            let subject = r.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let object = r.object.trimmingCharacters(in: .whitespacesAndNewlines)
            let predicate = r.predicate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !predicate.isEmpty,
                  nameSet.contains(GraphStore.normalizeName(subject)),
                  nameSet.contains(GraphStore.normalizeName(object)) else { continue }
            let key = "\(GraphStore.normalizeName(subject))|\(predicate)|\(GraphStore.normalizeName(object))"
            guard seenRelKeys.insert(key).inserted else { continue }
            relationships.append(.init(subject: subject, predicate: predicate, object: object))
            if relationships.count >= maxRelationships { break }
        }

        return Database.GraphPayload(entities: entities, relationships: relationships)
    }

    static let systemPrompt = """
    You extract a knowledge graph from text. Respond with ONLY a JSON object — no prose, no code fences:
    {"entities":[{"name":"...","kind":"person|organization|place|event|work|concept|other"}],\
    "relationships":[{"subject":"...","predicate":"...","object":"..."}]}
    Rules: at most 12 entities and 15 relationships; subject and object MUST exactly match a name \
    from entities; predicates are short lowercase verb phrases ("founded","works at","part of"); \
    keep original name casing; no duplicates.
    """
}

#if canImport(MLX)
import MLX
import MLXLMCommon
import MLXLLM

/// On-device LLM extractor. Lazily loads a small instruct model via the Hub and runs a fresh
/// deterministic chat session per document. Any parse failure throws so the caller can fall
/// back to keywords — extraction never fails ingest.
actor MLXGraphExtractionProvider: GraphExtracting {
    private let modelId: String
    private let maxInputChars: Int
    private var container: ModelContainer?

    init(modelId: String = "mlx-community/Qwen3-1.7B-4bit", maxInputChars: Int = 3_000) {
        self.modelId = modelId
        self.maxInputChars = maxInputChars
    }

    func extract(from texts: [String], logger: Logger) async throws -> Database.GraphPayload {
        let container = try await loadedModel(logger: logger)
        let input = String(texts.joined(separator: " ").prefix(maxInputChars))
        let session = ChatSession(
            container,
            instructions: GraphExtractionParser.systemPrompt,
            generateParameters: GenerateParameters(maxTokens: 800, temperature: 0)
        )
        let response = try await session.respond(to: input)
        return try GraphExtractionParser.parse(response)
    }

    private func loadedModel(logger: Logger) async throws -> ModelContainer {
        if let container { return container }
        logger.info("Loading MLX extraction model: \(modelId)")
        let loaded = try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(id: modelId)
        )
        container = loaded
        logger.info("MLX extraction model ready: \(modelId)")
        return loaded
    }
}
#endif
