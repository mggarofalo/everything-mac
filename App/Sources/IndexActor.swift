import Foundation
import CoreServices
import IndexCore

typealias IndexScanOperation = @Sendable ([String], ExcludeRules, [String: DirectoryIdentity],
                                         (@Sendable (Int) -> Void)?) async -> ScanResult
typealias IndexSaveOperation = @Sendable (FileStore, URL, UInt64, UInt64, [ScanIssue]) async -> Bool

// Owns publication and mutable state. Filesystem scans and cache serialization
// run through off-actor operations; completed snapshots publish atomically.
actor IndexActor {
    private var store = FileStore()
    private let engine = QueryEngine()
    private var componentIndex = ComponentSearchIndex()
    private var componentIndexBuild: Task<(UInt64, ComponentSearchIndex), Never>?
    private var componentIndexGeneration: UInt64 = 0
    private var rules = ExcludeRules.defaults
    private var scope = IndexScope.localVolumes
    private var scanIssues: [ScanIssue] = []
    private var scopeSettings = IndexScopeSettings(mode: .localVolumes, folders: [])
    private var accessIssues: [ScanIssue] = []
    private var monitoringState = IndexMonitoringState.inactive
    private var accessResolutionRevision: UInt64 = 0
    private let cacheOverride: URL?
    private let scanFiles: IndexScanOperation
    private let saveCache: IndexSaveOperation
    private var publicationEpoch: UInt64 = 0
    // Rules the LIVE path reconciles with — the user rules plus the firmlink back-door /
    // network-mount exclusions the scan applies via effectiveRules(). Without these, a
    // live reconcile that ever sees a "/System/Volumes/Data/…" path (the Data volume's
    // firmlink alias) would index it as a SECOND copy of a file already held at its
    // canonical "/…" path — the duplicate-folder bug. Refreshed whenever rules change.
    private var liveRules = ExcludeRules.defaults

    // Matched ids for the last query (text + matchPath), so a sort-only change
    // re-sorts these instead of re-scanning millions of records. Invalidated
    // whenever the store mutates (rescan / live reconcile).
    private var cachedQueryKey: String?
    private var cachedIDs: [UInt32] = []
    private var visibleResultPaths: Set<String> = []
    private var lastSort: QueryEngine.SortKey = .name

    private var monitor: LiveMonitor?
    private var eventContinuation: AsyncStream<[LiveMonitor.FSChange]>.Continuation?
    private var eventConsumer: Task<Void, Never>?
    private var monitorRetry: Task<Void, Never>?
    private var lastEventID: UInt64 = UInt64(kFSEventStreamEventIdSinceNow)
    private var onLiveChange: (@Sendable () -> Void)?
    private var onProgress: (@Sendable (Int) -> Void)?
    private var isRescanning = false
    private var rescanRequested = false
    private var rescanWaiters: [CheckedContinuation<Void, Never>] = []
    private var accessEnabled = false
    private var hasPublishedSnapshot = false
    private var accessGeneration: UInt64 = 0
    private var saveInProgress = false
    private var revision: UInt64 = 0

    init() {
        cacheOverride = nil
        scanFiles = Self.scanFiles
        saveCache = Self.saveCache
        if let data = UserDefaults.standard.data(forKey: "excludeRules"),
           let r = try? JSONDecoder().decode(ExcludeRules.self, from: data) {
            rules = r
        }
    }

    /// Deterministic construction for service tests and scoped embedding. It avoids
    /// reading preferences or starting system services; callers explicitly supply the
    /// index snapshot and whether live reconciliation is allowed.
    init(store: FileStore, rules: ExcludeRules, accessEnabled: Bool, cacheURL: URL? = nil,
         scan: @escaping IndexScanOperation = IndexActor.scanFiles,
         save: @escaping IndexSaveOperation = IndexActor.saveCache) {
        scanFiles = scan
        saveCache = save
        self.store = store
        self.rules = rules
        self.liveRules = rules
        self.accessEnabled = accessEnabled
        self.hasPublishedSnapshot = true
        let roots = (0..<store.count).map(UInt32.init).filter {
            store.parent(of: $0) == FileStore.noParent
        }.map { store.path(of: $0) }
        self.scope = IndexScope(mode: .selectedFolders, roots: roots)
        self.scopeSettings = IndexScopeSettings(mode: .selectedFolders, folders: roots)
        self.cacheOverride = cacheURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("EverythingMacActorTests-\(UUID().uuidString)/index.idx")
    }

    nonisolated static func scanFiles(_ roots: [String], _ rules: ExcludeRules,
                                      _ identities: [String: DirectoryIdentity],
                                      _ progress: (@Sendable (Int) -> Void)?) async -> ScanResult {
        await Task.detached(priority: .userInitiated) {
            ParallelScanner.scan(roots: roots, rules: rules, identities: identities, progress: progress)
        }.value
    }

    nonisolated static func saveCache(_ store: FileStore, _ url: URL, _ eventID: UInt64,
                                      _ fingerprint: UInt64, _ issues: [ScanIssue]) async -> Bool {
        await Task.detached(priority: .utility) {
            do {
                try IndexCache.save(store, to: url, lastEventID: eventID,
                                    rulesFingerprint: fingerprint, issues: issues)
                return true
            } catch { return false }
        }.value
    }

    var totalCount: Int { store.liveCount }

    func serviceStatus(accessAvailable: Bool = true) -> ServiceStatus {
        ServiceStatus(totalCount: store.liveCount, revision: revision,
                      scanning: isRescanning, accessAvailable: accessAvailable,
                      ready: hasPublishedSnapshot,
                      coverage: IndexCoverage(scope: scopeSettings, issues: accessIssues + scanIssues,
                                              monitoring: monitoringState))
    }

    func configureAccess(_ resolved: ResolvedIndexAccess) async {
        guard resolved.revision >= accessResolutionRevision else { return }
        accessResolutionRevision = resolved.revision
        let changed = scope != resolved.scope || scopeSettings != resolved.settings
        accessIssues = resolved.issues
        scopeSettings = resolved.settings
        guard accessEnabled else { scope = resolved.scope; return }
        guard changed else { return }
        accessGeneration &+= 1
        publicationEpoch &+= 1
        scope = resolved.scope
        // Fence scans, detached searches, and staged writes before removing old coverage.
        stopMonitor()
        store = FileStore()
        hasPublishedSnapshot = false
        discardComponentIndex()
        cachedQueryKey = nil
        cachedIDs.removeAll()
        visibleResultPaths.removeAll()
        scanIssues.removeAll()
        clearDeferredChanges()
        try? FileManager.default.removeItem(at: cacheLocation())
        revision &+= 1
        onLiveChange?()
        if accessEnabled {
            await rescanAll()
            await flush()
        }
    }

    // ~/Library/Application Support/EverythingMac/index.idx
    static func cacheURL() -> URL {
        prepareApplicationSupportDirectory()
            .appendingPathComponent("index.idx")
    }

    private func cacheLocation() -> URL {
        guard let cacheOverride else { return Self.cacheURL() }
        try? FileManager.default.createDirectory(at: cacheOverride.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return cacheOverride
    }

    @discardableResult
    static func prepareApplicationSupportDirectory(
        fileManager: FileManager = .default,
        currentURL: URL = ServicePaths.applicationSupportURL,
        legacyURL: URL = ServicePaths.legacyApplicationSupportURL
    ) -> URL {
        ServicePaths.prepareApplicationSupportDirectory(fileManager: fileManager,
                                                         currentURL: currentURL, legacyURL: legacyURL)
    }

    func search(_ text: String, matchPath: Bool, caseInsensitive: Bool = true, wholeWord: Bool = false,
                usesRegularExpression: Bool = false,
                sort: QueryEngine.SortKey, ascending: Bool, limit: Int = 5000,
                isCancelled: @escaping @Sendable () -> Bool = { false }) async -> [FileRecord] {
        (try? await searchResponse(text, matchPath: matchPath, caseInsensitive: caseInsensitive,
                                   wholeWord: wholeWord, usesRegularExpression: usesRegularExpression,
                                   sort: sort, ascending: ascending, limit: limit,
                                   isCancelled: isCancelled).records) ?? []
    }

    func searchResponse(_ text: String, matchPath: Bool, caseInsensitive: Bool = true,
                        wholeWord: Bool = false, usesRegularExpression: Bool = false,
                        sort: QueryEngine.SortKey, ascending: Bool, limit: Int = 5000,
                        interactive: Bool = true,
                        isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> SearchResponse {
        guard hasPublishedSnapshot else { throw ServiceErrorCode.indexNotReady }
        guard accessEnabled else { throw ServiceErrorCode.permissionDenied }
        let generation = publicationEpoch
        let query = Query(text: text, matchPath: matchPath, caseInsensitive: caseInsensitive,
                          wholeWord: wholeWord, usesRegularExpression: usesRegularExpression)
        try validate(query, caseInsensitive: caseInsensitive)
        if !interactive {
            let response = try await searchSnapshot(query, sort: sort, ascending: ascending,
                                                    limit: limit, isCancelled: isCancelled)
            guard generation == publicationEpoch else { throw ServiceErrorCode.cancelled }
            return response
        }
        // Re-scan only when the query (not the sort) changed. The key folds in every
        // flag that changes which ids match — matchPath, case sensitivity, whole-word,
        // and regular-expression mode —
        // so flipping any of them invalidates the cache. engine.search already excludes
        // tombstoned ids, so no separate isLive filter pass is needed.
        let key = (matchPath ? "P" : "N") + (caseInsensitive ? "i" : "s")
            + (wholeWord ? "w" : "x") + (usesRegularExpression ? "r" : "t") + "\u{1}" + text
        if key != cachedQueryKey {
            let matches: [UInt32]
            if query.isUnconstrained {
                matches = engine.search(query, in: store, isCancelled: isCancelled)
            } else {
                guard await prepareComponentIndex(isCancelled: isCancelled),
                      generation == publicationEpoch else {
                    throw ServiceErrorCode.cancelled
                }
                matches = engine.search(query, in: store, componentIndex: componentIndex,
                                        isCancelled: isCancelled)
            }
            guard !isCancelled() else { throw ServiceErrorCode.cancelled }
            cachedIDs = matches
            cachedQueryKey = key
        }
        let effectiveLimit = min(max(1, limit), query.requestedLimit ?? Int.max)
        let sorted = engine.sortedPrefix(cachedIDs, by: sort, ascending: ascending,
                                         limit: effectiveLimit, in: store,
                                         isCancelled: isCancelled)
        guard !isCancelled() else { throw ServiceErrorCode.cancelled }
        let records = sorted.map { id in
            FileRecord(id: id, name: store.name(of: id), path: store.path(of: id),
                       parent: store.parent(of: id),
                       size: store.size(of: id), mtime: store.mtime(of: id),
                       isDir: store.isDir(of: id), volID: store.volID(of: id))
        }
        lastSort = sort
        visibleResultPaths = Set(records.map(\.path))
        return SearchResponse(records: records, limit: effectiveLimit,
                              truncated: cachedIDs.count > effectiveLimit,
                              scanning: isRescanning)
    }

    private func validate(_ query: Query, caseInsensitive: Bool) throws {
        let plan = query.plan
        guard plan.isValid else { throw ServiceErrorCode.invalidQuery }
        if let pattern = plan.regularExpression {
            let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
            guard (try? NSRegularExpression(pattern: pattern, options: options)) != nil else {
                throw ServiceErrorCode.invalidQuery
            }
        }
    }

    private func searchSnapshot(_ query: Query, sort: QueryEngine.SortKey,
                                ascending: Bool, limit: Int,
                                isCancelled: @escaping @Sendable () -> Bool) async throws -> SearchResponse {
        if !query.isUnconstrained {
            guard await prepareComponentIndex(isCancelled: isCancelled) else {
                throw ServiceErrorCode.cancelled
            }
        }
        guard !isCancelled() else { throw ServiceErrorCode.cancelled }
        let snapshot = store
        let index = componentIndex
        let scanning = isRescanning
        let effectiveLimit = min(max(1, limit), query.requestedLimit ?? Int.max)
        return try await Task.detached(priority: .utility) {
            let engine = QueryEngine()
            let ids = engine.search(query, in: snapshot,
                                    componentIndex: query.isUnconstrained ? nil : index,
                                    isCancelled: isCancelled)
            guard !isCancelled() else { throw ServiceErrorCode.cancelled }
            let sorted = engine.sortedPrefix(ids, by: sort, ascending: ascending,
                                             limit: effectiveLimit, in: snapshot,
                                             isCancelled: isCancelled)
            guard !isCancelled() else { throw ServiceErrorCode.cancelled }
            let records = sorted.map { id in
                FileRecord(id: id, name: snapshot.name(of: id), path: snapshot.path(of: id),
                           parent: snapshot.parent(of: id), size: snapshot.size(of: id),
                           mtime: snapshot.mtime(of: id), isDir: snapshot.isDir(of: id),
                           volID: snapshot.volID(of: id))
            }
            guard !isCancelled() else { throw ServiceErrorCode.cancelled }
            return SearchResponse(records: records, limit: effectiveLimit,
                                  truncated: ids.count > effectiveLimit, scanning: scanning)
        }.value
    }

    func path(of id: UInt32) -> String { store.path(of: id) }

    func currentRules() -> ExcludeRules { rules }

    func setRules(_ r: ExcludeRules, accessGeneration expectedGeneration: UInt64? = nil) {
        guard expectedGeneration == nil || expectedGeneration == accessGeneration else { return }
        rules = r
        liveRules = effectiveRules()
        if let data = try? JSONEncoder().encode(r) {
            UserDefaults.standard.set(data, forKey: "excludeRules")
        }
    }

    // macOS presents one unified filesystem at "/": the read-only System volume
    // and the Data volume are joined via firmlinks, and external volumes mount
    // under /Volumes. A single recursive scan of "/" covers the entire disk and
    // every mounted volume exactly once — EXCEPT the Data volume is also visible
    // at /System/Volumes/Data (and siblings), which would duplicate every user
    // file. Exclude those firmlink back-doors. User rules are merged in.
    private func effectiveRules() -> ExcludeRules {
        let firmlinkBackDoors = [
            "/System/Volumes/Data",
            "/System/Volumes/Preboot",
            "/System/Volumes/VM",
            "/System/Volumes/Update",
            "/System/Volumes/xarts",
            "/System/Volumes/iSCPreboot",
            "/System/Volumes/Hardware",
        ]
        // Copy + mutate one field rather than re-listing every field by hand, so a
        // future ExcludeRules property is carried through automatically instead of
        // being silently dropped back to its default on the scan path.
        var effective = rules
        // Also skip network (non-local) mounts. Crawling an SMB/NFS share does one
        // network round-trip per lstat and an smbfs readdir blocks in uninterruptible
        // I/O — a single mounted share with millions of files hangs the whole scan.
        effective.pathPrefixes += firmlinkBackDoors + Self.nonLocalMountPaths()
        return effective
    }

    // Mount points of non-local (network) filesystems — SMB/NFS/AFP/WebDAV shares.
    // getmntinfo with MNT_NOWAIT reads the kernel's cached mount table and never
    // itself touches the network (MNT_WAIT would refresh stats and could block on a
    // stalled mount). MNT_LOCAL is set only for filesystems stored on local media.
    static func nonLocalMountPaths() -> [String] {
        MountedVolumes.snapshot().filter { !$0.isLocal }.map(\.path)
    }

    // Rebuild the whole index from "/". The walk runs OFF the actor on a pool of
    // worker threads (ParallelScanner), so the actor stays free to serve searches
    // against the existing index while the new one builds — no scan↔search
    // contention, all cores busy. The finished store is swapped in atomically.
    func rescanAll(accessGeneration expectedGeneration: UInt64? = nil) async {
        guard accessEnabled,
              expectedGeneration == nil || expectedGeneration == accessGeneration else { return }
        if isRescanning {
            // Coalesce concurrent requests into one follow-up scan. Suspend callers
            // on continuations instead of polling the actor with Task.sleep.
            rescanRequested = true
            await withCheckedContinuation { rescanWaiters.append($0) }
            return
        }
        guard !Task.isCancelled else { return }
        isRescanning = true
        var scanGeneration = accessGeneration
        defer {
            isRescanning = false
            let waiters = rescanWaiters
            rescanWaiters.removeAll(keepingCapacity: true)
            waiters.forEach { $0.resume() }
        }
        repeat {
            rescanRequested = false
            scanGeneration = accessGeneration
            // Take the checkpoint before stopping the stream. Events generated while the
            // scanner runs are replayed into the finished snapshot from this point.
            let checkpoint = UInt64(FSEventsGetCurrentEventId())
            stopMonitor()
            pendingDirs.removeAll(keepingCapacity: true)
            pendingDeep.removeAll(keepingCapacity: true)
            pendingMetadata.removeAll(keepingCapacity: true)
            clearDeferredChanges()
            retryCounts.removeAll(keepingCapacity: true)
            pendingMaxEventID = 0
            pendingFullRescan = false
            drainScheduled = false

            let effective = effectiveRules()
            liveRules = effective
            let prog = onProgress
            let roots = scope.roots
            let identities = scope.identities
            let epoch = publicationEpoch
            let scanned = await scanFiles(roots, effective, identities, prog)
            guard accessEnabled, !Task.isCancelled else { return }
            if accessGeneration != scanGeneration || publicationEpoch != epoch {
                rescanRequested = true
                continue
            }
            store = scanned.store
            scanIssues = scanned.issues
            for issue in scanned.issues where issue.accessDenied { suppressPath(issue.path) }
            for (path, identity) in identities where !ParallelScanner.rootMatches(path, identity: identity) {
                suppressPath(path)
                scanIssues.append(ScanIssue(path: path, errorCode: ENOENT))
            }
            hasPublishedSnapshot = true
            beginComponentIndexBuild()
            revision &+= 1
            cachedQueryKey = nil
            lastEventID = checkpoint
            onProgress?(store.liveCount)
            startMonitor()
        } while rescanRequested
    }

    // Launch path: load the cache if present (FSEvents replays any changes made
    // while we were closed), otherwise do a full scan and save a fresh cache.
    // Then start the live monitor from the saved event id.
    func startUp(onLiveChange: @escaping @Sendable () -> Void,
                 onProgress: @escaping @Sendable (Int) -> Void,
                 accessGeneration requestedGeneration: UInt64) async {
        guard requestedGeneration >= accessGeneration else { return }
        accessGeneration = requestedGeneration
        publicationEpoch &+= 1
        accessEnabled = true
        self.onLiveChange = onLiveChange
        self.onProgress = onProgress
        liveRules = effectiveRules()   // before the monitor starts firing live reconciles
        let url = cacheLocation()
        let fingerprint = scope.fingerprint(rules: effectiveRules())
        // Use the cache only if it was built with the SAME exclusion rules now in
        // effect. Otherwise (e.g. an upgrade that turned dev-folder skipping on, or a
        // changed exclude list) the cached index disagrees with the active rules and
        // would keep serving folders that should now be hidden — rebuild instead.
        if let (loaded, evid, savedFingerprint, issues) = try? IndexCache.loadSnapshot(from: url),
           savedFingerprint == fingerprint,
           !Self.isContaminated(loaded) {
            store = loaded
            scanIssues = issues
            hasPublishedSnapshot = true
            beginComponentIndexBuild()
            revision &+= 1
            lastEventID = evid
            startMonitor()
        } else {
            await rescanAll()
            guard accessEnabled, requestedGeneration == accessGeneration,
                  !Task.isCancelled else { return }
            await flush()
        }
    }

    // A clean scan excludes the Data volume's firmlink back-door, so a healthy index
    // never holds a "/System/Volumes/Data" entry. If a loaded cache does, it was written
    // by an older build whose live path indexed that alias as duplicate records (every
    // affected file appeared twice — once at its canonical "/…" path, once under
    // "/System/Volumes/Data/…"). Treat the cache as contaminated and rebuild once to
    // purge it; the hardened live path (see liveRules) won't let it come back.
    private static func isContaminated(_ store: FileStore) -> Bool {
        store.idForDirPath("/System/Volumes/Data") != nil
    }

    private func startMonitor() {
        stopMonitor()
        guard !scope.roots.isEmpty else { return }
        monitoringState = .starting
        let stream = AsyncStream<[LiveMonitor.FSChange]> { eventContinuation = $0 }
        eventConsumer = Task { [weak self] in
            for await changes in stream {
                guard !Task.isCancelled else { return }
                await self?.enqueueChanges(changes)
            }
        }
        let continuation = eventContinuation
        let m = LiveMonitor(onChanged: { changes in continuation?.yield(changes) })
        // WatchRoot opens ancestor directories outside a selected folder's grant.
        // Selected-root moves are instead detected by the access boundary's identity check.
        guard m.start(paths: watchPaths(), sinceWhen: FSEventStreamEventId(lastEventID),
                      watchRoot: scope.mode == .localVolumes) else {
            monitoringState = .retrying
            eventContinuation?.finish()
            eventContinuation = nil
            eventConsumer?.cancel()
            eventConsumer = nil
            // A transient stream-creation failure must not leave a permanently static
            // index. Retry from the last fully processed event checkpoint.
            monitorRetry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.startMonitor()
            }
            return
        }
        monitorRetry?.cancel()
        monitorRetry = nil
        monitor = m
        monitoringState = .live
        onLiveChange?()
    }

    private func stopMonitor() {
        monitoringState = .inactive
        monitor?.stop()
        monitor = nil
        eventContinuation?.finish()
        eventContinuation = nil
        eventConsumer?.cancel()
        eventConsumer = nil
        monitorRetry?.cancel()
        monitorRetry = nil
    }

    func invalidateForAccessRevocation(generation requestedGeneration: UInt64) {
        guard requestedGeneration >= accessGeneration else { return }
        accessGeneration = requestedGeneration
        accessEnabled = false
        publicationEpoch &+= 1
        stopMonitor()
        pendingDirs.removeAll()
        pendingDeep.removeAll()
        pendingMetadata.removeAll()
        clearDeferredChanges()
        retryCounts.removeAll()
        pendingMaxEventID = 0
        pendingFullRescan = false
        drainScheduled = false
        store = FileStore()
        hasPublishedSnapshot = false
        discardComponentIndex()
        cachedQueryKey = nil
        cachedIDs.removeAll()
        try? FileManager.default.removeItem(at: cacheLocation())
    }

    // An FSEvents stream rooted at "/" only covers the boot volume's hierarchy
    // (System + firmlinked Data). Other volumes mount under /Volumes on separate
    // devices and need their own watch roots, or live updates never fire for files
    // on them (e.g. an external/secondary disk). The boot volume's own entry in
    // /Volumes is a symlink — lstat skips it (S_IFLNK), so it isn't double-watched.
    private func watchPaths() -> [String] {
        guard scope.mode == .localVolumes else { return scope.roots }
        // "/" is the sealed, read-only System volume; the writable Data volume — home,
        // /Users, /private, /Applications — is mounted at /System/Volumes/Data, and its
        // live changes are NOT delivered through a "/" watch (only via slow coalesced
        // rescans every few minutes, which is why new files in the home folder took
        // minutes to appear). Watch the Data volume directly so home-folder changes are
        // instant; enqueueChanges maps the /System/Volumes/Data prefix back to canonical.
        var paths = ["/", "/System/Volumes/Data"]
        // Network shares are skipped (checked BEFORE lstat — stat'ing a network mount
        // point itself can block), matching the scan, which doesn't index them.
        let networkMounts = Set(Self.nonLocalMountPaths())
        if let vols = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for v in vols.sorted() {
                let p = "/Volumes/" + v
                if networkMounts.contains(p) { continue }
                var st = stat()
                if lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR { paths.append(p) }
            }
        }
        return paths
    }

    // FSEvents delivery → coalesced reconcile. Watching the whole Data volume delivers a
    // FIREHOSE of change notifications during normal use (browser caches, app state, logs
    // — hundreds per second under load). Reconciling once per delivery hammered this
    // actor so relentlessly that the UI's own search/sort calls (which share the actor)
    // never got a turn — the window looked frozen even though typing still worked. So
    // instead of reconciling inline, accumulate the changed directories and process them
    // in one deduped, throttled drain (≈twice a second), yielding mid-drain so a queued
    // search interleaves. Each reported path IS the directory that changed; firmlink
    // Data paths are mapped back to canonical so they resolve against the index.
    private var pendingDirs: Set<String> = []
    private var pendingDeep: Set<String> = []
    private var pendingMetadata: Set<String> = []
    private var pendingMaxEventID: UInt64 = 0
    private var pendingFullRescan = false
    // Failed paths have their own timer. Fresh events must not inherit their backoff.
    private struct DeferredChanges {
        var directories: [String: Bool] = [:]
        var metadata: Set<String> = []
        var eventID: UInt64 = 0
        var isEmpty: Bool { directories.isEmpty && metadata.isEmpty }
    }
    private var deferredChanges = DeferredChanges()
    private var retryTask: Task<Void, Never>?
    private var retryCounts: [String: Int] = [:]
    private var drainScheduled = false
    private var draining = false

    func enqueueChanges(_ changes: [LiveMonitor.FSChange]) {
        // The stopped stream's last callbacks can already be queued when a rebuild
        // starts. The new stream replays everything after the pre-scan checkpoint.
        guard accessEnabled, !isRescanning else { return }
        for c in changes {
            let p = LiveMonitor.canonicalEventPath(c.path)
            pendingMaxEventID = max(pendingMaxEventID, c.eventID)
            if c.historyDropped { pendingFullRescan = true; continue }
            guard validateRoot(containing: p) else { continue }
            if c.mountChanged || (c.structural && scope.roots.contains(p)) {
                pendingFullRescan = true
            } else if !scope.contains(p) {
                continue
            } else if c.mustScanSubtree {
                pendingDirs.insert(p)
                pendingDeep.insert(p)
            } else {
                if c.structural {
                    let parent = (p as NSString).deletingLastPathComponent
                    pendingDirs.insert(parent.isEmpty ? "/" : parent)
                }
                if c.metadataChanged { pendingMetadata.insert(p) }
                // A flagless event retains the directory-level API semantics.
                if !c.structural && !c.metadataChanged { pendingDirs.insert(p) }
            }
        }
        // A drain is already pending or running — it will sweep up what we just added.
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard !drainScheduled, !draining,
              !pendingDirs.isEmpty || !pendingMetadata.isEmpty || pendingFullRescan else { return }
        drainScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // coalesce a 0.5s burst
            await self?.drainChanges()
        }
    }

    private func drainChanges() async {
        drainScheduled = false
        guard !draining else { return }
        draining = true
        defer { draining = false; scheduleDrain() }
        let generation = accessGeneration
        var state = DrainState()
        // Loop until the backlog is empty so changes that arrive mid-drain aren't lost.
        while !pendingDirs.isEmpty || !pendingMetadata.isEmpty || pendingFullRescan {
            if await performPendingFullRescan() { return }
            let batch = takePendingBatch()
            processMetadata(batch.metadata, state: &state)
            if await processDirectories(batch.directories, deep: batch.deep,
                                        generation: generation, state: &state) { return }
            guard generation == accessGeneration else { return }
            publishChanges(from: state)
            finishBatch(eventID: batch.eventID, state: state)
            state.resetForNextBatch()
        }
    }

    private struct DrainBatch {
        let directories: [String]
        let deep: Set<String>
        let metadata: Set<String>
        let eventID: UInt64
    }

    private struct DrainState {
        var processed = 0
        var newlyIndexed = Set<String>()
        var structuralChanged = false
        var visibleMetadataChanged = false
        var retryDelay: UInt64 = 1_000_000_000

        mutating func resetForNextBatch() {
            structuralChanged = false
            visibleMetadataChanged = false
            retryDelay = 1_000_000_000
        }
    }

    private func performPendingFullRescan() async -> Bool {
        guard pendingFullRescan else { return false }
        pendingFullRescan = false
        await rescanAll()
        onLiveChange?()
        return true
    }

    private func takePendingBatch() -> DrainBatch {
        let batch = DrainBatch(directories: pendingDirs.sorted(), deep: pendingDeep,
                               metadata: pendingMetadata, eventID: pendingMaxEventID)
        pendingDirs.removeAll(keepingCapacity: true)
        pendingDeep.removeAll(keepingCapacity: true)
        pendingMetadata.removeAll(keepingCapacity: true)
        pendingMaxEventID = 0
        return batch
    }

    private func processMetadata(_ paths: Set<String>, state: inout DrainState) {
        for path in paths {
            guard scope.contains(path), validateRoot(containing: path) else { continue }
            var failures: [ScanIssue] = []
            let result = LiveMonitor.refreshMetadataStatus(path: path, in: &store,
                                                          onIssue: { failures.append($0) })
            if handleAccessFailures(failures) {
                state.structuralChanged = true
                deferredChanges.metadata.remove(path)
                retryCounts.removeValue(forKey: "m:" + path)
                continue
            }
            switch result {
            case .changed:
                deferredChanges.metadata.remove(path)
                retryCounts.removeValue(forKey: "m:" + path)
                if lastSort == .size || lastSort == .mtime || visibleResultPaths.contains(path) {
                    state.visibleMetadataChanged = true
                }
            case .retry:
                recordRetry(for: "m:" + path, state: &state)
                deferredChanges.metadata.insert(path)
            case .noChange:
                deferredChanges.metadata.remove(path)
                retryCounts.removeValue(forKey: "m:" + path)
            }
        }
    }

    private func processDirectories(_ directories: [String], deep: Set<String>,
                                    generation: UInt64,
                                    state: inout DrainState) async -> Bool {
        for directory in directories {
            guard scope.contains(directory), validateRoot(containing: directory) else { continue }
            let descend = deep.contains(directory) || deferredChanges.directories[directory] == true
            if descend, Self.isVolumeRoot(directory) {
                await rescanAll()
                onLiveChange?()
                return true
            }
            var stack = [directory]
            while let path = stack.popLast() {
                guard scope.contains(path), validateRoot(containing: path) else { continue }
                var failures: [ScanIssue] = []
                let result = LiveMonitor.reconcileLevelStatus(
                    directory: path, in: &store, rules: liveRules, volID: 1,
                    descend: descend, newlyIndexedDirs: &state.newlyIndexed,
                    pushChildDirsTo: &stack, onIssue: { failures.append($0) }
                )
                let denied = handleAccessFailures(failures)
                let unresolved = failures.contains { !$0.accessDenied && $0.errorCode != ENOENT && $0.errorCode != ENOTDIR }
                applyDirectoryResult(denied && !unresolved ? .changed : result,
                                     path: path, descend: descend, state: &state)
                state.processed += 1
                // Yield periodically so search and sort requests stay responsive.
                if state.processed % 64 == 0 {
                    await Task.yield()
                    guard generation == accessGeneration else { return true }
                }
            }
        }
        return false
    }

    @discardableResult
    private func handleAccessFailures(_ issues: [ScanIssue]) -> Bool {
        let denied = issues.filter(\.accessDenied)
        for issue in denied {
            suppressPath(issue.path)
            if !scanIssues.contains(issue), scanIssues.count < 100 { scanIssues.append(issue) }
        }
        return !denied.isEmpty
    }

    private func suppressPath(_ path: String) {
        guard let root = store.idForDirPath(path) else { return }
        publicationEpoch &+= 1
        try? FileManager.default.removeItem(at: cacheLocation())
        var pending = [root]
        while let id = pending.popLast() {
            pending += store.childIDs(of: id)
            store.markDeleted(id)
        }
        cachedQueryKey = nil
    }

    private func validateRoot(containing path: String) -> Bool {
        guard MountedVolumes.permitsInspection(path) else {
            suppressPath(path)
            let issue = ScanIssue(path: path, errorCode: ENOTSUP)
            if !scanIssues.contains(issue), scanIssues.count < 100 { scanIssues.append(issue) }
            revision &+= 1
            onLiveChange?()
            return false
        }
        for (root, identity) in scope.identities where IndexScope.contains(path, under: root) {
            guard ParallelScanner.rootMatches(root, identity: identity) else {
                suppressPath(root)
                let issue = ScanIssue(path: root, errorCode: ENOENT)
                if !scanIssues.contains(issue) { scanIssues.append(issue) }
                revision &+= 1
                onLiveChange?()
                return false
            }
        }
        return true
    }

    private func applyDirectoryResult(_ result: LiveMonitor.InspectionResult, path: String,
                                      descend: Bool, state: inout DrainState) {
        switch result {
        case .changed:
            deferredChanges.directories.removeValue(forKey: path)
            retryCounts.removeValue(forKey: "d:" + path)
            state.structuralChanged = true
        case .retry:
            // Safe additions may already have been applied before an incomplete
            // snapshot was detected, so invalidate results while scheduling a retry.
            state.structuralChanged = true
            recordRetry(for: "d:" + path, state: &state)
            deferredChanges.directories[path] = descend || deferredChanges.directories[path] == true
        case .noChange:
            deferredChanges.directories.removeValue(forKey: path)
            retryCounts.removeValue(forKey: "d:" + path)
        }
    }

    private func recordRetry(for key: String, state: inout DrainState) {
        let attempts = retryCounts[key, default: 0] + 1
        retryCounts[key] = attempts
        state.retryDelay = max(state.retryDelay, Self.retryDelay(for: attempts))
    }

    private func publishChanges(from state: DrainState) {
        guard state.structuralChanged || state.visibleMetadataChanged else { return }
        if state.structuralChanged { cachedQueryKey = nil }
        revision &+= 1
        onLiveChange?()
    }

    private func finishBatch(eventID: UInt64, state: DrainState) {
        deferredChanges.eventID = max(deferredChanges.eventID, eventID)
        if deferredChanges.isEmpty {
            // Later successful batches cannot advance the durable checkpoint past
            // an earlier failed inspection. Release that barrier only after recovery.
            lastEventID = max(lastEventID, deferredChanges.eventID)
            clearDeferredChanges()
            return
        }
        guard retryTask == nil else { return }
        retryTask = Task { [weak self, delay = state.retryDelay] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.retryDeferredChanges()
        }
    }

    private func retryDeferredChanges() {
        retryTask = nil
        pendingDirs.formUnion(deferredChanges.directories.keys)
        pendingDeep.formUnion(deferredChanges.directories.compactMap { $0.value ? $0.key : nil })
        pendingMetadata.formUnion(deferredChanges.metadata)
        pendingMaxEventID = max(pendingMaxEventID, deferredChanges.eventID)
        enqueueChanges([])
    }

    private func clearDeferredChanges() {
        retryTask?.cancel()
        retryTask = nil
        deferredChanges = DeferredChanges()
    }

    private static func retryDelay(for attempt: Int) -> UInt64 {
        let seconds = min(60, 1 << min(max(0, attempt - 1), 6))
        return UInt64(seconds) * 1_000_000_000
    }

    // "/" covers the boot + firmlinked Data volume; "/Volumes/<name>" is an
    // external mount root. Deep events at either root require a complete rebuild.
    private static func isVolumeRoot(_ path: String) -> Bool {
        if path == "/" || path == "/System/Volumes/Data" { return true }
        if path.hasPrefix("/Volumes/") { return !path.dropFirst("/Volumes/".count).contains("/") }
        return false
    }

    // Safety net for iCloud "Desktop & Documents" (FileProvider) folders: macOS does
    // NOT deliver FSEvents for these the way it does ordinary folders, so files
    // created/deleted on the Desktop or in Documents/Downloads can lag minutes behind
    // (only coarse coalesced rescans eventually catch them). Periodically re-read just
    // these few user-facing folders directly. Cost is trivial — each unchanged folder
    // is gated to a single lstat by reconcile's mtime check; a folder only gets a full
    // readdir when its contents actually changed. Shallow (one level) on purpose:
    // a deep subtree walk would lstat the entire subtree every tick, which is not free.
    func sweepUserFolders() {
        guard accessEnabled, !isRescanning else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let targets = ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
        var newlyIndexed = Set<String>()
        var changed = false
        for dir in targets {
            guard scope.contains(dir) else { continue }
            var failures: [ScanIssue] = []
            let result = LiveMonitor.reconcileStatus(directory: dir, in: &store, rules: liveRules, volID: 1,
                                                     newlyIndexedDirs: &newlyIndexed,
                                                     onIssue: { failures.append($0) })
            if handleAccessFailures(failures) || result == .changed { changed = true }
        }
        guard changed else { return }
        cachedQueryKey = nil
        revision &+= 1
        onLiveChange?()
    }

    func refreshUnavailablePaths() async {
        guard !isRescanning else { return }
        let denied = scanIssues.filter(\.accessDenied)
        for issue in denied {
            guard scope.contains(issue.path), validateRoot(containing: issue.path),
                  MountedVolumes.permitsInspection(issue.path),
                  Self.metadataAccessible(issue.path) else { continue }
            await rescanAll()
            await flush()
            onLiveChange?()
            return
        }
    }

    private static func metadataAccessible(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return true }
        guard let directory = opendir(path) else { return false }
        closedir(directory)
        return true
    }

    // Persist the current store and the highest event fully applied to it.
    func flush(accessGeneration expectedGeneration: UInt64? = nil) async {
        guard accessEnabled,
              hasPublishedSnapshot,
              !saveInProgress,
              expectedGeneration == nil || expectedGeneration == accessGeneration else { return }
        // Bound in-memory churn without paying for an O(n) rebuild on every deletion.
        // The serializer independently omits every tombstone from the durable cache.
        let compactThreshold = max(100_000, store.count / 10)
        if store.deletedCount >= compactThreshold {
            store = store.compacted()
            beginComponentIndexBuild()
            cachedQueryKey = nil
            cachedIDs.removeAll(keepingCapacity: false)
            visibleResultPaths.removeAll(keepingCapacity: false)
            onLiveChange?()
        }
        // Snapshotting FileStore is copy-on-write. Serialize that snapshot away from
        // this actor so searches and live updates continue while a multi-million-file
        // cache is written. Promote the staged file only if disk access is still valid.
        let snapshot = store
        let eventID = lastEventID
        let fingerprint = scope.fingerprint(rules: effectiveRules())
        let issues = scanIssues
        let generation = publicationEpoch
        let finalURL = cacheLocation()
        let stagingURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent("index.\(UUID().uuidString).staging")
        saveInProgress = true
        let saved = await saveCache(snapshot, stagingURL, eventID, fingerprint, issues)
        defer {
            saveInProgress = false
            try? FileManager.default.removeItem(at: stagingURL)
        }
        guard saved, accessEnabled, publicationEpoch == generation else { return }
        try? FileManager.default.removeItem(at: finalURL)
        try? FileManager.default.moveItem(at: stagingURL, to: finalURL)
    }

    /// Builds the large derived postings table once per store replacement. Search
    /// requests share this task: canceling a stale keystroke request must not throw
    /// away construction work needed by the request that superseded it.
    private func beginComponentIndexBuild() {
        componentIndexGeneration &+= 1
        let generation = componentIndexGeneration
        let snapshot = store
        componentIndex = ComponentSearchIndex()
        componentIndexBuild?.cancel()
        componentIndexBuild = Task.detached(priority: .utility) {
            var index = ComponentSearchIndex()
            _ = index.rebuild(with: snapshot, isCancelled: { Task.isCancelled })
            return (generation, index)
        }
    }

    private func discardComponentIndex() {
        componentIndexGeneration &+= 1
        componentIndexBuild?.cancel()
        componentIndexBuild = nil
        componentIndex = ComponentSearchIndex()
    }

    private func prepareComponentIndex(isCancelled: @Sendable () -> Bool) async -> Bool {
        while let build = componentIndexBuild {
            let (generation, built) = await build.value
            guard generation == componentIndexGeneration else { continue }
            componentIndex = built
            componentIndexBuild = nil
        }
        guard !isCancelled() else { return false }
        return componentIndex.synchronize(with: store, isCancelled: isCancelled)
    }
}
