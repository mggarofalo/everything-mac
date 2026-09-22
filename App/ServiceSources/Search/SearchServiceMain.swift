import Foundation

private final class SearchService: NSObject, EverythingMacServiceProtocol, @unchecked Sendable {
    private let connectionLock = NSLock()
    private var connection: NSXPCConnection?
    private var closed = false
    private let lease: ConnectionLease
    private let interactive: Bool

    init(lease: ConnectionLease, interactive: Bool) {
        self.lease = lease
        self.interactive = interactive
    }

    func perform(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        let once = ReplyOnce()
        let forwarded: Data
        do {
            forwarded = try trustedRequest(request)
        } catch {
            Self.send(.failure("Invalid service request", code: .invalidQuery), once: once, to: reply)
            return
        }
        guard let connection = activeConnection() else {
            Self.send(.failure("Search session closed", code: .serviceUnavailable), once: once, to: reply)
            return
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.discardConnection(connection)
            let failure = ServiceReply.failure("Index service unavailable: \(error.localizedDescription)",
                                               code: .serviceUnavailable)
            Self.send(failure, once: once, to: reply)
        }
        guard let service = proxy as? EverythingMacServiceProtocol else {
            let failure = ServiceReply.failure("Index service unavailable", code: .serviceUnavailable)
            Self.send(failure, once: once, to: reply)
            return
        }
        service.perform(forwarded) { data in once.deliver(data, to: reply) }
    }

    private func trustedRequest(_ data: Data) throws -> Data {
        let request = try JSONDecoder().decode(ServiceRequest.self, from: data)
        return try JSONEncoder().encode(request.trustedForwarding(interactive: interactive))
    }

    func close() {
        connectionLock.lock()
        closed = true
        let oldConnection = connection
        connection = nil
        connectionLock.unlock()
        oldConnection?.invalidate()
        lease.close()
    }

    private static func send(_ value: ServiceReply, once: ReplyOnce,
                             to reply: @escaping @Sendable (Data) -> Void) {
        once.deliver((try? JSONEncoder().encode(value)) ?? Data(), to: reply)
    }

    private func activeConnection() -> NSXPCConnection? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard !closed else { return nil }
        if let connection { return connection }
        let newConnection = NSXPCConnection(machServiceName: indexMachServiceName, options: [])
        newConnection.remoteObjectInterface = NSXPCInterface(with: EverythingMacServiceProtocol.self)
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func discardConnection(_ candidate: NSXPCConnection) {
        connectionLock.lock()
        guard connection === candidate else {
            connectionLock.unlock()
            return
        }
        connection = nil
        connectionLock.unlock()
        candidate.invalidate()
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let admission = ConnectionAdmission(capacity: 32)

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let identifier = ConnectionTrust.validatedIdentifier(
                  connection, identifiers: [appSigningIdentifier]),
              let lease = admission.acquire() else {
            return false
        }
        let service = SearchService(lease: lease, interactive: identifier == appSigningIdentifier)
        connection.exportedInterface = NSXPCInterface(with: EverythingMacServiceProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { [weak service] in service?.close() }
        connection.interruptionHandler = { [weak service] in service?.close() }
        connection.resume()
        return true
    }
}

@main
enum EverythingMacSearchService {
    static func main() {
        let delegate = ListenerDelegate()
        let listener = NSXPCListener(machServiceName: searchMachServiceName)
        listener.delegate = delegate
        listener.resume()
        RunLoop.main.run()
        _ = delegate
    }
}
