//
//  AppConstants.swift
//  thread
//
//  Created by Ritesh Pakala on 10/26/25.
//  Based on: https://github.com/mzbac/swift-mlx-server

import Foundation

enum AppConstants {
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 8_081
    static let sseDoneMessage = "data: [DONE]\n\n"
    static let sseEventHeader = "data: "
    static let sseEventSeparator = "\n\n"
}
