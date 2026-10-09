import Foundation

/// XML and HTML, including HTML-based templates (Vue, Svelte, ERB/EJS, Handlebars, Jinja, Liquid…).
///
/// State:
/// - `mode`: 0 text, 1 comment, 2 CDATA, 3 inside a tag, 4 inside a quoted attribute value,
///   5 raw `<script>`/`<style>` content, 6 inside a template tag (`{{ … }}`, `{% … %}`, `<% … %>`),
///   7 inside a declaration (`<!DOCTYPE …>`), 8 inside a processing instruction (`<?xml … ?>`).
/// - `sub`: in modes 3–5 the kind of the current tag (plain, or a script/style flavor); in mode 6 the
///   template kind; in mode 8, 1 for opaque instructions (`<?php … ?>`).
/// - `depth`: in mode 4 the quote (1 = `"`, 2 = `'`).
/// - In mode 5, `LineState.embedded`/`inner` hold the embedded language (JavaScript, CSS…) and its state.
public struct MarkupLexer: SyntaxLexer {
    public let html: Bool

    public init(html: Bool = false) {
        self.html = html
    }

    enum Mode {
        static let text: UInt8 = 0
        static let comment: UInt8 = 1
        static let cdata: UInt8 = 2
        static let tag: UInt8 = 3
        static let attributeValue: UInt8 = 4
        static let raw: UInt8 = 5
        static let template: UInt8 = 6
        static let declaration: UInt8 = 7
        static let instruction: UInt8 = 8
    }

    enum Tag {
        static let normal: UInt8 = 0
        static let script: UInt8 = 1
        static let style: UInt8 = 2
        static let scriptJSON: UInt8 = 3
        static let scriptTemplate: UInt8 = 4
        static let scriptRaw: UInt8 = 5
        static let scriptTS: UInt8 = 6
        static let styleSCSS: UInt8 = 7
        static let styleLess: UInt8 = 8
    }

    enum Template {
        static let mustache: UInt8 = 1        // {{ … }}
        static let triple: UInt8 = 2          // {{{ … }}}
        static let block: UInt8 = 3           // {% … %}
        static let comment: UInt8 = 4         // {# … #}
        static let mustacheComment: UInt8 = 5 // {{! … }}
        static let erb: UInt8 = 6             // <% … %>
        static let erbComment: UInt8 = 7      // <%# … %>
    }

    private static let commentOpen = u16("<!--")
    private static let commentClose = u16("-->")
    private static let cdataOpen = u16("<![CDATA[")
    private static let cdataClose = u16("]]>")
    private static let instructionClose = u16("?>")
    private static let scriptName = u16("script")
    private static let styleName = u16("style")
    private static let typeName = u16("type")
    private static let langName = u16("lang")
    private static let onPrefix = u16("on")
    private static let closers: [[UInt16]] = [[], u16("}}"), u16("}}}"), u16("%}"), u16("#}"), u16("}}"), u16("%>"), u16("%>")]
    private static let rubyKeywords = ConfigLexKit.words("if else elsif end unless do for while until case when begin rescue ensure")
    private static let templateKeywords = ConfigLexKit.words("else elif endif endfor endblock")

    public func lex(_ line: LineBuffer, state: inout LineState, tokens: inout TokenBuffer) {
        var st = state.main
        var i = line.start
        let end = line.end
        while i < end {
            switch st.mode {
            case Mode.comment:
                if let close = line.find(Self.commentClose, from: i) {
                    tokens.add(i, close + 3, .comment)
                    i = close + 3
                    st = .initial
                } else {
                    tokens.add(i, end, .comment)
                    i = end
                }
            case Mode.cdata:
                if let close = line.find(Self.cdataClose, from: i) {
                    tokens.add(i, close, .string)
                    tokens.add(close, close + 3, .meta)
                    i = close + 3
                    st = .initial
                } else {
                    tokens.add(i, end, .string)
                    i = end
                }
            case Mode.tag, Mode.attributeValue:
                i = lexTag(line, from: i, st: &st, state: &state, tokens: &tokens)
            case Mode.raw:
                i = lexRaw(line, from: i, st: &st, state: &state, tokens: &tokens)
            case Mode.template:
                i = lexTemplateBody(line, from: i, st: &st, tokens: &tokens)
            case Mode.declaration:
                i = lexDeclaration(line, from: i, tokenStart: i, st: &st, tokens: &tokens)
            case Mode.instruction:
                i = lexInstruction(line, from: i, st: &st, tokens: &tokens)
            default:
                i = lexText(line, from: i, st: &st, tokens: &tokens)
            }
        }
        state.main = st
    }

