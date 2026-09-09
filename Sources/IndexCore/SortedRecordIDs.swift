/// Set operations over unique record IDs that are already in ascending order.
enum SortedRecordIDs {
    static func union(
        _ left: [UInt32],
        _ right: [UInt32],
        isCancelled: @Sendable () -> Bool
    ) -> [UInt32] {
        combine(left, right, includeEqual: true, isCancelled: isCancelled)
    }

    static func symmetricDifference(
        _ left: [UInt32],
        _ right: [UInt32],
        isCancelled: @Sendable () -> Bool
    ) -> [UInt32] {
        combine(left, right, includeEqual: false, isCancelled: isCancelled)
    }

    private static func combine(
        _ left: [UInt32],
        _ right: [UInt32],
        includeEqual: Bool,
        isCancelled: @Sendable () -> Bool
    ) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(left.count + right.count)
        var leftIndex = 0
        var rightIndex = 0

        while leftIndex < left.count || rightIndex < right.count {
            if (leftIndex + rightIndex) & 0xFFF == 0, isCancelled() { return [] }
            if rightIndex == right.count ||
                (leftIndex < left.count && left[leftIndex] < right[rightIndex]) {
                result.append(left[leftIndex])
                leftIndex += 1
            } else if leftIndex == left.count || right[rightIndex] < left[leftIndex] {
                result.append(right[rightIndex])
                rightIndex += 1
            } else {
                if includeEqual { result.append(left[leftIndex]) }
                leftIndex += 1
                rightIndex += 1
            }
        }
        return result
    }
}
