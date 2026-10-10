# Vibe Notepad — To-do & ideas

Ideas to revisit later. Nothing here is implemented yet unless it's checked.

## Next up

Nothing queued right now; see "Not now" for parked ideas.

## Done

- [x] **Minimap** (Sublime-style): every character drawn as a small block in its syntax color, one row per line,
  with git changes along its edge and a slider for what's on screen; click or drag to scroll. Rows are rendered
  in 64-line tiles that are reused while scrolling and redrawn only where the text changes, so large files cost
  the same as small ones. Hides itself when the editor is narrow or the sidebar is collapsed; View → Minimap or
  Settings → Editor turn it off.

- [x] **Git gutter**: green bars for added lines, blue for modified ones and a red wedge where lines were deleted,
  next to the line numbers. The buffer is compared with the version staged in git (`git show :path`) in the
  background as you type; the line diff (Myers) lives in VibeCore with unit tests. Refreshed on save, reload,
  coming back to the app and (for the open project) changes inside `.git`. Settings → Editor can turn it off.

- [x] **Open a folder as a project**: File → Open Folder… (⇧⌘O), `vibeNotePad .`, Finder's Open With, or dropping
  a folder on the window or Dock icon. The sidebar shows the folder as a file tree (folders load as you expand them
  and follow changes on disk), and Quick Open searches the whole project (`git ls-files` in a repository, otherwise
  a folder scan). One project at a time; it comes back on the next launch, recent folders are in Open Recent.

- [x] **Just the text** (Fredy's idea): collapsing the sidebar (⌘B or the sidebar button) also hides the status bar,
  the minimap and the toolbar's actions on the right (Markdown view switcher, Find, Quick Open, More), leaving only
  the title, the sidebar and New File buttons, the tabs and the text. Shortcuts keep working. One control for all of
  it, remembered across launches.

- [x] **Open from anywhere** (Fredy's idea) — shipped in v1:
  - Finder right-click → Open With → Vibe Notepad for every supported document (declared document types:
    text, Markdown, code, config, any file as "Alternate" so it never steals default apps).
  - `vibeNotePad` command-line tool: `vibeNotePad file.md`, `vibeNotePad src/app.swift:42:7` (line/column),
    `vibeNotePad a b c`, `cat x | vibeNotePad -`.
  - Deep link for agents/scripts: `open "vibeNotePad://open?path=/abs/path/file.md&line=42&column=7"`, `vibeNotePad://new`.
  - Launch arguments: `Vibe Notepad.app/Contents/MacOS/Vibe Notepad /path/to/file`.

- [x] Code folding (JSON and brace languages, YAML/Python indentation, Markdown headings).

## Not now

- iPadOS / iOS app sharing `VibeCore` (syntax engine, Markdown renderer, themes are already platform-neutral).
- Split editor (two files side by side).
- Multiple cursors / "select next occurrence" (⌘D) like Sublime.
