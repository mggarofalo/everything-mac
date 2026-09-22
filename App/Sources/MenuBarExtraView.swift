import AppKit
import SwiftUI

struct EverythingMacMenuBarExtra: View {
    @EnvironmentObject private var presentation: SearchPresentationCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Search EverythingMac") {
            presentation.showCurrentSearch()
        }
        SettingsLink {
            Text("Settings…")
        }
        Divider()
        Button("Quit EverythingMac") {
            NSApp.terminate(nil)
        }
    }
}
