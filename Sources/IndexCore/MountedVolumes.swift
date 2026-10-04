import Foundation

/// Classify paths from the cached kernel mount table before inspecting the filesystem.
public enum MountedVolumes {
    public struct Mount: Sendable, Equatable {
        public let path: String
        public let isLocal: Bool

        public init(path: String, isLocal: Bool) { self.path = path; self.isLocal = isLocal }
    }

    public static func snapshot() -> [Mount] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        return (0..<Int(count)).map { i in
            var mount = buffer[i]
            let path = withUnsafePointer(to: &mount.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            return Mount(path: path, isLocal: (mount.f_flags & UInt32(MNT_LOCAL)) != 0)
        }
    }

    public static func permitsInspection(_ path: String, mounts: [Mount]? = nil) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let matching = (mounts ?? snapshot()).filter { IndexScope.contains(path, under: $0.path) }
        return matching.max { $0.path.count < $1.path.count }?.isLocal == true
    }
}
