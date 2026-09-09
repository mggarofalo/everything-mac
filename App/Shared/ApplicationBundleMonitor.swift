import AppKit
import Darwin
import Foundation
import ServiceManagement

/// Runs a lightweight child process that cleans up after Finder moves the app to Trash.
///
/// A registered launch agent cannot reliably unregister itself because unregistering a
/// running service terminates that process. The indexer therefore launches a separate,
/// unregistered copy of its executable in observer mode. That process survives long
/// enough to remove application data and unregister both agents.
enum ApplicationBundleMonitor {
    fileprivate static let observerArgument = "--observe-app-removal"

    static func runObserverIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, arguments[1] == observerArgument,
              let parentPID = pid_t(arguments[3]) else {
            return false
        }

        let observer = RemovalObserver(
            appURL: URL(fileURLWithPath: arguments[2], isDirectory: true),
            parentPID: parentPID
        )
        observer.run()
        return true
    }

    static func launchObserver() {
        guard let executableURL = currentExecutableURL(),
              let appURL = containingAppURL(for: executableURL) else {
            NSLog("EverythingMac could not locate its installed bundle")
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [observerArgument, appURL.path, String(getpid())]
        do {
            try process.run()
        } catch {
            NSLog("EverythingMac could not start its uninstall observer: %@",
                  error.localizedDescription)
        }
    }

    private static func currentExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL
    }

    private static func containingAppURL(for executableURL: URL) -> URL? {
        var candidate = executableURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}

private final class RemovalObserver: @unchecked Sendable {
    private let appURL: URL
    private let parentPID: pid_t
    private let services = [
        SMAppService.agent(plistName: "com.everythingmac.indexer.plist"),
        SMAppService.agent(plistName: "com.everythingmac.search.plist"),
    ]
    private let queue = DispatchQueue(label: "com.everythingmac.bundle-monitor")
    private let lock = NSLock()
    private var cleanupScheduled = false
    private var transfersToReplacement = false
    private var bundleSource: (any DispatchSourceFileSystemObject)?
    private var parentSource: (any DispatchSourceProcess)?

    init(appURL: URL, parentPID: pid_t) {
        self.appURL = appURL.standardizedFileURL
        self.parentPID = parentPID

        let descriptor = open(appURL.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.delete, .rename, .revoke],
                queue: queue
            )
            source.setCancelHandler { close(descriptor) }
            source.setEventHandler { [weak self] in
                self?.scheduleCleanupCheck(transfersToReplacement: true)
            }
            bundleSource = source
        }

        let source = DispatchSource.makeProcessSource(
            identifier: parentPID,
            eventMask: .exit,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleCleanupCheck(transfersToReplacement: false)
        }
        parentSource = source
    }

    func run() {
        guard let bundleSource else {
            NSLog("EverythingMac could not monitor its app bundle: %s", strerror(errno))
            return
        }
        bundleSource.resume()
        parentSource?.resume()
        RunLoop.main.run()
    }

    private func scheduleCleanupCheck(transfersToReplacement: Bool) {
        lock.lock()
        guard !cleanupScheduled else {
            lock.unlock()
            return
        }
        cleanupScheduled = true
        self.transfersToReplacement = transfersToReplacement
        lock.unlock()

        bundleSource?.cancel()
        parentSource?.cancel()
        queue.asyncAfter(deadline: .now() + 2) { [self] in finish() }
    }

    private func finish() {
        if Bundle(url: appURL)?.bundleIdentifier == "com.everythingmac.app" {
            guard transfersToReplacement else { exit(EXIT_SUCCESS) }
            // Hand observation to the replacement's signed executable. The registered
            // indexer may continue running its old inode until launchd next restarts it.
            let process = Process()
            process.executableURL = appURL.appendingPathComponent(
                "Contents/MacOS/EverythingMacIndexingService"
            )
            process.arguments = [
                ApplicationBundleMonitor.observerArgument,
                appURL.path,
                String(parentPID),
            ]
            do {
                try process.run()
            } catch {
                NSLog("EverythingMac could not transfer its uninstall observer: %@",
                      error.localizedDescription)
            }
            exit(EXIT_SUCCESS)
        }

        do {
            try FileManager.default.removeItem(at: ServicePaths.applicationSupportURL)
        } catch {
            if (error as NSError).code != NSFileNoSuchFileError {
                NSLog("EverythingMac could not remove its index data: %@",
                      error.localizedDescription)
            }
        }

        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.everythingmac.app"
        ) {
            application.terminate()
        }

        for service in services {
            do {
                try service.unregister()
            } catch {
                if (error as NSError).code != kSMErrorJobNotFound {
                    NSLog("EverythingMac could not unregister a removed service: %@",
                          error.localizedDescription)
                }
            }
        }
        exit(EXIT_SUCCESS)
    }
}
