import Foundation

/// Filesystem enumeration is shared by initial scans and live reconciliation.
/// Index policy receives names and inspection failures, never an open directory.
enum DirectoryReader {
    struct Snapshot {
        let names: [String]
        let inProjectDir: Bool
        let mounts: [MountedVolumes.Mount]
        let errorCode: Int32?
        let opened: Bool
    }

    static func read(_ path: String, mounts: [MountedVolumes.Mount]? = nil) -> Snapshot {
        let mounts = mounts ?? MountedVolumes.snapshot()
        guard MountedVolumes.permitsInspection(path, mounts: mounts) else {
            return failure(ENOTSUP, mounts: mounts)
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return failure(errno, mounts: mounts) }
        guard let directory = fdopendir(descriptor) else {
            let error = errno
            close(descriptor)
            return failure(error, mounts: mounts)
        }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            names.append(name)
        }
        let errorCode: Int32? = errno == 0 ? nil : errno
        return Snapshot(names: names, inProjectDir: names.contains { ExcludeRules.projectMarkers.contains($0) },
                        mounts: mounts, errorCode: errorCode, opened: true)
    }

    private static func failure(_ errorCode: Int32, mounts: [MountedVolumes.Mount]) -> Snapshot {
        Snapshot(names: [], inProjectDir: false, mounts: mounts, errorCode: errorCode, opened: false)
    }
}
