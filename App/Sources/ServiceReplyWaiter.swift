import Foundation

enum ServiceReplyTimeout: Error {
    case elapsed
}

// An XPC message can remain queued indefinitely when launchd cannot spawn the
// service. A deadline can start a health probe or finish an unanswered ping;
// whichever result completes the request first owns its continuation.
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
        onDeadline(after: seconds) { [self] in
            finish(.failure(ServiceReplyTimeout.elapsed))
        }
    }

    func onDeadline(after seconds: TimeInterval, perform action: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [self] in
            lock.lock()
            let isPending = completion != nil
            lock.unlock()
            if isPending { action() }
        }
    }
}
