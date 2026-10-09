import Foundation

/// JSON, JSONC (comments) and JSON5-ish input (single quotes, unquoted keys).
/// Object keys are colored as properties, values by type.
public struct JSONLexer: SyntaxLexer {
    public init() {}

    private enum Mode {
        static let blockComment: UInt8 = 1
    }

    private static let literals: Set<String> = ["true", "false", "null", "NaN", "Infinity"]

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        var i = line.start
        if state.main.mode == Mode.blockComment {
            if let close = line.find(u16("*/"), from: i) {
                tokens.add(i, close + 2, .comment)
                i = close + 2
                state.main = .initial
            } else {
                tokens.add(i, line.end, .comment)
                return
            }
        }

        while i < line.end {
            let c = line[i]
            if Ch.isSpace(c) { i += 1; continue }
            switch c {
            case Ch.quote, Ch.apostrophe:
                let end = scanString(line, from: i, quote: c, tokens: &tokens)
                if isKey(line, after: end) {
                    tokens.removeTokens(from: i)
                    tokens.add(i, end, .property)
                }
                i = end
            case Ch.lbrace, Ch.rbrace, Ch.lbracket, Ch.rbracket, Ch.comma, Ch.colon:
                tokens.add(i, i + 1, .punctuation)
                i += 1
            case Ch.slash where line[i + 1] == Ch.slash:
                tokens.add(i, line.end, .comment)
                return
            case Ch.slash where line[i + 1] == Ch.star:
                if let close = line.find(u16("*/"), from: i + 2) {
                    tokens.add(i, close + 2, .comment)
                    i = close + 2
                } else {
                    tokens.add(i, line.end, .comment)
                    state.main = LexState(mode: Mode.blockComment)
                    return
                }
            case Ch.minus, Ch.plus, Ch.dot:
                if Ch.isDigit(line[i + 1]) || line[i + 1] == Ch.dot {
                    let end = line.scanNumber(i + 1)
                    tokens.add(i, end, .number)
                    i = end
                } else {
                    tokens.add(i, i + 1, .operator)
                    i += 1
                }
            default:
                if Ch.isDigit(c) {
                    let end = line.scanNumber(i)
                    tokens.add(i, end, .number)
                    i = end
                } else if Ch.isIdentStart(c) || c == Ch.dollar {
                    let end = line.scanIdentifier(i, extra: Ch.dollar)
                    if isKey(line, after: end) {
                        tokens.add(i, end, .property)
                    } else if Self.literals.contains(line.string(i, end)) {
                        tokens.add(i, end, .constant)
                    } else {
                        tokens.add(i, end, .invalid)
                    }
                    i = end
                } else {
                    i += 1
                }
            }
        }
    }

    private func isKey(_ line: LineBuffer, after end: Int) -> Bool {
        line[line.skipSpaces(end)] == Ch.colon
    }

    /// Scans a string with escapes; unterminated strings end at the end of the line.
    private func scanString(_ line: LineBuffer, from start: Int, quote: UInt16, tokens: inout TokenBuffer) -> Int {
        var segment = start
        var j = start + 1
        while j < line.end {
            let c = line[j]
            if c == Ch.backslash {
                tokens.add(segment, j, .string)
                var escEnd = j + 2
                if line[j + 1] == 0x75 /* u */ {
                    var k = j + 2
                    while k < j + 6, Ch.isHexDigit(line[k]) { k += 1 }
                    escEnd = k
                }
                escEnd = min(escEnd, line.end)
                tokens.add(j, escEnd, .escape)
                j = escEnd
                segment = j
                continue
            }
            if c == quote {
                tokens.add(segment, j + 1, .string)
                return j + 1
            }
            j += 1
        }
        tokens.add(segment, line.end, .string)
        return line.end
    }
}
