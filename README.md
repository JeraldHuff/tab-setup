# tab-setup

A Claude Code skill that gives each terminal tab a unique high-contrast color and renames it after its working directory — automatically, across all open sessions.

## What it does

- Injects **`/color`** and **`/rename`** into the Claude Code session to update the prompt bar
- Sets the **iTerm2 tab color** via escape codes (iTerm2 only)
- Tracks open sessions in `~/.claude/tab-colors.json` and prunes dead ones automatically
- Assigns colors from a pre-computed high-contrast sequence so adjacent tabs never look similar
- A background watcher process removes each session from the tracking file when Claude exits

## Color sequence

Colors are assigned in this order (greedy farthest-point in RGB space):

`red → blue → green → pink → purple → cyan → yellow → orange`

With `sync-all`, sessions are sorted oldest-first so the longest-running session always anchors at red. With `tab-setup` (single session), the earliest free slot in the sequence is claimed.

## Installation

1. Copy this folder into your Claude Code skills directory:

```bash
cp -r tab-setup ~/.claude/skills/tab-setup
chmod +x ~/.claude/skills/tab-setup/scripts/*.sh
```

2. Run at the start of any session:

```
/tab-setup
```

Or sync all open sessions at once:

```
/tab-setup all
```

## Usage

| Command | Effect |
|---|---|
| `/tab-setup` | Color + rename this tab from its CWD |
| `/tab-setup billing` | Color this tab, name it "billing" |
| `/tab-setup all` | Recolor + rename every active Claude session |

## Auto-startup (optional)

`hook-startup.sh` runs automatically at session boot via Claude Code's `SessionStart` hook — no need to type `/tab-setup` each time.

Add to `~/.claude/settings.json`:

```json
"hooks": {
  "SessionStart": [{
    "matcher": "",
    "hooks": [{"type": "command", "command": "bash ~/.claude/skills/tab-setup/scripts/hook-startup.sh"}]
  }]
}
```

**How it works:** `CLAUDE_SESSION_ID` is empty in `SessionStart` hooks (a known Claude Code limitation), so the script discovers the session by matching `/dev/tty` against live session files instead. It then assigns a color, writes iTerm2 escape codes immediately, and injects `/color` + `/rename` via a background AppleScript after a short delay (default 4s — increase via `TAB_SETUP_INJECT_DELAY` if needed).

**Name collision avoidance:** if two sessions share the same project name, the second gets `project (color)` — matching its banner color — so tabs stay visually distinct.

## Requirements

- macOS
- Claude Code CLI
- Python 3 (stdlib only — no pip dependencies)
- iTerm2 (optional) — required for tab color escape codes and auto-injection of `/color`/`/rename`; without it, the assigned color and name are still reported so you can apply them manually
