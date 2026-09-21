//
//  NodeIdentitySourceTests.swift
//  thread-tests
//
//  Where a fixed node id comes from: `--node-id` first, THREAD_NODE_ID in the
//  environment as the fallback (a launcher's hand-off, kept out of argv), and
//  anything that is not a UUID is reported rather than silently dropped.
//

import Foundation
import XCTest
@testable import thread

final class NodeIdentitySourceTests: XCTestCase {

    private let a = UUID()
    private let b = UUID()

    func testArgvWinsOverTheEnvironment() {
        let result = NodeIdentity.override(argument: a.uuidString, environment: ["THREAD_NODE_ID": b.uuidString])
        XCTAssertEqual(result.uuid, a)
        XCTAssertNil(result.rejected)
    }

    func testTheEnvironmentIsTheFallback() {
        let result = NodeIdentity.override(argument: nil, environment: ["THREAD_NODE_ID": " \(b.uuidString)\n"])
        XCTAssertEqual(result.uuid, b, "trimmed")
        XCTAssertNil(result.rejected)
        XCTAssertEqual(NodeIdentity.environmentKey, "THREAD_NODE_ID")
    }

    func testNothingGivenMeansNothingFixed() {
        let result = NodeIdentity.override(argument: nil, environment: [:])
        XCTAssertNil(result.uuid)
        XCTAssertNil(result.rejected)
        let blank = NodeIdentity.override(argument: "", environment: ["THREAD_NODE_ID": "  "])
        XCTAssertNil(blank.uuid)
        XCTAssertNil(blank.rejected)
    }

    func testAValueThatIsNotAUUIDIsRejectedNotGuessed() {
        let argv = NodeIdentity.override(argument: "not-a-uuid", environment: ["THREAD_NODE_ID": b.uuidString])
        XCTAssertNil(argv.uuid, "a bad argv value does not fall through to the environment")
        XCTAssertEqual(argv.rejected, "not-a-uuid")
        let env = NodeIdentity.override(argument: nil, environment: ["THREAD_NODE_ID": "nope"])
        XCTAssertNil(env.uuid)
        XCTAssertEqual(env.rejected, "nope")
    }
}
