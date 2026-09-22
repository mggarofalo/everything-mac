import Foundation
import XCTest

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
            XCTAssertEqual((error as NSError).code, CocoaError.xpcConnectionReplyInvalid.rawValue)
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
}
