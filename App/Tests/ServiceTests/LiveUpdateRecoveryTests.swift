import Foundation
import IndexCore
import XCTest

final class LiveUpdateRecoveryTests: XCTestCase {
    func testUnreadableDirectoryDoesNotDelayUnrelatedCreation() async throws {
        let root = URL(fileURLWithPath: IndexScope.canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("EverythingMacRetryTests-\(UUID().uuidString)").standardizedFileURL
        let blocked = root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: root)
        }
        var store = FileStore()
        try Scanner(rules: ExcludeRules()).scan(rootPath: root.path, into: &store, volID: 1)
        let actor = IndexActor(store: store, rules: ExcludeRules(), accessEnabled: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        await actor.enqueueChanges([
            .init(path: blocked.path, eventID: 10, mustScanSubtree: false)
        ])

        // Observed denial suppresses cached metadata without delaying unrelated paths.
        let retryDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await actor.serviceStatus().coverage?.issues.isEmpty != false,
              ContinuousClock.now < retryDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let retryStatus = await actor.serviceStatus()
        XCTAssertTrue(retryStatus.coverage?.issues.contains(where: \.accessDenied) == true)

        let fresh = root.appendingPathComponent("fresh.txt")
        try Data("fresh".utf8).write(to: fresh)
        await actor.enqueueChanges([
            .init(path: fresh.path, eventID: 20, mustScanSubtree: false, structural: true)
        ])
        let freshResults = await waitForFile("fresh.txt", in: actor, seconds: 2)
        XCTAssertEqual(freshResults.map(\.path), [fresh.path],
                       "A failed path's backoff must not delay unrelated file creation")

        // Recovery must still happen without a second event for the failed path.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        let recovered = blocked.appendingPathComponent("recovered.txt")
        try Data("recovered".utf8).write(to: recovered)
        await actor.refreshUnavailablePaths()
        let recoveredResults = await waitForFile("recovered.txt", in: actor, seconds: 6)
        XCTAssertEqual(recoveredResults.map(\.path), [recovered.path])
    }

    func testFreshShallowEventPreservesDeferredSubtreeInspection() async throws {
        let root = URL(fileURLWithPath: IndexScope.canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("EverythingMacDeepRetryTests-\(UUID().uuidString)").standardizedFileURL
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        var store = FileStore()
        try Scanner(rules: ExcludeRules()).scan(rootPath: root.path, into: &store, volID: 1)
        let actor = IndexActor(store: store, rules: ExcludeRules(), accessEnabled: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        await actor.enqueueChanges([
            .init(path: root.path, eventID: 10, mustScanSubtree: true)
        ])
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await actor.serviceStatus().revision == 0,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let status = await actor.serviceStatus()
        XCTAssertGreaterThan(status.revision, 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let added = nested.appendingPathComponent("nested-recovery.txt")
        try Data("nested".utf8).write(to: added)
        await actor.refreshUnavailablePaths()
        await actor.enqueueChanges([
            .init(path: root.path, eventID: 20, mustScanSubtree: false)
        ])
        let results = await waitForFile("nested-recovery.txt", in: actor, seconds: 2)
        XCTAssertEqual(results.map(\.path), [added.path])
    }

    private func waitForFile(_ name: String, in actor: IndexActor,
                             seconds: Int) async -> [FileRecord] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        repeat {
            let records = await actor.search(name, matchPath: false, sort: .name, ascending: true)
            if !records.isEmpty { return records }
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        return []
    }
}
