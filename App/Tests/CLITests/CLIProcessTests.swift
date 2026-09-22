import Foundation
import XCTest
import Darwin

final class CLIProcessTests: XCTestCase {
    func testOfflineHelpAndVersionAreExecutableCommands() throws {
        for arguments in [["--help"], ["--version"]] {
            let child = try FixtureChild(arguments: arguments, mode: "trap")
            let result = child.finish()
            XCTAssertEqual(result.status, 0)
            XCTAssertTrue(result.stderr.isEmpty)
            XCTAssertFalse(result.stdout.isEmpty)
        }
    }

    func testUnavailableServiceExitsThreeWithoutStdout() throws {
        let child = try FixtureChild(arguments: ["search", "--", "needle"], mode: "unavailable")
        let result = child.finish()
        XCTAssertEqual(result.status, 3)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(result.stderr, Data("Fixture search service unavailable.\n".utf8))
    }

    func testNoReplyHonorsDeadlineAndCancelsWork() throws {
        let paths = try FixturePaths()
        let child = try FixtureChild(arguments: ["search", "--timeout", "0.05", "--", "needle"],
                                     mode: "never", paths: paths)
        let result = child.finish()
        XCTAssertEqual(result.status, 4)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(result.stderr, Data("Search timed out.\n".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cancel.path))
    }

    func testSIGINTExits130AndCancelsWork() throws {
        try assertSignalCancels(SIGINT)
    }

    func testSIGTERMExitsPromptlyAndCancelsWork() throws {
        try assertSignalCancels(SIGTERM)
    }

    func testClosedStdoutPipeExitsCleanly() throws {
        let paths = try FixturePaths()
        let child = try FixtureChild(arguments: ["search", "--", "needle"],
                                     mode: "results", paths: paths)
        XCTAssertTrue(paths.waitForReady())
        child.closeStdoutReader()
        try Data().write(to: paths.release)
        let result = child.finish(readStdout: false)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stderr.isEmpty)
    }

    private func assertSignalCancels(_ signalNumber: Int32) throws {
        let paths = try FixturePaths()
        let child = try FixtureChild(arguments: ["search", "--", "needle"],
                                     mode: "never", paths: paths)
        XCTAssertTrue(paths.waitForReady())
        XCTAssertEqual(kill(child.pid, signalNumber), 0)
        let result = child.finish()
        XCTAssertEqual(result.status, 130)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(result.stderr, Data("Search interrupted.\n".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cancel.path))
    }
}

private final class FixturePaths {
    let directory: URL
    let ready: URL
    let release: URL
    let cancel: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("everythingmac-cli-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ready = directory.appendingPathComponent("ready")
        release = directory.appendingPathComponent("release")
        cancel = directory.appendingPathComponent("cancel")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func waitForReady() -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: ready.path) { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }
}

private final class FixtureChild {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let completed = DispatchSemaphore(value: 0)

    var pid: pid_t { process.processIdentifier }

    init(arguments: [String], mode: String, paths: FixturePaths? = nil) throws {
        let products = Bundle(for: CLIProcessTests.self).bundleURL.deletingLastPathComponent()
        process.executableURL = products.appendingPathComponent("everythingmac-fixture")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["EVERYTHINGMAC_FIXTURE_MODE"] = mode
        environment["EVERYTHINGMAC_FIXTURE_READY_PATH"] = paths?.ready.path
        environment["EVERYTHINGMAC_FIXTURE_RELEASE_PATH"] = paths?.release.path
        environment["EVERYTHINGMAC_FIXTURE_CANCEL_PATH"] = paths?.cancel.path
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [completed] _ in completed.signal() }
        try process.run()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
    }

    deinit {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    func closeStdoutReader() { stdoutPipe.fileHandleForReading.closeFile() }

    func finish(readStdout: Bool = true) -> (status: Int32, stdout: Data, stderr: Data) {
        if completed.wait(timeout: .now() + 3) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            XCTFail("Fixture process did not exit promptly")
        }
        let stdout = readStdout ? stdoutPipe.fileHandleForReading.readDataToEndOfFile() : Data()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, stdout, stderr)
    }
}
