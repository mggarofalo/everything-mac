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
                       isCancelled: @escaping @Sendable () -> Bool = { false }) -> [UInt32] {
        let plan = query.plan
        guard plan.isValid else { return [] }
        if let expression = plan.filterExpression {
            return expressionSearch(expression, query: query, in: store,
                                    componentIndex: componentIndex,
                                    isCancelled: isCancelled)
        }
        guard firstDirectoryExists(plan, in: store) else { return [] }
        let selection = initialCandidates(for: plan, query: query, in: store,
                                          componentIndex: componentIndex,
                                          isCancelled: isCancelled)
        if selection.isFinal { return selection.ids }
        guard !isCancelled() else { return [] }
        return refine(selection.ids, with: selection.refinementPlan, originalPlan: plan,
                      query: query, in: store, isCancelled: isCancelled)
    }

    private struct CandidateSelection {
        let ids: [UInt32]
        let refinementPlan: Query.Plan
        let isFinal: Bool
    }

    private func firstDirectoryExists(_ plan: Query.Plan, in store: FileStore) -> Bool {
        guard let directory = plan.directories.first, directory.hasPrefix("/") else { return true }
        return store.idForDirPath(directory) != nil
    }

    private func initialCandidates(
        for plan: Query.Plan, query: Query, in store: FileStore,
        componentIndex: ComponentSearchIndex?, isCancelled: @Sendable () -> Bool
    ) -> CandidateSelection {
        var refinementPlan = plan
        let ids: [UInt32]
        if let pattern = plan.regularExpression {
            ids = regularExpressionSearch(pattern, query: query, in: store,
                                          componentIndex: componentIndex,
                                          isCancelled: isCancelled)
        } else if let scoped = scopedCandidates(for: plan, in: store,
                                                isCancelled: isCancelled) {
            let extensions = plan.alternativeFileTypes.mapValues {
                $0.compactMap(Glob.asciiLowerBytes)
            }
            ids = scopedAlternativeSearch(scoped, plan: plan, extensions: extensions,
                                          query: query, in: store, isCancelled: isCancelled)
            refinementPlan.directories.removeFirst()
        } else if plan.hasAlternativeMatchers {
            ids = alternativeCandidates(for: plan, query: query, in: store,
                                        componentIndex: componentIndex,
                                        isCancelled: isCancelled)
        } else if let directory = plan.directories.first, directory.hasPrefix("/") {
            ids = descendants(of: directory, in: store, isCancelled: isCancelled) ?? []
            refinementPlan.directories.removeFirst()
        } else if !plan.fileTypes.isEmpty {
            ids = fileTypeSearch(plan.fileTypes, in: store, componentIndex: componentIndex,
                                 isCancelled: isCancelled)
        } else if plan.hasFilters {
            let extensions = plan.fileTypes.compactMap(Glob.asciiLowerBytes)
            ids = filteredScan(plan, extensions: extensions, query: query,
                               in: store, isCancelled: isCancelled)
            return CandidateSelection(ids: ids, refinementPlan: plan, isFinal: true)
        } else {
            ids = rawSearch(Query(text: ""), in: store, isCancelled: isCancelled)
        }
        return CandidateSelection(ids: ids, refinementPlan: refinementPlan, isFinal: false)
    }

    private func scopedCandidates(for plan: Query.Plan, in store: FileStore,
                                  isCancelled: @Sendable () -> Bool) -> [UInt32]? {
        guard plan.regularExpression == nil, plan.hasAlternativeMatchers,
              let directory = plan.directories.first, directory.hasPrefix("/") else { return nil }
        return descendants(of: directory, in: store, maximumCount: 250_000,
                           isCancelled: isCancelled)
    }

    private func alternativeCandidates(
        for plan: Query.Plan, query: Query, in store: FileStore,
        componentIndex: ComponentSearchIndex?, isCancelled: @Sendable () -> Bool
    ) -> [UInt32] {
        let extensionBytes = plan.alternativeFileTypes.mapValues {
            $0.compactMap(Glob.asciiLowerBytes)
        }
        var union: [UInt32] = []
        for groupIndex in plan.termGroups.indices {
            if isCancelled() { return [] }
            let matches = alternativeCandidates(
                forGroup: groupIndex, plan: plan, extensionBytes: extensionBytes,
                query: query, in: store, componentIndex: componentIndex,
                isCancelled: isCancelled
            )
            union = SortedRecordIDs.union(union, matches, isCancelled: isCancelled)
        }
        return union
    }

    private func alternativeCandidates(
        forGroup groupIndex: Int, plan: Query.Plan, extensionBytes: [Int: [[UInt8]]],
        query: Query, in store: FileStore, componentIndex: ComponentSearchIndex?,
        isCancelled: @Sendable () -> Bool
    ) -> [UInt32] {
        let group = plan.termGroups[groupIndex]
        let alternativeTypes = plan.alternativeFileTypes[groupIndex] ?? []
        guard !group.isEmpty else {
            return fileTypeSearch(alternativeTypes, in: store, componentIndex: componentIndex,
                                  isCancelled: isCancelled)
        }
        let groupText = group.map {
            $0.contains(where: { $0.isWhitespace }) ? "\"\($0)\"" : $0
        }.joined(separator: " ")
        let groupQuery = Query(text: groupText, matchPath: query.matchPath,
                               caseInsensitive: query.caseInsensitive,
                               wholeWord: query.wholeWord)
        let textMatches = textSearch(groupQuery, in: store, componentIndex: componentIndex,
                                     isCancelled: isCancelled)
        let types = extensionBytes[groupIndex] ?? []
        return types.isEmpty ? textMatches : filter(
            textMatches, byExtensions: types, in: store, isCancelled: isCancelled
        )
    }

    private func refine(_ ids: [UInt32], with refinementPlan: Query.Plan,
                        originalPlan: Query.Plan, query: Query, in store: FileStore,
                        isCancelled: @Sendable () -> Bool) -> [UInt32] {
        let extensionBytes = originalPlan.fileTypes.compactMap(Glob.asciiLowerBytes)
        var result: [UInt32] = []
        result.reserveCapacity(min(ids.count, 16_384))
        for (offset, id) in ids.enumerated() {
            if offset & 0xFFF == 0, isCancelled() { return [] }
            guard matchesFilters(refinementPlan, extensions: extensionBytes,
                                 id: id, query: query, in: store) else { continue }
            // Regex is the candidate generator, so any ordinary terms before it
            // still need their normal AND/OR semantics applied as a refinement.
            if originalPlan.regularExpression != nil, originalPlan.hasPositiveTerms,
               !matchesAnyTermGroup(originalPlan.termGroups, id: id, query: query, in: store) {
                continue
            }
            result.append(id)
        }
        return result
    }

    private func expressionSearch(
        _ expression: Query.FilterExpression,
        query: Query,
        in store: FileStore,
        componentIndex: ComponentSearchIndex?,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> [UInt32] {
        ExpressionEvaluator(engine: self, query: query, store: store,
                            componentIndex: componentIndex,
                            isCancelled: isCancelled).evaluate(expression)
    }

    private final class ExpressionEvaluator {
        private let engine: QueryEngine
        private let query: Query
        private let store: FileStore
        private let componentIndex: ComponentSearchIndex?
        private let isCancelled: @Sendable () -> Bool
        private var regularExpressions: [String: NSRegularExpression] = [:]
        private var extensionBytes: [String: [UInt8]] = [:]

        init(engine: QueryEngine, query: Query, store: FileStore,
             componentIndex: ComponentSearchIndex?,
             isCancelled: @escaping @Sendable () -> Bool) {
            self.engine = engine
            self.query = query
            self.store = store
            self.componentIndex = componentIndex
            self.isCancelled = isCancelled
        }

        func matches(_ expression: Query.FilterExpression, id: UInt32) -> Bool {
            switch expression {
            case .predicate(let predicate): return matches(predicate, id: id)
            case .and(let expressions): return expressions.allSatisfy { matches($0, id: id) }
            case .or(let expressions): return expressions.contains { matches($0, id: id) }
            case .xor(let left, let right): return matches(left, id: id) != matches(right, id: id)
            case .not(let excluded): return !matches(excluded, id: id)
            }
        }

        private func matches(_ predicate: Query.Predicate, id: UInt32) -> Bool {
            guard store.isLive(id) else { return false }
            switch predicate {
            case .all: return true
            case .text(let term): return matchesText(term, in: itemText(id), wholeWord: query.wholeWord)
            case .path(let term): return matchesPath(term, id: id)
            case .directory(let directory): return path(id, isWithin: directory)
            case .fileTypes(let extensions): return matchesFileType(extensions, id: id)
            case .regularExpression(let pattern): return matchesRegularExpression(pattern, id: id)
            case .kind(let kind): return kind == .folder ? store.isDir(of: id) : !store.isDir(of: id)
            case .size(let constraint): return constraint.contains(store.size(of: id))
            case .modified(let constraint): return constraint.contains(store.mtime(of: id))
            }
        }

        private func itemText(_ id: UInt32) -> String {
            query.matchPath ? store.path(of: id) : store.name(of: id)
        }

        private func matchesText(_ term: String, in text: String, wholeWord: Bool) -> Bool {
            guard Glob.matches(pattern: term, in: text,
                               caseInsensitive: query.caseInsensitive) else { return false }
            return !wholeWord || term.contains("*") || term.contains("?") ||
                Glob.containsWholeWord(term, in: text, caseInsensitive: query.caseInsensitive)
        }

        private func matchesPath(_ term: String, id: UInt32) -> Bool {
            let normalized = term.replacingOccurrences(of: "\\", with: "/")
            return matchesText(normalized, in: store.path(of: id), wholeWord: query.wholeWord)
        }

        private func path(_ id: UInt32, isWithin directory: String) -> Bool {
            let path = store.path(of: id)
            if directory == "/" { return path.hasPrefix("/") }
            let options: String.CompareOptions = query.caseInsensitive ? [.caseInsensitive] : []
            return path.compare(directory, options: options) == .orderedSame ||
                path.range(of: directory + "/", options: options.union(.anchored)) != nil
        }

        private func matchesFileType(_ extensions: [String], id: UInt32) -> Bool {
            extensions.contains { value in
                let key = value.lowercased()
                let bytes = cachedExtensionBytes(for: key)
                return !bytes.isEmpty && store.extensionMatches(bytes, of: id)
            }
        }

        private func cachedExtensionBytes(for key: String) -> [UInt8] {
            if let cached = extensionBytes[key] { return cached }
            let bytes = Glob.asciiLowerBytes(key) ?? []
            extensionBytes[key] = bytes
            return bytes
        }

        private func matchesRegularExpression(_ pattern: String, id: UInt32) -> Bool {
            guard let expression = regularExpression(pattern) else { return false }
            return QueryEngine.matches(expression, id: id, query: query, in: store)
        }

        private func regularExpression(_ pattern: String) -> NSRegularExpression? {
            if let cached = regularExpressions[pattern] { return cached }
            let options: NSRegularExpression.Options = query.caseInsensitive ? [.caseInsensitive] : []
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
                return nil
            }
            regularExpressions[pattern] = expression
            return expression
        }

        func evaluate(_ expression: Query.FilterExpression) -> [UInt32] {
            if isCancelled() { return [] }
            switch expression {
            case .predicate(let predicate): return evaluate(predicate, expression: expression)
            case .and(let expressions): return evaluateAnd(expressions)
            case .or(let expressions): return evaluateOr(expressions)
            case .xor(let left, let right):
                return SortedRecordIDs.symmetricDifference(
                    evaluate(left), evaluate(right), isCancelled: isCancelled
                )
            case .not: return scan(expression)
            }
        }

        private func evaluate(_ predicate: Query.Predicate,
                              expression: Query.FilterExpression) -> [UInt32] {
            switch predicate {
            case .all:
                return engine.rawSearch(Query(text: ""), in: store, isCancelled: isCancelled)
            case .text(let term): return engine.textSearch(textQuery(term), in: store,
                                                           componentIndex: componentIndex,
                                                           isCancelled: isCancelled)
            case .path(let term): return engine.textSearch(pathQuery(term), in: store,
                                                           componentIndex: componentIndex,
                                                           isCancelled: isCancelled)
            case .directory(let path):
                return engine.descendants(of: path, in: store, isCancelled: isCancelled) ?? []
            case .fileTypes(let extensions):
                return engine.fileTypeSearch(extensions, in: store, componentIndex: componentIndex,
                                             isCancelled: isCancelled)
            case .regularExpression(let pattern):
                return engine.regularExpressionSearch(pattern, query: query, in: store,
                                                      componentIndex: componentIndex,
                                                      isCancelled: isCancelled)
            case .kind, .size, .modified: return scan(expression)
            }
        }

        private func textQuery(_ term: String) -> Query {
            Query(text: term, matchPath: query.matchPath, caseInsensitive: query.caseInsensitive,
                  wholeWord: query.wholeWord)
        }

        private func pathQuery(_ term: String) -> Query {
            Query(text: term, matchPath: true, caseInsensitive: query.caseInsensitive,
                  wholeWord: query.wholeWord)
        }

        private func evaluateAnd(_ expressions: [Query.FilterExpression]) -> [UInt32] {
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
        }

        private func evaluateOr(_ expressions: [Query.FilterExpression]) -> [UInt32] {
            var result: [UInt32] = []
            for alternative in expressions {
                result = SortedRecordIDs.union(result, evaluate(alternative),
                                               isCancelled: isCancelled)
                if isCancelled() { return [] }
            }
            return result
        }

        private func scan(_ expression: Query.FilterExpression) -> [UInt32] {
            var result: [UInt32] = []
            result.reserveCapacity(min(store.count / 64 + 16, 16_384))
            for index in 0..<store.count {
                if index & 0xFFF == 0, isCancelled() { return [] }
                let id = UInt32(index)
                if matches(expression, id: id) { result.append(id) }
            }
            return result
        }

        private func rank(_ expression: Query.FilterExpression) -> Int {
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
        if !matchesKind(plan.kind, id: id, in: store) { return false }
        if !plan.sizes.allSatisfy({ $0.contains(store.size(of: id)) }) { return false }
        if !plan.modified.allSatisfy({ $0.contains(store.mtime(of: id)) }) { return false }
        if !plan.fileTypes.isEmpty,
           !extensions.contains(where: { store.extensionMatches($0, of: id) }) { return false }
        return matchesPathFilters(plan, id: id, query: query, in: store)
    }

    private func matchesKind(_ kind: Query.FileKind?, id: UInt32, in store: FileStore) -> Bool {
        guard let kind else { return true }
        return kind == .folder ? store.isDir(of: id) : !store.isDir(of: id)
    }

    private func matchesPathFilters(_ plan: Query.Plan, id: UInt32, query: Query,
                                    in store: FileStore) -> Bool {
        guard !plan.directories.isEmpty || !plan.excludedTerms.isEmpty else { return true }
        let path = store.path(of: id)
        if !plan.directories.allSatisfy({ isPath(path, within: $0,
                                                 caseInsensitive: query.caseInsensitive) }) {
            return false
        }
        return !plan.excludedTerms.contains {
            Glob.matches(pattern: $0, in: path, caseInsensitive: query.caseInsensitive)
        }
    }

    private func isPath(_ path: String, within directory: String,
                        caseInsensitive: Bool) -> Bool {
        if directory == "/" { return path.hasPrefix("/") }
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        return path.compare(directory, options: options) == .orderedSame ||
            path.range(of: directory + "/", options: options.union(.anchored)) != nil
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
            guard let candidates = indexedFileTypeCandidates(
                bytes, in: store, componentIndex: componentIndex,
                isCancelled: isCancelled
            ) else {
                scanExtensions.append(bytes)
                continue
            }
            if !collectFileTypeMatches(candidates, extensionBytes: bytes, in: store,
                                       into: &result, isCancelled: isCancelled) { return [] }
        }
        if !collectScannedFileTypes(scanExtensions, in: store, into: &result,
                                    isCancelled: isCancelled) {
            return []
        }
        return result.sorted()
    }

    private func indexedFileTypeCandidates(
        _ bytes: [UInt8], in store: FileStore, componentIndex: ComponentSearchIndex?,
        isCancelled: @Sendable () -> Bool
    ) -> [UInt32]? {
        let suffix = [UInt8(46)] + bytes
        guard suffix.count >= 3 else { return nil }
        let suffixText = String(decoding: suffix, as: UTF8.self)
        return componentIndex?.candidates(
            for: Query(text: suffixText, caseInsensitive: true), in: store,
            isCancelled: isCancelled
        )
    }

    private func collectFileTypeMatches(
        _ candidates: [UInt32], extensionBytes: [UInt8], in store: FileStore,
        into result: inout Set<UInt32>, isCancelled: @Sendable () -> Bool
    ) -> Bool {
        for (offset, id) in candidates.enumerated() {
            if offset & 0xFFF == 0, isCancelled() { return false }
            if store.extensionMatches(extensionBytes, of: id) { result.insert(id) }
        }
        return true
    }

    private func collectScannedFileTypes(
        _ extensions: [[UInt8]], in store: FileStore, into result: inout Set<UInt32>,
        isCancelled: @Sendable () -> Bool
    ) -> Bool {
        guard !extensions.isEmpty else { return true }
        for index in 0..<store.count {
            if index & 0xFFF == 0, isCancelled() { return false }
            let id = UInt32(index)
            guard store.isLive(id) else { continue }
            if extensions.contains(where: { store.extensionMatches($0, of: id) }) {
                result.insert(id)
            }
        }
        return true
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
        // Whether any record is tombstoned. If not, skip the per-id live check
        // entirely (the common case — keeps the hot all-ASCII loop branch-free).
        let checkLive = store.hasDeletions
        if matchPath {
            return scanPathRange(lo, hi, matchers: matchers, caseInsensitive: ci,
                                 checkLive: checkLive, in: store, isCancelled: isCancelled)
        }
        if hasNonASCII {
            return scanMixedNameRange(lo, hi, matchers: matchers, caseInsensitive: ci,
                                      checkLive: checkLive, in: store, isCancelled: isCancelled)
        }
        return scanASCIINameRange(lo, hi, matchers: matchers, checkLive: checkLive,
                                  in: store, isCancelled: isCancelled)
    }

    private func scanPathRange(
        _ lower: UInt32, _ upper: UInt32, matchers: [TermMatcher], caseInsensitive: Bool,
        checkLive: Bool, in store: FileStore, isCancelled: @Sendable () -> Bool
    ) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(Int(upper - lower) / 64 + 16)
        var id = lower
        while id < upper {
            if id & 0xFFF == 0, isCancelled() { return [] }
            defer { id &+= 1 }
            if checkLive, !store.isLive(id) { continue }
            let path = store.path(of: id)
            let bytes = Array(path.utf8)[...]
            if matchers.allSatisfy({ matches($0, text: path, bytes: bytes,
                                              caseInsensitive: caseInsensitive) }) {
                out.append(id)
            }
        }
        return out
    }

    private func scanMixedNameRange(
        _ lower: UInt32, _ upper: UInt32, matchers: [TermMatcher], caseInsensitive: Bool,
        checkLive: Bool, in store: FileStore, isCancelled: @Sendable () -> Bool
    ) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(Int(upper - lower) / 64 + 16)
        var id = lower
        while id < upper {
            if id & 0xFFF == 0, isCancelled() { return [] }
            defer { id &+= 1 }
            if checkLive, !store.isLive(id) { continue }
            let bytes = store.nameBytesSlice(of: id)
            let text = store.name(of: id)
            if matchers.allSatisfy({ matches($0, text: text, bytes: bytes,
                                              caseInsensitive: caseInsensitive) }) {
                out.append(id)
            }
        }
        return out
    }

    private func matches(_ matcher: TermMatcher, text: String, bytes: ArraySlice<UInt8>,
                         caseInsensitive: Bool) -> Bool {
        switch matcher {
        case .ascii(let pattern):
            return Glob.matchesASCII(patternLowerBytes: pattern, in: bytes)
        case .string(let term):
            return Glob.matches(pattern: term, in: text, caseInsensitive: caseInsensitive)
        }
    }

    // Common case: all terms ASCII — zero String allocation per record.
    private func scanASCIINameRange(
        _ lower: UInt32, _ upper: UInt32, matchers: [TermMatcher], checkLive: Bool,
        in store: FileStore, isCancelled: @Sendable () -> Bool
    ) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(Int(upper - lower) / 64 + 16)
        var id = lower
        while id < upper {
            if id & 0xFFF == 0, isCancelled() { return [] }
            defer { id &+= 1 }
            if checkLive, !store.isLive(id) { continue }
            let name = store.nameBytesSlice(of: id)
            if matchers.allSatisfy({ matcher in
                guard case .ascii(let pattern) = matcher else { return false }
                return Glob.matchesASCII(patternLowerBytes: pattern, in: name)
            }) {
                out.append(id)
            }
        }
        return out
    }
}
