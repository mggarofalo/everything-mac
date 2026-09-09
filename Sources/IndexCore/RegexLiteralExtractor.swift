/// Finds literal text that every match of a regular expression must contain.
///
/// The extractor intentionally supports a conservative subset. Returning `nil`
/// only disables an index optimization; it never changes matching semantics.
enum RegexLiteralExtractor {
    static func requiredLiteral(in pattern: String) -> String? {
        guard !hasUnescaped(pattern, anyOf: "|()") else { return nil }
        var parser = Parser(characters: Array(pattern))
        return parser.requiredLiteral()
    }

    private struct Parser {
        let characters: [Character]
        var runs: [String] = []
        var current = ""
        var previousAtomWasLiteral = false
        var index = 0

        mutating func requiredLiteral() -> String? {
            while index < characters.count {
                guard consumeNext() else { return nil }
            }
            finishRun()
            return runs.max { $0.utf8.count < $1.utf8.count }
        }

        private mutating func finishRun() {
            if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }

        private mutating func consumeNext() -> Bool {
            let character = characters[index]
            switch character {
            case "\\": return consumeEscape()
            case "[":
                finishRun()
                previousAtomWasLiteral = false
                skipCharacterClass()
            case "?", "*": consumeOptionalAtom()
            case "{": consumeQuantifier()
            case ".", "^", "$":
                finishRun()
                previousAtomWasLiteral = false
                index += 1
            case "+": index += 1
            default:
                current.append(character)
                previousAtomWasLiteral = true
                index += 1
            }
            return true
        }

        private mutating func consumeEscape() -> Bool {
            guard index + 1 < characters.count else {
                finishRun()
                index = characters.count
                return true
            }
            let escaped = characters[index + 1]
            // Escaped punctuation is literal. Escaped letters and digits may
            // represent classes, control escapes, Unicode escapes, or backreferences.
            guard !escaped.isLetter, !escaped.isNumber else { return false }
            current.append(escaped)
            previousAtomWasLiteral = true
            index += 2
            return true
        }

        private mutating func skipCharacterClass() {
            index += 1
            var escaped = false
            while index < characters.count {
                let next = characters[index]
                index += 1
                if escaped { escaped = false }
                else if next == "\\" { escaped = true }
                else if next == "]" { return }
            }
        }

        private mutating func consumeOptionalAtom() {
            if previousAtomWasLiteral, !current.isEmpty { current.removeLast() }
            finishRun()
            previousAtomWasLiteral = false
            index += 1
        }

        private mutating func consumeQuantifier() {
            guard let closing = characters[(index + 1)...].firstIndex(of: "}") else {
                finishRun()
                index = characters.count
                return
            }
            let quantifier = String(characters[(index + 1)..<closing])
            let firstValue = quantifier.split(
                separator: ",", omittingEmptySubsequences: false
            ).first ?? ""
            let minimum = Int(firstValue) ?? 0
            if minimum == 0 { removeOptionalAtom() }
            index = closing + 1
        }

        private mutating func removeOptionalAtom() {
            if previousAtomWasLiteral, !current.isEmpty { current.removeLast() }
            finishRun()
            previousAtomWasLiteral = false
        }
    }

    private static func hasUnescaped(_ pattern: String, anyOf metacharacters: String) -> Bool {
        var escaped = false
        for character in pattern {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if metacharacters.contains(character) {
                return true
            }
        }
        return false
    }
}
