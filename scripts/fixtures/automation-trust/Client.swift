import Foundation

@objc private protocol TrustProbeProtocol {
    func ping(_ reply: @escaping (Bool) -> Void)
}

@main private enum SignedTrustClient {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let connection = NSXPCConnection(machServiceName: CommandLine.arguments[1])
        connection.remoteObjectInterface = NSXPCInterface(with: TrustProbeProtocol.self)
        connection.resume()
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var accepted = false
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in semaphore.signal() }
        guard let probe = proxy as? TrustProbeProtocol else { exit(2) }
        probe.ping { result in
            lock.lock(); accepted = result; lock.unlock()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
        connection.invalidate()
        lock.lock(); let result = accepted; lock.unlock()
        exit(result ? 0 : 1)
    }
}
