import Foundation
import Dispatch
import Darwin

@main
enum EverythingMacCLI {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let task = Task { await CLIRunner(transport: XPCSearchTransport()).run(arguments: Array(CommandLine.arguments.dropFirst())) }
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        interruption.setEventHandler { task.cancel() }
        termination.setEventHandler { task.cancel() }
        interruption.resume()
        termination.resume()
        let result = await task.value
        interruption.cancel()
        termination.cancel()
        FileHandle.standardOutput.write(result.stdout)
        FileHandle.standardError.write(result.stderr)
        exit(result.exitCode)
    }
}

final class XPCSearchTransport: NSObject, CLISearchTransport, @unchecked Sendable {
    private let connection: NSXPCConnection

    override init() {
        connection = NSXPCConnection(machServiceName: searchMachServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: EverythingMacServiceProtocol.self)
        super.init()
        connection.resume()
    }

    deinit { connection.invalidate() }

    func search(_ request: SearchRequest, requestID: UUID, deadline: Date) async throws -> SearchResponse {
        let payload = try JSONEncoder().encode(request)
        let envelope = try JSONEncoder().encode(ServiceRequest(operation: .search, payload: payload, requestID: requestID))
        let reply: Data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in continuation.resume(throwing: error) }
            guard let service = proxy as? EverythingMacServiceProtocol else {
                continuation.resume(throwing: CLIError.unavailable("Search service is unavailable; open EverythingMac to complete setup."))
                return
            }
            service.perform(envelope) { data in continuation.resume(returning: data) }
        }
        let decoded = try JSONDecoder().decode(ServiceReply.self, from: reply)
        if let error = decoded.error {
            if decoded.errorCode == ServiceErrorCode.permissionDenied || decoded.errorCode == ServiceErrorCode.indexNotReady ||
                decoded.errorCode == ServiceErrorCode.serviceUnavailable || decoded.errorCode == ServiceErrorCode.overloaded {
                throw CLIError.unavailable(error)
            }
            if decoded.errorCode == ServiceErrorCode.invalidQuery { throw CLIError.invalidArguments(error) }
            throw CLIError.internalError(error)
        }
        guard let payload = decoded.payload else { throw CLIError.internalError("Empty service response.") }
        return try JSONDecoder().decode(SearchResponse.self, from: payload)
    }

    func cancel(_ requestID: UUID) async {
        guard let payload = try? JSONEncoder().encode(ServiceRequest(operation: .cancelSearch, payload: nil, requestID: requestID)),
              let service = connection.remoteObjectProxy as? EverythingMacServiceProtocol else { return }
        service.perform(payload) { _ in }
    }
}
