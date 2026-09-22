import XCTest
import IndexCore

@MainActor
final class CLITests: XCTestCase {
    func testHelpAndVersionDoNotUseTransport() async {
        let transport = MockTransport()
        let runner = CLIRunner(transport: transport)

        let help = await runner.run(arguments: ["search", "--help"])
        let version = await runner.run(arguments: ["search", "--version"])

        XCTAssertEqual(help.exitCode, 0)
        XCTAssertTrue(String(decoding: help.stdout, as: UTF8.self).contains("Usage:"))
        XCTAssertEqual(version.exitCode, 0)
        XCTAssertEqual(transport.searches, 0)
    }

    func testPathsNullOutputPreservesControlCharacters() async {
        let record = FileRecord(id: 1, name: "a\nb", path: "/a\nb", parent: 0, size: 0, mtime: 0,
                                isDir: false, volID: 1)
        let transport = MockTransport(response: SearchResponse(records: [record], limit: 1000))
        let result = await CLIRunner(transport: transport).run(arguments: ["search", "--null", "--", "a"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, Data([47, 97, 10, 98, 0]))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testJSONEnvelopeEscapesFilenameAndReportsServiceValues() async throws {
        let record = FileRecord(id: 1, name: "a\tb", path: "/a\tb", parent: 0, size: 12, mtime: 1,
                                isDir: true, volID: 1)
        let transport = MockTransport(response: SearchResponse(records: [record], limit: 7, truncated: true, scanning: true))
        let result = await CLIRunner(transport: transport).run(arguments: ["search", "--format", "json", "--", "a"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["limit"] as? Int, 7)
        XCTAssertEqual(json["truncated"] as? Bool, true)
        XCTAssertEqual(json["scanning"] as? Bool, true)
        XCTAssertEqual((json["results"] as? [[String: Any]])?.first?["path"] as? String, "/a\tb")
    }

    func testInvalidArgumentsDoNotConnect() async {
        let transport = MockTransport()
        let result = await CLIRunner(transport: transport).run(arguments: ["search", "--limit", "0", "--", "a"])

        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(transport.searches, 0)
    }

    func testNonfiniteAndExcessiveTimeoutsExitTwoWithoutConnecting() async {
        let transport = MockTransport()
        for timeout in ["inf", "1e309", "1e308", "3600.001", "-1"] {
            let result = await CLIRunner(transport: transport).run(
                arguments: ["search", "--timeout", timeout, "--", "a"]
            )
            XCTAssertEqual(result.exitCode, 2, timeout)
            XCTAssertTrue(result.stdout.isEmpty, timeout)
        }
        XCTAssertEqual(transport.searches, 0)
    }

    func testUnavailableServiceUsesExitThree() async {
        let transport = MockTransport(error: CLIError.unavailable("Command-line search access is disabled."))
        let result = await CLIRunner(transport: transport).run(arguments: ["search", "--", "a"])

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "Command-line search access is disabled.\n")
    }

    func testDeadlineCancelsARequestThatNeverReplies() async {
        let transport = SlowTransport()
        let result = await CLIRunner(transport: transport).run(arguments: ["search", "--timeout", "0.001", "--", "a"])

        XCTAssertEqual(result.exitCode, 4)
        XCTAssertEqual(transport.cancellations, 1)
        XCTAssertEqual(transport.finished.wait(timeout: .now() + 1), .success)
    }

    func testCancellationCancelsOnlyThisRequestAndUsesSIGINTStatus() async {
        let transport = SlowTransport()
        let task = Task { await CLIRunner(transport: transport).run(arguments: ["search", "--", "a"]) }
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.exitCode, 130)
        XCTAssertEqual(transport.cancellations, 1)
        XCTAssertEqual(transport.finished.wait(timeout: .now() + 1), .success)
    }
}

private final class MockTransport: CLISearchTransport, @unchecked Sendable {
    private let response: SearchResponse
    private let error: CLIError?
    private(set) var searches = 0

    init(response: SearchResponse = SearchResponse(records: []), error: CLIError? = nil) {
        self.response = response
        self.error = error
    }

    func search(_ request: SearchRequest, requestID: UUID, deadline: Date) async throws -> SearchResponse {
        searches += 1
        if let error { throw error }
        return response
    }

    func cancel(_ requestID: UUID) async {}
}

private final class SlowTransport: CLISearchTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationCount = 0
    let finished = DispatchSemaphore(value: 0)
    var cancellations: Int { lock.lock(); defer { lock.unlock() }; return cancellationCount }

    func search(_ request: SearchRequest, requestID: UUID, deadline: Date) async throws -> SearchResponse {
        defer { finished.signal() }
        try await Task.sleep(for: .seconds(3_600))
        return SearchResponse(records: [])
    }

    func cancel(_ requestID: UUID) async { recordCancellation() }

    private func recordCancellation() {
        lock.lock(); cancellationCount += 1; lock.unlock()
    }
}
