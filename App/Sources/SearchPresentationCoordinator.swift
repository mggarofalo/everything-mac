import AppKit
import IndexCore

/// A request from an adapter that wants the search window shown or a query run.
/// Empty text is intentionally not used to represent `showCurrentSearch`.
enum SearchPresentationRequest: Equatable {
    case showCurrentSearch
    case runQuery(String)
}

enum SearchPresentationError: LocalizedError, Equatable {
    case emptyQuery
    case containsNUL
    case queryTooLong

    var errorDescription: String? {
        switch self {
        case .emptyQuery: "A search query cannot be blank."
        case .containsNUL: "A search query cannot contain a NUL character."
        case .queryTooLong: "A search query must be at most 16 KiB."
        }
    }
}

/// The values used for a supplied query. They are deliberately not persisted.
struct PresentedSearchDefaults: Equatable {
    let sortKey: QueryEngine.SortKey = .name
    let ascending = true
    let matchPath = false
    let caseSensitive = false
    let wholeWord = false
    let usesRegularExpression = false
    let resultLimit = 5_000
}

/// Latest-wins request storage, kept separate so delivery behavior is testable without AppKit.
struct SearchPresentationRequestQueue {
    private(set) var pending: SearchPresentationRequest?

    mutating func enqueue(_ request: SearchPresentationRequest) {
        pending = request
    }

    mutating func consumeWhenReady(sceneIsReady: Bool,
                                   searchWindowIsReady: Bool) -> SearchPresentationRequest? {
        guard sceneIsReady, searchWindowIsReady else { return nil }
        defer { pending = nil }
        return pending
    }
}

/// The sole app-hosted route for search presentation requests from external adapters.
@MainActor
final class SearchPresentationCoordinator: ObservableObject {
    static let searchWindowID = "search"
    nonisolated static let maximumQueryUTF8Length = 16 * 1_024

    @Published private(set) var requestGeneration = 0

    private var queue = SearchPresentationRequestQueue()
    private var sceneIsReady = false
    private var isOpeningSearchWindow = false
    private var searchWindows: [NSWindow] = []
    private var openSearchWindow: (() -> Void)?
    private let deliver: (SearchPresentationRequest, NSWindow) -> Void

    init(deliver: @escaping (SearchPresentationRequest, NSWindow) -> Void) {
        self.deliver = deliver
    }

    func showCurrentSearch() {
        enqueue(.showCurrentSearch)
    }

    /// Presents an error without discarding a query already waiting for a scene or window.
    func showCurrentSearchPreservingPendingRequest() {
        guard queue.pending == nil else {
            presentPendingRequest()
            return
        }
        enqueue(.showCurrentSearch)
    }

    func runQuery(_ query: String) throws {
        try Self.validate(query: query)
        enqueue(.runQuery(query))
    }

    nonisolated static func validate(query: String) throws {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SearchPresentationError.emptyQuery
        }
        guard !query.contains("\0") else { throw SearchPresentationError.containsNUL }
        guard query.lengthOfBytes(using: .utf8) <= maximumQueryUTF8Length else {
            throw SearchPresentationError.queryTooLong
        }
    }

    func installSceneOpener(_ opener: @escaping () -> Void) {
        sceneIsReady = true
        openSearchWindow = opener
        presentPendingRequest()
    }

    func registerSearchWindow(_ window: NSWindow) {
        searchWindows.removeAll { $0 == window }
        searchWindows.append(window)
        isOpeningSearchWindow = false
        presentPendingRequest()
    }

    func unregisterSearchWindow(_ window: NSWindow) {
        searchWindows.removeAll { $0 == window }
    }

    func presentPendingRequest() {
        guard sceneIsReady, queue.pending != nil else { return }
        guard let window = preferredSearchWindow() else {
            guard !isOpeningSearchWindow else { return }
            isOpeningSearchWindow = true
            activateApplication()
            openSearchWindow?()
            return
        }
        activate(window)
        guard let request = queue.consumeWhenReady(sceneIsReady: sceneIsReady,
                                                   searchWindowIsReady: true) else { return }
        deliver(request, window)
    }

    private func enqueue(_ request: SearchPresentationRequest) {
        queue.enqueue(request)
        requestGeneration &+= 1
        presentPendingRequest()
    }

    private func preferredSearchWindow() -> NSWindow? {
        return NSApp.orderedWindows.first(where: { searchWindows.contains($0) })
            ?? searchWindows.last
    }

    private func activate(_ window: NSWindow) {
        activateApplication()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func activateApplication() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
