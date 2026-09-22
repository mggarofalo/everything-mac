import XCTest
import IndexCore

@MainActor
final class AppModelPreferenceTests: XCTestCase {
    func testPresentedQueryDefaultsSurviveBootstrapWithoutChangingPreferences() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "pref.matchPath")
        defaults.set(true, forKey: "pref.caseSensitive")
        let model = AppModel(defaults: defaults)
        model.runPresentedQuery("report")

        model.setWholeWord(true)

        XCTAssertTrue(defaults.bool(forKey: "pref.matchPath"))
        XCTAssertTrue(defaults.bool(forKey: "pref.caseSensitive"))
        XCTAssertTrue(defaults.bool(forKey: "pref.wholeWord"))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AppModelPreferenceTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}
