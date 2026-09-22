import SwiftUI
import AppKit
import IndexCore
import Combine

enum ServiceAccessState {
    case granted
    case denied
    case backgroundApprovalRequired
    case serviceUnavailable
}

@MainActor
final class AppModel: ObservableObject {
    @Published var query = ""
    @Published var results: [FileRecord] = []
    @Published var total = 0
    @Published var sortKey: QueryEngine.SortKey = .name
    @Published var ascending = true
    @Published var matchPath = false
    // Live search modifiers (Everything's Match Case / Match Whole Word). Persisted
    // and threaded into every search; not part of ExcludeRules, so changing them
    // re-runs the query instantly without re-indexing.
    @Published var caseSensitive = false
    @Published var wholeWord = false
    @Published var usesRegularExpression = false
    // Max rows handed to the table — the old hardcoded 5000 cap, now user-tunable.
    @Published var resultLimit = 5000
    @Published var rules: ExcludeRules = .defaults
    @Published var scanning = false
    @Published private(set) var hasFullDiskAccess = false
    @Published var selectedPath: String?
    private(set) var selectedIdentity: ResultActions.ItemIdentity?
    // Bumped to ask the focused window to put the cursor in the search field (⌘F /
    // File ▸ Find). A counter, not a Bool, so repeated requests always fire onChange.
    @Published var focusSearchSignal = 0
    @Published private(set) var focusSearchWindowNumber: Int?

    // The currently-selected result, resolved by stable path against the live
    // result set. nil once the file drops out of results, which auto-disables the
    // selection-dependent menu items.
    var selected: FileRecord? { selectedPath.flatMap { path in results.first { $0.path == path } } }

    func select(_ record: FileRecord?) {
        selectedIdentity = record.flatMap { ResultActions.identity(for: $0) }
        selectedPath = record?.path
    }

    let index: SearchClient
    private let preferences: UserDefaults
    private var presentedDefaultsAreActive = false
    private var task: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var searchSeq = 0
    private var didBootstrap = false
    private var bootstrapTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var accessGeneration: UInt64 = 0
    private var accessRefreshTask: Task<ServiceAccessState, Never>?
    private var restartAfterRefresh = false

    init(defaults: UserDefaults = .standard, index: SearchClient = SearchClient()) {
        preferences = defaults
        self.index = index
    }
    func refreshFullDiskAccess(
        restartServicesIfDenied: Bool = false
    ) async -> ServiceAccessState {
        if restartServicesIfDenied { restartAfterRefresh = true }
        if let accessRefreshTask { return await accessRefreshTask.value }

        let task = Task {
            let restartNow = restartAfterRefresh
            restartAfterRefresh = false
            var result = await performAccessRefresh(restartServicesIfDenied: restartNow)
            if restartAfterRefresh && result == .denied && !restartNow {
                restartAfterRefresh = false
                result = await performAccessRefresh(restartServicesIfDenied: true)
            }
            restartAfterRefresh = false
            accessRefreshTask = nil
            return result
        }
        accessRefreshTask = task
        return await task.value
    }

    private func performAccessRefresh(
        restartServicesIfDenied: Bool
    ) async -> ServiceAccessState {
        guard let status = await waitForServiceStatus() else {
            return await recoverBackgroundServices()
        }
        if status.hasFullDiskAccess {
            publish(status)
            return .granted
        }

        guard restartServicesIfDenied else {
            publish(status)
            return .denied
        }

        await index.resetConnection()
        guard BackgroundServices.restartAfterFullDiskAccessChange() else {
            return serviceFailureState
        }

        return await waitForRestartedServiceAccess()
    }

    private func recoverBackgroundServices() async -> ServiceAccessState {
        await index.resetConnection()
        switch BackgroundServices.recoverAfterConnectionFailure() {
        case .enabled:
            return await waitForRestartedServiceAccess(attempts: 5)
        case .requiresApproval:
            return .backgroundApprovalRequired
        case .unavailable:
            return .serviceUnavailable
        }
    }

    private var serviceFailureState: ServiceAccessState {
        BackgroundServices.availability == .requiresApproval
            ? .backgroundApprovalRequired : .serviceUnavailable
    }

