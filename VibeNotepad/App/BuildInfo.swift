import Foundation

/// What Settings → General shows about this copy of Vibe Notepad. The "Stamp build info" build phase writes the
/// build number (the git commit count), the commit and the build time into Info.plist.
enum BuildInfo {
    static let name = "Vibe Notepad"

    static var version: String { info("CFBundleShortVersionString") ?? "–" }
    static var build: String { info("CFBundleVersion") ?? "–" }

    static var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The build configuration ("Debug" for Vibe Notepad Dev, "Release" for the installed app).
    static var configuration: String { isDebug ? "Debug" : "Release" }

    /// Short commit hash, or nil when built outside a git checkout.
    static var commit: String? {
        info("VibeGitCommit").map { $0.hasSuffix("+") ? String($0.dropLast()) : $0 }
    }

    /// The build included changes that weren't committed yet.
    static var hasLocalChanges: Bool { info("VibeGitCommit")?.hasSuffix("+") ?? false }

    static var date: Date? {
        if let stamp = info("VibeBuildDate"), let date = ISO8601DateFormatter().date(from: stamp) { return date }
        // Builds without the stamp: when the executable was linked.
        guard let executable = Bundle.main.executableURL else { return nil }
        return (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// `12 · a481f3a` or `12 · a481f3a + local changes`.
    static var buildDescription: String {
        var text = build
        if let commit { text += " · \(commit)" }
        if hasLocalChanges { text += " + local changes" }
        return text
    }

    /// For pasting into a bug report: `Vibe Notepad 1.0.0 (12, a481f3a), Release, built 2026-10-10 08:01`.
    static var summary: String {
        let details = [build, commit.map { hasLocalChanges ? $0 + "+" : $0 }].compactMap { $0 }.joined(separator: ", ")
        let built = date.map { ", built " + $0.formatted(.iso8601.year().month().day().dateSeparator(.dash)) + " "
            + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return "\(name) \(version) (\(details)), \(configuration)\(built)"
    }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
