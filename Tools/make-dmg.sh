#!/bin/bash
# Builds the disk image for a release, build/ClaudeNotch-<version>.dmg: Claude Notch for Apple Silicon
# and Intel next to a link to Applications, on a background with an arrow from one to the other.
# Finder lays the window out, so the first run asks whether this terminal may control Finder.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
VOLUME="Claude Notch"
WORK=build/dmg
OUT="build/ClaudeNotch-$VERSION.dmg"
MOUNT="/Volumes/$VOLUME"

if [[ -d "$MOUNT" ]]; then
    echo "$MOUNT is mounted already: eject it first." >&2
    exit 1
fi

ARCHS="arm64 x86_64" ./build.sh --no-install
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/stage/.background"
mv build/ClaudeNotch.app "$WORK/stage/"
ln -s /Applications "$WORK/stage/Applications"

# The background, sharp on Retina screens too: both sizes in one TIFF.
swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" Tools/DmgBackground.swift -o "$WORK/make-background"
"$WORK/make-background" "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/stage/.background/background.tiff" >/dev/null 2>&1

# A writable image to lay out, then the compressed one from it.
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -ov "$WORK/layout.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$WORK/layout.dmg"
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true' EXIT

# Positions match Tools/DmgBackground.swift (left, right, size).
osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 528}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 128
        set text size of options to 13
        set background picture of options to file ".background:background.tiff"
        set position of item "ClaudeNotch.app" of container window to {160, 175}
        set position of item "Applications" of container window to {440, 175}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

# Finder writes the layout into .DS_Store a moment after the window closes.
for _ in {1..20}; do [[ -f "$MOUNT/.DS_Store" ]] && break; sleep 0.5; done
[[ -f "$MOUNT/.DS_Store" ]] || { echo "Finder saved no layout." >&2; exit 1; }
# The disk shows the app's icon. Only now: laying the window out, Finder deletes the icon file.
cp Resources/ClaudeNotch.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"
rm -rf "$MOUNT/.fseventsd"
chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach -quiet "$MOUNT"
trap - EXIT

hdiutil convert -quiet "$WORK/layout.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -rf "$WORK"
echo "Wrote $OUT"