    // MARK: Text

    private func lexText(_ line: LineBuffer, from i: Int, st: inout LexState, tokens: inout TokenBuffer) -> Int {
        let end = line.end
        var j = i
        while j < end {
            let c = line[j]
            if c == Ch.lt {
                let n = line[j + 1]
                if line.matches(Self.commentOpen, at: j) {
                    if let close = line.find(Self.commentClose, from: j + 4) {
                        tokens.add(j, close + 3, .comment)
                        j = close + 3
                        continue
                    }
                    tokens.add(j, end, .comment)
                    st = LexState(mode: Mode.comment)
                    return end
                }
                if line.matches(Self.cdataOpen, at: j) {
                    tokens.add(j, j + 9, .meta)
                    if let close = line.find(Self.cdataClose, from: j + 9) {
                        tokens.add(j + 9, close, .string)
                        tokens.add(close, close + 3, .meta)
                        j = close + 3
                        continue
                    }
                    tokens.add(j + 9, end, .string)
                    st = LexState(mode: Mode.cdata)
                    return end
                }
                if n == Ch.bang, Ch.isAlpha(line[j + 2]) || line[j + 2] == Ch.lbracket {
                    return lexDeclaration(line, from: j + 2, tokenStart: j, st: &st, tokens: &tokens)
                }
                if n == Ch.question {
                    var ne = j + 2
                    while ne < end, isNameChar(line[ne]) { ne += 1 }
                    tokens.add(j, ne, .meta)
                    let xml = ne - j - 2 >= 3 && line.matchesIgnoringCase(u16("xml"), at: j + 2)
                    st = LexState(mode: Mode.instruction, sub: xml ? 0 : 1)
                    return ne
                }
                if html, n == Ch.percent, let t = templateStart(line, at: j) {
                    let r = lexTemplate(line, at: j, kind: t.kind, openEnd: t.openEnd, limit: end, multiline: true, st: &st, tokens: &tokens)
                    if st.mode == Mode.template { return end }
                    j = r
                    continue
                }
                if n == Ch.slash, isNameStart(line[j + 2]) {
                    tokens.add(j, j + 2, .punctuation)
                    let ne = scanName(line, from: j + 2)
                    tokens.add(j + 2, ne, .tag)
                    st = LexState(mode: Mode.tag)
                    return ne
                }
                if isNameStart(n) {
                    tokens.add(j, j + 1, .punctuation)
                    let ne = scanName(line, from: j + 1)
                    tokens.add(j + 1, ne, .tag)
                    st = LexState(mode: Mode.tag, sub: html ? tagKind(line, j + 1, ne) : Tag.normal)
                    return ne
                }
                j += 1
                continue
            }
            if c == Ch.amp, let e = entityEnd(line, at: j) {
                tokens.add(j, e, .escape)
                j = e
                continue
            }
            if html, c == Ch.lbrace, let t = templateStart(line, at: j) {
                let r = lexTemplate(line, at: j, kind: t.kind, openEnd: t.openEnd, limit: end, multiline: true, st: &st, tokens: &tokens)
                if st.mode == Mode.template { return end }
                j = r
                continue
            }
            if !html, c == Ch.dollar, line[j + 1] == Ch.lbrace,
               let close = ConfigLexKit.find(line, Ch.rbrace, from: j + 2, limit: min(end, j + ConfigLexKit.referenceWindow)) {
                tokens.add(j, close + 1, .variable)
                j = close + 1
                continue
            }
            j += 1
        }
        return end
    }

    @inline(__always)
    private func isNameStart(_ c: UInt16) -> Bool {
        Ch.isAlpha(c) || c == Ch.underscore || c == Ch.colon || (c >= 0x80 && !Ch.isSpace(c))
    }

    @inline(__always)
    private func isNameChar(_ c: UInt16) -> Bool {
        isNameStart(c) || Ch.isDigit(c) || c == Ch.minus || c == Ch.dot
    }

