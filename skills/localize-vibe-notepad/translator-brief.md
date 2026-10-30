# Translating Vibe Notepad's strings

You translate the interface of Vibe Notepad, a native macOS text editor for the files people open
every day: Markdown (with a live preview), `.env` files, YAML and JSON configs, shell scripts and
code. It has tabs, a split editor (up to four panes), a sidebar with recent and pinned files and
folders, Quick Open and a Command Palette, Find & Replace with regular expressions, Go to Line and
Go to Symbol, code folding, a minimap, syntax highlighting with themes, git changes next to the line
numbers, previews for Markdown, SVG and CSV (a table), an image viewer, and tools that format JSON
and XML. Its users are developers and anyone who edits configuration files. The English is plain,
short and precise; keep that tone.

## What you get and what you write

Your input is one JSON file (the path is in your task) for one language, from
`scripts/localization.py export`. It has:

- `language`, `languageName`: the language to write.
- `pluralCategories`, `optionalPluralCategories`, `numberMayBeLeftOutIn`: see Plurals below.
- `glossary`, `glossaryNotes`: terms already chosen for this language. Use them.
- `strings`: each with `key` (an id: copy it exactly, never translate it), `english` (the text
  to translate; an object of `one`/`other` forms when English varies by number), `comment` (what
  it is, when the code says), `canVaryByPlural`, `usedAt` (file, line and the line of Swift code
  that shows it, which tells you whether it's a button, a menu item, a tooltip (`.help`), a
  section title, a status bar item, a toast…) and, when there's one already, `current` (an earlier
  translation: keep it unless it's wrong). With `currentState: needs_review`, someone found it
  wrong, or the English changed: translate it again, with the comment in mind.

Write your translations as JSON with the Write tool, to the output path in your task:

```json
{"language": "de", "translations": {
  "Find Next": "Weitersuchen",
  "%lld lines": {"one": "%lld Zeile", "other": "%lld Zeilen"},
  "Preview.mode": "Vorschau"
}}
```

Every key of the input must be there, exactly as given. Long lists can go in several files
(`<path>.part1.json`, `<path>.part2.json`…), each a complete object like the one above. Then check
them with

```bash
python3 scripts/localization.py import --dry-run <your files>
```

which reads the catalog but changes nothing, and lists placeholder mistakes, plural problems and
the keys you haven't translated yet. Fix everything it reports and run it again until it reports
no problems and nothing missing. Don't run `import` without `--dry-run`, and don't edit any other
file: other translators work at the same time.

## Placeholders

`%@` (text), `%lld` (a number) and their numbered forms (`%1$@`, `%2$lld`) are filled in by the
app. Keep every one of them, as many times as the English has it. To change their order, number
them (`%2$@ … %1$@`). The comment and the code in `usedAt` show what fills them: a file name, a
folder, a format (`JSON`), a count, a line number. Don't add or remove spaces the language doesn't
need around them.

Keep as they are: `Vibe Notepad`, `Vibe Notepad Dev`, `GitHub`, `git`, `macOS`, `Xcode`, `Sublime
Text`, `Finder` (macOS's own name for it in your language), `Markdown`, `JSON`, `XML`, `XPath`,
`YAML`, `SVG`, `CSV`, `TSV`, `HTML`, `UTF-8` and other encoding names, `BOM`, `LF`, `CRLF`, `CR`,
`Base64`, `URL`, `UUID`, `camelCase`, `snake_case`, `kebab-case`, theme and font names (Vibe Night,
Monokai, SF Mono…), file names and extensions (`.env`, `README.md`, `~/.zshrc`), the `vibeNotePad`
command and `vibeNotePad://…` links, commands and code inside backticks (the backticks stay too),
regular expression syntax (`$1`, `\n`), keyboard shortcuts (⌘P, ⇧⌘P, ⌥⌘1, ⌃G) and the `›` or `→`
between menu or settings names.

## Plurals

A string with `canVaryByPlural: true` has exactly one number. When the words around the number
change with it in your language, give an object with your language's `pluralCategories` (all of
them, except that `optionalPluralCategories` may be left out). When nothing changes, a plain
string is fine. Each form keeps all the placeholders, the number too, except in the categories
listed in `numberMayBeLeftOutIn` (only those stand for a single number; in Russian "one" also
means 21, in French 0). `other` is also what fractions use. Strings without `canVaryByPlural`
must be plain strings.

