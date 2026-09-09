import Foundation
import XCTest
@testable import IndexCore

final class LiveMonitorCoverageTests: XCTestCase {
    func testReconcileAddsUpdatesDeletesAndUsesMtimeGate() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        try Data("one".utf8).write(to: original)
        var store = try scanned(root)
        var newlyIndexed = Set<String>()

        XCTAssertEqual(LiveMonitor.reconcileStatus(
            directory: root.path, in: &store, rules: ExcludeRules(), volID: 1,
            newlyIndexedDirs: &newlyIndexed
        ), .noChange)
        XCTAssertEqual(LiveMonitor.reconcileStatus(
            directory: root.path, in: &store, rules: ExcludeRules(), volID: 1,
            newlyIndexedDirs: &newlyIndexed
        ), .noChange)

        let added = root.appendingPathComponent("added.txt")
        try Data("added".utf8).write(to: added)
        bumpDirectoryMtime(root)
        XCTAssertTrue(LiveMonitor.reconcile(directory: root.path, in: &store,
                                            rules: ExcludeRules(), volID: 1))
        XCTAssertNotNil(store.idForDirPath(added.path))

        try FileManager.default.removeItem(at: original)
        bumpDirectoryMtime(root)
        XCTAssertTrue(LiveMonitor.reconcile(directory: root.path, in: &store,
                                            rules: ExcludeRules(), volID: 1))
        XCTAssertNil(store.idForDirPath(original.path))
    }

    func testNewDirectoryIndexesSubtreeAndDeepReconcileDeduplicatesIt() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var store = try scanned(root)
        let nested = root.appendingPathComponent("new/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("value".utf8).write(to: nested.appendingPathComponent("file.txt"))
        bumpDirectoryMtime(root)

        var newlyIndexed = Set<String>()
        var stack: [String] = []
        XCTAssertTrue(LiveMonitor.reconcileLevel(
            directory: root.path, in: &store, rules: ExcludeRules(), volID: 1,
            descend: true, newlyIndexedDirs: &newlyIndexed, pushChildDirsTo: &stack
        ))
        XCTAssertTrue(newlyIndexed.contains(root.appendingPathComponent("new").path))
        XCTAssertTrue(stack.isEmpty)
        XCTAssertNotNil(store.idForDirPath(nested.appendingPathComponent("file.txt").path))
    }

    func testDeepReconcileQueuesExistingChildDirectories() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        var store = try scanned(root)
        var newlyIndexed = Set<String>()
        var stack: [String] = []

        XCTAssertEqual(LiveMonitor.reconcileLevelStatus(
            directory: root.path, in: &store, rules: ExcludeRules(), volID: 1,
            descend: true, newlyIndexedDirs: &newlyIndexed, pushChildDirsTo: &stack
        ), .noChange)
        XCTAssertEqual(stack, [child.path])
        stack.removeAll()
        XCTAssertFalse(LiveMonitor.reconcileLevel(
            directory: root.path, in: &store, rules: ExcludeRules(), volID: 1,
            descend: false, newlyIndexedDirs: &newlyIndexed, pushChildDirsTo: &stack
        ))
        XCTAssertTrue(stack.isEmpty)
    }

    func testMissingDirectoryDeletesDescendants() throws {
        let root = try makeDirectory()
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data().write(to: child.appendingPathComponent("file"))
        var store = try scanned(root)
        try FileManager.default.removeItem(at: root)
        var newlyIndexed = Set<String>()

        XCTAssertEqual(LiveMonitor.reconcileStatus(
            directory: root.path, in: &store, rules: ExcludeRules(), volID: 1,
            newlyIndexedDirs: &newlyIndexed
        ), .changed)
        XCTAssertEqual(store.liveCount, 1)
        XCTAssertEqual(LiveMonitor.reconcileStatus(
            directory: root.path, in: &store, rules: ExcludeRules(), volID: 1,
            newlyIndexedDirs: &newlyIndexed
        ), .noChange)
    }

    func testExcludedEntriesAreRemovedOnReconcile() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = root.appendingPathComponent("scratch.tmp")
        try Data().write(to: scratch)
        var store = try scanned(root)
        bumpDirectoryMtime(root)
        let rules = ExcludeRules(excludeFilePatterns: ["*.tmp"])
        var newlyIndexed = Set<String>()
        XCTAssertEqual(LiveMonitor.reconcileStatus(
            directory: root.path, in: &store, rules: rules, volID: 1,
            newlyIndexedDirs: &newlyIndexed
        ), .changed)
        XCTAssertNil(store.idForDirPath(scratch.path))
    }

    func testMetadataStatuses() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("one".utf8).write(to: file)
        var store = try scanned(root)

        XCTAssertEqual(LiveMonitor.refreshMetadataStatus(path: root.appendingPathComponent("none").path,
                                                         in: &store), .noChange)
        XCTAssertFalse(LiveMonitor.refreshMetadata(path: file.path, in: &store))
        try Data("a much larger value".utf8).write(to: file)
        XCTAssertEqual(LiveMonitor.refreshMetadataStatus(path: file.path, in: &store), .changed)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(LiveMonitor.refreshMetadataStatus(path: file.path, in: &store), .noChange)
    }

    func testCanonicalEventPathsAndEmptyMonitorOperations() {
        XCTAssertEqual(LiveMonitor.canonicalEventPath("/System/Volumes/Data"), "/")
        XCTAssertEqual(LiveMonitor.canonicalEventPath("/System/Volumes/Data/Users/me"), "/Users/me")
        XCTAssertEqual(LiveMonitor.canonicalEventPath("/Volumes/Data/file"), "/Volumes/Data/file")
        let monitor = LiveMonitor { _ in }
        monitor.flush()
        monitor.stop()
    }

    private func scanned(_ root: URL) throws -> FileStore {
        var store = FileStore()
        try Scanner(rules: ExcludeRules()).scan(rootPath: root.path, into: &store, volID: 1)
        return store
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EverythingMacLiveMonitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bumpDirectoryMtime(_ directory: URL) {
        let future = Date().addingTimeInterval(5)
        try? FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: directory.path)
    }
}
