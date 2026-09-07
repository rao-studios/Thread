import SwiftUI

@MainActor
final class AppState: ObservableObject {

    // MARK: - Library state

    @Published var documents: [DatabaseDocument] = []
    @Published var uploadingFiles: [UploadingFile] = []

    // MARK: - Search state

    @Published var searchResults: [SearchResult] = []
    @Published var isSearching = false
    @Published var searchError: String?
    @Published var lastQuery = ""

    // MARK: - Server state

    @Published var serverReachable: Bool? = nil

    // MARK: - Persisted config

    @AppStorage("sewnServerURL")    var serverURL:      String = "http://127.0.0.1:8080"
    @AppStorage("threadServerURL")   var threadURL:       String = "http://127.0.0.1:8081"
    @AppStorage("sewnOwnerId")      var ownerId:        String = "database-demo"
    @AppStorage("sewnGroupId")      var groupId:        String = "demo-group"
    @AppStorage("sewnBearerToken")  var bearerToken:    String = ""
    @AppStorage("sewnRefreshToken") var refreshToken:   String = ""
    @AppStorage("sewnTokenExpiry")  var tokenExpiry:    Double = 0

    var isSignedIn: Bool { !bearerToken.isEmpty }

    // MARK: - Sign-in state

    @Published var isSigningIn = false
    @Published var signInError: String?

    // MARK: - API

    var api: DatabaseAPI {
        DatabaseAPI(
            databaseBaseURL: serverURL,
            threadBaseURL: threadURL,
            ownerId: ownerId,
            groupId: groupId,
            groupLabel: "Demo",
            bearerToken: bearerToken
        )
    }

    // MARK: - Auth

    func signIn(email: String, password: String) async {
        isSigningIn = true
        signInError = nil
        do {
            let result = try await api.signIn(email: email, password: password)
            ownerId = result.userId
            bearerToken = result.accessToken
            refreshToken = result.refreshToken
            tokenExpiry = Date().timeIntervalSince1970 + result.expiresIn
        } catch {
            signInError = error.localizedDescription
        }
        isSigningIn = false
    }

    func signOut() {
        bearerToken = ""
        refreshToken = ""
        tokenExpiry = 0
        ownerId = "database-demo"
        signInError = nil
    }

    // MARK: - Health check

    func checkHealth() async {
        serverReachable = await api.isReachable()
        if serverReachable == true {
            await loadLibrary()
        }
    }

    // MARK: - Library persistence

    func loadLibrary() async {
        do {
            let fetched = try await api.fetchLibrary()
            guard !fetched.isEmpty else { return }
            // Merge: keep any locally-uploaded docs from this session,
            // add server docs that aren't already in the list.
            let existingIds = Set(documents.map { $0.id })
            let newDocs = fetched.filter { !existingIds.contains($0.id) }
            if !newDocs.isEmpty {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    documents.append(contentsOf: newDocs)
                }
            }
        } catch {
            // Silent fail — library is a convenience; missing it doesn't block usage
        }
    }

    // MARK: - Upload

    func uploadFiles(urls: [URL]) {
        let newFiles = urls.map { UploadingFile(url: $0) }
        uploadingFiles.append(contentsOf: newFiles)
        for file in newFiles {
            let fileId = file.id
            Task { await self.processFile(id: fileId) }
        }
    }

    private func processFile(id: UUID) async {
        guard let idx = uploadingFiles.firstIndex(where: { $0.id == id }) else { return }
        let url = uploadingFiles[idx].url

        setStatus(id: id, .reading)

        let text: String
        do {
            text = try await Task.detached(priority: .userInitiated) {
                let raw = try FileReader.extractText(from: url)
                return TextSanitizer.sanitize(raw)
            }.value
        } catch {
            setStatus(id: id, .error(error.localizedDescription))
            return
        }

        guard !text.isEmpty else {
            setStatus(id: id, .error("Empty file"))
            return
        }

        setStatus(id: id, .embedding)

        do {
            let currentAPI = api
            let filename = url.lastPathComponent
            try await currentAPI.embed(text: text, filename: filename)

            let doc = DatabaseDocument(
                id: UUID().uuidString,
                name: filename,
                url: url,
                uploadedAt: Date()
            )
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                documents.append(doc)
            }
            setStatus(id: id, .done)

            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeOut(duration: 0.3)) {
                uploadingFiles.removeAll { $0.id == id }
            }
        } catch {
            setStatus(id: id, .error(error.localizedDescription))
        }
    }

    private func setStatus(id: UUID, _ status: UploadingFile.UploadStatus) {
        if let idx = uploadingFiles.firstIndex(where: { $0.id == id }) {
            uploadingFiles[idx].status = status
        }
    }

    // MARK: - Search

    func search(query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        isSearching = true
        searchError = nil
        lastQuery = q

        do {
            let currentAPI = api
            let results = try await currentAPI.search(query: q)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                searchResults = results
            }
        } catch {
            searchError = error.localizedDescription
            searchResults = []
        }
        isSearching = false
    }

    func clearSearch() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
            searchResults = []
            searchError = nil
            lastQuery = ""
        }
    }
}
