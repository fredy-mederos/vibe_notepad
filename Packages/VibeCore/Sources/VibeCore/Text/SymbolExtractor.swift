import Foundation

/// A navigable symbol (function, type, heading, section, key…).
public struct DocumentSymbol: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case function, type, heading, section, key, variable, target
    }

    public let name: String
    public let kind: Kind
    /// 0-based line.
    public let line: Int
    /// Nesting level (heading level, indentation depth) for display.
    public let level: Int

    public var id: Int { line }
}

/// Lightweight, regex-based outline extraction for "Go to Symbol" (⌘R).
public enum SymbolExtractor {
    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let kind: DocumentSymbol.Kind
        /// Capture group holding the name.
        let group: Int
        /// Optional capture group whose match decides the kind (`class` → type, `func` → function).
        let kindGroup: Int?

        init(_ pattern: String, _ kind: DocumentSymbol.Kind, group: Int = 1, kindGroup: Int? = nil) {
            regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            self.kind = kind
            self.group = group
            self.kindGroup = kindGroup
        }
    }

    private static let typeWords: Set<String> = [
        "class", "struct", "enum", "protocol", "extension", "actor", "interface", "trait", "impl", "object",
        "type", "record", "module", "namespace", "typealias", "message", "service", "defmodule", "union",
    ]

    private static let swiftLike = Rule(#"^[ \t]*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|private|internal|fileprivate|open|package|static|final|override|class|mutating|nonmutating|nonisolated|convenience|required|indirect|async|unsafe|pub(?:\([^)]*\))?|export|default|abstract|sealed|data|inline|suspend|operator|infix|tailrec|external|const|virtual|protected|async)\s+)*(func|fun|fn|def|function|class|struct|enum|protocol|extension|actor|interface|trait|impl|object|type|record|typealias|union)\s+(?:<[^>]*>\s*)?([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)"#, .function, group: 2, kindGroup: 1)
    private static let goFunc = Rule(#"^func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)"#, .function)
    private static let goType = Rule(#"^type\s+([A-Za-z_]\w*)"#, .type)
    private static let jsConst = Rule(#"^[ \t]*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>"#, .function)
    private static let pythonRuby = Rule(#"^[ \t]*(?:async\s+)?(def|class|module)\s+(?:self\.)?([A-Za-z_]\w*[?!]?)"#, .function, group: 2, kindGroup: 1)
    private static let cFunction = Rule(#"^(?:[\w:<>*&\s]+?)\s+\**([A-Za-z_][\w:~]*)\s*\([^;]*$"#, .function)
    private static let elixir = Rule(#"^[ \t]*(def|defp|defmacro|defmodule)\s+([A-Za-z_][\w.?!]*)"#, .function, group: 2, kindGroup: 1)
    private static let shellFunction = Rule(#"^[ \t]*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*\{?"#, .function)
    private static let shellKeywordFunction = Rule(#"^[ \t]*function\s+([A-Za-z_][\w-]*)"#, .function)
    private static let iniSection = Rule(#"^[ \t]*\[\[?([^\]]+)\]\]?"#, .section)
    private static let envKey = Rule(#"^[ \t]*(?:export\s+)?([A-Za-z_][\w.-]*)[ \t]*="#, .key)
    private static let yamlKey = Rule(#"^([A-Za-z_"'][^:#\n]*?)\s*:(?:\s|$)"#, .key)
    private static let makeTarget = Rule(#"^([A-Za-z0-9_.%/$()-][^:=\s]*)\s*::?(?!=)"#, .target)
    private static let dockerStage = Rule(#"^\s*FROM\s+\S+(?:\s+AS\s+(\S+))?"#, .section)
    private static let cssSelector = Rule(#"^([^\s{}@/][^{}]*?)\s*\{"#, .type)
    private static let sqlObject = Rule(#"(?i)^\s*create\s+(?:or\s+replace\s+)?(?:temporary\s+|temp\s+)?(table|view|function|procedure|index|trigger|type|schema)\s+(?:if\s+not\s+exists\s+)?([\w."`]+)"#, .type, group: 2, kindGroup: 1)
    private static let xmlId = Rule(#"<([A-Za-z][\w:-]*)[^>]*\bid\s*=\s*"([^"]+)""#, .type, group: 2)
    private static let graphql = Rule(#"^\s*(type|interface|enum|input|union|scalar|query|mutation|subscription|fragment)\s+([A-Za-z_]\w*)"#, .type, group: 2, kindGroup: 1)
    private static let protobuf = Rule(#"^\s*(message|enum|service|rpc)\s+([A-Za-z_]\w*)"#, .type, group: 2, kindGroup: 1)
    private static let hcl = Rule(#"^\s*(resource|data|module|variable|output|provider)\s+((?:"[^"]*"\s*)+)"#, .type, group: 2)

    public static func symbols(in text: String, language: LanguageID) -> [DocumentSymbol] {
        if language == .markdown { return markdownHeadings(text) }
        let rules: [Rule]
        switch language {
        case .swift, .kotlin, .java, .scala, .groovy, .csharp, .rust, .typescript, .javascript, .dart, .php, .objectiveC:
            rules = [swiftLike, jsConst]
        case .go: rules = [goFunc, goType]
        case .python, .ruby: rules = [pythonRuby]
        case .elixir: rules = [elixir]
        case .c, .cpp: rules = [swiftLike, cFunction]
        case .shell, .powershell: rules = [shellKeywordFunction, shellFunction]
        case .ini, .toml, .gitignore, .sshConfig: rules = [iniSection]
        case .env, .properties, .xcconfig: rules = [envKey]
        case .yaml: rules = [yamlKey]
        case .makefile: rules = [makeTarget]
        case .dockerfile: rules = [dockerStage]
        case .css, .scss, .less: rules = [cssSelector]
        case .sql: rules = [sqlObject]
        case .xml, .html: rules = [xmlId]
        case .graphql: rules = [graphql]
        case .protobuf: rules = [protobuf]
        case .hcl: rules = [hcl]
        default: return []
        }
        let ns = text as NSString
        var found: [Int: DocumentSymbol] = [:]
        let lineStarts = lineStartOffsets(ns)
        for rule in rules {
            rule.regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
                guard let match, found.count < 5000 else { stop.pointee = true; return }
                let nameRange = match.range(at: rule.group)
                guard nameRange.location != NSNotFound, nameRange.length > 0 else { return }
                let line = lineIndex(of: match.range.location, in: lineStarts)
                guard found[line] == nil else { return }
                var kind = rule.kind
                if let kindGroup = rule.kindGroup, match.range(at: kindGroup).location != NSNotFound {
                    let word = ns.substring(with: match.range(at: kindGroup)).lowercased()
                    kind = typeWords.contains(word) || ["table", "view", "schema", "type", "index", "trigger"].contains(word) ? .type : .function
                }
                let name = ns.substring(with: nameRange).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: language == .hcl ? "" : "\"")
                let indent = ns.substring(with: NSRange(location: lineStarts[line], length: match.range.location - lineStarts[line])).count
                found[line] = DocumentSymbol(name: name, kind: kind, line: line, level: indent / 2)
            }
        }
        return found.values.sorted { $0.line < $1.line }
    }

    /// ATX headings outside fenced code blocks.
    static func markdownHeadings(_ text: String) -> [DocumentSymbol] {
        var result: [DocumentSymbol] = []
        var fence: Character?
        var index = 0
        text.enumerateLines { line, _ in
            defer { index += 1 }
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = trimmed.first!
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                return
            }
            guard fence == nil, trimmed.hasPrefix("#") else { return }
            let hashes = trimmed.prefix { $0 == "#" }.count
            guard hashes <= 6 else { return }
            let rest = trimmed.dropFirst(hashes)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return }
            var title = rest.trimmingCharacters(in: .whitespaces)
            while title.hasSuffix("#") { title.removeLast() }
            title = title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            result.append(DocumentSymbol(name: title, kind: .heading, line: index, level: hashes))
        }
        return result
    }

    private static func lineStartOffsets(_ text: NSString) -> [Int] {
        var starts = [0]
        let length = text.length
        var buffer = [unichar](repeating: 0, count: 4096)
        var position = 0
        while position < length {
            let count = min(4096, length - position)
            text.getCharacters(&buffer, range: NSRange(location: position, length: count))
            for k in 0..<count where buffer[k] == 0x0A { starts.append(position + k + 1) }
            position += count
        }
        return starts
    }

    private static func lineIndex(of offset: Int, in starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
