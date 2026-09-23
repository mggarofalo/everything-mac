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
        queryButton.click()

        let query = "name:EverythingMacUITest.swift"
        let queryEditor = editor.textViews.firstMatch
        XCTAssertTrue(queryEditor.waitForExistence(timeout: 10), shortcuts.debugDescription)
        queryEditor.typeText(query)
        editor.buttons["shortcut.button.run"].firstMatch.click()

        let searchField = everythingMac.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND value == %@", "Search", query))
            .firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 30), everythingMac.debugDescription)

        everythingMac.typeKey("w", modifierFlags: .command)
        let closedSearchWindow = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: searchField
        )
        wait(for: [closedSearchWindow], timeout: 10)
        shortcuts.activate()
        editor.buttons["shortcut.button.run"].firstMatch.click()
        XCTAssertTrue(searchField.waitForExistence(timeout: 30), everythingMac.debugDescription)

        everythingMac.terminate()
        XCTAssertTrue(everythingMac.wait(for: .notRunning, timeout: 10))
        shortcuts.activate()
        editor.buttons["shortcut.button.run"].firstMatch.click()
        XCTAssertTrue(searchField.waitForExistence(timeout: 30), everythingMac.debugDescription)
    }
}