    private func scanName(_ line: LineBuffer, from s: Int) -> Int {
        var e = s
        while e < line.end, isNameChar(line[e]) { e += 1 }
        return e
    }

    private func tagKind(_ line: LineBuffer, _ s: Int, _ e: Int) -> UInt8 {
        if e - s == 6, line.matchesIgnoringCase(Self.scriptName, at: s) { return Tag.script }
        if e - s == 5, line.matchesIgnoringCase(Self.styleName, at: s) { return Tag.style }
        return Tag.normal
    }

    /// `&amp;`, `&#123;`, `&#x1F;`
    private func entityEnd(_ line: LineBuffer, at j: Int) -> Int? {
        var k = j + 1
        if line[k] == Ch.hash {
            k += 1
            let hex = line[k] == Ch.x || line[k] == 0x58
            if hex { k += 1 }
            let s = k
            while k < line.end, k - s < 8, hex ? Ch.isHexDigit(line[k]) : Ch.isDigit(line[k]) { k += 1 }
            guard k > s else { return nil }
        } else {
            let s = k
            while k < line.end, k - s < 32, Ch.isAlnum(line[k]) { k += 1 }
            guard k > s else { return nil }
        }
        return line[k] == Ch.semicolon ? k + 1 : nil
    }

    // MARK: Tags

    private enum AttributeName { case other, type, lang, style, script }

    private func lexTag(_ line: LineBuffer, from i: Int, st: inout LexState, state: inout LineState, tokens: inout TokenBuffer) -> Int {
        let end = line.end
        var j = i
        if st.mode == Mode.attributeValue {
            let q = st.depth == 2 ? Ch.apostrophe : Ch.quote
            guard let close = ConfigLexKit.find(line, q, from: j, limit: end) else {
                lexAttributeValue(line, j, end, tokens: &tokens)
                return end
            }
            lexAttributeValue(line, j, close + 1, tokens: &tokens)
            j = close + 1
            st.mode = Mode.tag
            st.depth = 0
        }
        var attribute = AttributeName.other
        while j < end {
            let c = line[j]
            if Ch.isSpace(c) {
                j += 1
                continue
            }
            if c == Ch.gt {
                tokens.add(j, j + 1, .punctuation)
                enterContent(&st, &state)
                return j + 1
            }
            if c == Ch.slash, line[j + 1] == Ch.gt {
                tokens.add(j, j + 2, .punctuation)
                st = .initial
                return j + 2
            }
            if html, c == Ch.lbrace || c == Ch.lt, let t = templateStart(line, at: j) {
                j = lexTemplate(line, at: j, kind: t.kind, openEnd: t.openEnd, limit: end, multiline: false, st: &st, tokens: &tokens)
                continue
            }
            if c == Ch.lt {
                // A new tag before this one was closed: recover in text mode.
                st = .initial
                return j
            }
            if c == Ch.quote || c == Ch.apostrophe {
                guard let close = ConfigLexKit.find(line, c, from: j + 1, limit: end) else {
                    lexAttributeValue(line, j, end, tokens: &tokens)
                    st.mode = Mode.attributeValue
                    st.depth = c == Ch.quote ? 1 : 2
                    return end
                }
                lexAttributeValue(line, j, close + 1, tokens: &tokens)
                j = close + 1
                continue
            }
            if c == Ch.equals {
                tokens.add(j, j + 1, .punctuation)
                j += 1
                while j < end, Ch.isSpace(line[j]) { j += 1 }
                guard j < end else { return end }
                let v = line[j]
                if v == Ch.quote || v == Ch.apostrophe {
                    guard let close = ConfigLexKit.find(line, v, from: j + 1, limit: end) else {
                        lexAttributeValue(line, j, end, tokens: &tokens)
                        st.mode = Mode.attributeValue
                        st.depth = v == Ch.quote ? 1 : 2
                        return end
                    }
                    if attribute == .style || attribute == .script, close > j + 1, !containsTemplate(line, j + 1, close) {
                        // `style="color: red"` is CSS; `onclick="go()"`, `@click="n++"` are JavaScript.
                        tokens.add(j, j + 1, .string)
                        var scratch = LexState.initial
                        lexEmbedded(attribute == .style ? .css : .javascript, line.slice(j + 1, close), inner: &scratch, tokens: &tokens)
                        tokens.add(close, close + 1, .string)
                    } else {
                        lexAttributeValue(line, j, close + 1, tokens: &tokens)
                    }
                    updateKind(&st, attribute, line, j + 1, close)
                    j = close + 1
                } else if v != Ch.gt {
                    var ve = j
                    while ve < end, !Ch.isSpace(line[ve]), line[ve] != Ch.gt { ve += 1 }
                    tokens.add(j, ve, .string)
                    updateKind(&st, attribute, line, j, ve)
                    j = ve
                }
                attribute = .other
                continue
            }
            var ne = j
            while ne < end, isAttributeNameChar(line[ne]) { ne += 1 }
            if ne == j {
                j += 1
                continue
            }
            tokens.add(j, ne, .attribute)
            attribute = attributeName(line, j, ne)
            j = ne
        }
        return end
    }

