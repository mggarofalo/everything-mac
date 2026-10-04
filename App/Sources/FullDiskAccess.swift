import Foundation
import AppKit

enum FullDiskAccess {
    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
