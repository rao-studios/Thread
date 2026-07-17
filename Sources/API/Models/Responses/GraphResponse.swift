import Foundation

struct GraphResponseEntity: Codable {
    let id: String
    let name: String
    let kind: String
    let score: Float
    let mentionCount: Int
    let documentIds: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case score
        case mentionCount = "mention_count"
        case documentIds = "document_ids"
    }
}

struct GraphResponseRelationship: Codable {
    let id: String
    let subjectId: String
    let predicate: String
    let objectId: String
    let weight: Int
    let documentIds: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case subjectId = "subject_id"
        case predicate
        case objectId = "object_id"
        case weight
        case documentIds = "document_ids"
    }
}

struct GraphResponseDocument: Codable {
    let id: String
    let name: String?
    let ownerId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownerId = "owner_id"
    }
}

struct GraphResponseStats: Codable {
    let entityCount: Int
    let relationshipCount: Int

    enum CodingKeys: String, CodingKey {
        case entityCount = "entity_count"
        case relationshipCount = "relationship_count"
    }
}

struct GraphResponse: Codable {
    var object: String = "graph"
    let entities: [GraphResponseEntity]
    let relationships: [GraphResponseRelationship]
    let documents: [GraphResponseDocument]
    let stats: GraphResponseStats?
}
