# Vibe Notepad — To-do & ideas

Ideas to revisit later. Nothing here is implemented yet unless it's checked.

## Next up

- [ ] **Minimap** (Sublime-style): a zoomed-out view of the file along the right edge with the visible region
  highlighted; click or drag it to scroll. Can be turned off, and stays cheap on large files.

## Done

- [x] **Git gutter**: green bars for added lines, blue for modified ones and a red wedge where lines were deleted,
  next to the line numbers. The buffer is compared with the version staged in git (`git show :path`) in the
  background as you type; the line diff (Myers) lives in VibeCore with unit tests. Refreshed on save, reload,
  coming back to the app and (for the open project) changes inside `.git`. Settings → Editor can turn it off.

- [x] **Open a folder as a project**: File → Open Folder… (⇧⌘O), `vibeNotePad .`, Finder's Open With, or dropping
  a folder on the window or Dock icon. The sidebar shows the folder as a file tree (folders load as you expand them
  and follow changes on disk), and Quick Open searches the whole project (`git ls-files` in a repository, otherwise
  a folder scan). One project at a time; it comes back on the next launch, recent folders are in Open Recent.

- [x] **Just the text** (Fredy's idea): collapsing the sidebar (⌘B or the sidebar button) also hides the status bar,
  leaving only the title bar, tabs and the text. One control for both, and it's remembered across launches.

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
