import Foundation
import IndexCore
import XCTest

private actor ScopeWorkGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?

    func pause() async {
        guard !released else { return }
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { blocked = $0 }
    }

    func waitForEntry() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() { released = true; blocked?.resume(); blocked = nil }
}

private final class ScopeSearchGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var checks = 0

    func check() -> Bool {
        lock.lock(); checks += 1; let pause = checks == 2; lock.unlock()
        if pause { entered.signal(); released.wait() }
        return false
    }
}

private struct ScopeFixture {
    let root: URL
    let blocked: URL
    let cache: URL
    let store: FileStore

    init() throws {
        root = URL(fileURLWithPath: IndexScope.canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("EverythingMacScopeTests-\(UUID().uuidString)")
        blocked = root.appendingPathComponent("blocked")
        cache = root.appendingPathComponent("state/index.idx")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: blocked.appendingPathComponent("secret.txt"))
        try Data("ordinary".utf8).write(to: root.appendingPathComponent("ordinary.txt"))
        var scanned = FileStore()
        try Scanner(rules: ExcludeRules()).scan(rootPath: root.path, into: &scanned, volID: 1)
        store = scanned
    }

    func cleanup() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        try? FileManager.default.removeItem(at: root)
    }

    func access(_ scope: IndexScope, revision: UInt64) -> ResolvedIndexAccess {
        ResolvedIndexAccess(revision: revision, scope: scope,
                            settings: IndexScopeSettings(mode: scope.mode, folders: scope.roots), issues: [])
    }
}

