//
//  GraphStore+Identifiers.swift
//  database-server
//
//  WHAT: The code instrument's entity match. A code search names identifiers
//        (`posix_spawn`, `Session.send`, `NSApplication`); code-aware clients
//        deposit them namespaced (`type:posix_spawn`, `sym:Session.send`).
//        Matching is exact on the name with the namespace stripped — no
//        tokenising into words, no embeddings.
//  PIN:  `matchEntities` and `matchRelationships` are the prose instrument and
//        stay exactly as they are; nothing here is reached without
//        `media_type = "code"`.
//

import Foundation

extension GraphStore {

    /// Prefixes a code-aware client puts on an entity's name. Stripped before matching.
    static let identifierNamespaces = ["sym:", "type:", "memory:"]

    /// Kinds that name a place, not an identifier: a file path or a module is never what
    /// a code search is after, and a module is a hub every importing file touches.
    static let nonIdentifierKinds: Set<String> = ["file", "module"]

    /// The identifier an entity names, or nil when it names none.
    ///
    /// `type:posix_spawn` → `posix_spawn`; `sym:Session.send` → `Session.send`;
    /// `sym:fn Repl.handle(_:)` (a memory's scope, written with its kind) → `Repl.handle`;
    /// `sym:Session+ext@42` (an extension) → `Session`. A name with whitespace and no
    /// namespace is prose (`Marie Curie`) and never an identifier.
    static func identifier(of entity: Entity) -> String? {
        guard !nonIdentifierKinds.contains(entity.kind) else { return nil }
        var name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let namespace = identifierNamespaces.first(where: { name.hasPrefix($0) }) {
            name.removeFirst(namespace.count)
            // A scope written as "<kind> <name>" names the last word.
            if let last = name.split(whereSeparator: \.isWhitespace).last { name = String(last) }
        }
        guard !name.contains(where: \.isWhitespace) else { return nil }
        if let parenthesis = name.firstIndex(of: "(") { name = String(name[..<parenthesis]) }
        if let ext = name.range(of: "+ext@") { name = String(name[..<ext.lowerBound]) }
        return name.isEmpty ? nil : name
    }

    /// Entities whose identifier matches one of `terms`, best first.
    ///
    /// - exact name: 1.0 (`Session.send` names `sym:Session.send`)
    /// - a dotted term that ends the name: 0.8 (`Session.send` names `sym:App.Session.send`)
    /// - a single word that is the name's last component: 0.6 (`send` names `sym:Session.send`)
    ///
    /// Case-sensitive: `Process` and `process` are different identifiers. An entity in more
    /// than `hubDegreeCap` documents is skipped — `type:String` names nothing in particular.
    func matchIdentifiers(_ terms: [String], hubDegreeCap: Int, limit: Int = 32) -> [(entity: Entity, score: Float)] {
        let wanted = terms.map { ($0, $0.split(separator: ".").map(String.init)) }.filter { !$0.1.isEmpty }
        guard !wanted.isEmpty else { return [] }
        // Every rule needs the last components to agree, so that is the cheap first test.
        let lastComponents = Set(wanted.compactMap { $0.1.last })

        var matches: [(entity: Entity, score: Float)] = []
        for entity in entities.values {
            guard entity.documentIds.count <= hubDegreeCap, let name = Self.identifier(of: entity) else { continue }
            let components = name.split(separator: ".").map(String.init)
            guard let last = components.last, lastComponents.contains(last) else { continue }
            var best: Float = 0
            for (term, termComponents) in wanted where termComponents.last == last {
                if term == name {
                    best = max(best, 1.0)
                } else if termComponents.count >= 2, components.count > termComponents.count,
                          Array(components.suffix(termComponents.count)) == termComponents {
                    best = max(best, 0.8)
                } else if termComponents.count == 1 {
                    best = max(best, 0.6)
                }
            }
            if best > 0 { matches.append((entity, best)) }
        }
        return matches
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                // A declaration lives in fewer documents than the references to it.
                if lhs.entity.documentIds.count != rhs.entity.documentIds.count {
                    return lhs.entity.documentIds.count < rhs.entity.documentIds.count
                }
                return lhs.entity.name < rhs.entity.name
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The identifiers a code search names: the request's entities first, then those in its
    /// text — backticked spans, dotted paths, snake_case and CamelCase words. Plain words and
    /// numbers are not identifiers. Deduplicated in order.
    static func identifierTerms(queryText: String, entities: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            var term = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`'\" \t\n.,;:?!"))
            if let parenthesis = term.firstIndex(of: "(") { term = String(term[..<parenthesis]) }
            guard !term.isEmpty, !term.contains(where: \.isWhitespace), term.contains(where: \.isLetter),
                  seen.insert(term).inserted else { return }
            out.append(term)
        }
        for entity in entities { add(entity) }
        // Backticked spans are the odd segments between backticks.
        let segments = queryText.split(separator: "`", omittingEmptySubsequences: false)
        for (index, segment) in segments.enumerated() where index % 2 == 1 && index < segments.count - 1 {
            add(String(segment))
        }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()[]{}<>,;\"'`"))
        for token in queryText.components(separatedBy: separators) {
            let word = token.trimmingCharacters(in: CharacterSet(charactersIn: ".:?!"))
            if looksLikeIdentifier(word) { add(word) }
        }
        return out
    }

    /// `Session.send`, `posix_spawn`, `NSApplication`, `runBlocking` — and not `kill`,
    /// `Session` or `2026`, which could as well be English.
    static func looksLikeIdentifier(_ word: String) -> Bool {
        guard let first = word.first, first.isLetter || first == "_" else { return false }
        guard word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else { return false }
        if word.contains(".") { return word.split(separator: ".").count >= 2 }
        if word.contains("_") { return true }
        return word.dropFirst().contains(where: \.isUppercase)
    }
}
