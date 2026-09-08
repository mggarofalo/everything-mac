import Foundation

/// A derived substring index over individual filename/path components.
///
/// Each lowercased ASCII trigram maps to the monotonically increasing record IDs
/// whose own component contains it. Full paths are deliberately not duplicated:
/// path searches use the rarest component posting as a candidate generator, then
/// verify those candidates and their descendants against reconstructed paths.
public struct ComponentSearchIndex: Sendable {
    private struct Posting: Sendable {
        let byteOffset: Int
        let byteCount: Int
        let idCount: Int
        let lastID: UInt32
    }

    private struct PendingPosting: Sendable {
        var bytes: [UInt8] = []
        var idCount = 0
        var lastID: UInt32

        mutating func append(_ id: UInt32) {
            ComponentSearchIndex.encode(id &- lastID, into: &bytes)
            lastID = id
            idCount += 1
        }
    }

    // The stable baseline is delta/varint encoded because every posting is a
    // monotonically increasing sequence of record IDs. Newly appended filesystem
    // records stay in a small mutable tail until the next whole-index rebuild.
    private var directory: [UInt32: Posting] = [:]
    private var compressedIDs: [UInt8] = []
    private var pendingPostings: [UInt32: PendingPosting] = [:]
    public private(set) var indexedRecordCount = 0
    public private(set) var postingIDCount = 0
    public var compressedByteCount: Int { compressedIDs.count }

    public init() {}

