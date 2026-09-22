import Foundation
import IndexCore
import XCTest

private final class LockedReplies: @unchecked Sendable {
    private let lock: NSLock
    private var values: [Data] = []

    init(lock: NSLock) { self.lock = lock }
    func append(_ value: Data) { lock.lock(); values.append(value); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        return checks > 2
    }
}

private final class BlockingSearchProbe: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var checks = 0
    private var released = false

    func check() -> Bool {
        lock.lock()
        checks += 1
        let shouldBlock = checks == 2
        lock.unlock()
        if shouldBlock {
            entered.signal()
            release.wait()
        }
        return false
    }

    func unblock() {
        lock.lock()
        released = true
        lock.unlock()
        release.signal()
    }

    var wasReleased: Bool { lock.lock(); defer { lock.unlock() }; return released }
}

private final class PendingLaunchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID] = []
    func record(_ id: UUID) { lock.lock(); ids.append(id); lock.unlock() }
    var values: [UUID] { lock.lock(); defer { lock.unlock() }; return ids }
}

private final class AutomationForwardProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Data) -> Void)?
    private var values: [ServiceReply] = []
    private var cancellations = 0

    func forward(_ data: Data, callback: @escaping @Sendable (Data) -> Void) {
        lock.lock(); self.callback = callback; lock.unlock()
    }

    func cancel() { lock.lock(); cancellations += 1; lock.unlock() }

    func record(_ data: Data) {
        lock.lock(); values.append(try! JSONDecoder().decode(ServiceReply.self, from: data)); lock.unlock()
    }

    func completeLate() {
        lock.lock(); let callback = self.callback; lock.unlock()
        callback?((try? JSONEncoder().encode(ServiceReply.success(true))) ?? Data())
    }

    var replies: [ServiceReply] { lock.lock(); defer { lock.unlock() }; return values }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
}

final class ServiceProtocolTests: XCTestCase {
    func testAutomationRoleAndSignatureAllowlist() {
        let accepted: Set<String> = [appSigningIdentifier, cliSigningIdentifier]
        XCTAssertTrue(ConnectionTrust.accepts(identifier: appSigningIdentifier,
                                              teamIdentifier: "TEAM", ownTeamIdentifier: "TEAM",
                                              identifiers: accepted))
        XCTAssertTrue(ConnectionTrust.accepts(identifier: cliSigningIdentifier,
                                              teamIdentifier: "TEAM", ownTeamIdentifier: "TEAM",
                                              identifiers: accepted))
        XCTAssertFalse(ConnectionTrust.accepts(identifier: "com.everythingmac.other",
                                               teamIdentifier: "TEAM", ownTeamIdentifier: "TEAM",
                                               identifiers: accepted))
        XCTAssertFalse(ConnectionTrust.accepts(identifier: cliSigningIdentifier,
                                               teamIdentifier: "OTHER", ownTeamIdentifier: "TEAM",
                                               identifiers: accepted))
        XCTAssertFalse(ConnectionTrust.accepts(identifier: cliSigningIdentifier,
                                               teamIdentifier: "", ownTeamIdentifier: "TEAM",
                                               identifiers: accepted))
        XCTAssertFalse(ConnectionTrust.accepts(identifier: cliSigningIdentifier,
                                               teamIdentifier: "TEAM", ownTeamIdentifier: "TEAM",
                                               identifiers: [searchServiceSigningIdentifier]))
        XCTAssertTrue(SearchClientRole.cli.allows(.search))
        XCTAssertTrue(SearchClientRole.cli.allows(.status))
        XCTAssertTrue(SearchClientRole.cli.allows(.cancelSearch))
        for operation in [ServiceOperation.rebuild, .getRules, .setRules,
                          .getAutomationAccess, .setAutomationAccess] {
            XCTAssertFalse(SearchClientRole.cli.allows(operation))
            XCTAssertTrue(SearchClientRole.app.allows(operation))
        }
    }

    func testAutomationAccessDefaultsOffPersistsAndRevokes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("everythingmac-automation-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("automation-access")
        let access = AutomationAccess(url: url)
        XCTAssertFalse(access.isEnabled)
        let revoked = expectation(description: "revoked")
        let observer = access.observe { revoked.fulfill() }
        try access.setEnabled(true)
        XCTAssertTrue(access.isEnabled)
        XCTAssertTrue(AutomationAccess(url: url).isEnabled)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try access.setEnabled(false)
        wait(for: [revoked], timeout: 1)
        XCTAssertFalse(AutomationAccess(url: url).isEnabled)
        access.removeObserver(observer)
    }