    @inline(__always)
    private func isAttributeNameChar(_ c: UInt16) -> Bool {
        !(Ch.isSpace(c) || c == Ch.quote || c == Ch.apostrophe || c == Ch.gt || c == Ch.slash || c == Ch.equals || c == Ch.lt)
    }

    private func attributeName(_ line: LineBuffer, _ s: Int, _ e: Int) -> AttributeName {
        if e - s == 4, line.matchesIgnoringCase(Self.typeName, at: s) { return .type }
        if e - s == 4, line.matchesIgnoringCase(Self.langName, at: s) { return .lang }
        guard html else { return .other }
        if e - s == 5, line.matchesIgnoringCase(Self.styleName, at: s) { return .style }
        // Event handlers and framework bindings hold JavaScript: onclick, @click, :prop, v-if, x-data,
        // [prop], (event), *ngIf.
        let c = line[s]
        if c == Ch.at || c == Ch.colon || c == Ch.lbracket || c == Ch.lparen || c == Ch.star { return e - s > 1 ? .script : .other }
        if e - s > 2, line[s + 1] == Ch.minus, c == 0x76 || c == 0x78 { return .script }
        if e - s > 3, line.matchesIgnoringCase(Self.onPrefix, at: s), Ch.isAlpha(line[s + 2]) {
            var k = s + 2
            while k < e, Ch.isAlpha(line[k]) { k += 1 }
            return k == e ? .script : .other
        }
        return .other
    }

    /// Whether `[s, e)` contains a template tag, which keeps an attribute value a plain string.
    private func containsTemplate(_ line: LineBuffer, _ s: Int, _ e: Int) -> Bool {
        var k = s
        while k + 1 < e {
            let c = line[k], n = line[k + 1]
            if (c == Ch.lbrace && (n == Ch.lbrace || n == Ch.percent)) || (c == Ch.lt && n == Ch.percent) { return true }
            k += 1
        }
        return false
    }

    private func isScript(_ kind: UInt8) -> Bool {
        kind == Tag.script || kind == Tag.scriptJSON || kind == Tag.scriptTemplate || kind == Tag.scriptRaw || kind == Tag.scriptTS
    }

    private func isStyle(_ kind: UInt8) -> Bool {
        kind == Tag.style || kind == Tag.styleSCSS || kind == Tag.styleLess
    }

    private func embeddedLanguage(_ kind: UInt8) -> LanguageID? {
        switch kind {
        case Tag.script: .javascript
        case Tag.scriptTS: .typescript
        case Tag.scriptJSON: .json
        case Tag.style: .css
        case Tag.styleSCSS: .scss
        case Tag.styleLess: .less
        default: nil
        }
    }

