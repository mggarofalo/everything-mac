import SwiftUI
import IndexCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var fdaGranted = true
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !fdaGranted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Grant Full Disk Access to EverythingMacIndexer.")
                    Spacer()
                    Button("Open Settings") { FullDiskAccess.openSettings() }
                }
                .padding(8)
                .background(.yellow.opacity(0.2))
                Divider()
            }
            SearchField(text: $model.query,
                        matchPath: $model.matchPath,
                        caseSensitive: $model.caseSensitive,
                        wholeWord: $model.wholeWord,
                        focused: $searchFocused,
                        onTextChange: { model.queryChanged() },
                        onOptionsChange: { model.searchOptionsChanged() })
            Divider()
            ResultsTable(rows: model.results,
                         onSort: { k, a in model.setSort(k, ascending: a) },
                         onSelect: { model.select($0) },
                         onActivate: { ResultActions.open($0) })
            Divider()
            StatusBar(total: model.total, shown: model.results.count, scanning: model.scanning)
        }
        .background(.regularMaterial)
        .onAppear {
            refreshAccess()
            searchFocused = true
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { refreshAccess() }
        }
        .onChange(of: model.focusSearchSignal) { searchFocused = true }
    }

    private func refreshAccess() {
        Task {
            let granted = await model.index.serviceHasFullDiskAccess()
            fdaGranted = granted
            model.updateFullDiskAccess(granted)
        }
    }
}
