import Foundation

/// A knowledge-graph query: resolve entities by name and relationships by semantic similarity, then traverse
/// up to `hops` edges. At least one of `entity` / `query` must be present.
struct GraphRequest: Codable {
    let thread: DatabaseRequest
    /// Entity name lookup (token containment).
    let entity: String?
    /// Free-text query embedded for relationship and predicate matching.
    let query: String?
    /// Restrict matches to these entity kinds.
    let kinds: [String]?
    /// Traversal depth (0–3). Defaults to 1.
    let hops: Int?
    /// Max entities returned. Defaults to 20.
    let limit: Int?
    /// Whether to resolve linked documents. Defaults to true.
    let includeDocuments: Bool?

    enum CodingKeys: String, CodingKey {
        case thread
        case entity
        case query
        case kinds
        case hops
        case limit
        case includeDocuments = "include_documents"
    }
}
