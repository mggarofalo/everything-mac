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
        let outputStatus = write(result.stdout, to: STDOUT_FILENO)
        let errorStatus = write(result.stderr, to: STDERR_FILENO)
        exit(outputStatus == 0 && errorStatus == 0 ? result.exitCode : 5)
    }

    private static func write(_ data: Data, to descriptor: Int32) -> Int32 {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if errno == EINTR { continue }
                if errno == EPIPE { return 0 }
                return 5
            }
            return 0
        }
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
        let reply = CLIReplyContinuation()
        let data: Data
        do {
            data = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                reply.install(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in reply.complete(.failure(error)) }
            guard let service = proxy as? EverythingMacServiceProtocol else {
                reply.complete(.failure(CLIError.unavailable("Search service is unavailable; open EverythingMac to complete setup.")))
                return
            }
                service.perform(envelope) { data in reply.complete(.success(data)) }
            }
            }, onCancel: {
            reply.complete(.failure(CancellationError()))
            Task { await self.cancel(requestID) }
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CLIError.unavailable("Search service is unavailable; open EverythingMac to complete setup.")
        }
        let decoded = try JSONDecoder().decode(ServiceReply.self, from: data)
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

private final class CLIReplyContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?

    func install(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func complete(_ result: Result<Data, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
