#!/bin/sh
# Builds Vibe Notepad (Release), installs it into /Applications (or ~/Applications),
# registers it with Launch Services (Finder "Open With") and installs the vibeNotePad command.
set -e
cd "$(dirname "$0")/.."

APP_NAME="Vibe Notepad"
DERIVED="build/DerivedData"
SOURCE="$DERIVED/Build/Products/Release/$APP_NAME.app"

if [ "$1" != "--skip-build" ]; then
  command -v xcodegen >/dev/null 2>&1 && xcodegen generate >/dev/null
  xcodebuild -project VibeNotepad.xcodeproj -scheme VibeNotepad -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS' build | tail -1
fi

DEST_DIR="/Applications"
[ -w "$DEST_DIR" ] || { DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; }
DEST="$DEST_DIR/$APP_NAME.app"

osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
sleep 1
rm -rf "$DEST"
ditto "$SOURCE" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
echo "✓ Installed $DEST"

scripts/install-cli.sh "$DEST"
