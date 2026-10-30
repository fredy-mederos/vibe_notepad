# Vibe Notepad

A native macOS text editor (SwiftUI and AppKit, no third-party dependencies). README.md describes the
app and its architecture; TODO.md keeps the ideas and what's done. Skills in `skills/` (linked for
Claude Code and Codex): `release-vibe-notepad` publishes a release, `localize-vibe-notepad` translates.

## Translations

- The app is in English plus 20 languages (the most spoken ones macOS runs in, the same as Vibe
  GitTree's, listed in `scripts/localization.py`), all in the String Catalog
  `VibeNotepad/Localizable.xcstrings`. Any change that adds or changes text the app shows ships with
  its translations in the same commit: follow the `localize-vibe-notepad` skill (sync, export,
  translate with subagents on a lighter model, `haiku` for a few strings or `sonnet` per language for
  many, import, then `scripts/localization.py check`, which must pass). Don't translate with the main
  model.
- SwiftUI literals (`Text("…")`, `Button("…")`, `.help("…")`, a `LocalizedStringKey` parameter) are
  localized as they are. Text that becomes a `String` first (toasts, alerts, errors, enum titles,
  palette commands, tooltips built in code, AppKit menus and panels) goes through
  `String(localized:)`. Data (file names, paths, the document's text, language and theme names)
  stays as it is.
- VibeCore stays in English; the app puts what it shows from VibeCore into words in
  `VibeNotepad/Support/VibeCoreStrings.swift`.
- Whole sentences with interpolations, never English pieces joined together. Counts are `Int`
  interpolations (`"\(count) lines"`) with the English singular added by
  `scripts/localization.py plural`; one count per string. Line and column numbers and versions go in
  as `String(number)`, or they're grouped (`Ln 12,345`). A word used in two senses gets its own key
  (`String(localized: "Preview.mode", defaultValue: "Preview", comment: …)`), and a `comment:`
  explains anything a translator could misread. The skill has the details.
- Check the UI in another language by starting the Dev build with `--args -AppleLanguages "(de)"`
  (`de` for long words); right-to-left needs `-AppleLanguages "(ar)" -AppleTextDirection YES
  -NSForceRightToLeftWritingDirection YES`. The window mirrors, but the editing area (panes, code, the
  CSV table) stays left to right, as code editors do.
