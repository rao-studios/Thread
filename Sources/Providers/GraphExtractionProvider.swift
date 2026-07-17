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
        let cap = ExtractionPolicyStore.current.maxEntities
        return Database.GraphPayload(
            entities: TagGenerator.generate(from: texts)
                .prefix(cap)
                .map { .init(name: $0, kind: "concept") }
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
    /// Caps and kind validation come from the active `ExtractionPolicy` (overridable for tests).
    static func parse(_ response: String, policy: ExtractionPolicy? = nil) throws -> Database.GraphPayload {
        let policy = policy ?? ExtractionPolicyStore.current
        let entityCap = min(policy.maxEntities, maxEntities)
        let relationshipCap = min(policy.maxRelationships, maxRelationships)
        let allowedKinds = Set(policy.kinds.map { GraphStore.normalizeKind($0.name) })

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
            var kind = GraphStore.normalizeKind(e.kind ?? "concept")
            if !allowedKinds.isEmpty, !allowedKinds.contains(kind) {
                // Out-of-ontology kinds coerce to the closest generic bucket.
                kind = allowedKinds.contains("concept") ? "concept" : (allowedKinds.first ?? "concept")
            }
            let key = "\(kind)|\(GraphStore.normalizeName(name))"
            guard seenEntityKeys.insert(key).inserted else { continue }
            entities.append(.init(name: name, kind: kind))
            nameSet.insert(GraphStore.normalizeName(name))
            if entities.count >= entityCap { break }
        }

        // Validate relationships — subject/object must reference a known entity name.
        var relationships: [Database.GraphPayload.RelationIn] = []
        var seenRelKeys = Set<String>()
        for r in raw.relationships ?? [] {
            let subject = r.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let object = r.object.trimmingCharacters(in: .whitespacesAndNewlines)
            let predicate = policy.normalizePredicate(r.predicate)
            guard !predicate.isEmpty,
                  nameSet.contains(GraphStore.normalizeName(subject)),
                  nameSet.contains(GraphStore.normalizeName(object)) else { continue }
            let key = "\(GraphStore.normalizeName(subject))|\(predicate)|\(GraphStore.normalizeName(object))"
            guard seenRelKeys.insert(key).inserted else { continue }
            relationships.append(.init(subject: subject, predicate: predicate, object: object))
            if relationships.count >= relationshipCap { break }
        }

        return Database.GraphPayload(entities: entities, relationships: relationships)
    }

    /// Built-in fallback prompt — the live prompt comes from
    /// `ExtractionPolicyStore.current.effectiveSystemPrompt`.
    static let systemPrompt = ExtractionPolicy().effectiveSystemPrompt
}

/// Mistral-API extractor: same prompt/parse contract as the on-device MLX
/// provider, no local model. Uses the same `MISTRAL_API_KEY` the embedding
/// provider already reads. Failures throw — GraphEnrichment catches and keeps
/// the keyword entities, so extraction never fails ingest.
actor MistralGraphExtractionProvider: GraphExtracting {
    private let model: String
    private let maxInputChars: Int
    private let network: NetworkService

    init(model: String = "mistral-tiny", maxInputChars: Int = 3_000, logger: Logger) {
        self.model = model
        self.maxInputChars = maxInputChars
        self.network = NetworkService(logger: logger)
    }

    func extract(from texts: [String], logger: Logger) async throws -> Database.GraphPayload {
        let policy = ExtractionPolicyStore.current
        let input = String(texts.joined(separator: " ").prefix(maxInputChars))
        let response = try await network.request(
            Requests.Chat.Get(
                model: model,
                messages: [
                    .init(role: "system", content: policy.effectiveSystemPrompt),
                    .init(role: "user", content: input),
                ],
                maxTokens: 800,
                temperature: 0
            )
        )
        guard let content = response.choices.first?.message.content else {
            throw GraphExtractionParser.ParseError.noJSONObject
        }
        return try GraphExtractionParser.parse(content, policy: policy)
    }
}

#if canImport(MLX)
import MLX
import MLXLMCommon
import MLXLLM

/// Probes whether MLX can actually run on this build before any MLX op executes.
///
/// Frigate's Cmlx compiles the Metal backend on Apple platforms but ships no
/// compiled kernel library (the CUDA-focused fork removed upstream mlx-swift's
/// metallib build step). When `default.metallib` is missing, the first GPU op
/// aborts the whole process from C++ ("Failed to load the default metallib") —
/// not a catchable Swift error — so availability must be checked up front and
/// MLX-backed providers skipped entirely when the library isn't bundled.
enum MLXRuntimeProbe {
    static func metalKernelLibraryAvailable() -> Bool {
        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
        let fm = FileManager.default
        var roots: [URL] = []
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(executableDir)
        }
        roots.append(Bundle.main.bundleURL)
        if let resources = Bundle.main.resourceURL { roots.append(resources) }

        // mlx looks for METAL_PATH ("default.metallib") inside the SWIFTPM_BUNDLE
        // ("mlx-swift_Cmlx") colocated with the executable, or beside it.
        let relativeCandidates = [
            "mlx-swift_Cmlx.bundle/default.metallib",
            "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib",
            "Frigate_Cmlx.bundle/default.metallib",
            "Frigate_Cmlx.bundle/Contents/Resources/default.metallib",
            "default.metallib",
            "mlx.metallib",
        ]
        for root in roots {
            for candidate in relativeCandidates
            where fm.fileExists(atPath: root.appendingPathComponent(candidate).path) {
                return true
            }
        }
        return false
        #else
        // Linux builds route MLX through the CPU/CUDA backends — no metallib.
        return true
        #endif
    }
}

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
        let policy = ExtractionPolicyStore.current
        let input = String(texts.joined(separator: " ").prefix(maxInputChars))
        let session = ChatSession(
            container,
            instructions: policy.effectiveSystemPrompt,
            generateParameters: GenerateParameters(maxTokens: 800, temperature: 0)
        )
        let response = try await session.respond(to: input)
        return try GraphExtractionParser.parse(response, policy: policy)
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
