#!/bin/bash
# Removes Claude Notch: its hooks in ~/.claude/settings.json, the login item, the app and its data.
set -euo pipefail
cd "$(dirname "$0")"

APP=/Applications/ClaudeNotch.app
OLD="$HOME/Applications/ClaudeNotch.app"  # where it went before

./install-hooks.sh --uninstall
if [[ -x "$APP/Contents/MacOS/ClaudeNotch" ]]; then
    "$APP/Contents/MacOS/ClaudeNotch" --unregister-login-item || true
fi
pkill -x ClaudeNotch 2>/dev/null || true
rm -rf "$APP" "$OLD" "$HOME/Library/Application Support/ClaudeNotch" \
    "$HOME/Library/Caches/local.claudenotch" "$HOME/Library/HTTPStorages/local.claudenotch"
defaults delete local.claudenotch >/dev/null 2>&1 || true
echo "Claude Notch removed."
