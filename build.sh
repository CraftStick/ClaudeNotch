#!/bin/bash
# Builds ClaudeNotch.app, installs it to ~/Applications and (re)starts it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ClaudeNotch.app
DEST="$HOME/Applications/ClaudeNotch.app"
FLAGS=(-O -swift-version 5 -target arm64-apple-macos14.0)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc "${FLAGS[@]}" -parse-as-library Sources/App/*.swift -o "$APP/Contents/MacOS/ClaudeNotch"
swiftc "${FLAGS[@]}" Sources/Hook/main.swift -o "$APP/Contents/MacOS/claude-notch-hook"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

if [[ "${1:-}" == "--no-install" ]]; then exit 0; fi

pkill -x ClaudeNotch 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed $DEST"
echo "Hook command: $DEST/Contents/MacOS/claude-notch-hook"
