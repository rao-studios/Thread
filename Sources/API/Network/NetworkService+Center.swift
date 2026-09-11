import Foundation

extension NetworkService {
    enum BaseEndpoint: String, Codable {
        case global = "api.mistral.ai"

        var apiKey: String {
            // Read MISTRAL_API_KEY from environment; fall back to empty string.
            ProcessInfo.processInfo.environment["MISTRAL_API_KEY"] ?? ""
        }
    }

    struct Configuration: Codable {
        var base: BaseEndpoint
        var endpoint: String {
            "https://\(base.rawValue)/"
        }
    }

    enum NetworkError: LocalizedError {
        case invalidRequestUrl
        case invalidResponse
        case unauthorized
        case backend(ErrorResponse)
        case noMockDataAvailable

        var errorDescription: String? { reason }

        var reason: String {
            switch self {
            case .invalidRequestUrl:    return "Invalid request URL."
            case .invalidResponse:      return "Invalid response data."
            case .unauthorized:         return "Insufficient rights to perform the request."
            case .backend(let r):       return r.message
            case .noMockDataAvailable:  return "No mock data available."
            }
        }
    }
}
