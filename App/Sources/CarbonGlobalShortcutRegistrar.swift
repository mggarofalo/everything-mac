@preconcurrency import Carbon

/// Public Carbon Event Manager registration is the system-wide API used here.
/// It receives only registered hot-key presses and needs no event tap, Accessibility,
/// or Input Monitoring permission. Carbon's API is main-thread-only, so this wrapper
/// is isolated to the main actor.
@MainActor
final class CarbonGlobalShortcutRegistrar: GlobalShortcutRegistering {
    private var handler: EventHandlerRef?
    private var nextIdentifier: UInt32 = 1
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var repeatFilter = HotKeyRepeatFilter()

    func register(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) throws -> any GlobalShortcutRegistration {
        try installHandlerIfNeeded()
        let identifier = nextIdentifier
        nextIdentifier &+= 1
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: OSType(0x45564D43), id: identifier),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey
        )
        guard status == noErr, let hotKey else {
            if status == eventHotKeyExistsErr { throw GlobalShortcutRegistrationError.conflict }
            throw GlobalShortcutRegistrationError.system(status)
        }
        actions[identifier] = action
        return CarbonRegistration(registrar: self, identifier: identifier, hotKey: hotKey)
    }

    private func installHandlerIfNeeded() throws {
        guard handler == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(), Self.handleEvent, eventTypes.count, &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard status == noErr else { throw GlobalShortcutRegistrationError.system(status) }
    }

    private func unregister(identifier: UInt32, hotKey: EventHotKeyRef) {
        UnregisterEventHotKey(hotKey)
        actions[identifier] = nil
        repeatFilter.release(identifier)
    }

    private func handle(identifier: UInt32, kind: UInt32) {
        if kind == UInt32(kEventHotKeyReleased) {
            repeatFilter.release(identifier)
            return
        }
        guard repeatFilter.shouldDeliverPress(identifier) else { return }
        actions[identifier]?()
    }

    private static let handleEvent: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        var size = MemoryLayout<EventHotKeyID>.size
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, size, &size, &identifier
        )
        guard status == noErr else { return status }
        let registrar = Unmanaged<CarbonGlobalShortcutRegistrar>.fromOpaque(userData)
            .takeUnretainedValue()
        let kind = GetEventKind(event)
        Task { @MainActor in registrar.handle(identifier: identifier.id, kind: kind) }
        return noErr
    }

    private final class CarbonRegistration: GlobalShortcutRegistration {
        private weak var registrar: CarbonGlobalShortcutRegistrar?
        private let identifier: UInt32
        private var hotKey: EventHotKeyRef?

        init(registrar: CarbonGlobalShortcutRegistrar, identifier: UInt32, hotKey: EventHotKeyRef) {
            self.registrar = registrar
            self.identifier = identifier
            self.hotKey = hotKey
        }

        func unregister() {
            guard let hotKey else { return }
            registrar?.unregister(identifier: identifier, hotKey: hotKey)
            self.hotKey = nil
        }

    }
}

/// Carbon supplies pressed and released events for a registered hot key. Keeping
/// the short-lived press state prevents repeated pressed callbacks while a key is
/// held, then clears promptly on release.
struct HotKeyRepeatFilter {
    private var pressedIdentifiers: Set<UInt32> = []

    mutating func shouldDeliverPress(_ identifier: UInt32) -> Bool {
        pressedIdentifiers.insert(identifier).inserted
    }

    mutating func release(_ identifier: UInt32) {
        pressedIdentifiers.remove(identifier)
    }
}
