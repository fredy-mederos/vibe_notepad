import Foundation

public struct FindOptions: Hashable, Codable, Sendable {
    public var isRegex = false
    public var caseSensitive = false
    public var wholeWord = false

    public init(isRegex: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false) {
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }
}

/// Search and replace over `NSString`, shared by the editor's find bar.
public enum FindEngine {
    public enum FindError: Error, LocalizedError {
        case invalidPattern(String)
        public var errorDescription: String? {
            if case .invalidPattern(let message) = self { return message }
            return nil
        }
    }

    public static func regex(for pattern: String, options: FindOptions) throws -> NSRegularExpression {
        var body = options.isRegex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        if options.wholeWord { body = "(?<![\\p{L}\\p{N}_])(?:\(body))(?![\\p{L}\\p{N}_])" }
        var regexOptions: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { regexOptions.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: body, options: regexOptions)
        } catch {
            throw FindError.invalidPattern("Invalid regular expression")
        }
    }

    /// Non-empty matches of `pattern` in `text` (up to `limit`).
    public static func matches(of pattern: String, in text: NSString, options: FindOptions, limit: Int = 100_000) throws -> [NSRange] {
        guard !pattern.isEmpty else { return [] }
        let expression = try regex(for: pattern, options: options)
        var result: [NSRange] = []
        expression.enumerateMatches(in: text as String, options: [], range: NSRange(location: 0, length: text.length)) { match, _, stop in
            guard let match, match.range.length > 0 else { return }
            result.append(match.range)
            if result.count >= limit { stop.pointee = true }
        }
        return result
    }

    /// The text that replaces `match`, expanding `$1`-style references and `\n`/`\t` in regex mode.
    /// Returns nil when `match` is no longer a match of `pattern` (the text changed since searching).
    public static func replacement(for match: NSRange, in text: NSString, pattern: String, template: String, options: FindOptions) -> String? {
        guard NSMaxRange(match) <= text.length, let expression = try? regex(for: pattern, options: options) else { return nil }
        // Transparent bounds let lookbehind and \b see the surrounding text.
        let result = expression.firstMatch(in: text as String,
                                           options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds],
                                           range: NSRange(location: match.location, length: text.length - match.location))
        guard let result, result.range == match else { return nil }
        guard options.isRegex else { return template }
        return expression.replacementString(for: result, in: text as String, offset: 0, template: expandEscapes(template))
    }

    /// All replacements for "Replace All": ranges in the original text with their new strings,
    /// in increasing order. Includes zero-length regex matches (e.g. `^` to prefix every line).
    public static func replaceAll(in text: NSString, pattern: String, template: String, options: FindOptions) throws -> [(NSRange, String)] {
        guard !pattern.isEmpty else { return [] }
        let expression = try regex(for: pattern, options: options)
        let expandedTemplate = options.isRegex ? expandEscapes(template) : NSRegularExpression.escapedTemplate(for: template)
        var edits: [(NSRange, String)] = []
        expression.enumerateMatches(in: text as String, options: [], range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match else { return }
            edits.append((match.range, expression.replacementString(for: match, in: text as String, offset: 0, template: expandedTemplate)))
        }
        return edits
    }

    /// Turns `\n`, `\t` and `\r` typed in the replace field into real characters; other escapes
    /// are left for `NSRegularExpression` (`\$` → `$`, `\\` → `\`).
    static func expandEscapes(_ template: String) -> String {
        var out = ""
        var iterator = template.makeIterator()
        while let c = iterator.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let n = iterator.next() else { out.append("\\\\"); break }
            switch n {
            case "n", "r": out.append("\n") // the buffer always uses \n line breaks
            case "t": out.append("\t")
            default:
                out.append("\\")
                out.append(n)
            }
        }
        return out
    }
}