## Style

- Write what macOS itself and Apple's apps (TextEdit, Xcode, Finder) say in your language for the
  usual things: Cancel, OK, Done, Save, Save As…, Revert to Saved, Settings, Show in Finder, Copy,
  Paste, Find, Find Next, Use Selection for Find, Replace All, Close Tab, New Tab, Zoom In, Actual
  Size, Show Sidebar, Window. Use the names macOS gives Finder, Terminal, System Settings and the
  Applications folder in your language.
- Editor terms: the words developers in your language actually use, as in Xcode's and VS Code's
  translations where they have one. One word per concept, everywhere: tab, pane, split (the
  editor), editor, preview, sidebar, recent files, pinned, folder, project, Quick Open, Command
  Palette, find, replace, match case, whole word, regular expression, go to line, symbol, fold,
  unfold, minimap, word wrap, invisible characters, line numbers, indentation, spaces, tabs (the
  character), line endings, encoding, syntax highlighting, theme, appearance, zoom, format,
  minify, selection, caret, cell, row, column, header row, delimiter, sort.
- A string that names another part of the app ("Settings › General", "File → Open Recent",
  "View → Minimap", "Editor Layout") uses exactly your translation of that part: find its own
  string in the list.
- "Tab" has two senses: a tab in the tab bar (a document) and the tab character in indentation
  (`Indent Using Tabs`, `Tabs: 4`). The comment and the code tell them apart.
- Capitalization: English uses Title Case for buttons, menus and titles. Use your language's own
  rule (most capitalize only the first word).
- `…` (one character) stays where English has it: a menu item or button that opens a dialog, or
  something under way ("Sorting…").
- Quotation marks around names (“README.md”): your language's own (« » French, „ “ German, 「」 Japanese).
- Short labels stay short: toolbar buttons, the status bar (`Ln %lld, Col %lld`), segmented
  controls, badges, palette categories and the CSV bar have little room. Tooltips and explanations
  can be full sentences.
- Keys like `Preview.mode` are ids for a word used in one particular sense: translate their
  `english` text with the comment in mind.
- Address the user the way Apple's software does in your language (formal or informal), the same
  way everywhere, and the way the glossary's notes say.

## Your glossary

The glossary keeps the app's words the same from one feature to the next, and the same as Vibe
GitTree's for what both apps say (Settings, sidebar, Show in Finder…). It only grows: what it has
stays, with details a copy would lose (which word on a button, which in a menu). So also write,
next to your translations, `<language>.glossary.json` with only what's new:

```json
{"language": "it", "terms": {"minimap": "minimappa"}}
```

- `terms`: the words you chose for concepts these strings name that `glossary` doesn't have yet
  (an editor term, a part of the app), so the next translator says them the same way. The key is
  the English term, with its sense in parentheses when it has two (`tab (document)`,
  `tab (character)`); the value is your word, with where it's used when that varies.
- A `glossary` term you found wrong: its key exactly as given, with your word, and why in your
  reply. Leave out every term you used as it is.
- `notes`: only a convention you settled that `glossaryNotes` doesn't cover, in a sentence. Don't
  repeat or reword the notes.

With nothing new, write `{"language": "<code>", "terms": {}}`.

When `glossary` doesn't have the editor's terms yet (no `tab (document)`: the first translation of
Vibe Notepad into your language), write the words you chose for: tab (document), tab (character),
pane, split (editor), editor, preview, sidebar, recent files, pinned, folder, project, Quick Open,
Command Palette, find, replace, match case, whole word, go to line, symbol, fold, unfold, minimap,
word wrap, invisible characters, line numbers, indentation, spaces, line endings, encoding, syntax
highlighting, theme, zoom, format, minify, selection, caret, cell, row, column, header row,
delimiter, hot exit, toast; and `notes` on what's particular to this app that the notes don't
cover yet.
