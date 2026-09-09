public extension QueryEngine {
    enum SortKey: String, Codable, Sendable { case name, path, size, mtime, kind }

    func sort(
        _ ids: [UInt32],
        by key: SortKey,
        ascending: Bool,
        in store: FileStore
    ) -> [UInt32] {
        let ascendingComparator = comparator(for: key, in: store)
        let precedes: (UInt32, UInt32) -> Bool = ascending
            ? ascendingComparator
            : { ascendingComparator($1, $0) }
        return ids.sorted(by: precedes)
    }

    /// Returns a sorted prefix without paying to sort records the caller will discard.
    func sortedPrefix(
        _ ids: [UInt32],
        by key: SortKey,
        ascending: Bool,
        limit: Int,
        in store: FileStore,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [UInt32] {
        let ascendingComparator = comparator(for: key, in: store)
        let precedes: (UInt32, UInt32) -> Bool = ascending
            ? ascendingComparator
            : { ascendingComparator($1, $0) }

        guard ids.count > limit else { return ids.sorted(by: precedes) }

        // A max-heap keeps the worst retained result at the root, producing
        // O(n log limit) work instead of sorting every match.
        func follows(_ lhs: UInt32, _ rhs: UInt32) -> Bool { precedes(rhs, lhs) }
        var heap: [UInt32] = []
        heap.reserveCapacity(limit)

        func siftUp(from start: Int) {
            var index = start
            while index > 0 {
                let parent = (index - 1) / 2
                guard follows(heap[index], heap[parent]) else { break }
                heap.swapAt(index, parent)
                index = parent
            }
        }

        func siftDown(from start: Int) {
            var index = start
            while true {
                let left = 2 * index + 1
                let right = left + 1
                var candidate = index
                if left < heap.count, follows(heap[left], heap[candidate]) { candidate = left }
                if right < heap.count, follows(heap[right], heap[candidate]) { candidate = right }
                guard candidate != index else { break }
                heap.swapAt(index, candidate)
                index = candidate
            }
        }

        for (offset, id) in ids.enumerated() {
            if offset & 0xFFF == 0, isCancelled() { return [] }
            if heap.count < limit {
                heap.append(id)
                siftUp(from: heap.count - 1)
            } else if precedes(id, heap[0]) {
                heap[0] = id
                siftDown(from: 0)
            }
        }
        return heap.sorted(by: precedes)
    }

    private func comparator(
        for key: SortKey,
        in store: FileStore
    ) -> (UInt32, UInt32) -> Bool {
        switch key {
        case .name:
            return { store.nameSortsBefore($0, $1) }
        case .path:
            return {
                store.path(of: $0).localizedStandardCompare(store.path(of: $1)) == .orderedAscending
            }
        case .size:
            return { store.size(of: $0) < store.size(of: $1) }
        case .mtime:
            return { store.mtime(of: $0) < store.mtime(of: $1) }
        case .kind:
            return { store.kindSortsBefore($0, $1) }
        }
    }
}