    /// `type`/`lang` attributes pick the language of `<script>` and `<style>` contents.
    private func updateKind(_ st: inout LexState, _ attribute: AttributeName, _ line: LineBuffer, _ s: Int, _ e: Int) {
        guard attribute == .type || attribute == .lang, isScript(st.sub) || isStyle(st.sub), e - s <= 64 else { return }
        let value = line.lowercasedString(s, e).trimmingCharacters(in: .whitespaces)
        if isScript(st.sub) {
            if attribute == .lang {
                if value == "ts" || value == "tsx" || value == "typescript" { st.sub = Tag.scriptTS }
                if value == "js" || value == "jsx" || value == "javascript" { st.sub = Tag.script }
                return
            }
            switch value {
            case "", "text/javascript", "application/javascript", "module", "text/babel", "text/jsx", "jsx",
                 "application/ecmascript", "text/ecmascript", "application/x-javascript":
                st.sub = Tag.script
            case _ where value.contains("json") || value == "importmap" || value == "speculationrules":
                st.sub = Tag.scriptJSON
            case _ where value.contains("typescript"):
                st.sub = Tag.scriptTS
            case _ where value.contains("template") || value.contains("html") || value.contains("handlebars")
                || value.contains("mustache") || value.contains("x-tmpl"):
                st.sub = Tag.scriptTemplate
            default:
                st.sub = Tag.scriptRaw
            }
        } else {
            if value.contains("scss") || value == "sass" {
                st.sub = Tag.styleSCSS
            } else if value.contains("less") {
                st.sub = Tag.styleLess
            } else if value == "css" || value == "text/css" || value == "postcss" {
                st.sub = Tag.style
            }
        }
    }

    /// After the `>` of a start tag: text, or raw script/style content.
    private func enterContent(_ st: inout LexState, _ state: inout LineState) {
        let kind = st.sub
        if kind == Tag.normal || kind == Tag.scriptTemplate {
            st = .initial
            return
        }
        st = LexState(mode: Mode.raw, sub: kind)
        state.embedded = embeddedLanguage(kind)
        state.inner = .initial
    }

    /// Attribute values: strings with entities, template tags (HTML) and `${…}` placeholders (XML).
    private func lexAttributeValue(_ line: LineBuffer, _ s: Int, _ e: Int, tokens: inout TokenBuffer) {
        var seg = s
        var k = s
        while k < e {
            let c = line[k]
            if c == Ch.amp, let ee = entityEnd(line, at: k), ee <= e {
                tokens.add(seg, k, .string)
                tokens.add(k, ee, .escape)
                k = ee
                seg = k
                continue
            }
            if html, c == Ch.lbrace || c == Ch.lt, let t = templateStart(line, at: k),
               let close = ConfigLexKit.find(line, Self.closers[Int(t.kind)], from: t.openEnd, limit: min(e, t.openEnd + 1024)) {
                tokens.add(seg, k, .string)
                emitTemplate(line, start: k, openEnd: t.openEnd, close: close, kind: t.kind, tokens: &tokens)
                k = close + Self.closers[Int(t.kind)].count
                seg = k
                continue
            }
            if !html, c == Ch.dollar, line[k + 1] == Ch.lbrace, let close = ConfigLexKit.find(line, Ch.rbrace, from: k + 2, limit: e) {
                tokens.add(seg, k, .string)
                tokens.add(k, close + 1, .variable)
                k = close + 1
                seg = k
                continue
            }
            k += 1
        }
        tokens.add(seg, e, .string)
    }

    // MARK: Raw content

    private func lexRaw(_ line: LineBuffer, from i: Int, st: inout LexState, state: inout LineState, tokens: inout TokenBuffer) -> Int {
        let end = line.end
        let name = isScript(st.sub) ? Self.scriptName : Self.styleName
        var close: Int?
        var k = i
        while k + 1 < end {
            if line[k] == Ch.lt, line[k + 1] == Ch.slash, line.matchesIgnoringCase(name, at: k + 2), !isNameChar(line[k + 2 + name.count]) {
                close = k
                break
            }
            k += 1
        }
        let segmentEnd = close ?? end
        if segmentEnd > i, let language = embeddedLanguage(st.sub) {
            lexEmbedded(language, line.slice(i, segmentEnd), inner: &state.inner, tokens: &tokens)
        }
        guard let close else { return end }
        st = .initial
        state.embedded = nil
        state.inner = .initial
        return close
    }

    // MARK: Declarations and instructions

