import Foundation
import IndexCore

actor SearchClient {
    private var connection: NSXPCConnection?
    private var onLiveChange: (@Sendable () -> Void)?
    private var onProgress: (@Sendable (Int) -> Void)?
    private nonisolated(unsafe) var notificationToken: NSObjectProtocol?

    init() {
        notificationToken = DistributedNotificationCenter.default().addObserver(
            forName: indexChangedNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.indexChanged() }
        }
    }

    func startUp(onLiveChange: @escaping @Sendable () -> Void,
                 onProgress: @escaping @Sendable (Int) -> Void,
                 accessGeneration: UInt64) async {
        self.onLiveChange = onLiveChange
        self.onProgress = onProgress
        _ = accessGeneration
    }

    var totalCount: Int {
        get async { (try? await status().totalCount) ?? 0 }
    }

    func serviceHasFullDiskAccess() async -> Bool {
        (try? await status().hasFullDiskAccess) ?? false
    }

    func currentStatus() async -> ServiceStatus? { try? await status() }

    func currentRules() async -> ExcludeRules {
        (try? await call(.getRules, payload: Optional<Bool>.none, as: ExcludeRules.self)) ?? .defaults
    }

    func search(_ text: String, matchPath: Bool, caseInsensitive: Bool = true,
                wholeWord: Bool = false, sort: QueryEngine.SortKey,
                ascending: Bool, limit: Int = 5000) async -> [FileRecord] {
        let request = SearchRequest(text: text, matchPath: matchPath,
                                    caseInsensitive: caseInsensitive, wholeWord: wholeWord,
                                    sort: sortKeyName(sort), ascending: ascending,
                                    limit: limit)
        return (try? await call(.search, payload: request, as: SearchResponse.self).records) ?? []
    }

    func rescanAll(accessGeneration: UInt64? = nil) async {
        _ = accessGeneration
        _ = try? await call(.rebuild, payload: Optional<Bool>.none, as: Bool.self)
    }

    func setRules(_ rules: ExcludeRules, accessGeneration: UInt64? = nil) async {
        _ = accessGeneration
        _ = try? await call(.setRules, payload: rules, as: Bool.self)
    }

    func flush(accessGeneration: UInt64? = nil) async { _ = accessGeneration }
    func sweepUserFolders() async {}
    func invalidateForAccessRevocation(generation: UInt64) async { _ = generation }

    private func status() async throws -> ServiceStatus {
        try await call(.status, payload: Optional<Bool>.none, as: ServiceStatus.self)
    }

    private func sortKeyName(_ key: QueryEngine.SortKey) -> String {
        switch key {
        case .name: return "name"
        case .path: return "path"
        case .size: return "size"
        case .mtime: return "mtime"
        case .kind: return "kind"
        }
    }

    private func indexChanged() async {
        guard let status = try? await status() else { return }
        if status.scanning { onProgress?(status.totalCount) }
        onLiveChange?()
    }

    private func call<P: Encodable, R: Decodable>(_ operation: ServiceOperation,
                                                   payload: P?, as type: R.Type) async throws -> R {
        let payloadData = try payload.map { try JSONEncoder().encode($0) }
        let request = try JSONEncoder().encode(ServiceRequest(operation: operation, payload: payloadData))
        // The app delegate registers the launch agents during application launch.
        // Connect only when the first request is made so a brand-new installation
        // cannot permanently capture an unavailable service before registration.
        let connection = activeConnection()
        let replyData: Data = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            }
            guard let service = proxy as? EverythingMacServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "EverythingMac", code: 2,
                                                       userInfo: [NSLocalizedDescriptionKey: "Search service unavailable"]))
                return
            }
            service.perform(request) { continuation.resume(returning: $0) }
        }
        let envelope = try JSONDecoder().decode(ServiceReply.self, from: replyData)
        if let error = envelope.error {
            throw NSError(domain: "EverythingMac", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: error])
        }
        guard let payload = envelope.payload else {
            throw NSError(domain: "EverythingMac", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Empty service response"])
        }
        return try JSONDecoder().decode(type, from: payload)
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let newConnection = NSXPCConnection(machServiceName: searchMachServiceName, options: [])
        newConnection.remoteObjectInterface = NSXPCInterface(with: EverythingMacServiceProtocol.self)
        newConnection.resume()
        connection = newConnection
        return newConnection
    }
}
