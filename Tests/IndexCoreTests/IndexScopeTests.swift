import Foundation
import XCTest
@testable import IndexCore

final class IndexScopeTests: XCTestCase {
    func testRootsAreCanonicalAndOverlapsAreRemovedAtComponentBoundaries() {
        let scope = IndexScope(mode: .selectedFolders, roots: [
            "/System/Volumes/Data/Users/me/Docs/", "/Users/me/Docs/nested",
            "/Users/me/Docs", "/Users/me/DocsElsewhere", "relative", "/tmp/test/../test"
        ])
        XCTAssertEqual(scope.roots, ["/Users/me/Docs", "/Users/me/DocsElsewhere", "/private/tmp/test"])
        XCTAssertTrue(scope.contains("/Users/me/Docs/nested/file"))
        XCTAssertFalse(scope.contains("/Users/me/Docs2/file"))
        XCTAssertFalse(IndexScope.empty.contains("/anything"))
        XCTAssertTrue(IndexScope.localVolumes.contains("/anything"))
        XCTAssertEqual(IndexScope(mode: .localVolumes, roots: ["/ignored"]).roots, ["/"])
        XCTAssertEqual(IndexScope.canonicalPath("/System/Volumes/Data"), "/")
        XCTAssertEqual(IndexScope.canonicalPath("/var"), "/private/var")
        XCTAssertEqual(IndexScope.canonicalPath("/etc/hosts"), "/private/etc/hosts")
        XCTAssertEqual(IndexScope.canonicalPath("/variety"), "/variety")
    }

    func testFingerprintIncludesScopeRulesAndDirectoryIdentity() throws {
        let first = IndexScope(mode: .selectedFolders, roots: ["/one"], identities: [
            "/one": DirectoryIdentity(device: 1, inode: 2), "/outside": DirectoryIdentity(device: 1, inode: 3)
        ])
        let replacement = IndexScope(mode: .selectedFolders, roots: ["/one"], identities: [
            "/one": DirectoryIdentity(device: 1, inode: 4)
        ])
        XCTAssertEqual(first.identities.count, 1)
        XCTAssertNotEqual(first.fingerprint(rules: ExcludeRules()), replacement.fingerprint(rules: ExcludeRules()))
        XCTAssertNotEqual(first.fingerprint(rules: ExcludeRules()), first.fingerprint(rules: ExcludeRules(excludeHidden: true)))
        XCTAssertNotEqual(IndexScope.empty.fingerprint(rules: ExcludeRules()), IndexScope.localVolumes.fingerprint(rules: ExcludeRules()))
        let decoded = try JSONDecoder().decode(IndexScope.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(first, decoded)
        XCTAssertTrue(ScanIssue(path: "/one", errorCode: EACCES).accessDenied)
        XCTAssertTrue(ScanIssue(path: "/one", errorCode: EPERM).accessDenied)
        XCTAssertFalse(ScanIssue(path: "/one", errorCode: ENOENT).accessDenied)
    }

    func testMultipleRootsAndReportedFailures() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("one")
        let second = base.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data().write(to: first.appendingPathComponent("first"))
        try Data().write(to: second.appendingPathComponent("second"))
        let result = ParallelScanner.scan(roots: [first.path + "/", second.path, base.appendingPathComponent("missing").path],
                                          rules: ExcludeRules(), workerCount: 2)
        XCTAssertNotNil(result.store.idForDirPath(first.appendingPathComponent("first").path))
        XCTAssertNotNil(result.store.idForDirPath(second.appendingPathComponent("second").path))
        XCTAssertEqual(result.issues.map(\.errorCode), [ENOENT])
        let rejected = ParallelScanner.scan(roots: [first.path], rules: ExcludeRules(),
                                            identities: [first.path: DirectoryIdentity(device: 0, inode: 0)])
        XCTAssertEqual(rejected.store.liveCount, 0)
        XCTAssertEqual(rejected.issues.map(\.errorCode), [ENOENT])
        XCTAssertFalse(ParallelScanner.rootMatches(base.appendingPathComponent("missing").path,
                                                  identity: DirectoryIdentity(device: 0, inode: 0)))
        var status = stat()
        XCTAssertEqual(lstat(first.path, &status), 0)
        let identity = DirectoryIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
        XCTAssertTrue(ParallelScanner.rootMatches(first.path, identity: identity))
        XCTAssertEqual(ParallelScanner.scan(roots: [first.path], rules: ExcludeRules(),
                                            identities: [first.path: identity]).issues, [])
        XCTAssertEqual(ParallelScanner.scan(roots: [], rules: ExcludeRules()).store.liveCount, 0)
    }
    func testMountClassificationUsesMostSpecificComponentRoot() {
        let mounts = [MountedVolumes.Mount(path: "/", isLocal: true),
                      MountedVolumes.Mount(path: "/Volumes/Share", isLocal: false),
                      MountedVolumes.Mount(path: "/Volumes/Share/Local", isLocal: true)]
        XCTAssertTrue(MountedVolumes.permitsInspection("/ordinary", mounts: mounts))
        XCTAssertFalse(MountedVolumes.permitsInspection("/Volumes/Share/file", mounts: mounts))
        XCTAssertTrue(MountedVolumes.permitsInspection("/Volumes/ShareElsewhere/file", mounts: mounts))
        XCTAssertTrue(MountedVolumes.permitsInspection("/Volumes/Share/Local/file", mounts: mounts))
        XCTAssertFalse(MountedVolumes.permitsInspection("relative", mounts: mounts))
        XCTAssertFalse(MountedVolumes.permitsInspection("/unknown", mounts: []))
        XCTAssertTrue(MountedVolumes.snapshot().contains { $0.path == "/" && $0.isLocal })
        XCTAssertTrue(MountedVolumes.permitsInspection(FileManager.default.temporaryDirectory.path))
    }

