import Foundation
import XCTest

private final class DelayedStatusForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private var statusCallback: (@Sendable (Data) -> Void)?
    private var statusReplies = 0
    private var pingReplies = 0

    func forward(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        let request = try? JSONDecoder().decode(ServiceRequest.self, from: data)
        switch request?.operation {
        case .status:
            lock.lock(); statusCallback = reply; lock.unlock()
        case .ping:
            reply((try? JSONEncoder().encode(ServiceReply.success(true))) ?? Data())
        default:
            reply((try? JSONEncoder().encode(ServiceReply.failure("Unexpected request"))) ?? Data())
        }
    }

    func completeStatus() {
        lock.lock(); let callback = statusCallback; lock.unlock()
        let status = ServiceStatus(totalCount: 12, revision: 1, scanning: false,
                                   hasFullDiskAccess: true)
        callback?((try? JSONEncoder().encode(ServiceReply.success(status))) ?? Data())
    }

    func recordStatus(_ data: Data) {
        lock.lock(); statusReplies += 1; lock.unlock()
    }

    func recordPing(_ data: Data) {
        lock.lock(); pingReplies += 1; lock.unlock()
    }

    var counts: (Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return (statusReplies, pingReplies)
    }
}

final class StartupRecoveryTests: XCTestCase {
    func testBundleReplacementChangesIdentityEvenAtTheSamePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("App.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try XCTUnwrap(BundleInstallation.identity(at: app))
        XCTAssertEqual(BundleInstallation.identity(at: app), original)
        try FileManager.default.moveItem(at: app, to: root.appendingPathComponent("Previous.app"))
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertNotEqual(try XCTUnwrap(BundleInstallation.identity(at: app)), original)
        XCTAssertNil(BundleInstallation.identity(at: root.appendingPathComponent("missing")))
    }

    func testUnansweredRequestTimesOutAndIgnoresLateReply() async {
        let finished = expectation(description: "Status probe times out")
        finished.assertForOverFulfill = true
        let waiter = ServiceReplyWaiter { result in
            guard case .failure(let error) = result else {
                XCTFail("Unanswered request must fail")
                finished.fulfill()
                return
            }
            XCTAssertTrue(error is ServiceReplyTimeout)
            finished.fulfill()
        }
        waiter.timeOut(after: 0.01)
        await fulfillment(of: [finished], timeout: 1)
        waiter.finish(.success(Data([1])))
        waiter.finish(.failure(CocoaError(.xpcConnectionInvalid)))
    }

    func testReplyWinsBeforeDeadlineAndCompletesOnlyOnce() async {
        let finished = expectation(description: "Reply completes once")
        finished.assertForOverFulfill = true
        let waiter = ServiceReplyWaiter { result in
            XCTAssertEqual(try? result.get(), Data([42]))
            finished.fulfill()
        }
        waiter.timeOut(after: 0.01)
        waiter.finish(.success(Data([42])))
        waiter.finish(.success(Data([99])))
        await fulfillment(of: [finished], timeout: 1)
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    func testConnectionErrorWinsBeforeDeadline() async {
        let finished = expectation(description: "Connection error completes once")
        finished.assertForOverFulfill = true
        let waiter = ServiceReplyWaiter { result in
            guard case .failure(let error) = result else { XCTFail("Expected error"); return }
            XCTAssertEqual((error as NSError).code, CocoaError.xpcConnectionInvalid.rawValue)
            finished.fulfill()
        }
        waiter.timeOut(after: 0.01)
        waiter.finish(.failure(CocoaError(.xpcConnectionInvalid)))
        await fulfillment(of: [finished], timeout: 1)
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    func testHealthyProbeLeavesSlowStatusPendingUntilItsRealReply() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("everythingmac-startup-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let admission = ConnectionAdmission(capacity: 1)
        let forwarder = DelayedStatusForwarder()
        let service = SearchService(lease: try XCTUnwrap(admission.acquire()), role: .app,
                                    automation: AutomationAccess(url: directory),
                                    testForward: { data, reply in forwarder.forward(data, reply: reply) })
        defer { service.close() }
        let status = try JSONEncoder().encode(ServiceRequest(operation: .status, payload: nil))
        let ping = try JSONEncoder().encode(ServiceRequest(operation: .ping, payload: nil))
        let receivedStatus = expectation(description: "Delayed status arrives")
        let receivedPing = expectation(description: "Indexer replies while status is pending")

        let waiter = ServiceReplyWaiter { result in
            guard let data = try? result.get(),
                  let envelope = try? JSONDecoder().decode(ServiceReply.self, from: data),
                  let payload = envelope.payload,
                  let value = try? JSONDecoder().decode(ServiceStatus.self, from: payload) else {
                XCTFail("Expected the original status reply")
                receivedStatus.fulfill()
                return
            }
            XCTAssertEqual(value.totalCount, 12)
            forwarder.recordStatus(data)
            receivedStatus.fulfill()
        }
        service.perform(status) { waiter.finish(.success($0)) }
        waiter.onDeadline(after: 0.01) {
            service.perform(ping) { data in
                let envelope = try? JSONDecoder().decode(ServiceReply.self, from: data)
                let isAlive = envelope?.payload.flatMap {
                    try? JSONDecoder().decode(Bool.self, from: $0)
                }
                XCTAssertEqual(isAlive, true)
                forwarder.recordPing(data)
                receivedPing.fulfill()
            }
        }
        await fulfillment(of: [receivedPing], timeout: 1)
        XCTAssertEqual(forwarder.counts.0, 0)
        forwarder.completeStatus()
        await fulfillment(of: [receivedStatus], timeout: 1)
        waiter.finish(.failure(ServiceReplyTimeout.elapsed))
        XCTAssertEqual(forwarder.counts.0, 1)
        XCTAssertEqual(forwarder.counts.1, 1)
    }

    func testFailedHealthProbeEndsStatusOnceAndIgnoresLateReply() async {
        let finished = expectation(description: "Unresponsive service fails status")
        finished.assertForOverFulfill = true
        let status = ServiceReplyWaiter { result in
            guard case .failure(let error) = result else {
                XCTFail("Expected health failure")
                finished.fulfill()
                return
            }
            XCTAssertTrue(error is ServiceReplyTimeout)
            finished.fulfill()
        }
        status.onDeadline(after: 0.01) {
            let ping = ServiceReplyWaiter { result in
                if case .failure = result {
                    status.finish(.failure(ServiceReplyTimeout.elapsed))
                }
            }
            ping.timeOut(after: 0.01)
        }
        await fulfillment(of: [finished], timeout: 1)
        status.finish(.success(Data([1])))
    }
}
