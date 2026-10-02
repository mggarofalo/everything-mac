import Darwin
import Foundation

/// Package-only process control. Only exact executable paths in the destination
/// bundle are eligible, including the old indexer's removal-observer process.
struct UpgradeProcessControl {
    struct RunningProcess: Equatable {
        let pid: pid_t
        let uid: uid_t
        let path: String
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    let applicationURL: URL

    var executablePaths: Set<String> {
        Set(["EverythingMacApp", "EverythingMacIndexingService", "EverythingMacSearchService", "everythingmac"].map {
            applicationURL.appendingPathComponent("Contents/MacOS/" + $0).path
        })
    }

    func affectedUsers() throws -> Set<uid_t> {
        Set(try runningProcesses().map(\.uid)).union(consoleUser().map { [$0] } ?? []).subtracting([0])
    }

    func stop(users: Set<uid_t>) throws {
        for uid in users {
            for label in BackgroundServiceCatalog.all {
                // bootout removes the running jobs, not the user's BTM approval or
                // launchd disabled preference. The new app refreshes registration.
                _ = try run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
                guard try run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"]) != 0 else {
                    throw PackageInstallationError.processesStillRunning
                }
            }
        }
        try terminateRemainingProcesses()
    }

    func relaunch(users: Set<uid_t>) throws {
        var failed = false
        for uid in users {
            let result = try run("/bin/launchctl", ["asuser", String(uid), "/usr/bin/sudo", "-u", "#\(uid)",
                                                  "/usr/bin/open", applicationURL.path])
            if result != 0 { failed = true }
        }
        guard !failed else { throw PackageInstallationError.processesStillRunning }
    }

    func runningProcesses() throws -> [RunningProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { throw PackageInstallationError.processesStillRunning }
        var pids = [pid_t](repeating: 0, count: Int(count) + 128)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0, Int(filled) < pids.count else { throw PackageInstallationError.processesStillRunning }
        return pids.prefix(min(Int(filled), pids.count)).compactMap { pid in
            guard let process = Self.inspect(pid), executablePaths.contains(process.path) else { return nil }
            return process
        }
    }

    static func inspect(_ pid: pid_t) -> RunningProcess? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return RunningProcess(pid: pid, uid: info.pbi_uid, path: String(cString: buffer),
                              startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    private func terminateRemainingProcesses() throws {
        let processes = try runningProcesses()
        for process in processes { signal(SIGTERM, to: process) }
        let deadline = Date().addingTimeInterval(3)
        while processes.contains(where: { Self.inspect($0.pid) == $0 }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for process in processes { signal(SIGKILL, to: process) }
        let killDeadline = Date().addingTimeInterval(2)
        while try !runningProcesses().isEmpty, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.05) }
        guard try runningProcesses().isEmpty else { throw PackageInstallationError.processesStillRunning }
    }

    private func signal(_ signal: Int32, to process: RunningProcess) {
        // Recheck start time and path immediately before signalling to reject PID reuse.
        guard Self.inspect(process.pid) == process else { return }
        _ = kill(process.pid, signal)
    }

    private func consoleUser() -> uid_t? {
        var info = stat()
        guard stat("/dev/console", &info) == 0, info.st_uid != 0 else { return nil }
        return info.st_uid
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard !process.isRunning else {
            process.terminate()
            throw PackageInstallationError.processesStillRunning
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
