//
//  SearchRequest.swift
//  database-server
//
//  Created by Ritesh Pakala on 11/1/25.
//

import Foundation

struct SearchRequest: Codable {
    let model: String?
    let query: String
    let train: Bool
    /// Whether the one-hop graph expansion runs after the direct scan. Defaults to true.
    let expand: Bool
    let totem: DatabaseRequest

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        query = try container.decode(String.self, forKey: .query)
        train = try container.decodeIfPresent(Bool.self, forKey: .train) ?? false
        expand = try container.decodeIfPresent(Bool.self, forKey: .expand) ?? true
        totem = try container.decode(DatabaseRequest.self, forKey: .totem)
    }
}
