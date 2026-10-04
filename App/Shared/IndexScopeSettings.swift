import Foundation
import IndexCore

struct IndexScopeSettings: Codable, Sendable, Equatable {
    let mode: IndexScope.Mode
    let folders: [String]
}

/// Existing grants stay in the indexer; only newly selected capabilities cross XPC.
struct IndexScopeUpdate: Codable, Sendable {
    let mode: IndexScope.Mode
    let retainedFolders: [String]
    let addedBookmarks: [Data]
}

struct ResolvedIndexAccess: Sendable {
    let revision: UInt64
    let scope: IndexScope
    let settings: IndexScopeSettings
    let issues: [ScanIssue]
}

enum IndexMonitoringState: String, Codable, Sendable { case inactive, starting, live, retrying }

struct IndexCoverage: Codable, Sendable, Equatable {
    let scope: IndexScopeSettings
    let issues: [ScanIssue]
    let monitoring: IndexMonitoringState
}
