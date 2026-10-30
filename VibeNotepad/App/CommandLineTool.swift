import Foundation

/// Installs the `vibeNotePad` shell command bundled with the app.
enum CommandLineTool {
    struct Status {
        var isInstalled: Bool
        var description: String
    }

    static let name = "vibeNotePad"

    private static var candidateDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent("bin"),
        ]
    }

    private static var bundledScript: URL? {
        Bundle.main.url(forResource: "vibeNotePad", withExtension: "sh")
    }

    static func status() -> Status {
        for directory in candidateDirectories {
            let path = directory.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: path) {
                return Status(isInstalled: true, description: String(localized: "Installed at \(path)", comment: "The vibeNotePad command; the placeholder is a path"))
            }
        }
        return Status(isInstalled: false, description: String(localized: "Not installed", comment: "The vibeNotePad command"))
    }

    /// Copies the script to the first writable bin directory (preferring ones on the default PATH).
    @discardableResult
    static func install() -> Status {
        guard let source = bundledScript else {
            return Status(isInstalled: false, description: String(localized: "The script is missing from the app bundle."))
        }
        let fm = FileManager.default
        for directory in candidateDirectories {
            let isHomeDirectory = directory.path.hasPrefix(fm.homeDirectoryForCurrentUser.path)
            if !fm.fileExists(atPath: directory.path) {
                guard isHomeDirectory, directory.lastPathComponent == "bin", directory.deletingLastPathComponent().lastPathComponent == ".local" else { continue }
                try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            guard fm.isWritableFile(atPath: directory.path) else { continue }
            let destination = directory.appendingPathComponent(name)
            do {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: source, to: destination)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
                let message = isHomeDirectory
                    ? String(localized: "Installed at \(destination.path) — make sure \(directory.path) is in your PATH", comment: "The vibeNotePad command; the placeholders are paths")
                    : String(localized: "Installed at \(destination.path)", comment: "The vibeNotePad command; the placeholder is a path")
                return Status(isInstalled: true, description: message)
            } catch {
                continue
            }
        }
        return Status(isInstalled: false, description: String(localized: "No writable bin folder found. Copy the script manually from the app bundle."))
    }
}