    func testAppCanSetAccessAndCliCannotForgeMutations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("everythingmac-auth-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = AutomationAccess(url: directory.appendingPathComponent("access"))
        let admission = ConnectionAdmission(capacity: 2)
        let app = SearchService(lease: try XCTUnwrap(admission.acquire()), role: .app,
                                automation: access)
        let cli = SearchService(lease: try XCTUnwrap(admission.acquire()), role: .cli,
                                automation: access)
        func request(_ service: SearchService, _ operation: ServiceOperation,
                     payload: Data? = nil) throws -> ServiceReply {
            let data = try JSONEncoder().encode(ServiceRequest(operation: operation, payload: payload))
            var result: ServiceReply?
            service.perform(data) { response in result = try? JSONDecoder().decode(ServiceReply.self, from: response) }
            return try XCTUnwrap(result)
        }
        XCTAssertEqual(try request(cli, .status).errorCode, .permissionDenied)
        XCTAssertEqual(try JSONDecoder().decode(Bool.self,
                       from: XCTUnwrap(request(app, .getAutomationAccess).payload)), false)
        let enabled = try JSONEncoder().encode(true)
        XCTAssertNil(try request(app, .setAutomationAccess, payload: enabled).errorCode)
        XCTAssertTrue(access.isEnabled)
        for operation in [ServiceOperation.rebuild, .setRules, .getRules,
                          .setAutomationAccess, .getAutomationAccess] {
            XCTAssertEqual(try request(cli, operation, payload: enabled).errorCode, .permissionDenied)
        }
        app.close(); cli.close()
    }

    func testDisablingAccessCancelsOutstandingCliReplyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("everythingmac-auth-revoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = AutomationAccess(url: directory.appendingPathComponent("access"))
        try access.setEnabled(true)
        let admission = ConnectionAdmission(capacity: 1)
        let probe = AutomationForwardProbe()
        let cli = SearchService(lease: try XCTUnwrap(admission.acquire()), role: .cli,
                                automation: access,
                                testForward: { data, callback in probe.forward(data, callback: callback) },
                                testCancel: { probe.cancel() })
        let query = SearchRequest(text: "needle", matchPath: false, caseInsensitive: true,
                                  wholeWord: false, usesRegularExpression: false,
                                  sort: .name, ascending: true, limit: 10)
        let payload = try JSONEncoder().encode(query)
        let request = try JSONEncoder().encode(ServiceRequest(operation: .search, payload: payload))
        cli.perform(request) { probe.record($0) }
        XCTAssertTrue(probe.replies.isEmpty)
        try access.setEnabled(false)
        XCTAssertEqual(probe.replies.map(\.errorCode), [.permissionDenied])
        XCTAssertEqual(probe.cancelCount, 1)
        probe.completeLate()
        XCTAssertEqual(probe.replies.count, 1)
        cli.close()
    }

    func testGlobalAdmissionReleaseWakesPreRegisteredPendingSearch() {
        let admission = SearchAdmission(capacity: 1, backgroundCapacity: 1)
        let state = SearchSessionState<String>(capacity: 1)
        let recorded = PendingLaunchBox()
        let latestID = UUID()
        let observer = admission.observe {
            if let launch = state.takeReady(
                acquire: { admission.acquire(interactive: true) },
                releaseWithoutNotification: {
                    admission.release(interactive: true, notify: false)
                }
            ) { recorded.record(launch.id) }
        }
        XCTAssertTrue(admission.acquire(interactive: true))
        let oldID = UUID()
        XCTAssertNotNil(state.beginIndependent(oldID))
        guard case .accepted = state.offer("latest", id: latestID) else {
            return XCTFail("Expected pending search")
        }
        state.finish(oldID)
        XCTAssertNil(state.takeReady(acquire: { admission.acquire(interactive: true) },
                                     releaseWithoutNotification: {}))
        admission.release(interactive: true)
        XCTAssertEqual(recorded.values, [latestID])
        admission.removeObserver(observer)
        admission.release(interactive: true)
        XCTAssertEqual(recorded.values, [latestID])
    }

