import Darwin
import Foundation

@main
struct EverythingMacInstaller {
    static func main() {
        do {
            guard geteuid() == 0, CommandLine.arguments.count == 2 else {
                throw PackageInstallationError.unsupportedDestination
            }
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            let destination = URL(fileURLWithPath: "/Applications/EverythingMac.app", isDirectory: true)
            let team = try InstallerTrust.signingTeam(executable: executable)
            try InstallerTrust.validate(source, team: team)
            try InstallerTrust.preventDowngrade(source: source, destination: destination)
            let control = UpgradeProcessControl(applicationURL: destination)
            let users = try control.affectedUsers()
            let replacement = PackageReplacement(validate: { try InstallerTrust.validate($0, team: team) },
                                                 prepare: { try control.stop(users: users) })
            do {
                try replacement.install(source: source, destination: destination)
            } catch {
                try? control.relaunch(users: users)
                throw error
            }
            do {
                try control.relaunch(users: users)
            } catch {
                // Installation succeeded. A locked or absent GUI session must not
                // turn a valid installed app into a failed package transaction.
                FileHandle.standardError.write(Data("EverythingMac installed. Open it from Applications to start its services.\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("EverythingMac installation failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
