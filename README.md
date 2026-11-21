# agent-status

A tiny macOS menu bar light for your **Claude Code** and **Codex** sessions.

The menu bar shows one small pill with three counts:

| Box | Counts sessions that… |
|---|---|
| 🟨 yellow | are waiting for you: a permission to approve, a question, a plan to review |
| 🟩 green | are running |
| 🟦 blue | finished, and you haven't looked yet |

Sessions you've already seen, and interrupted ones, aren't shown.

Click the badge to see every session. Click a session to jump straight back to it in Claude Code Desktop or the Codex app (or to the terminal it runs in).

There's no daemon. The agents' own hooks write one small JSON file per session and ask SwiftBar to redraw at once. Each redraw also checks what the apps themselves recorded (see below), which catches what the hooks can't see.

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

Hooks give the live signal:

| Event | Claude Code | Codex | State |
|---|---|---|---|
| prompt sent | `UserPromptSubmit` | same | **running (green)** |
| approval or question | `PermissionRequest`, `PreToolUse` (AskUserQuestion / ExitPlanMode), `Notification` | `PermissionRequest` | **waiting (yellow)** |
| tool finished after approval | `PostToolUse` | `PostToolUse` | back to running |
| turn finished | `Stop` | `Stop` | **done (blue until seen)** |
| interrupted | – | `Interrupt` | not shown |
| session closed | `SessionEnd` (CLI) · archived (Desktop) | `SessionEnd` (CLI) · archived (app) | not shown |

The Claude and Codex apps send `SessionEnd` every time they quit and `SessionStart` when they reopen a session, so for app sessions neither one changes the state; archiving does.

Some changes send no hook at all: pressing Esc in Claude Code, denying an approval, or a session that hasn't fired a hook since you installed. So every redraw also reads, for sessions active recently:

- **The end of each transcript** (`~/.claude/projects/…`, `~/.codex/sessions/…`): did the last turn finish, get interrupted, or is it still going? When the transcript is newer than the last hook event, it wins. Approvals and questions only come from hooks.
- **Claude Desktop's session files** (`~/Library/Application Support/Claude/claude-code-sessions/`): the session title, whether it's archived, and when you last opened it. A finished session you've opened since counts as seen.
- **Codex's state database** (`~/.codex/state_*.sqlite`, read-only): the thread title, whether it's archived, and the Codex app's own read/unread mark.

A blue session counts as seen, and leaves the badge, when you click it in the menu, open it in the app, or send it a new message. Yellow and blue sessions nobody looks at are cleared after 24 hours. A running session with no sign of life for 30 minutes stops counting as running.

Jump targets are worked out when the hook fires:

- Claude Code Desktop: `claude://claude.ai/epitaxy/<local session id>` (from `CLAUDE_CODE_HOST_SESSION_ID`)
- Codex app: `codex://threads/<thread id>`
- Terminal sessions: the terminal app that started them (`__CFBundleIdentifier`)

These deep links aren't documented by either app, so if one stops working, clicking still brings the app forward.

## Commands

```sh
bin/agent-status status      # current sessions as JSON
bin/agent-status seen-all    # mark every finished session as seen
bin/agent-status uninstall   # remove the hooks and the plugin
```

Menu language follows your macOS language (English or Chinese). Set `AGENT_STATUS_LANG=zh` or `en` in the plugin file to change it.

To debug the hooks, `touch ~/.agent-status/.debug`. Every event is then appended to `~/.agent-status/debug.log`, with prompts and tool output replaced by their length. Delete `.debug` to stop.

See [DESIGN.md](DESIGN.md) for the design notes.
