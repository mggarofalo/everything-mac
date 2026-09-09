import SwiftUI
import IndexCore

struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section("Background services") {
                LabeledContent("Indexing and search", value: BackgroundServices.statusText)
                Text("The index and search services stay available when this window is closed or quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
