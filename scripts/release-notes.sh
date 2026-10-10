#!/bin/bash
# Prints the notes for a GitHub release: the icon, how to install, and the commits since the previous release.
# Usage: scripts/release-notes.sh v1.1.0   (before that tag exists, the commits up to HEAD)
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:?Usage: scripts/release-notes.sh vX.Y.Z}"
repo="fredy-mederos/vibe_notepad"
icon="https://raw.githubusercontent.com/$repo/main/VibeNotepad/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256@1x.png"

ref="$tag"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null || ref="HEAD"
previous=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$ref^" 2>/dev/null || true)

cat <<NOTES
<p align="center">
  <img src="$icon" width="80" alt="Vibe Notepad icon" />
</p>

Download **VibeNotepad.dmg** below, open it and drag Vibe Notepad into Applications. Settings → General installs the \`vibeNotePad\` command. Vibe Notepad tells you when a new version is out; Vibe Notepad → Check for Updates… checks any time.

NOTES

if [ -n "$previous" ]; then
    echo "## What's changed"
    echo
    git log --no-merges --format='- %s' "$previous..$ref" | grep -v -E '^- Bump version to ' || true
    echo
    echo "**Full changelog**: https://github.com/$repo/compare/$previous...$tag"
else
    echo "The first release: [the README](https://github.com/$repo#readme) describes what Vibe Notepad does."
fi
