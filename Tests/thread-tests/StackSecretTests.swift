//
//  StackSecretTests.swift
//  thread-tests
//
//  Local mode: a Thread an app launched for itself answers only requests that
//  carry that app's secret and name this machine by loopback. Without the
//  secret configured nothing changes — hosted and dev servers stay open.
//

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import thread

final class StackSecretTests: XCTestCase {

    /// Known answers, shared with Ambient's tests. Computed with
    /// `printf '%s' 'ambient-stack-health-v1:<nonce>' | openssl dgst -sha256 -hmac '<secret>'`.
    private enum KAT {
        static let nonce = "000102030405060708090a0b0c0d0e0f"
        static let proofForS3cret = "eb9c34a43319f28ce0a8af801edaf4e6f7d588ed4c16d8edf05e4ed6db53272c"
        static let proofForOther = "320c7f0d1afe5b81c3875afe27948389026503d31477a92543a13e7ef1843ba2"
    }

    func testOnlyTheExactSecretMatches() {
        XCTAssertTrue(StackSecret.matches("s3cret", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("s3cres", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("s3cret-and-more", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches(nil, secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("anything", secret: nil))
    }

    func testHealthProvesTheSecretForANonce() {
        XCTAssertEqual(StackSecret.proof(nonce: KAT.nonce, secret: "s3cret"), KAT.proofForS3cret)

        let unchallenged = StackSecret.healthAnswer(nonce: nil, secret: "s")
        XCTAssertEqual(unchallenged.stack, "proof")
        XCTAssertNil(unchallenged.proof)

        for malformed in ["zz", "", String(repeating: "ab", count: 100)] {
            let answer = StackSecret.healthAnswer(nonce: malformed, secret: "s")
            XCTAssertEqual(answer.stack, "proof", malformed)
            XCTAssertNil(answer.proof, "a malformed nonce earns no proof: \(malformed)")
        }

        let open = StackSecret.healthAnswer(nonce: KAT.nonce, secret: nil)
        XCTAssertEqual(open.stack, "open")
        XCTAssertNil(open.proof)

        let uppercase = StackSecret.healthAnswer(nonce: KAT.nonce.uppercased(), secret: "s3cret")
        XCTAssertEqual(uppercase.stack, "proof")
        XCTAssertNotNil(uppercase.proof, "either case is a well-formed nonce")
        XCTAssertNotEqual(uppercase.proof, KAT.proofForS3cret, "the proof covers the nonce exactly as received")
    }

    func testTheProofIsNotTheSecret() {
        let proof = StackSecret.proof(nonce: KAT.nonce, secret: "s3cret")
        XCTAssertEqual(proof.count, 64)
        XCTAssertTrue(proof.allSatisfy { "0123456789abcdef".contains($0) }, proof)
        XCTAssertNotEqual(proof, "s3cret")
        XCTAssertEqual(StackSecret.proof(nonce: KAT.nonce, secret: "other"), KAT.proofForOther)
    }

    func testOnlyLoopbackHostsAreAnswered() {
        for host in ["127.0.0.1:47080", "localhost:47080", "LOCALHOST", "[::1]:47080", "127.0.0.1"] {
            XCTAssertTrue(StackSecret.isLoopback(authority: host), host)
        }
        for host in ["evil.example:47080", "127.0.0.1.evil.example", "192.168.1.4:47080", "", "[::2]:1"] {
            XCTAssertFalse(StackSecret.isLoopback(authority: host), host)
        }
        XCTAssertFalse(StackSecret.isLoopback(authority: nil))
    }

    func testARebindingPageIsRefusedEvenWithTheSecret() {
        let refusal = StackSecret.refusal(authority: "evil.example:47080", presented: "s", secret: "s")
        XCTAssertEqual(refusal?.status, .misdirectedRequest)
        XCTAssertNil(StackSecret.refusal(authority: "evil.example", presented: nil, secret: nil),
                     "no secret configured: nothing is refused")
    }

    /// The shape /health really sends, so the test sees it through the middleware.
    private struct HealthShape: ResponseCodable {
        let stack: String
        let proof: String?
    }

    private func app(secret: String?) -> some ApplicationProtocol {
        let router = Router()
        router.middlewares.add(StackSecretMiddleware<BasicRequestContext>(secret: secret))
        router.get("health") { request, _ in
            let answer = StackSecret.healthAnswer(
                nonce: request.headers[StackSecret.nonceHeaderName], secret: secret)
            return HealthShape(stack: answer.stack, proof: answer.proof)
        }
        router.post("/v1/clear") { _, _ in "cleared" }
        return Application(router: router)
    }

    func testHealthAnswersAChallengeWithoutTheSecret() async throws {
        try await app(secret: "s3cret").test(.router) { client in
            try await client.execute(
                uri: "/health", method: .get,
                headers: [StackSecret.nonceHeaderName: KAT.nonce]) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"proof\":\"\(KAT.proofForS3cret)\""), body)
                XCTAssertFalse(body.contains("s3cret"), "the secret never crosses on /health: \(body)")
            }
            try await client.execute(
                uri: "/health", method: .get,
                headers: [StackSecret.headerName: "s3cret"]) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"stack\":\"proof\""), body)
                XCTAssertFalse(body.contains("\"proof\":"), "the legacy header earns nothing, not even null: \(body)")
            }
        }
    }

    func testWithoutTheSecretNothingButHealthAnswers() async throws {
        try await app(secret: "s").test(.router) { client in
            try await client.execute(uri: "/v1/clear", method: .post) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(
                uri: "/v1/clear", method: .post,
                headers: [StackSecret.headerName: "wrong"]) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok, "a launcher must be able to ask for proof of the secret")
            }
        }
    }

    func testWithTheSecretTheRouteAnswers() async throws {
        try await app(secret: "s").test(.router) { client in
            try await client.execute(
                uri: "/v1/clear", method: .post,
                headers: [StackSecret.headerName: "s"]) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testWithNoSecretConfiguredEverythingIsOpenAsBefore() async throws {
        try await app(secret: nil).test(.router) { client in
            try await client.execute(uri: "/v1/clear", method: .post) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }
}
