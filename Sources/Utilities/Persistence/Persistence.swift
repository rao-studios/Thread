//
//  Persistence.swift
//  Granite
//
//  Created by Ritesh Pakala on 12/10/21.
//  Copyright © 2020 Stoic Collective, LLC. All rights reserved.
//

import Foundation
import Logging

/// Base protocol or interface to create Persistent classes.
protocol AnyPersistence : AnyObject {
    var key : String { get }
    
    var isRestoring : Bool { get set }
    var hasRestored : Bool { get set }
    
    var logger: Logger { get }
    
    init(key : String, kind: PersistenceKind, logger: Logger)
    
    func save<State : Codable>(state : State)
    func restore<State : Codable>() -> State?
    func purge()
}

enum PersistenceKind {
    case basic
    // App Groups, group ID as string, not necessary for servers.
    case group(String)
}

extension AnyPersistence {
    var key : String {
        "Empty"
    }
    
    func save<State>(state: State) where State : Codable {}
    
    func restore<State>() -> State? where State : Codable {
        return nil
    }
    
    func purge() {}
}