    /// Build a compact whole-store baseline without first materializing UInt32
    /// posting arrays. The first pass measures exact varint sizes; the second fills
    /// one allocation. Dense temporary counters are indexed by a packed 21-bit
    /// ASCII trigram and disappear before this value is returned.
    @discardableResult
    public mutating func rebuild(
        with store: FileStore,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> Bool {
        let keySpace = 1 << 21
        var bytePositions = [UInt32](repeating: 0, count: keySpace)
        var counts = [UInt32](repeating: 0, count: keySpace)
        var previousIDs = [UInt32](repeating: 0, count: keySpace)
        var usedKeys: [UInt32] = []
        usedKeys.reserveCapacity(64_000)
        var totalPostings = 0

        for recordIndex in 0..<store.count {
            if recordIndex & 0xFFF == 0, isCancelled() { return false }
            let id = UInt32(recordIndex)
            for key in Self.uniqueTrigrams(in: store.nameBytesSlice(of: id)) {
                let index = Int(key)
                if counts[index] == 0 { usedKeys.append(key) }
                let delta = id &- previousIDs[index]
                bytePositions[index] &+= UInt32(Self.encodedLength(delta))
                counts[index] &+= 1
                previousIDs[index] = id
                totalPostings += 1
            }
        }

        var compactDirectory: [UInt32: Posting] = [:]
        compactDirectory.reserveCapacity(usedKeys.count)
        var totalBytes = 0
        for key in usedKeys {
            let index = Int(key)
            let byteCount = Int(bytePositions[index])
            compactDirectory[key] = Posting(byteOffset: totalBytes,
                                            byteCount: byteCount,
                                            idCount: Int(counts[index]),
                                            lastID: previousIDs[index])
            bytePositions[index] = UInt32(totalBytes)
            previousIDs[index] = 0
            totalBytes += byteCount
        }

        var bytes = [UInt8](repeating: 0, count: totalBytes)
        for recordIndex in 0..<store.count {
            if recordIndex & 0xFFF == 0, isCancelled() { return false }
            let id = UInt32(recordIndex)
            for key in Self.uniqueTrigrams(in: store.nameBytesSlice(of: id)) {
                let index = Int(key)
                let delta = id &- previousIDs[index]
                var position = Int(bytePositions[index])
                Self.encode(delta, into: &bytes, at: &position)
                bytePositions[index] = UInt32(position)
                previousIDs[index] = id
            }
        }

        directory = compactDirectory
        compressedIDs = bytes
        pendingPostings = [:]
        indexedRecordCount = store.count
        postingIDCount = totalPostings
        return true
    }

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
            for key in keys {
                let previous = directory[key]?.lastID ?? 0
                pendingPostings[key, default: PendingPosting(lastID: previous)].append(id)
            }
            postingIDCount += keys.count
            indexedRecordCount += 1
        }
        return true
    }

    /// Freeze the mutable postings into one compact byte arena. IDs are stored as
    /// unsigned deltas using base-128 varints; common postings have small gaps and
    /// therefore usually consume one or two bytes per ID instead of four plus the
    /// overhead of thousands of independently allocated Swift Arrays.
    public mutating func compactStorage() {
        guard !pendingPostings.isEmpty else { return }

        // Whole-store construction has no compressed baseline. Remove each source
        // list as it is encoded so its allocation can be released while the byte
        // arena grows, keeping peak memory substantially below a two-copy rebuild.
        if directory.isEmpty {
            var bytes: [UInt8] = []
            var compactDirectory: [UInt32: Posting] = [:]
            compactDirectory.reserveCapacity(pendingPostings.count)
            for key in Array(pendingPostings.keys) {
                guard let pending = pendingPostings.removeValue(forKey: key) else { continue }
                let offset = bytes.count
                bytes.append(contentsOf: pending.bytes)
                compactDirectory[key] = Posting(byteOffset: offset,
                                                byteCount: bytes.count - offset,
                                                idCount: pending.idCount,
                                                lastID: pending.lastID)
            }
            pendingPostings = [:]
            compressedIDs = bytes
            directory = compactDirectory
            return
        }

        // This path is only needed if a caller explicitly recompacts an incremental
        // tail. Concatenate the already-compatible encoded streams in posting order.
        let keys = Set(directory.keys).union(pendingPostings.keys)
        var bytes: [UInt8] = []
        var compactDirectory: [UInt32: Posting] = [:]
        compactDirectory.reserveCapacity(keys.count)
        for key in keys {
            let offset = bytes.count
            var count = 0
            var lastID: UInt32 = 0
            if let posting = directory[key] {
                let end = posting.byteOffset + posting.byteCount
                bytes.append(contentsOf: compressedIDs[posting.byteOffset..<end])
                count += posting.idCount
                lastID = posting.lastID
            }
            if let pending = pendingPostings[key] {
                bytes.append(contentsOf: pending.bytes)
                count += pending.idCount
                lastID = pending.lastID
            }
            compactDirectory[key] = Posting(byteOffset: offset,
                                            byteCount: bytes.count - offset,
                                            idCount: count,
                                            lastID: lastID)
        }
        compressedIDs = bytes
        directory = compactDirectory
        pendingPostings = [:]
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

        var seed: (term: [UInt8], key: UInt32, count: Int)?
        for term in terms {
            let fragments = query.matchPath
                ? term.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                : [term]
            for fragment in fragments {
                guard let bytes = Glob.asciiLowerBytes(fragment), bytes.count >= 3 else { continue }
                for key in Self.trigrams(in: bytes) {
                    let count = postingCount(for: key)
                    guard count > 0 else { return [] }
                    if seed == nil || count < seed!.count { seed = (bytes, key, count) }
                }
            }
        }
        guard let seed else { return nil }
        let seedIDs = decodedPosting(for: seed.key)

        if !query.matchPath {
            var result: [UInt32] = []
            result.reserveCapacity(min(seed.count, 16_384))
            let matchers = query.caseInsensitive ? terms.compactMap(Glob.asciiLowerBytes) : []
            if query.caseInsensitive, matchers.count != terms.count { return nil }
            for (offset, id) in seedIDs.enumerated() {
                if offset & 0xFFF == 0, isCancelled() { return [] }
                guard store.isLive(id) else { continue }
                let matches = query.caseInsensitive
                    ? matchers.allSatisfy {
                        Glob.matchesASCII(patternLowerBytes: $0,
                                          in: store.nameBytesSlice(of: id))
                    }
                    : terms.allSatisfy {
                        Glob.matches(pattern: $0, in: store.name(of: id), caseInsensitive: false)
                    }
                if matches {
                    result.append(id)
                }
            }
            return result
        }

        var visited = Set<UInt32>()
        var result: [UInt32] = []
        for (offset, componentID) in seedIDs.enumerated() {
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

    private func postingCount(for key: UInt32) -> Int {
        (directory[key]?.idCount ?? 0) + (pendingPostings[key]?.idCount ?? 0)
    }

    private func decodedPosting(for key: UInt32) -> [UInt32] {
        var ids: [UInt32] = []
        ids.reserveCapacity(postingCount(for: key))
        decode(key) { ids.append($0) }
        if let pending = pendingPostings[key] {
            decode(pending.bytes[...], after: directory[key]?.lastID ?? 0) { ids.append($0) }
        }
        return ids
    }

    private func decode(_ key: UInt32, body: (UInt32) -> Void) {
        guard let posting = directory[key] else { return }
        let end = posting.byteOffset + posting.byteCount
        decode(compressedIDs[posting.byteOffset..<end], after: 0, body: body)
    }

    private func decode(_ bytes: ArraySlice<UInt8>, after initial: UInt32,
                        body: (UInt32) -> Void) {
        var offset = bytes.startIndex
        var previous = initial
        while offset < bytes.endIndex {
            var delta: UInt32 = 0
            var shift: UInt32 = 0
            while true {
                let byte = bytes[offset]
                offset += 1
                delta |= UInt32(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            previous &+= delta
            body(previous)
        }
    }

    private static func encode(_ value: UInt32, into bytes: inout [UInt8]) {
        var remainder = value
        repeat {
            var byte = UInt8(remainder & 0x7F)
            remainder >>= 7
            if remainder != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remainder != 0
    }

    private static func encodedLength(_ value: UInt32) -> Int {
        if value < 1 << 7 { return 1 }
        if value < 1 << 14 { return 2 }
        if value < 1 << 21 { return 3 }
        if value < 1 << 28 { return 4 }
        return 5
    }

    private static func encode(_ value: UInt32, into bytes: inout [UInt8],
                               at position: inout Int) {
        var remainder = value
        repeat {
            var byte = UInt8(remainder & 0x7F)
            remainder >>= 7
            if remainder != 0 { byte |= 0x80 }
            bytes[position] = byte
            position += 1
        } while remainder != 0
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
            keys.append(UInt32(a) << 14 | UInt32(b) << 7 | UInt32(c))
        }
        return keys
    }
}
