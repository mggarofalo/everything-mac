import XCTest
import IndexCore

@MainActor
final class AppModelPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppModelPreferenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPresentedQueryDefaultsSurviveBootstrapWithoutChangingPreferences() {
        defaults.set(true, forKey: "pref.matchPath")
        defaults.set(true, forKey: "pref.caseSensitive")
        defaults.set(true, forKey: "pref.wholeWord")
        defaults.set(900, forKey: "pref.resultLimit")
        defaults.set(QueryEngine.SortKey.mtime.rawValue, forKey: "pref.sortKey")
        defaults.set(false, forKey: "pref.ascending")
        let model = AppModel(defaults: defaults)

        model.runPresentedQuery("regex:report.*")
        model.loadPrefs()

        XCTAssertEqual(model.query, "regex:report.*")
        XCTAssertEqual(model.sortKey, .name)
        XCTAssertTrue(model.ascending)
        XCTAssertFalse(model.matchPath)
        XCTAssertFalse(model.caseSensitive)
        XCTAssertFalse(model.wholeWord)
        XCTAssertEqual(model.resultLimit, 5_000)
        XCTAssertTrue(defaults.bool(forKey: "pref.matchPath"))
        XCTAssertTrue(defaults.bool(forKey: "pref.caseSensitive"))
        XCTAssertTrue(defaults.bool(forKey: "pref.wholeWord"))
        XCTAssertEqual(defaults.integer(forKey: "pref.resultLimit"), 900)
        XCTAssertEqual(defaults.string(forKey: "pref.sortKey"), QueryEngine.SortKey.mtime.rawValue)
        XCTAssertFalse(defaults.bool(forKey: "pref.ascending"))
    }

    func testTypingAfterPresentedQueryDoesNotPersistTransientDefaults() {
        defaults.set(true, forKey: "pref.matchPath")
        defaults.set(900, forKey: "pref.resultLimit")
        let model = AppModel(defaults: defaults)
        model.runPresentedQuery("report")

        model.query = "report final"
        model.queryChanged()

        XCTAssertTrue(defaults.bool(forKey: "pref.matchPath"))
        XCTAssertEqual(defaults.integer(forKey: "pref.resultLimit"), 900)
    }

    func testUserOptionEditPersistsOnlyItsOwnSettingAfterPresentedQuery() {
        defaults.set(true, forKey: "pref.matchPath")
        defaults.set(true, forKey: "pref.caseSensitive")
        let model = AppModel(defaults: defaults)
        model.runPresentedQuery("report")

        model.setWholeWord(true)

        XCTAssertTrue(defaults.bool(forKey: "pref.matchPath"))
        XCTAssertTrue(defaults.bool(forKey: "pref.caseSensitive"))
        XCTAssertTrue(defaults.bool(forKey: "pref.wholeWord"))
    }
}
