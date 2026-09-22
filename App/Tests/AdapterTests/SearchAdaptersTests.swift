import XCTest

@MainActor
final class SearchAdaptersTests: XCTestCase {
    func testURLParserAcceptsCanonicalURLsWithoutChangingLiterals() throws {
        let cases = [
            ("everythingmac://search?q=report", "report"),
            ("EVERYTHINGMAC://SEARCH/?q=quoted%20path%20%26%20plus%2B", "quoted path & plus+"),
            ("everythingmac://search?q=regex%3Afoo%5Cd%2B", "regex:foo\\d+"),
            ("everythingmac://search?q=%F0%9F%93%84", "📄"),
            ("everythingmac://search?q=one%2520two", "one%20two")
        ]

        for (source, expected) in cases {
            XCTAssertEqual(try SearchURLParser.query(from: try url(source)), expected, source)
        }
    }

    func testURLParserRejectsNonCanonicalOrUnsafeURLs() throws {
        let invalidURLs = [
            "other://search?q=query",
            "everythingmac://files?q=query",
            "everythingmac://search/other?q=query",
            "everythingmac://user@search?q=query",
            "everythingmac://search:80?q=query",
            "everythingmac://search?q=query#fragment",
            "everythingmac://search",
            "everythingmac://search?q=query&q=again",
            "everythingmac://search?q=query&other=value",
            "everythingmac://search?q=",
            "everythingmac://search?query=value",
            "everythingmac://search?q=%00"
        ]

        for source in invalidURLs {
            XCTAssertThrowsError(try SearchURLParser.query(from: try url(source)), source)
        }
    }

    func testURLParserEnforcesUTF8ByteLimit() throws {
        let maximum = String(repeating: "📄", count: 4_096)
        let tooLong = maximum + "a"

        XCTAssertEqual(try SearchURLParser.query(from: searchURL(query: maximum)), maximum)
        XCTAssertThrowsError(try SearchURLParser.query(from: searchURL(query: tooLong)))
    }

    func testIntentHandoffPreservesTypedQueryBeforeCoordinatorInstallation() throws {
        let host = SearchPresentationHost()
        let intent = SearchEverythingMacIntent(query: "name:\"annual report\" OR regex:foo\\d+")

        try host.runQuery(intent.query)

        XCTAssertEqual(host.pendingRequest, .runQuery(intent.query))
    }

    func testInvalidURLDoesNotReplacePendingSearch() throws {
        let host = SearchPresentationHost()
        try host.runQuery("existing query")

        host.handle(url: try url("everythingmac://search?q="))

        XCTAssertEqual(host.pendingRequest, .runQuery("existing query"))
        XCTAssertNotNil(host.urlErrorMessage)
    }

    func testInvalidURLPreservesInstalledCoordinatorRequestUntilWindowIsReady() throws {
        _ = NSApplication.shared
        var delivered: [SearchPresentationRequest] = []
        let coordinator = SearchPresentationCoordinator { request, _ in
            delivered.append(request)
        }
        let host = SearchPresentationHost()
        host.install(coordinator)
        try host.runQuery("valid query")

        host.handle(url: try url("everythingmac://search?q="))
        coordinator.installSceneOpener {}
        let window = NSWindow()
        coordinator.registerSearchWindow(window)

        XCTAssertEqual(delivered, [.runQuery("valid query")])
        XCTAssertNotNil(host.urlErrorMessage)
    }

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    private func searchURL(query: String) -> URL {
        var components = URLComponents()
        components.scheme = "everythingmac"
        components.host = "search"
        components.percentEncodedQuery = "q=" + query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        return components.url!
    }
}
