import SwiftUI
import IndexCore

struct SearchField: View {
    private struct SlashCommand: Identifiable {
        let command: String
        let description: String
        var id: String { command }
    }

    private static let slashCommands = [
        SlashCommand(command: "/filetype", description: "Find one or more file extensions"),
        SlashCommand(command: "/regex", description: "Search with a regular expression")
    ]

    @Binding var text: String
    @Binding var matchPath: Bool
    @Binding var caseSensitive: Bool
    @Binding var wholeWord: Bool
    @Binding var usesRegularExpression: Bool
    var focused: FocusState<Bool>.Binding
    var onTextChange: () -> Void
    var onOptionsChange: () -> Void
    @State private var showsSlashCommands = false

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search everything…", text: $text)
                .textFieldStyle(.plain).font(.system(size: 15))
                .focused(focused)
                .onChange(of: text) {
                    onTextChange()
                    showsSlashCommands = !matchingSlashCommands.isEmpty
                }
                .onKeyPress(.tab) {
                    let query = Query(text: text)
                    guard query.isSlashCommandPrefix else { return .ignored }
                    if let completion = query.slashCommandCompletion {
                        text = completion
                        showsSlashCommands = false
                    }
                    return .handled
                }
                .popover(isPresented: $showsSlashCommands, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Slash Commands")
                            .font(.headline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        Divider()
                        ForEach(matchingSlashCommands) { suggestion in
                            Button {
                                accept(suggestion)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(suggestion.command)
                                        .font(.system(.body, design: .monospaced))
                                    Text(suggestion.description)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 390)
                    .padding(.vertical, 4)
                }
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

    private var matchingSlashCommands: [SlashCommand] {
        let matching = Set(Query(text: text).matchingSlashCommands)
        return Self.slashCommands.filter { matching.contains($0.command) }
    }

    private func accept(_ suggestion: SlashCommand) {
        text = suggestion.command + " "
        showsSlashCommands = false
        focused.wrappedValue = true
    }
}
