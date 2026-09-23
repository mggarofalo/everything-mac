import AppKit
@preconcurrency import Carbon
import Combine
import XCTest

@MainActor
final class GlobalShortcutTests: XCTestCase {
    func testSuggestedShortcutIsControlOptionSpaceAndOptIn() {
        let fixture = Fixture()

        XCTAssertEqual(fixture.controller.shortcut, .suggested)
        XCTAssertEqual(fixture.controller.shortcut.displayString, "⌃⌥Space")
        XCTAssertFalse(fixture.controller.isEnabled)
        XCTAssertEqual(fixture.registrar.registeredShortcuts, [])
    }

    func testSavedLetterShortcutDisplaysWhenSettingsReopens() {
        let fixture = Fixture()
        let shortcut = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | shiftKey)
        )
        fixture.controller.setShortcut(shortcut)

        let reloaded = fixture.reloadedController(registrar: MockRegistrar())
        let recorder = ShortcutRecorderView()
        recorder.shortcut = reloaded.shortcut

        XCTAssertEqual(reloaded.shortcut, shortcut)
        XCTAssertTrue(recorder.title.hasPrefix("⌃⇧"))
        XCTAssertGreaterThan(recorder.title.count, 2)
    }

    func testEnableRegistersOnlyOnceAndPersists() {
        let fixture = Fixture()

        fixture.controller.enable()
        fixture.controller.enable()

        XCTAssertTrue(fixture.controller.isEnabled)
        XCTAssertEqual(fixture.registrar.registeredShortcuts, [.suggested])
        XCTAssertTrue(fixture.reloadedController(registrar: MockRegistrar()).isEnabled)
    }

    func testFailedEnableLeavesTheShortcutDisabled() {
        let fixture = Fixture()
        fixture.registrar.result = .failure(.conflict)

        fixture.controller.enable()

        XCTAssertFalse(fixture.controller.isEnabled)
        XCTAssertEqual(fixture.controller.registrationError,
                       GlobalShortcutRegistrationError.conflict.localizedDescription)
        XCTAssertFalse(fixture.reloadedController(registrar: MockRegistrar()).isEnabled)
    }

    func testFailedRebindRetainsPriorRegistrationAndSettings() {
        let fixture = Fixture()
        fixture.controller.enable()
        let prior = fixture.controller.shortcut
        let candidate = shortcut(keyCode: kVK_ANSI_A)
        fixture.registrar.result = .failure(.conflict)

        fixture.controller.setShortcut(candidate)

        XCTAssertEqual(fixture.controller.shortcut, prior)
        XCTAssertEqual(fixture.registrar.registrations.count, 1)
        XCTAssertFalse(fixture.registrar.registrations[0].didUnregister)
        XCTAssertEqual(fixture.controller.registrationError,
                       GlobalShortcutRegistrationError.conflict.localizedDescription)
        XCTAssertEqual(fixture.reloadedController(registrar: MockRegistrar()).shortcut, prior)
    }

    func testSuccessfulRebindRegistersReplacementBeforeRemovingPriorBinding() {
        let fixture = Fixture()
        fixture.controller.enable()
        let candidate = shortcut(keyCode: kVK_ANSI_A)

        fixture.controller.setShortcut(candidate)

        XCTAssertEqual(fixture.controller.shortcut, candidate)
        XCTAssertTrue(fixture.registrar.registrations[0].didUnregister)
        XCTAssertFalse(fixture.registrar.registrations[1].didUnregister)
        XCTAssertEqual(fixture.reloadedController(registrar: MockRegistrar()).shortcut, candidate)
    }

    func testDisableUnregistersAndClearsTheEnabledPreference() {
        let fixture = Fixture()
        fixture.controller.enable()

        fixture.controller.disable()
        XCTAssertTrue(fixture.registrar.registrations[0].didUnregister)
        XCTAssertFalse(fixture.controller.isEnabled)

    }

    func testStopUnregistersWithoutClearingTheEnabledPreference() {
        let fixture = Fixture()
        fixture.controller.enable()

        fixture.controller.stop()

        XCTAssertTrue(fixture.registrar.registrations[0].didUnregister)
        XCTAssertTrue(fixture.controller.isEnabled)
        let reloadedRegistrar = MockRegistrar()
        let reloaded = fixture.reloadedController(registrar: reloadedRegistrar)
        reloaded.start()
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertEqual(reloadedRegistrar.registeredShortcuts, [.suggested])
    }

    func testRejectsBareAndKnownReservedShortcuts() {
        let fixture = Fixture()

        fixture.controller.setShortcut(GlobalShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: 0))
        XCTAssertEqual(fixture.controller.registrationError,
                       "Add Command or Control to the shortcut.")
        fixture.controller.setShortcut(GlobalShortcut(
            keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)
        ))
        XCTAssertEqual(fixture.controller.registrationError,
                       "Command-Space is reserved by macOS. Choose another shortcut.")
    }

    func testRecorderIgnoresHeldKeyRepeats() {
        let recorder = ShortcutRecorderView()
        var recordings: [GlobalShortcut] = []
        recorder.onRecord = { recordings.append($0) }
        let event = try! XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: true, keyCode: UInt16(kVK_ANSI_A)
        ))

        recorder.keyDown(with: event)

        XCTAssertTrue(recordings.isEmpty)
    }

    func testClickingRecorderFocusesItForKeyboardInput() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let recorder = ShortcutRecorderView(frame: NSRect(x: 20, y: 20, width: 200, height: 30))
        window.contentView?.addSubview(recorder)

        recorder.performClick(nil)

        XCTAssertTrue(window.firstResponder === recorder)
        XCTAssertEqual(recorder.title, "Type Shortcut")
    }

    func testFocusedRecorderCapturesMenuKeyEquivalent() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let recorder = ShortcutRecorderView(frame: NSRect(x: 20, y: 20, width: 200, height: 30))
        window.contentView?.addSubview(recorder)
        var recordings: [GlobalShortcut] = []
        recorder.onRecord = { recordings.append($0) }
        recorder.performClick(nil)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "f",
            charactersIgnoringModifiers: "f", isARepeat: false, keyCode: UInt16(kVK_ANSI_F)
        ))

        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(recordings, [GlobalShortcut.from(event: event)])
    }

    func testRestoringTheActiveSuggestionDoesNotReregister() throws {
        let fixture = Fixture()
        fixture.controller.enable()
        fixture.registrar.result = .failure(.conflict)
        let recorder = ShortcutRecorderView()
        recorder.onRecord = fixture.controller.setShortcut
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0,
            windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: UInt16(kVK_Space)
        ))

        recorder.keyDown(with: event)
        fixture.controller.restoreSuggestedShortcut()

        XCTAssertEqual(fixture.registrar.registrations.count, 1)
        XCTAssertNil(fixture.controller.registrationError)
    }

    func testHotKeyRepeatFilterDeliversOnceUntilRelease() {
        var filter = HotKeyRepeatFilter()

        XCTAssertTrue(filter.shouldDeliverPress(17))
        XCTAssertFalse(filter.shouldDeliverPress(17))
        filter.release(17)
        XCTAssertTrue(filter.shouldDeliverPress(17))
    }

    func testMenuBarPreferenceDefaultsOffAndPersists() {
        let suite = "MenuBarPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = MenuBarPreference(defaults: defaults)

        XCTAssertFalse(preference.isVisible)
        preference.isVisible = true
        XCTAssertTrue(MenuBarPreference(defaults: defaults).isVisible)
    }

    func testMenuBarPreferenceDoesNotPublishForAnUnchangedValue() {
        let suite = "MenuBarPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = MenuBarPreference(defaults: defaults)
        var updates = 0
        let subscription = preference.objectWillChange.sink { _ in updates += 1 }
        defer { subscription.cancel() }

        preference.setVisible(false)
        XCTAssertEqual(updates, 0)

        preference.setVisible(true)
        XCTAssertEqual(updates, 1)
    }

    private func shortcut(keyCode: Int) -> GlobalShortcut {
        GlobalShortcut(keyCode: UInt32(keyCode), modifiers: UInt32(controlKey | optionKey))
    }
}

@MainActor
private final class Fixture {
    let defaults: UserDefaults
    private let suite: String
    let registrar = MockRegistrar()
    let controller: GlobalShortcutController

    init() {
        suite = "GlobalShortcutTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        controller = GlobalShortcutController(defaults: defaults, registrar: registrar, action: {})
    }

    deinit { defaults.removePersistentDomain(forName: suite) }

    func reloadedController(registrar: MockRegistrar) -> GlobalShortcutController {
        GlobalShortcutController(defaults: defaults, registrar: registrar, action: {})
    }
}

@MainActor
private final class MockRegistrar: GlobalShortcutRegistering {
    enum Result { case success, failure(GlobalShortcutRegistrationError) }
    var result: Result = .success
    private(set) var registeredShortcuts: [GlobalShortcut] = []
    private(set) var registrations: [MockRegistration] = []

    func register(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) throws -> any GlobalShortcutRegistration {
        if case let .failure(error) = result { throw error }
        registeredShortcuts.append(shortcut)
        let registration = MockRegistration()
        registrations.append(registration)
        return registration
    }
}

@MainActor
private final class MockRegistration: GlobalShortcutRegistration {
    private(set) var didUnregister = false
    func unregister() { didUnregister = true }
}
