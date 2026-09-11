import Foundation

actor DatabaseAPI {
    let databaseBaseURL: String    // Database mothership — search, library
    let threadBaseURL: String   // Thread node — embed
    let ownerId: String
    let groupId: String
    let groupLabel: String
    let bearerToken: String

    init(databaseBaseURL: String, threadBaseURL: String, ownerId: String, groupId: String, groupLabel: String = "Demo", bearerToken: String = "") {
        self.databaseBaseURL = databaseBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadBaseURL = threadBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ownerId = ownerId
        self.groupId = groupId
        self.groupLabel = groupLabel
        self.bearerToken = bearerToken
    }

    // MARK: - Health check (Database mothership)

    func isReachable() async -> Bool {
        guard let url = URL(string: "\(databaseBaseURL)/health") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Batch embeddings (Thread node)

    func embed(text: String, filename: String? = nil) async throws {
        guard let url = URL(string: "\(threadBaseURL)/v1/batch/embeddings") else {
            throw APIError.invalidURL
        }

        let body = EmbedRequest(
            inputs: [[text]],
            sanitize: true,
            names: filename.map { [$0] },
            database: EmbedRequest.DatabaseParams(
                ownerId: ownerId,
                group: EmbedRequest.GroupParams(
                    id: groupId, label: groupLabel, ownerId: ownerId, access: "available", documents: []
                )
            )
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(0) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.badResponse(http.statusCode, msg)
        }
    }

    // MARK: - Sign in (Database mothership)

    struct SignInResult {
        let userId: String
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
    }

    func signIn(email: String, password: String) async throws -> SignInResult {
        guard let url = URL(string: "\(databaseBaseURL)/v1/auth/sign-in") else {
            throw APIError.invalidURL
        }
        struct Body: Encodable { let email: String; let password: String }
        struct Response: Decodable {
            let userId: String
            let accessToken: String
            let refreshToken: String
            let expiresIn: Double
            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Body(email: email, password: password))
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(0) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.badResponse(http.statusCode, msg)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return SignInResult(userId: decoded.userId, accessToken: decoded.accessToken,
                            refreshToken: decoded.refreshToken, expiresIn: decoded.expiresIn)
    }

    // MARK: - Search (Database mothership)

    func search(query: String) async throws -> [SearchResult] {
        guard let url = URL(string: "\(threadBaseURL)/v1/search") else {
            throw APIError.invalidURL
        }

        let body = SearchRequest(
            query: query,
            database: SearchRequest.DatabaseParams(ownerId: ownerId, scope: "personal")
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !bearerToken.isEmpty {
            req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(0) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.badResponse(http.statusCode, msg)
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.texts.enumerated().map { i, text in
            let ref = decoded.references.indices.contains(i) ? decoded.references[i] : nil
            return SearchResult(
                id: "result-\(i)",
                text: text,
                documentId: ref?.id ?? "",
                partitionId: ref?.partitionId ?? "",
                ownerId: ref?.ownerId ?? "",
                distance: nil,
                threadId: ref?.threadId,
                shardIndex: ref?.shardIndex
            )
        }
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case invalidURL
        case badResponse(Int, String = "")

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid server URL. Check Settings."
            case .badResponse(let code, let msg):
                return "Server error \(code)\(msg.isEmpty ? "" : ": \(msg.prefix(120))")"
            }
        }
    }

    // MARK: - Codable types (private)

    private struct EmbedRequest: Encodable {
        let inputs: [[String]]
        let sanitize: Bool
        let names: [String]?
        let database: DatabaseParams

        struct DatabaseParams: Encodable {
            let ownerId: String
            let group: GroupParams
            enum CodingKeys: String, CodingKey { case ownerId = "owner_id", group }
        }

        struct GroupParams: Encodable {
            let id, label, ownerId, access: String
            let documents: [String]
            enum CodingKeys: String, CodingKey { case id, label, ownerId = "owner_id", documents, access }
        }
    }

    // MARK: - Library (Thread node — documents live where they were indexed)

    func fetchLibrary() async throws -> [DatabaseDocument] {
        guard let url = URL(string: "\(threadBaseURL)/v1/library") else {
            throw APIError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(LibraryRequest(ownerId: ownerId, includeAvailable: true))
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(0) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.badResponse(http.statusCode, msg)
        }

        let decoded = try JSONDecoder().decode(LibraryResponse.self, from: data)

        var seen = Set<String>()
        var documents: [DatabaseDocument] = []
        for group in decoded.groups {
            for doc in group.documents {
                guard seen.insert(doc.id).inserted else { continue }
                documents.append(DatabaseDocument(
                    id: doc.id,
                    name: doc.name ?? String(doc.id.prefix(8)),
                    url: nil,
                    uploadedAt: Date.now
                ))
            }
        }
        return documents
    }

    private struct LibraryRequest: Encodable {
        let ownerId: String
        let includeAvailable: Bool
        enum CodingKeys: String, CodingKey {
            case ownerId = "owner_id"
            case includeAvailable = "include_available"
        }
    }

    private struct LibraryResponse: Decodable {
        let groups: [LibraryGroup]

        struct LibraryGroup: Decodable {
            let documents: [LibraryDocument]
        }

        struct LibraryDocument: Decodable {
            let id: String
            let name: String?
        }
    }

    private struct SearchRequest: Encodable {
        let query: String
        let database: DatabaseParams

        struct DatabaseParams: Encodable {
            let ownerId: String
            let scope: String
            enum CodingKeys: String, CodingKey { case ownerId = "owner_id", scope }
        }
    }

    private struct SearchResponse: Decodable {
        let texts: [String]
        let references: [Reference]

        struct Reference: Decodable {
            let id: String
            let partitionId: String
            let ownerId: String
            let threadId: String?
            let shardIndex: Int?
            enum CodingKeys: String, CodingKey {
                case id
                case partitionId = "partition_id"
                case ownerId     = "owner_id"
                case threadId     = "thread_id"
                case shardIndex  = "shard_index"
            }
        }
    }
}
