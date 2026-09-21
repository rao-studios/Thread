//
//  StackSecretMiddleware.swift
//  thread
//
//  WHAT: Local mode. When the app that launched this Thread hands it
//        AMBIENT_STACK_SECRET, every request must carry that secret in
//        X-Ambient-Secret and address this machine by loopback.
//  IN:   Ambient's LocalStackManager (sets the variable; hosted deployments
//        and dev scripts don't, and nothing here changes for them)
//  OUT:  401 without the secret; 421 for a Host that isn't loopback
//  PIN:  Keeps web pages out. A page can't send a custom header cross-site
//        without a CORS preflight, and local mode answers none; a
//        DNS-rebinding page arrives under its own Host and never learns the
//        secret. /health stays open so a launcher can ask for proof of the
//        secret without sending it.
//

import Crypto
import Foundation
import HTTPTypes
import Hummingbird

enum StackSecret {
    static let environmentKey = "AMBIENT_STACK_SECRET"
    static let headerName = HTTPField.Name("X-Ambient-Secret")!
    static let nonceHeaderName = HTTPField.Name("X-Ambient-Nonce")!
    /// Domain-separates the proof so /health is not a general HMAC oracle.
    static let proofDomain = "ambient-stack-health-v1:"

    /// Read once: the launcher sets it before exec and never changes it.
    static let value: String? = {
        let secret = ProcessInfo.processInfo.environment[environmentKey] ?? ""
        return secret.isEmpty ? nil : secret
    }()

    static var isLocalMode: Bool { value != nil }

    /// Constant-time, so a wrong guess learns nothing from how long it took.
    static func matches(_ presented: String?, secret: String? = value) -> Bool {
        guard let secret, let presented else { return false }
        let expected = Array(secret.utf8)
        let given = Array(presented.utf8)
        guard expected.count == given.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices {
            difference |= expected[index] ^ given[index]
        }
        return difference == 0
    }

    /// 16...128 hex characters (either case).
    static func isWellFormedNonce(_ nonce: String) -> Bool {
        let bytes = nonce.utf8
        guard (16...128).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }
    }

    /// Lowercase hex of HMAC-SHA256(key: UTF-8(secret), message:
    /// UTF-8(proofDomain + nonce)), nonce exactly as received.
    static func proof(nonce: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data((proofDomain + nonce).utf8), using: key)
        let digits = Array("0123456789abcdef".utf8)
        var hex: [UInt8] = []
        hex.reserveCapacity(SHA256.byteCount * 2)
        for byte in code {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: hex, as: UTF8.self)
    }

    /// What /health says: ("open", nil) when no secret is configured;
    /// ("proof", proof) for a well-formed nonce; ("proof", nil) otherwise.
    /// The secret itself never answers.
    static func healthAnswer(nonce: String?, secret: String? = value) -> (stack: String, proof: String?) {
        guard let secret else { return ("open", nil) }
        guard let nonce, isWellFormedNonce(nonce) else { return ("proof", nil) }
        return ("proof", proof(nonce: nonce, secret: secret))
    }

    /// `127.0.0.1`, `localhost` or `[::1]`, with or without a port.
    static func isLoopback(authority: String?) -> Bool {
        guard let authority, !authority.isEmpty else { return false }
        let host: Substring
        if authority.hasPrefix("[") {
            host = authority.split(separator: "]", maxSplits: 1).first.map { $0.dropFirst() } ?? ""
        } else {
            host = authority.split(separator: ":", maxSplits: 1).first ?? ""
        }
        return ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    /// The whole local-mode check for one request; nil when it may pass.
    static func refusal(authority: String?, presented: String?, secret: String? = value) -> HTTPError? {
        guard secret != nil else { return nil }
        guard isLoopback(authority: authority) else {
            return HTTPError(.misdirectedRequest, message: "This server answers on loopback only")
        }
        guard matches(presented, secret: secret) else {
            return HTTPError(.unauthorized, message: "Missing or wrong X-Ambient-Secret")
        }
        return nil
    }
}

struct StackSecretMiddleware<Context: RequestContext>: RouterMiddleware {
    var secret: String? = StackSecret.value

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if request.uri.path == "/health" {
            return try await next(request, context)
        }
        if let refusal = StackSecret.refusal(
            authority: request.head.authority,
            presented: request.headers[StackSecret.headerName],
            secret: secret) {
            throw refusal
        }
        return try await next(request, context)
    }
}
