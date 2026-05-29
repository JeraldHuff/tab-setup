# tab-setup

A Claude Code skill that gives each iTerm2 tab a unique high-contrast color and renames it after its working directory — automatically, across all open sessions.

## What it does

- Sets the **iTerm2 tab color** via proprietary escape codes
- Injects **`/color`** and **`/rename`** into the Claude Code session to update the prompt bar
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

## Requirements

- macOS with iTerm2
- Claude Code CLI
- Python 3 (stdlib only — no pip dependencies)
