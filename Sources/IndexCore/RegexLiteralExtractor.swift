/// Finds literal text that every match of a regular expression must contain.
///
/// The extractor intentionally supports a conservative subset. Returning `nil`
/// only disables an index optimization; it never changes matching semantics.
enum RegexLiteralExtractor {
    static func requiredLiteral(in pattern: String) -> String? {
        guard !hasUnescaped(pattern, anyOf: "|()") else { return nil }
        let characters = Array(pattern)
        var runs: [String] = []
        var current = ""
        var previousAtomWasLiteral = false
        var index = 0

        func finishRun() {
            if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }

        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                guard index + 1 < characters.count else {
                    finishRun()
                    break
                }
                let escaped = characters[index + 1]
                // Escaped punctuation is literal. Escaped letters and digits may
                // represent classes, control escapes, Unicode escapes, or backreferences.
                guard !escaped.isLetter, !escaped.isNumber else { return nil }
                current.append(escaped)
                previousAtomWasLiteral = true
                index += 2
                continue
            }
            if character == "[" {
                finishRun()
                previousAtomWasLiteral = false
                index += 1
                var escaped = false
                while index < characters.count {
                    let next = characters[index]
                    index += 1
                    if escaped {
                        escaped = false
                    } else if next == "\\" {
                        escaped = true
                    } else if next == "]" {
                        break
                    }
                }
                continue
            }
            if character == "?" || character == "*" {
                if previousAtomWasLiteral, !current.isEmpty { current.removeLast() }
                finishRun()
                previousAtomWasLiteral = false
                index += 1
                continue
            }
            if character == "{" {
                guard let closing = characters[(index + 1)...].firstIndex(of: "}") else {
                    finishRun()
                    break
                }
                let quantifier = String(characters[(index + 1)..<closing])
                let minimum = Int(
                    quantifier.split(separator: ",", omittingEmptySubsequences: false).first ?? ""
                ) ?? 0
                if minimum == 0, previousAtomWasLiteral, !current.isEmpty { current.removeLast() }
                if minimum == 0 { finishRun() }
                index = closing + 1
                continue
            }
            if character == "." || character == "^" || character == "$" {
                finishRun()
                previousAtomWasLiteral = false
            } else if character != "+" {
                current.append(character)
                previousAtomWasLiteral = true
            }
            index += 1
        }
        finishRun()
        return runs.max { $0.utf8.count < $1.utf8.count }
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
