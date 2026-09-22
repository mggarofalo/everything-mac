import Combine
import Foundation

@MainActor
final class MenuBarPreference: ObservableObject {
    @Published var isVisible: Bool {
        didSet { defaults.set(isVisible, forKey: Self.preferenceKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isVisible = defaults.bool(forKey: Self.preferenceKey)
    }

    private static let preferenceKey = "pref.showInMenuBar"
}
