//
//  StackSecretTests.swift
//  thread-tests
//
//  Local mode: a Thread an app launched for itself answers only requests that
//  carry that app's secret and name this machine by loopback. Without the
//  secret configured nothing changes — hosted and dev servers stay open. On a
//  shared ~/.rao stack a Thread is still one app's: it proves and accepts that
//  app's secret alone.
//

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import RaoStack
import XCTest
@testable import thread

final class StackSecretTests: XCTestCase {

    /// Known answers, shared with Ambient's, Sewn's and RaoStack's tests.
    /// Computed with
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
        let mode = StackMode.single(secret: "s3cret", app: nil)
        XCTAssertEqual(mode.healthAnswer(nonce: KAT.nonce, requestedApp: nil).proof, KAT.proofForS3cret)

        let unchallenged = StackMode.single(secret: "s", app: nil).healthAnswer(nonce: nil, requestedApp: nil)
        XCTAssertEqual(unchallenged.stack, "proof")
        XCTAssertNil(unchallenged.proof)

        for malformed in ["zz", "", String(repeating: "ab", count: 100)] {
            let answer = StackMode.single(secret: "s", app: nil).healthAnswer(nonce: malformed, requestedApp: nil)
            XCTAssertEqual(answer.stack, "proof", malformed)
            XCTAssertNil(answer.proof, "a malformed nonce earns no proof: \(malformed)")
        }

        let open = StackMode.open.healthAnswer(nonce: KAT.nonce, requestedApp: nil)
        XCTAssertEqual(open.stack, "open")
        XCTAssertNil(open.proof)

        let uppercase = mode.healthAnswer(nonce: KAT.nonce.uppercased(), requestedApp: nil)
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
        XCTAssertEqual(StackMode.single(secret: "s", app: nil).admit(authority: "evil.example:47080", presented: "s"),
                       .notLoopback)
        XCTAssertEqual(StackMode.open.admit(authority: "evil.example", presented: nil), .admitted(nil),
                       "no secret configured: nothing is refused")
    }

    func testAThreadAcceptsOnlyItsOwnAppsSecret() {
        let craftThread = StackMode.single(secret: "craft-secret", app: .craft)
        XCTAssertEqual(craftThread.admit(authority: "127.0.0.1:48081", presented: "craft-secret"), .admitted(.craft))
        XCTAssertEqual(craftThread.admit(authority: "127.0.0.1:48081", presented: "ambient-secret"), .badSecret)
        let answer = craftThread.healthAnswer(nonce: KAT.nonce, requestedApp: "ambient")
        XCTAssertEqual(answer.app, .craft, "a Thread proves its own app whatever the challenge names")
    }

    // MARK: - Through the middleware and the real /health route

    private func app(mode: StackMode) -> some ApplicationProtocol {
        let router = Router(context: ThreadRequestContext.self)
        router.middlewares.add(StackSecretMiddleware<ThreadRequestContext>(mode: mode))
        registerHealthRoute(router, stack: mode)
        router.post("/v1/clear") { _, _ in "cleared" }
        return Application(router: router)
    }

    func testHealthAnswersAChallengeWithoutTheSecret() async throws {
        try await app(mode: .single(secret: "s3cret", app: .ambient)).test(.router) { client in
            try await client.execute(
                uri: "/health", method: .get,
                headers: [.ambientNonce: KAT.nonce]) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"proof\":\"\(KAT.proofForS3cret)\""), body)
                XCTAssertTrue(body.contains("\"app\":\"ambient\""), body)
                XCTAssertTrue(body.contains("\"contract\":\(RaoContract.version)"), body)
                XCTAssertFalse(body.contains("s3cret"), "the secret never crosses on /health: \(body)")
            }
            try await client.execute(
                uri: "/health", method: .get,
                headers: [.ambientSecret: "s3cret"]) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"stack\":\"proof\""), body)
                XCTAssertFalse(body.contains("\"proof\":"), "the legacy header earns nothing, not even null: \(body)")
            }
        }
    }

    func testAnOpenThreadsHealthIsUnchanged() async throws {
        try await app(mode: .open).test(.router) { client in
            try await client.execute(uri: "/health", method: .get, headers: [.ambientNonce: KAT.nonce]) { response in
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"stack\":\"open\""), body)
                XCTAssertFalse(body.contains("\"proof\""), body)
                XCTAssertFalse(body.contains("\"app\""), body)
                XCTAssertFalse(body.contains("\"contract\""), body)
            }
        }
    }

    func testWithoutTheSecretNothingButHealthAnswers() async throws {
        try await app(mode: .single(secret: "s", app: nil)).test(.router) { client in
            try await client.execute(uri: "/v1/clear", method: .post) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(
                uri: "/v1/clear", method: .post,
                headers: [.ambientSecret: "wrong"]) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok, "a launcher must be able to ask for proof of the secret")
            }
        }
    }

    func testWithTheSecretTheRouteAnswers() async throws {
        try await app(mode: .single(secret: "s", app: nil)).test(.router) { client in
            try await client.execute(
                uri: "/v1/clear", method: .post,
                headers: [.ambientSecret: "s"]) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testWithNoSecretConfiguredEverythingIsOpenAsBefore() async throws {
        try await app(mode: .open).test(.router) { client in
            try await client.execute(uri: "/v1/clear", method: .post) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }
}

final class RaoHomeLaunchTests: XCTestCase {

    func testTheDataDirectoryOrder() {
        XCTAssertEqual(ThreadServer.resolveDataDirectory(argument: "/flag", environment: ["THREAD_DATA_DIR": "/env"]), "/flag")
        XCTAssertEqual(ThreadServer.resolveDataDirectory(argument: nil, environment: ["THREAD_DATA_DIR": "/env"]), "/env")
        XCTAssertEqual(ThreadServer.resolveDataDirectory(
            argument: nil, environment: ["RAO_HOME": "/r", "RAO_APP": "craft"]), "/r/apps/craft/thread-db")
        XCTAssertNil(ThreadServer.resolveDataDirectory(argument: nil, environment: ["RAO_HOME": "/r"]),
                     "no app: FilePersistence's default")
        XCTAssertNil(ThreadServer.resolveDataDirectory(argument: nil, environment: [:]))
    }

    func testTheMistralKeyFallsBackToTheEnvironment() {
        let store = ProviderKeyStore(home: nil, environment: { ["MISTRAL_API_KEY": "from-env"] })
        XCTAssertEqual(store.value(for: ProviderKeyStore.mistralAPIKey), "from-env")
        XCTAssertEqual(ProviderKeyStore.process.isFileBacked, ProcessInfo.processInfo.environment["RAO_HOME"] != nil,
                       "a server reads the shared key file only when its launcher set RAO_HOME")
    }
}
