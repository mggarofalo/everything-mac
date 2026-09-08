import Foundation

public struct Query: Sendable {
    public static let slashCommands = ["/filetype", "/regex"]

    public enum Expression: Equatable, Sendable {
        case terms([String])
        case fileTypes([String])
        case regularExpression(String)
    }

    public var text: String
    public var matchPath: Bool
    public var caseInsensitive: Bool
    // When true, each plain (non-wildcard) term must match as a whole word — bounded by
    // a non-alphanumeric character or a string edge — rather than as a loose substring.
    public var wholeWord: Bool
    public var usesRegularExpression: Bool

    public init(text: String, matchPath: Bool = false, caseInsensitive: Bool = true,
                wholeWord: Bool = false, usesRegularExpression: Bool = false) {
        self.text = text
        self.matchPath = matchPath
        self.caseInsensitive = caseInsensitive
        self.wholeWord = wholeWord
        self.usesRegularExpression = usesRegularExpression
    }

    /// Slash commands are recognized only at the beginning of the field. Regex
    /// consumes the remainder verbatim; filetype consumes space-separated extensions.
    public var expression: Expression {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let remainder = Self.commandRemainder("/regex", in: trimmed) {
            return .regularExpression(remainder)
        }
        if let remainder = Self.commandRemainder("/filetype", in: trimmed) {
            let extensions = remainder.split(whereSeparator: { $0.isWhitespace }).map {
                String($0).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }.filter { !$0.isEmpty }
            return .fileTypes(extensions)
        }
        if usesRegularExpression { return .regularExpression(text) }
        return .terms(Self.parseTerms(text))
    }

    public var terms: [String] {
        guard case .terms(let terms) = expression else { return [] }
        return terms
    }

    /// Only an ordinary query with no terms is truly unconstrained. Slash
    /// commands may expose no `terms`, but still need the component index for
    /// their optimized implementations.
    public var isUnconstrained: Bool {
        guard case .terms(let terms) = expression else { return false }
        return terms.isEmpty
    }

    /// True while the user is typing the name of a known slash command, before
    /// its separating space. The app uses this to show
    /// completions without launching a search for `/`, `/f`, and similar input.
    public var isSlashCommandPrefix: Bool {
        !matchingSlashCommands.isEmpty
    }

    public var matchingSlashCommands: [String] {
        guard text.hasPrefix("/"), !text.contains(where: { $0.isWhitespace }) else { return [] }
        let prefix = text.lowercased()
        return Self.slashCommands.filter { $0.hasPrefix(prefix) }
    }

    /// A trailing space makes the completed command immediately ready for its
    /// argument. Ambiguous prefixes intentionally have no completion.
    public var slashCommandCompletion: String? {
        guard matchingSlashCommands.count == 1, let command = matchingSlashCommands.first else {
            return nil
        }
        return command + " "
    }

    private static func commandRemainder(_ command: String, in text: String) -> String? {
        guard text.count >= command.count,
              String(text.prefix(command.count)).caseInsensitiveCompare(command) == .orderedSame else {
            return nil
        }
        let boundary = text.index(text.startIndex, offsetBy: command.count)
        guard boundary == text.endIndex || text[boundary].isWhitespace else { return nil }
        return String(text[boundary...]).trimmingCharacters(in: .whitespaces)
    }

    // Whitespace-separated terms; quoted phrases kept intact.
    private static func parseTerms(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        for ch in text {
            if ch == "\"" { inQuote.toggle(); continue }
            if ch == " " && !inQuote {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
