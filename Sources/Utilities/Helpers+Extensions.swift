//  Based on: https://github.com/mzbac/swift-mlx-server

import Foundation
import Logging

typealias BaseModel = Codable & Equatable

// Encode server sent events.
func encodeSSE<T: Encodable>(response: T, logger: Logger) -> String? {
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let jsonData = try encoder.encode(response)

        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("Failed to encode SSE response to UTF-8")
            return nil
        }

        return AppConstants.sseEventHeader + jsonString + AppConstants.sseEventSeparator
    } catch {
        logger.error("Failed to encode SSE response: \(error)")
        return nil
    }
}

// MARK: - Concurrency Helpers

struct SendableValue<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Extensions

extension Array {
    func nilIfEmpty() -> Self? {
        return isEmpty ? nil : self
    }
}
