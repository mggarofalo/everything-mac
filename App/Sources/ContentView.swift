import SwiftUI
import IndexCore

struct ContentView: View {
    private enum AccessState {
        case checking
        case granted
        case denied
        case backgroundApprovalRequired
        case serviceUnavailable
    }

    @EnvironmentObject var model: AppModel
    @EnvironmentObject private var presentationHost: SearchPresentationHost
    @Environment(\.scenePhase) private var scenePhase
    @State private var accessState = AccessState.checking
    @State private var refreshServicesAfterSettings = false
    @FocusState private var searchFocused: Bool
    @State private var searchWindowNumber: Int?

    var body: some View {
        VStack(spacing: 0) {
            if let urlErrorMessage = presentationHost.urlErrorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(urlErrorMessage)
                    Spacer()
                    Button("Dismiss") { presentationHost.dismissURLError() }
                }
                .padding(8)
                .background(.yellow.opacity(0.2))
                Divider()
            }
            if accessState == .denied {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Grant Full Disk Access to EverythingMac.")
                    Spacer()
                    Button("Open Settings") {
                        refreshServicesAfterSettings = true
                        FullDiskAccess.openSettings()
                    }
                }
                .padding(8)
                .background(.yellow.opacity(0.2))
                Divider()
            } else if accessState == .backgroundApprovalRequired {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Allow EverythingMac to run in the background.")
                    Spacer()
                    Button("Open Login Items") { BackgroundServices.openApprovalSettings() }
                }
                .padding(8)
                .background(.yellow.opacity(0.2))
                Divider()
            } else if accessState == .serviceUnavailable {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("EverythingMac's background services aren't responding.")
                    Spacer()
                    Button("Retry") { refreshAccess() }
                }
                .padding(8)
                .background(.yellow.opacity(0.2))
                Divider()
            }
            SearchField(text: $model.query,
                        matchPath: Binding(get: { model.matchPath }, set: { model.setMatchPath($0) }),
                        caseSensitive: Binding(get: { model.caseSensitive }, set: { model.setCaseSensitive($0) }),
                        wholeWord: Binding(get: { model.wholeWord }, set: { model.setWholeWord($0) }),
                        focused: $searchFocused,
                        focusSignal: model.focusSearchSignal,
                        isFocusTarget: model.focusSearchWindowNumber == searchWindowNumber,
                        onTextChange: { model.queryChanged() })
            Divider()
            ZStack {
                ResultsTable(rows: model.results,
                             onSort: { k, a in model.setSort(k, ascending: a) },
                             onSelect: { model.select($0) },
                             onActivate: { ResultActions.open($0) })
                if showsStartupProgress {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Starting indexer")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Starting indexing service…").font(.headline)
                            Text("Preparing the first scan").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                }
            }
            Divider()
            StatusBar(total: model.total, shown: model.results.count, scanning: model.scanning)
        }
        .background(.regularMaterial)
        .background(SearchWindowRegistration { searchWindowNumber = $0?.windowNumber })
        .onAppear {
            refreshAccess()
            searchFocused = true
        }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            let shouldRestart = refreshServicesAfterSettings
            refreshServicesAfterSettings = false
            refreshAccess(restartServicesIfDenied: shouldRestart)
        }
        .onChange(of: model.focusSearchSignal) {
            guard model.focusSearchWindowNumber == searchWindowNumber else { return }
            searchFocused = true
        }
    }

    private var showsStartupProgress: Bool {
        (accessState == .checking || (accessState == .granted && model.scanning))
            && model.total == 0 && model.results.isEmpty
    }

    private func refreshAccess(restartServicesIfDenied: Bool = false) {
        Task {
            let result = await model.refreshFullDiskAccess(
                restartServicesIfDenied: restartServicesIfDenied
            )
            switch result {
            case .granted: accessState = .granted
            case .denied: accessState = .denied
            case .backgroundApprovalRequired: accessState = .backgroundApprovalRequired
            case .serviceUnavailable: accessState = .serviceUnavailable
            }
        }
    }
}
