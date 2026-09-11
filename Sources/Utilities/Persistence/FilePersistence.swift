//
//  FilePersistence.swift
//  Granite
//
//  Created by Ritesh Pakala on 12/10/21.
//  Copyright © 2020 Stoic Collective, LLC. All rights reserved.
//

import Foundation
import Logging

/// FilePersistence is a basic document-file read-write utility class.
final class FilePersistence : AnyPersistence, @unchecked Sendable {
    
    let key : String
    
    let url : URL
    
    public var isRestoring: Bool = false
    
    public var hasRestored: Bool = false
    
    let logger: Logger
    
    required init(key: String,
                  kind: PersistenceKind,
                  logger: Logger) {
        let rootPath: URL = FilePersistence.getDefaultURL()
        
        self.key = key
        
        self.url = rootPath.appendingPathComponent(key)
        self.logger = logger
        
        do {
            try FileManager.default.createDirectory(at: rootPath,
                                                     withIntermediateDirectories: true,
                                                     attributes: nil)
        }
        catch let error {
            logger.error(.init(stringLiteral: error.localizedDescription))
        }
    }
    
    /// Process-wide data root override, set once at startup from `--data-dir`
    /// or `THREAD_DATA_DIR`. Nil means `~/Documents/thread-db`. Written once
    /// before any persistence exists, then only read.
    nonisolated(unsafe) private static var dataDirectoryOverride: URL?

    /// Point every FilePersistence at `path` (tilde expanded, created with
    /// intermediates). Nil or empty restores the default. Call before any
    /// persistence is constructed — instances resolve the root in `init`.
    @discardableResult
    static func configure(dataDirectory path: String?) -> URL {
        if let path, !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            dataDirectoryOverride = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            dataDirectoryOverride = nil
        }
        let root = getDefaultURL()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The data root: the configured override, else `~/Documents/thread-db`.
    static func getDefaultURL() -> URL {
        if let override = dataDirectoryOverride { return override }
        let value = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return value.appendingPathComponent("thread-db")
    }
    
    func save<State>(state: State,
                     logger: Logger? = nil) where State : Codable {
        
        let encoder = PropertyListEncoder()
        
        do {
            let data = try encoder.encode(state)
            
            if !FileManager.default.fileExists(atPath: self.url.path()) {
                let directory = self.url.deletingLastPathComponent()
                try FileManager
                    .default
                    .createDirectory(at: directory,
                                     withIntermediateDirectories: true,
                                     attributes: nil)
                
                // self.logger.info("Creating file at: \(self.url.path())")
                
                _ = FileManager
                    .default
                    .createFile(
                        atPath: self.url.path(),
                        contents: data
                    )
            } else {
                // self.logger.info("Writing data to \(self.url)")
                try data.write(to: self.url, options: .atomic)
            }
            
            // self.logger.info("Wrote chunk to: \(self.url.absoluteString)")
        }
        catch let error {
            self.logger
                .error(
                    .init(stringLiteral: error.localizedDescription)
                )
        }
    }
    
    func restore<State>() -> State? where State : Codable {
        let decoder = PropertyListDecoder()

        guard FileManager.default.fileExists(atPath: url.path()) else {
            return nil
        }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            logger.error("\(key) failed to read data.")
            return nil
        }

        do {
            hasRestored = true
            return try decoder.decode(State.self, from: data)
        }
        catch let error {
            logger.error("\(key) | error: \(error.localizedDescription)")
            return nil
        }
    }
  
    func purge() {
        try? FileManager.default.removeItem(at: url)
    }
}
