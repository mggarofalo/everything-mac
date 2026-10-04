import AppKit
import Foundation
import IndexCore

/// A separately signed UI client for exercising the production service boundary.
@main @MainActor enum ScopeServiceSmoke {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { exit(64) }
        let operation = arguments[1]
        let output = URL(fileURLWithPath: arguments[2])
        let application = NSApplication.shared
        application.setActivationPolicy(operation == "select" ? .regular : .prohibited)
        Task {
            do {
                let client = SearchClient()
                let result: Data
                switch operation {
                case "select":
                    application.activate(ignoringOtherApps: true)
                    let settings = try await client.scopeSettings()
                    guard let bookmarks = try FolderSelection.chooseBookmarks() else {
                        result = try JSONEncoder().encode(["cancelled": true])
                        try result.write(to: output)
                        exit(0)
                    }
                    let updated = try await client.setScope(IndexScopeUpdate(
                        mode: .selectedFolders, retainedFolders: settings.folders, addedBookmarks: bookmarks
                    ))
                    result = try JSONEncoder().encode(updated)
                case "clear":
                    result = try JSONEncoder().encode(await client.setScope(IndexScopeUpdate(
                        mode: .selectedFolders, retainedFolders: [], addedBookmarks: []
                    )))
                case "status":
                    result = try JSONEncoder().encode(await client.currentStatus())
                case "search":
                    let text = arguments.count > 3 ? arguments[3] : ""
                    result = try JSONEncoder().encode(await client.search(
                        text, matchPath: false, sort: .name, ascending: true, limit: 1000
                    ))
                default: throw ServiceErrorCode.invalidQuery
                }
                try result.write(to: output)
                exit(0)
            } catch {
                try? JSONEncoder().encode(["error": error.localizedDescription]).write(to: output)
                exit(1)
            }
        }
        application.run()
    }
}
