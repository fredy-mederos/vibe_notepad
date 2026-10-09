# Vibe Notepad — To-do & ideas

Ideas to revisit later. Nothing here is implemented yet unless it's checked.

## Next up

- [ ] **Immersive "just the text" mode** (Fredy's idea)
  - When a file is open, show a clean, distraction-free view: only the text, no sidebar, tabs, toolbar or status bar.
  - The chrome reveals itself on intent: moving the mouse or scrolling brings back controls, e.g. the recent files
    appearing in a corner with a smooth animation, then fading away again after a few seconds of typing/idle.
  - Keep the UI minimal by default — no heavy writing tools; simplicity is the point.
  - Open questions: should it be the default when opening a file, or a toggle (e.g. ⌃⌘F / a toolbar button)?
    Which corner for recents? Do tabs also hide? Does the status bar come back on hover at the bottom edge?

- [ ] **Open from anywhere** (Fredy's idea) — being built in v1, verify once installed:
  - Finder right-click → Open With → Vibe Notepad for every supported document (declared document types:
    text, Markdown, code, config, any file as "Alternate" so it never steals default apps).
  - `vibeNotePad` command-line tool: `vibeNotePad file.md`, `vibeNotePad src/app.swift:42:7` (line/column),
    `vibeNotePad a b c`, `cat x | vibeNotePad -`.
  - Deep link for agents/scripts: `open "vibeNotePad://open?path=/abs/path/file.md&line=42&column=7"`, `vibeNotePad://new`.
  - Launch arguments: `Vibe Notepad.app/Contents/MacOS/Vibe Notepad /path/to/file`.

## Later

- [ ] iPadOS / iOS app sharing `VibeCore` (syntax engine, Markdown renderer, themes are already platform-neutral).
- [ ] Multiple cursors / "select next occurrence" (⌘D) like Sublime.
- [ ] Split editor (two files side by side).
- [ ] Minimap.
- [x] Code folding (JSON and brace languages, YAML/Python indentation, Markdown headings).
- [ ] Git gutter (added / modified / deleted line markers).
- [ ] Open a folder as a project (file tree + Goto Anything over the project).
