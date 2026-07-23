//
//  EmbeddingRequests.swift
//  Database
//
//  Created by Ritesh Pakala on 10/28/25.
//

import Foundation

extension Requests {
    struct Embedding {}
}

extension Requests.Embedding {
    struct Get: NetworkRequest {
        typealias Response = Result

        var path: String { "v1/embeddings" }

        var method: RequestMethod { .post }

        /// A hung embedding call otherwise stalls a chat search for the ~60s
        /// URLSession default; embeds normally return in well under a second.
        var timeoutInterval: TimeInterval? { 10 }
        
        let input: [String]
        let model: String
        let encodingFormat: String
//        let outputDimension: Int
//        let outputDType: String

        enum CodingKeys: String, CodingKey {
            case input
            case model
            case encodingFormat = "encoding_format"
//            case outputDimension = "output_dimension"
//            case outputDType = "output_dtype"
        }
        
        init(
            input: [String],
            model: String = "mistral-embed",
            encodingFormat: String = "float"
//            outputDimension: Int = 4096,
//            outputDType: String = "float"
        ) {
            self.input = input
            self.model = model
            self.encodingFormat = encodingFormat
//            self.outputDimension = outputDimension
//            self.outputDType = outputDType
        }
        
        struct Result: Codable {
            let id: String?
            let object: String
            let data: [EmbeddingData]
            let model: String
            let usage: Usage

            struct EmbeddingData: Codable {
                let object: String
                let embedding: [Float]
                let index: Int
            }

            struct Usage: Codable {
                let promptAudioSeconds: Double?
                let promptTokens: Int
                let totalTokens: Int
                let completionTokens: Int
                let requestCount: Int?
                let promptTokenDetails: [String: Int]?

                enum CodingKeys: String, CodingKey {
                    case promptAudioSeconds = "prompt_audio_seconds"
                    case promptTokens = "prompt_tokens"
                    case totalTokens = "total_tokens"
                    case completionTokens = "completion_tokens"
                    case requestCount = "request_count"
                    case promptTokenDetails = "prompt_token_details"
                }
            }
        }
    }
}
