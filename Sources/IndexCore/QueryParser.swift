import Foundation

/// Selects the query syntax and produces the execution plan used by `QueryEngine`.
enum QueryParser {
    static func parse(_ query: Query) -> Query.Plan {
        if StructuredQueryParser.shouldParse(query.text) {
            return StructuredQueryParser.parse(query.text)
        }
        if query.usesRegularExpression,
           !SlashCommandQueryParser.containsCommand(in: query.text) {
            var plan = Query.Plan()
            plan.regularExpression = query.text
            return plan
        }
        return SlashCommandQueryParser.parse(query.text)
    }
}

/// Parses the compact slash-command syntax while retaining ordinary search terms.
private enum SlashCommandQueryParser {
    static func containsCommand(in source: String) -> Bool {
        tokens(in: source).contains { Query.slashCommands.contains($0.lowercased()) }
    }

    static func parse(_ source: String) -> Query.Plan {
        let input = tokens(in: source)
        var plan = Query.Plan()
        var group = 0
        var index = 0

        while index < input.count {
            let token = input[index]
            let command = token.lowercased()
            guard Query.slashCommands.contains(command) else {
                if token.hasPrefix("/") {
                    invalidate(&plan, "Unknown command \(token). Type / to see available commands.")
                }
                plan.termGroups[group].append(token)
                index += 1
                continue
            }

            if command == "/or" {
                beginAlternative(in: &plan, group: &group)
                index += 1
                continue
            }

            if command == "/regex" {
                let pattern = input.dropFirst(index + 1).joined(separator: " ")
                plan.regularExpression = pattern
                if group > 0 {
                    invalidate(&plan, "/regex cannot be used as an /or alternative.")
                } else if pattern.isEmpty {
                    invalidate(&plan, "/regex needs a pattern and must be last.")
                }
                break
            }

            guard index + 1 < input.count else {
                invalidate(&plan, "\(command) needs one argument.")
                break
            }
            apply(command, argument: input[index + 1], group: group, to: &plan)
            index += 2
        }

        if plan.termGroups.count > 1,
           plan.termGroups.last?.isEmpty == true,
           plan.alternativeFileTypes[plan.termGroups.count - 1] == nil {
            invalidate(&plan, "/or needs a search expression on both sides.")
        }
        return plan
    }

    private static func beginAlternative(in plan: inout Query.Plan, group: inout Int) {
        if group == 0, plan.termGroups[0].isEmpty, !plan.fileTypes.isEmpty {
            plan.alternativeFileTypes[0] = plan.fileTypes
            plan.fileTypes = []
        }
        guard !plan.termGroups[group].isEmpty || plan.alternativeFileTypes[group] != nil else {
            invalidate(&plan, "/or needs a search expression on both sides.")
            return
        }
        plan.termGroups.append([])
        group += 1
    }

    private static func apply(
        _ command: String,
        argument: String,
        group: Int,
        to plan: inout Query.Plan
    ) {
        switch command {
        case "/filetype": applyFileTypes(argument, group: group, to: &plan)
        case "/in": applyDirectory(argument, to: &plan)
        case "/limit": applyLimit(argument, to: &plan)
        case "/modified": applyModified(argument, to: &plan)
        case "/not":
            plan.excludedTerms.append(argument)
        case "/size": applySize(argument, to: &plan)
        case "/type": applyKind(argument, to: &plan)
        default:
            break
        }
    }

    private static func applyFileTypes(_ argument: String, group: Int,
                                       to plan: inout Query.Plan) {
        guard let extensions = QueryValueParser.fileTypes(argument) else {
            invalidate(&plan, "/filetype expects comma-separated extensions, such as md,docx.")
            return
        }
        if group > 0, plan.termGroups[group].isEmpty {
            plan.alternativeFileTypes[group, default: []].append(contentsOf: extensions)
        } else {
            plan.fileTypes.append(contentsOf: extensions)
        }
    }

    private static func applyDirectory(_ argument: String, to plan: inout Query.Plan) {
        guard let path = QueryValueParser.absolutePath(argument) else {
            invalidate(&plan, "/in expects an absolute path or one beginning with ~.")
            return
        }
        plan.directories.append(path)
    }

    private static func applyLimit(_ argument: String, to plan: inout Query.Plan) {
        guard let limit = QueryValueParser.limit(argument) else {
            invalidate(&plan, "/limit expects a positive number.")
            return
        }
        plan.limit = limit
    }

    private static func applyModified(_ argument: String, to plan: inout Query.Plan) {
        guard let constraint = QueryValueParser.modified(argument) else {
            invalidate(&plan, "/modified expects today, Nd, DATE, or DATE..DATE.")
            return
        }
        plan.modified.append(constraint)
    }

