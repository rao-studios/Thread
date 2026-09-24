import Foundation

struct DatabaseRequest: Codable {
    let ownerId: String
    let group: Database.Group?
    let groups: [Database.Group]?
    /// Query entity terms for graph matching. `tags` is kept as a legacy alias;
    /// consumers should read `entities ?? tags`.
    let entities: [String]?
    let tags: [String]?
    let aggregate: Bool?
    let scope: DatabaseRequestScope?
    let requestID: String?
    /// How the query is read. `.code` selects the identifier instrument and returns
    /// only code partitions; `.text` returns only text partitions; nil is the search
    /// as it was before the field existed.
    let mediaType: MediaType?
    /// The most results to return, across documents. Nil or zero is unlimited.
    let topK: Int?

    init(ownerId: String,
         group: Database.Group? = nil,
         groups: [Database.Group]? = nil,
         entities: [String]? = nil,
         tags: [String]? = nil,
         aggregate: Bool? = nil,
         scope: DatabaseRequestScope? = nil,
         requestID: String? = nil,
         mediaType: MediaType? = nil,
         topK: Int? = nil) {
        self.ownerId = ownerId
        self.group = group
        self.groups = groups
        self.entities = entities
        self.tags = tags
        self.aggregate = aggregate
        self.scope = scope
        self.requestID = requestID
        self.mediaType = mediaType
        self.topK = topK
    }

    enum CodingKeys: String, CodingKey {
        case ownerId = "owner_id"
        case group
        case groups
        case entities
        case tags
        case aggregate
        case scope
        case requestID = "request_id"
        case mediaType = "media_type"
        case topK = "top_k"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ownerId   = try c.decode(String.self,                    forKey: .ownerId)
        group     = try c.decodeIfPresent(Database.Group.self,       forKey: .group)
        groups    = try c.decodeIfPresent([Database.Group].self,     forKey: .groups)
        entities  = try c.decodeIfPresent([String].self,         forKey: .entities)
        tags      = try c.decodeIfPresent([String].self,         forKey: .tags)
        aggregate = try c.decodeIfPresent(Bool.self,             forKey: .aggregate)
        scope     = try c.decodeIfPresent(DatabaseRequestScope.self, forKey: .scope)
        requestID = try c.decodeIfPresent(String.self,           forKey: .requestID)
        mediaType = try c.decodeIfPresent(String.self,           forKey: .mediaType).map(MediaType.init(wire:))
        topK      = try c.decodeIfPresent(Int.self,              forKey: .topK)
    }

    /// In Thread there is no auth middleware — ownerId comes directly from the body.
    /// Call this with the Hummingbird request context's id: `withRequestID(context.id)`
    func withRequestID(_ id: String) -> DatabaseRequest {
        return .init(
            ownerId: self.ownerId.lowercased(),
            group: self.group,
            groups: self.groups,
            entities: self.entities,
            tags: self.tags,
            aggregate: self.aggregate,
            scope: self.scope,
            requestID: id,
            mediaType: self.mediaType,
            topK: self.topK
        )
    }

    /// The code instrument: identifiers matched exactly, applied as a boost.
    var isCode: Bool { mediaType == .code }

    /// `topK` as a limit, or nil for no limit.
    var resultLimit: Int? { (topK ?? 0) > 0 ? topK : nil }
}

enum DatabaseRequestScope: String, Codable {
    case global
    case personal
}
