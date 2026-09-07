import Foundation

// MARK: - Library

struct DatabaseDocument: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL?
    let uploadedAt: Date
}

struct UploadingFile: Identifiable {
    let id: UUID
    let name: String
    let url: URL
    var status: UploadStatus

    init(url: URL) {
        self.id = UUID()
        self.name = url.lastPathComponent
        self.url = url
        self.status = .reading
    }

    enum UploadStatus: Equatable {
        case reading
        case embedding
        case done
        case error(String)

        var label: String {
            switch self {
            case .reading:        return "Reading…"
            case .embedding:      return "Embedding…"
            case .done:           return "Done"
            case .error(let msg): return msg
            }
        }

        var isError: Bool {
            if case .error = self { return true }
            return false
        }

        var isDone: Bool { self == .done }
    }
}

// MARK: - Search

struct SearchResult: Identifiable {
    let id: String
    let text: String
    let documentId: String
    let partitionId: String
    let ownerId: String
    let distance: Float?
    let threadId: String?
    let shardIndex: Int?
}
