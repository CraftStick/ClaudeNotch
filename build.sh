#!/bin/bash
# Builds ClaudeNotch.app, installs it to /Applications and (re)starts it.
# --no-install only builds it into build/.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null; then
    echo "Swift not found. Install the Xcode Command Line Tools first: xcode-select --install" >&2
    exit 1
fi

APP=build/ClaudeNotch.app
DEST=/Applications/ClaudeNotch.app
OLD="$HOME/Applications/ClaudeNotch.app"  # where it went before: one copy is enough
# This Mac's kind by default; ARCHS="arm64 x86_64" makes one app for both (Tools/make-dmg.sh does).
read -r -a ARCHS <<< "${ARCHS:-$(uname -m)}"

# compile <output> <swiftc arguments…>: once per architecture, then glued into one file.
compile() {
    local out=$1 parts=()
    shift
    for arch in "${ARCHS[@]}"; do
        swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" "$@" -o "$out-$arch"
        parts+=("$out-$arch")
    done
    if (( ${#parts[@]} == 1 )); then mv "${parts[0]}" "$out"; else lipo -create "${parts[@]}" -output "$out" && rm "${parts[@]}"; fi
}

APP_SOURCES=()
while IFS= read -r -d '' file; do APP_SOURCES+=("$file"); done < <(find Sources/App -name '*.swift' -print0)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
compile "$APP/Contents/MacOS/ClaudeNotch" -parse-as-library "${APP_SOURCES[@]}"
compile "$APP/Contents/MacOS/claude-notch-hook" Sources/Hook/main.swift
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
rm -rf "$DEST" "$OLD"
cp -R "$APP" "$DEST"
rm -rf "$APP"  # a copy left in build/ would show up in Spotlight too
open "$DEST"
echo "Installed $DEST"
