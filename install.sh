#!/bin/bash
# One-step install: builds the app into ~/Applications, starts it and adds the Claude Code hooks.
# Run it again to update after `git pull`.
set -euo pipefail
cd "$(dirname "$0")"

major=$(sw_vers -productVersion | cut -d. -f1)
if (( major < 14 )); then
    echo "Claude Notch needs macOS 14 or newer (this Mac has $(sw_vers -productVersion))." >&2
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null; then
    echo "The Xcode Command Line Tools are missing. Run:  xcode-select --install" >&2
    echo "then run ./install.sh again." >&2
    exit 1
fi

echo "==> Building and installing the app"
./build.sh
echo "==> Adding the hooks to Claude Code"
./install-hooks.sh
echo
echo "Done. Claude Notch is running (Clawd's icon is in the menu bar)."
echo "Start a task in Claude Code and watch the notch. Menu → «Показать демо» plays a fake session."