    private static func applySize(_ argument: String, to plan: inout Query.Plan) {
        guard let constraint = QueryValueParser.size(argument) else {
            invalidate(&plan, "/size expects bytes such as >100mb or 1mb..1gb.")
            return
        }
        plan.sizes.append(constraint)
    }

    private static func applyKind(_ argument: String, to plan: inout Query.Plan) {
        guard let kind = QueryValueParser.fileKind(argument) else {
            invalidate(&plan, "/type expects file or folder.")
            return
        }
        plan.kind = kind
    }

    private static func invalidate(_ plan: inout Query.Plan, _ message: String) {
        plan.isValid = false
        if plan.validationMessage == nil { plan.validationMessage = message }
    }

    /// Whitespace-separated tokens with quoted phrases kept as a single value.
    private static func tokens(in source: String) -> [String] {
        var output: [String] = []
        var current = ""
        var isQuoted = false
        for character in source {
            if character == "\"" {
                isQuoted.toggle()
            } else if character.isWhitespace && !isQuoted {
                if !current.isEmpty {
                    output.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { output.append(current) }
        return output
    }
}

/// Shared value grammar for both supported query syntaxes.
enum QueryValueParser {
    static func absolutePath(_ source: String) -> String? {
        let expanded = (source as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        if expanded == "/" { return expanded }
        return expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
    }

    static func fileTypes(_ source: String) -> [String]? {
        let values = source.split(separator: ",", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return values.isEmpty || values.contains(where: \.isEmpty) ? nil : values
    }

    static func fileKind(_ source: String) -> Query.FileKind? {
        switch source.lowercased() {
        case "file", "files": return .file
        case "folder", "folders", "directory", "directories": return .folder
        default: return nil
        }
    }

    static func limit(_ source: String) -> Int? {
        guard let value = Int(source), value > 0 else { return nil }
        return min(value, 10_000)
    }

    static func size(_ source: String) -> Query.SizeConstraint? {
        if let separator = source.range(of: "..") {
            guard let lower = byteCount(String(source[..<separator.lowerBound])),
                  let upper = byteCount(String(source[separator.upperBound...])),
                  lower <= upper else { return nil }
            return .range(lower, upper)
        }
        let operators: [(String, (UInt64) -> Query.SizeConstraint)] = [
            (">=", Query.SizeConstraint.atLeast), ("<=", Query.SizeConstraint.atMost),
            (">", Query.SizeConstraint.greaterThan), ("<", Query.SizeConstraint.lessThan),
            ("=", Query.SizeConstraint.exactly),
        ]
        for (prefix, makeConstraint) in operators where source.hasPrefix(prefix) {
            return byteCount(String(source.dropFirst(prefix.count))).map(makeConstraint)
        }
        return byteCount(source).map(Query.SizeConstraint.exactly)
    }

    static func modified(_ source: String, now: Date = Date()) -> Query.ModifiedConstraint? {
        let calendar = Calendar.current
        let lowercased = source.lowercased()
        if lowercased == "today" {
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return .range(Int64(start.timeIntervalSince1970), Int64(end.timeIntervalSince1970) - 1)
        }
        if lowercased.hasSuffix("d"),
           let days = Int(lowercased.dropLast()), days >= 0,
           let start = calendar.date(byAdding: .day, value: -days, to: now) {
            return .since(Int64(start.timeIntervalSince1970))
        }
        if let separator = source.range(of: "..") {
            guard let start = date(String(source[..<separator.lowerBound])),
                  let endDay = date(String(source[separator.upperBound...])),
                  let end = calendar.date(byAdding: .day, value: 1, to: endDay),
                  start <= endDay else { return nil }
            return .range(Int64(start.timeIntervalSince1970), Int64(end.timeIntervalSince1970) - 1)
        }
        guard let day = date(source),
              let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
        return .range(Int64(day.timeIntervalSince1970), Int64(end.timeIntervalSince1970) - 1)
    }

    private static func byteCount(_ source: String) -> UInt64? {
        let lowercased = source.lowercased()
        let units: [(String, Double)] = [
            ("tb", 1_099_511_627_776), ("gb", 1_073_741_824),
            ("mb", 1_048_576), ("kb", 1_024), ("b", 1),
        ]
        let unit = units.first { lowercased.hasSuffix($0.0) }
        let numberText = unit.map { String(lowercased.dropLast($0.0.count)) } ?? lowercased
        guard let number = Double(numberText), number >= 0,
              number <= Double(UInt64.max) / (unit?.1 ?? 1) else { return nil }
        return UInt64(number * (unit?.1 ?? 1))
    }

    private static func date(_ source: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: source)
    }
}
