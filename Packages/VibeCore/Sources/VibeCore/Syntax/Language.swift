import Foundation

/// Every language the editor knows how to highlight.
public enum LanguageID: String, CaseIterable, Sendable, Codable, Identifiable {
    case plainText = "text"
    case markdown
    case json
    case yaml
    case toml
    case ini
    case properties
    case env
    case xml
    case html
    case css
    case scss
    case less
    case javascript
    case typescript
    case swift
    case kotlin
    case java
    case groovy
    case scala
    case c
    case cpp
    case objectiveC = "objc"
    case csharp
    case go
    case rust
    case python
    case ruby
    case php
    case lua
    case dart
    case perl
    case r
    case sql
    case shell
    case powershell
    case dockerfile
    case makefile
    case diff
    case log
    case csv
    case tsv
    case gitignore
    case sshConfig = "ssh-config"
    case conf
    case graphql
    case protobuf
    case hcl
    case elixir
    case haskell
    case xcconfig
    case appleStrings = "strings"

    public var id: String { rawValue }
    public var info: LanguageInfo { LanguageRegistry.info(self) }
    public var displayName: String { info.name }
}

/// Static metadata for a language.
public struct LanguageInfo: Sendable {
    public let id: LanguageID
    public let name: String
    /// Lowercase file extensions without the dot.
    public let extensions: [String]
    /// Exact lowercase file names (e.g. `dockerfile`, `.zshrc`).
    public let fileNames: [String]
    /// Names accepted in Markdown code-fence info strings.
    public let aliases: [String]
    public let lineComment: String?
    public let blockComment: (open: String, close: String)?
    /// Prose languages get spell checking, word counts and proportional-font options.
    public let isProse: Bool

    init(_ id: LanguageID, _ name: String,
         ext: [String] = [], files: [String] = [], aliases: [String] = [],
         line: String? = nil, block: (String, String)? = nil, prose: Bool = false) {
        self.id = id
        self.name = name
        self.extensions = ext
        self.fileNames = files
        self.aliases = aliases
        self.lineComment = line
        self.blockComment = block.map { (open: $0.0, close: $0.1) }
        self.isProse = prose
    }
}

