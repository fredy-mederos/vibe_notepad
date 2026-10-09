import Foundation
import VibeCore

/// Reading and writing text files.
nonisolated enum FileIO {
    struct Loaded: Sendable {
        var decoded: DecodedText
        var modificationDate: Date?
        var size: Int
    }

    enum FileError: LocalizedError {
        case isDirectory
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .isDirectory: "Folders can't be opened as text."
            case .tooLarge(let size): "The file is too large to open (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
            }
        }
    }

    static let maximumSize = 512 * 1024 * 1024

    static func load(_ url: URL, encoding: String.Encoding? = nil) throws -> Loaded {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        if values.isDirectory == true { throw FileError.isDirectory }
        let size = values.fileSize ?? 0
        if size > maximumSize { throw FileError.tooLarge(size) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoded = try TextFileCodec.decode(data, forced: encoding)
        return Loaded(decoded: decoded, modificationDate: values.contentModificationDate, size: size)
    }

    static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Writes `text` back. Existing files are overwritten in place (following symlinks), which
    /// keeps permissions, extended attributes, hard links and Docker bind mounts intact — like
    /// Sublime Text's default `atomic_save: false`. New files are written atomically.
    static func save(_ text: String, to url: URL, encoding: String.Encoding, hasBOM: Bool, lineEnding: LineEnding) throws -> Date? {
        let data = try TextFileCodec.encode(text, encoding: encoding, hasBOM: hasBOM, lineEnding: lineEnding)
        let target = url.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: target.path) {
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } else {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        return modificationDate(of: target)
    }
}