final class IndexScopeServiceTests: XCTestCase {
    func testObservedDenialFencesDetachedSearchAndStagedCache() async throws {
        let fixture = try ScopeFixture()
        defer { fixture.cleanup() }
        let saving = ScopeWorkGate()
        let actor = IndexActor(store: fixture.store, rules: ExcludeRules(), accessEnabled: true,
                               cacheURL: fixture.cache, save: { store, url, id, fingerprint, issues in
            await saving.pause()
            return await IndexActor.saveCache(store, url, id, fingerprint, issues)
        })
        let probe = ScopeSearchGate()
        let searching = Task {
            try await actor.searchResponse("", matchPath: false, sort: .name, ascending: true,
                                           interactive: false, isCancelled: { probe.check() })
        }
        let entered = await Task.detached { probe.entered.wait(timeout: .now() + 5) }.value
        XCTAssertEqual(entered, .success)
        let flushing = Task { await actor.flush() }
        await saving.waitForEntry()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.blocked.path)
        await actor.enqueueChanges([.init(path: fixture.blocked.path, eventID: 10, mustScanSubtree: true)])
        await waitForDenial(in: actor)
        probe.released.signal()
        await saving.release()
        do { _ = try await searching.value; XCTFail("An old snapshot must be canceled after observed denial") }
        catch { XCTAssertEqual(error as? ServiceErrorCode, .cancelled) }
        await flushing.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.path))
        let hidden = await actor.search("secret.txt", matchPath: false, sort: .name, ascending: true)
        XCTAssertTrue(hidden.isEmpty)
        await actor.flush()
        let saved = try IndexCache.loadSnapshot(from: fixture.cache)
        XCTAssertTrue(saved.issues.contains { $0.path == fixture.blocked.path && $0.accessDenied })
        XCTAssertNil(saved.store.idForDirPath(fixture.blocked.appendingPathComponent("secret.txt").path))
        await actor.invalidateForAccessRevocation(generation: .max)
    }

    func testDeniedSubtreeRecoverySurvivesRestartWithoutAnotherEvent() async throws {
        let fixture = try ScopeFixture()
        defer { fixture.cleanup() }
        let first = IndexActor(store: fixture.store, rules: ExcludeRules(), accessEnabled: true, cacheURL: fixture.cache)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.blocked.path)
        await first.enqueueChanges([.init(path: fixture.blocked.path, eventID: 10, mustScanSubtree: true)])
        await waitForDenial(in: first)
        await first.flush()
        let restarted = IndexActor(store: FileStore(), rules: ExcludeRules(), accessEnabled: false, cacheURL: fixture.cache)
        await restarted.configureAccess(fixture.access(IndexScope(mode: .selectedFolders, roots: [fixture.root.path]), revision: 1))
        await restarted.startUp(onLiveChange: {}, onProgress: { _ in }, accessGeneration: 1)
        let status = await restarted.serviceStatus()
        XCTAssertTrue(status.coverage?.issues.contains(where: \.accessDenied) == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.blocked.path)
        await restarted.refreshUnavailablePaths()
        let recovered = await restarted.search("secret.txt", matchPath: false, sort: .name, ascending: true)
        XCTAssertEqual(recovered.map(\.path), [fixture.blocked.appendingPathComponent("secret.txt").path])
        await first.invalidateForAccessRevocation(generation: .max)
        await restarted.invalidateForAccessRevocation(generation: .max)
    }

    func testSubtreeInspectionRefreshesMetadataDespiteUnchangedDirectoryMtime() async throws {
        let fixture = try ScopeFixture()
        defer { fixture.cleanup() }
        var store = fixture.store
        var indexed = Set<String>()
        _ = LiveMonitor.reconcileStatus(directory: fixture.blocked.path, in: &store,
                                        rules: ExcludeRules(), volID: 1, newlyIndexedDirs: &indexed)
        let actor = IndexActor(store: store, rules: ExcludeRules(), accessEnabled: true, cacheURL: fixture.cache)
        let secret = fixture.blocked.appendingPathComponent("secret.txt")
        try Data("a longer content value".utf8).write(to: secret)
        await actor.enqueueChanges([.init(path: fixture.blocked.path, eventID: 10, mustScanSubtree: true)])
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var results: [FileRecord] = []
        repeat {
            results = await actor.search("secret.txt", matchPath: false, sort: .size, ascending: true)
            if results.first?.size == 22 { break }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(results.first?.size, 22)
        await actor.invalidateForAccessRevocation(generation: .max)
    }

    func testDroppedHistoryRebuildsSelectedScopeEvenOutsideRoot() async throws {
        let fixture = try ScopeFixture()
        defer { fixture.cleanup() }
        let actor = IndexActor(store: fixture.store, rules: ExcludeRules(), accessEnabled: true, cacheURL: fixture.cache)
        let added = fixture.blocked.appendingPathComponent("missed-event.txt")
        try Data().write(to: added)
        await actor.enqueueChanges([.init(path: "/outside", eventID: 10, mustScanSubtree: true, historyDropped: true)])
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var results: [FileRecord] = []
        repeat {
            results = await actor.search("missed-event.txt", matchPath: false, sort: .name, ascending: true)
            if !results.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(results.map(\.path), [added.path])
        await actor.invalidateForAccessRevocation(generation: .max)
    }

    func testFileMetadataDenialRecoversAfterParentSearchPermissionReturns() async throws {
        let fixture = try ScopeFixture()
        defer { fixture.cleanup() }
        let actor = IndexActor(store: fixture.store, rules: ExcludeRules(), accessEnabled: true, cacheURL: fixture.cache)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.blocked.path)
        let secret = fixture.blocked.appendingPathComponent("secret.txt")
        await actor.enqueueChanges([.init(path: secret.path, eventID: 10, mustScanSubtree: false, metadataChanged: true)])
        await waitForDenial(in: actor)
        let denied = await actor.serviceStatus()
        XCTAssertTrue(denied.coverage?.issues.contains { $0.path == secret.path && $0.accessDenied } == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.blocked.path)
        await actor.refreshUnavailablePaths()
        let recovered = await actor.search("secret.txt", matchPath: false, sort: .name, ascending: true)
        XCTAssertEqual(recovered.map(\.path), [secret.path])
        await actor.invalidateForAccessRevocation(generation: .max)
    }

    func testNarrowingFencesScanAndCannotCacheUnpublishedEmptyStore() async throws {
        let fixture = try ScopeFixture()
        defer { fixture.cleanup() }
        let scanning = ScopeWorkGate()
        let actor = IndexActor(store: fixture.store, rules: ExcludeRules(), accessEnabled: true,
                               cacheURL: fixture.cache, scan: { roots, rules, identities, progress in
            await scanning.pause()
            return await IndexActor.scanFiles(roots, rules, identities, progress)
        })
        let rescan = Task { await actor.rescanAll() }
        await scanning.waitForEntry()
        let narrowing = Task { await actor.configureAccess(fixture.access(.empty, revision: 2)) }
        for _ in 0..<100 {
            if await actor.serviceStatus().ready == false { break }
            await Task.yield()
        }
        let unpublished = await actor.serviceStatus()
        XCTAssertFalse(unpublished.ready)
        await actor.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.path))
        await scanning.release()
        await rescan.value
        await narrowing.value
        XCTAssertEqual(try IndexCache.load(from: fixture.cache).0.liveCount, 0)
        let results = await actor.search("secret.txt", matchPath: false, sort: .name, ascending: true)
        XCTAssertTrue(results.isEmpty)
        await actor.configureAccess(fixture.access(IndexScope(mode: .selectedFolders, roots: [fixture.root.path]), revision: 1))
        let final = await actor.serviceStatus()
        XCTAssertEqual(final.coverage?.scope.folders, [])
        await actor.invalidateForAccessRevocation(generation: .max)
    }

    func testReplacementRootRequiresNewIdentityAndReselection() async throws {
        let fixture = try ScopeFixture()
        defer { fixture.cleanup() }
        var info = stat()
        XCTAssertEqual(lstat(fixture.blocked.path, &info), 0)
        let original = DirectoryIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        let actor = IndexActor(store: FileStore(), rules: ExcludeRules(), accessEnabled: true, cacheURL: fixture.cache)
        let scope = IndexScope(mode: .selectedFolders, roots: [fixture.blocked.path], identities: [fixture.blocked.path: original])
        await actor.configureAccess(fixture.access(scope, revision: 1))
        try FileManager.default.moveItem(at: fixture.blocked, to: fixture.root.appendingPathComponent("previous"))
        try FileManager.default.createDirectory(at: fixture.blocked, withIntermediateDirectories: false)
        try Data().write(to: fixture.blocked.appendingPathComponent("replacement.txt"))
        await actor.enqueueChanges([.init(path: fixture.blocked.path, eventID: 10, mustScanSubtree: true)])
        let hidden = await actor.search("replacement.txt", matchPath: false, sort: .name, ascending: true)
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(lstat(fixture.blocked.path, &info), 0)
        let replacement = DirectoryIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        let reselected = IndexScope(mode: .selectedFolders, roots: [fixture.blocked.path], identities: [fixture.blocked.path: replacement])
        await actor.configureAccess(fixture.access(reselected, revision: 2))
        let visible = await actor.search("replacement.txt", matchPath: false, sort: .name, ascending: true)
        XCTAssertEqual(visible.count, 1)
        let old = await actor.search("secret.txt", matchPath: false, sort: .name, ascending: true)
        XCTAssertTrue(old.isEmpty)
        await actor.invalidateForAccessRevocation(generation: .max)
    }

    func testNewInstallLegacyMigrationCorruptScopeAndInvalidUpdate() async throws {
        let fixture = try ScopeFixture()
        defer { fixture.cleanup() }
        let url = fixture.root.appendingPathComponent("state/scope.json")
        let fresh = IndexAccess(url: url, legacyCacheExists: false)
        let empty = await fresh.settings()
        XCTAssertEqual(empty.mode, .selectedFolders)
        XCTAssertTrue(empty.folders.isEmpty)
        let legacy = IndexAccess(url: url, legacyCacheExists: true)
        let migrated = await legacy.resolve()
        XCTAssertEqual(migrated.scope, .localVolumes)
        let restart = IndexAccess(url: url, legacyCacheExists: false)
        let restartedSettings = await restart.settings()
        XCTAssertEqual(restartedSettings.mode, .localVolumes)
        do {
            _ = try await restart.update(IndexScopeUpdate(mode: .selectedFolders,
                                                          retainedFolders: ["/unauthorized"], addedBookmarks: []))
            XCTFail("Unknown retained paths must not create authority")
        } catch { XCTAssertEqual(error as? ServiceErrorCode, .invalidQuery) }
        _ = try await restart.update(IndexScopeUpdate(mode: .selectedFolders, retainedFolders: [], addedBookmarks: []))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try Data("corrupt".utf8).write(to: url)
        let corrupt = IndexAccess(url: url, legacyCacheExists: true)
        let corruptSettings = await corrupt.settings()
        XCTAssertEqual(corruptSettings.mode, .selectedFolders)
    }

    func testLegacyStorageMigrationPrecedesCreatingFolderScope() async throws {
        let fixture = try ScopeFixture()
        defer { fixture.cleanup() }
        let old = fixture.root.appendingPathComponent("legacy")
        let current = fixture.root.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        try Data("old index".utf8).write(to: old.appendingPathComponent("index.idx"))
        let directory = ServicePaths.prepareApplicationSupportDirectory(currentURL: current, legacyURL: old)
        let access = IndexAccess(url: directory.appendingPathComponent("scope.json"))
        let resolved = await access.resolve()
        XCTAssertEqual(resolved.scope, .localVolumes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("index.idx")), Data("old index".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("scope.json").path))
    }

    private func waitForDenial(in actor: IndexActor) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            if await actor.serviceStatus().coverage?.issues.contains(where: \.accessDenied) == true { return }
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        XCTFail("Expected an observed access denial")
    }

}
