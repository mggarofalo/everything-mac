import Foundation
import CoreServices

public final class LiveMonitor: @unchecked Sendable {
    public enum InspectionResult: Sendable, Equatable {
        case changed
        case noChange
        case retry
    }
    // One FSEvents delivery: the directory whose contents changed, plus whether the
    // kernel coalesced so much it could only flag "rescan everything under here"
    // (kFSEventStreamEventFlagMustScanSubDirs) instead of naming the exact level.
    public struct FSChange: Sendable {
        public let path: String
        public let eventID: UInt64
        public let mustScanSubtree: Bool
        public let structural: Bool
        public let metadataChanged: Bool
        public let mountChanged: Bool

        public init(path: String, eventID: UInt64, mustScanSubtree: Bool,
                    structural: Bool = false, metadataChanged: Bool = false,
                    mountChanged: Bool = false) {
            self.path = path
            self.eventID = eventID
            self.mustScanSubtree = mustScanSubtree
            self.structural = structural
            self.metadataChanged = metadataChanged
            self.mountChanged = mountChanged
        }
    }

    private var stream: FSEventStreamRef?
    private let onChanged: ([FSChange]) -> Void

    public init(onChanged: @escaping ([FSChange]) -> Void) {
        self.onChanged = onChanged
    }

    // Re-scan one directory level and apply create/delete diffs against the store.
    // Returns whether anything was actually added or removed: the live path uses this
    // to avoid re-searching the whole index on the constant stream of FSEvents that
    // change nothing structural (file content modifications) — the difference between
    // a flat idle cost and CPU that climbs the longer the app is open.
    //
    // `newlyIndexedDirs` collects the paths of brand-new directory subtrees indexed in
    // this pass (via indexContents). The batch driver uses it to skip re-listing a
    // subtree a sibling event in the same batch already built.
    @discardableResult
    public static func reconcileStatus(directory: String, in store: inout FileStore,
                                       rules: ExcludeRules, volID: UInt32,
                                       newlyIndexedDirs: inout Set<String>) -> InspectionResult {
        guard let dirID = store.idForDirPath(directory) else { return .noChange }
        let diskMtime = directoryMtimeNanoseconds(directory)
        if let diskMtime, diskMtime == store.reconcileMtime(of: dirID) { return .noChange }
        let existing = store.childIDs(of: dirID)
        guard let dir = opendir(directory) else {
            return reconcileMissingDirectory(existing, in: &store)
        }
        defer { closedir(dir) }
        let snapshot = readDirectorySnapshot(dir)
        let existingByName = childIDsByName(existing, in: store)
        var onDisk = Set<String>()
        var changed = false
        var incompleteSnapshot = snapshot.incomplete
        for name in snapshot.names {
            switch reconcileEntry(name, directory: directory, parentID: dirID,
                                  existingID: existingByName[name],
                                  inProjectDir: snapshot.inProjectDir, rules: rules,
                                  volID: volID, store: &store,
                                  newlyIndexedDirs: &newlyIndexedDirs) {
            case .excluded, .vanished: break
            case .failed: incompleteSnapshot = true
            case .present(let entryChanged):
                onDisk.insert(name)
                changed = changed || entryChanged
            }
        }
        if incompleteSnapshot { return .retry }
        changed = removeMissing(existing, onDisk: onDisk, from: &store) || changed
        if let diskMtime { store.setReconcileMtime(dirID, diskMtime) }
        return changed ? .changed : .noChange
    }

    private struct DirectorySnapshot {
        let names: [String]
        let inProjectDir: Bool
        let incomplete: Bool
    }

    private enum EntryInspection {
        case excluded
        case vanished
        case failed
        case present(changed: Bool)
    }

    // A directory's mtime changes when entries are added, removed, or renamed.
    // Nanosecond precision lets repeated content-only events avoid readdir entirely.
    private static func directoryMtimeNanoseconds(_ path: String) -> Int64? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return Int64(status.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(status.st_mtimespec.tv_nsec)
    }

    private static func reconcileMissingDirectory(_ existing: [UInt32],
                                                  in store: inout FileStore) -> InspectionResult {
        // Only absence proves that indexed children disappeared. Permission and other
        // transient failures must not turn a partial snapshot into durable deletions.
        guard errno == ENOENT || errno == ENOTDIR else { return .retry }
        guard !existing.isEmpty else { return .noChange }
        for id in existing { markSubtreeDeleted(id, in: &store) }
        return .changed
    }

