import Foundation

/// Collects synchronous parallel scan results while preserving chunk order.
/// Every access to `chunks` is protected by `lock`, which makes the unchecked
/// sendability boundary local to this type.
final class ParallelSearchResults: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [[UInt32]]

    init(chunkCount: Int) {
        chunks = [[UInt32]](repeating: [], count: chunkCount)
    }

    func store(_ ids: [UInt32], forChunk index: Int) {
        lock.withLock {
            chunks[index] = ids
        }
    }

    func joined() -> [UInt32] {
        lock.withLock {
            chunks.flatMap { $0 }
        }
    }
}
