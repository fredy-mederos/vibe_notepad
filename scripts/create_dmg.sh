#!/bin/bash
# Builds Vibe Notepad (Release, for Apple silicon and Intel), signs it with a Developer ID and packs it into
# build/VibeNotepad.dmg, signed too. scripts/release.sh runs this, then scripts/notarize_dmg.sh.
#
# Usage: APP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/create_dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${APP_SIGN_IDENTITY:?Set APP_SIGN_IDENTITY, e.g. \"Developer ID Application: Your Name (TEAMID)\"}"

name="Vibe Notepad"
derived="build/release/DerivedData"
app="$derived/Build/Products/Release/$name.app"
staging="build/release/dmg"
dmg="build/VibeNotepad.dmg"

# A release is built from a commit: the "Stamp build info" build phase records its hash (shown in Settings →
# General → About), with "+" for uncommitted changes.
if [ -n "$(git status --porcelain)" ] && [ -z "${ALLOW_DIRTY:-}" ]; then
    echo "There are uncommitted changes. Commit them first, or set ALLOW_DIRTY=1 for a test build." >&2
    exit 1
fi

command -v xcodegen >/dev/null 2>&1 && xcodegen generate --quiet
rm -rf "$derived"
xcodebuild -project VibeNotepad.xcodeproj -scheme VibeNotepad -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" build -quiet

# The Developer ID signature, with the hardened runtime and a secure timestamp: notarization requires both.
codesign --force --options runtime --timestamp --sign "$APP_SIGN_IDENTITY" "$app"
codesign --verify --deep --strict "$app"

rm -rf "$staging" "$dmg"
mkdir -p "$staging"
ditto "$app" "$staging/$name.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "$name" -srcfolder "$staging" -format UDZO -imagekey zlib-level=9 -quiet "$dmg"
codesign --force --timestamp --sign "$APP_SIGN_IDENTITY" "$dmg"
rm -rf "$staging"

plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
commit=$(/usr/libexec/PlistBuddy -c "Print :VibeGitCommit" "$plist" 2>/dev/null || echo "no commit")
echo "Created $dmg: $name $version (build $build, $commit)"
