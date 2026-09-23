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
    private(set) var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        title = shortcut.displayString
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel("Global search shortcut")
        setAccessibilityHelp("Click to record one shortcut. Press Delete while recording to clear it.")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
        title = "Type Shortcut"
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if isRecording { title = "Type Shortcut" }
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        title = shortcut.displayString
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        guard !event.isARepeat else { return }
        let recordedShortcut: GlobalShortcut
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            recordedShortcut = .suggested
        } else {
            recordedShortcut = GlobalShortcut.from(event: event)
        }
        isRecording = false
        window?.makeFirstResponder(nil)
        title = shortcut.displayString
        onRecord?(recordedShortcut)
    }
}
