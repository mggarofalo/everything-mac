import Foundation
import IndexCore

let indexMachServiceName = "com.everythingmac.indexer"
let searchMachServiceName = "com.everythingmac.search"
let indexChangedNotification = Notification.Name("com.everythingmac.index-changed")

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

    static func success<T: Encodable>(_ value: T) -> ServiceReply {
        ServiceReply(payload: try? JSONEncoder().encode(value), error: nil)
    }

    static func failure(_ message: String) -> ServiceReply {
        ServiceReply(payload: nil, error: message)
    }
}

struct ServiceStatus: Codable, Sendable {
    let totalCount: Int
    let revision: UInt64
    let scanning: Bool
    let hasFullDiskAccess: Bool
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
}

enum ServicePaths {
    static func cacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Everything-Mac", isDirectory: true)
        return base.appendingPathComponent("index.idx")
    }
}
