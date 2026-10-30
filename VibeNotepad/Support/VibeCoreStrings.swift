import Foundation
import VibeCore

// What the app shows from VibeCore, in the user's language. VibeCore stays in English (it's
// platform-neutral, and its tests read its messages), so its titles and errors are put into words here.

extension LanguageID {
    /// The language's name: names stay as they are, but Plain Text is said in the user's language.
    var localizedName: String {
        self == .plainText ? String(localized: "Plain Text", comment: "The language of a file that isn't code or markup") : displayName
    }
}

extension LanguageInfo {
    var localizedName: String { id.localizedName }
}

extension PaneLayout.Preset {
    var localizedTitle: String {
        switch self {
        case .single: String(localized: "Single", comment: "Editor layout: one pane")
        case .twoColumns: String(localized: "Two Columns", comment: "Editor layout: two panes side by side")
        case .twoRows: String(localized: "Two Rows", comment: "Editor layout: two panes, one above the other")
        case .threeColumns: String(localized: "Three Columns", comment: "Editor layout: three panes side by side")
        case .mainAndTwo: String(localized: "One Left, Two Right", comment: "Editor layout: one pane on the left, two stacked on the right")
        case .grid: String(localized: "Grid (2 × 2)", comment: "Editor layout: four panes")
        }
    }
}

extension CSVTable.Delimiter {
    var localizedName: String {
        switch self {
        case .comma: String(localized: "Comma", comment: "What separates a CSV file's columns")
        case .semicolon: String(localized: "Semicolon", comment: "What separates a CSV file's columns")
        case .tab: String(localized: "Tab.character", defaultValue: "Tab", comment: "What separates a CSV file's columns: the tab character")
        case .pipe: String(localized: "Pipe", comment: "What separates a CSV file's columns: the | character")
        }
    }
}

extension Indentation {
    /// `Spaces: 4`, for the status bar.
    var localizedLabel: String {
        usesTabs ? String(localized: "Tabs: \(String(width))", comment: "Status bar: indentation with tab characters this wide")
            : String(localized: "Spaces: \(String(width))", comment: "Status bar: indentation with this many spaces")
    }
}

extension LineEnding {
    /// `LF (macOS / Linux)`, for menus.
    var localizedDescription: String {
        switch self {
        case .lf: String(localized: "LF (macOS / Linux)", comment: "Line endings")
        case .crlf: String(localized: "CRLF (Windows)", comment: "Line endings")
        case .cr: String(localized: "CR (Classic Mac)", comment: "Line endings: what Macs used before macOS")
        }
    }
}

enum VibeCoreStrings {
    /// An error's message in the user's language: VibeCore's (formatting JSON or XML, a find pattern,
    /// reading or writing a file), or what the system says for its own.
    static func message(for error: Error) -> String {
        switch error {
        case let error as TextTransforms.JSONFormatError:
            switch error {
            case .invalid(let detail): String(localized: "Invalid JSON: \(detail)", comment: "The placeholder is the parser's explanation, in English")
            }
        case let error as TextTransforms.XMLFormatError:
            switch error {
            case .invalid(let line, let problem):
                String(localized: "Invalid XML (line \(String(line))): \(xmlProblem(problem))",
                       comment: "The second placeholder says what's wrong, like “</c> doesn’t match <b> on line 2”")
            }
        case let error as FindEngine.FindError:
            switch error {
            case .invalidPattern: String(localized: "Invalid regular expression")
            }
        case let error as TextFileCodec.CodecError:
            switch error {
            case .binary: String(localized: "This looks like a binary file.")
            case .undecodable: String(localized: "The file’s text encoding could not be determined.")
            case .unencodable(let name): String(localized: "The text contains characters that can’t be saved as \(name).", comment: "The placeholder is a text encoding")
            }
        default:
            error.localizedDescription
        }
    }

    private static func xmlProblem(_ problem: TextTransforms.XMLProblem) -> String {
        switch problem {
        case .neverEnds(.comment): String(localized: "the comment never ends (-->)", comment: "Invalid XML: what's wrong")
        case .neverEnds(.cdata): String(localized: "the CDATA section never ends (]]>)", comment: "Invalid XML: what's wrong")
        case .neverEnds(.instruction): String(localized: "the processing instruction never ends (?>)", comment: "Invalid XML: what's wrong")
        case .neverEnds(.declaration): String(localized: "the declaration never ends (>)", comment: "Invalid XML: what's wrong")
        case .neverEnds(.tag): String(localized: "the tag never ends (>)", comment: "Invalid XML: what's wrong")
        case .noStartTag(let name): String(localized: "</\(name)> has no start tag", comment: "Invalid XML: what's wrong; the placeholder is an element's name")
        case .mismatch(let closing, let opening, let openingLine):
            String(localized: "</\(closing)> doesn’t match <\(opening)> on line \(String(openingLine))",
                   comment: "Invalid XML: a closing tag isn't the open element's; placeholders: the two element names and a line number")
        case .neverClosed(let name): String(localized: "<\(name)> is never closed", comment: "Invalid XML: what's wrong; the placeholder is an element's name")
        case .parser(let message): message ?? String(localized: "the parser stopped", comment: "Invalid XML: the parser stopped without saying why")
        }
    }
}