    func testGlobalAdmissionRotatesFirstChanceBetweenPendingClients() {
        let admission = SearchAdmission(capacity: 1, backgroundCapacity: 1)
        let first = SearchSessionState<String>(capacity: 1)
        let second = SearchSessionState<String>(capacity: 1)
        let recorded = PendingLaunchBox()
        let firstObserver = admission.observe {
            if let launch = first.takeReady(
                acquire: { admission.acquire(interactive: true) },
                releaseWithoutNotification: {
                    admission.release(interactive: true, notify: false)
                }
            ) { recorded.record(launch.id) }
        }
        let secondObserver = admission.observe {
            if let launch = second.takeReady(
                acquire: { admission.acquire(interactive: true) },
                releaseWithoutNotification: {
                    admission.release(interactive: true, notify: false)
                }
            ) { recorded.record(launch.id) }
        }
        XCTAssertTrue(admission.acquire(interactive: true))
        let firstID = UUID()
        let secondID = UUID()
        guard case .accepted = first.offer("first", id: firstID),
              case .accepted = second.offer("second", id: secondID) else {
            return XCTFail("Expected pending searches")
        }
        admission.release(interactive: true)
        XCTAssertEqual(recorded.values, [firstID])

        first.finish(firstID)
        guard case .accepted = first.offer("first again", id: UUID()) else {
            return XCTFail("Expected first client to stay pending")
        }
        admission.release(interactive: true)
        XCTAssertEqual(recorded.values, [firstID, secondID])
        admission.removeObserver(firstObserver)
        admission.removeObserver(secondObserver)
        admission.release(interactive: true)
    }

    func testClosingSaturatedSessionReturnsPendingOnlyOnce() {
        let state = SearchSessionState<String>(capacity: 1)
        let active = state.beginIndependent(UUID())!
        guard case .accepted = state.offer("pending", id: UUID()) else {
            return XCTFail("Expected pending search")
        }
        XCTAssertEqual(state.close(), "pending")
        XCTAssertTrue(active.isCancelled)
        XCTAssertNil(state.close())
        XCTAssertNil(state.takeReady(acquire: { true }, releaseWithoutNotification: {}))
    }

    func testClientAdmissionIsBoundedAndReleasesOnce() {
        let admission = ConnectionAdmission(capacity: 1)
        let lease = admission.acquire()
        XCTAssertNotNil(lease)
        XCTAssertNil(admission.acquire())
        lease?.close()
        lease?.close()
        XCTAssertNotNil(admission.acquire())
    }

    func testSessionCancellationIsIsolatedAndSupersessionIsLocal() {
        let ui = SearchSessionRequests()
        let cli = SearchSessionRequests()
        let uiFirstID = UUID()
        let cliID = UUID()
        let uiFirst = ui.begin(uiFirstID, supersede: true)!
        let cliSearch = cli.begin(cliID, supersede: false)!
        ui.cancel(cliID) // An ID from another connection cannot reach its token.
        XCTAssertFalse(cliSearch.isCancelled)
        let uiNewest = ui.begin(UUID(), supersede: true)!
        XCTAssertTrue(uiFirst.isCancelled)
        XCTAssertFalse(uiNewest.isCancelled)
        XCTAssertFalse(cliSearch.isCancelled)
        ui.close()
        XCTAssertTrue(ui.isClosed)
        XCTAssertTrue(uiNewest.isCancelled)
        XCTAssertFalse(cliSearch.isCancelled)
        XCTAssertNil(ui.begin(UUID(), supersede: false))
        cli.cancel(cliID)
        XCTAssertTrue(cliSearch.isCancelled)
    }

    func testIndependentRequestsTargetedCancellationAndBoundedLifetime() {
        let session = SearchSessionRequests(capacity: 2)
        let firstID = UUID()
        let secondID = UUID()
        let first = session.begin(firstID, supersede: false)!
        let second = session.begin(secondID, supersede: false)!
        XCTAssertNil(session.begin(UUID(), supersede: false))
        XCTAssertNil(session.begin(firstID, supersede: false))
        session.cancel(firstID)
        XCTAssertTrue(first.isCancelled)
        XCTAssertFalse(second.isCancelled)
        session.finish(firstID)
        XCTAssertNotNil(session.begin(UUID(), supersede: false))
        session.close()
        XCTAssertTrue(second.isCancelled)
    }

