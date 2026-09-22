import AppKit
import SwiftUI
@preconcurrency import Carbon

/// A focused, local AppKit responder for recording a shortcut. It does not observe
/// keys outside this settings control.
struct GlobalShortcutRecorder: NSViewRepresentable {
    let shortcut: GlobalShortcut
    let onRecord: (GlobalShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onRecord = onRecord
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.shortcut = shortcut
        view.onRecord = onRecord
    }

    static func dismantleNSView(_ view: ShortcutRecorderView, coordinator: ()) {
        view.onRecord = nil
    }
}

final class ShortcutRecorderView: NSButton {
    var shortcut = GlobalShortcut.suggested {
        didSet { title = shortcut.displayString }
    }
    var onRecord: ((GlobalShortcut) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        title = shortcut.displayString
        setAccessibilityLabel("Global search shortcut")
        setAccessibilityHelp("Press this button, then press a shortcut. Press Delete to clear it.")
    }

    required init?(coder: NSCoder) { nil }

    override func becomeFirstResponder() -> Bool {
        title = "Type Shortcut"
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        title = shortcut.displayString
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            onRecord?(GlobalShortcut.suggested)
            return
        }
        onRecord?(GlobalShortcut.from(event: event))
    }
}
