#!/bin/bash
# Renders the app icon (Tools/AppIcon.swift) into Resources/ClaudeNotch.icns.
# Only needed after changing the icon; build.sh uses the committed file.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=build/icon
rm -rf "$WORK"
mkdir -p "$WORK" Resources
# The app's sources minus its entry point, for ClawdSprite.
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find Sources/App -name '*.swift' ! -path Sources/App/App.swift -print0)
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" -parse-as-library \
    "${SOURCES[@]}" Tools/AppIcon.swift -o "$WORK/make-app-icon"
"$WORK/make-app-icon" "$WORK/ClaudeNotch.iconset"
iconutil -c icns "$WORK/ClaudeNotch.iconset" -o Resources/ClaudeNotch.icns
rm -rf "$WORK"
echo "Wrote Resources/ClaudeNotch.icns"
