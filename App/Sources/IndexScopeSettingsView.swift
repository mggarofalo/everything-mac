import SwiftUI
import IndexCore

struct IndexScopeSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmBroadScope = false

    var body: some View {
        Form {
            Section("Search scope") {
                LabeledContent("Indexing", value: model.scopeSettings.mode == .selectedFolders
                               ? "Selected folders" : "All local volumes")
                if model.scopeSettings.mode == .localVolumes {
                    Text("This includes accessible folders across local drives. Protected app data may remain unavailable. Full Disk Access is optional and must be granted explicitly in System Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Use Selected Folders") {
                        model.changeScope(mode: .selectedFolders, retaining: model.scopeSettings.folders)
                    }
                } else {
                    Button("Index All Local Volumes…") { confirmBroadScope = true }
                }
            }
            Section("Selected folders") {
                if model.scopeSettings.folders.isEmpty {
                    Text("Choose folders to start searching. Full Disk Access is not required for ordinary selected folders.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.scopeSettings.folders, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(2).truncationMode(.middle)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            model.changeScope(mode: .selectedFolders,
                                              retaining: model.scopeSettings.folders.filter { $0 != path })
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Folders…") { model.chooseFolders() }
            }
            Section("Live updates") {
                LabeledContent("Monitoring", value: monitoringText)
                Text("The indexing service watches changes while the app is closed and replays changes after restarting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issues = model.coverage?.issues, !issues.isEmpty {
                Section("Unavailable paths") {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading) {
                            Text(issue.path).lineLimit(2).truncationMode(.middle)
                            Text(issue.accessDenied ? "Access denied" : "Folder or metadata unavailable")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Open Privacy Settings", action: FullDiskAccess.openSettings)
                    Button("Retry Access and Rebuild") { model.rebuildIndex() }
                }
            }
            if let error = model.scopeError { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .padding(20)
        .disabled(model.scanning)
        .confirmationDialog("Index accessible files on all local volumes?", isPresented: $confirmBroadScope) {
            Button("Index All Local Volumes") {
                model.changeScope(mode: .localVolumes, retaining: model.scopeSettings.folders)
            }
        } message: {
            Text("Filenames and paths from your local drives will be stored on this Mac. This changes search scope; macOS still controls access to protected data.")
        }
    }

    private var monitoringText: String {
        switch model.coverage?.monitoring {
        case .live: "Watching filesystem changes"
        case .retrying: "Unavailable — retrying"
        case .starting: "Starting"
        case .inactive, nil: "No active watch"
        }
    }
}
