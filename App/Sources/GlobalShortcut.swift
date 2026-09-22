import AppKit
@preconcurrency import Carbon
import Combine

/// A physical keyboard shortcut. Key codes, rather than rendered characters, are
/// persisted so a shortcut continues to refer to the same key across keyboard
/// layouts and after relaunch.
struct GlobalShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let suggested = GlobalShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey)
    )

    var hasCommandOrControl: Bool {
        modifiers & UInt32(cmdKey | controlKey) != 0
    }

    func validationError() -> String? {
        guard !Self.modifierKeyCodes.contains(keyCode) else {
            return "Choose a key together with Command or Control."
        }
        guard hasCommandOrControl else {
            return "Add Command or Control to the shortcut."
        }
        if modifiers & UInt32(cmdKey) != 0, keyCode == UInt32(kVK_Space) {
            return "Command-Space is reserved by macOS. Choose another shortcut."
        }
        if modifiers & UInt32(cmdKey) != 0, keyCode == UInt32(kVK_Tab) {
            return "Command-Tab is reserved by macOS. Choose another shortcut."
        }
        return nil
    }

    var displayString: String {
        modifierDisplayString + KeyboardLayout.keyName(for: keyCode)
    }

    static func from(event: NSEvent) -> GlobalShortcut {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        return GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers)
    }

    private var modifierDisplayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result
    }

    private static let modifierKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_RightCommand),
        UInt32(kVK_Control), UInt32(kVK_RightControl),
        UInt32(kVK_Option), UInt32(kVK_RightOption),
        UInt32(kVK_Shift), UInt32(kVK_RightShift), UInt32(kVK_CapsLock),
        UInt32(kVK_Function)
    ]
}

private enum KeyboardLayout {
    static func keyName(for keyCode: UInt32) -> String {
        if keyCode == UInt32(kVK_Space) { return "Space" }
        if keyCode == UInt32(kVK_Return) { return "Return" }
        if keyCode == UInt32(kVK_Tab) { return "Tab" }
        if keyCode == UInt32(kVK_Escape) { return "Escape" }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
                .assumingMemoryBound(to: CFData.self).pointee as CFData?,
              let bytes = CFDataGetBytePtr(data)
        else { return "Key \(keyCode)" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState, characters.count, &length, &characters
        )
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

enum GlobalShortcutRegistrationError: LocalizedError, Equatable {
    case conflict
    case system(OSStatus)

    var errorDescription: String? {
        switch self {
        case .conflict:
            "That shortcut is already in use by another application."
        case let .system(status):
            "macOS could not register this shortcut (error \(status))."
        }
    }
}

@MainActor
protocol GlobalShortcutRegistration: AnyObject {
    func unregister()
}

@MainActor
protocol GlobalShortcutRegistering: AnyObject {
    func register(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) throws -> any GlobalShortcutRegistration
}

@MainActor
final class GlobalShortcutController: ObservableObject {
    @Published private(set) var shortcut: GlobalShortcut
    @Published private(set) var isEnabled: Bool
    @Published private(set) var registrationError: String?

    private let defaults: UserDefaults
    private let registrar: any GlobalShortcutRegistering
    private let action: @MainActor () -> Void
    private var registration: (any GlobalShortcutRegistration)?

    init(
        defaults: UserDefaults,
        registrar: any GlobalShortcutRegistering,
        action: @escaping @MainActor () -> Void
    ) {
        self.defaults = defaults
        self.registrar = registrar
        self.action = action
        shortcut = Self.loadShortcut(from: defaults)
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    convenience init(defaults: UserDefaults = .standard, action: @escaping @MainActor () -> Void) {
        self.init(defaults: defaults, registrar: CarbonGlobalShortcutRegistrar(), action: action)
    }

    /// Starts registration once during application launch. Reopening Settings does
    /// not create another registration.
    func start() {
        guard isEnabled, registration == nil else { return }
        registerCurrentShortcut()
    }

    func enable() {
        guard !isEnabled else { return }
        registerCurrentShortcut(persistEnabledOnSuccess: true)
    }

    func disable() {
        registration?.unregister()
        registration = nil
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        registrationError = nil
    }

    /// Called from application termination after the UI has gone away.
    func stop() { disable() }

    /// Attempts the replacement before touching the current registration. A
    /// registration failure therefore leaves the previous working shortcut active.
    func setShortcut(_ candidate: GlobalShortcut) {
        guard let message = candidate.validationError() else {
            registrationError = nil
            if !isEnabled {
                shortcut = candidate
                persistShortcut(candidate)
                return
            }
            do {
                let replacement = try registrar.register(candidate, action: action)
                registration?.unregister()
                registration = replacement
                shortcut = candidate
                persistShortcut(candidate)
            } catch {
                registrationError = error.localizedDescription
            }
            return
        }
        registrationError = message
    }

    func clearShortcut() {
        disable()
        shortcut = .suggested
        persistShortcut(shortcut)
    }

    func restoreSuggestedShortcut() {
        setShortcut(.suggested)
    }

    private func registerCurrentShortcut(persistEnabledOnSuccess: Bool = false) {
        if let message = shortcut.validationError() {
            registrationError = message
            return
        }
        do {
            registration = try registrar.register(shortcut, action: action)
            registrationError = nil
            if persistEnabledOnSuccess {
                isEnabled = true
                defaults.set(true, forKey: Self.enabledKey)
            }
        } catch {
            registrationError = error.localizedDescription
        }
    }

    private func persistShortcut(_ value: GlobalShortcut) {
        defaults.set(Int(value.keyCode), forKey: Self.keyCodeKey)
        defaults.set(Int(value.modifiers), forKey: Self.modifiersKey)
    }

    private static func loadShortcut(from defaults: UserDefaults) -> GlobalShortcut {
        guard defaults.object(forKey: keyCodeKey) != nil,
              defaults.object(forKey: modifiersKey) != nil else { return .suggested }
        return GlobalShortcut(
            keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
            modifiers: UInt32(defaults.integer(forKey: modifiersKey))
        )
    }

    private static let enabledKey = "pref.globalShortcut.enabled"
    private static let keyCodeKey = "pref.globalShortcut.keyCode"
    private static let modifiersKey = "pref.globalShortcut.modifiers"
}
