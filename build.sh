#!/bin/bash
# Builds ClaudeNotch.app, installs it to ~/Applications and (re)starts it.
# --no-install only builds it into build/.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null; then
    echo "Swift not found. Install the Xcode Command Line Tools first: xcode-select --install" >&2
    exit 1
fi

APP=build/ClaudeNotch.app
DEST="$HOME/Applications/ClaudeNotch.app"
FLAGS=(-O -swift-version 5 -target "$(uname -m)-apple-macos14.0")

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc "${FLAGS[@]}" -parse-as-library Sources/App/*.swift -o "$APP/Contents/MacOS/ClaudeNotch"
swiftc "${FLAGS[@]}" Sources/Hook/main.swift -o "$APP/Contents/MacOS/claude-notch-hook"
cp Info.plist "$APP/Contents/Info.plist"
# Folders like ~/Desktop (iCloud) give files extended attributes that codesign rejects.
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

if [[ "${1:-}" == "--no-install" ]]; then exit 0; fi

pkill -x ClaudeNotch 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed $DEST"
