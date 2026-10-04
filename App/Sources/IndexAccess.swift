import Foundation
import IndexCore

/// Owns durable folder authority. Index policy sees resolved roots, never bookmarks.
actor IndexAccess {
    private struct Folder: Codable, Sendable {
        var bookmark: Data
        let path: String
        let device: UInt64
        let inode: UInt64
    }

    private struct Configuration: Codable {
        var mode: IndexScope.Mode
        var folders: [Folder]
    }

    private let url: URL
    private var configuration: Configuration
    private var leases: [URL] = []
    private var revision: UInt64 = 0
    private var needsPersist = true

    init(url: URL? = nil,
         legacyCacheExists: Bool? = nil) {
        let url = url ?? ServicePaths.prepareApplicationSupportDirectory().appendingPathComponent("scope.json")
        self.url = url
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Configuration.self, from: data) {
            configuration = saved
        } else {
            let cacheURL = url.deletingLastPathComponent().appendingPathComponent("index.idx")
            let legacy = legacyCacheExists ?? FileManager.default.fileExists(atPath: cacheURL.path)
            // An unreadable/corrupt existing scope must fail closed, not migrate again.
            let mode: IndexScope.Mode = !FileManager.default.fileExists(atPath: url.path) && legacy
                ? .localVolumes : .selectedFolders
            configuration = Configuration(mode: mode, folders: [])
        }
    }

    func settings() -> IndexScopeSettings {
        IndexScopeSettings(mode: configuration.mode, folders: configuration.folders.map(\.path))
    }

    func update(_ update: IndexScopeUpdate) throws -> ResolvedIndexAccess {
        let retained = Set(update.retainedFolders)
        guard retained.isSubset(of: Set(configuration.folders.map(\.path))) else {
            throw ServiceErrorCode.invalidQuery
        }
        var folders = configuration.folders.filter { retained.contains($0.path) }
        for bookmark in update.addedBookmarks {
            let received = try receive(bookmark)
            folders.removeAll { $0.path == received.path }
            folders.append(received)
        }
        let roots = IndexScope(mode: .selectedFolders, roots: folders.map(\.path)).roots
        let unique = roots.compactMap { path in folders.first { $0.path == path } }
        let previous = configuration
        configuration = Configuration(mode: update.mode, folders: unique)
        do { try persist(); needsPersist = false } catch { configuration = previous; throw error }
        return resolve()
    }

    func resolve() -> ResolvedIndexAccess {
        let previousLeases = leases
        defer { previousLeases.forEach { $0.stopAccessingSecurityScopedResource() } }
        leases.removeAll()
        var roots: [String] = []
        var identities: [String: DirectoryIdentity] = [:]
        var issues: [ScanIssue] = []
        for i in configuration.folders.indices where configuration.mode == .selectedFolders {
            do {
                let folder = configuration.folders[i]
                var stale = false
                let resolved = try URL(resolvingBookmarkData: folder.bookmark,
                                       options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                       relativeTo: nil, bookmarkDataIsStale: &stale)
                let started = resolved.startAccessingSecurityScopedResource()
                var accepted = false
                defer { if started && !accepted { resolved.stopAccessingSecurityScopedResource() } }
                let path = IndexScope.canonicalPath(resolved.path)
                // A moved root requires reselection; never follow a replacement at its old path.
                let identity = try Self.directoryIdentity(path)
                guard path == folder.path, identity == (folder.device, folder.inode) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                if stale {
                    configuration.folders[i].bookmark = try Self.durableBookmark(resolved)
                    needsPersist = true
                }
                if started { leases.append(resolved) }
                accepted = true
                roots.append(path)
                identities[path] = DirectoryIdentity(device: folder.device, inode: folder.inode)
            } catch {
                issues.append(ScanIssue(path: configuration.folders[i].path,
                                        errorCode: Self.posixCode(error)))
            }
        }
        if needsPersist {
            do { try persist(); needsPersist = false } catch { /* Retry persistence on the next refresh. */ }
        }
        let scope = IndexScope(mode: configuration.mode, roots: roots, identities: identities)
        revision &+= 1
        return ResolvedIndexAccess(revision: revision, scope: scope, settings: settings(), issues: issues)
    }

    private func receive(_ data: Data) throws -> Folder {
        var stale = false
        // Implicit scope transfers access from the picker through the forwarding service.
        let selected = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        defer { selected.stopAccessingSecurityScopedResource() }
        let path = IndexScope.canonicalPath(selected.path)
        let (device, inode) = try Self.directoryIdentity(path)
        return Folder(bookmark: try Self.durableBookmark(selected), path: path,
                      device: device, inode: inode)
    }

    private static func durableBookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func directoryIdentity(_ path: String) throws -> (UInt64, UInt64) {
        guard MountedVolumes.permitsInspection(path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard let dir = opendir(path) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        closedir(dir)
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    private static func posixCode(_ error: Error) -> Int32 {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
        return error.code == CocoaError.fileReadNoSuchFile.rawValue ? ENOENT : EPERM
    }

    private func persist() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(configuration)
        let staging = directory.appendingPathComponent("scope.\(UUID().uuidString).staging")
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { try? FileManager.default.removeItem(at: staging) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(staging.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
