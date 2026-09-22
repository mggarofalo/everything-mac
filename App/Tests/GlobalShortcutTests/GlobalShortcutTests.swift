import AppKit
@preconcurrency import Carbon
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

    func testEnableRegistersOnlyOnceAndPersists() {
        let fixture = Fixture()

        fixture.controller.enable()
        fixture.controller.enable()

        XCTAssertTrue(fixture.controller.isEnabled)
        XCTAssertEqual(fixture.registrar.registeredShortcuts, [.suggested])
        XCTAssertTrue(fixture.reloadedController().isEnabled)
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
        XCTAssertEqual(fixture.reloadedController().shortcut, prior)
    }

    func testSuccessfulRebindRegistersReplacementBeforeRemovingPriorBinding() {
        let fixture = Fixture()
        fixture.controller.enable()
        let candidate = shortcut(keyCode: kVK_ANSI_A)

        fixture.controller.setShortcut(candidate)

        XCTAssertEqual(fixture.controller.shortcut, candidate)
        XCTAssertTrue(fixture.registrar.registrations[0].didUnregister)
        XCTAssertFalse(fixture.registrar.registrations[1].didUnregister)
        XCTAssertEqual(fixture.reloadedController().shortcut, candidate)
    }

    func testDisableAndStopUnregisterTheActiveBinding() {
        let fixture = Fixture()
        fixture.controller.enable()

        fixture.controller.disable()
        XCTAssertTrue(fixture.registrar.registrations[0].didUnregister)
        XCTAssertFalse(fixture.controller.isEnabled)

        fixture.controller.enable()
        fixture.controller.stop()
        XCTAssertTrue(fixture.registrar.registrations[1].didUnregister)
        XCTAssertFalse(fixture.controller.isEnabled)
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

    func reloadedController() -> GlobalShortcutController {
        GlobalShortcutController(defaults: defaults, registrar: MockRegistrar(), action: {})
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
