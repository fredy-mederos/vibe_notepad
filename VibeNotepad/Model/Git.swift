import Foundation

/// Runs `git` for the project file list, when git is installed.
nonisolated enum Git {
    /// The git binary, or nil. `/usr/bin/git` is avoided: without the developer tools it's a
    /// stub that pops up an "install the command line developer tools" dialog.
    static let executable: URL? = {
        var candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git"]
        if let developer = run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], in: nil, timeout: 5)
            .flatMap({ String(data: $0, encoding: .utf8) })?
            .trimmingCharacters(in: .whitespacesAndNewlines), !developer.isEmpty {
            candidates.append(developer + "/usr/bin/git")
        }
        candidates.append("/Applications/Xcode.app/Contents/Developer/usr/bin/git")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }()

    /// Runs git with `arguments` in `directory`; returns its output when it succeeds.
    static func run(_ arguments: [String], in directory: URL, timeout: TimeInterval = 10) -> Data? {
        guard let executable else { return nil }
        return run(executable, arguments, in: directory, timeout: timeout)
    }

    /// Files under `directory` that git tracks (plus, with `includeUntracked`, new files that
    /// aren't ignored), relative to `directory`. Nil outside a repository.
    static func listFiles(in directory: URL, includeUntracked: Bool = true) -> [String]? {
        var arguments = ["ls-files", "-z", "--cached"]
        if includeUntracked { arguments += ["--others", "--exclude-standard"] }
        guard let data = run(arguments, in: directory, timeout: 20) else { return nil }
        var seen = Set<String>()
        // Conflicted files are listed once per merge stage.
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { seen.insert($0).inserted }
    }

    private static func run(_ executable: URL, _ arguments: [String], in directory: URL?, timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        var environment = ProcessInfo.processInfo.environment
        // Never take index.lock (a commit in the terminal must not collide with us) and never prompt.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return process.terminationReason == .exit && process.terminationStatus == 0 ? data : nil
    }
}
