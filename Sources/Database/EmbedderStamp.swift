//
//  EmbedderStamp.swift
//  thread
//
//  WHAT: Which embedder wrote this node's vectors, kept beside the table
//        (`embedder-<nodeId>`), and whether the embedder running now matches it.
//  WHY:  Vectors from two models are not comparable, even at the same width: a
//        query embedded by one scores garbage against documents embedded by
//        another, and graph vectors are reused forever. Nothing else records the
//        model, so without this a model change is silent.
//  PIN:  An empty table takes the running embedder's stamp. A mismatch is reported
//        (/health, the log) and holds the table still — no filing, no search — never
//        repaired here: the way out is the original model back, or a Clear, which
//        re-stamps.
//

import Foundation

struct EmbedderStamp: Codable, Equatable, Sendable {
    /// e.g. `voyage-4@1024`, `mistral-embed@1024`.
    var vectorSpace: String
    var model: String
    var revision: String?
    var stampedAt: Date
}

/// How the table's vectors relate to the embedder running now.
enum IndexState: Equatable, Sendable {
    /// Written by this vector space (or empty, and stamped for it).
    case matches
    /// Written by another vector space.
    case mismatch(stamped: String)
    /// Vectors from before stamps existed: their space is unknown.
    case unstamped

    var label: String {
        switch self {
        case .matches: return "matches"
        case .mismatch: return "mismatch"
        case .unstamped: return "unstamped"
        }
    }

    var stampedSpace: String? {
        if case .mismatch(let stamped) = self { return stamped }
        return nil
    }
}

extension Database {
    nonisolated var embedderStampStore: FilePersistence {
        FilePersistence(key: "embedder-\(nodeId)", kind: .basic, logger: logger.base)
    }

    /// Compare the stored stamp with the running embedder, stamping an empty table.
    /// Call once the table is restored (`initializationTask`).
    @discardableResult
    func reconcileEmbedder(vectorSpace: String, model: String, revision: String?) -> IndexState {
        let current = EmbedderStamp(vectorSpace: vectorSpace, model: model, revision: revision, stampedAt: Date())
        runningEmbedder = current
        let isEmpty = (table?.keys.isEmpty ?? true)
        let stored: EmbedderStamp? = embedderStampStore.restore()
        let state = Self.indexState(stored: stored, running: vectorSpace, tableIsEmpty: isEmpty)
        if state == .matches, stored?.vectorSpace != vectorSpace {
            embedderStampStore.save(state: current)
        }
        indexState = state
        switch state {
        case .matches:
            break
        case .mismatch(let stamped):
            logger.error(
                "Embedder",
                "This index was built with \(stamped); the embedder now is \(vectorSpace). Search against it is meaningless until it is cleared and rebuilt.",
                service: .database)
        case .unstamped:
            logger.error(
                "Embedder",
                "This index predates embedder stamps; its vectors may not be \(vectorSpace). Clear it to rebuild.",
                service: .database)
        }
        return state
    }

    /// The rule, alone: an empty table always matches; otherwise the stored space decides.
    static func indexState(stored: EmbedderStamp?, running: String, tableIsEmpty: Bool) -> IndexState {
        if tableIsEmpty { return .matches }
        guard let stored else { return .unstamped }
        return stored.vectorSpace == running ? .matches : .mismatch(stamped: stored.vectorSpace)
    }

    /// Why vectors may not be written to or searched in this table now, or nil when
    /// they may. While another model's index is loaded, a filing would mix two
    /// spaces (so switching back would no longer be clean) and a search would
    /// return noise — Sewn would put it in front of the model as context.
    func vectorRefusal() -> String? {
        let running = runningEmbedder?.vectorSpace ?? "this model"
        switch indexState {
        case .mismatch(let stamped):
            return "this index was built with \(stamped), not \(running): switch back, or clear it to rebuild"
        case .unstamped:
            return "this index predates embedder stamps and may not be \(running): clear it to rebuild"
        case .matches, .none:
            return nil
        }
    }

    /// After a clear the table is empty again: stamp it for the running embedder.
    func restampAfterClear() {
        guard var current = runningEmbedder else {
            try? FileManager.default.removeItem(at: embedderStampStore.url)
            indexState = nil
            return
        }
        current.stampedAt = Date()
        embedderStampStore.save(state: current)
        indexState = .matches
    }
}
