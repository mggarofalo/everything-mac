import AppKit
import IndexCore

private final class IndexService: @unchecked Sendable {
    private let index = IndexActor()
    let admission = SearchAdmission()
    private var generation: UInt64 = 1
    private let startLock = NSLock()
    private var didStart = false
    private var cacheTimer: DispatchSourceTimer?
    private var userFolderTimer: DispatchSourceTimer?

    init() {
        ensureStarted()
    }

    fileprivate func ensureStarted() {
        guard FullDiskAccess.isGranted() else { return }
        startLock.lock()
        guard !didStart else { startLock.unlock(); return }
        didStart = true
        startLock.unlock()
        let generation = generation
        Task {
            let changed: @Sendable () -> Void = {
                DistributedNotificationCenter.default().post(name: indexChangedNotification,
                                                             object: nil)
            }
            let progressed: @Sendable (Int) -> Void = { count in
                DistributedNotificationCenter.default().post(
                    name: indexProgressNotification,
                    object: String(count)
                )
            }
            await index.startUp(onLiveChange: changed, onProgress: progressed,
                                accessGeneration: generation)
            installMaintenanceTimers(generation: generation)
            changed()
        }
    }

    private func installMaintenanceTimers(generation: UInt64) {
        let cache = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        cache.schedule(deadline: .now() + .seconds(600), repeating: .seconds(600))
        cache.setEventHandler { [index] in Task { await index.flush(accessGeneration: generation) } }
        cache.resume()
        cacheTimer = cache

        let folders = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        folders.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        folders.setEventHandler { [index] in Task { await index.sweepUserFolders() } }
        folders.resume()
        userFolderTimer = folders
    }

    func handle(_ request: ServiceRequest, token: SearchCancellationToken?) async throws -> ServiceReply {
        switch request.operation {
        case .status:
            let status = await index.serviceStatus(hasFullDiskAccess: FullDiskAccess.isGranted())
            return .success(status)
        case .search:
            guard FullDiskAccess.isGranted() else {
                return .failure(ServiceErrorCode.permissionDenied.message, code: .permissionDenied)
            }
            let payload = try requirePayload(request)
            let query = try JSONDecoder().decode(SearchRequest.self, from: payload)
            guard let token else { return .failure("Missing search token") }
            guard !token.isCancelled else { throw ServiceErrorCode.cancelled }
            guard (1...10_000).contains(query.limit) else {
                return .failure("Limit must be between 1 and 10000.", code: .invalidQuery)
            }
            let response = try await index.searchResponse(
                query.text, matchPath: query.matchPath,
                caseInsensitive: query.caseInsensitive, wholeWord: query.wholeWord,
                usesRegularExpression: query.usesRegularExpression,
                sort: query.sort, ascending: query.ascending, limit: query.limit,
                interactive: query.supersedeExisting == true,
                isCancelled: { token.isCancelled }
            )
            return .success(response)
        case .cancelSearch:
            // Handled synchronously by perform(), before creating this task.
            return .success(true)
        case .rebuild:
            await index.rescanAll(accessGeneration: generation)
            await index.flush(accessGeneration: generation)
            return .success(true)
        case .getRules:
            return .success(await index.currentRules())
        case .setRules:
            let payload = try requirePayload(request)
            let rules = try JSONDecoder().decode(ExcludeRules.self, from: payload)
            await index.setRules(rules, accessGeneration: generation)
            await index.rescanAll(accessGeneration: generation)
            await index.flush(accessGeneration: generation)
            return .success(true)
        }
    }

    private func requirePayload(_ request: ServiceRequest) throws -> Data {
        guard let payload = request.payload else {
            throw NSError(domain: "EverythingMac", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing service request payload"])
        }
        return payload
    }

}

private final class IndexSession: NSObject, EverythingMacServiceProtocol, @unchecked Sendable {
    private struct PendingSearch: Sendable {
        let request: ServiceRequest
        let reply: @Sendable (Data) -> Void
    }

    private let service: IndexService
    private let state = SearchSessionState<PendingSearch>()
    private let lease: ConnectionLease
    private var observerID: UUID?

    init(service: IndexService, lease: ConnectionLease) {
        self.service = service
        self.lease = lease
        super.init()
        observerID = service.admission.observe { [weak self] in self?.drainPending() }
    }

