---
name: localize-vibe-notepad
description: "Translate Vibe Notepad's interface into its 20 languages: write the code so its text is localizable, sync the String Catalog (VibeNotepad/Localizable.xcstrings) with it, export what each language misses, have lighter-model subagents translate it, validate and import their work, check, build. Use whenever a change adds or changes text the app shows (a feature isn't done until every language has it), and when asked to add translations or a language, or to review or fix one."
---

# Localize Vibe Notepad

## Overview

Every string the app shows is in `VibeNotepad/Localizable.xcstrings`, with English as the source and
20 translations: the most spoken languages macOS runs in, the same as Vibe GitTree's (`LANGUAGES` in
`scripts/localization.py`: zh-Hans, hi, es, ar, fr, pt-BR, ru, id, de, ja, vi, tr, ko, zh-Hant, it, th,
pl, uk, ms, nl). The build compiles the catalog into the app; macOS picks the language (System
Settings › General › Language & Region, also per app). XcodeGen reads the catalog's languages into
the project's `knownRegions`. `scripts/localization.py` does the bookkeeping; subagents on a lighter
model do the translating, with `translator-brief.md` (next to this file) as their brief and
`scripts/localization-glossary.json` keeping their words consistent from one feature to the next. The
glossary started from Vibe GitTree's: the words both apps share (Settings, sidebar, Show in Finder…)
and each language's conventions stay the same across the apps.

A change that adds or changes text the app shows ships with its translations, in the same commit:
`scripts/localization.py check` passes.

## Writing localizable code

- SwiftUI literals are localized as they are: `Text("…")`, `Button("…")`, `Label("…", systemImage:)`,
  `Toggle`, `Picker`, `Section`, `Menu`, `TextField` and its prompt, `.help("…")`,
  `.accessibilityLabel("…")`, `ContentUnavailableView`, `LabeledContent`, `Tab("…", …)`, menu commands,
  including a literal ternary (`Button(pinned ? "Unpin" : "Pin to Top")`). So is a literal passed to
  your own view's `LocalizedStringKey` parameter.
- Text that becomes a `String` first goes through `String(localized: "…")`: a toast, an enum's
  `title`, an error's message, a custom view's `title: String` given a literal, a tooltip or `help`
  built in code, `NSMenuItem`, `NSAlert`, `NSSavePanel`/`NSOpenPanel` messages and prompts, a
  `presentError` title. Helpers can take a `String.LocalizationValue` parameter (literals passed to it
  are extracted) and call `String(localized:)` inside, as the command palette's `add(…)` does; its
  categories are `PaletteCategory`'s, or a name that stays the same (`JSON`, a language's name).
- Data stays as it is: file names and paths, the document's text, language names (but "Plain Text"),
  theme names, encoding names (UTF-8, Windows Latin 1), keyboard shortcuts.
  `Text(verbatim:)` for literal punctuation like `"·"`, and for strings made only of data.
- VibeCore stays in English: it's platform-neutral, and its tests read its messages. What the app
  shows from it is put into words in `VibeNotepad/Support/VibeCoreStrings.swift` (pane layouts, CSV
  delimiters, indentation and line endings, the JSON and XML formatters', Find's and the file codec's
  errors). A new message in VibeCore gets a case there.
- Whole sentences with interpolations, never English pieces glued together:
  `String(localized: "Exported \(name)")`, not `"Exported " + name`, and no `"\(a) " + verb`.
  Separators between independent phrases (`" · "`) are fine.
- Counts are `Int` interpolations, `"\(count) lines"` (not `count.formatted()`, which can't vary
  by plural); the number is grouped for the locale either way. Give the English singular with
  `scripts/localization.py plural "%lld lines" "%lld line"` when the words change with the
  number. One count per string: a sentence with two counts puts one inside the other
  (`let lines = String(localized: "\(n) lines")`, then `"\(lines), \(characters) characters"`).
- Numbers that aren't quantities (line and column numbers, years, versions, HTTP statuses) go in as
  `String(number)`; as an `Int` they'd be grouped, `Ln 12,345`.
- A word used in two senses gets a key of its own with the English as its value:
  `String(localized: "Preview.mode", defaultValue: "Preview", comment: "View mode: only the preview shows")`.
  Add a `comment:` to anything a translator could read two ways (a lone word, a placeholder whose
  content isn't obvious). Translators also see the line of code that shows each string.
- Never change an enum's `rawValue` to translate it (they're saved, and some are debug link
  arguments): add a `title`.
