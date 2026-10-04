import AppKit
import Foundation
import IndexCore

@MainActor enum FolderSelection {
    static func chooseBookmarks() throws -> [Data]? {
        let panel = NSOpenPanel()
        panel.title = "Choose Folders to Search"
        panel.prompt = "Add Folders"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return nil }
        return try panel.urls.map {
            guard MountedVolumes.permitsInspection($0.path) else {
                throw NSError(domain: "EverythingMac", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Choose a folder on a local drive."])
            }
            return try $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }
}
