import Foundation

// An XPC message can remain queued indefinitely when launchd cannot spawn the
// service. Resolve status probes on a deadline, and ignore any later XPC reply.
final class ServiceReplyWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Result<Data, Error>) -> Void)?

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(result)
    }

    func timeOut(after seconds: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [self] in
            finish(.failure(CocoaError(.xpcConnectionReplyInvalid,
                userInfo: [NSLocalizedDescriptionKey: "Background service did not respond in time"])))
        }
    }
}
