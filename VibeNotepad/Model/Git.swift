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

    /// The branch checked out in the repository at `root` (the first characters of the commit when
    /// detached), read from its HEAD file; nil when `root` isn't a repository's top folder.
    static func branch(at root: URL) -> String? {
        let dotGit = root.appendingPathComponent(".git")
        var gitDirectory = dotGit
        // Worktrees and submodules have a `.git` file pointing to the real folder.
        if !dotGit.isFolder {
            guard let link = try? String(contentsOf: dotGit, encoding: .utf8), link.hasPrefix("gitdir:") else { return nil }
            let path = link.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        }
        guard let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }
        return String(head.prefix(7))
    }

    /// The file's content as staged in git's index (what `git diff` compares the working copy
    /// with). Nil outside a repository and for untracked files.
    static func indexVersion(of file: URL) -> Data? {
        // `:./name` is the index entry for a path relative to the working directory.
        run(["show", ":./" + file.lastPathComponent], in: file.deletingLastPathComponent())
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