    /// `<!DOCTYPE html PUBLIC "…">`: meta with quoted parts as strings.
    private func lexDeclaration(_ line: LineBuffer, from k: Int, tokenStart: Int, st: inout LexState, tokens: inout TokenBuffer) -> Int {
        let end = line.end
        var seg = tokenStart
        var j = k
        while j < end {
            let c = line[j]
            if c == Ch.quote || c == Ch.apostrophe {
                tokens.add(seg, j, .meta)
                guard let close = ConfigLexKit.find(line, c, from: j + 1, limit: end) else {
                    tokens.add(j, end, .string)
                    st = LexState(mode: Mode.declaration)
                    return end
                }
                tokens.add(j, close + 1, .string)
                j = close + 1
                seg = j
                continue
            }
            if c == Ch.gt || c == Ch.lbracket {
                // `[` starts a DOCTYPE internal subset, whose declarations are lexed on their own.
                tokens.add(seg, j + 1, .meta)
                st = .initial
                return j + 1
            }
            j += 1
        }
        tokens.add(seg, end, .meta)
        st = LexState(mode: Mode.declaration)
        return end
    }

    /// The inside of `<?xml version="1.0"?>` (attributes) or `<?php … ?>` (opaque).
    private func lexInstruction(_ line: LineBuffer, from i: Int, st: inout LexState, tokens: inout TokenBuffer) -> Int {
        let end = line.end
        if st.sub == 1 {
            guard let close = line.find(Self.instructionClose, from: i) else {
                tokens.add(i, end, .meta)
                return end
            }
            tokens.add(i, close + 2, .meta)
            st = .initial
            return close + 2
        }
        var j = i
        while j < end {
            let c = line[j]
            if Ch.isSpace(c) {
                j += 1
            } else if c == Ch.question, line[j + 1] == Ch.gt {
                tokens.add(j, j + 2, .meta)
                st = .initial
                return j + 2
            } else if c == Ch.quote || c == Ch.apostrophe {
                let close = ConfigLexKit.find(line, c, from: j + 1, limit: end).map { $0 + 1 } ?? end
                tokens.add(j, close, .string)
                j = close
            } else if c == Ch.equals {
                tokens.add(j, j + 1, .punctuation)
                j += 1
            } else if isNameStart(c) {
                let e = scanName(line, from: j)
                tokens.add(j, e, .attribute)
                j = e
            } else {
                j += 1
            }
        }
        return end
    }

    // MARK: Templates

    /// Recognizes `{{`, `{{{`, `{{!`, `{%`, `{#` and `<%` (HTML only).
    private func templateStart(_ line: LineBuffer, at j: Int) -> (kind: UInt8, openEnd: Int)? {
        guard html else { return nil }
        let c = line[j], n = line[j + 1]
        if c == Ch.lbrace {
            if n == Ch.lbrace {
                let m = line[j + 2]
                if m == Ch.lbrace { return (Template.triple, j + 3) }
                if m == Ch.bang { return (Template.mustacheComment, j + 3) }
                return (Template.mustache, j + 2)
            }
            if n == Ch.percent { return (Template.block, j + 2) }
            // `{# comment #}`; Svelte blocks such as `{#if x}` are not comments.
            if n == Ch.hash, !Ch.isAlpha(line[j + 2]) { return (Template.comment, j + 2) }
            return nil
        }
        if c == Ch.lt, n == Ch.percent {
            let m = line[j + 2]
            if m == Ch.hash { return (Template.erbComment, j + 3) }
            if m == Ch.equals || m == Ch.minus || m == Ch.underscore { return (Template.erb, j + 3) }
            return (Template.erb, j + 2)
        }
        return nil
    }

    private func isCommentTemplate(_ kind: UInt8) -> Bool {
        kind == Template.comment || kind == Template.mustacheComment || kind == Template.erbComment
    }

    /// Lexes a template tag opening at `j`. Returns the index after its closer, or `limit` when it
    /// does not close before (with `multiline`, the state then continues it on the next line).
    private func lexTemplate(_ line: LineBuffer, at j: Int, kind: UInt8, openEnd: Int, limit: Int, multiline: Bool,
                             st: inout LexState, tokens: inout TokenBuffer) -> Int {
        let closer = Self.closers[Int(kind)]
        if let close = line.find(closer, from: openEnd), close + closer.count <= limit {
            emitTemplate(line, start: j, openEnd: openEnd, close: close, kind: kind, tokens: &tokens)
            return close + closer.count
        }
        if isCommentTemplate(kind) {
            tokens.add(j, limit, .comment)
        } else {
            tokens.add(j, openEnd, .escape)
            lexTemplateContent(line, from: openEnd, to: limit, kind: kind, tokens: &tokens)
        }
        if multiline { st = LexState(mode: Mode.template, sub: kind) }
        return limit
    }

