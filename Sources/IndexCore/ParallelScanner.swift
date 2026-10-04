import Foundation

// Whole-disk scanner that walks the tree with a pool of worker threads pulling
// from a shared directory work-queue. Replaces the old single-threaded async
// recursion that ran on the IndexActor: that walk paid continuation overhead per
// directory and, worse, contended with searches re-sorting the growing index on
// every progress tick. This runs entirely off the actor and saturates all cores,
// taking a whole-disk scan from minutes to tens of seconds.
public enum ParallelScanner {

    // Mutable index shared by all workers, guarded by one lock. The lock is held
    // only to append a directory's already-stat'd entries (a memory-only burst);
    // the expensive readdir/lstat happens outside it, so contention stays low.
    final class Builder: @unchecked Sendable {
        private var store = FileStore()
        private let lock = NSLock()
        private var lastReported = 0
        private var issues: [ScanIssue] = []
        private let progress: (@Sendable (Int) -> Void)?

        init(progress: (@Sendable (Int) -> Void)?) { self.progress = progress }

        func appendRoot(name: String) -> UInt32 {
            lock.lock(); defer { lock.unlock() }
            return store.append(name: name, parent: FileStore.noParent,
                                size: 0, mtime: 0, isDir: true, volID: 1)
        }

        // Append all children of `parent`, returning their ids in input order so
        // the caller can pair subdirectory entries with their new ids.
        func appendChildren(_ entries: [Entry], parent: UInt32) -> [UInt32] {
            lock.lock()
            let ids = entries.map {
                store.append(name: $0.name, parent: parent, size: $0.size,
                             mtime: $0.mtime, isDir: $0.isDir, volID: 1)
            }
            let count = store.count
            let crossed = count / 50_000 != lastReported / 50_000
            lastReported = count
            lock.unlock()
            if crossed { progress?(count) }
            return ids
        }

        func recordIssue(path: String, errorCode: Int32) {
            lock.lock(); defer { lock.unlock() }
            if issues.count < 100 { issues.append(ScanIssue(path: path, errorCode: errorCode)) }
        }

        func finish() -> ScanResult {
            lock.lock(); defer { lock.unlock() }
            return ScanResult(store: store, issues: issues)
        }
    }

    struct Entry { let name: String; let path: String; let isDir: Bool; let size: UInt64; let mtime: Int64 }

    // Lock-protected work stack with active-worker accounting so a worker only
    // concludes the scan is finished when the stack is empty AND no peer is still
    // mid-directory (and could yet push more subdirectories).
    final class DirQueue: @unchecked Sendable {
        private var stack: [(path: String, parent: UInt32)] = []
        private let lock = NSLock()
        private var active = 0

        init(seeds: [(String, UInt32)]) { stack = seeds }

        func push(_ items: [(String, UInt32)]) {
            guard !items.isEmpty else { return }
            lock.lock(); stack.append(contentsOf: items); lock.unlock()
        }

        // Claim the next directory, or return nil once the whole tree is done.
        func claim() -> (path: String, parent: UInt32)? {
            while true {
                lock.lock()
                if let item = stack.popLast() { active += 1; lock.unlock(); return item }
                if active == 0 { lock.unlock(); return nil }   // empty + nobody working → done
                lock.unlock()
                usleep(200)                                    // peers may still push
            }
        }

        func release() { lock.lock(); active -= 1; lock.unlock() }
    }

    /// Scan the entire filesystem from "/" and return a single FileStore.
    /// `rules` should already include the firmlink back-door exclusions so the
    /// Data volume isn't counted twice. Blocks the calling thread until complete,
    /// so call it from a detached task, never on the actor.
    public static func scanWholeDisk(rules: ExcludeRules,
                                     progress: (@Sendable (Int) -> Void)? = nil) -> FileStore {
        scan(rootPath: "/", rules: rules,
             workerCount: max(2, ProcessInfo.processInfo.activeProcessorCount),
             progress: progress)
    }

    /// Scoped entry point used by tests to exercise the same parallel scanner without
    /// traversing the machine's real root. Production uses `scanWholeDisk` above.
    static func scan(rootPath: String, rules: ExcludeRules, workerCount: Int,
                     progress: (@Sendable (Int) -> Void)? = nil) -> FileStore {
        scan(roots: [rootPath], rules: rules, workerCount: workerCount, progress: progress).store
    }

    public static func scan(roots: [String], rules: ExcludeRules,
                            identities: [String: DirectoryIdentity] = [:],
                            workerCount: Int = max(2, ProcessInfo.processInfo.activeProcessorCount),
                            progress: (@Sendable (Int) -> Void)? = nil) -> ScanResult {
        let builder = Builder(progress: progress)
        let acceptedRoots = roots.filter { path in
            guard let expected = identities[path] else { return true }
            if rootMatches(path, identity: expected) { return true }
            builder.recordIssue(path: path, errorCode: ENOENT)
            return false
        }
        let seeds = acceptedRoots.map { path in
            let name = path == "/" || !path.hasSuffix("/") ? path : String(path.dropLast())
            return (name, builder.appendRoot(name: name))
        }
        let queue = DirQueue(seeds: seeds)

        DispatchQueue.concurrentPerform(iterations: max(1, workerCount)) { _ in
            while let (path, parent) = queue.claim() {
                let entries = readDirectory(path, rules: rules, builder: builder)
                let ids = builder.appendChildren(entries, parent: parent)
                var subdirs: [(String, UInt32)] = []
                for (entry, id) in zip(entries, ids) where entry.isDir {
                    subdirs.append((entry.path, id))
                }
                queue.push(subdirs)
                queue.release()
            }
        }
        return builder.finish()
    }

    public static func rootMatches(_ path: String, identity: DirectoryIdentity) -> Bool {
        guard MountedVolumes.permitsInspection(path) else { return false }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        return UInt64(info.st_dev) == identity.device && UInt64(info.st_ino) == identity.inode
    }

    // One directory level: readdir + lstat each entry, applying exclude rules.
    // lstat (not stat) means symlinked directories are recorded but never
    // descended into, so the firmlink/symlink graph can't create scan loops.
    //
    // Two passes: the first reads names only (no stat) and notes whether this
    // directory holds a project marker (Cargo.toml/package.json/.git/…); the second
    // applies the now-marker-aware exclude rules and stats only the survivors. The
    // marker pass is what lets generic names like "build"/"target" be skipped inside
    // a real project but kept for an unrelated user folder of the same name.
    private static func readDirectory(_ path: String, rules: ExcludeRules, builder: Builder) -> [Entry] {
        let snapshot = DirectoryReader.read(path)
        if let error = snapshot.errorCode { builder.recordIssue(path: path, errorCode: error) }
        var out: [Entry] = []
        out.reserveCapacity(snapshot.names.count)
        for name in snapshot.names {
            let full = path == "/" ? "/" + name : path + "/" + name
            guard MountedVolumes.permitsInspection(full, mounts: snapshot.mounts) else { continue }
            let isHidden = name.hasPrefix(".")
            if rules.shouldExclude(name: name, path: full, isHidden: isHidden, inProjectDir: snapshot.inProjectDir) { continue }
            var st = stat()
            guard lstat(full, &st) == 0 else {
                builder.recordIssue(path: full, errorCode: errno)
                continue
            }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            // File-name exclude patterns apply to files only.
            if !isDir && rules.shouldExcludeFile(name: name) { continue }
            out.append(Entry(name: name, path: full, isDir: isDir,
                             size: UInt64(st.st_size), mtime: Int64(st.st_mtimespec.tv_sec)))
        }
        return out
    }
}
