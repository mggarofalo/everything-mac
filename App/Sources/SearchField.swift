import SwiftUI
import IndexCore

struct SearchField: View {
    private struct Suggestion: Identifiable {
        let insertion: String
        let description: String
        var id: String { insertion }
    }

    private static let suggestions = [
        Suggestion(insertion: "in:", description: "restrict to a folder subtree"),
        Suggestion(insertion: "filetype:", description: "match extensions; comma-separate values"),
        Suggestion(insertion: "name:", description: "match filename text"),
        Suggestion(insertion: "path:", description: "match full-path text"),
        Suggestion(insertion: "regex:", description: "match a regular expression"),
        Suggestion(insertion: "size:", description: "for example >100mb or 1mb..1gb"),
        Suggestion(insertion: "modified:", description: "today, 7d, or DATE..DATE"),
        Suggestion(insertion: "type:file", description: "files only"),
        Suggestion(insertion: "type:folder", description: "folders only"),
        Suggestion(insertion: "limit:", description: "return at most N results"),
        Suggestion(insertion: "AND", description: "both expressions must match"),
        Suggestion(insertion: "OR", description: "either expression may match"),
        Suggestion(insertion: "XOR", description: "exactly one expression must match"),
        Suggestion(insertion: "NOT", description: "exclude the following expression")
    ]

    @Binding var text: String
    @Binding var matchPath: Bool
    @Binding var caseSensitive: Bool
    @Binding var wholeWord: Bool
    var focused: FocusState<Bool>.Binding
    var onTextChange: () -> Void
    var onOptionsChange: () -> Void
    @State private var showsSuggestions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                QueryTextField(text: $text, focused: focused,
                               onTextChange: textChanged,
                               onTab: complete)
                    .frame(height: 26)
                    .popover(isPresented: $showsSuggestions, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Filters and Operators")
                                .font(.headline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            Divider()
                            ForEach(matchingSuggestions) { suggestion in
                                Button { accept(suggestion) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(suggestion.insertion)
                                            .font(.system(.body, design: .monospaced))
                                        Text(suggestion.description)
                                            .foregroundStyle(.secondary)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                }
                                .buttonStyle(.plain)
                            }
                            Divider()
                            Text("Spaces mean AND. Use parentheses to group expressions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .frame(width: 460)
                        .padding(.vertical, 4)
                    }
                Menu {
                    Toggle("Match Path", isOn: $matchPath)
                    Toggle("Match Case", isOn: $caseSensitive)
                    Toggle("Match Whole Word", isOn: $wholeWord)
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
            }
            .padding(8)
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
    }

    private var validationMessage: String? { Query(text: text).plan.validationMessage }

    private var matchingSuggestions: [Suggestion] {
        guard let range = activeTokenRange(in: text, cursor: (text as NSString).length) else {
            return []
        }
        return suggestions(matching: (text as NSString).substring(with: range),
                           in: text, activeRange: range)
    }

    private func textChanged() {
        onTextChange()
        showsSuggestions = !matchingSuggestions.isEmpty
    }

    private func complete(_ source: String, _ selection: NSRange) -> String? {
        guard selection.length == 0,
              selection.location == (source as NSString).length,
              let range = activeTokenRange(in: source, cursor: selection.location) else { return nil }
        let token = (source as NSString).substring(with: range).lowercased()
        let matches = suggestions(matching: token, in: source, activeRange: range)
        guard !token.isEmpty, let suggestion = matches.first else { return nil }
        return replacing(range, in: source, with: completedInsertion(suggestion))
    }

    private func accept(_ suggestion: Suggestion) {
        guard let range = activeTokenRange(in: text, cursor: (text as NSString).length) else { return }
        text = replacing(range, in: text, with: completedInsertion(suggestion))
        showsSuggestions = false
        focused.wrappedValue = true
        onTextChange()
    }

    private func completedInsertion(_ suggestion: Suggestion) -> String {
        suggestion.insertion.hasSuffix(":") ? suggestion.insertion : suggestion.insertion + " "
    }

    private func replacing(_ range: NSRange, in source: String, with replacement: String) -> String {
        (source as NSString).replacingCharacters(in: range, with: replacement)
    }

    private func activeTokenRange(in source: String, cursor: Int) -> NSRange? {
        let string = source as NSString
        guard cursor <= string.length else { return nil }
        let delimiters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()"))
        var start = cursor
        while start > 0, let scalar = UnicodeScalar(string.character(at: start - 1)),
              !delimiters.contains(scalar) { start -= 1 }
        var end = cursor
        while end < string.length, let scalar = UnicodeScalar(string.character(at: end)),
              !delimiters.contains(scalar) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private func suggestionRank(_ suggestion: Suggestion, needle: String) -> Int {
        let insertion = suggestion.insertion.lowercased()
        if insertion == needle { return 0 }
        if insertion.hasPrefix(needle) { return 1 }
        if insertion.contains(needle) { return 2 }
        return 3
    }

    private func suggestions(matching token: String, in source: String,
                             activeRange: NSRange) -> [Suggestion] {
        let needle = token.lowercased()
        guard !needle.isEmpty, !needle.contains("/") else { return [] }
        let prefix = (source as NSString).substring(to: activeRange.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectsOperand = prefix.isEmpty || prefix.hasSuffix("(") ||
            ["AND", "OR", "XOR", "NOT"].contains {
                prefix.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) == $0
            }
        return Self.suggestions.filter { suggestion in
            guard suggestion.insertion.lowercased().contains(needle) else { return false }
            if expectsOperand, ["AND", "OR", "XOR"].contains(suggestion.insertion) {
                return false
            }
            return true
        }.sorted {
            suggestionRank($0, needle: needle) < suggestionRank($1, needle: needle)
        }
    }
}
