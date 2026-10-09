import Foundation

public enum LineEnding: String, Codable, Sendable, CaseIterable {
    case lf
    case crlf
    case cr

    public var characters: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }

    public var label: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
    }

    public var description: String {
        switch self {
        case .lf: "LF (macOS / Linux)"
        case .crlf: "CRLF (Windows)"
        case .cr: "CR (Classic Mac)"
        }
    }
}

/// Indentation used by a document.
public struct Indentation: Hashable, Codable, Sendable {
    public var usesTabs: Bool
    public var width: Int

    public init(usesTabs: Bool, width: Int) {
        self.usesTabs = usesTabs
        self.width = max(1, min(width, 16))
    }

    /// The text inserted for one level of indentation.
    public var unit: String { usesTabs ? "\t" : String(repeating: " ", count: width) }

    public var label: String { usesTabs ? "Tabs: \(width)" : "Spaces: \(width)" }
}

/// Text decoded from disk, with everything needed to write it back the same way.
public struct DecodedText: Sendable {
    /// The content with line endings normalized to `\n`.
    public var text: String
    public var encoding: String.Encoding
    public var hasBOM: Bool
    public var lineEnding: LineEnding
}

public enum TextFileCodec {
    public enum CodecError: Error, LocalizedError {
        case binary
        case undecodable
        case unencodable(String)

        public var errorDescription: String? {
            switch self {
            case .binary: "This looks like a binary file."
            case .undecodable: "The file's text encoding could not be determined."
            case .unencodable(let name): "The text contains characters that can't be saved as \(name)."
            }
        }
    }

    /// Encodings offered in the UI.
    public static let commonEncodings: [String.Encoding] = [
        .utf8, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .windowsCP1252, .macOSRoman,
        .ascii, .shiftJIS, .japaneseEUC, .isoLatin2, .windowsCP1251, .utf32,
    ]

