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

    init(ownerId: String,
         group: Database.Group? = nil,
         groups: [Database.Group]? = nil,
         entities: [String]? = nil,
         tags: [String]? = nil,
         aggregate: Bool? = nil,
         scope: DatabaseRequestScope? = nil,
         requestID: String? = nil) {
        self.ownerId = ownerId
        self.group = group
        self.groups = groups
        self.entities = entities
        self.tags = tags
        self.aggregate = aggregate
        self.scope = scope
        self.requestID = requestID
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
            requestID: id
        )
    }
}

enum DatabaseRequestScope: String, Codable {
    case global
    case personal
}
