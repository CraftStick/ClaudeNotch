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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${FLAGS[@]}" -parse-as-library Sources/App/*.swift -o "$APP/Contents/MacOS/ClaudeNotch"
swiftc "${FLAGS[@]}" Sources/Hook/main.swift -o "$APP/Contents/MacOS/claude-notch-hook"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/ClaudeNotch.icns "$APP/Contents/Resources/"
# Folders like ~/Desktop (iCloud) give files extended attributes that codesign rejects.
xattr -cr "$APP"
# Quiet unless it fails: it always says "replacing existing signature" (the linker already signed ad hoc).
if ! out=$(codesign --force --deep --sign - "$APP" 2>&1); then
    echo "$out" >&2
    exit 1
fi

if [[ "${1:-}" == "--no-install" ]]; then exit 0; fi

pkill -x ClaudeNotch 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
rm -rf "$APP"  # a copy left in build/ would show up in Spotlight too
open "$DEST"
echo "Installed $DEST"
