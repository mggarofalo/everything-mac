import AppIntents
import Foundation
import SwiftUI

enum SearchURLParseError: LocalizedError, Equatable {
    case invalidURL
    case invalidRoute
    case invalidQuery
    case invalidEncoding
    case invalidSearchQuery(SearchPresentationError)

    var errorDescription: String? {
        switch self {
        case .invalidURL, .invalidRoute, .invalidQuery, .invalidEncoding:
            "This is not a valid EverythingMac search URL."
        case let .invalidSearchQuery(error): error.errorDescription
        }
    }
}

enum SearchURLParser {
    static func query(from url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SearchURLParseError.invalidURL
        }
        guard components.scheme?.caseInsensitiveCompare("everythingmac") == .orderedSame,
              components.host?.caseInsensitiveCompare("search") == .orderedSame,
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw SearchURLParseError.invalidRoute
        }
        guard let encodedQuery = components.percentEncodedQuery else {
            throw SearchURLParseError.invalidQuery
        }
        let parameters = encodedQuery.split(separator: "&", omittingEmptySubsequences: false)
        guard parameters.count == 1,
              let separator = parameters[0].firstIndex(of: "="),
              parameters[0][..<separator] == "q" else {
            throw SearchURLParseError.invalidQuery
        }
        let encodedValue = String(parameters[0][parameters[0].index(after: separator)...])
        guard hasValidPercentEncoding(encodedValue),
              let query = encodedValue.removingPercentEncoding else {
            throw SearchURLParseError.invalidEncoding
        }
        do {
            try SearchPresentationCoordinator.validate(query: query)
            return query
        } catch let error as SearchPresentationError {
            throw SearchURLParseError.invalidSearchQuery(error)
        }
    }

    private static func hasValidPercentEncoding(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        for index in bytes.indices where bytes[index] == 37 {
            guard index + 2 < bytes.endIndex,
                  isHexadecimal(bytes[index + 1]), isHexadecimal(bytes[index + 2]) else {
                return false
            }
        }
        return true
    }

    private static func isHexadecimal(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}

/// Holds an adapter request only until the app creates its shared coordinator.
@MainActor
final class SearchPresentationHost: ObservableObject {
    static let shared = SearchPresentationHost()

    @Published private(set) var urlErrorMessage: String?
    private var coordinator: SearchPresentationCoordinator?
    private(set) var pendingRequest: SearchPresentationRequest?

    func install(_ coordinator: SearchPresentationCoordinator) {
        self.coordinator = coordinator
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        forward(request, to: coordinator)
    }

    func runQuery(_ query: String) throws {
        try SearchPresentationCoordinator.validate(query: query)
        urlErrorMessage = nil
        handoff(.runQuery(query))
    }

    func handle(url: URL) {
        do {
            try runQuery(SearchURLParser.query(from: url))
        } catch let error as SearchURLParseError {
            urlErrorMessage = error.errorDescription
            coordinator?.showCurrentSearch()
        } catch let error as SearchPresentationError {
            urlErrorMessage = error.errorDescription
            coordinator?.showCurrentSearch()
        } catch {
            urlErrorMessage = SearchURLParseError.invalidURL.errorDescription
            coordinator?.showCurrentSearch()
        }
    }

    func dismissURLError() {
        urlErrorMessage = nil
    }

    private func handoff(_ request: SearchPresentationRequest) {
        guard let coordinator else {
            pendingRequest = request
            return
        }
        forward(request, to: coordinator)
    }

    private func forward(_ request: SearchPresentationRequest,
                         to coordinator: SearchPresentationCoordinator) {
        switch request {
        case .showCurrentSearch: coordinator.showCurrentSearch()
        case let .runQuery(query): try? coordinator.runQuery(query)
        }
    }
}

struct SearchEverythingMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Search EverythingMac"
    static let description = IntentDescription("Search files and folders in EverythingMac.")
    static let openAppWhenRun = true

    @Parameter(title: "Query", requestValueDialog: "What do you want to search for?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search \(\.$query)")
    }

    init() {}

    init(query: String) {
        self.query = query
    }

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            try SearchPresentationHost.shared.runQuery(query)
        }
        return .result()
    }
}

struct EverythingMacShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchEverythingMacIntent(),
            phrases: ["Search in \(.applicationName)"],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
    }
}
