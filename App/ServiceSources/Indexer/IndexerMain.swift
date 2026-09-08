import AppKit
import IndexCore

private final class LatestSearch: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == candidate
    }
}

private final class IndexService: NSObject, EverythingMacServiceProtocol, @unchecked Sendable {
    private let index = IndexActor()
    private let latestSearch = LatestSearch()
    private var generation: UInt64 = 1
    private let startLock = NSLock()
    private var didStart = false
    private var cacheTimer: DispatchSourceTimer?
    private var userFolderTimer: DispatchSourceTimer?

    override init() {
        super.init()
        ensureStarted()
    }

    private func ensureStarted() {
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
            await index.startUp(onLiveChange: changed, onProgress: { _ in },
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

    func perform(_ requestData: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        ensureStarted()
        let request: ServiceRequest
        do {
            request = try JSONDecoder().decode(ServiceRequest.self, from: requestData)
        } catch {
            let failure = ServiceReply.failure(error.localizedDescription)
            reply((try? JSONEncoder().encode(failure)) ?? Data())
            return
        }
        // Cancellation must not wait for the index actor: that actor may be
        // occupied by the CPU-bound regex scan that needs interrupting.
        if request.operation == .cancelSearch {
            _ = latestSearch.begin()
            reply((try? JSONEncoder().encode(ServiceReply.success(true))) ?? Data())
            return
        }
        // Advance this before awaiting the actor. A newer XPC request can then
        // cancel a CPU-bound older search even while the actor is occupied by it.
        let searchGeneration = request.operation == .search ? latestSearch.begin() : nil
        Task {
            let envelope: ServiceReply
            do {
                envelope = try await handle(request, searchGeneration: searchGeneration)
            } catch {
                envelope = .failure(error.localizedDescription)
            }
            reply((try? JSONEncoder().encode(envelope)) ?? Data())
        }
    }

    private func handle(_ request: ServiceRequest, searchGeneration: UInt64?) async throws -> ServiceReply {
        switch request.operation {
        case .status:
            let status = await index.serviceStatus(hasFullDiskAccess: FullDiskAccess.isGranted())
            return .success(status)
        case .search:
            let payload = try requirePayload(request)
            let query = try JSONDecoder().decode(SearchRequest.self, from: payload)
            guard let searchGeneration else { return .failure("Missing search generation") }
            let records = await index.search(query.text, matchPath: query.matchPath,
                                             caseInsensitive: query.caseInsensitive,
                                             wholeWord: query.wholeWord,
                                             usesRegularExpression: query.usesRegularExpression,
                                             sort: sortKey(query.sort), ascending: query.ascending,
                                             limit: min(max(1, query.limit), 10_000),
                                             isCancelled: { [latestSearch] in
                                                 !latestSearch.isCurrent(searchGeneration)
                                             })
            return .success(SearchResponse(records: records))
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

    private func sortKey(_ name: String) -> QueryEngine.SortKey {
        switch name {
        case "path": return .path
        case "size": return .size
        case "mtime": return .mtime
        case "kind": return .kind
        default: return .name
        }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = IndexService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ConnectionTrust.accepts(connection, identifiers: ["EverythingMacSearchService"]) else {
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: EverythingMacServiceProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

@main
enum EverythingMacIndexer {
    static func main() {
        let delegate = ListenerDelegate()
        let listener = NSXPCListener(machServiceName: indexMachServiceName)
        listener.delegate = delegate
        listener.resume()
        RunLoop.main.run()
        _ = delegate
    }
}
