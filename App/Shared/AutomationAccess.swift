import Foundation

/// Search-service owned preference. Its observers are invoked outside the lock.
final class AutomationAccess: @unchecked Sendable {
    private let lock = NSCondition()
    private let transitionLock = NSLock()
    private let url: URL
    private var enabled: Bool
    private var delivering = 0
    private var observers: [UUID: @Sendable () -> Void] = [:]

    init(url: URL = ServicePaths.applicationSupportURL.appendingPathComponent("automation-access")) {
        self.url = url
        enabled = (try? Data(contentsOf: url)) == Data("enabled\n".utf8)
    }

    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }

    func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock(); observers[id] = callback; lock.unlock()
        return id
    }

    func removeObserver(_ id: UUID?) {
        guard let id else { return }
        lock.lock(); observers.removeValue(forKey: id); lock.unlock()
    }

    func setEnabled(_ newValue: Bool) throws {
        transitionLock.lock()
        defer { transitionLock.unlock() }
        lock.lock()
        let callbacks: [@Sendable () -> Void]
        do {
            try persist(newValue)
            enabled = newValue
            callbacks = newValue ? [] : Array(observers.values)
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        for callback in callbacks { callback() }
        if !newValue {
            lock.lock()
            while delivering > 0 { lock.wait() }
            lock.unlock()
        }
    }

    /// A disable cannot acknowledge until every already-authorized reply has
    /// handed its bytes to the XPC callback. The callback runs outside locks.
    func deliverIfEnabled(_ body: () -> Void) -> Bool {
        lock.lock()
        guard enabled else { lock.unlock(); return false }
        delivering += 1
        lock.unlock()
        defer {
            lock.lock()
            delivering -= 1
            if delivering == 0 { lock.broadcast() }
            lock.unlock()
        }
        body()
        return true
    }

    private func persist(_ newValue: Bool) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              chmod(directory.path, 0o700) == 0 else { throw POSIXError(.EACCES) }
        let temporary = directory.appendingPathComponent(".automation-access-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { unlink(temporary.path) }
        defer { close(descriptor) }
        let data = Data((newValue ? "enabled\n" : "disabled\n").utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }
}
