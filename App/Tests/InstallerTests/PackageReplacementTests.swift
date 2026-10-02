import Foundation
import XCTest

final class PackageReplacementTests: XCTestCase {
    private enum Failure: Error { case expected }

    private func fixture(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.app")
        let destination = root.appendingPathComponent("installed.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("version"))
        try body(root, source, destination)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.hasPrefix(".EverythingMac-install.") })
    }

    private func writeOld(_ destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("version"))
    }

    private func version(_ destination: URL) throws -> String {
        try String(contentsOf: destination.appendingPathComponent("version"), encoding: .utf8)
    }

    func testFreshInstallAndUpgradePreserveUnrelatedData() throws {
        for upgrading in [false, true] {
            try fixture { root, source, destination in
                if upgrading { try writeOld(destination) }
                let cache = root.appendingPathComponent("index.cache")
                try Data("private index".utf8).write(to: cache)
                var prepared = false
                let installer = PackageReplacement(validate: { url in
                    XCTAssertEqual(try self.version(url), "new")
                }, prepare: {
                    prepared = true
                    if upgrading { XCTAssertEqual(try self.version(destination), "old") }
                })
                try installer.install(source: source, destination: destination)
                XCTAssertTrue(prepared)
                XCTAssertEqual(try version(destination), "new")
                XCTAssertEqual(try Data(contentsOf: cache), Data("private index".utf8))
            }
        }
    }

    func testInvalidSourceOrStageDoesNotStopProcessesOrReplaceOldApp() throws {
        for failingValidation in [1, 2] {
            try fixture { _, source, destination in
                try writeOld(destination)
                var validations = 0
                let installer = PackageReplacement(validate: { _ in
                    validations += 1
                    if validations == failingValidation { throw Failure.expected }
                }, prepare: { XCTFail("Must validate before shutdown") })
                XCTAssertThrowsError(try installer.install(source: source, destination: destination))
                XCTAssertEqual(try version(destination), "old")
            }
        }
    }

    func testShutdownFailureLeavesOldAppInstalled() throws {
        try fixture { _, source, destination in
            try writeOld(destination)
            let installer = PackageReplacement(validate: { _ in }, prepare: { throw Failure.expected })
            XCTAssertThrowsError(try installer.install(source: source, destination: destination))
            XCTAssertEqual(try version(destination), "old")
        }
    }

    func testPostCommitFailureRestoresOldAppOrRemovesFailedFreshInstall() throws {
        for upgrading in [false, true] {
            try fixture { _, source, destination in
                if upgrading { try writeOld(destination) }
                let installer = PackageReplacement(validate: { url in
                    if url == destination {
                        XCTAssertEqual(try self.version(url), "new")
                        throw Failure.expected
                    }
                }, prepare: {})
                XCTAssertThrowsError(try installer.install(source: source, destination: destination))
                if upgrading {
                    XCTAssertEqual(try version(destination), "old")
                } else {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                }
            }
        }
    }

    func testDowngradeRejectedAndBuildReadAfterReplacementIsFresh() throws {
        try fixture { _, source, destination in
            func writeBuild(_ value: String, to app: URL) throws {
                let contents = app.appendingPathComponent("Contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(
                    fromPropertyList: ["CFBundleVersion": value], format: .xml, options: 0)
                try data.write(to: contents.appendingPathComponent("Info.plist"))
            }
            try writeBuild("29", to: source)
            try writeBuild("30", to: destination)
            XCTAssertThrowsError(try InstallerTrust.preventDowngrade(source: source, destination: destination))
            try writeBuild("28", to: destination)
            XCTAssertNoThrow(try InstallerTrust.preventDowngrade(source: source, destination: destination))
            XCTAssertEqual(InstallerTrust.buildNumber(at: destination), 28)
            XCTAssertThrowsError(try InstallerTrust.validate(source, team: "649367BDD4"))
        }
    }

    func testProcessSelectionIsConfinedToDestinationBundle() throws {
        let control = UpgradeProcessControl(applicationURL: URL(fileURLWithPath: "/Applications/EverythingMac.app"))
        XCTAssertEqual(control.executablePaths.count, 4)
        XCTAssertTrue(control.executablePaths.contains(
            "/Applications/EverythingMac.app/Contents/MacOS/EverythingMacIndexingService"))
        XCTAssertFalse(control.executablePaths.contains("/tmp/EverythingMacApp"))
        XCTAssertNotNil(UpgradeProcessControl.inspect(getpid()))
        let unused = UpgradeProcessControl(applicationURL: URL(fileURLWithPath: "/nonexistent-" + UUID().uuidString))
        XCTAssertTrue(try unused.runningProcesses().isEmpty)
    }
}
