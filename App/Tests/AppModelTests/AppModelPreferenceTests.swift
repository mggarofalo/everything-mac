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

    func testSearchUsesPublishedSnapshotDuringBackgroundScan() async {
        let model = makeScanningModel()
        model.query = "fresh-report"

        await model.runSearch()

        XCTAssertEqual(model.results.map(\.name), ["fresh-report"])
        XCTAssertTrue(model.scanning)
    }

    func testPresentedQueryRunsDuringBackgroundScan() async throws {
        let model = makeScanningModel()

        model.runPresentedQuery("spotlight-report")
        for _ in 0..<100 where model.results.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.query, "spotlight-report")
        XCTAssertEqual(model.results.map(\.name), ["spotlight-report"])
        XCTAssertTrue(model.scanning)
    }

    private func makeScanningModel() -> AppModel {
        let client = SearchClient { data in
            let request = try JSONDecoder().decode(ServiceRequest.self, from: data)
            let reply: ServiceReply
            if request.operation == .search {
                let query = try JSONDecoder().decode(SearchRequest.self, from: XCTUnwrap(request.payload))
                let record = FileRecord(id: 1, name: query.text, path: "/" + query.text,
                                        parent: 0, size: 0, mtime: 0, isDir: false, volID: 1)
                reply = .success(SearchResponse(records: [record], limit: query.limit,
                                                truncated: false, scanning: true))
            } else {
                reply = .success(true)
            }
            return try JSONEncoder().encode(reply)
        }
        let model = AppModel(index: client)
        model.scanning = true
        return model
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AppModelPreferenceTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}
