import SwiftUI
import IndexCore

// Result-display defaults apply immediately; no re-index is required.
// Match options live beside the search field, where their effect is visible.
struct SearchSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Results") {
                Picker("Sort by", selection: sortBinding) {
                    Text("Name").tag(QueryEngine.SortKey.name)
                    Text("Path").tag(QueryEngine.SortKey.path)
                    Text("Size").tag(QueryEngine.SortKey.size)
                    Text("Kind").tag(QueryEngine.SortKey.kind)
                    Text("Date Modified").tag(QueryEngine.SortKey.mtime)
                }
                Picker("Order", selection: ascendingBinding) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                Stepper(value: limitBinding, in: 100...10_000, step: 100) {
                    LabeledContent("Max results shown", value: model.resultLimit.formatted())
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private var sortBinding: Binding<QueryEngine.SortKey> {
        Binding(get: { model.sortKey }, set: { model.setSort($0, ascending: model.ascending) })
    }
    private var ascendingBinding: Binding<Bool> {
        Binding(get: { model.ascending }, set: { model.setSort(model.sortKey, ascending: $0) })
    }
    private var limitBinding: Binding<Int> {
        Binding(get: { model.resultLimit }, set: { model.resultLimit = $0; model.searchOptionsChanged() })
    }
}