    func close() {
        let abandoned = state.close()
        service.admission.removeObserver(observerID)
        lease.close()
        if let abandoned { send(.failure(ServiceErrorCode.cancelled.message, code: .cancelled),
                                to: abandoned.reply) }
    }

    func perform(_ data: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        guard !state.isClosed else {
            send(.failure("Index session closed", code: .serviceUnavailable), to: reply)
            return
        }
        service.ensureStarted()
        guard let request = try? JSONDecoder().decode(ServiceRequest.self, from: data) else {
            send(.failure("Invalid service request"), to: reply)
            return
        }
        if request.operation == .cancelSearch {
            if let cancelled = state.cancel(request.requestID) {
                send(.failure(ServiceErrorCode.cancelled.message, code: .cancelled),
                     to: cancelled.reply)
            }
            send(.success(true), to: reply)
            return
        }
        let id = request.requestID ?? UUID()
        let interactive = (try? request.payload.flatMap {
            try JSONDecoder().decode(SearchRequest.self, from: $0)
        })?.supersedeExisting == true
        if request.operation == .search {
            if interactive {
                queueInteractive(request, id: id, reply: reply)
                return
            }
            guard service.admission.acquire(interactive: interactive) else {
                send(.failure(ServiceErrorCode.overloaded.message, code: .overloaded), to: reply)
                return
            }
            guard let token = state.beginIndependent(id) else {
                service.admission.release(interactive: interactive)
                send(.failure(ServiceErrorCode.overloaded.message, code: .overloaded), to: reply)
                return
            }
            run(request, id: id, token: token, interactive: false, reply: reply)
            return
        }
        run(request, id: id, token: nil, interactive: false, reply: reply)
    }

    private func queueInteractive(_ request: ServiceRequest, id: UUID,
                                  reply: @escaping @Sendable (Data) -> Void) {
        switch state.offer(PendingSearch(request: request, reply: reply), id: id) {
        case .closed:
            send(.failure("Index session closed", code: .serviceUnavailable), to: reply)
        case .duplicate:
            send(.failure("Duplicate search request ID", code: .invalidQuery), to: reply)
        case .accepted(let replaced):
            if let replaced {
                send(.failure(ServiceErrorCode.cancelled.message, code: .cancelled),
                     to: replaced.reply)
            }
            drainPending()
        }
    }

    private func drainPending() {
        guard let next = state.takeReady(
            acquire: { service.admission.acquire(interactive: true) },
            releaseWithoutNotification: {
                service.admission.release(interactive: true, notify: false)
            }
        ) else { return }
        run(next.work.request, id: next.id, token: next.token,
            interactive: true, reply: next.work.reply)
    }

    private func run(_ request: ServiceRequest, id: UUID, token: SearchCancellationToken?,
                     interactive: Bool, reply: @escaping @Sendable (Data) -> Void) {
        Task {
            var envelope: ServiceReply
            do {
                envelope = try await service.handle(request, token: token)
            } catch let error as ServiceErrorCode {
                envelope = .failure(error.message, code: error)
            } catch {
                envelope = .failure(error.localizedDescription)
            }
            if token?.isCancelled == true {
                envelope = .failure(ServiceErrorCode.cancelled.message, code: .cancelled)
            }
            if request.operation == .search {
                state.finish(id)
                service.admission.release(interactive: interactive)
            }
            send(envelope, to: reply)
        }
    }

    private func send(_ value: ServiceReply, to reply: @escaping @Sendable (Data) -> Void) {
        reply((try? JSONEncoder().encode(value)) ?? Data())
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = IndexService()
    private let admission = ConnectionAdmission(capacity: 32)

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ConnectionTrust.accepts(connection, identifiers: [searchServiceSigningIdentifier]),
              let lease = admission.acquire() else {
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: EverythingMacServiceProtocol.self)
        let session = IndexSession(service: service, lease: lease)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak session] in session?.close() }
        connection.interruptionHandler = { [weak session] in session?.close() }
        connection.resume()
        return true
    }
}

@main
enum EverythingMacIndexingService {
    static func main() {
        if ApplicationBundleMonitor.runObserverIfRequested() { return }
        ApplicationBundleMonitor.launchObserver()
        let delegate = ListenerDelegate()
        let listener = NSXPCListener(machServiceName: indexMachServiceName)
        listener.delegate = delegate
        listener.resume()
        RunLoop.main.run()
        _ = delegate
    }
}
