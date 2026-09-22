import SwiftUI
import AppKit

@main
struct EverythingMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var presentation: SearchPresentationCoordinator

    init() {
        let appModel = AppModel()
        _model = StateObject(wrappedValue: appModel)
        _presentation = StateObject(wrappedValue: SearchPresentationCoordinator { [weak appModel] request in
            guard let appModel else { return }
            switch request {
            case .showCurrentSearch:
                appModel.focusSearch()
            case let .runQuery(query):
                appModel.runPresentedQuery(query)
                appModel.focusSearch()
            }
        })
    }

    var body: some Scene {
        WindowGroup("EverythingMac", id: SearchPresentationCoordinator.searchWindowID) {
            ContentView()
                .environmentObject(model)
                .environmentObject(presentation)
                .background(SearchPresentationSceneHost())
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands { AppCommands(model: model) }
        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(presentation)
                .background(SearchPresentationSceneHost())
        }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        BackgroundServices.install()
    }
}
