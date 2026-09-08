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
        public var termGroups: [[String]] = [[]]
        public var excludedTerms: [String] = []
        public var fileTypes: [String] = []
        public var directories: [String] = []
        public var sizes: [SizeConstraint] = []
        public var modified: [ModifiedConstraint] = []
        public var kind: FileKind?
        public var limit: Int?
        public var regularExpression: String?
        public var isValid = true

        var hasPositiveTerms: Bool { termGroups.contains { !$0.isEmpty } }
        var hasFilters: Bool {
            !excludedTerms.isEmpty || !fileTypes.isEmpty || !directories.isEmpty ||
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

    public var plan: Plan { Self.parse(text, regularExpressionMode: usesRegularExpression) }

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
        return parsed.isValid && !parsed.hasPositiveTerms && !parsed.hasFilters
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

    private static func parse(_ text: String, regularExpressionMode: Bool) -> Plan {
        if regularExpressionMode, !containsKnownCommand(in: text) {
            var plan = Plan()
            plan.regularExpression = text
            return plan
        }

        let tokens = tokenize(text)
        var plan = Plan()
        var group = 0
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let command = token.lowercased()
            guard slashCommands.contains(command) else {
                plan.termGroups[group].append(token)
                index += 1
                continue
            }

            if command == "/or" {
                guard !plan.termGroups[group].isEmpty else { plan.isValid = false; index += 1; continue }
                plan.termGroups.append([])
                group += 1
                index += 1
                continue
            }

            if command == "/regex" {
                let remainder = tokens.dropFirst(index + 1).joined(separator: " ")
                plan.regularExpression = remainder
                if remainder.isEmpty { plan.isValid = false }
                break
            }

            guard index + 1 < tokens.count else { plan.isValid = false; break }
            let argument = tokens[index + 1]
            switch command {
            case "/filetype":
                var extensions: [String] = []
                var cursor = index + 1
                while cursor < tokens.count, !slashCommands.contains(tokens[cursor].lowercased()) {
                    let value = tokens[cursor].trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    if !value.isEmpty { extensions.append(value) }
                    cursor += 1
                }
                plan.fileTypes.append(contentsOf: extensions)
                if extensions.isEmpty { plan.isValid = false }
                index = cursor
                continue
            case "/in":
                let path = expandPath(argument)
                if path.hasPrefix("/") { plan.directories.append(path) }
                else { plan.isValid = false }
            case "/limit":
                if let value = Int(argument), value > 0 { plan.limit = min(value, 10_000) }
                else { plan.isValid = false }
            case "/modified":
                if let value = parseModified(argument) { plan.modified.append(value) }
                else { plan.isValid = false }
            case "/not":
                plan.excludedTerms.append(argument)
            case "/size":
                if let value = parseSize(argument) { plan.sizes.append(value) }
                else { plan.isValid = false }
            case "/type":
                switch argument.lowercased() {
                case "file", "files": plan.kind = .file
                case "folder", "folders", "directory", "directories": plan.kind = .folder
                default: plan.isValid = false
                }
            default:
                break
            }
            index += 2
        }
        if plan.termGroups.count > 1, plan.termGroups.last?.isEmpty == true { plan.isValid = false }
        return plan
    }

    private static func containsKnownCommand(in text: String) -> Bool {
        tokenize(text).contains { slashCommands.contains($0.lowercased()) }
    }

    // Whitespace-separated tokens with quoted phrases kept as a single value.
    private static func tokenize(_ text: String) -> [String] {
        var output: [String] = []
        var current = ""
        var inQuote = false
        for character in text {
            if character == "\"" { inQuote.toggle(); continue }
            if character.isWhitespace && !inQuote {
                if !current.isEmpty { output.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { output.append(current) }
        return output
    }

    private static func expandPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded == "/" { return expanded }
        return expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
    }

    private static func parseSize(_ source: String) -> SizeConstraint? {
        if let separator = source.range(of: "..") {
            guard let lower = byteCount(String(source[..<separator.lowerBound])),
                  let upper = byteCount(String(source[separator.upperBound...])), lower <= upper else { return nil }
            return .range(lower, upper)
        }
        let operators: [(String, (UInt64) -> SizeConstraint)] = [
            (">=", SizeConstraint.atLeast), ("<=", SizeConstraint.atMost),
            (">", SizeConstraint.greaterThan), ("<", SizeConstraint.lessThan),
            ("=", SizeConstraint.exactly)
        ]
        for (prefix, make) in operators where source.hasPrefix(prefix) {
            return byteCount(String(source.dropFirst(prefix.count))).map(make)
        }
        return byteCount(source).map(SizeConstraint.exactly)
    }

    private static func byteCount(_ source: String) -> UInt64? {
        let lower = source.lowercased()
        let units: [(String, Double)] = [
            ("tb", 1_099_511_627_776), ("gb", 1_073_741_824),
            ("mb", 1_048_576), ("kb", 1_024), ("b", 1)
        ]
        let unit = units.first { lower.hasSuffix($0.0) }
        let numberText = unit.map { String(lower.dropLast($0.0.count)) } ?? lower
        guard let number = Double(numberText), number >= 0,
              number <= Double(UInt64.max) / (unit?.1 ?? 1) else { return nil }
        return UInt64(number * (unit?.1 ?? 1))
    }

    private static func parseModified(_ source: String, now: Date = Date()) -> ModifiedConstraint? {
        let calendar = Calendar.current
        let lower = source.lowercased()
        if lower == "today" {
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return .range(Int64(start.timeIntervalSince1970), Int64(end.timeIntervalSince1970) - 1)
        }
        if lower.hasSuffix("d"), let days = Int(lower.dropLast()), days >= 0,
           let start = calendar.date(byAdding: .day, value: -days, to: now) {
            return .since(Int64(start.timeIntervalSince1970))
        }
        if let separator = source.range(of: "..") {
            guard let start = parseDate(String(source[..<separator.lowerBound])),
                  let endDay = parseDate(String(source[separator.upperBound...])),
                  let end = calendar.date(byAdding: .day, value: 1, to: endDay), start <= endDay else { return nil }
            return .range(Int64(start.timeIntervalSince1970), Int64(end.timeIntervalSince1970) - 1)
        }
        guard let day = parseDate(source),
              let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
        return .range(Int64(day.timeIntervalSince1970), Int64(end.timeIntervalSince1970) - 1)
    }

    private static func parseDate(_ source: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: source)
    }
}

private extension Query.Plan {
    var hasFiltersExceptFileType: Bool {
        !excludedTerms.isEmpty || !directories.isEmpty || !sizes.isEmpty || !modified.isEmpty ||
            kind != nil || limit != nil || regularExpression != nil
    }
}