    private func waitForServiceStatus(attempts: Int = 3) async -> ServiceStatus? {
        for attempt in 0..<attempts {
            if let status = await index.currentStatus() { return status }
            await index.resetConnection()
            if attempt + 1 < attempts {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        return nil
    }

    private func waitForRestartedServiceAccess(attempts: Int = 10) async -> ServiceAccessState {
        guard let status = await waitForServiceStatus(attempts: attempts) else {
            return serviceFailureState
        }
        publish(status)
        return status.hasFullDiskAccess ? .granted : .denied
    }

    private func publish(_ status: ServiceStatus) {
        updateFullDiskAccess(status.hasFullDiskAccess)
        scanning = status.scanning
        total = status.totalCount
    }

    func updateFullDiskAccess(_ granted: Bool) {
        guard granted != hasFullDiskAccess || (granted && !didBootstrap) else { return }
        hasFullDiskAccess = granted
        accessGeneration &+= 1
        let generation = accessGeneration
        if granted {
            bootstrap(generation: generation)
            return
        }
        guard didBootstrap else { return }
        didBootstrap = false
        bootstrapTask?.cancel()
        maintenanceTask?.cancel()
        task?.cancel()
        liveTask?.cancel()
        scanning = false
        selectedPath = nil
        selectedIdentity = nil
        results = []
        total = 0
        Task { await index.invalidateForAccessRevocation(generation: generation) }
    }

    private func bootstrap(generation: UInt64) {
        guard !didBootstrap, hasFullDiskAccess else { return }
        didBootstrap = true
        scanning = true
        loadPrefs()   // before the first runSearch so the initial query uses saved options
        bootstrapTask = Task {
            await index.startUp(
                onLiveChange: { [weak self] in
                    Task { @MainActor in self?.liveRefresh() }
                },
                onProgress: { [weak self] count in
                    Task { @MainActor in self?.onScanProgress(count) }
                },
                accessGeneration: generation
            )
            guard !Task.isCancelled, hasFullDiskAccess else { return }
            if let status = await index.currentStatus() {
                scanning = status.scanning
                total = status.totalCount
            }
            rules = await index.currentRules()
            if !scanning { await runSearch() }
        }
    }

    // Driven by the off-actor scan: flips into "indexing" mode and streams the
    // running count to the status bar as the new index builds.
    func onScanProgress(_ count: Int) {
        guard hasFullDiskAccess, didBootstrap else { return }
        scanning = true
        total = count
        // No live search here: during the initial build the actor serves the OLD
        // index, so re-searching every tick just churns. Results refresh once when
        // the scan completes (bootstrap/applyRules call runSearch afterward).
    }

    func queryChanged() {
        invalidateSearch()
        task = Task {
            // Cancelling this Swift task cannot retract an XPC request that was
            // already delivered. Invalidate it before issuing its replacement.
            await index.cancelPendingSearch()
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 40_000_000) // debounce 40ms
            if Task.isCancelled { return }
            await runSearch()
        }
    }

    // A live search option (case / whole-word / result limit) changed: persist it and
    // re-run immediately (no debounce — these come from a deliberate click, not typing).
    private func searchOptionsChanged() {
        invalidateSearch()
        task = Task {
            await index.cancelPendingSearch()
            if Task.isCancelled { return }
            await runSearch()
        }
    }

    // Persisted sort change from a column header or the View menu.
    func setSort(_ key: QueryEngine.SortKey, ascending asc: Bool) {
        sortKey = key
        ascending = asc
        preferences.set(key.rawValue, forKey: "pref.sortKey")
        preferences.set(asc, forKey: "pref.ascending")
        Task { await runSearch() }
    }

    func setMatchPath(_ enabled: Bool) {
        guard matchPath != enabled else { return }
        matchPath = enabled
        preferences.set(enabled, forKey: "pref.matchPath")
        searchOptionsChanged()
    }

    func setCaseSensitive(_ enabled: Bool) {
        guard caseSensitive != enabled else { return }
        caseSensitive = enabled
        preferences.set(enabled, forKey: "pref.caseSensitive")
        searchOptionsChanged()
    }

    func setWholeWord(_ enabled: Bool) {
        guard wholeWord != enabled else { return }
        wholeWord = enabled
        preferences.set(enabled, forKey: "pref.wholeWord")
        searchOptionsChanged()
    }

    func setResultLimit(_ limit: Int) {
        guard resultLimit != limit else { return }
        resultLimit = limit
        preferences.set(limit, forKey: "pref.resultLimit")
        searchOptionsChanged()
    }

    func runSearch() async {
        guard !scanning else { return }
        searchSeq &+= 1
        let mySeq = searchSeq
        let r = await index.search(query, matchPath: matchPath, caseInsensitive: !caseSensitive,
                                   wholeWord: wholeWord,
                                   usesRegularExpression: usesRegularExpression,
                                   sort: sortKey, ascending: ascending, limit: resultLimit)
        // Only the most recently started search may publish — stops a slower
        // in-flight search (e.g. from a live-refresh tick) clobbering newer
        // results with a stale sort order.
        if mySeq == searchSeq && !Task.isCancelled { results = r }
    }

    // Coalesce bursts of FSEvents into at most one refresh per 200ms.
    func liveRefresh() {
        liveTask?.cancel()
        liveTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            if let status = await index.currentStatus() {
                scanning = status.scanning
                total = status.totalCount
            }
            await runSearch()
        }
    }

