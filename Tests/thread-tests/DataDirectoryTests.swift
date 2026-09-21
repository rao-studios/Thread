//
//  DataDirectoryTests.swift
//  thread-tests
//
//  The storage root is process-wide and set once at startup from
//  `--data-dir` / `THREAD_DATA_DIR`. These tests prove the seam: configure
//  moves every FilePersistence and node-id under the chosen directory, and
//  nil restores the default. Reset in tearDown so other tests keep their root.
//

import Foundation
import Logging
import XCTest
@testable import thread

final class DataDirectoryTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-data-dir-\(UUID().uuidString)")
    }

    override func tearDown() {
        FilePersistence.configure(dataDirectory: nil)
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testConfigureMovesTheRootAndCreatesIt() {
        let root = FilePersistence.configure(dataDirectory: tempRoot.path)
        XCTAssertEqual(root.standardizedFileURL.path, tempRoot.standardizedFileURL.path)
        XCTAssertEqual(FilePersistence.getDefaultURL().standardizedFileURL.path, tempRoot.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.path))

        let store = FilePersistence(key: "probe/value", kind: .basic, logger: Logger(label: "test"))
        XCTAssertTrue(store.url.path.hasPrefix(tempRoot.standardizedFileURL.path))
        store.save(state: ["hello": 1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
    }

    /// A root with a space, like Craft's `~/Library/Application Support/Craft/thread-db`:
    /// save must create the file, restore must read it back, and a nested key
    /// (a document's `-parts`) must land too.
    func testARootWithASpacePersistsAndRestores() {
        let spaced = tempRoot.appendingPathComponent("Application Support/thread-db")
        FilePersistence.configure(dataDirectory: spaced.path)
        let logger = Logger(label: "test")

        let table = FilePersistence(key: "table-probe", kind: .basic, logger: logger)
        table.save(state: ["hello": 1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: table.url.path(percentEncoded: false)), "created under the real path")
        let restored: [String: Int]? = FilePersistence(key: "table-probe", kind: .basic, logger: logger).restore()
        XCTAssertEqual(restored, ["hello": 1])

        let parts = FilePersistence(key: "documents/craft-abc/Sources/A+B.swift@v1-parts", kind: .basic, logger: logger)
        parts.save(state: ["x"])
        table.save(state: ["hello": 2])   // the overwrite path
        let again: [String: Int]? = FilePersistence(key: "table-probe", kind: .basic, logger: logger).restore()
        XCTAssertEqual(again, ["hello": 2])
        let nested: [String]? = FilePersistence(key: "documents/craft-abc/Sources/A+B.swift@v1-parts", kind: .basic, logger: logger).restore()
        XCTAssertEqual(nested, ["x"])
    }

    func testTildeIsExpanded() {
        let root = FilePersistence.configure(dataDirectory: "~/thread-data-dir-tilde-probe")
        XCTAssertFalse(root.path.contains("~"))
        XCTAssertTrue(root.path.hasPrefix(NSHomeDirectory()))
        try? FileManager.default.removeItem(at: root)
    }

    func testNodeIdentityLivesUnderTheConfiguredRoot() {
        FilePersistence.configure(dataDirectory: tempRoot.path)
        let first = NodeIdentity.load(logger: Logger(label: "test"))
        let second = NodeIdentity.load(logger: Logger(label: "test"))
        XCTAssertEqual(first.nodeId, second.nodeId, "a fresh root must keep a stable identity")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("node-id").path))
    }

    func testNilRestoresTheDefault() {
        FilePersistence.configure(dataDirectory: tempRoot.path)
        FilePersistence.configure(dataDirectory: nil)
        XCTAssertTrue(FilePersistence.getDefaultURL().path.hasSuffix("/Documents/thread-db"))
    }
}
