import XCTest

@MainActor
final class ShortcutsUITests: XCTestCase {
    func testShortcutsFindsAndRunsSearchAction() {
        let everythingMac = XCUIApplication(bundleIdentifier: "com.everythingmac.app")
        everythingMac.launch()

        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.launch()

        let addShortcut = shortcuts.buttons["add"].firstMatch
        let newShortcut = shortcuts.buttons["New Shortcut"].firstMatch
        if addShortcut.exists {
            addShortcut.click()
        } else {
            XCTAssertTrue(newShortcut.waitForExistence(timeout: 20), shortcuts.debugDescription)
            newShortcut.click()
        }

        let editor = shortcuts.windows["New Shortcut"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), shortcuts.debugDescription)
        let actionSearch = editor.searchFields.firstMatch
        XCTAssertTrue(actionSearch.waitForExistence(timeout: 20), shortcuts.debugDescription)
        actionSearch.click()
        actionSearch.typeText("Search EverythingMac")

        let searchAction = editor.buttons[
            "editor.drawer.action.com.everythingmac.app.SearchEverythingMacIntent"
        ].firstMatch
        XCTAssertTrue(searchAction.waitForExistence(timeout: 30), shortcuts.debugDescription)
        searchAction.doubleClick()

        let actionCard = editor.descendants(matching: .any)
            .matching(identifier: "editor.action.com.everythingmac.app.SearchEverythingMacIntent")
            .firstMatch
        let queryButton = actionCard.buttons.firstMatch
        XCTAssertTrue(queryButton.waitForExistence(timeout: 10), shortcuts.debugDescription)
        let queryEditor = editor.textViews.firstMatch
        func setQuery(_ query: String) {
            queryButton.click()
            XCTAssertTrue(queryEditor.waitForExistence(timeout: 10), shortcuts.debugDescription)
            queryEditor.typeKey("a", modifierFlags: .command)
            queryEditor.typeText(query)
            XCTAssertEqual(queryEditor.value as? String, query)
        }
        func searchField(for query: String) -> XCUIElement {
            everythingMac.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@ AND value == %@", "Search", query))
                .firstMatch
        }

        let initialQuery = "name:EverythingMacUITest.swift"
        setQuery(initialQuery)
        editor.buttons["shortcut.button.run"].firstMatch.click()

        XCTAssertTrue(searchField(for: initialQuery).waitForExistence(timeout: 30), everythingMac.debugDescription)

        everythingMac.typeKey("w", modifierFlags: .command)
        let closedSearchWindow = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: searchField(for: initialQuery)
        )
        wait(for: [closedSearchWindow], timeout: 10)
        shortcuts.activate()
        let closedQuery = "name:EverythingMacUITest-Closed.swift"
        setQuery(closedQuery)
        editor.buttons["shortcut.button.run"].firstMatch.click()
        XCTAssertTrue(searchField(for: closedQuery).waitForExistence(timeout: 30), everythingMac.debugDescription)

        everythingMac.typeKey("h", modifierFlags: .command)
        XCTAssertTrue(everythingMac.wait(for: .runningBackground, timeout: 10))
        shortcuts.activate()
        let hiddenQuery = "name:EverythingMacUITest-Hidden.swift"
        setQuery(hiddenQuery)
        editor.buttons["shortcut.button.run"].firstMatch.click()
        XCTAssertTrue(everythingMac.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(searchField(for: hiddenQuery).waitForExistence(timeout: 30), everythingMac.debugDescription)

        everythingMac.terminate()
        XCTAssertTrue(everythingMac.wait(for: .notRunning, timeout: 10))
        shortcuts.activate()
        let relaunchedQuery = "name:EverythingMacUITest-Relaunched.swift"
        setQuery(relaunchedQuery)
        editor.buttons["shortcut.button.run"].firstMatch.click()
        XCTAssertTrue(searchField(for: relaunchedQuery).waitForExistence(timeout: 30), everythingMac.debugDescription)
    }
}
