import AppKit
import SwiftUI
import VibeCore

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

extension Theme {
    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }
    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

extension LanguageID {
    enum Icon {
        case symbol(String)
        case text(String)
    }

    var icon: Icon {
        switch self {
        case .plainText: .symbol("doc.text")
        case .markdown: .symbol("text.document")
        case .json: .symbol("curlybraces")
        case .yaml: .symbol("list.bullet.indent")
        case .toml, .ini, .properties: .symbol("slider.horizontal.3")
        case .env: .symbol("key.fill")
        case .xml, .html: .symbol("chevron.left.forwardslash.chevron.right")
        case .css, .scss, .less: .symbol("paintbrush.fill")
        case .swift: .symbol("swift")
        case .shell, .powershell: .symbol("terminal.fill")
        case .dockerfile: .symbol("shippingbox.fill")
        case .makefile: .symbol("hammer.fill")
        case .diff: .symbol("plus.forwardslash.minus")
        case .log: .symbol("list.bullet.rectangle")
        case .csv, .tsv: .symbol("tablecells")
        case .gitignore: .symbol("eye.slash.fill")
        case .sshConfig: .symbol("lock.shield.fill")
        case .conf: .symbol("gearshape.fill")
        case .sql: .symbol("cylinder.split.1x2.fill")
        case .xcconfig: .symbol("hammer.circle.fill")
        case .appleStrings: .symbol("character.bubble.fill")
        case .javascript: .text("JS")
        case .typescript: .text("TS")
        case .kotlin: .text("KT")
        case .java: .text("JV")
        case .groovy: .text("GR")
        case .scala: .text("SC")
        case .c: .text("C")
        case .cpp: .text("C+")
        case .objectiveC: .text("OC")
        case .csharp: .text("C#")
        case .go: .text("GO")
        case .rust: .text("RS")
        case .python: .text("PY")
        case .ruby: .text("RB")
        case .php: .text("PH")
        case .lua: .text("LU")
        case .dart: .text("DA")
        case .perl: .text("PL")
        case .r: .text("R")
        case .graphql: .text("GQ")
        case .protobuf: .text("PB")
        case .hcl: .text("TF")
        case .elixir: .text("EX")
        case .haskell: .text("HS")
        }
    }

    var tint: Color {
        let hex: String = switch self {
        case .plainText, .log, .appleStrings: "#8E8E93"
        case .markdown: "#5B8CFF"
        case .json: "#F2A93B"
        case .yaml: "#FF6B6B"
        case .toml: "#9C6ADE"
        case .ini, .properties: "#7D8BA0"
        case .env: "#2FC28A"
        case .xml: "#FF9F0A"
        case .html: "#E34C26"
        case .css: "#2965F1"
        case .scss: "#CD6799"
        case .less: "#2A4D80"
        case .javascript: "#E8C21A"
        case .typescript: "#3178C6"
        case .swift: "#F05138"
        case .kotlin: "#7F52FF"
        case .java: "#E76F00"
        case .groovy: "#4298B8"
        case .scala: "#DC322F"
        case .c: "#6E7F99"
        case .cpp: "#00599C"
        case .objectiveC: "#438EFF"
        case .csharp: "#68217A"
        case .go: "#00ADD8"
        case .rust: "#CE6A34"
        case .python: "#3776AB"
        case .ruby: "#CC342D"
        case .php: "#777BB4"
        case .lua: "#2C2D72"
        case .dart: "#0175C2"
        case .perl: "#39457E"
        case .r: "#276DC3"
        case .sql: "#E38C00"
        case .shell: "#3FA34D"
        case .powershell: "#5391FE"
        case .dockerfile: "#2496ED"
        case .makefile: "#6D8086"
        case .diff: "#41B883"
        case .csv, .tsv: "#217346"
        case .gitignore: "#F05032"
        case .sshConfig: "#30B0C7"
        case .conf: "#8A8F98"
        case .graphql: "#E10098"
        case .protobuf: "#4285F4"
        case .hcl: "#844FBA"
        case .elixir: "#6E4A7E"
        case .haskell: "#5E5086"
        case .xcconfig: "#1A8CFF"
        }
        return RGBA(hex).color
    }
}

extension URL {
    /// A stable identity for a file: standardized, with macOS's `/private` aliases removed
    /// (`/private/tmp/x` and `/tmp/x` are the same file).
    nonisolated var canonicalPath: String {
        var path = standardizedFileURL.path
        for prefix in ["/private/tmp/", "/private/var/", "/private/etc/"] where path.hasPrefix(prefix) {
            path.removeFirst("/private".count)
        }
        return path
    }

    nonisolated var canonicalFileURL: URL { URL(fileURLWithPath: canonicalPath) }

    /// Whether this is an existing folder (following symlinks).
    nonisolated var isFolder: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `~/path/to` style display of the parent folder.
    var abbreviatedParentPath: String {
        (deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
