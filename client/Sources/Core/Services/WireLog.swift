import Foundation

/// A rolling record of every HTTP call the client makes.
///
/// This is the difference between an API console and a debugging client: when
/// a request fails you want the bytes that went out, not a localized error
/// string. Entries are recorded in two phases so a slow call (re-extract
/// blocks until the LLM extractor finishes) is visible while it is in flight.
@MainActor
final class WireLog: ObservableObject {

    struct Entry: Identifiable {
        let id = UUID()
        let started: Date
        let method: String
        let url: String
        let requestBody: String?

        var status: Int?
        var responseBody: String?
        var duration: TimeInterval?
        var failure: String?

        var isInFlight: Bool { status == nil && failure == nil }

        var isError: Bool {
            if failure != nil { return true }
            if let status { return !(200..<300).contains(status) }
            return false
        }

        /// A runnable reproduction of this request.
        var curl: String {
            var parts = ["curl -s -X \(method) '\(url)'"]
            if requestBody != nil {
                parts.append("-H 'content-type: application/json'")
            }
            if let body = requestBody {
                // Single-quote the payload, escaping any embedded single quotes.
                let escaped = body.replacingOccurrences(of: "'", with: #"'\''"#)
                parts.append("-d '\(escaped)'")
            }
            return parts.joined(separator: " \\\n  ")
        }
    }

    /// Newest first — the log is read from the top.
    @Published private(set) var entries: [Entry] = []

    private let limit = 200

    func begin(method: String, url: String, requestBody: String?) -> UUID {
        let entry = Entry(started: Date(), method: method, url: url, requestBody: requestBody)
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        return entry.id
    }

    func finish(_ id: UUID,
                status: Int?,
                responseBody: String?,
                duration: TimeInterval,
                failure: String? = nil) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].status = status
        entries[idx].responseBody = responseBody
        entries[idx].duration = duration
        entries[idx].failure = failure
    }

    func clear() { entries.removeAll() }
}

// MARK: - Pretty printing

enum JSONPretty {
    /// Re-encode JSON with sorted keys and indentation for display. Returns the
    /// original text when the body isn't JSON (a 500 returns an empty body, and
    /// Hummingbird's 404 returns nothing at all).
    static func format(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ),
            let text = String(data: pretty, encoding: .utf8)
        else {
            return String(data: data, encoding: .utf8)
        }
        return text
    }
}
