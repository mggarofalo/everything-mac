import Foundation

/// Launch-agent names shared by registration, removal, and package upgrades.
enum BackgroundServiceCatalog {
    static let current = ["com.everythingmac.indexing-agent", "com.everythingmac.search"]
    static let retired = ["com.everythingmac.indexer", "com.everythingmac.indexing-service"]
    static var all: [String] { current + retired }
}
