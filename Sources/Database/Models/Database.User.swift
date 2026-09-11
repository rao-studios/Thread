//
//  Database.USer.swift
//  database-server
//
//  Created by Ritesh Pakala Rao on 12/15/25.
//

import Foundation

extension Database {
    struct User: Codable {
        var groups: [Database.Group]
    }
}
