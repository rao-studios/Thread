import Foundation

// MARK: - Search

struct SearchResult: Identifiable {
    let id: String
    let text: String
    let documentId: String
    let partitionId: String
    let ownerId: String
    let threadId: String?
    let shardIndex: Int?
}

/// The knowledge-graph context behind a search: which entities the query
/// matched, which edges the one-hop expansion crossed, and how many extra
/// documents that pulled in. The server has always returned this; the client
/// used to throw it away.
struct SearchGraphContext {
    struct Entity: Identifiable {
        let id: String
        let name: String
        let kind: String
    }

    struct Relationship: Identifiable {
        var id: String { "\(subject)|\(predicate)|\(object)" }
        let subject: String
        let predicate: String
        let object: String
        let weight: Int
    }

    let entities: [Entity]
    let relationships: [Relationship]
    let expandedDocuments: Int

    var isEmpty: Bool {
        entities.isEmpty && relationships.isEmpty && expandedDocuments == 0
    }

    init(from dto: SearchGraphDTO) {
        entities = dto.entities.map { .init(id: $0.id, name: $0.name, kind: $0.kind) }
        relationships = dto.relationships.map {
            .init(subject: $0.subject, predicate: $0.predicate, object: $0.object, weight: $0.weight)
        }
        expandedDocuments = dto.expandedDocuments
    }
}
