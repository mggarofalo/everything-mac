import Foundation

public struct QueryEngine: Sendable {
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
        let plan = query.plan
        guard plan.isValid else { return [] }
        if let expression = plan.filterExpression {
            return expressionSearch(expression, query: query, in: store,
                                    componentIndex: componentIndex,
                                    isCancelled: isCancelled)
        }
        let extensionBytes = plan.fileTypes.compactMap(Glob.asciiLowerBytes)
        let alternativeExtensions = plan.alternativeFileTypes.mapValues {
            $0.compactMap(Glob.asciiLowerBytes)
        }
        var refinementPlan = plan

        if let directory = plan.directories.first, directory.hasPrefix("/"),
           store.idForDirPath(directory) == nil { return [] }

        let scopedIDs: [UInt32]?
        if plan.regularExpression == nil, plan.hasAlternativeMatchers,
           let directory = plan.directories.first, directory.hasPrefix("/") {
            scopedIDs = descendants(of: directory, in: store, maximumCount: 250_000,
                                    isCancelled: isCancelled)
        } else {
            scopedIDs = nil
        }

        let ids: [UInt32]
        if let pattern = plan.regularExpression {
            ids = regularExpressionSearch(pattern, query: query, in: store,
                                          componentIndex: componentIndex,
                                          isCancelled: isCancelled)
        } else if let scopedIDs {
            ids = scopedAlternativeSearch(scopedIDs, plan: plan,
                                          extensions: alternativeExtensions,
                                          query: query, in: store,
                                          isCancelled: isCancelled)
            refinementPlan.directories.removeFirst()
        } else if plan.hasAlternativeMatchers {
            var union: [UInt32] = []
            for groupIndex in plan.termGroups.indices {
                if isCancelled() { return [] }
                let group = plan.termGroups[groupIndex]
                let alternativeTypes = plan.alternativeFileTypes[groupIndex] ?? []
                let matches: [UInt32]
                if !group.isEmpty {
                    let groupText = group.map {
                        $0.contains(where: { $0.isWhitespace }) ? "\"\($0)\"" : $0
                    }.joined(separator: " ")
                    let groupQuery = Query(text: groupText, matchPath: query.matchPath,
                                           caseInsensitive: query.caseInsensitive,
                                           wholeWord: query.wholeWord)
                    let textMatches = textSearch(groupQuery, in: store,
                                                 componentIndex: componentIndex,
                                                 isCancelled: isCancelled)
                    let types = alternativeExtensions[groupIndex] ?? []
                    matches = types.isEmpty ? textMatches : filter(
                        textMatches, byExtensions: types, in: store,
                        isCancelled: isCancelled
                    )
                } else {
                    matches = fileTypeSearch(alternativeTypes, in: store,
                                             componentIndex: componentIndex,
                                             isCancelled: isCancelled)
                }
                union = SortedRecordIDs.union(union, matches, isCancelled: isCancelled)
            }
            ids = union
        } else if let directory = plan.directories.first, directory.hasPrefix("/") {
            ids = descendants(of: directory, in: store, isCancelled: isCancelled) ?? []
            refinementPlan.directories.removeFirst()
        } else if !plan.fileTypes.isEmpty {
            ids = fileTypeSearch(plan.fileTypes, in: store, componentIndex: componentIndex,
                                 isCancelled: isCancelled)
        } else if plan.hasFilters {
            return filteredScan(plan, extensions: extensionBytes, query: query,
                                in: store, isCancelled: isCancelled)
        } else {
            ids = rawSearch(Query(text: ""), in: store, isCancelled: isCancelled)
        }

