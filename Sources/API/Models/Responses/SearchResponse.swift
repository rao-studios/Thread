import Foundation

/// Matched / traversed entity surfaced alongside a fused search.
struct SearchGraphEntity: Codable {
    let id: String
    let name: String
    let kind: String
}

/// A relationship traversed by the one-hop graph expansion.
struct SearchGraphRelationship: Codable {
    let subject: String
    let predicate: String
    let object: String
    let weight: Int
}

/// The knowledge-graph context for a fused search: which entities the query matched and
/// which relationships the one-hop expansion traversed to pull in related documents.
struct SearchResponseGraph: Codable {
    let entities: [SearchGraphEntity]
    let relationships: [SearchGraphRelationship]
    let expandedDocuments: Int

    enum CodingKeys: String, CodingKey {
        case entities
        case relationships
        case expandedDocuments = "expanded_documents"
    }
}

struct SearchResponse: Codable {
    var object: String = "list"
    let texts: [String]
    let references: [Database.DocumentReference]
    let graph: SearchResponseGraph?

    enum CodingKeys: String, CodingKey {
        case object
        case texts
        case references
        case graph
    }
}
