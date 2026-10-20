#!/bin/bash
# Adds (or with --uninstall removes) the Claude Notch hooks in ~/.claude/settings.json.
# Other settings and hooks are kept. The first run saves the original file next to it.
set -euo pipefail

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
HOOK="$HOME/Applications/ClaudeNotch.app/Contents/MacOS/claude-notch-hook"
MODE="${1:-install}"

if [[ "$MODE" != "install" && "$MODE" != "--uninstall" ]]; then
    echo "usage: $0 [--uninstall]" >&2
    exit 2
fi
if [[ "$MODE" == "install" && ! -x "$HOOK" ]]; then
    echo "Hook binary not found at $HOOK — run ./build.sh first." >&2
    exit 1
fi

BACKUP="$SETTINGS.bak-claudenotch"
mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
# Only once: later runs (updates, uninstall) must not overwrite the original with modified settings.
[[ -e "$BACKUP" ]] || cp "$SETTINGS" "$BACKUP"

python3 -I - "$SETTINGS" "$HOOK" "$MODE" <<'EOF'
import json, sys

path, hook, mode = sys.argv[1:4]

# event -> (matcher or None, timeout in seconds). The app adds the same ones itself when it's
# installed from the disk image (Sources/App/ClaudeHooks.swift): keep the two lists alike.
EVENTS = {
    "SessionStart": (None, 3),  # also starts the app if it isn't running
    "UserPromptSubmit": (None, 3),
    "PreToolUse": ("*", 3),
    "PostToolUse": ("*", 3),
    "PostToolUseFailure": ("*", 3),
    "PermissionRequest": ("*", 600),  # waits for a click in the notch
    "PermissionDenied": ("*", 3),  # auto mode turned a tool down
    "Notification": (None, 3),
    "Elicitation": (None, 3),  # an MCP server asks for input; the hook never answers it
    "ElicitationResult": (None, 3),
    "PreCompact": (None, 3),
    "PostCompact": (None, 3),
    "Stop": (None, 3),
    "StopFailure": (None, 3),
    "SessionEnd": (None, 3),
    "SubagentStart": (None, 3),
    "SubagentStop": (None, 3),
}

def is_ours(group):
    # Also a quoted path, as the app writes one with spaces in it.
    return any("claude-notch-hook" in h.get("command", "") for h in group.get("hooks", []))

with open(path, encoding="utf-8") as f:
    settings = json.load(f)
hooks = settings.setdefault("hooks", {})

for event in set(hooks) | set(EVENTS):
    groups = [g for g in hooks.get(event, []) if not is_ours(g)]
    if mode == "install" and event in EVENTS:
        matcher, timeout = EVENTS[event]
        group = {"hooks": [{"type": "command", "command": hook, "timeout": timeout}]}
        if matcher:
            group = {"matcher": matcher, **group}
        groups.append(group)
    if groups:
        hooks[event] = groups
    else:
        hooks.pop(event, None)

if not hooks:
    settings.pop("hooks")

with open(path, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
EOF

if [[ "$MODE" == "install" ]]; then
    echo "Hooks installed in $SETTINGS (original settings: $BACKUP)"
else
    echo "Hooks removed from $SETTINGS (original settings: $BACKUP)"
fi
