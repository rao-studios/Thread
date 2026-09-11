import Foundation

protocol RawRequest : Encodable {
    associatedtype Response : Codable //TODO: rename to IntermediateResponse
    associatedtype TransformedResponse : Codable & Sendable //TODO: rename to Response
    
    var ignoresEndpoint : Bool { get }
    var ignoresAuthHeader : Bool { get }
    var ignoresPercentEncoding : Bool { get }
    var path : String { get }
    var method : RequestMethod { get }
    var data : [String : Any] { get }
    var dateFormatter : DateFormatter { get }
    /// Per-request URLRequest timeout; nil = URLSession default (~60s).
    var timeoutInterval : TimeInterval? { get }

    func transform(_ publisher : AnyPublisher<Response, Error>) throws -> AnyPublisher<TransformedResponse, Error>
}

extension RawRequest {

    var timeoutInterval : TimeInterval? {
        nil
    }

    var ignoresEndpoint : Bool {
        false
    }
    
    var ignoresAuthHeader : Bool {
        false
    }
    
    var ignoresPercentEncoding : Bool {
        false
    }
    
    var data : [String : Any] {
        let coder = DictionaryEncoder()
        return (try? coder.encode(self)) ?? [:]
    }
    
    var dateFormatter: DateFormatter {
        .init()
    }
}

extension RawRequest where TransformedResponse == Response {
    
    func transform(_ publisher : AnyPublisher<Response, Error>) throws -> AnyPublisher<TransformedResponse, Error> {
        publisher
    }
    
}

