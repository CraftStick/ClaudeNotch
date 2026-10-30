# Claude Notch

[English](README.md) · [Русский](README.ru.md)

<div align="center">

<img src="docs/icon.png" width="128" alt="Claude Notch icon: pixel Clawd behind his open laptop on a cream tile">

**[Claude Code](https://claude.com/claude-code) in your MacBook's notch, like the Dynamic Island on an iPhone.**<br>
See what Claude is doing, how long it's been at it and when it needs you, and answer it right there.<br>
And Clawd lives in the notch.

<img src="docs/notch.gif" width="640" alt="The notch during a task: Clawd gets out his laptop and types, a command runs, Done">

<table>
<tr>
<td align="center" valign="top"><img src="docs/clawd/coffee.gif" width="120" alt="Clawd sipping a mug of coffee"><br><b>Coffee</b></td>
<td align="center" valign="top"><img src="docs/clawd/music.gif" width="120" alt="Clawd nodding along in headphones"><br><b>Music</b></td>
<td align="center" valign="top"><img src="docs/clawd/wizard.gif" width="120" alt="Clawd as a wizard, sparkles flying off his wand"><br><b>Magic</b></td>
<td align="center" valign="top"><img src="docs/clawd/chef.gif" width="120" alt="Clawd in a chef's hat tossing a pancake"><br><b>Pancakes</b></td>
</tr>
</table>

</div>

## Install

You need macOS 14 or later and Claude Code, in a terminal or in the Claude app.

1. Download **ClaudeNotch-….dmg** from the [latest release](https://github.com/CraftStick/ClaudeNotch/releases/latest) and open Claude Notch right in it. Apple hasn't notarized it, so the first time macOS won't: click **Done**, then **System Settings → Privacy & Security → Open Anyway**.
2. Click **Move**: it copies itself to Applications and opens from there.
3. When it asks to connect to Claude Code, click **Connect**. It adds its hooks to `~/.claude/settings.json` and keeps the original next to it.

**Or with [Homebrew](https://brew.sh):**

```bash
brew install craftstick/tap/claude-notch
```

Then open Claude Notch from Applications (the first time: **Done**, then **System Settings → Privacy & Security → Open Anyway**) and click **Connect**. Update with `brew upgrade claude-notch`.

**Update:** open the new one from its disk image and click **Move**: it quits the old one and takes its place.<br>
**Uninstall:** move the app to the Trash and click **Remove All**: its hooks, login item, settings and data go with it.

<details>
<summary>Build from source</summary>

```bash
xcode-select --install   # Apple's command line tools, if you don't have them yet
git clone https://github.com/CraftStick/ClaudeNotch.git ~/ClaudeNotch
cd ~/ClaudeNotch && ./install.sh
```

`install.sh` builds the app into `/Applications` and adds the hooks. Update with `git pull && ./install.sh`, remove with `./uninstall.sh`, run the tests with `swift test`.

</details>

## What it does

- **Status in the notch.** Clawd on the left, the task's time on the right, a counter when several sessions are at work. The notch opens for what matters: a new task, a failure, Claude waiting for you, done.
- **Only while Claude Code runs.** When the last Claude Code session quits, in a terminal, an editor or the Claude app, the notch empties and Clawd's menu bar icon goes too; they're back with the next session. To get to the menu meanwhile, open Claude Notch again.
- **Details on hover.** The task, what Claude is doing and why, its plan, subagents, recent actions, tokens and context, other sessions. A click brings forward the terminal tab or app the session runs in.
- **Answers from the notch.** Allow or deny a permission request (⌃⌥⌘Y / ⌃⌥⌘N, or **Always**), and pick the answers to Claude's questions (⌃⌥⌘1…4).
- **Clawd.** He types while Claude works, thinks, waves when it needs you, hops when it's done and dozes while he rests; he turns detective while Claude searches, packs papers into a box while it compacts, stirs a pot while a build runs, launches a rocket after a push and puts on a mortarboard once his whole plan is done. With **Clawd stays in the notch** on, he lives there for good, with pastimes of his own. [All his animations →](docs/clawd/README.md)
- **Limits.** When your plan's session or weekly limit runs out, the notch opens on Clawd by his hourglass and tells you when it resets; when it's back, he hops.
- **Telegram.** Link your Mac to Claude Notch's bot with a code from the settings, and pick what it sends you: a limit ran out or is back, Claude is done, waiting for you, or hit an API error.
- A sound when Claude is done or waiting for you, a glowing rim, English and Russian, your own shortcuts, an update check if you want one. All of it in the settings: Clawd's menu in the menu bar → **Settings…** (⌘,).

<p align="center"><img src="docs/card.png" width="440" alt="The card you get on hover"> <img src="docs/permission.png" width="440" alt="A permission request in the notch"></p>

## Meet Clawd

He lives in the notch and reacts to everything Claude does, more than 40 animations in all.

<table>
<tr>
<td align="center" valign="top" width="25%"><img src="docs/clawd/typing.gif" width="120" alt="Types while Claude works"><br><sub><b>Types while Claude works</b></sub></td>
<td align="center" valign="top" width="25%"><img src="docs/clawd/thinking.gif" width="120" alt="Thinks"><br><sub><b>Thinks</b></sub></td>
<td align="center" valign="top" width="25%"><img src="docs/clawd/searching.gif" width="120" alt="Turns detective"><br><sub><b>Turns detective</b></sub></td>
<td align="center" valign="top" width="25%"><img src="docs/clawd/waving.gif" width="120" alt="Waves when it needs you"><br><sub><b>Waves when it needs you</b></sub></td>
</tr>
<tr>
<td align="center" valign="top" width="25%"><img src="docs/clawd/thanks.gif" width="120" alt="Goes shy at a thank-you"><br><sub><b>Goes shy at a thank-you</b></sub></td>
<td align="center" valign="top" width="25%"><img src="docs/clawd/rocket.gif" width="120" alt="Launches a rocket on a push"><br><sub><b>Launches a rocket on a push</b></sub></td>
<td align="center" valign="top" width="25%"><img src="docs/clawd/sleeping.gif" width="120" alt="Reads, then naps"><br><sub><b>Reads, then naps</b></sub></td>
<td align="center" valign="top" width="25%"><img src="docs/clawd/hula.gif" width="120" alt="Does the hula"><br><sub><b>Does the hula</b></sub></td>
</tr>
</table>

<p align="center"><a href="docs/clawd/README.md"><b>All of Clawd's animations →</b></a></p>

## How it works

Claude Code runs a tiny hook on every event, which hands it to the app over a local socket and, for a permission request or a question, hands your answer back. The app also reads the session files in `~/.claude/projects`, to notice Esc and count tokens, and watches Claude Code's list of running sessions in `~/.claude/sessions`, to know when it quits.

Everything about Claude's work stays on your Mac. The app goes online for three things only. To watch the plan's limits it asks api.anthropic.com, signed in as Claude Code (renewing its login when it has gone stale, as Claude Code itself does), every few minutes while Claude works and every 10 minutes otherwise, as chats and other devices spend the limits too (switch it off in the settings). Telegram messages, if you link the bot, go through Claude Notch's own [server](Server/), which keeps only your chat. And a check for updates on GitHub once a day, if you switch it on. While the notch can't be seen (the display asleep, the screen locked), the app wakes up only for that look at the limits; while Claude works, it takes about 1–2% of one core.

## Troubleshooting

- **The notch doesn't react:** check that **Connected to Claude Code** is on in the settings. Sessions opened before may need a restart.
- **A click opens the terminal but not the session's tab:** allow Claude Notch in System Settings → Privacy & Security → Automation.
- **What reaches the app:** `tail -f ~/Library/Application\ Support/ClaudeNotch/events.log`.

## Ideas

Have an idea for what to add, or found something that doesn't work? [Open an issue](https://github.com/CraftStick/ClaudeNotch/issues/new) and tell me about it.

## About Clawd

Clawd is Anthropic's character, and his sprites aren't in this repository: the app reads them from the Claude app on your Mac, and draws a simpler Clawd if it isn't there. This project isn't affiliated with or endorsed by Anthropic.

[PolyForm Strict License 1.0.0](LICENSE), for every version, 0.1.0 to 0.2.5 included: you may use Claude Notch for any noncommercial purpose and share unchanged copies of it for free, but not make changes or new works based on it.
