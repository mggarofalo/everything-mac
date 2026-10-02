import Darwin
import Foundation

enum PackageInstallationError: LocalizedError {
    case invalidBundle
    case downgrade
    case processesStillRunning
    case rollbackFailed(String)
    case unsupportedDestination

    var errorDescription: String? {
        switch self {
        case .invalidBundle: "The application package failed verification."
        case .downgrade: "A newer version of EverythingMac is already installed."
        case .processesStillRunning: "EverythingMac could not be stopped. The existing app was not replaced."
        case .rollbackFailed(let path): "Could not restore the previous app. Its backup is at \(path)."
        case .unsupportedDestination: "Install EverythingMac on the current startup disk in /Applications."
        }
    }
}

/// A staged, same-volume replacement. No cache or preference paths enter this API.
/// Validation completes before service shutdown; a failed post-swap validation rolls back.
struct PackageReplacement {
    var fileManager: FileManager = .default
    var validate: (URL) throws -> Void
    var prepare: () throws -> Void

    func install(source: URL, destination: URL) throws {
        try validate(source)
        let staging = try makeStagingDirectory(beside: destination)
        let stagedApp = staging.appendingPathComponent("EverythingMac.app")
        var keepBackup = false
        defer { if !keepBackup { try? fileManager.removeItem(at: staging) } }
        try fileManager.copyItem(at: source, to: stagedApp)
        try validate(stagedApp)
        try prepare()
        let replacing = fileManager.fileExists(atPath: destination.path)
        try commit(stagedApp, to: destination, replacing: replacing)
        do {
            try validate(destination)
        } catch {
            do {
                try rollback(stagedApp, destination: destination, replacing: replacing)
            } catch {
                keepBackup = true
                throw PackageInstallationError.rollbackFailed(stagedApp.path)
            }
            throw error
        }
    }

    private func makeStagingDirectory(beside destination: URL) throws -> URL {
        var template = Array(destination.deletingLastPathComponent()
            .appendingPathComponent(".EverythingMac-install.XXXXXX").path.utf8CString)
        guard let path = mkdtemp(&template) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private func commit(_ staged: URL, to destination: URL, replacing: Bool) throws {
        if replacing {
            // Atomic exchange avoids a missing-bundle interval and keeps the prior
            // bundle available in our private staging directory for rollback.
            guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    private func rollback(_ staged: URL, destination: URL, replacing: Bool) throws {
        if replacing {
            try commit(staged, to: destination, replacing: true)
        } else {
            try fileManager.removeItem(at: destination)
        }
    }
}
