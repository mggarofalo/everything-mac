import SwiftUI
import IndexCore

struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject private var shortcut: GlobalShortcutController
    @Binding var showInMenuBar: Bool
    @State private var automationEnabled = false
    @State private var automationLoaded = false
    @State private var automationSaving = false
    @State private var automationError: String?
    var body: some View {
        Form {
            Section("Search access") {
                Toggle("Global search shortcut", isOn: Binding(
                    get: { shortcut.isEnabled },
                    set: { enabled in enabled ? shortcut.enable() : shortcut.disable() }
                ))
                HStack {
                    GlobalShortcutRecorder(shortcut: shortcut.shortcut, onRecord: shortcut.setShortcut)
                        .frame(minWidth: 150, maxWidth: 210)
                    Button("Clear") { shortcut.clearShortcut() }
                    Button("Restore Suggested") { shortcut.restoreSuggestedShortcut() }
                }
                Text("Use Command or Control with another key. \(GlobalShortcut.suggested.displayString) is suggested.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = shortcut.registrationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Show in menu bar", isOn: $showInMenuBar)
                Text("The menu bar and global shortcut remain available while this app is running, even with all windows closed. Quit EverythingMac removes both; indexing and search services continue running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Background services") {
                LabeledContent("Indexing and search", value: BackgroundServices.statusText)
                Text("The index and search services stay available when this window is closed or quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Command line") {
                Toggle("Allow command-line searches", isOn: Binding(
                    get: { automationEnabled },
                    set: { enabled in
                        automationEnabled = enabled
                        automationSaving = true
                        Task {
                            do {
                                try await model.index.setAutomationAccess(enabled)
                                automationError = nil
                            } catch {
                                automationEnabled = !enabled
                                automationError = "Could not save command-line access."
                            }
                            automationSaving = false
                        }
                    }
                ))
                .disabled(!automationLoaded || automationSaving)
                Text("Off by default. When on, any local process running the signed EverythingMac command-line tool as your user can search and receive filenames and paths. Turning this off cancels active command-line searches but cannot recall output already received.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let automationError {
                    Text(automationError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Index") {
                LabeledContent("Objects indexed", value: model.total.formatted())
                if let s = Self.cacheStats() {
                    LabeledContent("Cache size",
                                   value: ByteCountFormatter.string(fromByteCount: s.size, countStyle: .file))
                    LabeledContent("Last saved",
                                   value: s.modified.formatted(date: .abbreviated, time: .shortened))
                } else {
                    LabeledContent("Cache", value: "not written yet")
                }
                Button(model.scanning ? "Rebuilding…" : "Rebuild Index Now") { model.rebuildIndex() }
                    .disabled(model.scanning || !model.hasFullDiskAccess)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .task {
            do {
                automationEnabled = try await model.index.automationAccessEnabled()
                automationError = nil
            } catch {
                automationError = "Command-line access setting is unavailable."
            }
            automationLoaded = true
        }
    }

    // Size + mtime of the on-disk index cache (~/Library/Application Support/...).
    static func cacheStats() -> (size: Int64, modified: Date)? {
        let path = ServicePaths.cacheURL().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        let date = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        return (size, date)
    }
}
