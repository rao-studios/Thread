//
//  ExtractionPolicy.swift
//  database-server
//
//  Editable policy governing in-flight entity/edge creation at ingest:
//  custom ontology + extraction prompt, predicate normalization, caps, and
//  auto-edge rules with hub suppression.
//
//  The policy is global, persisted as a plist, and editable at runtime via
//  GET/PUT /v1/graph/policy. Changes are prospective — already-ingested
//  documents pick up the new policy only when explicitly re-extracted.
//

import Foundation
import Logging

struct ExtractionPolicy: Codable, Sendable, Equatable {

    struct KindDef: Codable, Sendable, Equatable {
        var name: String
        var description: String

        enum CodingKeys: String, CodingKey {
            case name, description
        }
    }

    /// Entities co-extracted from the same document get a weighted
    /// `auto:appears with` edge — cheap structural signal linking the cast of a
    /// document even when the extractor emitted no explicit relationship.
    struct CoMentionRule: Codable, Sendable, Equatable {
        var enabled: Bool = true
        var predicate: String = "appears with"
        /// Skip pairs already connected by an explicit (non-auto) relationship.
        var skipExplicitlyLinked: Bool = true
    }

    /// Ontology: the entity kinds the extractor may assign, with descriptions
    /// that are expanded into the prompt.
    var kinds: [KindDef] = ExtractionPolicy.defaultKinds
    /// Overrides the built-in extraction system prompt. `{{kinds}}` expands to
    /// the ontology listing; `{{max_entities}}`/`{{max_relationships}}` to caps.
    var promptTemplate: String?
    /// Predicate normalization: alias → canonical ("works for" → "employed by").
    var predicateAliases: [String: String] = [:]
    var maxEntities: Int = 12
    var maxRelationships: Int = 15
    var coMention: CoMentionRule? = CoMentionRule(enabled: false)
    /// Entities at/over this graph degree receive no new auto-edges (megahub guard).
    var hubDegreeCap: Int? = 24

    enum CodingKeys: String, CodingKey {
        case kinds
        case promptTemplate = "prompt_template"
        case predicateAliases = "predicate_aliases"
        case maxEntities = "max_entities"
        case maxRelationships = "max_relationships"
        case coMention = "co_mention"
        case hubDegreeCap = "hub_degree_cap"
    }

    static let defaultKinds: [KindDef] = [
        .init(name: "person", description: "A human individual."),
        .init(name: "organization", description: "A company, institution, or group."),
        .init(name: "place", description: "A geographic location."),
        .init(name: "event", description: "A happening at a point or span in time."),
        .init(name: "work", description: "A created artifact: book, paper, product, system."),
        .init(name: "concept", description: "An abstract idea, topic, or term."),
        .init(name: "other", description: "Anything that fits no other kind."),
    ]

    /// The system prompt handed to the LLM extractor, with policy placeholders expanded.
    var effectiveSystemPrompt: String {
        let kindList = kinds.map { "\($0.name) (\($0.description))" }.joined(separator: ", ")
        let kindNames = kinds.map { $0.name }.joined(separator: "|")
        let template = promptTemplate ?? """
        You extract a knowledge graph from text. Respond with ONLY a JSON object — no prose, no code fences:
        {"entities":[{"name":"...","kind":"{{kind_names}}"}],\
        "relationships":[{"subject":"...","predicate":"...","object":"..."}]}
        Allowed kinds: {{kinds}}.
        Rules: at most {{max_entities}} entities and {{max_relationships}} relationships; subject and object MUST \
        exactly match a name from entities; predicates are short lowercase verb phrases \
        ("founded","works at","part of"); keep original name casing; no duplicates.
        """
        return template
            .replacingOccurrences(of: "{{kinds}}", with: kindList)
            .replacingOccurrences(of: "{{kind_names}}", with: kindNames)
            .replacingOccurrences(of: "{{max_entities}}", with: String(maxEntities))
            .replacingOccurrences(of: "{{max_relationships}}", with: String(maxRelationships))
    }

    /// Canonicalizes a predicate through the alias map (case-insensitive keys).
    func normalizePredicate(_ predicate: String) -> String {
        let key = predicate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return predicateAliases[key] ?? key
    }

    /// Predicate namespace for policy-generated edges so they can be stripped
    /// and regenerated when the policy changes.
    static let autoPredicatePrefix = "auto:"
}

// MARK: - Store

/// Process-wide policy holder: plist-persisted, hot-swappable via the policy route.
enum ExtractionPolicyStore {
    private static let state = LockedValue<ExtractionPolicy?>(nil)
    private static let key = "graph-extraction-policy"

    static var current: ExtractionPolicy {
        if let policy = state.withLock({ $0 }) { return policy }
        let logger = Logger(label: "totem-policy")
        let loaded: ExtractionPolicy = FilePersistence(key: key, kind: .basic, logger: logger)
            .restore() ?? ExtractionPolicy()
        state.withLock { $0 = loaded }
        return loaded
    }

    static func update(_ policy: ExtractionPolicy, logger: Logger) {
        state.withLock { $0 = policy }
        FilePersistence(key: key, kind: .basic, logger: logger).save(state: policy)
    }
}
