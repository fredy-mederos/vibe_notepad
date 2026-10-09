import Foundation

// MARK: - Block tree

/// Marker data shared by a list and its items.
struct MDListInfo {
    var ordered = false
    /// `-`, `+` or `*` for bullet lists.
    var bulletChar: UInt8 = 0
    /// `.` or `)` for ordered lists.
    var delimiter: UInt8 = 0
    var start = 1
    /// Column of the marker relative to the enclosing container's content.
    var markerOffset = 0
    /// Marker width plus the spaces up to the item's content column.
    var padding = 0
    var tight = true

    func matches(_ other: MDListInfo) -> Bool {
        ordered == other.ordered && bulletChar == other.bulletChar && delimiter == other.delimiter
    }
}

/// Column alignment of a GFM table.
enum MDAlignment {
    case none
    case left
    case center
    case right
}

/// A node of the block tree. Created and mutated only by `MDBlockParser`; read by the renderer.
final class MDBlock {
    enum Kind {
        case document
        case blockQuote
        case list
        case item
        case footnoteDefinition
        case paragraph
        case heading
        case thematicBreak
        case codeBlock
        case htmlBlock
        case table
    }

    var kind: Kind
    /// 0-based source line where the block starts.
    var startLine: Int
    /// 0-based source line of the block's last line (used for tight/loose list detection).
    var endLine: Int
    var children: [MDBlock] = []

    /// Raw lines: paragraph text, code lines (fenced: info string first), HTML lines, table rows (header first).
    var lines: [MDLineSlice] = []
    /// Inline content of paragraphs and headings, trimmed.
    var content: [UInt8] = []

    // Headings
    var level = 0
    var anchor = ""
    var headingText = ""

    // Lists and items
    var list = MDListInfo()

    // Code blocks
    var isFenced = false
    var fenceChar: UInt8 = 0
    var fenceLength = 0
    var fenceOffset = 0

    // HTML blocks (CommonMark start condition 1...7)
    var htmlType = 0

    // Tables
    var alignments: [MDAlignment] = []

    // Footnote definitions
    var footnoteLabel = ""

    init(kind: Kind, startLine: Int) {
        self.kind = kind
        self.startLine = startLine
        self.endLine = startLine
    }

    /// Whether a block of this kind may directly contain a block of `child` kind.
    func canContain(_ child: Kind) -> Bool {
        switch kind {
        case .document, .blockQuote, .item, .footnoteDefinition:
            return child != .item
        case .list:
            return child == .item
        default:
            return false
        }
    }

    var isContainer: Bool {
        switch kind {
        case .document, .blockQuote, .list, .item, .footnoteDefinition: return true
        default: return false
        }
    }
}

// MARK: - Side data

/// A resolved link reference definition (`[label]: destination "title"`).
struct MDLinkReference {
    /// Normalized, sanitized URL bytes (not yet HTML-escaped).
    var destination: [UInt8]
    /// Unescaped title bytes, if any.
    var title: [UInt8]?
}

/// YAML front matter found at the very top of the document.
struct MDFrontMatter {
    /// Source lines of the YAML body (between the `---` fences); `upperBound` is the closing fence line.
    var contentLines: Range<Int>
}

// MARK: - Slugs

/// GitHub-style heading slugs with github-slugger's de-duplication rules.
struct MDSlugger {
    private var occurrences: [String: Int] = [:]

    mutating func slug(for text: String) -> String {
        let base = MDSlugger.slugify(text)
        var result = base
        while let count = occurrences[result] {
            let next = (occurrences[base] ?? count) + 1
            occurrences[base] = next
            result = base + "-" + String(next)
        }
        occurrences[result] = 0
        return result
    }

    /// Lowercases, drops everything except letters, marks, digits, spaces, `-` and `_`, maps spaces to `-`.
    static func slugify(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            switch scalar {
            case " ":
                scalars.append("-")
            case "-", "_":
                scalars.append(scalar)
            default:
                if scalar.value < 0x80 {
                    let c = UInt8(scalar.value)
                    if MDChar.isAlphanumeric(c) { scalars.append(scalar) }
                } else {
                    switch scalar.properties.generalCategory {
                    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                         .nonspacingMark, .spacingMark, .enclosingMark,
                         .decimalNumber, .letterNumber, .otherNumber, .connectorPunctuation:
                        scalars.append(scalar)
                    default:
                        break
                    }
                }
            }
        }
        return String(scalars)
    }
}
