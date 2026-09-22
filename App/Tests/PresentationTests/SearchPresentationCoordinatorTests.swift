import XCTest

final class SearchPresentationCoordinatorTests: XCTestCase {
    func testRequestWaitsForSceneAndWindowThenConsumesOnce() {
        var queue = SearchPresentationRequestQueue()
        queue.enqueue(.showCurrentSearch)

        XCTAssertNil(queue.consumeWhenReady(sceneIsReady: false, searchWindowIsReady: true))
        XCTAssertNil(queue.consumeWhenReady(sceneIsReady: true, searchWindowIsReady: false))
        XCTAssertEqual(queue.consumeWhenReady(sceneIsReady: true, searchWindowIsReady: true),
                       .showCurrentSearch)
        XCTAssertNil(queue.consumeWhenReady(sceneIsReady: true, searchWindowIsReady: true))
    }

    func testLatestQueryReplacesEarlierRequest() {
        var queue = SearchPresentationRequestQueue()
        queue.enqueue(.showCurrentSearch)
        queue.enqueue(.runQuery("older"))
        queue.enqueue(.runQuery("newer"))

        XCTAssertEqual(queue.consumeWhenReady(sceneIsReady: true, searchWindowIsReady: true),
                       .runQuery("newer"))
    }

    func testPresentedQueryDefaultsArePredictable() {
        let defaults = PresentedSearchDefaults()

        XCTAssertEqual(defaults.sortKey, .name)
        XCTAssertTrue(defaults.ascending)
        XCTAssertFalse(defaults.matchPath)
        XCTAssertFalse(defaults.caseSensitive)
        XCTAssertFalse(defaults.wholeWord)
        XCTAssertFalse(defaults.usesRegularExpression)
        XCTAssertEqual(defaults.resultLimit, 5_000)
    }

    func testQueryValidationRejectsBlankNULAndOversizedInput() {
        XCTAssertThrowsError(try SearchPresentationCoordinator.validate(query: "  \n"))
        XCTAssertThrowsError(try SearchPresentationCoordinator.validate(query: "a\0b"))
        XCTAssertThrowsError(try SearchPresentationCoordinator.validate(
            query: String(repeating: "a", count: SearchPresentationCoordinator.maximumQueryUTF8Length + 1)
        ))
        XCTAssertNoThrow(try SearchPresentationCoordinator.validate(query: "regex:report.*"))
    }
}
