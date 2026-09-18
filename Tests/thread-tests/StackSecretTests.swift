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

    func testOnlyTheExactSecretMatches() {
        XCTAssertTrue(StackSecret.matches("s3cret", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("s3cres", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("s3cret-and-more", secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches(nil, secret: "s3cret"))
        XCTAssertFalse(StackSecret.matches("anything", secret: nil))
    }

    func testHealthSaysWhoseServerThisIs() {
        XCTAssertEqual(StackSecret.verdict(of: "s", secret: "s"), "matched")
        XCTAssertEqual(StackSecret.verdict(of: "x", secret: "s"), "mismatched")
        XCTAssertEqual(StackSecret.verdict(of: nil, secret: "s"), "mismatched")
        XCTAssertEqual(StackSecret.verdict(of: "s", secret: nil), "open")
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

    private func app(secret: String?) -> some ApplicationProtocol {
        let router = Router()
        router.middlewares.add(StackSecretMiddleware<BasicRequestContext>(secret: secret))
        router.get("health") { _, _ in "ok" }
        router.post("/v1/clear") { _, _ in "cleared" }
        return Application(router: router)
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
                XCTAssertEqual(response.status, .ok, "a launcher must be able to ask whose server this is")
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
