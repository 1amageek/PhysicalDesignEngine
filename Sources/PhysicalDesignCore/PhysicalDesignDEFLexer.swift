import Foundation

struct PhysicalDesignDEFLexer: Sendable {
    func lex(_ source: String) -> [PhysicalDesignDEFToken] {
        var tokens: [PhysicalDesignDEFToken] = []
        var cursor = source.startIndex
        var line = 1
        var column = 1

        func isPunctuation(_ character: Character) -> Bool {
            character == "(" || character == ")" || character == ";" || character == "+" || character == "-"
        }

        while cursor < source.endIndex {
            let character = source[cursor]
            if character == "#" {
                while cursor < source.endIndex, source[cursor] != "\n" {
                    if source[cursor] == "\n" {
                        line += 1
                        column = 1
                    } else {
                        column += 1
                    }
                    cursor = source.index(after: cursor)
                }
                continue
            }
            if character.isWhitespace {
                if character == "\n" {
                    line += 1
                    column = 1
                } else {
                    column += 1
                }
                cursor = source.index(after: cursor)
                continue
            }

            let startLine = line
            let startColumn = column
            if character == "\"" {
                cursor = source.index(after: cursor)
                column += 1
                var value = ""
                while cursor < source.endIndex, source[cursor] != "\"" {
                    let quotedCharacter = source[cursor]
                    value.append(quotedCharacter)
                    if quotedCharacter == "\n" {
                        line += 1
                        column = 1
                    } else {
                        column += 1
                    }
                    cursor = source.index(after: cursor)
                }
                if cursor < source.endIndex {
                    cursor = source.index(after: cursor)
                    column += 1
                }
                tokens.append(PhysicalDesignDEFToken(text: value, line: startLine, column: startColumn))
                continue
            }

            let nextIndex = source.index(after: cursor)
            let isNegativeNumber = character == "-" && nextIndex < source.endIndex && source[nextIndex].isNumber
            if isPunctuation(character) && !isNegativeNumber {
                tokens.append(PhysicalDesignDEFToken(text: String(character), line: startLine, column: startColumn))
                cursor = nextIndex
                column += 1
                continue
            }

            var value = ""
            while cursor < source.endIndex {
                let current = source[cursor]
                let next = source.index(after: cursor)
                let negativeNumberAtStart = value.isEmpty && current == "-" && next < source.endIndex && source[next].isNumber
                if current.isWhitespace || current == "#" || (isPunctuation(current) && !negativeNumberAtStart) || current == "\"" {
                    break
                }
                value.append(current)
                cursor = next
                column += 1
            }
            if !value.isEmpty {
                tokens.append(PhysicalDesignDEFToken(text: value, line: startLine, column: startColumn))
            } else {
                cursor = nextIndex
                column += 1
            }
        }
        return tokens
    }
}
