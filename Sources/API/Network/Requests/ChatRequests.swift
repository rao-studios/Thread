//
//  ChatRequests.swift
//  Database
//
//  Minimal Mistral chat-completions shape — used by the Mistral-API graph
//  extraction provider. Mirrors EmbeddingRequests.
//

import Foundation

extension Requests {
    struct Chat {}
}

extension Requests.Chat {
    struct Get: NetworkRequest {
        typealias Response = Result

        var path: String { "v1/chat/completions" }

        var method: RequestMethod { .post }

        let model: String
        let messages: [Message]
        let maxTokens: Int?
        let temperature: Double?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case maxTokens = "max_tokens"
            case temperature
        }

        init(
            model: String,
            messages: [Message],
            maxTokens: Int? = nil,
            temperature: Double? = nil
        ) {
            self.model = model
            self.messages = messages
            self.maxTokens = maxTokens
            self.temperature = temperature
        }

        struct Message: Codable {
            let role: String
            let content: String
        }

        struct Result: Codable {
            let choices: [Choice]
            let usage: Usage?

            struct Choice: Codable {
                let message: Message
            }

            struct Usage: Codable {
                let promptTokens: Int?
                let completionTokens: Int?
                let totalTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case promptTokens = "prompt_tokens"
                    case completionTokens = "completion_tokens"
                    case totalTokens = "total_tokens"
                }
            }
        }
    }
}
