# agent-status

A tiny macOS menu bar light for your **Claude Code** and **Codex** sessions.

The menu bar shows three counts side by side:

| Box | Counts sessions that… |
|---|---|
| 🟥 red | are waiting for you: a permission to approve, a question, a plan to review |
| 🟩 green | finished and you haven't looked yet |
| ⬜ grey | need nothing from you (running or idle) |

Click the badge to see every session. Click a session to jump straight back to it in Claude Code Desktop or the Codex app (or to the terminal it runs in).

There's no daemon and no polling. The agents' own hooks write one small JSON file per session, and SwiftBar redraws the menu only when a state changes.

## Requirements

- macOS, with `/usr/bin/python3` and `swiftc` (both come with the Xcode Command Line Tools: `xcode-select --install`). `swiftc` builds the badge once at install; without it the menu shows a single coloured dot
- [SwiftBar](https://github.com/swiftbar/SwiftBar): `brew install --cask swiftbar`
- Claude Code (CLI or Desktop) and/or Codex (CLI 0.169+ or the Codex app)

## Install

```sh
git clone https://github.com/Handsomemikezzz/agent-monitor.git ~/agent-status
~/agent-status/install.sh
```

`install.sh` adds hooks to `~/.claude/settings.json` and `~/.codex/hooks.json`. It backs up each file first and leaves your other hooks alone, so you can run it again safely. It also writes the plugin into your SwiftBar plugin folder.

**Codex:** Codex runs a new hook only after you trust it, and it doesn't prompt you on its own. When `install.sh` runs in a terminal, it lists the hooks and asks you `[y/N]`. You can also do this later:

```sh
bin/agent-status trust-codex
```

It uses the same `codex app-server` API that the Codex app's **Settings → Hooks → Review hooks** page uses, and you can trust them on that page instead. If a hook's definition changes, Codex asks you to trust it again.

## How it works

| Event | Claude Code | Codex | State |
|---|---|---|---|
| prompt sent, session started | `UserPromptSubmit`, `SessionStart` | same | running (grey) |
| approval or question | `PermissionRequest`, `PreToolUse` (AskUserQuestion / ExitPlanMode), `Notification` | `PermissionRequest` | **waiting (red)** |
| tool finished after approval | `PostToolUse` | `PostToolUse` | back to running |
| turn finished | `Stop` | `Stop` | **done (green)** |
| interrupted | – | `Interrupt` | grey |
| session closed | `SessionEnd` | `SessionEnd` | removed |

A green light goes back to grey when you send that session a new message, when you click it in the menu, or after 2 hours. Sessions with no events for 12 hours are forgotten.

Jump targets are worked out when the hook fires:

- Claude Code Desktop: `claude://claude.ai/epitaxy/<local session id>` (from `CLAUDE_CODE_HOST_SESSION_ID`)
- Codex app: `codex://threads/<thread id>`
- Terminal sessions: the terminal app that started them (`__CFBundleIdentifier`)

These deep links aren't documented by either app, so if one stops working, clicking still brings the app forward.

## Commands

```sh
bin/agent-status status      # current sessions as JSON
bin/agent-status seen-all    # turn every green light grey
bin/agent-status uninstall   # remove the hooks and the plugin
```

Menu language follows your macOS language (English or Chinese). Set `AGENT_STATUS_LANG=zh` or `en` in the plugin file to change it.

To debug the hooks, `touch ~/.agent-status/.debug`. Every event is then appended to `~/.agent-status/debug.log`, with prompts and tool output replaced by their length. Delete `.debug` to stop.

See [DESIGN.md](DESIGN.md) for the design notes.
