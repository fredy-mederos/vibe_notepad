import Foundation

/// Lexer instances, created once and shared (they are immutable value types).
enum Lexers {
    static let plain = PlainLexer()
    static let markdown = MarkdownLexer()
    static let json = JSONLexer()
    static let yaml = YAMLLexer()
    static let env = EnvLexer()
    static let ini = INILexer()
    static let toml = TOMLLexer()
    static let properties = PropertiesLexer()
    static let conf = ConfLexer()
    static let sshConfig = ConfLexer(sshConfig: true)
    static let xcconfig = XcconfigLexer()
    static let gitignore = GitignoreLexer()
    static let xml = MarkupLexer(html: false)
    static let html = MarkupLexer(html: true)
    static let css = CSSLexer(dialect: .css)
    static let scss = CSSLexer(dialect: .scss)
    static let less = CSSLexer(dialect: .less)
    static let shell = ShellLexer()
    static let dockerfile = DockerfileLexer()
    static let makefile = MakefileLexer()
    static let diff = DiffLexer()
    static let log = LogLexer()
    static let csv = CSVLexer(delimiter: Ch.comma)
    static let tsv = CSVLexer(delimiter: Ch.tab)
    static let swift = CodeLexer(CodeSpecs.swift)
    static let objectiveC = CodeLexer(CodeSpecs.objectiveC)
    static let kotlin = CodeLexer(CodeSpecs.kotlin)
    static let java = CodeLexer(CodeSpecs.java)
    static let groovy = CodeLexer(CodeSpecs.groovy)
    static let scala = CodeLexer(CodeSpecs.scala)
    static let c = CodeLexer(CodeSpecs.c)
    static let cpp = CodeLexer(CodeSpecs.cpp)
    static let csharp = CodeLexer(CodeSpecs.csharp)
    static let go = CodeLexer(CodeSpecs.go)
    static let rust = CodeLexer(CodeSpecs.rust)
    static let javascript = CodeLexer(CodeSpecs.javascript)
    static let typescript = CodeLexer(CodeSpecs.typescript)
    static let php = CodeLexer(CodeSpecs.php)
    static let python = CodeLexer(CodeSpecs.python)
    static let ruby = CodeLexer(CodeSpecs.ruby)
    static let lua = CodeLexer(CodeSpecs.lua)
    static let dart = CodeLexer(CodeSpecs.dart)
    static let perl = CodeLexer(CodeSpecs.perl)
    static let r = CodeLexer(CodeSpecs.r)
    static let elixir = CodeLexer(CodeSpecs.elixir)
    static let haskell = CodeLexer(CodeSpecs.haskell)
    static let sql = CodeLexer(CodeSpecs.sql)
    static let powershell = CodeLexer(CodeSpecs.powershell)
    static let graphql = CodeLexer(CodeSpecs.graphql)
    static let protobuf = CodeLexer(CodeSpecs.protobuf)
    static let hcl = CodeLexer(CodeSpecs.hcl)
    static let appleStrings = CodeLexer(CodeSpecs.appleStrings)
}

public extension LanguageID {
    /// The lexer used to highlight this language.
    var lexer: any SyntaxLexer {
        switch self {
        case .plainText: Lexers.plain
        case .markdown: Lexers.markdown
        case .json: Lexers.json
        case .yaml: Lexers.yaml
        case .env: Lexers.env
        case .ini: Lexers.ini
        case .toml: Lexers.toml
        case .properties: Lexers.properties
        case .conf: Lexers.conf
        case .sshConfig: Lexers.sshConfig
        case .xcconfig: Lexers.xcconfig
        case .gitignore: Lexers.gitignore
        case .xml: Lexers.xml
        case .html: Lexers.html
        case .css: Lexers.css
        case .scss: Lexers.scss
        case .less: Lexers.less
        case .shell: Lexers.shell
        case .dockerfile: Lexers.dockerfile
        case .makefile: Lexers.makefile
        case .diff: Lexers.diff
        case .log: Lexers.log
        case .csv: Lexers.csv
        case .tsv: Lexers.tsv
        case .swift: Lexers.swift
        case .objectiveC: Lexers.objectiveC
        case .kotlin: Lexers.kotlin
        case .java: Lexers.java
        case .groovy: Lexers.groovy
        case .scala: Lexers.scala
        case .c: Lexers.c
        case .cpp: Lexers.cpp
        case .csharp: Lexers.csharp
        case .go: Lexers.go
        case .rust: Lexers.rust
        case .javascript: Lexers.javascript
        case .typescript: Lexers.typescript
        case .php: Lexers.php
        case .python: Lexers.python
        case .ruby: Lexers.ruby
        case .lua: Lexers.lua
        case .dart: Lexers.dart
        case .perl: Lexers.perl
        case .r: Lexers.r
        case .elixir: Lexers.elixir
        case .haskell: Lexers.haskell
        case .sql: Lexers.sql
        case .powershell: Lexers.powershell
        case .graphql: Lexers.graphql
        case .protobuf: Lexers.protobuf
        case .hcl: Lexers.hcl
        case .appleStrings: Lexers.appleStrings
        }
    }
}
