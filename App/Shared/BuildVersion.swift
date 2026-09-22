import Foundation

enum BuildVersion {
    static var display: String {
        // The CLI lives beside the app executable in Contents/MacOS. Read the
        // enclosing bundle so both commands report the same stamped build.
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              executable.deletingLastPathComponent().lastPathComponent == "MacOS" else {
            return "version unknown"
        }
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let infoURL = contents.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return "version unknown"
        }
        return display(from: info)
    }

    static func display(from info: [String: Any]) -> String {
        if let stamped = info["EverythingMacBuildVersion"] as? String, !stamped.isEmpty {
            return stamped
        }
        let semantic = info["CFBundleShortVersionString"] as? String ?? "version unknown"
        return "\(semantic) (revision unknown)"
    }
}
