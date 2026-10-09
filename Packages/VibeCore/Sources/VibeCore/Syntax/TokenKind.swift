import Foundation

/// The semantic category of a highlighted span. Themes map each kind to a color/style.
public enum TokenKind: UInt8, Sendable, CaseIterable, Codable {
    case plain = 0
    case comment
    case keyword
    case type
    case function
    case string
    case number
    case constant
    case variable
    case property
    case `operator`
    case punctuation
    case tag
    case attribute
    case meta
    case escape
    case regex
    case section

    // Markup (Markdown and friends)
    case heading
    case emphasis
    case strong
    case strikethrough
    case link
    case url
    case code
    case quote
    case listMarker
    case markup

    // Diffs
    case inserted
    case deleted
    case changed
    case invalid

    // Rainbow columns for CSV/TSV
    case rainbow1
    case rainbow2
    case rainbow3
    case rainbow4
    case rainbow5
    case rainbow6

    // Log levels
    case logError
    case logWarning
    case logInfo
    case logDebug

    /// CSS class used by the HTML highlighter (`tk-keyword`, ...).
    public var cssClass: String { "tk-\(self)" }

    public static let rainbow: [TokenKind] = [.rainbow1, .rainbow2, .rainbow3, .rainbow4, .rainbow5, .rainbow6]
}

/// A highlighted span. Offsets are UTF-16 based (NSString compatible).
public struct Token: Sendable, Equatable {
    public var start: Int
    public var length: Int
    public var kind: TokenKind

    public init(start: Int, length: Int, kind: TokenKind) {
        self.start = start
        self.length = length
        self.kind = kind
    }

    public var end: Int { start + length }
}

/// Collects the tokens produced for one line.
public struct TokenBuffer: Sendable {
    public private(set) var tokens: [Token] = []

    public init() {
        tokens.reserveCapacity(64)
    }

    /// Adds a token covering `[start, end)`. Empty ranges and `.plain` are ignored.
    @inline(__always)
    public mutating func add(_ start: Int, _ end: Int, _ kind: TokenKind) {
        guard end > start, kind != .plain else { return }
        tokens.append(Token(start: start, length: end - start, kind: kind))
    }

    public mutating func removeAll() {
        tokens.removeAll(keepingCapacity: true)
    }

    /// Removes trailing tokens that start at or after `offset`.
    public mutating func removeTokens(from offset: Int) {
        while let last = tokens.last, last.start >= offset { tokens.removeLast() }
    }

    public var isEmpty: Bool { tokens.isEmpty }
}
