import Foundation

public struct Query: Sendable {
    public static let slashCommands = [
        "/filetype", "/in", "/limit", "/modified", "/not", "/or", "/regex", "/size", "/type"
    ]

    public enum Expression: Equatable, Sendable {
        case terms([String])
        case fileTypes([String])
        case regularExpression(String)
    }

    public indirect enum FilterExpression: Equatable, Sendable {
        case predicate(Predicate)
        case and([FilterExpression])
        case or([FilterExpression])
        case xor(FilterExpression, FilterExpression)
        case not(FilterExpression)
    }

    public enum Predicate: Equatable, Sendable {
        case all
        case text(String)
        case path(String)
        case directory(String)
        case fileTypes([String])
        case regularExpression(String)
        case kind(FileKind)
        case size(SizeConstraint)
        case modified(ModifiedConstraint)
    }

    public enum FileKind: Equatable, Sendable { case file, folder }

    public enum SizeConstraint: Equatable, Sendable {
        case lessThan(UInt64)
        case atMost(UInt64)
        case exactly(UInt64)
        case atLeast(UInt64)
        case greaterThan(UInt64)
        case range(UInt64, UInt64)

        func contains(_ value: UInt64) -> Bool {
            switch self {
            case .lessThan(let bound): return value < bound
            case .atMost(let bound): return value <= bound
            case .exactly(let bound): return value == bound
            case .atLeast(let bound): return value >= bound
            case .greaterThan(let bound): return value > bound
            case .range(let lower, let upper): return lower...upper ~= value
            }
        }
    }

    public enum ModifiedConstraint: Equatable, Sendable {
        case since(Int64)
        case range(Int64, Int64)

        func contains(_ value: Int64) -> Bool {
            switch self {
            case .since(let lower): return value >= lower
            case .range(let lower, let upper): return lower...upper ~= value
            }
        }
    }

    public struct Plan: Equatable, Sendable {
        public var filterExpression: FilterExpression?
        public var termGroups: [[String]] = [[]]
        public var excludedTerms: [String] = []
        public var fileTypes: [String] = []
        public var alternativeFileTypes: [Int: [String]] = [:]
        public var directories: [String] = []
        public var sizes: [SizeConstraint] = []
        public var modified: [ModifiedConstraint] = []
        public var kind: FileKind?
        public var limit: Int?
        public var regularExpression: String?
        public var isValid = true
        public var validationMessage: String?

        var hasPositiveTerms: Bool { termGroups.contains { !$0.isEmpty } }
        var hasAlternativeMatchers: Bool {
            hasPositiveTerms || !alternativeFileTypes.isEmpty
        }
        var hasFilters: Bool {
            !excludedTerms.isEmpty || !fileTypes.isEmpty || !alternativeFileTypes.isEmpty || !directories.isEmpty ||
                !sizes.isEmpty || !modified.isEmpty || kind != nil || regularExpression != nil
        }
    }

    public var text: String
    public var matchPath: Bool
    public var caseInsensitive: Bool
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

    public var plan: Plan { QueryParser.parse(self) }

    // Compact compatibility representation used by callers that only need one expression.
    public var expression: Expression {
        let parsed = plan
        if let pattern = parsed.regularExpression { return .regularExpression(pattern) }
        if !parsed.fileTypes.isEmpty, !parsed.hasPositiveTerms, !parsed.hasFiltersExceptFileType {
            return .fileTypes(parsed.fileTypes)
        }
        return .terms(parsed.termGroups.flatMap { $0 })
    }

    public var terms: [String] { plan.termGroups.flatMap { $0 } }

    public var isUnconstrained: Bool {
        let parsed = plan
        if let expression = parsed.filterExpression {
            return parsed.isValid && expression == .predicate(.all)
        }
        return parsed.isValid && !parsed.hasAlternativeMatchers && !parsed.hasFilters
    }

    public var isSlashCommandPrefix: Bool { !matchingSlashCommands.isEmpty }

    public var requestedLimit: Int? { plan.limit }

    /// Matches the slash-prefixed token currently being typed, including after
    /// ordinary text so commands can be composed in one field.
    public var matchingSlashCommands: [String] {
        guard text.last.map({ !$0.isWhitespace }) == true,
              let token = text.split(whereSeparator: { $0.isWhitespace }).last,
              !token.isEmpty, token.hasPrefix("/") else { return [] }
        let prefix = token.lowercased()
        return Self.slashCommands.filter { $0.hasPrefix(prefix) }
    }

    /// Replaces only the active token and preserves any commands or text before it.
    public var slashCommandCompletion: String? {
        guard matchingSlashCommands.count == 1, let command = matchingSlashCommands.first else { return nil }
        guard let split = text.lastIndex(where: { $0.isWhitespace }) else { return command + " " }
        return String(text[...split]) + command + " "
    }

}

private extension Query.Plan {
    var hasFiltersExceptFileType: Bool {
        !excludedTerms.isEmpty || !directories.isEmpty || !sizes.isEmpty || !modified.isEmpty ||
            kind != nil || limit != nil || regularExpression != nil
    }
}
