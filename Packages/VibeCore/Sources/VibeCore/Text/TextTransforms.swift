import Foundation

/// A replacement plus the selection to apply afterwards (in the coordinates of the new text).
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

/// Editing commands implemented as pure functions over `NSString` (UTF-16 ranges), so they
/// are easy to test and shared by every platform's text view.
public enum TextTransforms {
    private static let newline: unichar = 0x0A

    // MARK: Lines

    /// The full lines touched by `selection`, including the final line feed. A non-empty
    /// selection that ends right after a line feed doesn't include the following line.
    public static func lineRange(_ text: NSString, _ selection: NSRange) -> NSRange {
        var sel = clamp(selection, text.length)
        if sel.length > 0, text.character(at: NSMaxRange(sel) - 1) == newline { sel.length -= 1 }
        return text.lineRange(for: sel)
    }

    /// Splits a line block into lines, reporting whether it ended with a line feed.
    private static func lines(of block: String) -> (lines: [String], trailingNewline: Bool) {
        var parts = block.components(separatedBy: "\n")
        let trailing = block.hasSuffix("\n")
        if trailing { parts.removeLast() }
        return (parts, trailing)
    }

    private static func join(_ lines: [String], trailingNewline: Bool) -> String {
        lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    private static func utf16(_ s: String) -> Int { (s as NSString).length }

    static func clamp(_ range: NSRange, _ length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    private static func leadingWhitespace(_ s: some StringProtocol) -> String {
        String(s.prefix { $0 == " " || $0 == "\t" })
    }

    // MARK: Indentation

    public static func indent(_ text: NSString, selection: NSRange, unit: String) -> TextEdit {
        let range = lineRange(text, selection)
        let (lines, trailing) = lines(of: text.substring(with: range))
        let unitLength = utf16(unit)
        var added = 0, firstAdded = 0
        let output = lines.enumerated().map { index, line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 { return line }
            added += unitLength
            if index == 0 { firstAdded = unitLength }
            return unit + line
        }
        let start = selection.location + firstAdded
        let end = NSMaxRange(selection) + added
        return TextEdit(range: range, replacement: join(output, trailingNewline: trailing),
                        selection: NSRange(location: start, length: max(0, end - start)))
    }

    public static func outdent(_ text: NSString, selection: NSRange, tabWidth: Int) -> TextEdit? {
        let range = lineRange(text, selection)
        let (lines, trailing) = lines(of: text.substring(with: range))
        var removedTotal = 0, removedFirst = 0
        let output = lines.enumerated().map { index, line -> String in
            var remove = 0
            if line.hasPrefix("\t") {
                remove = 1
            } else {
                remove = min(tabWidth, line.prefix { $0 == " " }.count)
            }
            removedTotal += remove
            if index == 0 { removedFirst = remove }
            return String(line.dropFirst(remove))
        }
        guard removedTotal > 0 else { return nil }
        let column = selection.location - range.location
        let start = range.location + max(0, column - removedFirst)
        let end = max(start, NSMaxRange(selection) - removedTotal)
        return TextEdit(range: range, replacement: join(output, trailingNewline: trailing),
                        selection: NSRange(location: start, length: end - start))
    }

    // MARK: Comments

    /// Toggles line comments (or wraps in a block comment when the language has no line comments).
    public static func toggleComment(_ text: NSString, selection: NSRange, lineComment: String?, blockComment: (open: String, close: String)?) -> TextEdit? {
        let range = lineRange(text, selection)
        let block = text.substring(with: range)
        let (lines, trailing) = lines(of: block)

        if let token = lineComment {
            let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !content.isEmpty else { return nil }
            let allCommented = content.allSatisfy { $0.drop { $0 == " " || $0 == "\t" }.hasPrefix(token) }
            var firstDelta = 0, totalDelta = 0
            var output: [String] = []
            if allCommented {
                for (index, line) in lines.enumerated() {
                    let ws = leadingWhitespace(line)
                    var rest = line.dropFirst(ws.count)
                    guard rest.hasPrefix(token) else { output.append(line); continue }
                    rest = rest.dropFirst(token.count)
                    var removed = utf16(token)
                    if rest.hasPrefix(" ") { rest = rest.dropFirst(); removed += 1 }
                    totalDelta -= removed
                    if index == 0 { firstDelta = -removed }
                    output.append(ws + rest)
                }
            } else {
                let column = content.map { leadingWhitespace($0).count }.min() ?? 0
                let insert = token + " "
                for (index, line) in lines.enumerated() {
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { output.append(line); continue }
                    let prefix = line.prefix(column)
                    output.append(prefix + insert + line.dropFirst(column))
                    totalDelta += utf16(insert)
                    if index == 0 { firstDelta = utf16(insert) }
                }
            }
            let replacement = join(output, trailingNewline: trailing)
            let newSelection: NSRange
            if selection.length == 0 {
                newSelection = NSRange(location: max(range.location, selection.location + firstDelta), length: 0)
            } else {
                newSelection = NSRange(location: range.location, length: utf16(replacement) - (trailing ? 1 : 0))
            }
            return TextEdit(range: range, replacement: replacement, selection: newSelection)
        }

        if let (open, close) = blockComment {
            let trimmedBlock = block.trimmingCharacters(in: .whitespacesAndNewlines)
            let ws = leadingWhitespace(block)
            if trimmedBlock.hasPrefix(open), trimmedBlock.hasSuffix(close), trimmedBlock.count >= open.count + close.count {
                var inner = String(trimmedBlock.dropFirst(open.count).dropLast(close.count))
                if inner.hasPrefix(" ") { inner.removeFirst() }
                if inner.hasSuffix(" ") { inner.removeLast() }
                let replacement = ws + inner + (trailing ? "\n" : "")
                return TextEdit(range: range, replacement: replacement,
                                selection: NSRange(location: range.location, length: utf16(replacement) - (trailing ? 1 : 0)))
            }
            let body = trailing ? String(block.dropLast()) : block
            let content = body.dropFirst(ws.count)
            let replacement = ws + open + " " + content + " " + close + (trailing ? "\n" : "")
            return TextEdit(range: range, replacement: replacement,
                            selection: NSRange(location: range.location, length: utf16(replacement) - (trailing ? 1 : 0)))
        }
        return nil
    }

    // MARK: Line operations

    public static func moveLines(_ text: NSString, selection: NSRange, up: Bool) -> TextEdit? {
        let range = lineRange(text, selection)
        let block = text.substring(with: range)
        let offset = selection.location - range.location
        if up {
            guard range.location > 0 else { return nil }
            let previous = text.lineRange(for: NSRange(location: range.location - 1, length: 0))
            let previousText = text.substring(with: previous)
            let replacement: String
            if block.hasSuffix("\n") {
                replacement = block + previousText
            } else {
                replacement = block + "\n" + String(previousText.dropLast())
            }
            let combined = NSRange(location: previous.location, length: previous.length + range.length)
            return TextEdit(range: combined, replacement: replacement,
                            selection: NSRange(location: previous.location + offset, length: selection.length))
        } else {
            guard NSMaxRange(range) < text.length else { return nil }
            let next = text.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
            let nextText = text.substring(with: next)
            let replacement: String
            let blockStart: Int
            if nextText.hasSuffix("\n") {
                replacement = nextText + block
                blockStart = range.location + utf16(nextText)
            } else {
                replacement = nextText + "\n" + String(block.dropLast())
                blockStart = range.location + utf16(nextText) + 1
            }
            let combined = NSRange(location: range.location, length: range.length + next.length)
            return TextEdit(range: combined, replacement: replacement,
                            selection: NSRange(location: blockStart + offset, length: selection.length))
        }
    }

    public static func duplicate(_ text: NSString, selection: NSRange) -> TextEdit {
        if selection.length > 0 {
            let selected = text.substring(with: selection)
            if !selected.contains("\n") {
                return TextEdit(range: NSRange(location: NSMaxRange(selection), length: 0), replacement: selected,
                                selection: NSRange(location: NSMaxRange(selection), length: selection.length))
            }
        }
        let range = lineRange(text, selection)
        let block = text.substring(with: range)
        // The last line has no line feed: add one before the copy.
        let insertion = block.hasSuffix("\n") ? block : "\n" + block
        return TextEdit(range: NSRange(location: NSMaxRange(range), length: 0), replacement: insertion,
                        selection: NSRange(location: selection.location + utf16(insertion), length: selection.length))
    }

    public static func deleteLines(_ text: NSString, selection: NSRange) -> TextEdit {
        var range = lineRange(text, selection)
        // Deleting the last line also removes the line feed before it.
        if NSMaxRange(range) == text.length, range.location > 0, !text.substring(with: range).hasSuffix("\n") {
            range = NSRange(location: range.location - 1, length: range.length + 1)
        }
        let caret = min(range.location, text.length - range.length)
        return TextEdit(range: range, replacement: "", selection: NSRange(location: max(0, caret), length: 0))
    }

    /// Joins the selected lines (or the current line with the next) using single spaces.
    public static func joinLines(_ text: NSString, selection: NSRange) -> TextEdit? {
        var range = lineRange(text, selection)
        if lines(of: text.substring(with: range)).lines.count < 2 {
            guard NSMaxRange(range) < text.length else { return nil }
            let next = text.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
            range = NSRange(location: range.location, length: range.length + next.length)
        }
        let (allLines, trailing) = lines(of: text.substring(with: range))
        guard allLines.count >= 2 else { return nil }
        let first = allLines[0].replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
        var result = first
        for line in allLines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            result += (result.isEmpty ? "" : " ") + trimmed
        }
        return TextEdit(range: range, replacement: result + (trailing ? "\n" : ""),
                        selection: NSRange(location: range.location + utf16(first), length: 0))
    }

    public static func sortLines(_ text: NSString, selection: NSRange, descending: Bool = false, caseSensitive: Bool = false, unique: Bool = false) -> TextEdit? {
        let range = selection.length > 0 ? lineRange(text, selection) : NSRange(location: 0, length: text.length)
        let (lines, trailing) = lines(of: text.substring(with: range))
        guard lines.count > 1 else { return nil }
        var sorted = lines.sorted { a, b in
            let order = a.compare(b, options: caseSensitive ? [.numeric] : [.caseInsensitive, .numeric])
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
        if unique {
            var seen = Set<String>()
            sorted = sorted.filter { seen.insert(caseSensitive ? $0 : $0.lowercased()).inserted }
        }
        let replacement = join(sorted, trailingNewline: trailing)
        return TextEdit(range: range, replacement: replacement,
                        selection: NSRange(location: range.location, length: utf16(replacement) - (trailing ? 1 : 0)))
    }

    /// Applies `transform` to the selection, or to the word at the caret when nothing is selected.
    public static func transform(_ text: NSString, selection: NSRange, _ transform: (String) -> String) -> TextEdit? {
        let target = selection.length > 0 ? selection : wordRange(text, at: selection.location)
        guard target.length > 0 else { return nil }
        let replacement = transform(text.substring(with: target))
        return TextEdit(range: target, replacement: replacement, selection: NSRange(location: target.location, length: utf16(replacement)))
    }

    /// Range of the word (letters, digits, `_`) containing or touching `location`.
    public static func wordRange(_ text: NSString, at location: Int) -> NSRange {
        func isWord(_ c: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || c == 0x5F
        }
        var start = min(max(0, location), text.length)
        var end = start
        while start > 0, isWord(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWord(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Removes trailing spaces/tabs from every line. Returns nil when nothing changes.
    public static func trimTrailingWhitespace(_ text: NSString, selection: NSRange) -> TextEdit? {
        let original = text as String
        let trimmed = original.replacingOccurrences(of: "[ \\t]+(?=\\n|$)", with: "", options: .regularExpression)
        guard trimmed != original else { return nil }
        let removedBefore = (original as NSString).substring(to: min(selection.location, text.length))
            .replacingOccurrences(of: "[ \\t]+(?=\\n)", with: "", options: .regularExpression)
        let caret = min(utf16(removedBefore), utf16(trimmed))
        return TextEdit(range: NSRange(location: 0, length: text.length), replacement: trimmed, selection: NSRange(location: caret, length: 0))
    }

    // MARK: Newlines

    /// What pressing Return inserts: keeps the indentation, adds a level after an opening
    /// bracket (splitting `{|}`), and continues Markdown lists and quotes.
    public static func newline(_ text: NSString, selection: NSRange, indentUnit: String, language: LanguageID, continueLists: Bool = true) -> TextEdit {
        let sel = clamp(selection, text.length)
        let location = sel.location
        let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
        var lineEnd = NSMaxRange(lineRange)
        if lineEnd > lineRange.location, text.character(at: lineEnd - 1) == newline { lineEnd -= 1 }
        let before = text.substring(with: NSRange(location: lineRange.location, length: location - lineRange.location))
        let selectionEnd = min(max(NSMaxRange(sel), location), max(lineEnd, location))
        let after = text.substring(with: NSRange(location: selectionEnd, length: max(0, lineEnd - selectionEnd)))
        let indent = leadingWhitespace(before)

        func insert(_ s: String) -> TextEdit {
            TextEdit(range: sel, replacement: s, selection: NSRange(location: location + utf16(s), length: 0))
        }

        if continueLists, language == .markdown || language == .plainText {
            let line = text.substring(with: NSRange(location: lineRange.location, length: lineEnd - lineRange.location))
            if let item = listItem(in: line), location - lineRange.location >= item.prefixLength {
                let rest = line.dropFirst(item.prefixLength).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty, after.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Return on an empty item ends the list.
                    let full = NSRange(location: lineRange.location, length: lineEnd - lineRange.location)
                    return TextEdit(range: full, replacement: "", selection: NSRange(location: lineRange.location, length: 0))
                }
                return insert("\n" + item.continuation)
            }
        }

        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
        let firstAfter = after.first { $0 != " " && $0 != "\t" }
        let pairs: [Character: Character] = ["{": "}", "[": "]", "(": ")"]
        if let last = trimmedBefore.last, let closer = pairs[last] {
            if firstAfter == closer {
                let spaces = after.prefix { $0 == " " || $0 == "\t" }.count
                let inner = "\n" + indent + indentUnit
                let replacement = inner + "\n" + indent
                return TextEdit(range: NSRange(location: location, length: selectionEnd - location + spaces),
                                replacement: replacement, selection: NSRange(location: location + utf16(inner), length: 0))
            }
            return insert("\n" + indent + indentUnit)
        }
        if trimmedBefore.hasSuffix(":"), [.python, .yaml].contains(language) {
            return insert("\n" + indent + indentUnit)
        }
        return insert("\n" + indent)
    }

    struct ListItem {
        var prefixLength: Int
        var continuation: String
    }

    /// Recognizes `- `, `* `, `+ `, `1. `, `1) `, `> ` and task boxes at the start of `line`.
    static func listItem(in line: String) -> ListItem? {
        let indent = leadingWhitespace(line)
        var rest = Substring(line.dropFirst(indent.count))
        var prefix = indent
        var continuation = indent

        if rest.hasPrefix(">") {
            var quote = ""
            while rest.hasPrefix(">") {
                quote += ">"
                rest = rest.dropFirst()
                if rest.hasPrefix(" ") { quote += " "; rest = rest.dropFirst() }
            }
            prefix += quote
            continuation += quote
            if listMarker(rest) == nil {
                return ListItem(prefixLength: (prefix as NSString).length, continuation: continuation)
            }
        }
        guard let (marker, next) = listMarker(rest) else { return nil }
        rest = rest.dropFirst(marker.count)
        let spacing = String(rest.prefix { $0 == " " || $0 == "\t" })
        guard !spacing.isEmpty || rest.isEmpty else { return nil }
        rest = rest.dropFirst(spacing.count)
        prefix += marker + spacing
        continuation += next + (spacing.isEmpty ? " " : spacing)
        if rest.hasPrefix("[ ] ") || rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
            prefix += "[ ] "
            continuation += "[ ] "
        }
        return ListItem(prefixLength: (prefix as NSString).length, continuation: continuation)
    }

    /// The marker at the start of `s` and the marker the next item should use.
    private static func listMarker(_ s: Substring) -> (String, String)? {
        if let c = s.first, c == "-" || c == "*" || c == "+" {
            let after = s.dropFirst().first
            if after == nil || after == " " || after == "\t" { return (String(c), String(c)) }
            return nil
        }
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
        let delimiter = s.dropFirst(digits.count).first
        guard delimiter == "." || delimiter == ")" else { return nil }
        let after = s.dropFirst(digits.count + 1).first
        guard after == nil || after == " " || after == "\t" else { return nil }
        return ("\(digits)\(delimiter!)", "\(number + 1)\(delimiter!)")
    }

    // MARK: JSON

    public enum JSONFormatError: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            if case .invalid(let message) = self { return "Invalid JSON: \(message)" }
            return nil
        }
    }

    /// Pretty-prints JSON while preserving key order and number spelling.
    public static func formatJSON(_ source: String, indent: String = "  ") throws -> String {
        try validateJSON(source)
        return reformatJSON(source, indent: indent)
    }

    public static func minifyJSON(_ source: String) throws -> String {
        try validateJSON(source)
        return reformatJSON(source, indent: nil)
    }

    private static func validateJSON(_ source: String) throws {
        do {
            _ = try JSONSerialization.jsonObject(with: Data(source.utf8), options: [.fragmentsAllowed, .json5Allowed])
        } catch {
            let message = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            throw JSONFormatError.invalid(message)
        }
    }

    /// Streaming re-indenter: never reorders anything, only rewrites whitespace.
    private static func reformatJSON(_ source: String, indent: String?) -> String {
        var out = String()
        out.reserveCapacity(source.utf8.count + source.utf8.count / 4)
        var depth = 0
        var inString = false
        var escaped = false
        var quote: Character = "\""
        let chars = Array(source)
        var i = 0
        func newline() {
            guard let indent else { return }
            out.append("\n")
            out.append(String(repeating: indent, count: depth))
        }
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == quote { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"", "'":
                inString = true
                quote = c
                out.append(c)
            case "{", "[":
                // Keep empty containers compact.
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == (c == "{" ? "}" : "]") {
                    out.append(c)
                    out.append(chars[j])
                    i = j
                } else {
                    out.append(c)
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth = max(0, depth - 1)
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out.append(indent == nil ? ":" : ": ")
            case "/" where i + 1 < chars.count && chars[i + 1] == "/":
                // Drop comments: they can't be placed reliably after reflowing.
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            case "/" where i + 1 < chars.count && chars[i + 1] == "*":
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            default:
                if !c.isWhitespace { out.append(c) }
            }
            i += 1
        }
        return out
    }
}
