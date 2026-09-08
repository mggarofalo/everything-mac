import Foundation

private final class SearchService: NSObject, EverythingMacServiceProtocol, @unchecked Sendable {
    private let connection: NSXPCConnection

    override init() {
        connection = NSXPCConnection(machServiceName: indexMachServiceName, options: [])
        super.init()
        connection.remoteObjectInterface = NSXPCInterface(with: EverythingMacServiceProtocol.self)
        connection.resume()
    }

    func perform(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
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
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = SearchService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ConnectionTrust.accepts(connection, identifiers: ["com.everythingmac.app"]) else {
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