public enum LanguageRegistry {
    public static let all: [LanguageInfo] = [
        LanguageInfo(.plainText, "Plain Text", ext: ["txt", "text", "pem", "crt", "cer", "csr", "pub", "asc", "rtf"], aliases: ["text", "txt", "plain", "plaintext"], prose: true),
        LanguageInfo(.markdown, "Markdown", ext: ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdx", "rmd", "livemd"], aliases: ["markdown", "md", "mdx"], block: ("<!--", "-->"), prose: true),
        LanguageInfo(.json, "JSON", ext: ["json", "jsonc", "json5", "geojson", "jsonl", "ndjson", "ipynb", "har", "webmanifest", "code-workspace", "resolved", "arb", "avsc", "babelrc", "eslintrc", "jshintrc", "swcrc", "lottie"], files: [".babelrc", ".eslintrc", ".jshintrc", ".swcrc", ".stylelintrc", "composer.lock", ".watchmanconfig"], aliases: ["json", "jsonc", "json5", "jsonl"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.yaml, "YAML", ext: ["yaml", "yml"], files: [".clang-format", ".clang-tidy", "yarn.lock", "podfile.lock", "pubspec.lock", "procfile", ".gemrc"], aliases: ["yaml", "yml"], line: "#"),
        LanguageInfo(.toml, "TOML", ext: ["toml"], files: ["cargo.lock", "poetry.lock", "pdm.lock", "uv.lock", "pipfile"], aliases: ["toml"], line: "#"),
        LanguageInfo(.ini, "INI", ext: ["ini", "cfg", "cnf", "inf", "desktop", "service", "timer", "socket", "mount", "target", "url", "reg", "editorconfig", "gitconfig", "gitmodules"], files: [".gitconfig", ".gitmodules", ".editorconfig", ".npmrc", ".pylintrc", ".flake8", "setup.cfg", "tox.ini", ".coveragerc", "pip.conf", ".pypirc", "my.cnf", ".mailmap"], aliases: ["ini", "cfg", "dosini", "gitconfig", "editorconfig"], line: ";"),
        LanguageInfo(.properties, "Properties", ext: ["properties", "prefs"], aliases: ["properties", "java-properties"], line: "#"),
        LanguageInfo(.env, "Environment (.env)", ext: ["env"], files: [".env", ".flaskenv"], aliases: ["env", "dotenv"], line: "#"),
        LanguageInfo(.xml, "XML", ext: ["xml", "plist", "svg", "xsd", "xsl", "xslt", "rss", "atom", "storyboard", "xib", "xcscheme", "xcworkspacedata", "csproj", "vbproj", "fsproj", "props", "targets", "nuspec", "resx", "wsdl", "kml", "gpx", "dae", "xaml", "entitlements", "xcprivacy", "mobileconfig", "fxml", "tld", "stringsdict", "xliff", "xlf", "iml", "config", "manifest"], aliases: ["xml", "plist", "svg", "xsd", "xsl"], block: ("<!--", "-->")),
        LanguageInfo(.html, "HTML", ext: ["html", "htm", "xhtml", "vue", "svelte", "erb", "ejs", "hbs", "handlebars", "mustache", "jinja", "jinja2", "j2", "twig", "liquid", "njk", "shtml", "astro"], aliases: ["html", "htm", "xhtml", "vue", "svelte", "erb", "astro"], block: ("<!--", "-->")),
        LanguageInfo(.css, "CSS", ext: ["css", "styl", "pcss", "postcss"], aliases: ["css"], block: ("/*", "*/")),
        LanguageInfo(.scss, "SCSS", ext: ["scss", "sass"], aliases: ["scss", "sass"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.less, "Less", ext: ["less"], aliases: ["less"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.javascript, "JavaScript", ext: ["js", "mjs", "cjs", "jsx", "es6", "gs", "jsm"], files: [".eslintrc.js", ".prettierrc.js"], aliases: ["javascript", "js", "jsx", "node", "mjs", "cjs"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.typescript, "TypeScript", ext: ["ts", "mts", "cts", "tsx"], aliases: ["typescript", "ts", "tsx", "mts"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.swift, "Swift", ext: ["swift", "swiftinterface"], aliases: ["swift"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.kotlin, "Kotlin", ext: ["kt", "kts", "ktm"], aliases: ["kotlin", "kt", "kts"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.java, "Java", ext: ["java", "jav", "jsh"], aliases: ["java"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.groovy, "Groovy", ext: ["groovy", "gradle", "gvy", "gy", "gsh"], files: ["jenkinsfile"], aliases: ["groovy", "gradle", "jenkinsfile"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.scala, "Scala", ext: ["scala", "sc", "sbt"], aliases: ["scala", "sbt"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.c, "C", ext: ["c", "h"], aliases: ["c", "h"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.cpp, "C++", ext: ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++", "ipp", "tpp", "inl", "ino", "cu", "cuh", "metal"], aliases: ["cpp", "c++", "cxx", "cc", "hpp", "cuda", "metal"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.objectiveC, "Objective-C", ext: ["m", "mm"], aliases: ["objc", "objective-c", "objectivec", "obj-c", "objc++", "objective-c++"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.csharp, "C#", ext: ["cs", "csx", "cake"], aliases: ["csharp", "cs", "c#"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.go, "Go", ext: ["go"], aliases: ["go", "golang"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.rust, "Rust", ext: ["rs", "ron"], aliases: ["rust", "rs"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.python, "Python", ext: ["py", "pyw", "pyi", "pyx", "pxd", "gyp", "gypi", "wsgi", "bzl", "star", "tac", "pyde"], files: ["build", "build.bazel", "workspace", "workspace.bazel", "sconstruct", "sconscript", "snakefile", ".pythonrc"], aliases: ["python", "py", "python3", "py3", "gyp", "bazel", "starlark"], line: "#"),
        LanguageInfo(.ruby, "Ruby", ext: ["rb", "rbw", "rake", "gemspec", "podspec", "ru", "jbuilder", "rabl", "thor", "irb"], files: ["gemfile", "podfile", "fastfile", "appfile", "matchfile", "pluginfile", "scanfile", "snapfile", "gymfile", "deliverfile", "rakefile", "brewfile", "vagrantfile", "dangerfile", "guardfile", "capfile", "berksfile", ".irbrc", ".pryrc", "steepfile"], aliases: ["ruby", "rb", "podfile", "gemfile", "fastfile"], line: "#", block: ("=begin", "=end")),
        LanguageInfo(.php, "PHP", ext: ["php", "phtml", "php3", "php4", "php5", "php7", "php8", "phps"], aliases: ["php"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.lua, "Lua", ext: ["lua", "luau", "rockspec"], aliases: ["lua", "luau"], line: "--", block: ("--[[", "]]")),
        LanguageInfo(.dart, "Dart", ext: ["dart"], aliases: ["dart", "flutter"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.perl, "Perl", ext: ["pl", "pm", "pod", "perl", "psgi"], aliases: ["perl", "pl"], line: "#"),
        LanguageInfo(.r, "R", ext: ["r", "rprofile"], files: [".rprofile"], aliases: ["r"], line: "#"),
        LanguageInfo(.sql, "SQL", ext: ["sql", "ddl", "dml", "psql", "mysql", "pgsql", "plsql", "hql", "cql", "prql"], aliases: ["sql", "mysql", "postgres", "postgresql", "psql", "sqlite", "plsql", "tsql"], line: "--", block: ("/*", "*/")),
        LanguageInfo(.shell, "Shell", ext: ["sh", "bash", "zsh", "fish", "ksh", "csh", "tcsh", "command", "bats", "zsh-theme", "ebuild", "envrc"], files: [".zshrc", ".bashrc", ".bash_profile", ".profile", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".bash_logout", ".bash_aliases", ".kshrc", ".envrc", "pkgbuild", ".xinitrc", ".xprofile", "gradlew", "mvnw", ".aliases", ".functions", ".exports", ".zpreztorc"], aliases: ["shell", "sh", "bash", "zsh", "fish", "ksh", "console", "shellscript", "terminal"], line: "#"),
        LanguageInfo(.powershell, "PowerShell", ext: ["ps1", "psm1", "psd1"], aliases: ["powershell", "ps1", "pwsh", "ps"], line: "#", block: ("<#", "#>")),
        LanguageInfo(.dockerfile, "Dockerfile", ext: ["dockerfile", "containerfile"], files: ["dockerfile", "containerfile"], aliases: ["dockerfile", "docker", "containerfile"], line: "#"),
        LanguageInfo(.makefile, "Makefile", ext: ["mk", "mak", "make"], files: ["makefile", "gnumakefile", "bsdmakefile"], aliases: ["makefile", "make", "mk"], line: "#"),
        LanguageInfo(.diff, "Diff", ext: ["diff", "patch", "rej"], aliases: ["diff", "patch", "udiff"]),
        LanguageInfo(.log, "Log", ext: ["log", "out", "err"], aliases: ["log"]),
        LanguageInfo(.csv, "CSV", ext: ["csv", "psv"], aliases: ["csv"]),
        LanguageInfo(.tsv, "TSV", ext: ["tsv", "tab"], aliases: ["tsv"]),
        LanguageInfo(.gitignore, "Ignore List", ext: ["gitignore", "dockerignore", "npmignore", "ignore"], files: [".gitignore", ".dockerignore", ".npmignore", ".eslintignore", ".prettierignore", ".stylelintignore", ".hgignore", ".gitattributes", ".slugignore", ".helmignore", ".vscodeignore", ".gcloudignore", ".cfignore", ".rgignore", ".ignore", ".fdignore", ".swiftlint-ignore", "codeowners"], aliases: ["gitignore", "ignore", "gitattributes"], line: "#"),
        LanguageInfo(.sshConfig, "SSH Config", files: ["ssh_config", "sshd_config"], aliases: ["ssh-config", "sshconfig"], line: "#"),
        LanguageInfo(.conf, "Config", ext: ["conf", "nginx", "htaccess", "cmake", "pro", "pri", "rc"], files: ["hosts", ".htaccess", "cmakelists.txt", "cartfile", "cartfile.resolved", "cartfile.private", "go.mod", "go.sum", "go.work", "requirements.txt", "constraints.txt", "gemfile.lock", "nginx.conf", "httpd.conf", "crontab", ".wgetrc", ".curlrc", ".inputrc", ".screenrc", ".tmux.conf", ".vimrc", ".gvimrc", ".exrc", "known_hosts", "authorized_keys", "fstab", "resolv.conf", "sudoers"], aliases: ["conf", "config", "nginx", "apache", "cmake", "tmux"], line: "#"),
        LanguageInfo(.graphql, "GraphQL", ext: ["graphql", "gql", "graphqls"], aliases: ["graphql", "gql"], line: "#"),
        LanguageInfo(.protobuf, "Protocol Buffers", ext: ["proto"], aliases: ["protobuf", "proto"], line: "//", block: ("/*", "*/")),
        LanguageInfo(.hcl, "HCL / Terraform", ext: ["tf", "tfvars", "hcl", "nomad", "tftpl"], aliases: ["hcl", "terraform", "tf"], line: "#", block: ("/*", "*/")),
        LanguageInfo(.elixir, "Elixir", ext: ["ex", "exs", "heex", "eex", "leex"], aliases: ["elixir", "ex", "exs"], line: "#"),
        LanguageInfo(.haskell, "Haskell", ext: ["hs", "lhs"], aliases: ["haskell", "hs"], line: "--", block: ("{-", "-}")),
        LanguageInfo(.xcconfig, "Xcode Config", ext: ["xcconfig"], aliases: ["xcconfig"], line: "//"),
        LanguageInfo(.appleStrings, "Strings / Plist", ext: ["strings", "pbxproj"], aliases: ["strings", "pbxproj"], line: "//", block: ("/*", "*/")),
    ]

    private static let byID: [LanguageID: LanguageInfo] = {
        var map: [LanguageID: LanguageInfo] = [:]
        for info in all { map[info.id] = info }
        return map
    }()

    private static let byExtension: [String: LanguageID] = {
        var map: [String: LanguageID] = [:]
        for info in all { for e in info.extensions where map[e] == nil { map[e] = info.id } }
        return map
    }()

    private static let byFileName: [String: LanguageID] = {
        var map: [String: LanguageID] = [:]
        for info in all { for f in info.fileNames where map[f] == nil { map[f] = info.id } }
        return map
    }()

    private static let byAlias: [String: LanguageID] = {
        var map: [String: LanguageID] = [:]
        for info in all {
            for a in info.aliases where map[a] == nil { map[a] = info.id }
            for e in info.extensions where map[e] == nil { map[e] = info.id }
        }
        return map
    }()

    public static func info(_ id: LanguageID) -> LanguageInfo {
        byID[id] ?? LanguageInfo(id, id.rawValue)
    }

    /// Resolves a Markdown fence info string (`swift`, `js {highlight}`, `language-ts`...).
    public static func language(forFenceInfo infoString: String) -> LanguageID? {
        var word = infoString.trimmingCharacters(in: .whitespaces)
        if let end = word.firstIndex(where: { $0 == " " || $0 == "{" || $0 == "," || $0 == "\t" }) {
            word = String(word[..<end])
        }
        word = word.lowercased()
        if word.hasPrefix("language-") { word = String(word.dropFirst("language-".count)) }
        if word.hasPrefix(".") { word = String(word.dropFirst()) }
        guard !word.isEmpty else { return nil }
        return byAlias[word]
    }

    /// Picks a language from a file path (name, extension, well-known locations) and,
    /// when the name is not conclusive, from the beginning of the content.
    public static func detect(path: String, content: String? = nil) -> LanguageID {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()

        if let id = detectByName(name, parent: parent) {
            // `.h` headers are shared by C, C++ and Objective-C: refine using the content.
            if id == .c, name.hasSuffix(".h"), let content { return refineHeader(content) }
            return id
        }
        if let content, let id = detectByContent(content) { return id }
        return .plainText
    }

    static func detectByName(_ name: String, parent: String) -> LanguageID? {
        // dotenv family: .env, .env.local, .env.production, app.env, .env.example...
        if name == ".envrc" { return .shell }
        if name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") {
            return .env
        }
        if parent == ".ssh", name == "config" || name.hasSuffix(".conf") { return .sshConfig }
        if parent == ".git", name == "config" { return .ini }
        if let id = byFileName[name] { return id }
        // `Dockerfile.dev`, `Makefile.am`… but `dockerfile-notes.md` is Markdown.
        let hasKnownExtension = name.lastIndex(of: ".").map { dot in
            dot != name.startIndex && byExtension[String(name[name.index(after: dot)...])] != nil
        } ?? false
        if !hasKnownExtension {
            if name.hasPrefix("dockerfile") || name.hasPrefix("containerfile") { return .dockerfile }
            if name.hasPrefix("makefile") || name.hasPrefix("gnumakefile") { return .makefile }
            if name.hasPrefix("jenkinsfile") { return .groovy }
        }
        if name.hasSuffix(".dockerfile") { return .dockerfile }
        if name.hasPrefix("requirements") && name.hasSuffix(".txt") { return .conf }
        if name.hasSuffix(".log") || name.contains(".log.") { return .log }
        if name.hasSuffix(".d.ts") { return .typescript }
        if name.hasSuffix(".gradle.kts") { return .kotlin }
        if name.hasPrefix(".") && name.hasSuffix("rc") && !name.contains(".", after: 1) {
            // .prettierrc, .babelrc etc. without extension are usually JSON; shells are listed explicitly.
            return nil
        }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let ext = String(name[name.index(after: dot)...])
            if let id = byExtension[ext] { return id }
        } else if name.hasPrefix("."), let id = byExtension[String(name.dropFirst())] {
            // `.gitignore`-style names whose "extension" is the whole name.
            return id
        }
        return nil
    }

    static func refineHeader(_ content: String) -> LanguageID {
        let head = content.prefix(16_384)
        if head.contains("@interface") || head.contains("@protocol") || head.contains("#import") || head.contains("NS_ASSUME_NONNULL") {
            return .objectiveC
        }
        if head.contains("namespace ") || head.contains("template <") || head.contains("template<") || head.contains("std::") || head.contains("class ") {
            return .cpp
        }
        return .c
    }

    /// Guesses from content: shebang lines first, then well-known shapes.
    public static func detectByContent(_ content: String) -> LanguageID? {
        let head = content.prefix(4096)
        let firstLine = head.prefix(while: { $0 != "\n" && $0 != "\r" })
        if firstLine.hasPrefix("#!") { return shebangLanguage(firstLine) }
        let trimmed = head.drop(while: { $0.isWhitespace })
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<plist") || trimmed.hasPrefix("<svg") { return .xml }
        let lowerHead = trimmed.prefix(64).lowercased()
        if lowerHead.hasPrefix("<!doctype html") || lowerHead.hasPrefix("<html") { return .html }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if looksLikeJSON(trimmed) { return .json }
        }
        if head.hasPrefix("diff --git") || head.hasPrefix("--- ") && head.contains("\n+++ ") { return .diff }
        if head.hasPrefix("---\n") {
            // Front matter followed by Markdown, or a YAML document?
            if let close = head.range(of: "\n---\n", range: head.index(head.startIndex, offsetBy: 3)..<head.endIndex),
               looksLikeMarkdown(head[close.upperBound...], threshold: 2) {
                return .markdown
            }
            return .yaml
        }
        if head.hasPrefix("%YAML") { return .yaml }
        if looksLikeEnv(head) { return .env }
        if looksLikeMarkdown(head) { return .markdown }
        return nil
    }

    /// The language of a `#!` line's interpreter (`#!/usr/bin/env -S python3.12 -u` → Python).
    static func shebangLanguage(_ line: Substring) -> LanguageID {
        var tokens = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return .shell }
        var program = (tokens.removeFirst() as NSString).lastPathComponent
        if program == "env" {
            // env [-S] [-i] [NAME=value…] program
            while let next = tokens.first, next.hasPrefix("-") || next.contains("=") { tokens.removeFirst() }
            program = tokens.first.map { ($0 as NSString).lastPathComponent } ?? ""
        }
        // python3.12 → python, ruby2.7 → ruby
        switch String(program.lowercased().prefix { $0.isLetter }) {
        case "python", "pypy": return .python
        case "node", "nodejs", "bun", "zx": return .javascript
        case "deno", "tsx", "ts": return .typescript
        case "ruby", "jruby": return .ruby
        case "perl": return .perl
        case "php": return .php
        case "swift": return .swift
        case "lua", "luajit": return .lua
        case "rscript": return .r
        case "pwsh", "powershell": return .powershell
        case "groovy": return .groovy
        case "kotlin", "kotlinc", "kscript": return .kotlin
        case "make", "gmake": return .makefile
        case "elixir": return .elixir
        case "osascript": return .plainText
        default: return .shell
        }
    }

    private static func looksLikeJSON(_ text: Substring) -> Bool {
        // Cheap check: the first non-space character after the bracket is a quote, bracket, brace, digit or literal.
        var it = text.dropFirst().drop(while: { $0.isWhitespace })
        guard let c = it.first else { return true }
        if c == "\"" || c == "{" || c == "[" || c == "]" || c == "}" || c.isNumber || c == "-" { return true }
        it = it.prefix(5)
        return it.hasPrefix("true") || it.hasPrefix("false") || it.hasPrefix("null")
    }

    private static func looksLikeEnv(_ text: Substring) -> Bool {
        var assignments = 0, others = 0
        for line in text.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            var body = Substring(t)
            if body.hasPrefix("export ") { body = body.dropFirst(7) }
            if let eq = body.firstIndex(of: "="), eq != body.startIndex,
               body[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) {
                assignments += 1
            } else {
                others += 1
            }
        }
        return assignments >= 2 && others == 0
    }

    private static func looksLikeMarkdown(_ text: Substring, threshold: Int = 3) -> Bool {
        var score = 0
        for line in text.split(separator: "\n", maxSplits: 60, omittingEmptySubsequences: true) {
            if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") { score += 2 }
            if line.hasPrefix("```") { score += 2 }
            if line.hasPrefix("- [ ]") || line.hasPrefix("- [x]") { score += 2 }
            if line.contains("](") { score += 1 }
        }
        return score >= threshold
    }
}

private extension String {
    /// Whether `ch` appears after the first `offset` characters.
    func contains(_ ch: Character, after offset: Int) -> Bool {
        dropFirst(offset).contains(ch)
    }
}
