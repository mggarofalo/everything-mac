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

    var message: String {
        switch self {
        case .invalidQuery: "Invalid query."
        case .permissionDenied: "Full Disk Access is required."
        case .indexNotReady: "The index is not ready."
        case .cancelled: "Search was cancelled."
        case .internalError: "Internal service error."
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
