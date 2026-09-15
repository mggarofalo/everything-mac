import Foundation

private final class SearchService: NSObject, EverythingMacServiceProtocol, @unchecked Sendable {
    private let connectionLock = NSLock()
    private var connection: NSXPCConnection?

    func perform(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        let connection = activeConnection()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            self.discardConnection(connection)
            let failure = ServiceReply.failure("Index service unavailable: \(error.localizedDescription)")
            reply((try? JSONEncoder().encode(failure)) ?? Data())
        }
        guard let service = proxy as? EverythingMacServiceProtocol else {
            let failure = ServiceReply.failure("Index service unavailable")
            reply((try? JSONEncoder().encode(failure)) ?? Data())
            return
        }
        service.perform(request, withReply: reply)
    }

    private func activeConnection() -> NSXPCConnection {
        connectionLock.lock()
        defer { connectionLock.unlock() }
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
    let service = SearchService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ConnectionTrust.accepts(connection, identifiers: [appSigningIdentifier]) else {
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: EverythingMacServiceProtocol.self)
        connection.exportedObject = service
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