    func focusSearch(in window: NSWindow? = NSApp.keyWindow) {
        focusSearchWindowNumber = window?.windowNumber
        focusSearchSignal &+= 1
    }

    func runPresentedQuery(_ text: String) {
        let defaults = PresentedSearchDefaults()
        query = text
        sortKey = defaults.sortKey
        ascending = defaults.ascending
        matchPath = defaults.matchPath
        caseSensitive = defaults.caseSensitive
        wholeWord = defaults.wholeWord
        usesRegularExpression = defaults.usesRegularExpression
        resultLimit = defaults.resultLimit
        presentedDefaultsAreActive = true
        select(nil)
        invalidateSearch()
        task = Task {
            await index.cancelPendingSearch()
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    private func invalidateSearch() {
        task?.cancel()
        // Invalidate a request as soon as the user changes the query or an external
        // request arrives, before cancellation reaches the indexing service.
        searchSeq &+= 1
    }

    // MARK: - Search preference persistence (UserDefaults)

    func loadPrefs() {
        guard !presentedDefaultsAreActive else { return }
        let d = preferences
        matchPath = d.bool(forKey: "pref.matchPath")
        caseSensitive = d.bool(forKey: "pref.caseSensitive")
        wholeWord = d.bool(forKey: "pref.wholeWord")
        // Regular expressions now compose explicitly as regex: predicates.
        usesRegularExpression = false
        let lim = d.integer(forKey: "pref.resultLimit")
        resultLimit = lim > 0 ? min(max(lim, 100), 10_000) : 5000
        if let name = d.string(forKey: "pref.sortKey"),
           let persistedSortKey = QueryEngine.SortKey(rawValue: name) {
            sortKey = persistedSortKey
        }
        if d.object(forKey: "pref.ascending") != nil { ascending = d.bool(forKey: "pref.ascending") }
    }

    // Force a full whole-disk rescan (File ▸ Rebuild Index). Same shape as applyRules
    // but without changing the exclude rules — for when the index drifts or the user
    // wants to be sure it's fresh. Persists the result so the next launch matches.
    func rebuildIndex() {
        guard hasFullDiskAccess, !scanning else { return }
        beginRebuild()
        let generation = accessGeneration
        maintenanceTask = Task {
            await index.cancelPendingSearch()
            await index.rescanAll(accessGeneration: generation)
            guard !Task.isCancelled, hasFullDiskAccess,
                  generation == accessGeneration else { return }
            await index.flush(accessGeneration: generation)
            guard !Task.isCancelled, hasFullDiskAccess,
                  generation == accessGeneration else { return }
            scanning = false
            total = await index.totalCount
            await runSearch()
        }
    }

    func applyRules(_ newRules: ExcludeRules) {
        guard hasFullDiskAccess, !scanning else { return }
        beginRebuild()
        let generation = accessGeneration
        maintenanceTask = Task {
            await index.cancelPendingSearch()
            await index.setRules(newRules, accessGeneration: generation)
            guard !Task.isCancelled, hasFullDiskAccess,
                  generation == accessGeneration else { return }
            rules = newRules
            await index.rescanAll(accessGeneration: generation)
            guard !Task.isCancelled, hasFullDiskAccess,
                  generation == accessGeneration else { return }
            // Persist the freshly-rebuilt index with the new rules' fingerprint, so the
            // next launch sees a matching cache instead of rescanning again.
            await index.flush(accessGeneration: generation)
            guard !Task.isCancelled, hasFullDiskAccess,
                  generation == accessGeneration else { return }
            scanning = false
            total = await index.totalCount
            await runSearch()
        }
    }

    private func beginRebuild() {
        invalidateSearch()
        liveTask?.cancel()
        scanning = true
        results = []
        total = 0
        selectedPath = nil
        selectedIdentity = nil
    }
}
