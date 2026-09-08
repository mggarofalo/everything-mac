import Foundation

public struct QueryEngine: Sendable {
    private final class ChunkResults: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[UInt32]]

        init(count: Int) { values = [[UInt32]](repeating: [], count: count) }

        func set(_ value: [UInt32], at index: Int) {
            lock.lock()
            values[index] = value
            lock.unlock()
        }

        func flattened() -> [UInt32] {
            lock.lock()
            defer { lock.unlock() }
            return values.flatMap { $0 }
        }
    }

    public init() {}

    // Pre-classified term: ASCII bytes (fast path) or String fallback.
    private enum TermMatcher {
        case ascii([UInt8])   // lowercased ASCII pattern bytes
        case string(String)   // original term, for non-ASCII or case-sensitive fallback
    }

    // Returns matching record ids in ascending id order. All terms must match (AND).
    // The substring/glob scan is the hot path; "Match whole word" is layered on top as
    // a cheap refinement pass over the already-narrowed result set, so the inner scan
    // loops stay exactly as fast as before and pay nothing when the option is off.
    public func search(_ query: Query, in store: FileStore,
                       componentIndex: ComponentSearchIndex? = nil,
                       isCancelled: @Sendable () -> Bool = { false }) -> [UInt32] {
        let normalizedQuery: Query
        if query.matchPath, query.text.contains("\\") {
            normalizedQuery = Query(text: query.text.replacingOccurrences(of: "\\", with: "/"),
                                    matchPath: true, caseInsensitive: query.caseInsensitive,
                                    wholeWord: query.wholeWord)
        } else {
            normalizedQuery = query
        }
        let ids: [UInt32]
        if let indexed = componentIndex?.candidates(for: normalizedQuery, in: store,
                                                     isCancelled: isCancelled) {
            ids = indexed
        } else {
            ids = rawSearch(normalizedQuery, in: store, isCancelled: isCancelled)
        }
        guard !isCancelled() else { return [] }
        guard normalizedQuery.wholeWord else { return ids }
        var refined: [UInt32] = []
        refined.reserveCapacity(ids.count)
        for (offset, id) in ids.enumerated() {
            if offset & 0xFFF == 0, isCancelled() { return [] }
            if wholeWordMatch(normalizedQuery, id: id, in: store) {
                refined.append(id)
            }
        }
        return refined
    }

    // Every plain (non-wildcard) term must occur as a whole word in the candidate's
    // name (or full path, when matching paths). Wildcard terms already matched via the
    // glob scan and aren't constrained further — "whole word" has no meaning for them.
    private func wholeWordMatch(_ query: Query, id: UInt32, in store: FileStore) -> Bool {
        let text = query.matchPath ? store.path(of: id) : store.name(of: id)
        for term in query.terms where !(term.contains("*") || term.contains("?")) {
            if !Glob.containsWholeWord(term, in: text, caseInsensitive: query.caseInsensitive) { return false }
        }
        return true
    }

    // Compatibility path for wildcard, very short, and other queries that cannot use
    // the component index. Large fallback scans are split across cores.
    private func rawSearch(_ query: Query, in store: FileStore,
                           isCancelled: @Sendable () -> Bool) -> [UInt32] {
        let terms = query.terms
        let n = store.count
        // Empty query = every record. With no tombstones the id range IS the answer
        // (instant). With deletions, one reserved single-threaded pass dropping dead
        // ids — faster than the chunked scan here, whose per-chunk arrays + flatMap
        // merge cost more than the scan for an all-match result.
        if terms.isEmpty {
            if !store.hasDeletions { return Array(0..<UInt32(n)) }
            var out = [UInt32](); out.reserveCapacity(n)
            var id: UInt32 = 0
            let upper = UInt32(n)
            while id < upper {
                if id & 0xFFF == 0, isCancelled() { return [] }
                if store.isLive(id) { out.append(id) }
                id &+= 1
            }
            return out
        }

        let matchers: [TermMatcher] = terms.map { term in
            if query.caseInsensitive, let bytes = Glob.asciiLowerBytes(term) { return .ascii(bytes) }
            return .string(term)
        }
        let ci = query.caseInsensitive
        let matchPath = query.matchPath
        let hasNonASCII = matchers.contains { if case .string = $0 { return true }; return false }

        // The common Match Path query is one or more plain terms. Since parent IDs
        // always precede their children, propagate "this component or an ancestor
        // matched" in a single allocation-free path pass per term. Reconstructing a
        // full String path for every one of several million records took tens of
        // seconds and made the table appear frozen. Slash-containing and wildcard
        // terms retain the exact full-path fallback below.
        if matchPath, terms.allSatisfy({ !$0.contains("/") && !$0.contains("*") && !$0.contains("?") }) {
            return inheritedPathSearch(terms, caseInsensitive: ci, in: store,
                                       isCancelled: isCancelled)
        }

        // Serial below this threshold — thread fan-out isn't worth it for small stores.
        if n < 100_000 {
            return scanRange(0, UInt32(n), matchers: matchers, matchPath: matchPath,
                             hasNonASCII: hasNonASCII, ci: ci, in: store,
                             isCancelled: isCancelled)
        }

        // Parallel: each chunk scans a contiguous id range with the same inlined
        // loop; results are concatenated in chunk order so output stays id-ascending.
        // `store` crosses the boundary once per chunk (not per record), so the hot
        // loop stays inlinable and ARC-free per id.
        let chunks = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let span = (n + chunks - 1) / chunks
        let parts = ChunkResults(count: chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let lo = c * span
            let hi = min(n, lo + span)
            guard lo < hi else { return }
            let matches = self.scanRange(UInt32(lo), UInt32(hi), matchers: matchers,
                                         matchPath: matchPath, hasNonASCII: hasNonASCII, ci: ci,
                                         in: store, isCancelled: isCancelled)
            parts.set(matches, at: c)
        }
        return parts.flattened()
    }

    private func inheritedPathSearch(_ terms: [String], caseInsensitive: Bool,
                                     in store: FileStore,
                                     isCancelled: @Sendable () -> Bool) -> [UInt32] {
        let n = store.count
        var matchesAll = [Bool](repeating: true, count: n)
        for term in terms {
            let ascii = caseInsensitive ? Glob.asciiLowerBytes(term) : nil
            var inherited = [Bool](repeating: false, count: n)
            for index in 0..<n {
                if index & 0xFFF == 0, isCancelled() { return [] }
                let id = UInt32(index)
                let parent = store.parent(of: id)
                let ancestorMatched = parent != FileStore.noParent && inherited[Int(parent)]
                let componentMatched: Bool
                if let ascii {
                    componentMatched = Glob.matchesASCII(patternLowerBytes: ascii,
                                                          in: store.nameBytesSlice(of: id))
                } else {
                    componentMatched = Glob.matches(pattern: term, in: store.name(of: id),
                                                    caseInsensitive: caseInsensitive)
                }
                inherited[index] = ancestorMatched || componentMatched
                matchesAll[index] = matchesAll[index] && inherited[index]
            }
        }
        var result: [UInt32] = []
        result.reserveCapacity(min(n, 16_384))
        for index in 0..<n where matchesAll[index] && store.isLive(UInt32(index)) {
            result.append(UInt32(index))
        }
        return result
    }

    // Scan ids in [lo, hi) and return those matching every term. The match logic is
    // inlined in three specialized loops (path / mixed-non-ASCII / all-ASCII) so the
    // common all-ASCII name scan allocates nothing and the optimizer can inline the
    // byte matcher. Called once per chunk — `store` is borrowed for the whole range.
    private func scanRange(_ lo: UInt32, _ hi: UInt32, matchers: [TermMatcher],
                           matchPath: Bool, hasNonASCII: Bool, ci: Bool, in store: FileStore,
                           isCancelled: @Sendable () -> Bool) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(Int(hi - lo) / 64 + 16)

        // Whether any record is tombstoned. If not, skip the per-id live check
        // entirely (the common case — keeps the hot all-ASCII loop branch-free).
        let checkLive = store.hasDeletions

        if matchPath {
            var id = lo
            while id < hi {
                if id & 0xFFF == 0, isCancelled() { return [] }
                if checkLive && !store.isLive(id) { id &+= 1; continue }
                let pathStr = store.path(of: id)
                var all = true
                for m in matchers {
                    switch m {
                    case .ascii(let pat):
                        if !Glob.matchesASCII(patternLowerBytes: pat, in: Array(pathStr.utf8)[...]) { all = false }
                    case .string(let term):
                        if !Glob.matches(pattern: term, in: pathStr, caseInsensitive: ci) { all = false }
                    }
                    if !all { break }
                }
                if all { out.append(id) }
                id &+= 1
            }
        } else if hasNonASCII {
            var id = lo
            while id < hi {
                if id & 0xFFF == 0, isCancelled() { return [] }
                if checkLive && !store.isLive(id) { id &+= 1; continue }
                let nameSlice = store.nameBytesSlice(of: id)
                var all = true
                var nameStr: String? = nil
                for m in matchers {
                    switch m {
                    case .ascii(let pat):
                        if !Glob.matchesASCII(patternLowerBytes: pat, in: nameSlice) { all = false }
                    case .string(let term):
                        if nameStr == nil { nameStr = store.name(of: id) }
                        if !Glob.matches(pattern: term, in: nameStr!, caseInsensitive: ci) { all = false }
                    }
                    if !all { break }
                }
                if all { out.append(id) }
                id &+= 1
            }
        } else {
            // Common case: all terms ASCII — zero String allocation per record.
            var id = lo
            while id < hi {
                if id & 0xFFF == 0, isCancelled() { return [] }
                if checkLive && !store.isLive(id) { id &+= 1; continue }
                let nameSlice = store.nameBytesSlice(of: id)
                var all = true
                for m in matchers {
                    if case .ascii(let pat) = m, !Glob.matchesASCII(patternLowerBytes: pat, in: nameSlice) {
                        all = false; break
                    }
                }
                if all { out.append(id) }
                id &+= 1
            }
        }
        return out
    }
}

