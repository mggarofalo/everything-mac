import Foundation
import Security

// Both agents have access to sensitive whole-disk filenames. A same-user Mach
// service is not, by itself, an authorization boundary: accept only clients signed
// by the same development/distribution team and carrying the expected identifier.
enum ConnectionTrust {
    private struct Identity {
        let identifier: String
        let teamIdentifier: String
    }

    static func accepts(_ connection: NSXPCConnection, identifiers: Set<String>) -> Bool {
        guard let own = identityForSelf(),
              let guest = identity(forPID: connection.processIdentifier) else { return false }
        return own.teamIdentifier == guest.teamIdentifier && identifiers.contains(guest.identifier)
    }

    private static func identityForSelf() -> Identity? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return identity(for: code)
    }

    private static func identity(forPID pid: pid_t) -> Identity? {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return nil }
        return identity(for: code)
    }

    private static func identity(for code: SecCode) -> Identity? {
        guard SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return identity(for: staticCode)
    }

    private static func identity(for code: SecStaticCode) -> Identity? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        return Identity(identifier: identifier, teamIdentifier: team)
    }
}
