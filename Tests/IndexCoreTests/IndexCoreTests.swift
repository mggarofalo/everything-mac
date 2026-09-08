import Foundation
import XCTest
@testable import IndexCore

final class IndexCoreTests: XCTestCase {
    func testExclusionPrefixesRespectPathComponents() {
        let rules = ExcludeRules(pathPrefixes: ["/Users/me/Secret", "/Volumes/Work/"])

        XCTAssertTrue(rules.shouldExclude(name: "file", path: "/Users/me/Secret/file", isHidden: false))
        XCTAssertTrue(rules.shouldExclude(name: "file", path: "/Volumes/Work/file", isHidden: false))
        XCTAssertFalse(rules.shouldExclude(name: "file", path: "/Users/me/Secret2/file", isHidden: false))
        XCTAssertFalse(rules.shouldExclude(name: "file", path: "/Volumes/Workspace/file", isHidden: false))

        let rootRules = ExcludeRules(pathPrefixes: ["/"])
        XCTAssertTrue(rootRules.shouldExclude(name: "file", path: "/Users/me/file", isHidden: false))
    }

    func testCompactionRemovesTombstonesAndPreservesPaths() {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        let kept = store.append(name: "kept", parent: root, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        _ = store.append(name: "note.txt", parent: kept, size: 4,
                         mtime: 10, isDir: false, volID: 1)
        let deleted = store.append(name: "deleted", parent: root, size: 0,
                                   mtime: 0, isDir: true, volID: 1)
        let deletedChild = store.append(name: "secret.txt", parent: deleted, size: 8,
                                        mtime: 20, isDir: false, volID: 1)
        store.markDeleted(deletedChild)
        store.markDeleted(deleted)

        let compacted = store.compacted()

        XCTAssertEqual(compacted.count, 3)
        XCTAssertEqual(compacted.liveCount, 3)
        XCTAssertEqual(compacted.deletedCount, 0)
        XCTAssertNotNil(compacted.idForDirPath("/kept/note.txt"))
        XCTAssertNil(compacted.idForDirPath("/deleted"))
    }

    func testRefreshMetadataAndSameNameTypeReplacement() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EverythingMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let itemURL = rootURL.appendingPathComponent("item")
        try Data("one".utf8).write(to: itemURL)
        var store = FileStore()
        try Scanner(rules: ExcludeRules()).scan(rootPath: rootURL.path, into: &store, volID: 1)
        let originalID = try XCTUnwrap(store.idForDirPath(itemURL.path))

        try Data("a larger replacement".utf8).write(to: itemURL)
        XCTAssertTrue(LiveMonitor.refreshMetadata(path: itemURL.path, in: &store))
        XCTAssertEqual(store.size(of: originalID), UInt64("a larger replacement".utf8.count))

        try FileManager.default.removeItem(at: itemURL)
        try FileManager.default.createDirectory(at: itemURL, withIntermediateDirectories: false)
        try Data("child".utf8).write(to: itemURL.appendingPathComponent("child.txt"))
        XCTAssertTrue(LiveMonitor.reconcile(directory: rootURL.path, in: &store,
                                            rules: ExcludeRules(), volID: 1))

        let replacementID = try XCTUnwrap(store.idForDirPath(itemURL.path))
        XCTAssertNotEqual(replacementID, originalID)
        XCTAssertTrue(store.isDir(of: replacementID))
        XCTAssertNotNil(store.idForDirPath(itemURL.appendingPathComponent("child.txt").path))
    }

    func testCacheIsPrivateAndRoundTripsCheckpoint() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EverythingMacCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let cacheURL = rootURL.appendingPathComponent("index.idx")

        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        let secret = store.append(name: "deleted-secret-name.txt", parent: root, size: 1,
                                  mtime: 1, isDir: false, volID: 1)
        store.markDeleted(secret)
        try IndexCache.save(store, to: cacheURL, lastEventID: 42, rulesFingerprint: 99)

        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let (loaded, eventID, fingerprint) = try IndexCache.load(from: cacheURL)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(eventID, 42)
        XCTAssertEqual(fingerprint, 99)
        XCTAssertNil(try Data(contentsOf: cacheURL).range(of: Data("deleted-secret-name.txt".utf8)))
    }

    func testLiveMonitorReportsStructuralEventWithCheckpoint() throws {
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("EverythingMacEventsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let resolvedRootURL = rootURL.resolvingSymlinksInPath()
        let createdURL = resolvedRootURL.appendingPathComponent("created.txt")
        let received = expectation(description: "FSEvents create notification")

        let monitor = LiveMonitor { changes in
            if changes.contains(where: {
                $0.path == createdURL.path && $0.structural && $0.eventID > 0
            }) {
                received.fulfill()
            }
        }
        XCTAssertTrue(monitor.start(paths: [resolvedRootURL.path]))
        usleep(100_000)
        try Data("event".utf8).write(to: createdURL)
        monitor.flush()

        wait(for: [received], timeout: 5)
        monitor.stop()
    }
}