public extension QueryEngine {
    enum SortKey: Sendable { case name, path, size, mtime, kind }

    // `a` ranks before `b` in ASCENDING order for the given key. Name uses the
    // allocation-free byte comparator; path falls back to a String compare (rare,
    // user-selected column). size/mtime are plain integer compares.
    private func ascendingLess(_ key: SortKey, in store: FileStore) -> (UInt32, UInt32) -> Bool {
        switch key {
        case .name:  return { store.nameSortsBefore($0, $1) }
        case .path:  return { store.path(of: $0).localizedStandardCompare(store.path(of: $1)) == .orderedAscending }
        case .size:  return { store.size(of: $0) < store.size(of: $1) }
        case .mtime: return { store.mtime(of: $0) < store.mtime(of: $1) }
        case .kind:  return { store.kindSortsBefore($0, $1) }
        }
    }

    func sort(_ ids: [UInt32], by key: SortKey, ascending: Bool, in store: FileStore) -> [UInt32] {
        let asc = ascendingLess(key, in: store)
        let less: (UInt32, UInt32) -> Bool = ascending ? asc : { asc($1, $0) }
        return ids.sorted(by: less)
    }

    /// Return at most `limit` ids in sorted order without fully sorting `ids`.
    /// Keeps the best `limit` via a bounded max-heap (worst-ranked on top), so the
    /// cost is O(n · log limit) instead of O(n · log n). With millions of matches
    /// for a short prefix, full-sorting every keystroke is what made typing lag;
    /// since the UI only ever shows `limit` rows, the rest never needs ordering.
    func sortedPrefix(_ ids: [UInt32], by key: SortKey, ascending: Bool,
                      limit: Int, in store: FileStore,
                      isCancelled: @Sendable () -> Bool = { false }) -> [UInt32] {
        let asc = ascendingLess(key, in: store)
        let earlier: (UInt32, UInt32) -> Bool = ascending ? asc : { asc($1, $0) }

        if ids.count <= limit { return ids.sorted(by: earlier) }

        // Max-heap keyed by "worse rank" — the element most likely to be evicted
        // sits at the root. `worse(x, y)` is true when x ranks AFTER y.
        func worse(_ x: UInt32, _ y: UInt32) -> Bool { earlier(y, x) }
        var heap: [UInt32] = []
        heap.reserveCapacity(limit)

        func siftUp(_ start: Int) {
            var i = start
            while i > 0 {
                let parent = (i - 1) / 2
                if worse(heap[i], heap[parent]) { heap.swapAt(i, parent); i = parent } else { break }
            }
        }
        func siftDown(_ start: Int) {
            var i = start
            let n = heap.count
            while true {
                let l = 2 * i + 1, r = 2 * i + 2
                var m = i
                if l < n && worse(heap[l], heap[m]) { m = l }
                if r < n && worse(heap[r], heap[m]) { m = r }
                if m == i { break }
                heap.swapAt(i, m); i = m
            }
        }

        for (offset, id) in ids.enumerated() {
            if offset & 0xFFF == 0, isCancelled() { return [] }
            if heap.count < limit {
                heap.append(id); siftUp(heap.count - 1)
            } else if earlier(id, heap[0]) {   // better than the worst kept → replace it
                heap[0] = id; siftDown(0)
            }
        }
        return heap.sorted(by: earlier)
    }
}
