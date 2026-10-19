<div align="center">

**English** · [Русский](README.ru.md)

# Claude Notch

**[Claude Code](https://claude.com/claude-code) status in your MacBook notch — like the Dynamic Island on an iPhone.**<br>
See what the agent is doing right now, how long the task has been running, and when it's waiting for you.<br>
Answer permission requests with buttons right in the notch. And Clawd lives there too.

<img src="docs/notch.gif" width="640" alt="The notch during a task: Clawd gets out his laptop and types, a command runs, Done">

</div>

## Install

You need **macOS 14 or later** and **Claude Code** (in the terminal or in the Code tab of the Claude desktop app).

**1.** Install Apple's command line developer tools if you don't have them yet (an installer window opens; if they're already there, the command says so):

```bash
xcode-select --install
```

**2.** Download and install Claude Notch:

```bash
git clone https://github.com/CraftStick/ClaudeNotch.git
cd ClaudeNotch
./install.sh
```

That's it. Clawd shows up in the menu bar, and the notch comes alive as soon as Claude Code starts a task. To try it right away without Claude: Clawd's menu bar icon → **Show demo**.

<details>
<summary>Without git — download the ZIP</summary>

```bash
curl -L -o ClaudeNotch.zip https://github.com/CraftStick/ClaudeNotch/archive/refs/heads/main.zip
unzip -q ClaudeNotch.zip && cd ClaudeNotch-main
chmod +x *.sh && ./install.sh
```

</details>

<details>
<summary>What <code>install.sh</code> does</summary>

1. Builds the app from source (`build.sh`) into `~/Applications/ClaudeNotch.app` and starts it. It's built on your Mac, so macOS shows no Gatekeeper warnings.
2. Adds the hooks to `~/.claude/settings.json` (`install-hooks.sh`). Your other settings and hooks stay untouched, a copy is saved as `settings.json.bak-claudenotch`, and running it again adds nothing twice.
3. The app turns on Open at Login by itself (you can switch it off in the menu).

</details>

**Update:**

```bash
cd ClaudeNotch && git pull && ./install.sh
```

**Uninstall** (hooks, login item, the app and its data):

```bash
cd ClaudeNotch && ./uninstall.sh
```

## Features

### Status in the notch

Clawd on the left of the notch, the task's time on the right. On every action the notch opens for a couple of seconds: "Running a command", "Reading file", "Editing", "Searching code", "Browser"… with the details. Several sessions at once are fine: a counter next to the timer shows how many are at work.

### Details on hover

Rest the pointer on the notch and a card opens: the task, what's happening now (with the description and the full command), subagents, recent actions with the size of each edit, other sessions, and at the bottom the turn's line changes, tokens and context fill. Click the notch to bring forward the app the session runs in (Terminal, iTerm, VS Code, Cursor, the Claude app…).

<p align="center"><img src="docs/card.png" width="560" alt="The card you get on hover"></p>

### Permissions from the notch

When Claude Code asks for permission, the notch shows **Allow** (⌘Y), **Deny** (⌘N) and **Always** — add the rule Claude Code suggests so it won't ask again. The shortcuts only work while a request is showing and need no macOS permissions. In the Claude app the usual permission dialog appears too, and whichever answer comes first wins; in the terminal, **In app** hands the question back to the usual prompt.

<p align="center"><img src="docs/permission.png" width="560" alt="A permission request in the notch"></p>

### Clawd

| When | Clawd |
|---|---|
| A new task comes in | a light bulb goes on above his head, then he gets out his laptop and types |
| Thinking for a while (12+ s with no actions) | sits down with a speech bubble "…" |
| A command runs longer than 8 s | moves over to a desktop computer |
| Subagents at work or many actions in a row | runs |
| Waiting for you: a question, a permission, a plan | waves at you |
| You allowed an action | is delighted |
| A command failed or you pressed Deny | facepalms |
| Done | hops for joy; after a big task — confetti and a breakdance |
| Stopped with Esc / API error | slumps / gets dizzy |
| After the task | stays in the notch for 15 more minutes: looks around, dances, dozes off after 3 minutes, and finally walks away |

If you're in another app when Claude finishes or needs an answer, a sound plays (can be switched off in the menu).

### Language

The interface is in English or Russian, following your system language. Switch it in Clawd's menu → **Language**.

## How it works

```
Claude Code ──hook (JSON on stdin)──▶ claude-notch-hook ──Unix socket──▶ ClaudeNotch.app
                    ◀── decision (permission requests only) ──┘
```

- **`Sources/Hook/main.swift`** — a tiny binary Claude Code runs on every event. It forwards the JSON to the app and prints the answer, if there is one. It always exits 0, silently, even when the app isn't running, so it never gets in Claude Code's way.
- **`Store.swift`** — turns hook events into the notch's state and answers permission requests.
- **`NotchView.swift`**, **`DetailsCard.swift`** — the interface: the shape around the notch, the open states, the cards.
- **`ClawdAnimation.swift`**, **`Clawd.swift`** — Clawd's animations (see below).
- **`TranscriptWatcher.swift`** — watches the session file: Claude Code sends no hook on Esc, and token usage lives there too.
- **`AppFocus.swift`**, **`HotKeys.swift`**, **`SocketServer.swift`**, **`Language.swift`** — click to focus, ⌘Y/⌘N, the socket, the two languages.

**Privacy.** Everything stays on your Mac, no network. The hook sends events only to the socket `~/Library/Application Support/ClaudeNotch/notch.sock`, which only your user can open. The app reads the session files in `~/.claude/projects` only to notice Esc and to count tokens.

## Troubleshooting

- **The notch doesn't react.** Check that the app is running (`pgrep -x ClaudeNotch`) and the hooks are in place (`grep -c claude-notch-hook ~/.claude/settings.json`). Claude Code sessions that were already open sometimes pick up new hooks only after a restart.
- **What reaches the app** is in the log: `tail -f ~/Library/Application\ Support/ClaudeNotch/events.log`.
- **Context fill** is counted against 200K tokens, or 1M once a session has used more: Claude Code doesn't write the window size into the session file.
- **A display without a notch** gets a "virtual" notch in the menu bar.

## About Clawd

Clawd is Anthropic's character, and his sprites aren't in this source code. At launch the app reads them from the Claude app installed on your Mac (they live in its `app.asar`, in the Clawd Quest easter egg). If Claude.app isn't installed or the sprite format changes, a simplified Clawd drawn in code is shown instead. The images in `docs/` are screenshots of the running app.

This project is not affiliated with or endorsed by Anthropic. Claude is a trademark of Anthropic.

## License

[MIT](LICENSE)