    public static func name(of encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: "UTF-8"
        case .utf16, .unicode: "UTF-16"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .utf32: "UTF-32"
        case .utf32LittleEndian: "UTF-32 LE"
        case .utf32BigEndian: "UTF-32 BE"
        case .isoLatin1: "ISO Latin 1"
        case .isoLatin2: "ISO Latin 2"
        case .windowsCP1252: "Windows Latin 1"
        case .windowsCP1251: "Windows Cyrillic"
        case .macOSRoman: "Mac Roman"
        case .ascii: "ASCII"
        case .shiftJIS: "Shift JIS"
        case .japaneseEUC: "EUC-JP"
        default: String.localizedName(of: encoding)
        }
    }

    // MARK: Decoding

    /// Decodes file data, detecting BOMs, UTF-16 without BOM, UTF-8 and legacy 8-bit encodings.
    /// - Parameter forced: decode with this encoding instead of detecting (the "Reopen with Encoding" menu).
    public static func decode(_ data: Data, forced: String.Encoding? = nil) throws -> DecodedText {
        if let forced {
            var body = data
            var bom = false
            if forced == .utf8, data.starts(with: [0xEF, 0xBB, 0xBF]) {
                body = data.dropFirst(3)
                bom = true
            }
            guard let text = String(data: body, encoding: forced) else { throw CodecError.undecodable }
            return finish(text, encoding: forced, hasBOM: bom)
        }

        // Byte order marks.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let text = String(decoding: data.dropFirst(3), as: UTF8.self)
            return finish(text, encoding: .utf8, hasBOM: true)
        }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]), let text = String(data: data, encoding: .utf32) {
            return finish(stripBOM(text), encoding: .utf32LittleEndian, hasBOM: true)
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]), let text = String(data: data, encoding: .utf32) {
            return finish(stripBOM(text), encoding: .utf32BigEndian, hasBOM: true)
        }
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return finish(text, encoding: .utf16LittleEndian, hasBOM: true)
        }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return finish(text, encoding: .utf16BigEndian, hasBOM: true)
        }

        if let utf16 = guessBOMLessUTF16(data) {
            if let text = String(data: data, encoding: utf16) { return finish(text, encoding: utf16, hasBOM: false) }
        }
        if looksBinary(data) { throw CodecError.binary }

        if let text = String(validating: data, as: UTF8.self) {
            return finish(text, encoding: .utf8, hasBOM: false)
        }

        // Legacy encodings: let Foundation guess among the usual suspects.
        var converted: NSString?
        var lossy = ObjCBool(false)
        let guessed = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [String.Encoding.windowsCP1252.rawValue, String.Encoding.isoLatin1.rawValue, String.Encoding.macOSRoman.rawValue, String.Encoding.shiftJIS.rawValue],
                .allowLossyKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: &lossy
        )
        if guessed != 0, let converted {
            return finish(converted as String, encoding: String.Encoding(rawValue: guessed), hasBOM: false)
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return finish(text, encoding: .isoLatin1, hasBOM: false)
        }
        throw CodecError.undecodable
    }

    private static func finish(_ text: String, encoding: String.Encoding, hasBOM: Bool) -> DecodedText {
        let ending = detectLineEnding(in: text)
        return DecodedText(text: normalizeLineEndings(text), encoding: encoding, hasBOM: hasBOM, lineEnding: ending)
    }

    private static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// NUL bytes in the first 8 KB of something that isn't UTF-16/32 mean binary.
    public static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        guard !sample.isEmpty else { return false }
        var nulCount = 0
        var controlCount = 0
        for byte in sample {
            if byte == 0 { nulCount += 1 } else if byte < 0x09 || (byte > 0x0D && byte < 0x20 && byte != 0x1B) { controlCount += 1 }
        }
        return nulCount > 0 || Double(controlCount) / Double(sample.count) > 0.1
    }

    /// Detects UTF-16 text without a BOM by the pattern of zero bytes in ASCII-heavy text.
    private static func guessBOMLessUTF16(_ data: Data) -> String.Encoding? {
        let sample = data.prefix(4096)
        guard sample.count >= 4, sample.count % 2 == 0 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (index, byte) in sample.enumerated() where byte == 0 {
            if index % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
        }
        let half = sample.count / 2
        if oddZeros > half * 7 / 10, evenZeros < half / 10 { return .utf16LittleEndian }
        if evenZeros > half * 7 / 10, oddZeros < half / 10 { return .utf16BigEndian }
        return nil
    }

    // MARK: Encoding

    /// Encodes `text` (with `\n` line endings) for writing to disk.
    public static func encode(_ text: String, encoding: String.Encoding, hasBOM: Bool, lineEnding: LineEnding) throws -> Data {
        let converted = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding.characters)
        var data = Data()
        switch encoding {
        case .utf8:
            if hasBOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
            data.append(contentsOf: converted.utf8)
            return data
        case .utf16LittleEndian:
            if hasBOM { data.append(contentsOf: [0xFF, 0xFE]) }
        case .utf16BigEndian:
            if hasBOM { data.append(contentsOf: [0xFE, 0xFF]) }
        case .utf32LittleEndian:
            if hasBOM { data.append(contentsOf: [0xFF, 0xFE, 0x00, 0x00]) }
        case .utf32BigEndian:
            if hasBOM { data.append(contentsOf: [0x00, 0x00, 0xFE, 0xFF]) }
        default:
            break
        }
        guard let body = converted.data(using: encoding, allowLossyConversion: false) else {
            throw CodecError.unencodable(name(of: encoding))
        }
        data.append(body)
        return data
    }

    // MARK: Line endings & indentation

    /// The most common line terminator in the first ~1 MB (LF when there are none).
    public static func detectLineEnding(in text: String) -> LineEnding {
        var lf = 0, crlf = 0, cr = 0
        var previousWasCR = false
        var scanned = 0
        for unit in text.utf16 {
            scanned += 1
            if scanned > 1_000_000 { break }
            if unit == 0x0A {
                if previousWasCR { crlf += 1 } else { lf += 1 }
                previousWasCR = false
            } else {
                if previousWasCR { cr += 1 }
                previousWasCR = unit == 0x0D
            }
        }
        if previousWasCR { cr += 1 }
        if crlf > lf, crlf >= cr { return .crlf }
        if cr > lf, cr > crlf { return .cr }
        return .lf
    }

    /// Converts CRLF and lone CR to LF.
    public static func normalizeLineEndings(_ text: String) -> String {
        guard text.utf8.contains(0x0D) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Guesses the indentation style from leading whitespace (nil when the text has none).
    public static func detectIndentation(in text: String) -> Indentation? {
        var tabLines = 0, spaceLines = 0
        var deltas: [Int: Int] = [:]
        var previousIndent = 0
        var examined = 0
        text.enumerateLines { line, stop in
            examined += 1
            if examined > 2000 { stop = true; return }
            guard let firstNonSpace = line.firstIndex(where: { $0 != " " && $0 != "\t" }) else { return }
            let leading = line[..<firstNonSpace]
            if leading.hasPrefix("\t") {
                tabLines += 1
                previousIndent = 0
                return
            }
            let spaces = leading.count
            if spaces > 0 { spaceLines += 1 }
            // Ignore the ` * ` continuation of block comments.
            if line[firstNonSpace] == "*" { return }
            let delta = abs(spaces - previousIndent)
            if delta >= 2, delta <= 8 { deltas[delta, default: 0] += 1 }
            previousIndent = spaces
        }
        if tabLines == 0, spaceLines == 0 { return nil }
        if tabLines > spaceLines { return Indentation(usesTabs: true, width: 4) }
        let best = deltas.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key ?? 4
        return Indentation(usesTabs: false, width: [2, 3, 4, 8].contains(best) ? best : 4)
    }
}
