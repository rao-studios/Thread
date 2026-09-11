import Foundation
import Logging

/// Actor-based network service for making HTTP requests
actor NetworkService {
    var configuration: Configuration
    
    let logger: Logger
    
    init(logger: Logger, base endpoint: BaseEndpoint = .global) {
        self.logger = logger
        self.configuration = Configuration(base: endpoint)
    }
}

