import Foundation
import IndexCore

let indexMachServiceName = "com.everythingmac.indexer"
let searchMachServiceName = "com.everythingmac.search"
let appSigningIdentifier = "com.everythingmac.app"
let indexingServiceSigningIdentifier = appSigningIdentifier
let searchServiceSigningIdentifier = "EverythingMacSearchService"
let indexChangedNotification = Notification.Name("com.everythingmac.index-changed")
let indexProgressNotification = Notification.Name("com.everythingmac.index-progress")

@objc protocol EverythingMacServiceProtocol {
    func perform(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}

enum ServiceOperation: String, Codable, Sendable {
    case status
    case search
    case cancelSearch
    case rebuild
    case getRules
    case setRules
}

struct ServiceRequest: Codable, Sendable {
    let operation: ServiceOperation
    let payload: Data?
    let requestID: UUID?

    init(operation: ServiceOperation, payload: Data?, requestID: UUID? = nil) {
        self.operation = operation
        self.payload = payload
        self.requestID = requestID
    }

    func trustedForwarding(interactive: Bool) throws -> ServiceRequest {
        guard operation == .search, let payload else { return self }
        let query = try JSONDecoder().decode(SearchRequest.self, from: payload)
        let trusted = SearchRequest(text: query.text, matchPath: query.matchPath,
                                    caseInsensitive: query.caseInsensitive, wholeWord: query.wholeWord,
                                    usesRegularExpression: query.usesRegularExpression,
                                    sort: query.sort, ascending: query.ascending,
                                    limit: query.limit, supersedeExisting: interactive)
        return ServiceRequest(operation: .search, payload: try JSONEncoder().encode(trusted),
                              requestID: requestID ?? UUID())
    }
}

struct ServiceReply: Codable, Sendable {
    let payload: Data?
    let error: String?
    let errorCode: ServiceErrorCode?

    static func success<T: Encodable>(_ value: T) -> ServiceReply {
        ServiceReply(payload: try? JSONEncoder().encode(value), error: nil, errorCode: nil)
    }

    static func failure(_ message: String, code: ServiceErrorCode = .internalError) -> ServiceReply {
        ServiceReply(payload: nil, error: message, errorCode: code)
    }
}

enum ServiceErrorCode: String, Codable, Sendable, Error {
    case invalidQuery
    case permissionDenied
    case indexNotReady
    case cancelled
    case internalError
    case overloaded
    case serviceUnavailable

    var message: String {
        switch self {
        case .invalidQuery: "Invalid query."
        case .permissionDenied: "Full Disk Access is required."
        case .indexNotReady: "The index is not ready."
        case .cancelled: "Search was cancelled."
        case .internalError: "Internal service error."
        case .overloaded: "Too many searches are in progress."
        case .serviceUnavailable: "Search service is unavailable."
        }
    }
}

struct ServiceStatus: Codable, Sendable {
    let totalCount: Int
    let revision: UInt64
    let scanning: Bool
    let hasFullDiskAccess: Bool
    let ready: Bool

    init(totalCount: Int, revision: UInt64, scanning: Bool,
         hasFullDiskAccess: Bool, ready: Bool = false) {
        self.totalCount = totalCount
        self.revision = revision
        self.scanning = scanning
        self.hasFullDiskAccess = hasFullDiskAccess
        self.ready = ready
    }
}

struct SearchRequest: Codable, Sendable {
    let text: String
    let matchPath: Bool
    let caseInsensitive: Bool
    let wholeWord: Bool
    let usesRegularExpression: Bool
    let sort: QueryEngine.SortKey
    let ascending: Bool
    let limit: Int
    let supersedeExisting: Bool?

    init(text: String, matchPath: Bool, caseInsensitive: Bool, wholeWord: Bool,
         usesRegularExpression: Bool, sort: QueryEngine.SortKey, ascending: Bool,
         limit: Int, supersedeExisting: Bool? = nil) {
        self.text = text
        self.matchPath = matchPath
        self.caseInsensitive = caseInsensitive
        self.wholeWord = wholeWord
        self.usesRegularExpression = usesRegularExpression
        self.sort = sort
        self.ascending = ascending
        self.limit = limit
        self.supersedeExisting = supersedeExisting
    }
}

final class SearchCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Owned by one accepted XPC connection. IDs are only meaningful within that connection.
final class SearchSessionRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [UUID: SearchCancellationToken] = [:]
    private var closed = false
    private let capacity: Int

    init(capacity: Int = 8) { self.capacity = capacity }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func begin(_ id: UUID, supersede: Bool) -> SearchCancellationToken? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, active[id] == nil, active.count < capacity else { return nil }
        if supersede { active.values.forEach { $0.cancel() } }
        let token = SearchCancellationToken()
        active[id] = token
        return token
    }

    func cancel(_ id: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        if let id { active[id]?.cancel() }
        else { active.values.forEach { $0.cancel() } }
    }

    func finish(_ id: UUID) {
        lock.lock()
        active.removeValue(forKey: id)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        active.values.forEach { $0.cancel() }
        active.removeAll()
        lock.unlock()
    }
}

final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didReply = false

    func deliver(_ data: Data, to reply: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        let shouldReply = !didReply
        didReply = true
        lock.unlock()
        if shouldReply { reply(data) }
    }
}

final class DataContinuationOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Data, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

final class ConnectionAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var active = 0

    init(capacity: Int) { self.capacity = capacity }

    func acquire() -> ConnectionLease? {
        lock.lock()
        defer { lock.unlock() }
        guard active < capacity else { return nil }
        active += 1
        return ConnectionLease(owner: self)
    }

    fileprivate func release() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}

final class ConnectionLease: @unchecked Sendable {
    private let owner: ConnectionAdmission
    private let lock = NSLock()
    private var released = false

    fileprivate init(owner: ConnectionAdmission) { self.owner = owner }

    func close() {
        lock.lock()
        let shouldRelease = !released
        released = true
        lock.unlock()
        if shouldRelease { owner.release() }
    }

    deinit { close() }
}

struct SearchResponse: Codable, Sendable {
    let records: [FileRecord]
    let limit: Int
    let truncated: Bool
    let scanning: Bool

    init(records: [FileRecord], limit: Int = 0, truncated: Bool = false,
         scanning: Bool = false) {
        self.records = records
        self.limit = limit
        self.truncated = truncated
        self.scanning = scanning
    }
}

enum ServicePaths {
    static var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EverythingMac", isDirectory: true)
    }

    /// The storage namespace used through 0.9.0. Keep this solely for migrating
    /// existing indexes and removing legacy data during uninstall.
    static var legacyApplicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Everything-Mac", isDirectory: true)
    }

    static func cacheURL() -> URL {
        applicationSupportURL.appendingPathComponent("index.idx")
    }
}