    func testSaturatedInteractiveSessionKeepsOnlyLatestPendingSearch() async throws {
        let state = SearchSessionState<String>(capacity: 8)
        let activeIDs = (0..<8).map { _ in UUID() }
        let active = activeIDs.compactMap { state.beginIndependent($0) }
        XCTAssertEqual(active.count, 8)
        let obsoleteID = UUID()
        guard case .accepted(replaced: nil) = state.offer("obsolete", id: obsoleteID) else {
            return XCTFail("Expected one pending search")
        }
        XCTAssertTrue(active.allSatisfy(\.isCancelled))
        XCTAssertNil(state.takeReady(acquire: { true }, releaseWithoutNotification: {}))

        let latestID = UUID()
        guard case .accepted(replaced: .some("obsolete")) = state.offer("latest", id: latestID) else {
            return XCTFail("Expected obsolete pending search to be replaced")
        }
        state.finish(activeIDs[0])
        var admission = false
        XCTAssertNil(state.takeReady(acquire: { admission }, releaseWithoutNotification: {}))
        admission = true
        let launch = try XCTUnwrap(state.takeReady(acquire: { admission },
                                                   releaseWithoutNotification: {}))
        XCTAssertEqual(launch.id, latestID)
        XCTAssertEqual(launch.work, "latest")
        XCTAssertFalse(launch.token.isCancelled)
        XCTAssertNil(state.takeReady(acquire: { true }, releaseWithoutNotification: {}))

        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        store.append(name: "latest", parent: root, size: 0, mtime: 0,
                     isDir: false, volID: 1)
        let actor = IndexActor(store: store, rules: ExcludeRules(), accessEnabled: true)
        let response = try await actor.searchResponse(launch.work, matchPath: false,
                                                      sort: .name, ascending: true,
                                                      isCancelled: { launch.token.isCancelled })
        XCTAssertEqual(response.records.map(\.name), ["latest"])
    }

    func testReplyCallbackWinsOnlyOnceAcrossRacingOutcomes() async throws {
        let once = ReplyOnce()
        let lock = NSLock()
        let replies = LockedReplies(lock: lock)
        let reply: @Sendable (Data) -> Void = { data in replies.append(data) }
        await withTaskGroup(of: Void.self) { group in
            for value in 0..<100 {
                group.addTask { once.deliver(Data([UInt8(value)]), to: reply) }
            }
        }
        XCTAssertEqual(replies.count, 1)
    }

    func testClientContinuationIgnoresLateReplyAfterFailure() async {
        do {
            let _: Data = try await withCheckedThrowingContinuation { continuation in
                let once = DataContinuationOnce(continuation)
                once.complete(.failure(ServiceErrorCode.cancelled))
                once.complete(.success(Data([1])))
            }
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? ServiceErrorCode, .cancelled)
        }
    }
    func testSigningIdentifiersMatchThePermissionAndTrustBoundaries() {
        XCTAssertEqual(appSigningIdentifier, "com.everythingmac.app")
        XCTAssertEqual(indexingServiceSigningIdentifier, appSigningIdentifier)
        XCTAssertEqual(searchServiceSigningIdentifier, "EverythingMacSearchService")
        XCTAssertNotEqual(appSigningIdentifier, searchServiceSigningIdentifier)
    }

    func testEveryOperationRoundTrips() throws {
        let requestID = UUID()
        for operation in [ServiceOperation.status, .search, .cancelSearch, .rebuild,
                          .getRules, .setRules] {
            let request = ServiceRequest(operation: operation, payload: Data([1, 2, 3]),
                                         requestID: requestID)
            let decoded = try JSONDecoder().decode(
                ServiceRequest.self, from: JSONEncoder().encode(request)
            )
            XCTAssertEqual(decoded.operation, operation)
            XCTAssertEqual(decoded.payload, request.payload)
            XCTAssertEqual(decoded.requestID, requestID)
        }
    }

    func testTrustedForwardingOverridesCallerPriorityAndAssignsRequestID() throws {
        let query = SearchRequest(text: "report", matchPath: false,
                                  caseInsensitive: true, wholeWord: false,
                                  usesRegularExpression: false, sort: .name,
                                  ascending: true, limit: 10, supersedeExisting: true)
        let request = ServiceRequest(operation: .search,
                                     payload: try JSONEncoder().encode(query))
        let forwarded = try request.trustedForwarding(interactive: false)
        XCTAssertNotNil(forwarded.requestID)
        let decoded = try JSONDecoder().decode(SearchRequest.self, from: XCTUnwrap(forwarded.payload))
        XCTAssertEqual(decoded.text, "report")
        XCTAssertEqual(decoded.supersedeExisting, false)
        let userRequest = ServiceRequest(operation: .search,
                                         payload: try JSONEncoder().encode(decoded),
                                         requestID: UUID())
        XCTAssertEqual(try userRequest.trustedForwarding(interactive: true).requestID,
                       userRequest.requestID)
    }

    func testSuccessAndFailureReplies() throws {
        let success = ServiceReply.success(["one", "two"])
        XCTAssertNil(success.error)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: XCTUnwrap(success.payload)),
                       ["one", "two"])

        let failure = ServiceReply.failure("Unavailable")
        XCTAssertNil(failure.payload)
        XCTAssertEqual(failure.error, "Unavailable")
        XCTAssertEqual(failure.errorCode, .internalError)
    }

    func testStatusSearchRequestAndResponseRoundTrip() throws {
        let status = ServiceStatus(totalCount: 42, revision: 7, scanning: true,
                                   hasFullDiskAccess: false)
        let decodedStatus = try roundTrip(status)
        XCTAssertEqual(decodedStatus.totalCount, 42)
        XCTAssertEqual(decodedStatus.revision, 7)
        XCTAssertTrue(decodedStatus.scanning)
        XCTAssertFalse(decodedStatus.hasFullDiskAccess)
        XCTAssertFalse(decodedStatus.ready)

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
        XCTAssertNil(decodedRequest.supersedeExisting)

        let record = FileRecord(id: 1, name: "résumé\n\u{1}.pdf", path: "/résumé\n\u{1}.pdf", parent: 0,
                                size: 10, mtime: 20, isDir: false, volID: 1)
        let response = try roundTrip(SearchResponse(records: [record], limit: 1,
                                                    truncated: true, scanning: true))
        XCTAssertEqual(response.records, [record])
        XCTAssertEqual(response.limit, 1)
        XCTAssertTrue(response.truncated)
        XCTAssertTrue(response.scanning)
    }

    func testServicePathsUsePrivateApplicationSupportNamespace() {
        XCTAssertEqual(ServicePaths.applicationSupportURL.lastPathComponent, "EverythingMac")
        XCTAssertEqual(ServicePaths.legacyApplicationSupportURL.lastPathComponent, "Everything-Mac")
        XCTAssertEqual(ServicePaths.cacheURL().lastPathComponent, "index.idx")
        XCTAssertEqual(ServicePaths.cacheURL().deletingLastPathComponent(),
                       ServicePaths.applicationSupportURL)
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}

