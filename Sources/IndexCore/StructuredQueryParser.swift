import Foundation

enum StructuredQueryParser {
    private enum Token: Equatable {
        case word(String)
        case and
        case or
        case xor
        case not
        case leftParenthesis
        case rightParenthesis
    }

    private static let filterNames = Set([
        "name", "path", "in", "filetype", "ext", "regex", "rx",
        "type", "size", "modified", "limit"
    ])

    static func shouldParse(_ source: String) -> Bool {
        let tokens = tokenize(source)
        return tokens.contains { token in
            switch token {
            case .and, .or, .xor, .not, .leftParenthesis, .rightParenthesis:
                return true
            case .word(let word):
                guard let colon = word.firstIndex(of: ":") else { return false }
                let name = word[..<colon]
                return !name.isEmpty && name.allSatisfy { $0.isLetter || $0 == "-" }
            }
        }
    }

    static func parse(_ source: String) -> Query.Plan {
        if source.filter({ $0 == "\"" }).count.isMultiple(of: 2) == false {
            var plan = Query.Plan()
            plan.isValid = false
            plan.validationMessage = "Missing closing quote."
            return plan
        }
        var parser = Parser(tokens: tokenize(source))
        return parser.parse()
    }

    private static func tokenize(_ source: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var quoted = false
        var wordWasQuoted = false

        func finishWord() {
            guard !current.isEmpty else { return }
            if !wordWasQuoted {
                switch current {
                case "AND": tokens.append(.and)
                case "OR": tokens.append(.or)
                case "XOR": tokens.append(.xor)
                case "NOT": tokens.append(.not)
                default: tokens.append(.word(current))
                }
            } else {
                tokens.append(.word(current))
            }
            current = ""
            wordWasQuoted = false
        }

        for character in source {
            if character == "\"" {
                quoted.toggle()
                wordWasQuoted = true
            } else if !quoted, character.isWhitespace {
                finishWord()
            } else if !quoted, character == "(" {
                finishWord()
                tokens.append(.leftParenthesis)
            } else if !quoted, character == ")" {
                finishWord()
                tokens.append(.rightParenthesis)
            } else {
                current.append(character)
            }
        }
        finishWord()
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0
        var plan = Query.Plan()

        mutating func parse() -> Query.Plan {
            guard !tokens.isEmpty else {
                plan.filterExpression = .predicate(.all)
                return plan
            }
            plan.filterExpression = removingDirectives(from: parseOr())
            if plan.isValid, index < tokens.count {
                invalidate("Unexpected token \(description(of: tokens[index])).")
            }
            if plan.filterExpression == nil, plan.isValid {
                plan.filterExpression = .predicate(.all)
            }
            return plan
        }

        func removingDirectives(
            from expression: Query.FilterExpression?
        ) -> Query.FilterExpression? {
            guard let expression else { return nil }
            switch expression {
            case .predicate(.all):
                return nil
            case .predicate:
                return expression
            case .and(let expressions):
                let children = expressions.compactMap { removingDirectives(from: $0) }
                if children.isEmpty { return nil }
                return children.count == 1 ? children[0] : .and(children)
            case .or(let expressions):
                let children = expressions.compactMap { removingDirectives(from: $0) }
                if children.isEmpty { return nil }
                return children.count == 1 ? children[0] : .or(children)
            case .xor(let left, let right):
                let filteredLeft = removingDirectives(from: left)
                let filteredRight = removingDirectives(from: right)
                switch (filteredLeft, filteredRight) {
                case let (.some(left), .some(right)): return .xor(left, right)
                case let (.some(expression), nil), let (nil, .some(expression)): return expression
                case (nil, nil): return nil
                }
            case .not(let child):
                return removingDirectives(from: child).map(Query.FilterExpression.not)
            }
        }

        mutating func parseOr() -> Query.FilterExpression? {
            guard var expression = parseXor() else { return nil }
            var alternatives = [expression]
            while consume(.or) {
                guard let right = parseXor() else {
                    invalidate("OR needs an expression on both sides.")
                    return expression
                }
                alternatives.append(right)
            }
            if alternatives.count > 1 { expression = .or(alternatives) }
            return expression
        }

        mutating func parseXor() -> Query.FilterExpression? {
            guard var expression = parseAnd() else { return nil }
            while consume(.xor) {
                guard let right = parseAnd() else {
                    invalidate("XOR needs an expression on both sides.")
                    return expression
                }
                expression = .xor(expression, right)
            }
            return expression
        }

        mutating func parseAnd() -> Query.FilterExpression? {
            guard let first = parseUnary() else { return nil }
            var expressions = [first]
            while index < tokens.count {
                if consume(.and) {
                    guard let right = parseUnary() else {
                        invalidate("AND needs an expression on both sides.")
                        break
                    }
                    expressions.append(right)
                    continue
                }
                guard beginsExpression(tokens[index]) else { break }
                guard let implicit = parseUnary() else { break }
                expressions.append(implicit)
            }
            let meaningful = expressions.filter { $0 != .predicate(.all) }
            if meaningful.isEmpty { return .predicate(.all) }
            return meaningful.count == 1 ? meaningful[0] : .and(meaningful)
        }

        mutating func parseUnary() -> Query.FilterExpression? {
            if consume(.not) {
                guard let expression = parseUnary() else {
                    invalidate("NOT needs an expression after it.")
                    return nil
                }
                return .not(expression)
            }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Query.FilterExpression? {
            guard index < tokens.count else { return nil }
            switch tokens[index] {
            case .leftParenthesis:
                index += 1
                guard let expression = parseOr() else {
                    invalidate("Parentheses cannot be empty.")
                    return nil
                }
                guard consume(.rightParenthesis) else {
                    invalidate("Missing closing parenthesis.")
                    return expression
                }
                return expression
            case .word(let word):
                index += 1
                return predicate(for: word)
            case .rightParenthesis:
                return nil
            case .and, .or, .xor:
                invalidate("\(description(of: tokens[index])) needs an expression on both sides.")
                index += 1
                return nil
            case .not:
                return nil
            }
        }

        mutating func predicate(for word: String) -> Query.FilterExpression {
            guard let colon = word.firstIndex(of: ":") else {
                return .predicate(.text(word))
            }
            let name = String(word[..<colon]).lowercased()
            let value = String(word[word.index(after: colon)...])
            guard filterNames.contains(name) else {
                invalidate("Unknown filter \(name):. Type part of a filter name to see suggestions.")
                return .predicate(.all)
            }
            guard !value.isEmpty else {
                invalidate("\(name): needs a value.")
                return .predicate(.all)
            }

            switch name {
            case "name":
                return .predicate(.text(value))
            case "path":
                return .predicate(.path(value))
            case "in":
                let path = expandPath(value)
                guard path.hasPrefix("/") else {
                    invalidate("in: expects an absolute path or one beginning with ~.")
                    return .predicate(.all)
                }
                return .predicate(.directory(path))
            case "filetype", "ext":
                let extensions = value.split(separator: ",", omittingEmptySubsequences: false).map {
                    String($0).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                }
                guard !extensions.contains(where: { $0.isEmpty }) else {
                    invalidate("filetype: expects comma-separated extensions, such as md,docx.")
                    return .predicate(.all)
                }
                return .predicate(.fileTypes(extensions))
            case "regex", "rx":
                do {
                    _ = try NSRegularExpression(pattern: value)
                    return .predicate(.regularExpression(value))
                } catch {
                    invalidate("Invalid regular expression: \(error.localizedDescription)")
                    return .predicate(.all)
                }
            case "type":
                switch value.lowercased() {
                case "file", "files": return .predicate(.kind(.file))
                case "folder", "folders", "directory", "directories":
                    return .predicate(.kind(.folder))
                default:
                    invalidate("type: expects file or folder.")
                    return .predicate(.all)
                }
            case "size":
                guard let constraint = parseSize(value) else {
                    invalidate("size: expects bytes such as >100mb or 1mb..1gb.")
                    return .predicate(.all)
                }
                return .predicate(.size(constraint))
            case "modified":
                guard let constraint = parseModified(value) else {
                    invalidate("modified: expects today, Nd, DATE, or DATE..DATE.")
                    return .predicate(.all)
                }
                return .predicate(.modified(constraint))
            case "limit":
                guard let limit = Int(value), limit > 0 else {
                    invalidate("limit: expects a positive number.")
                    return .predicate(.all)
                }
                plan.limit = min(limit, 10_000)
                return .predicate(.all)
            default:
                return .predicate(.text(word))
            }
        }

        func beginsExpression(_ token: Token) -> Bool {
            switch token {
            case .word, .not, .leftParenthesis: return true
            default: return false
            }
        }

        mutating func consume(_ token: Token) -> Bool {
            guard index < tokens.count, tokens[index] == token else { return false }
            index += 1
            return true
        }

        mutating func invalidate(_ message: String) {
            plan.isValid = false
            if plan.validationMessage == nil { plan.validationMessage = message }
        }

        func description(of token: Token) -> String {
            switch token {
            case .word(let word): return word
            case .and: return "AND"
            case .or: return "OR"
            case .xor: return "XOR"
            case .not: return "NOT"
            case .leftParenthesis: return "("
            case .rightParenthesis: return ")"
            }
        }

        func expandPath(_ path: String) -> String {
            let expanded = (path as NSString).expandingTildeInPath
            if expanded == "/" { return expanded }
            return expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
        }

        func parseSize(_ source: String) -> Query.SizeConstraint? {
            if let separator = source.range(of: "..") {
                guard let lower = byteCount(String(source[..<separator.lowerBound])),
                      let upper = byteCount(String(source[separator.upperBound...])),
                      lower <= upper else { return nil }
                return .range(lower, upper)
            }
            let operators: [(String, (UInt64) -> Query.SizeConstraint)] = [
                (">=", Query.SizeConstraint.atLeast), ("<=", Query.SizeConstraint.atMost),
                (">", Query.SizeConstraint.greaterThan), ("<", Query.SizeConstraint.lessThan),
                ("=", Query.SizeConstraint.exactly)
            ]
            for (prefix, make) in operators where source.hasPrefix(prefix) {
                return byteCount(String(source.dropFirst(prefix.count))).map(make)
            }
            return byteCount(source).map(Query.SizeConstraint.exactly)
        }

        func byteCount(_ source: String) -> UInt64? {
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

        func parseModified(_ source: String, now: Date = Date()) -> Query.ModifiedConstraint? {
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
                      let end = calendar.date(byAdding: .day, value: 1, to: endDay),
                      start <= endDay else { return nil }
                return .range(Int64(start.timeIntervalSince1970), Int64(end.timeIntervalSince1970) - 1)
            }
            guard let day = parseDate(source),
                  let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            return .range(Int64(day.timeIntervalSince1970), Int64(end.timeIntervalSince1970) - 1)
        }

        func parseDate(_ source: String) -> Date? {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = Calendar.current.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            return formatter.date(from: source)
        }
    }
}