        guard !isCancelled() else { return [] }
        var result: [UInt32] = []
        result.reserveCapacity(min(ids.count, 16_384))
        for (offset, id) in ids.enumerated() {
            if offset & 0xFFF == 0, isCancelled() { return [] }
            guard matchesFilters(refinementPlan, extensions: extensionBytes,
                                 id: id, query: query, in: store) else { continue }
            // Regex is the candidate generator, so any ordinary terms before it
            // still need their normal AND/OR semantics applied as a refinement.
            if plan.regularExpression != nil, plan.hasPositiveTerms,
               !matchesAnyTermGroup(plan.termGroups, id: id, query: query, in: store) { continue }
            result.append(id)
        }
        return result
    }

    private func expressionSearch(
        _ expression: Query.FilterExpression,
        query: Query,
        in store: FileStore,
        componentIndex: ComponentSearchIndex?,
        isCancelled: @Sendable () -> Bool
    ) -> [UInt32] {
        var regularExpressions: [String: NSRegularExpression] = [:]
        var extensionBytes: [String: [UInt8]] = [:]

        func matches(_ expression: Query.FilterExpression, id: UInt32) -> Bool {
            switch expression {
            case .predicate(let predicate):
                guard store.isLive(id) else { return false }
                switch predicate {
                case .all:
                    return true
                case .text(let term):
                    let text = query.matchPath ? store.path(of: id) : store.name(of: id)
                    guard Glob.matches(pattern: term, in: text,
                                       caseInsensitive: query.caseInsensitive) else { return false }
                    return !query.wholeWord || term.contains("*") || term.contains("?") ||
                        Glob.containsWholeWord(term, in: text,
                                               caseInsensitive: query.caseInsensitive)
                case .path(let term):
                    let normalized = term.replacingOccurrences(of: "\\", with: "/")
                    let path = store.path(of: id)
                    guard Glob.matches(pattern: normalized, in: path,
                                       caseInsensitive: query.caseInsensitive) else { return false }
                    return !query.wholeWord || term.contains("*") || term.contains("?") ||
                        Glob.containsWholeWord(normalized, in: path,
                                               caseInsensitive: query.caseInsensitive)
                case .directory(let directory):
                    let path = store.path(of: id)
                    if directory == "/" { return path.hasPrefix("/") }
                    let options: String.CompareOptions = query.caseInsensitive ? [.caseInsensitive] : []
                    return path.compare(directory, options: options) == .orderedSame ||
                        path.range(of: directory + "/", options: options.union(.anchored)) != nil
                case .fileTypes(let extensions):
                    return extensions.contains { value in
                        let key = value.lowercased()
                        let bytes: [UInt8]
                        if let cached = extensionBytes[key] {
                            bytes = cached
                        } else {
                            bytes = Glob.asciiLowerBytes(key) ?? []
                            extensionBytes[key] = bytes
                        }
                        return !bytes.isEmpty && store.extensionMatches(bytes, of: id)
                    }
                case .regularExpression(let pattern):
                    let regularExpression: NSRegularExpression
                    if let cached = regularExpressions[pattern] {
                        regularExpression = cached
                    } else {
                        let options: NSRegularExpression.Options = query.caseInsensitive
                            ? [.caseInsensitive] : []
                        guard let compiled = try? NSRegularExpression(pattern: pattern,
                                                                       options: options) else {
                            return false
                        }
                        regularExpressions[pattern] = compiled
                        regularExpression = compiled
                    }
                    return Self.matches(regularExpression, id: id, query: query, in: store)
                case .kind(let kind):
                    return kind == .folder ? store.isDir(of: id) : !store.isDir(of: id)
                case .size(let constraint):
                    return constraint.contains(store.size(of: id))
                case .modified(let constraint):
                    return constraint.contains(store.mtime(of: id))
                }
            case .and(let expressions):
                return expressions.allSatisfy { matches($0, id: id) }
            case .or(let expressions):
                return expressions.contains { matches($0, id: id) }
            case .xor(let left, let right):
                return matches(left, id: id) != matches(right, id: id)
            case .not(let excluded):
                return !matches(excluded, id: id)
            }
        }

        func scan(_ expression: Query.FilterExpression) -> [UInt32] {
            var result: [UInt32] = []
            result.reserveCapacity(min(store.count / 64 + 16, 16_384))
            for index in 0..<store.count {
                if index & 0xFFF == 0, isCancelled() { return [] }
                let id = UInt32(index)
                if matches(expression, id: id) { result.append(id) }
            }
            return result
        }

        func rank(_ expression: Query.FilterExpression) -> Int {
            switch expression {
            case .predicate(.directory): return 0
            case .predicate(.fileTypes), .predicate(.text), .predicate(.path): return 1
            case .predicate(.regularExpression): return 2
            case .or, .xor: return 3
            case .and(let expressions): return expressions.map(rank).min() ?? 8
            case .predicate(.kind), .predicate(.size), .predicate(.modified): return 7
            case .predicate(.all), .not: return 9
            }
        }

        func evaluate(_ expression: Query.FilterExpression) -> [UInt32] {
            if isCancelled() { return [] }
            switch expression {
            case .predicate(let predicate):
                switch predicate {
                case .all:
                    return rawSearch(Query(text: ""), in: store, isCancelled: isCancelled)
                case .text(let term):
                    return textSearch(
                        Query(text: term, matchPath: query.matchPath,
                              caseInsensitive: query.caseInsensitive,
                              wholeWord: query.wholeWord),
                        in: store, componentIndex: componentIndex,
                        isCancelled: isCancelled
                    )
                case .path(let term):
                    return textSearch(
                        Query(text: term, matchPath: true,
                              caseInsensitive: query.caseInsensitive,
                              wholeWord: query.wholeWord),
                        in: store, componentIndex: componentIndex,
                        isCancelled: isCancelled
                    )
                case .directory(let path):
                    return descendants(of: path, in: store, isCancelled: isCancelled) ?? []
                case .fileTypes(let extensions):
                    return fileTypeSearch(extensions, in: store,
                                          componentIndex: componentIndex,
                                          isCancelled: isCancelled)
                case .regularExpression(let pattern):
                    return regularExpressionSearch(pattern, query: query, in: store,
                                                   componentIndex: componentIndex,
                                                   isCancelled: isCancelled)
                case .kind, .size, .modified:
                    return scan(expression)
                }
            case .and(let expressions):
                guard let seedIndex = expressions.indices.min(by: {
                    rank(expressions[$0]) < rank(expressions[$1])
                }) else { return [] }
                let candidates = evaluate(expressions[seedIndex])
                let refinements = expressions.indices.filter { $0 != seedIndex }.map { expressions[$0] }
                guard !refinements.isEmpty else { return candidates }
                var result: [UInt32] = []
                result.reserveCapacity(min(candidates.count, 16_384))
                for (offset, id) in candidates.enumerated() {
                    if offset & 0xFFF == 0, isCancelled() { return [] }
                    if refinements.allSatisfy({ matches($0, id: id) }) { result.append(id) }
                }
                return result
            case .or(let expressions):
                var result: [UInt32] = []
                for alternative in expressions {
                    result = SortedRecordIDs.union(result, evaluate(alternative),
                                                   isCancelled: isCancelled)
                    if isCancelled() { return [] }
                }
                return result
            case .xor(let left, let right):
                return SortedRecordIDs.symmetricDifference(
                    evaluate(left), evaluate(right), isCancelled: isCancelled
                )
            case .not:
                return scan(expression)
            }
        }

        return evaluate(expression)
    }

    private func filter(_ ids: [UInt32], byExtensions extensions: [[UInt8]],
                        in store: FileStore,
                        isCancelled: @Sendable () -> Bool) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(min(ids.count, 16_384))
        for (offset, id) in ids.enumerated() {
            if offset & 0xFFF == 0, isCancelled() { return [] }
            if extensions.contains(where: { store.extensionMatches($0, of: id) }) {
                result.append(id)
            }
        }
        return result
    }

    private func filteredScan(_ plan: Query.Plan, extensions: [[UInt8]],
                              query: Query, in store: FileStore,
                              isCancelled: @Sendable () -> Bool) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(min(store.count / 64 + 16, 16_384))
        for index in 0..<store.count {
            if index & 0xFFF == 0, isCancelled() { return [] }
            let id = UInt32(index)
            if matchesFilters(plan, extensions: extensions, id: id, query: query, in: store) {
                result.append(id)
            }
        }
        return result
    }

    private func textSearch(_ query: Query, in store: FileStore,
                            componentIndex: ComponentSearchIndex?,
                            isCancelled: @Sendable () -> Bool) -> [UInt32] {

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

    private func descendants(of path: String, in store: FileStore,
                             maximumCount: Int? = nil,
                             isCancelled: @Sendable () -> Bool) -> [UInt32]? {
        guard path.hasPrefix("/"), let root = store.idForDirPath(path) else { return nil }
        var stack = [root]
        var result: [UInt32] = []
        while let id = stack.popLast() {
            if result.count & 0xFFF == 0, isCancelled() { return [] }
            if store.isLive(id) { result.append(id) }
            if let maximumCount, result.count > maximumCount { return nil }
            stack.append(contentsOf: store.childIDs(of: id))
        }
        result.sort()
        return result
    }

    private func matchesFilters(_ plan: Query.Plan, extensions: [[UInt8]],
                                id: UInt32, query: Query,
                                in store: FileStore) -> Bool {
        guard store.isLive(id) else { return false }
        if let kind = plan.kind {
            if kind == .file, store.isDir(of: id) { return false }
            if kind == .folder, !store.isDir(of: id) { return false }
        }
        if !plan.sizes.allSatisfy({ $0.contains(store.size(of: id)) }) { return false }
        if !plan.modified.allSatisfy({ $0.contains(store.mtime(of: id)) }) { return false }
        if !plan.fileTypes.isEmpty {
            if !extensions.contains(where: { store.extensionMatches($0, of: id) }) { return false }
        }

        var path: String?
        if !plan.directories.isEmpty || !plan.excludedTerms.isEmpty {
            path = store.path(of: id)
        }
        if !plan.directories.allSatisfy({ directory in
            guard let path else { return false }
            if directory == "/" { return path.hasPrefix("/") }
            let options: String.CompareOptions = query.caseInsensitive ? [.caseInsensitive] : []
            guard path.compare(directory, options: options) == .orderedSame ||
                    path.range(of: directory + "/", options: options.union(.anchored)) != nil else { return false }
            return true
        }) { return false }
        if let path, plan.excludedTerms.contains(where: {
            Glob.matches(pattern: $0, in: path, caseInsensitive: query.caseInsensitive)
        }) { return false }
        return true
    }

    private func matchesAnyTermGroup(_ groups: [[String]], id: UInt32, query: Query,
                                     in store: FileStore) -> Bool {
        let text = query.matchPath ? store.path(of: id) : store.name(of: id)
        return groups.contains { group in
            !group.isEmpty && group.allSatisfy { term in
                guard Glob.matches(pattern: term, in: text,
                                   caseInsensitive: query.caseInsensitive) else { return false }
                return !query.wholeWord || term.contains("*") || term.contains("?") ||
                    Glob.containsWholeWord(term, in: text, caseInsensitive: query.caseInsensitive)
            }
        }
    }

    private func scopedAlternativeSearch(
        _ ids: [UInt32], plan: Query.Plan, extensions: [Int: [[UInt8]]],
        query: Query, in store: FileStore,
        isCancelled: @Sendable () -> Bool
    ) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(min(ids.count, 16_384))
        for (offset, id) in ids.enumerated() {
            if offset & 0xFFF == 0, isCancelled() { return [] }
            if matchesAnyAlternative(plan, extensions: extensions, id: id,
                                     query: query, in: store) { result.append(id) }
        }
        return result
    }

    private func matchesAnyAlternative(_ plan: Query.Plan, extensions: [Int: [[UInt8]]],
                                       id: UInt32, query: Query,
                                       in store: FileStore) -> Bool {
        let text = query.matchPath ? store.path(of: id) : store.name(of: id)
        for groupIndex in plan.termGroups.indices {
            let terms = plan.termGroups[groupIndex]
            let types = extensions[groupIndex] ?? []
            guard !terms.isEmpty || !types.isEmpty else { continue }
            let termsMatch = terms.allSatisfy { term in
                guard Glob.matches(pattern: term, in: text,
                                   caseInsensitive: query.caseInsensitive) else { return false }
                return !query.wholeWord || term.contains("*") || term.contains("?") ||
                    Glob.containsWholeWord(term, in: text, caseInsensitive: query.caseInsensitive)
            }
            let typeMatches = types.isEmpty || types.contains { store.extensionMatches($0, of: id) }
            if termsMatch && typeMatches { return true }
        }
        return false
    }

    private func fileTypeSearch(
        _ extensions: [String],
        in store: FileStore,
        componentIndex: ComponentSearchIndex?,
        isCancelled: @Sendable () -> Bool
    ) -> [UInt32] {
        let requested = Array(Set(extensions.compactMap(Glob.asciiLowerBytes))).filter { !$0.isEmpty }
        guard !requested.isEmpty else { return [] }

        var result = Set<UInt32>()
        var scanExtensions: [[UInt8]] = []
        for bytes in requested {
            let suffix = [UInt8(46)] + bytes
            let suffixText = String(decoding: suffix, as: UTF8.self)
            if suffix.count >= 3,
               let candidates = componentIndex?.candidates(
                   for: Query(text: suffixText, caseInsensitive: true), in: store,
                   isCancelled: isCancelled
               ) {
                for (offset, id) in candidates.enumerated() {
                    if offset & 0xFFF == 0, isCancelled() { return [] }
                    if store.extensionMatches(bytes, of: id) { result.insert(id) }
                }
            } else {
                scanExtensions.append(bytes)
            }
        }

        if !scanExtensions.isEmpty {
            for index in 0..<store.count {
                if index & 0xFFF == 0, isCancelled() { return [] }
                let id = UInt32(index)
                guard store.isLive(id) else { continue }
                if scanExtensions.contains(where: { store.extensionMatches($0, of: id) }) {
                    result.insert(id)
                }
            }
        }
        return result.sorted()
    }

    private func regularExpressionSearch(
        _ pattern: String,
        query: Query,
        in store: FileStore,
        componentIndex: ComponentSearchIndex?,
        isCancelled: @Sendable () -> Bool
    ) -> [UInt32] {
        guard !pattern.isEmpty else { return [] }
        let options: NSRegularExpression.Options = query.caseInsensitive ? [.caseInsensitive] : []
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }

        let candidates: [UInt32]?
        if let literal = RegexLiteralExtractor.requiredLiteral(in: pattern), literal.utf8.count >= 3,
           let indexed = componentIndex?.candidates(
               for: Query(text: literal, matchPath: query.matchPath,
                          caseInsensitive: query.caseInsensitive),
               in: store, isCancelled: isCancelled
           ) {
            candidates = indexed
        } else {
            candidates = nil
        }

        var result: [UInt32] = []
        result.reserveCapacity(16_384)
        if let candidates {
            for (offset, id) in candidates.enumerated() {
                if offset & 0x3FF == 0, isCancelled() { return [] }
                if Self.matches(expression, id: id, query: query, in: store) { result.append(id) }
            }
            return result
        }

        if store.count < 100_000 {
            return regexScanRange(0, UInt32(store.count), expression: expression,
                                  query: query, in: store, isCancelled: isCancelled)
        }
        let chunks = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let span = (store.count + chunks - 1) / chunks
        let parts = ParallelSearchResults(chunkCount: chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let lower = chunk * span
            let upper = min(store.count, lower + span)
            guard lower < upper else { return }
            parts.store(regexScanRange(UInt32(lower), UInt32(upper), expression: expression,
                                        query: query, in: store, isCancelled: isCancelled),
                        forChunk: chunk)
        }
        return parts.joined()
    }

    private func regexScanRange(_ lower: UInt32, _ upper: UInt32,
                                expression: NSRegularExpression, query: Query,
                                in store: FileStore,
                                isCancelled: @Sendable () -> Bool) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(Int(upper - lower) / 64 + 16)
        var id = lower
        while id < upper {
            if id & 0x3FF == 0, isCancelled() { return [] }
            if Self.matches(expression, id: id, query: query, in: store) { result.append(id) }
            id &+= 1
        }
        return result
    }

    private static func matches(_ expression: NSRegularExpression, id: UInt32,
                                query: Query, in store: FileStore) -> Bool {
        guard store.isLive(id) else { return false }
        let text = query.matchPath ? store.path(of: id) : store.name(of: id)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, options: [], range: range) != nil
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
        let parts = ParallelSearchResults(chunkCount: chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let lo = c * span
            let hi = min(n, lo + span)
            guard lo < hi else { return }
            let matches = self.scanRange(UInt32(lo), UInt32(hi), matchers: matchers,
                                         matchPath: matchPath, hasNonASCII: hasNonASCII, ci: ci,
                                         in: store, isCancelled: isCancelled)
            parts.store(matches, forChunk: c)
        }
        return parts.joined()
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