    private static func readDirectorySnapshot(
        _ directory: UnsafeMutablePointer<DIR>
    ) -> DirectorySnapshot {
        var names: [String] = []
        var inProjectDir = false
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            names.append(name)
            if ExcludeRules.projectMarkers.contains(name) { inProjectDir = true }
        }
        return DirectorySnapshot(names: names, inProjectDir: inProjectDir,
                                 incomplete: errno != 0)
    }

    private static func childIDsByName(_ ids: [UInt32],
                                       in store: FileStore) -> [String: UInt32] {
        Dictionary(uniqueKeysWithValues: ids.map { (store.name(of: $0), $0) })
    }

    private static func reconcileEntry(
        _ name: String, directory: String, parentID: UInt32, existingID: UInt32?,
        inProjectDir: Bool, rules: ExcludeRules, volID: UInt32,
        store: inout FileStore, newlyIndexedDirs: inout Set<String>
    ) -> EntryInspection {
        let fullPath = (directory as NSString).appendingPathComponent(name)
        if rules.shouldExclude(name: name, path: fullPath, isHidden: name.hasPrefix("."),
                               inProjectDir: inProjectDir) { return .excluded }
        var status = stat()
        guard lstat(fullPath, &status) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .vanished : .failed
        }
        let isDirectory = (status.st_mode & S_IFMT) == S_IFDIR
        if !isDirectory, rules.shouldExcludeFile(name: name) { return .excluded }
        let metadata = (size: UInt64(status.st_size), mtime: Int64(status.st_mtimespec.tv_sec))
        guard let existingID else {
            appendEntry(name, at: fullPath, parentID: parentID, metadata: metadata,
                        isDirectory: isDirectory, rules: rules, volID: volID,
                        store: &store, newlyIndexedDirs: &newlyIndexedDirs)
            return .present(changed: true)
        }
        return updateEntry(existingID, name: name, path: fullPath, parentID: parentID,
                           metadata: metadata, isDirectory: isDirectory, rules: rules,
                           volID: volID, store: &store,
                           newlyIndexedDirs: &newlyIndexedDirs)
    }

    private static func updateEntry(
        _ id: UInt32, name: String, path: String, parentID: UInt32,
        metadata: (size: UInt64, mtime: Int64), isDirectory: Bool,
        rules: ExcludeRules, volID: UInt32, store: inout FileStore,
        newlyIndexedDirs: inout Set<String>
    ) -> EntryInspection {
        if store.isDir(of: id) != isDirectory {
            markSubtreeDeleted(id, in: &store)
            appendEntry(name, at: path, parentID: parentID, metadata: metadata,
                        isDirectory: isDirectory, rules: rules, volID: volID,
                        store: &store, newlyIndexedDirs: &newlyIndexedDirs)
            return .present(changed: true)
        }
        guard store.size(of: id) != metadata.size || store.mtime(of: id) != metadata.mtime else {
            return .present(changed: false)
        }
        store.updateMetadata(of: id, size: metadata.size, mtime: metadata.mtime)
        return .present(changed: true)
    }

    private static func appendEntry(
        _ name: String, at path: String, parentID: UInt32,
        metadata: (size: UInt64, mtime: Int64), isDirectory: Bool,
        rules: ExcludeRules, volID: UInt32, store: inout FileStore,
        newlyIndexedDirs: inout Set<String>
    ) {
        let id = store.append(name: name, parent: parentID, size: metadata.size,
                              mtime: metadata.mtime, isDir: isDirectory, volID: volID)
        guard isDirectory else { return }
        Scanner(rules: rules).indexContents(of: path, under: id, into: &store, volID: volID)
        newlyIndexedDirs.insert(path)
    }

    private static func removeMissing(_ existing: [UInt32], onDisk: Set<String>,
                                      from store: inout FileStore) -> Bool {
        let missing = existing.filter { !onDisk.contains(store.name(of: $0)) }
        for id in missing { markSubtreeDeleted(id, in: &store) }
        return !missing.isEmpty
    }

    /// Refresh metadata for one item reported by a file-level FSEvents stream.
    /// Structural changes are handled by reconciling the containing directory.
    @discardableResult
    public static func refreshMetadata(path: String, in store: inout FileStore) -> Bool {
        refreshMetadataStatus(path: path, in: &store) == .changed
    }

    public static func refreshMetadataStatus(path: String, in store: inout FileStore) -> InspectionResult {
        guard let id = store.idForDirPath(path), store.isLive(id) else { return .noChange }
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .noChange : .retry
        }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        guard isDir == store.isDir(of: id) else { return .noChange }
        let size = UInt64(st.st_size)
        let mtime = Int64(st.st_mtimespec.tv_sec)
        guard store.size(of: id) != size || store.mtime(of: id) != mtime else { return .noChange }
        store.updateMetadata(of: id, size: size, mtime: mtime)
        return .changed
    }

    // Convenience for callers that don't track cross-call subtree dedup (tests, one-off
    // reconciles): reconcile a single directory level.
    @discardableResult
    public static func reconcile(directory: String, in store: inout FileStore,
                                 rules: ExcludeRules, volID: UInt32) -> Bool {
        var ignored = Set<String>()
        return reconcileStatus(directory: directory, in: &store, rules: rules, volID: volID,
                               newlyIndexedDirs: &ignored) == .changed
    }

    // Reconcile a single directory level. When the caller is descending a subtree — the
    // FSEvents MustScanSubDirs overflow flag, where the kernel only says "something under
    // here changed" without naming the leaf — append the live child directories to `stack`
    // so the caller visits them next. The caller (IndexActor) drives the descent with an
    // explicit stack and an `await` between levels, so a deep resync NEVER holds the actor
    // in one uninterruptible call the way a recursive walk did: a queued search interleaves
    // throughout. `newlyIndexedDirs` carries across the whole descent so a subtree just
    // fully built (a new dir → indexContents) isn't re-listed.
    @discardableResult
    public static func reconcileLevel(directory: String, in store: inout FileStore,
                                      rules: ExcludeRules, volID: UInt32, descend: Bool,
                                      newlyIndexedDirs: inout Set<String>,
                                      pushChildDirsTo stack: inout [String]) -> Bool {
        reconcileLevelStatus(directory: directory, in: &store, rules: rules, volID: volID,
                             descend: descend, newlyIndexedDirs: &newlyIndexedDirs,
                             pushChildDirsTo: &stack) == .changed
    }

    public static func reconcileLevelStatus(directory: String, in store: inout FileStore,
                                            rules: ExcludeRules, volID: UInt32, descend: Bool,
                                            newlyIndexedDirs: inout Set<String>,
                                            pushChildDirsTo stack: inout [String]) -> InspectionResult {
        let result = reconcileStatus(directory: directory, in: &store, rules: rules, volID: volID,
                                     newlyIndexedDirs: &newlyIndexedDirs)
        guard result != .retry, descend,
              let dirID = store.idForDirPath(directory) else { return result }
        // Snapshot of live child dirs after reconcile (includes any just appended).
        for childID in store.childIDs(of: dirID) where store.isDir(of: childID) {
            let childPath = store.path(of: childID)
            // A subtree just fully indexed (new dir → indexContents) is already current.
            if newlyIndexedDirs.contains(where: { childPath == $0 || childPath.hasPrefix($0 + "/") }) { continue }
            stack.append(childPath)
        }
        return result
    }

    // FSEvents reports changes on the Data volume under its firmlink mount point
    // "/System/Volumes/Data", but the whole-disk index is rooted at the canonical
    // "/" (the Data volume's content appears directly under / via firmlinks, and the
    // scan deliberately skips the /System/Volumes/Data back-door to avoid double
    // indexing). Map a delivered Data-volume path back to its canonical form so
    // reconcile can resolve it against the store. Non-Data paths pass through.
    public static func canonicalEventPath(_ path: String) -> String {
        let alias = "/System/Volumes/Data"
        if path == alias { return "/" }
        if path.hasPrefix(alias + "/") { return String(path.dropFirst(alias.count)) }
        return path
    }

    private static func markSubtreeDeleted(_ id: UInt32, in store: inout FileStore) {
        store.markDeleted(id)
        for child in store.childIDs(of: id) {
            markSubtreeDeleted(child, in: &store)
        }
    }

    @discardableResult
    public func start(paths: [String],
                      sinceWhen: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)) -> Bool {
        let info = Unmanaged.passUnretained(self).toOpaque()
        var ctx = FSEventStreamContext(version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, flags, eventIDs in
            let mon = Unmanaged<LiveMonitor>.fromOpaque(info!).takeUnretainedValue()
            // Valid only because kFSEventStreamCreateFlagUseCFTypes is set below:
            // with that flag eventPaths is a CFArray<CFString>. Without it, paths
            // is a raw char** and this cast reads string bytes as a pointer →
            // SIGSEGV on the first delivered event.
            let cfArray = unsafeBitCast(paths, to: NSArray.self)
            let mustScan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            let structuralMask = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemRenamed)
            let metadataMask = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod |
                kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemXattrMod |
                kFSEventStreamEventFlagItemChangeOwner)
            let mountMask = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount |
                kFSEventStreamEventFlagRootChanged)
            var changes: [FSChange] = []
            changes.reserveCapacity(count)
            for i in 0..<count {
                guard let p = cfArray[i] as? String else { continue }
                let f = flags[i]
                changes.append(FSChange(path: p, eventID: UInt64(eventIDs[i]),
                                        mustScanSubtree: (f & mustScan) != 0,
                                        structural: (f & structuralMask) != 0,
                                        metadataChanged: (f & metadataMask) != 0,
                                        mountChanged: (f & mountMask) != 0))
            }
            mon.onChanged(changes)
        }
        // File-level events let the index refresh size and modification time without
        // re-reading a whole directory for every content write. The actor coalesces the
        // callback firehose before doing any work.
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray, sinceWhen, 0.3, flags)
        if let s = stream {
            FSEventStreamSetDispatchQueue(s, DispatchQueue(label: "fsevents"))
            if FSEventStreamStart(s) { return true }
            // Stop is valid only after a successful Start. Clean up a failed stream
            // directly so the actor can safely retry from the same checkpoint.
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        return false
    }

    public func stop() {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
    }

    public func flush() {
        if let stream { FSEventStreamFlushSync(stream) }
    }

    deinit { stop() }
}
