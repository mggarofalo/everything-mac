import Foundation

@objc private protocol TrustProbeProtocol {
    func ping(_ reply: @escaping (Bool) -> Void)
}

private final class TrustProbe: NSObject, TrustProbeProtocol {
    func ping(_ reply: @escaping (Bool) -> Void) { reply(true) }
}

private final class TrustDelegate: NSObject, NSXPCListenerDelegate {
    private let identifiers: Set<String>
    private let probe = TrustProbe()

    init(indexer: Bool) {
        identifiers = indexer ? ["EverythingMacSearchService"]
                              : ["com.everythingmac.app", "com.everythingmac.cli"]
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ConnectionTrust.accepts(connection, identifiers: identifiers) else { return false }
        connection.exportedInterface = NSXPCInterface(with: TrustProbeProtocol.self)
        connection.exportedObject = probe
        connection.resume()
        return true
    }
}

@main private enum SignedTrustListener {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { exit(2) }
        let delegate = TrustDelegate(indexer: arguments[2] == "indexer")
        let listener = NSXPCListener(machServiceName: arguments[1])
        listener.delegate = delegate
        listener.resume()
        RunLoop.main.run()
        _ = delegate
    }
}
