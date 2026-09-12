import Foundation

/// Typed client for the Thread node's HTTP API.
///
/// Every route funnels through `send`, which is what makes the wire log
/// complete and keeps the `thread` request-wrapper key spelled in exactly one
/// place (see `ThreadScope`). Thread has no authentication — `owner_id` in the
/// body is the only identity there is.
actor ThreadAPI {

    let baseURL: String
    let ownerId: String
    let groupId: String
    let groupLabel: String

    private let log: WireLog?

    init(baseURL: String,
         ownerId: String,
         groupId: String,
         groupLabel: String = "Demo",
         log: WireLog? = nil) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.ownerId = ownerId
        self.groupId = groupId
        self.groupLabel = groupLabel
        self.log = log
    }

    // MARK: - Scope helpers

    /// The `thread` wrapper every scoped route requires.
    private func scope(group: WireGroup? = nil, scope: String? = nil) -> ThreadScope {
        ThreadScope(ownerId: ownerId, group: group, scope: scope)
    }

    /// The group this client indexes into. Sent on write paths only.
    private var defaultGroup: WireGroup? {
        guard !groupId.isEmpty else { return nil }
        return WireGroup(id: groupId, label: groupLabel, ownerId: ownerId, documents: [], access: "available")
    }

    // MARK: - Health

    func health() async throws -> HealthDTO {
        try await send("GET", "/health", body: Optional<Never>.none, as: HealthDTO.self)
    }

    /// Liveness against the Thread node itself. Deliberately not pointed at a
    /// mothership: a standalone node is the common case and must not appear
    /// unreachable just because no Sewn instance is running.
    func isReachable() async -> Bool {
        (try? await health()) != nil
    }

    // MARK: - Search

    func search(query: String,
                scope searchScope: String = "personal",
                expand: Bool = true) async throws -> SearchResponseDTO {
        let body = SearchRequestDTO(
            query: query,
            expand: expand,
            thread: scope(scope: searchScope)
        )
        return try await send("POST", "/v1/search", body: body, as: SearchResponseDTO.self)
    }

    // MARK: - Indexing

    /// One document staged for indexing. The per-document arrays on the batch
    /// route align 1:1 with `inputs` by index, so these are zipped apart below.
    struct IndexDocument {
        var text: String
        var name: String?
        var tags: [String]
        var entities: [WireEntityInput]
        var relationships: [WireRelationInput]
        var mediaType: String?

        init(text: String,
             name: String? = nil,
             tags: [String] = [],
             entities: [WireEntityInput] = [],
             relationships: [WireRelationInput] = [],
             mediaType: String? = nil) {
            self.text = text
            self.name = name
            self.tags = tags
            self.entities = entities
            self.relationships = relationships
            self.mediaType = mediaType
        }
    }

    /// Index a batch in a single call.
    ///
    /// A 200 means "embedded and enqueued", not "searchable" — enrichment and
    /// the write queue run detached after the response returns.
    @discardableResult
    func index(_ documents: [IndexDocument],
               sanitize: Bool = true) async throws -> IndexResponseDTO {
        let body = IndexRequestDTO(
            inputs: documents.map { .string($0.text) },
            sanitize: sanitize,
            names: documents.contains(where: { $0.name != nil })
                ? documents.map(\.name) : nil,
            tags: documents.contains(where: { !$0.tags.isEmpty })
                ? documents.map(\.tags) : nil,
            entities: documents.contains(where: { !$0.entities.isEmpty })
                ? documents.map(\.entities) : nil,
            relationships: documents.contains(where: { !$0.relationships.isEmpty })
                ? documents.map(\.relationships) : nil,
            mediaType: documents.compactMap(\.mediaType).first,
            thread: scope(group: defaultGroup)
        )
        return try await send("POST", "/v1/batch/embeddings", body: body, as: IndexResponseDTO.self)
    }

    // MARK: - Library

    func library(includeAvailable: Bool = true) async throws -> [WireGroup] {
        let body = LibraryRequestDTO(ownerId: ownerId, includeAvailable: includeAvailable)
        let response = try await send("POST", "/v1/library", body: body, as: LibraryResponseDTO.self)
        return response.groups
    }

    /// The groups containing a document — not the document itself. There is no
    /// HTTP route that reads document content back; that comes from the store.
    func groupsContaining(documentId: String) async throws -> [WireGroup] {
        let body = LibraryDocumentRequestDTO(documentId: documentId)
        let response = try await send("POST", "/v1/library/document", body: body, as: LibraryResponseDTO.self)
        return response.groups
    }

    // MARK: - Graph

    /// Passing neither `entity` nor `query` is browse mode: the server returns
    /// the top `limit` entities by mention count, not the whole graph.
    func graph(entity: String? = nil,
               query: String? = nil,
               kinds: [String]? = nil,
               hops: Int = 1,
               limit: Int = 50,
               includeDocuments: Bool = true) async throws -> GraphResponseDTO {
        let body = GraphRequestDTO(
            thread: scope(),
            entity: entity?.isEmpty == true ? nil : entity,
            query: query?.isEmpty == true ? nil : query,
            kinds: kinds,
            hops: max(0, min(3, hops)),
            limit: limit,
            includeDocuments: includeDocuments
        )
        return try await send("POST", "/v1/graph", body: body, as: GraphResponseDTO.self)
    }

    // MARK: - Graph mutation

    func renameEntity(id: String, name: String) async throws -> GraphMutationResponseDTO {
        try await send("POST", "/v1/graph/entity/rename",
                       body: GraphEntityMutationDTO(id: id, name: name),
                       as: GraphMutationResponseDTO.self)
    }

    func setEntityKind(id: String, kind: String) async throws -> GraphMutationResponseDTO {
        try await send("POST", "/v1/graph/entity/set-kind",
                       body: GraphEntityMutationDTO(id: id, kind: kind),
                       as: GraphMutationResponseDTO.self)
    }

    func mergeEntities(from: String, into: String) async throws -> GraphMutationResponseDTO {
        try await send("POST", "/v1/graph/entity/merge",
                       body: GraphMergeDTO(from: from, into: into),
                       as: GraphMutationResponseDTO.self)
    }

    /// Note: the server returns `success: true` unconditionally here, even for
    /// an unknown id. Callers cannot treat the response as proof of deletion —
    /// re-query the graph and reconcile.
    func deleteEntity(id: String) async throws -> GraphMutationResponseDTO {
        try await send("POST", "/v1/graph/entity/delete",
                       body: GraphEntityMutationDTO(id: id),
                       as: GraphMutationResponseDTO.self)
    }

    /// Same caveat as `deleteEntity` — always reports success.
    func deleteRelationship(id: String) async throws -> GraphMutationResponseDTO {
        try await send("POST", "/v1/graph/relationship/delete",
                       body: GraphRelationshipDeleteDTO(id: id),
                       as: GraphMutationResponseDTO.self)
    }

    /// Blocks until the LLM extractor finishes — can take a while.
    func reExtract(documentId: String) async throws -> GraphMutationResponseDTO {
        try await send("POST", "/v1/graph/re-extract",
                       body: GraphReExtractDTO(documentId: documentId, thread: scope()),
                       as: GraphMutationResponseDTO.self)
    }

    // MARK: - Extraction policy

    func policy() async throws -> ExtractionPolicyDTO {
        try await send("GET", "/v1/graph/policy", body: Optional<Never>.none, as: ExtractionPolicyDTO.self)
    }

    func updatePolicy(_ policy: ExtractionPolicyDTO) async throws -> ExtractionPolicyDTO {
        try await send("PUT", "/v1/graph/policy", body: policy, as: ExtractionPolicyDTO.self)
    }

    // MARK: - Clear (destructive)

    /// Wipes this node's partition table, graph and registry.
    func clear() async throws -> ClearResponseDTO {
        try await send("POST", "/v1/clear",
                       body: ClearRequestDTO(confirm: true),
                       as: ClearResponseDTO.self)
    }

    // MARK: - Transport

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // The server encodes with JSONEncoder.dateEncodingStrategy = .iso8601,
        // so `created_at` fails to decode without this.
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// The single funnel: encode, call, log, decode.
    private func send<Body: Encodable, Response: Decodable>(
        _ method: String,
        _ path: String,
        body: Body?,
        as: Response.Type
    ) async throws -> Response {
        guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 180

        var payload: Data?
        if let body {
            do {
                payload = try Self.encoder.encode(body)
            } catch {
                throw APIError.encoding(String(describing: error))
            }
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let pretty = payload.flatMap(JSONPretty.format)
        let entryId = await log?.begin(method: method, url: url.absoluteString, requestBody: pretty)
        let started = Date()

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await URLSession.shared.data(for: request)
            guard let h = response as? HTTPURLResponse else { throw APIError.badResponse(0, "") }
            data = d
            http = h
        } catch let error as APIError {
            if let entryId { await log?.finish(entryId, status: nil, responseBody: nil,
                                               duration: Date().timeIntervalSince(started),
                                               failure: error.localizedDescription) }
            throw error
        } catch {
            let message = error.localizedDescription
            if let entryId { await log?.finish(entryId, status: nil, responseBody: nil,
                                               duration: Date().timeIntervalSince(started),
                                               failure: message) }
            throw APIError.transport(message)
        }

        let duration = Date().timeIntervalSince(started)
        let responseText = JSONPretty.format(data)

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.serverMessage(from: data, status: http.statusCode)
            if let entryId { await log?.finish(entryId, status: http.statusCode,
                                               responseBody: responseText, duration: duration,
                                               failure: message) }
            throw APIError.badResponse(http.statusCode, message)
        }

        if let entryId { await log?.finish(entryId, status: http.statusCode,
                                           responseBody: responseText, duration: duration) }

        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Hummingbird wraps 4xx messages in `{"error":{"message":…}}`. A 500 has an
    /// empty body, so say that rather than reporting a decode failure.
    private static func serverMessage(from data: Data, status: Int) -> String {
        if let envelope = try? JSONDecoder().decode(WireErrorEnvelope.self, from: data) {
            return envelope.error.message
        }
        if data.isEmpty {
            return status >= 500
                ? "empty body (the server logs the cause)"
                : "empty body"
        }
        return String(data: data, encoding: .utf8) ?? "unreadable body"
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case invalidURL
        case transport(String)
        case encoding(String)
        case decoding(String)
        case badResponse(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid server URL. Check Settings."
            case .transport(let message):
                return "Couldn't reach the node: \(message)"
            case .encoding(let message):
                return "Couldn't encode the request: \(message)"
            case .decoding(let message):
                return "Couldn't decode the response: \(message)"
            case .badResponse(let code, let message):
                return message.isEmpty ? "Server error \(code)" : "Server error \(code): \(message)"
            }
        }
    }
}
