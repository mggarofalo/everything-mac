import Foundation

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let admission = ConnectionAdmission(capacity: 32)
    private let automation = AutomationAccess()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let identifier = ConnectionTrust.validatedIdentifier(
                  connection, identifiers: [appSigningIdentifier, cliSigningIdentifier]),
              let lease = admission.acquire() else {
            return false
        }
        let role: SearchClientRole = identifier == appSigningIdentifier ? .app : .cli
        let service = SearchService(lease: lease, role: role, automation: automation)
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
