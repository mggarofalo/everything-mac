import XCTest

@MainActor
final class ShortcutsUITests: XCTestCase {
    func testSearchActionIsDiscoverableInShortcuts() {
        let everythingMac = XCUIApplication(bundleIdentifier: "com.everythingmac.app")
        everythingMac.launch()

        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.launch()

        let newShortcut = shortcuts.buttons["New Shortcut"].firstMatch
        XCTAssertTrue(newShortcut.waitForExistence(timeout: 20), shortcuts.debugDescription)
        newShortcut.click()

        let actionSearch = shortcuts.searchFields["Search"].firstMatch
        XCTAssertTrue(actionSearch.waitForExistence(timeout: 20), shortcuts.debugDescription)
        actionSearch.click()
        actionSearch.typeText("Search EverythingMac")

        let searchAction = shortcuts.staticTexts["Search EverythingMac"].firstMatch
        XCTAssertTrue(searchAction.waitForExistence(timeout: 30), shortcuts.debugDescription)
    }
}
