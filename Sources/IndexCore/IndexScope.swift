import Foundation

/// The same roots govern scanning, event reconciliation, and durable coverage.
public struct IndexScope: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case selectedFolders, localVolumes }
    public let mode: Mode
    public let roots: [String]
    public let identities: [String: DirectoryIdentity]

    public init(mode: Mode, roots: [String] = [], identities: [String: DirectoryIdentity] = [:]) {
        self.mode = mode
        let normalized = mode == .localVolumes ? ["/"] : Self.normalizedRoots(roots)
        self.roots = normalized
        self.identities = identities.filter { normalized.contains($0.key) }
    }

    public static let localVolumes = IndexScope(mode: .localVolumes)
    public static let empty = IndexScope(mode: .selectedFolders)

    public func contains(_ path: String) -> Bool {
        roots.contains { Self.contains(path, under: $0) }
    }

    public static func contains(_ path: String, under root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }

    public static func canonicalPath(_ path: String) -> String {
        let alias = "/System/Volumes/Data"
        if path == alias { return "/" }
        let canonical = path.hasPrefix(alias + "/") ? String(path.dropFirst(alias.count)) : path
        for prefix in ["/var", "/tmp", "/etc"] {
            if canonical == prefix || canonical.hasPrefix(prefix + "/") { return "/private" + canonical }
        }
        return canonical
    }

    public func fingerprint(rules: ExcludeRules) -> UInt64 {
        var hash = rules.fingerprint()
        for byte in ("scope1\u{0}" + mode.rawValue + "\u{0}" + roots.joined(separator: "\u{0}")).utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        for path in identities.keys.sorted() {
            let identity = identities[path]!
            for byte in "\(path)\u{0}\(identity.device):\(identity.inode)\u{0}".utf8 {
                hash = (hash ^ UInt64(byte)) &* 1099511628211
            }
        }
        return hash
    }

    private static func normalizedRoots(_ paths: [String]) -> [String] {
        let normalized = Set(paths.filter { $0.hasPrefix("/") }.map {
            canonicalPath(($0 as NSString).standardizingPath)
        }).sorted()
        return normalized.filter { path in
            !normalized.contains { $0 != path && contains(path, under: $0) }
        }
    }
}

public struct DirectoryIdentity: Codable, Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct ScanIssue: Codable, Sendable, Equatable {
    public let path: String
    public let errorCode: Int32

    public init(path: String, errorCode: Int32) {
        self.path = path
        self.errorCode = errorCode
    }

    public var accessDenied: Bool { errorCode == EACCES || errorCode == EPERM }
}

public struct ScanResult: Sendable {
    public let store: FileStore
    public let issues: [ScanIssue]
}
