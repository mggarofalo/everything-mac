import Foundation

/// A derived substring index over individual filename/path components.
///
/// Each lowercased ASCII trigram maps to the monotonically increasing record IDs
/// whose own component contains it. Full paths are deliberately not duplicated:
/// path searches use the rarest component posting as a candidate generator, then
/// verify those candidates and their descendants against reconstructed paths.
public struct ComponentSearchIndex: Sendable {
    private var postings: [UInt32: [UInt32]] = [:]
    public private(set) var indexedRecordCount = 0

    public init() {}

    /// Add records appended since the last synchronization. Tombstones remain in
    /// postings and are rejected during lookup; this makes live deletes O(1).
    @discardableResult
    public mutating func synchronize(
        with store: FileStore,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> Bool {
        guard indexedRecordCount <= store.count else {
            self = ComponentSearchIndex()
            return synchronize(with: store, isCancelled: isCancelled)
        }

        while indexedRecordCount < store.count {
            if indexedRecordCount & 0xFFF == 0, isCancelled() { return false }
            let id = UInt32(indexedRecordCount)
            let keys = Self.uniqueTrigrams(in: store.nameBytesSlice(of: id))
            for key in keys { postings[key, default: []].append(id) }
            indexedRecordCount += 1
        }
        return true
    }

    /// Drop geometric growth slack after a whole-store build. Incremental live
    /// additions can grow individual lists again, but the persistent baseline
    /// should reflect posting counts rather than Array capacity headroom.
    public mutating func compactStorage() {
        for key in Array(postings.keys) {
            guard let values = postings[key] else { continue }
            postings[key] = values.withUnsafeBufferPointer { Array($0) }
        }
    }

    /// Returns nil when the query cannot use this index and should take the exact
    /// legacy fallback. A non-nil result has already been fully verified.
    public func candidates(
        for query: Query,
        in store: FileStore,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [UInt32]? {
        guard !query.terms.isEmpty,
              query.terms.allSatisfy({ !$0.contains("*") && !$0.contains("?") }) else {
            return nil
        }

        let terms = query.matchPath
            ? query.terms.map { $0.replacingOccurrences(of: "\\", with: "/") }
            : query.terms

        var seed: (term: [UInt8], ids: [UInt32])?
        for term in terms {
            let fragments = query.matchPath
                ? term.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                : [term]
            for fragment in fragments {
                guard let bytes = Glob.asciiLowerBytes(fragment), bytes.count >= 3 else { continue }
                for key in Self.trigrams(in: bytes) {
                    guard let ids = postings[key] else { return [] }
                    if seed == nil || ids.count < seed!.ids.count { seed = (bytes, ids) }
                }
            }
        }
        guard let seed else { return nil }

        if !query.matchPath {
            let matchers = terms.compactMap(Glob.asciiLowerBytes)
            guard matchers.count == terms.count else { return nil }
            var result: [UInt32] = []
            result.reserveCapacity(min(seed.ids.count, 16_384))
            for (offset, id) in seed.ids.enumerated() {
                if offset & 0xFFF == 0, isCancelled() { return [] }
                guard store.isLive(id) else { continue }
                let name = store.nameBytesSlice(of: id)
                if matchers.allSatisfy({ Glob.matchesASCII(patternLowerBytes: $0, in: name) }) {
                    result.append(id)
                }
            }
            return result
        }

        var visited = Set<UInt32>()
        var result: [UInt32] = []
        for (offset, componentID) in seed.ids.enumerated() {
            if offset & 0x3FF == 0, isCancelled() { return [] }
            guard store.isLive(componentID),
                  Glob.matchesASCII(patternLowerBytes: seed.term,
                                    in: store.nameBytesSlice(of: componentID)) else { continue }
            var stack = [componentID]
            while let id = stack.popLast() {
                if visited.insert(id).inserted {
                    if store.isLive(id), Self.pathMatches(terms, caseInsensitive: query.caseInsensitive,
                                                          id: id, in: store) {
                        result.append(id)
                    }
                    stack.append(contentsOf: store.childIDs(of: id))
                }
                if visited.count & 0xFFF == 0, isCancelled() { return [] }
            }
        }
        result.sort()
        return result
    }

    private static func pathMatches(_ terms: [String], caseInsensitive: Bool,
                                    id: UInt32, in store: FileStore) -> Bool {
        let path = store.path(of: id)
        return terms.allSatisfy {
            Glob.matches(pattern: $0, in: path, caseInsensitive: caseInsensitive)
        }
    }

    private static func uniqueTrigrams(in bytes: ArraySlice<UInt8>) -> [UInt32] {
        var folded: [UInt8] = []
        folded.reserveCapacity(bytes.count)
        for byte in bytes {
            guard byte < 0x80 else {
                folded.append(0xFF)
                continue
            }
            folded.append(byte >= 0x41 && byte <= 0x5A ? byte &+ 0x20 : byte)
        }
        var keys = trigrams(in: folded)
        keys.sort()
        var unique: [UInt32] = []
        unique.reserveCapacity(keys.count)
        for key in keys where unique.last != key { unique.append(key) }
        return unique
    }

    private static func trigrams(in bytes: [UInt8]) -> [UInt32] {
        guard bytes.count >= 3 else { return [] }
        var keys: [UInt32] = []
        keys.reserveCapacity(bytes.count - 2)
        for index in 0...(bytes.count - 3) {
            let a = bytes[index], b = bytes[index + 1], c = bytes[index + 2]
            guard a < 0x80, b < 0x80, c < 0x80 else { continue }
            keys.append(UInt32(a) << 16 | UInt32(b) << 8 | UInt32(c))
        }
        return keys
    }
}
