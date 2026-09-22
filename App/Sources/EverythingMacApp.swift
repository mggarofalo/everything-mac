import SwiftUI
import AppKit

@main
struct EverythingMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var presentation: SearchPresentationCoordinator
    @StateObject private var shortcut: GlobalShortcutController
    @StateObject private var menuBar: MenuBarPreference

    init() {
        let appModel = AppModel()
        _model = StateObject(wrappedValue: appModel)
        let coordinator = SearchPresentationCoordinator { [weak appModel] request, window in
            guard let appModel else { return }
            switch request {
            case .showCurrentSearch:
                appModel.focusSearch(in: window)
            case let .runQuery(query):
                appModel.runPresentedQuery(query)
                appModel.focusSearch(in: window)
            }
        }
        _presentation = StateObject(wrappedValue: coordinator)
        _shortcut = StateObject(wrappedValue: GlobalShortcutController {
            coordinator.showCurrentSearch()
        })
        _menuBar = StateObject(wrappedValue: MenuBarPreference())
    }

    var body: some Scene {
        WindowGroup("EverythingMac", id: SearchPresentationCoordinator.searchWindowID) {
            ContentView()
                .environmentObject(model)
                .environmentObject(presentation)
                .background(SearchPresentationSceneHost())
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    shortcut.start()
                    appDelegate.onTerminate = { shortcut.stop() }
                }
        }
        .commands { AppCommands(model: model) }
        Settings {
            SettingsView(showInMenuBar: $menuBar.isVisible)
                .environmentObject(model)
                .environmentObject(presentation)
                .environmentObject(shortcut)
                .background(SearchPresentationSceneHost())
        }
        MenuBarExtra("EverythingMac", systemImage: "magnifyingglass", isInserted: $menuBar.isVisible) {
            EverythingMacMenuBarExtra()
                .environmentObject(presentation)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct SearchPresentationSceneHost: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var presentation: SearchPresentationCoordinator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                presentation.installSceneOpener {
                    openWindow(id: SearchPresentationCoordinator.searchWindowID)
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        BackgroundServices.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}
