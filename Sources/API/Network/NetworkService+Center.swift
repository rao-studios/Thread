import Foundation
import RaoStack

extension NetworkService {
    enum BaseEndpoint: String, Codable {
        case global = "api.mistral.ai"

        var apiKey: String {
            // Read on every call: RAO_HOME/keys/providers.json when the
            // launcher set RAO_HOME (a key saved in any Rao app lands here
            // with no restart), else MISTRAL_API_KEY from the environment.
            ProviderKeyStore.process.value(for: ProviderKeyStore.mistralAPIKey) ?? ""
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