final class IndexActorBoundaryTests: XCTestCase {
    func testInteractiveSearchRunsWhileBackgroundSnapshotSearchIsBusy() async throws {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        store.append(name: "candidate", parent: root, size: 0, mtime: 0,
                     isDir: false, volID: 1)
        for number in 0..<100_000 {
            store.append(name: "noise-\(number)", parent: root, size: 0, mtime: 0,
                         isDir: false, volID: 1)
        }
        let actor = IndexActor(store: store, rules: ExcludeRules(), accessEnabled: true)
        _ = try await actor.searchResponse("candidate", matchPath: false,
                                           sort: .name, ascending: true)
        let probe = BlockingSearchProbe()
        let background = Task {
            try await actor.searchResponse("", matchPath: false,
                                           sort: .name, ascending: true,
                                           interactive: false, isCancelled: { probe.check() })
        }
        XCTAssertEqual(probe.entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { probe.unblock() }
        let started = Date()
        let interactive = try await actor.searchResponse("candidate", matchPath: false,
                                                         sort: .name, ascending: true)
        print("Interactive search with 100000-record snapshot and blocked background: \(Date().timeIntervalSince(started)) s")
        XCTAssertEqual(interactive.records.map(\.name), ["candidate"])
        XCTAssertFalse(probe.wasReleased)
        _ = try await background.value
    }

    func testRegexScanObservesCancellationInsideActorWork() async {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        for number in 0..<12_000 {
            store.append(name: "candidate-\(number)-aaaaaaaaaaaaaaaa", parent: root,
                         size: 0, mtime: 0, isDir: false, volID: 1)
        }
        let actor = IndexActor(store: store, rules: ExcludeRules(), accessEnabled: true)
        let probe = CancellationProbe()
        do {
            _ = try await actor.searchResponse("candidate.*z", matchPath: false,
                                               usesRegularExpression: true,
                                               sort: .name, ascending: true,
                                               isCancelled: { probe.shouldCancel() })
            XCTFail("Expected cancellation during regex scan")
        } catch {
            XCTAssertEqual(error as? ServiceErrorCode, .cancelled)
        }
    }
    func testLegacyApplicationSupportDirectoryMigrates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyURL = root.appendingPathComponent("Everything-Mac", isDirectory: true)
        let currentURL = root.appendingPathComponent("EverythingMac", isDirectory: true)
        let cacheURL = legacyURL.appendingPathComponent("index.idx")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: legacyURL,
                                                withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: cacheURL)