    func testForestAndRecoveryIssuesSurviveCacheAndCompaction() throws {
        var store = FileStore()
        let one = store.append(name: "/one", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
        let two = store.append(name: "/two", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 2)
        _ = store.append(name: "file", parent: one, size: 1, mtime: 1, isDir: false, volID: 1)
        let deleted = store.append(name: "removed", parent: two, size: 1, mtime: 1, isDir: false, volID: 2)
        store.markDeleted(deleted)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let issues = [ScanIssue(path: "/one/denied", errorCode: EACCES)]
        try IndexCache.save(store.compacted(), to: cache, lastEventID: 42, rulesFingerprint: 99, issues: issues)
        let loaded = try IndexCache.loadSnapshot(from: cache)
        XCTAssertEqual(loaded.eventID, 42)
        XCTAssertEqual(loaded.fingerprint, 99)
        XCTAssertEqual(loaded.issues, issues)
        XCTAssertNotNil(loaded.store.idForDirPath("/one/file"))
        XCTAssertNotNil(loaded.store.idForDirPath("/two"))
        XCTAssertNil(loaded.store.idForDirPath("/two/removed"))
        var malformed = try Data(contentsOf: cache)
        malformed.replaceSubrange(20..<24, with: [255, 255, 255, 255])
        try malformed.write(to: cache)
        XCTAssertThrowsError(try IndexCache.loadSnapshot(from: cache))
        malformed.replaceSubrange(20..<24, with: [2, 0, 0, 0])
        malformed.replaceSubrange(24..<26, with: Array("xx".utf8))
        try malformed.write(to: cache)
        XCTAssertThrowsError(try IndexCache.loadSnapshot(from: cache))
    }

    func testDirectoryReaderClassifiesBeforeOpeningAndRefusesSymlinkRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("package.json"))
        let listing = DirectoryReader.read(root.path)
        XCTAssertTrue(listing.opened)
        XCTAssertTrue(listing.inProjectDir)
        XCTAssertEqual(listing.names, ["package.json"])
        XCTAssertNil(listing.errorCode)
        XCTAssertEqual(DirectoryReader.read(root.path, mounts: []).errorCode, ENOTSUP)
        XCTAssertEqual(DirectoryReader.read(root.appendingPathComponent("missing").path).errorCode, ENOENT)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertFalse(DirectoryReader.read(link.path).opened)
        XCTAssertFalse(DirectoryReader.read(root.appendingPathComponent("package.json").path).opened)
    }

}
