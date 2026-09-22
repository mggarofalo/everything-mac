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
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(), Self.handleEvent, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard status == noErr else { throw GlobalShortcutRegistrationError.system(status) }
    }

    private func unregister(identifier: UInt32, hotKey: EventHotKeyRef) {
        UnregisterEventHotKey(hotKey)
        actions[identifier] = nil
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
        Task { @MainActor in registrar.actions[identifier.id]?() }
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