        let preparedURL = IndexActor.prepareApplicationSupportDirectory(
            currentURL: currentURL,
            legacyURL: legacyURL
        )

        XCTAssertEqual(preparedURL, currentURL)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: currentURL.appendingPathComponent("index.idx").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: currentURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testEmptyActorStatusAndSearch() async {
        let actor = IndexActor()
        let initialCount = await actor.totalCount
        XCTAssertEqual(initialCount, 0)
        let status = await actor.serviceStatus(hasFullDiskAccess: false)
        XCTAssertEqual(status.totalCount, 0)
        XCTAssertEqual(status.revision, 0)
        XCTAssertFalse(status.scanning)
        XCTAssertFalse(status.hasFullDiskAccess)
        XCTAssertFalse(status.ready)
        let results = await actor.search("", matchPath: false, sort: .name, ascending: true)
        XCTAssertEqual(results, [])
    }

    func testPublishedEmptyIndexIsReadyAndNotTruncated() async throws {
        let actor = IndexActor(store: FileStore(), rules: ExcludeRules(), accessEnabled: true)
        let status = await actor.serviceStatus(hasFullDiskAccess: true)
        XCTAssertTrue(status.ready)
        XCTAssertEqual(status.totalCount, 0)
        let response = try await actor.searchResponse("missing", matchPath: false,
                                                      sort: .name, ascending: true, limit: 1)
        XCTAssertEqual(response.records, [])
        XCTAssertFalse(response.truncated)
        XCTAssertEqual(response.limit, 1)
    }

    func testSearchReportsInvalidQueryAndPermissionDenial() async {
        let cold = IndexActor()
        do {
            _ = try await cold.searchResponse("x", matchPath: false,
                                              sort: .name, ascending: true)
            XCTFail("Expected an unpublished index")
        } catch {
            XCTAssertEqual(error as? ServiceErrorCode, .indexNotReady)
        }
        let denied = IndexActor(store: FileStore(), rules: ExcludeRules(), accessEnabled: false)
        do {
            _ = try await denied.searchResponse("x", matchPath: false,
                                                sort: .name, ascending: true)
            XCTFail("Expected permission denial")
        } catch {
            XCTAssertEqual(error as? ServiceErrorCode, .permissionDenied)
        }
        let ready = IndexActor(store: FileStore(), rules: ExcludeRules(), accessEnabled: true)
        do {
            _ = try await ready.searchResponse("/limit 0", matchPath: false,
                                               sort: .name, ascending: true)
            XCTFail("Expected invalid query")
        } catch {
            XCTAssertEqual(error as? ServiceErrorCode, .invalidQuery)
        }
    }

    func testMalformedRegularExpressionsAreInvalidQueries() async {
        let actor = IndexActor(store: FileStore(), rules: ExcludeRules(), accessEnabled: true)
        for (source, raw) in [("[", true), ("/regex [", false), ("regex:[", false)] {
            do {
                _ = try await actor.searchResponse(source, matchPath: false,
                                                   usesRegularExpression: raw,
                                                   sort: .name, ascending: true)
                XCTFail("Expected invalid query for \(source)")
            } catch {
                XCTAssertEqual(error as? ServiceErrorCode, .invalidQuery)
            }
        }
    }

    func testBoundedSearchReportsExactTruncationAndQueryLimit() async throws {
        var store = FileStore()
        let root = store.append(name: "/", parent: FileStore.noParent, size: 0,
                                mtime: 0, isDir: true, volID: 1)
        store.append(name: "same", parent: root, size: 0, mtime: 0,
                     isDir: false, volID: 1)
        store.append(name: "other", parent: root, size: 0, mtime: 0,
                     isDir: false, volID: 1)
        let actor = IndexActor(store: store, rules: ExcludeRules(), accessEnabled: true)

        let exact = try await actor.searchResponse("same", matchPath: false,
                                                   sort: .name, ascending: true, limit: 1)
        XCTAssertEqual(exact.records.map(\.name), ["same"])
        XCTAssertFalse(exact.truncated)

        let capped = try await actor.searchResponse("/limit 1", matchPath: false,
                                                    sort: .name, ascending: true, limit: 2)
        XCTAssertEqual(capped.limit, 1)
        XCTAssertEqual(capped.records.count, 1)
        XCTAssertTrue(capped.truncated)
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
