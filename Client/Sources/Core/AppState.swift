import SwiftUI

@MainActor
final class AppState: ObservableObject {

    // MARK: - Search state

    @Published var searchResults: [SearchResult] = []
    @Published var searchGraph: SearchGraphContext?
    @Published var isSearching = false
    @Published var searchError: String?
    @Published var lastQuery = ""

    // MARK: - Server state

    @Published var serverReachable: Bool? = nil

    // MARK: - Persisted config

    /// The Thread node. This is the server the client actually talks to.
    @AppStorage("threadServerURL")  var threadURL:     String = "http://127.0.0.1:8081"
    /// Optional Sewn mothership — only used for account sign-in, never for health.
    @AppStorage("sewnServerURL")    var serverURL:     String = "http://127.0.0.1:8080"
    @AppStorage("sewnOwnerId")      var ownerId:       String = "database-demo"
    @AppStorage("sewnGroupId")      var groupId:       String = "demo-group"
    @AppStorage("sewnBearerToken")  var bearerToken:   String = ""
    @AppStorage("sewnRefreshToken") var refreshToken:  String = ""
    @AppStorage("sewnTokenExpiry")  var tokenExpiry:   Double = 0
    /// Where the node keeps its on-disk state. Empty means the server's own
    /// default, `~/Documents/thread-db`. Read-only; the client never writes here.
    @AppStorage("threadDataDirectory") var dataDirectory: String = ""

    var isSignedIn: Bool { !bearerToken.isEmpty }

    // MARK: - Sign-in state

    @Published var isSigningIn = false
    @Published var signInError: String?

    // MARK: - Wire log

    /// Every HTTP call the client makes, newest first.
    let wireLog = WireLog()

    // MARK: - API

    var api: ThreadAPI {
        ThreadAPI(
            baseURL: threadURL,
            ownerId: ownerId,
            groupId: groupId,
            groupLabel: "Demo",
            log: wireLog
        )
    }

    // MARK: - Health

    /// Liveness of the **Thread node**, not the mothership. A standalone node is
    /// the common case, and gating this on Sewn meant the library never loaded.
    func checkHealth() async {
        serverReachable = await api.isReachable()
    }

    // MARK: - Search

    func search(query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        isSearching = true
        searchError = nil
        lastQuery = q

        do {
            let response = try await api.search(query: q)

            let results = response.texts.enumerated().map { i, text -> SearchResult in
                let ref = response.references.indices.contains(i) ? response.references[i] : nil
                return SearchResult(
                    id: "result-\(i)",
                    text: text,
                    documentId: ref?.id ?? "",
                    partitionId: ref?.partitionId ?? "",
                    ownerId: ref?.ownerId ?? "",
                    threadId: ref?.threadId,
                    shardIndex: ref?.shardIndex
                )
            }

            let graph = response.graph.map { SearchGraphContext(from: $0) }

            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                searchResults = results
                searchGraph = graph
            }
        } catch {
            searchError = error.localizedDescription
            searchResults = []
            searchGraph = nil
        }
        isSearching = false
    }

    func clearSearch() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
            searchResults = []
            searchGraph = nil
            searchError = nil
            lastQuery = ""
        }
    }

    // MARK: - Sewn account (optional)

    /// Sign-in is a **mothership** call, not a Thread one. Thread has no
    /// authentication at all — `owner_id` from the request body is the only
    /// identity. This exists solely to borrow an account id as the owner.
    func signIn(email: String, password: String) async {
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }

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

        let base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base + "/v1/auth/sign-in") else {
            signInError = "Invalid mothership URL."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        do {
            request.httpBody = try JSONEncoder().encode(Body(email: email, password: password))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                signInError = String(data: data, encoding: .utf8) ?? "Sign-in failed."
                return
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            ownerId = decoded.userId
            bearerToken = decoded.accessToken
            refreshToken = decoded.refreshToken
            tokenExpiry = Date().timeIntervalSince1970 + decoded.expiresIn
        } catch {
            signInError = error.localizedDescription
        }
    }

    func signOut() {
        bearerToken = ""
        refreshToken = ""
        tokenExpiry = 0
        ownerId = "database-demo"
        signInError = nil
    }
}
