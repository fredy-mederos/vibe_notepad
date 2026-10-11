# Vibe Notepad — To-do & ideas

Ideas to revisit later. Nothing here is implemented yet unless it's checked.

## Next up

Picking up on 2026-10-12, in this order.

- **Split editor, to finish and check**:
  - Drag a tab (or a pane's header) onto a pane or one of its sides: the drop zones were only tried through code
    (`debug-panes?op=drop`), not with a real drag.
  - Dragging a divider over large wrapped files: does re-wrapping on every frame stutter? (The sidebar toggle had to
    freeze the wrap width while it moves.)
  - The collapsed-sidebar look: no pane headers, unfocused panes dimmed; check it reads well.
  - Maybe: Quick Open ⌥↩ opens the file beside the current one; the same file in two panes (not possible yet: a
    document has one editor view).
  - README: the split editor and the sidebar's folders (highlights, shortcuts ⌘\\, ⇧⌘\\, ⌃⌘W, ⌥⌘ arrows, ⌥⌘`),
    then a Done entry here.

## In progress

- **Split editor** (Fredy's idea), on `main`: up to four panes. View →
  Split Right (⌘\\) / Split Down (⇧⌘\\), Close Pane (⌃⌘W), Editor Layout (Single, Two Columns, Two Rows, Three
  Columns, One Left Two Right, Grid 2 × 2) and Focus Pane (⌥⌘ arrows, ⌥⌘` for the next one), also in the toolbar,
  the palette, and the tab and sidebar menus (Open to the Right / Open Below). Thin dividers (drag to resize,
  double-click to even out), a slim header per pane (name, split and close buttons; drag it to move the file),
  unfocused panes dimmed a little, tabs shown in other panes outlined in the tab bar. A new pane shows the file
  last seen that isn't on screen; closing a file gives its pane the next tab that isn't on screen, or closes the
  pane. The layout (`PaneLayout`, in VibeCore with tests) comes back with the session. Keyboard focus: SwiftUI
  puts the keyboard back in the first view it knows of that accepts it, so with the editor split only the
  focused pane's editor and preview accept it, and their hosts are updated when the focus moves so SwiftUI asks
  again (checked with real clicks and keys, 2026-10-12). Debug builds:
  `vibenotepad-dev://debug-panes?op=split|layout|focus|close|click|drop|report&value=…&pane=…&path=…`.

## Done

- [x] **Several folders at once** (Fredy's idea): opening a folder adds it to the sidebar instead of replacing the
  open one. Each folder has a row of its own (a folder in a color of its own, its name, where it is and its git
  branch) that folds its tree; click it or its chevron, or hover and click × to close it. Right-click: reveal,
  copy the path, Open Enclosing Folder… (goes up a level, keeping what's expanded), collapse what's inside,
  collapse or close the other folders. The Folders header opens another folder, collapses them all or closes them
  all. Quick Open and the sidebar filter search every folder, File → Close Folder lists them, and the session
  remembers them (sessions with a single project still load).

- [x] **Open Enclosing Folder…** (Fredy's idea): right-click a file in the sidebar (pinned, recent or in the tree),
  a tab, or use File → Open Enclosing Folder…: the Open Folder panel starts in the file's folder, so Open Folder
  opens that folder and the "Where" menu goes up to its parents. The folder becomes the project, its tree expanded
  down to the file and scrolled to it. The project's own ⋯ menu has it too, to go up a level (folders expanded so
  far stay expanded), and a folder in the tree can be opened as the project on its own.

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

- [x] **Just the text** (Fredy's idea): collapsing the sidebar (⌘B or the sidebar button) also hides the tabs, the
  toolbar buttons (New File, Markdown view switcher, Find, Quick Open, More), the status bar and the minimap, leaving
  only the title, the path and the sidebar button above the text. Shortcuts keep working (⌃Tab or ⌘1…9 to switch
  tabs, ⌘P, ⌘F, ⌘N…). One control for all of it, remembered across launches.

- [x] **Open from anywhere** (Fredy's idea) — shipped in v1:
  - Finder right-click → Open With → Vibe Notepad for every supported document (declared document types:
    text, Markdown, code, config, any file as "Alternate" so it never steals default apps).
  - `vibeNotePad` command-line tool: `vibeNotePad file.md`, `vibeNotePad src/app.swift:42:7` (line/column),
    `vibeNotePad a b c`, `cat x | vibeNotePad -`.
  - Deep link for agents/scripts: `open "vibeNotePad://open?path=/abs/path/file.md&line=42&column=7"`, `vibeNotePad://new`.
  - Launch arguments: `Vibe Notepad.app/Contents/MacOS/Vibe Notepad /path/to/file`.

- [x] Code folding (JSON and brace languages, YAML/Python indentation, Markdown headings).

## Not now

- Pinned groups: pin a set of files laid out in panes and reopen them in the same arrangement (Fredy's idea, too
  much for now).
- iPadOS / iOS app sharing `VibeCore` (syntax engine, Markdown renderer, themes are already platform-neutral).
- Multiple cursors / "select next occurrence" (⌘D) like Sublime.