    private func emitTemplate(_ line: LineBuffer, start j: Int, openEnd: Int, close: Int, kind: UInt8, tokens: inout TokenBuffer) {
        let closeEnd = close + Self.closers[Int(kind)].count
        if isCommentTemplate(kind) {
            tokens.add(j, closeEnd, .comment)
            return
        }
        var contentStart = openEnd
        var contentEnd = close
        // Whitespace control markers belong to the delimiters: `{{- x -}}`, `{%- x -%}`, `{{~ x ~}}`.
        if contentStart < contentEnd, line[contentStart] == Ch.minus || line[contentStart] == Ch.tilde { contentStart += 1 }
        if contentEnd > contentStart, line[contentEnd - 1] == Ch.minus || line[contentEnd - 1] == Ch.tilde { contentEnd -= 1 }
        tokens.add(j, contentStart, .escape)
        lexTemplateContent(line, from: contentStart, to: contentEnd, kind: kind, tokens: &tokens)
        tokens.add(contentEnd, closeEnd, .escape)
    }

    /// Continues a template tag that started on a previous line.
    private func lexTemplateBody(_ line: LineBuffer, from i: Int, st: inout LexState, tokens: inout TokenBuffer) -> Int {
        let kind = st.sub
        guard kind > 0, Int(kind) < Self.closers.count else {
            st = .initial
            return i
        }
        let closer = Self.closers[Int(kind)]
        guard let close = line.find(closer, from: i) else {
            if isCommentTemplate(kind) {
                tokens.add(i, line.end, .comment)
            } else {
                lexTemplateContent(line, from: i, to: line.end, kind: kind, tokens: &tokens)
            }
            return line.end
        }
        let closeEnd = close + closer.count
        if isCommentTemplate(kind) {
            tokens.add(i, closeEnd, .comment)
        } else {
            lexTemplateContent(line, from: i, to: close, kind: kind, tokens: &tokens)
            tokens.add(close, closeEnd, .escape)
        }
        st = .initial
        return closeEnd
    }

    /// Template expressions: identifiers are variables, the first word of `{% … %}` (and Ruby
    /// control words in `<% … %>`, block helpers such as `{{#each}}`) are keywords.
    private func lexTemplateContent(_ line: LineBuffer, from s: Int, to e: Int, kind: UInt8, tokens: inout TokenBuffer) {
        var k = s
        var first = true
        while k < e {
            let c = line[k]
            if Ch.isSpace(c) {
                k += 1
                continue
            }
            if c == Ch.quote || c == Ch.apostrophe {
                let close = ConfigLexKit.closingQuote(line, from: k, limit: e) ?? e
                tokens.add(k, close, .string)
                k = close
                first = false
                continue
            }
            if Ch.isDigit(c) {
                let n = min(line.scanNumber(k), e)
                tokens.add(k, n, .number)
                k = max(n, k + 1)
                first = false
                continue
            }
            let helper = (c == Ch.hash || c == Ch.slash || c == Ch.caret) && Ch.isIdentStart(line[k + 1]) && k + 1 < e
            if Ch.isIdentStart(c) || c == Ch.at || helper {
                var w = k + 1
                while w < e {
                    let d = line[w]
                    guard Ch.isIdentChar(d) || d == Ch.dot || d == Ch.minus || d == Ch.question || d == Ch.bang else { break }
                    w += 1
                }
                let keyword: Bool
                if helper || (first && kind == Template.block) {
                    keyword = true
                } else if kind == Template.erb {
                    keyword = ConfigLexKit.word(line, k, w, in: Self.rubyKeywords)
                } else {
                    keyword = ConfigLexKit.word(line, k, w, in: Self.templateKeywords)
                }
                tokens.add(k, w, keyword ? .keyword : .variable)
                k = w
                first = false
                continue
            }
            if c == Ch.lparen || c == Ch.rparen || c == Ch.lbracket || c == Ch.rbracket || c == Ch.comma || c == Ch.colon {
                tokens.add(k, k + 1, .punctuation)
            } else if Ch.isOperator(c) {
                tokens.add(k, k + 1, .operator)
            } else {
                tokens.add(k, k + 1, .variable)
            }
            k += 1
        }
    }
}