- `App/UpdateCheck.swift` is the same file in Vibe GitTree and Vibe Clean: its messages are put into
  words in `AppUpdater.swift` instead.
- Brand names, example paths and placeholders that stay the same in every language: `scripts/localization.py dnt "<key>"`.

## Workflow

1. `scripts/localization.py sync` builds (Debug), adds the code's new strings to the catalog, drops
   the ones no longer used, and prints what each language misses and which strings with a number
   have only one English form.
2. English singulars for those whose words change (`plural`), `dnt` for names.
3. `scripts/localization.py export <folder>` (the session's scratchpad) writes `<language>.json`
   per language: each missing string with its English, comment, the code that shows it, and the
   language's glossary and plural categories.
4. Translate with subagents (Agent tool, `subagent_type: general-purpose`), never the main model:
   - A few strings (up to about 30 per language): one agent on `model: haiku` for all 20 languages,
     one output file per language.
   - More: one agent per language on `model: sonnet`, all launched in one message so they run at
     the same time.

   The prompt, per agent (adjust for one agent doing every language):

   > Translate Vibe Notepad's interface strings (a macOS text editor) into <language name>,
   > language code <code>.
   > 1. Read the brief first and follow it exactly: <repository>/skills/localize-vibe-notepad/translator-brief.md
   > 2. Input: <folder>/<code>.json (read it in chunks if it's long).
   > 3. Write your translations to <folder>/out/<code>.json (parts `.part1.json`, `.part2.json`…
   >    of about 225 strings when there are many), and your glossary (only new or corrected terms,
   >    as the brief says) to <folder>/out/<code>.glossary.json.
   > 4. From <repository> run `python3 scripts/localization.py import --dry-run <your files>`; fix
   >    what it reports and repeat until it reports no problems and nothing missing. Never run
   >    import without --dry-run, and change no other file: other translators work at the same time.
   >
   > Reply in under 120 words: the dry run's final line, then any strings whose meaning was unclear
   > or where you made a judgment call worth a second look (key and your choice), and any glossary
   > term you corrected (term, old and new word, why).

5. When every agent is done: `scripts/localization.py import <folder>/out/*.part*.json` (or
   `<folder>/out/<code>.json`), then `scripts/localization.py glossary <folder>/out/*.glossary.json`.
   Read the judgment calls the agents reported and fix any that are wrong (edit their file, import it
   again).

   `glossary` adds new terms, and languages a term doesn't have yet. The words and notes the
   glossary has stay as they are; it lists where a file differs (`kept …`), mostly shorter copies
   that would lose details. What an agent corrected or added on purpose, and you agree with, goes in
   with `glossary --replace` on a file that has only that
   (`{"language": "it", "terms": {"tab": "…"}, "notes": "…"}`): its words replace the glossary's,
   and what its notes say that the glossary's don't is added to them. `--dry-run` first shows what
   it changes. Rewording or removing notes is done by hand, in `scripts/localization-glossary.json`.
6. `scripts/localization.py check` must pass (`import` regenerates the project, so `knownRegions`
   has every language). Build with the usual command, and look at the new UI in one or two
   languages: a Dev build started with `open -g --env VIBE_SUPPORT_DIR=<scratch folder> -a
   "<Vibe Notepad Dev.app>" --args -AppleLanguages "(de)"`, then `vibenotepad-dev://debug-snapshot`
   (German for long words). For right-to-left, Arabic needs `-AppleTextDirection YES
   -NSForceRightToLeftWritingDirection YES` too, or the layout isn't mirrored: the window mirrors,
   while the editing area (panes, code, the CSV table) stays left to right. Commit the catalog, the
   glossary and the code together.

Adding a language: add it to `LANGUAGES` and `PLURALS` in `scripts/localization.py`, then export (it
misses every string), translate and import as above; `make project` puts it in `knownRegions`.

Fixing a translation found wrong: when the English could be read two ways, add a `comment:` in the
code and sync; then `scripts/localization.py review "<key>" --lang <codes>` marks those
translations to redo, and export lists them again (with the current one and the comment) for the
usual translate, import and check.

Reviewing a language: `export --all --lang <code>` lists every string with its current translation;
a reviewer agent corrects what's wrong and writes only those to its output file, and only the
glossary terms it corrects to its glossary file, which `glossary --replace` applies once you've
read it.
