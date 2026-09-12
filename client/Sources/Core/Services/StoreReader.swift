import Foundation

/// Reads a Thread node's on-disk state.
///
/// This is the second lane, and the only one that can show document text,
/// per-document stats, the registry, or the whole graph — none of which the
/// HTTP API exposes. It is **read-only by design**, and works with the server
/// stopped.
///
/// Every read can fail softly: a decode error is returned as a value, never
/// thrown away and never fatal, because the models here mirror server-internal
/// types that can drift.
actor StoreReader {

    /// One node's state. A single directory can hold several — stores are
    /// scoped by node id, while `documents/` is shared between them.
    struct NodeSnapshot {
        let nodeId: String
        let isCurrent: Bool
        var registry: StoreRegistry?
        var graph: StoreGraph?
        var table: StoreTable?
        var registryError: String?
        var graphError: String?
        var tableError: String?
        /// When the newest of the three files was last written. On-disk state
        /// lags memory by up to the server's ~1s flush debounce.
        var modified: Date?

        var documentCount: Int { registry?.documentIds.count ?? table?.keys.count ?? 0 }
        var groupCount: Int { registry?.groups.count ?? 0 }
        var ownerCount: Int { registry?.owners.count ?? 0 }
        var availableCount: Int { registry?.availableDocumentIds.count ?? 0 }
        var entityCount: Int { graph?.entities.count ?? 0 }
        var relationshipCount: Int { graph?.relationships.count ?? 0 }
        var predicateCount: Int { graph?.predicates.count ?? 0 }

        var errors: [String] {
            [registryError, graphError, tableError].compactMap { $0 }
        }
    }

    struct DirectorySnapshot {
        let url: URL
        var currentNodeId: String?
        var nodes: [NodeSnapshot] = []
        var policy: ExtractionPolicyDTO?
        var error: String?
    }

    private let decoder = PropertyListDecoder()

    /// The server's default root: `--data-dir` > `THREAD_DATA_DIR` >
    /// `~/Documents/thread-db`.
    static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thread-db")
    }

    static func resolve(_ path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultDirectory }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    // MARK: - Directory

    func load(directory url: URL) -> DirectorySnapshot {
        var snapshot = DirectorySnapshot(url: url)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            snapshot.error = "No directory at \(url.path)"
            return snapshot
        }

        // `node-id` is a bare UTF-8 UUID string, not a plist.
        if let data = try? Data(contentsOf: url.appendingPathComponent("node-id")),
           let text = String(data: data, encoding: .utf8) {
            snapshot.currentNodeId = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []

        // A directory can hold several co-located nodes. Union the ids seen
        // across all three store prefixes so a partially-written node still lists.
        //
        // The id must parse as a UUID: `graph-extraction-policy` also starts
        // with "graph-" but is the global policy, not a node.
        var ids = Set<String>()
        for name in contents {
            for prefix in ["table-", "graph-", "registry-"] where name.hasPrefix(prefix) {
                let candidate = String(name.dropFirst(prefix.count))
                guard UUID(uuidString: candidate) != nil else { continue }
                ids.insert(candidate)
            }
        }

        snapshot.nodes = ids.sorted().map { id in
            node(id: id, in: url, isCurrent: id == snapshot.currentNodeId)
        }

        // The policy is global, not node-scoped.
        snapshot.policy = decode(ExtractionPolicyDTO.self,
                                 at: url.appendingPathComponent("graph-extraction-policy")).value

        if snapshot.nodes.isEmpty && snapshot.error == nil {
            snapshot.error = "No Thread node state in \(url.lastPathComponent)"
        }
        return snapshot
    }

    private func node(id: String, in root: URL, isCurrent: Bool) -> NodeSnapshot {
        var snapshot = NodeSnapshot(nodeId: id, isCurrent: isCurrent)

        let registryURL = root.appendingPathComponent("registry-\(id)")
        let graphURL = root.appendingPathComponent("graph-\(id)")
        let tableURL = root.appendingPathComponent("table-\(id)")

        let registry = decode(StoreRegistry.self, at: registryURL)
        snapshot.registry = registry.value
        snapshot.registryError = registry.error

        let graph = decode(StoreGraph.self, at: graphURL)
        snapshot.graph = graph.value
        snapshot.graphError = graph.error

        let table = decode(StoreTable.self, at: tableURL)
        snapshot.table = table.value
        snapshot.tableError = table.error

        snapshot.modified = [registryURL, graphURL, tableURL]
            .compactMap(modificationDate)
            .max()

        return snapshot
    }

    // MARK: - Documents

    /// Document metadata from `documents/{id}`.
    func document(id: String, in root: URL) -> StoreDocument? {
        decode(StoreDocument.self, at: root.appendingPathComponent("documents/\(id)")).value
    }

    /// The partition text for a document, from `documents/{id}-parts`.
    ///
    /// Content files are shared across co-located nodes rather than
    /// node-scoped, so this works regardless of which node is selected.
    func partitions(documentId: String, in root: URL) -> Result<[StorePartition], StoreError> {
        let url = root.appendingPathComponent("documents/\(documentId)-parts")
        let outcome = decode([StorePartition].self, at: url)
        if let value = outcome.value { return .success(value) }
        return .failure(StoreError(message: outcome.error ?? "No partition file for this document."))
    }

    // MARK: - Decoding

    struct StoreError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Decode one plist, converting any failure into a message.
    ///
    /// A missing file is not an error — a node that has never flushed a graph
    /// simply has no graph file.
    private func decode<T: Decodable>(_ type: T.Type, at url: URL) -> (value: T?, error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (nil, nil)
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return (nil, "\(url.lastPathComponent): unreadable or empty")
        }
        do {
            return (try decoder.decode(type, from: data), nil)
        } catch {
            // Model drift lands here — the server renamed a property and the
            // mirror in StoreModels is stale. Say which file and why rather
            // than showing the node as empty.
            return (nil, "\(url.lastPathComponent): \(describe(error))")
        }
    }

    private func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, _):
            return "missing key “\(key.stringValue)”"
        case .typeMismatch(let type, let context):
            return "type mismatch for \(type) at \(path(context))"
        case .valueNotFound(let type, let context):
            return "missing value for \(type) at \(path(context))"
        case .dataCorrupted(let context):
            return "corrupted: \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private func path(_ context: DecodingError.Context) -> String {
        let parts = context.codingPath.map(\.stringValue)
        return parts.isEmpty ? "root" : parts.joined(separator: ".")
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
