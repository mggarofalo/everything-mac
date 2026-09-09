import Foundation
import IndexCore
import XCTest

final class ServiceProtocolTests: XCTestCase {
    func testEveryOperationRoundTrips() throws {
        for operation in [ServiceOperation.status, .search, .cancelSearch, .rebuild,
                          .getRules, .setRules] {
            let request = ServiceRequest(operation: operation, payload: Data([1, 2, 3]))
            let decoded = try JSONDecoder().decode(
                ServiceRequest.self, from: JSONEncoder().encode(request)
            )
            XCTAssertEqual(decoded.operation, operation)
            XCTAssertEqual(decoded.payload, request.payload)
        }
    }

    func testSuccessAndFailureReplies() throws {
        let success = ServiceReply.success(["one", "two"])
        XCTAssertNil(success.error)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: XCTUnwrap(success.payload)),
                       ["one", "two"])

        let failure = ServiceReply.failure("Unavailable")
        XCTAssertNil(failure.payload)
        XCTAssertEqual(failure.error, "Unavailable")
    }

    func testStatusSearchRequestAndResponseRoundTrip() throws {
        let status = ServiceStatus(totalCount: 42, revision: 7, scanning: true,
                                   hasFullDiskAccess: false)
        let decodedStatus = try roundTrip(status)
        XCTAssertEqual(decodedStatus.totalCount, 42)
        XCTAssertEqual(decodedStatus.revision, 7)
        XCTAssertTrue(decodedStatus.scanning)
        XCTAssertFalse(decodedStatus.hasFullDiskAccess)

        let request = SearchRequest(text: "report", matchPath: true, caseInsensitive: false,
                                    wholeWord: true, usesRegularExpression: false,
                                    sort: .mtime, ascending: false, limit: 123)
        let decodedRequest = try roundTrip(request)
        XCTAssertEqual(decodedRequest.text, "report")
        XCTAssertTrue(decodedRequest.matchPath)
        XCTAssertFalse(decodedRequest.caseInsensitive)
        XCTAssertTrue(decodedRequest.wholeWord)
        XCTAssertFalse(decodedRequest.usesRegularExpression)
        XCTAssertEqual(decodedRequest.sort, .mtime)
        XCTAssertFalse(decodedRequest.ascending)
        XCTAssertEqual(decodedRequest.limit, 123)

        let record = FileRecord(id: 1, name: "report.pdf", path: "/report.pdf", parent: 0,
                                size: 10, mtime: 20, isDir: false, volID: 1)
        XCTAssertEqual(try roundTrip(SearchResponse(records: [record])).records, [record])
    }

    func testServicePathsUsePrivateApplicationSupportNamespace() {
        XCTAssertEqual(ServicePaths.applicationSupportURL.lastPathComponent, "Everything-Mac")
        XCTAssertEqual(ServicePaths.cacheURL().lastPathComponent, "index.idx")
        XCTAssertEqual(ServicePaths.cacheURL().deletingLastPathComponent(),
                       ServicePaths.applicationSupportURL)
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}

final class IndexActorBoundaryTests: XCTestCase {
    func testEmptyActorStatusAndSearch() async {
        let actor = IndexActor()
        let initialCount = await actor.totalCount
        XCTAssertEqual(initialCount, 0)
        let status = await actor.serviceStatus(hasFullDiskAccess: false)
        XCTAssertEqual(status.totalCount, 0)
        XCTAssertEqual(status.revision, 0)
        XCTAssertFalse(status.scanning)
        XCTAssertFalse(status.hasFullDiskAccess)
        let results = await actor.search("", matchPath: false, sort: .name, ascending: true)
        XCTAssertEqual(results, [])
    }

    func testRulesCanBeUpdatedWithoutDiskAccess() async {
        let actor = IndexActor()
        let rules = ExcludeRules(names: ["Private"], pathPrefixes: ["/secret"],
                                 excludeHidden: true, excludeDevFolders: false,
                                 excludeVCSFolders: false, excludeTrash: false,
                                 excludeFilePatterns: ["*.tmp"])
        await actor.setRules(rules)
        let currentRules = await actor.currentRules()
        XCTAssertEqual(currentRules, rules)
        await actor.rescanAll()
        let countAfterRescan = await actor.totalCount
        XCTAssertEqual(countAfterRescan, 0)
        await actor.enqueueChanges([
            .init(path: "/tmp", eventID: 1, mustScanSubtree: false, structural: true)
        ])
        let countAfterEvent = await actor.totalCount
        XCTAssertEqual(countAfterEvent, 0)
    }

    func testNonLocalMountPathsAreAbsolute() {
        XCTAssertTrue(IndexActor.nonLocalMountPaths().allSatisfy { $0.hasPrefix("/") })
    }

    func testSearchAndLiveReconcileAgainstScopedStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EverythingMacActorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        try Data("one".utf8).write(to: original)
        var store = FileStore()
        try Scanner(rules: ExcludeRules()).scan(rootPath: root.path, into: &store, volID: 1)
        let actor = IndexActor(store: store, rules: ExcludeRules(), accessEnabled: true)

        let originalResults = await actor.search(
            "original", matchPath: false, sort: .size, ascending: true
        )
        XCTAssertEqual(originalResults.map(\.path), [original.path])

        let added = root.appendingPathComponent("added.txt")
        try Data("added".utf8).write(to: added)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: root.path
        )
        await actor.enqueueChanges([
            .init(path: added.path, eventID: 10, mustScanSubtree: false, structural: true)
        ])
        try await Task.sleep(nanoseconds: 700_000_000)
        let reconciledCount = await actor.totalCount
        XCTAssertEqual(reconciledCount, 3)

        let addedResults = await actor.search(
            "added", matchPath: false, sort: .size, ascending: true
        )
        XCTAssertEqual(addedResults.map(\.path), [added.path])
        try Data("a much larger added value".utf8).write(to: added)
        await actor.enqueueChanges([
            .init(path: added.path, eventID: 11, mustScanSubtree: false,
                  metadataChanged: true)
        ])
        try await Task.sleep(nanoseconds: 700_000_000)
        let refreshed = await actor.search(
            "added", matchPath: false, sort: .size, ascending: true
        )
        XCTAssertEqual(refreshed.first?.size, UInt64("a much larger added value".utf8.count))
        let status = await actor.serviceStatus(hasFullDiskAccess: true)
        XCTAssertGreaterThan(status.revision, 0)
    }
}
