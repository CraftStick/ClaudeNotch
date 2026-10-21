#!/bin/bash
# Plays Clawd's reactions in the notch one after another, from made-up Claude Code events sent the way
# the hooks send them, for a session called "clawd-demo" that ends at the end. Claude Notch must be
# running. ./tools/demo.sh, or ./tools/demo.sh rocket to play just one (see the names below).
set -euo pipefail

HOOK=/Applications/ClaudeNotch.app/Contents/MacOS/claude-notch-hook
[[ -x "$HOOK" ]] || { echo "Claude Notch isn't in /Applications" >&2; exit 1; }
ONLY=${1:-}

# send <event> [more JSON fields, without the braces]
send() {
    printf '{"hook_event_name":"%s","session_id":"clawd-demo","cwd":"%s/clawd-demo"%s}' \
        "$1" "$HOME" "${2:+,$2}" | "$HOOK" >/dev/null
}
bash_tool() { echo "\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"}"; }
step() {  # step <name> <what you'll see>: false when it's not the one asked for
    [[ -z "$ONLY" || "$ONLY" == "$1" ]] || return 1
    echo "▸ $2"
}
turn() { send UserPromptSubmit '"prompt":"Clawd demo"'; sleep "${1:-2}"; }

if step idea "A light bulb for a new task, then the laptop"; then turn 6; fi

if step searching "Detective: a search"; then
    turn; send PreToolUse '"tool_name":"Grep","tool_input":{"pattern":"TODO"}'; sleep 6
    send PostToolUse '"tool_name":"Grep","tool_input":{"pattern":"TODO"}'; sleep 1
fi

if step desktop "The desktop computer: a command that runs long"; then
    turn; send PreToolUse "$(bash_tool 'make build')"; sleep 12
    send PostToolUse "$(bash_tool 'make build')"; sleep 1
fi

if step running "Running: lots of tools at once"; then
    turn 1
    for i in 1 2 3 4 5 6 7; do
        send PreToolUse '"tool_name":"Read","tool_input":{"file_path":"/tmp/a.swift"}'
        send PostToolUse '"tool_name":"Read","tool_input":{"file_path":"/tmp/a.swift"}'; sleep 0.4
    done
    sleep 4
fi

if step sparkler "A sparkler: tests passed"; then
    turn; send PreToolUse "$(bash_tool 'swift test')"; send PostToolUse "$(bash_tool 'swift test')"; sleep 8
fi

if step rocket "A rocket: git push"; then
    turn; send PreToolUse "$(bash_tool 'git push')"; send PostToolUse "$(bash_tool 'git push')"; sleep 6
fi

if step facepalm "A facepalm, then head in his hands: three failures in a row"; then
    turn
    for i in 1 2 3; do
        send PreToolUse "$(bash_tool 'false')"; send PostToolUseFailure "$(bash_tool 'false'),\"error\":\"exit 1\""; sleep 3.5
    done
    sleep 2
fi

if step shrug "A shrug: auto mode said no"; then
    turn; send PreToolUse "$(bash_tool 'rm -rf build')"
    send PermissionDenied "$(bash_tool 'rm -rf build'),\"reason\":\"[Irreversible Local Destruction]\""; sleep 4
fi

if step compacting "Papers into a box: compacting"; then
    turn; send PreCompact '"trigger":"auto"'; sleep 7; send PostCompact '"trigger":"auto"'; sleep 1
fi

if step done "A happy hop: done"; then
    turn; send Stop '"last_assistant_message":"All done."'; sleep 5
fi

if step celebrate "Confetti and a breakdance: a big task done"; then
    turn 1
    lines=$(printf 'line\\n%.0s' $(seq 160))
    send PreToolUse "\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/a.swift\",\"old_string\":\"\",\"new_string\":\"$lines\"}"
    send PostToolUse "\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/a.swift\",\"old_string\":\"\",\"new_string\":\"$lines\"}"
    send Stop '"last_assistant_message":"All done."'; sleep 7
fi

if step waiting "Waving: Claude waits for you"; then
    turn; send Stop '"last_assistant_message":"Shall I go on?"'; sleep 5
fi

if step error "Dizzy: an error"; then
    turn; send StopFailure '"error":"server_error","error_details":"API Error"'; sleep 5
fi

if step limit "An hourglass: the rate limit"; then
    turn; send StopFailure '"error":"rate_limit","error_details":"Rate limit reached"'; sleep 10
fi

send SessionEnd '"reason":"other"'
