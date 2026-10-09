#!/bin/sh
# Installs the `vibeNotePad` command (opens files in Vibe Notepad from the terminal).
set -e
cd "$(dirname "$0")/.."
SCRIPT="VibeNotepad/Resources/vibeNotePad.sh"
NAME="vibeNotePad"

for dir in /usr/local/bin /opt/homebrew/bin "$HOME/.local/bin"; do
  if [ "$dir" = "$HOME/.local/bin" ]; then mkdir -p "$dir"; fi
  if [ -d "$dir" ] && [ -w "$dir" ]; then
    install -m 755 "$SCRIPT" "$dir/$NAME"
    echo "✓ Installed $dir/$NAME"
    case ":$PATH:" in
      *":$dir:"*) ;;
      *) echo "  Note: add $dir to your PATH to use it." ;;
    esac
    exit 0
  fi
done
echo "No writable bin directory found; copy $SCRIPT somewhere on your PATH as $NAME." >&2
exit 1
