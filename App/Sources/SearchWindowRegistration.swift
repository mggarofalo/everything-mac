import AppKit
import SwiftUI

/// Associates only search scenes with the presentation coordinator. Settings and
/// incidental AppKit windows are never candidates for external presentation.
struct SearchWindowRegistration: NSViewRepresentable {
    @EnvironmentObject private var presentation: SearchPresentationCoordinator
    var onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.didMoveToWindow = { [weak presentation] window in
            guard let window else { return }
            onWindowChange(window)
            presentation?.registerSearchWindow(window)
        }
        view.didLeaveWindow = { [weak presentation] window in
            guard let window else { return }
            presentation?.unregisterSearchWindow(window)
            onWindowChange(nil)
        }
        return view
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {}
}

final class RegistrationView: NSView {
    var didMoveToWindow: ((NSWindow?) -> Void)?
    var didLeaveWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        didMoveToWindow?(window)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { didLeaveWindow?(window) }
        super.viewWillMove(toWindow: newWindow)
    }
}
