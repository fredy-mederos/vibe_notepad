import Foundation

/// Version, build number and build time. The "Stamp build info" build phase writes the build
/// number (the git commit count), the commit and the build date into Info.plist.
enum BuildInfo {
    static var version: String { info("CFBundleShortVersionString") ?? "–" }
    static var build: String { info("CFBundleVersion") ?? "–" }

    /// The build configuration ("Debug" for Vibe Notepad Dev, "Release" for the installed app).
    static var configuration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

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

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
