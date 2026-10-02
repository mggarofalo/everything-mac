import Foundation
import Security

enum InstallerTrust {
    /// Derive the signing team from the package's signed helper, never from a
    /// preference, environment variable, or the existing user-writable app.
    static func signingTeam(executable: URL) throws -> String {
        let code = try staticCode(at: executable)
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw PackageInstallationError.invalidBundle
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw PackageInstallationError.invalidBundle
        }
        return team
    }

    static func validate(_ app: URL, team: String) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.everythingmac.app",
              buildNumber(at: app) != nil else { throw PackageInstallationError.invalidBundle }
        let specifications = [
            (app, "com.everythingmac.app"),
            (app.appendingPathComponent("Contents/MacOS/EverythingMacIndexingService"), "com.everythingmac.app"),
            (app.appendingPathComponent("Contents/MacOS/EverythingMacSearchService"), "EverythingMacSearchService"),
            (app.appendingPathComponent("Contents/MacOS/everythingmac"), "com.everythingmac.cli"),
        ]
        for (url, identifier) in specifications {
            try validateCode(at: url, identifier: identifier, team: team)
        }
    }

    static func preventDowngrade(source: URL, destination: URL) throws {
        guard let installed = buildNumber(at: destination), let proposed = buildNumber(at: source) else { return }
        guard proposed >= installed else { throw PackageInstallationError.downgrade }
    }

    static func buildNumber(at app: URL) -> Int? {
        // Read fresh bytes: Bundle caches Info.plist across an atomic replacement.
        let url = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = info["CFBundleVersion"] as? String,
              let number = Int(value), number > 0 else { return nil }
        return number
    }

    private static func validateCode(at url: URL, identifier: String, team: String) throws {
        let requirement = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        var expected: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &expected) == errSecSuccess,
              let expected else { throw PackageInstallationError.invalidBundle }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(try staticCode(at: url), flags, expected) == errSecSuccess else {
            throw PackageInstallationError.invalidBundle
        }
    }

    private static func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { throw PackageInstallationError.invalidBundle }
        return code
    }
}
