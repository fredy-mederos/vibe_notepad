#!/bin/bash
# Prints Vibe Notepad's version (MARKETING_VERSION in project.yml), or sets it and regenerates the Xcode project:
# scripts/version.sh 1.1.0
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -gt 0 ]; then
    if ! [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Use a version like 1.2.0" >&2
        exit 1
    fi
    sed -i '' -E "s/^( *MARKETING_VERSION: ).*/\1\"$1\"/" project.yml
    xcodegen generate --quiet
fi

version=$(sed -n -E 's/^ *MARKETING_VERSION: "?([^"]+)"?$/\1/p' project.yml)
if [ "$(sed -n -E 's/.*MARKETING_VERSION = ([^;]+);/\1/p' VibeNotepad.xcodeproj/project.pbxproj | sort -u)" != "$version" ]; then
    echo "project.yml says $version, but VibeNotepad.xcodeproj differs: run xcodegen generate." >&2
    exit 1
fi
echo "$version"
