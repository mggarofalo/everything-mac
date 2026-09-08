import SwiftUI

struct SearchField: View {
    @Binding var text: String
    @Binding var matchPath: Bool
    @Binding var caseSensitive: Bool
    @Binding var wholeWord: Bool
    @Binding var usesRegularExpression: Bool
    var focused: FocusState<Bool>.Binding
    var onTextChange: () -> Void
    var onOptionsChange: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search everything…", text: $text)
                .textFieldStyle(.plain).font(.system(size: 15))
                .focused(focused)
                .onChange(of: text) { onTextChange() }
            Menu {
                Toggle("Match Path", isOn: $matchPath)
                Toggle("Match Case", isOn: $caseSensitive)
                Toggle("Match Whole Word", isOn: $wholeWord)
                    .disabled(usesRegularExpression)
                Divider()
                Toggle("Regular Expression", isOn: $usesRegularExpression)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .accessibilityLabel("Search Options")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Search Options")
            .onChange(of: matchPath) { onOptionsChange() }
            .onChange(of: caseSensitive) { onOptionsChange() }
            .onChange(of: wholeWord) { onOptionsChange() }
            .onChange(of: usesRegularExpression) { onOptionsChange() }
        }
        .padding(8)
    }
}
