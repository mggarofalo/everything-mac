import Foundation

@main
enum EverythingMacCLI {
    static func main() async {
        let result = await CLIRunner(transport: XPCSearchTransport()).run(arguments: Array(CommandLine.arguments.dropFirst()))
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

    func search(_ request: SearchRequest, deadline: Date) async throws -> SearchResponse {
        let payload = try JSONEncoder().encode(request)
        let envelope = try JSONEncoder().encode(ServiceRequest(operation: .search, payload: payload, requestID: UUID()))
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
