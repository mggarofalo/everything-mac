import SwiftUI
import IndexCore

struct SearchField: View {
    private struct SlashCommand: Identifiable {
        let command: String
        let description: String
        var id: String { command }
    }

    private static let slashCommands = [
        SlashCommand(command: "/filetype", description: "EXT[,EXT…] — match extensions"),
        SlashCommand(command: "/in", description: "~/Folder — restrict to a subtree"),
        SlashCommand(command: "/limit", description: "N — return at most N results"),
        SlashCommand(command: "/modified", description: "today, 7d, or DATE..DATE"),
        SlashCommand(command: "/not", description: "TERM — exclude name or path text"),
        SlashCommand(command: "/or", description: "match either side"),
        SlashCommand(command: "/regex", description: "PATTERN — regular expression; use last"),
        SlashCommand(command: "/size", description: ">100mb or 1mb..1gb"),
        SlashCommand(command: "/type", description: "file|folder — restrict result kind")
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
                        if matchingSlashCommands.count == Self.slashCommands.count {
                            Divider()
                            Text("Each command takes one argument; comma-separate file types.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                    }
                    .frame(width: 440)
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
        let prefix = text.lastIndex(where: { $0.isWhitespace }).map { String(text[...$0]) } ?? ""
        text = prefix + suggestion.command + " "
        showsSlashCommands = false
        focused.wrappedValue = true
    }
}
