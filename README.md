# tab-setup

A Claude Code skill that gives each terminal tab a unique high-contrast color and renames it after its working directory — automatically, across all open sessions.

## What it does

- Injects **`/color`** and **`/rename`** into the Claude Code session to update the banner
- Tracks session→color assignments in `~/.claude/tab-colors.json` and prunes dead ones automatically
- Assigns colors from a pre-computed high-contrast sequence so adjacent sessions never look similar
- Avoids name collisions: if two sessions share a project name, the second gets `project (color)` appended
- A background watcher process removes each session from the tracking file when Claude exits

## Supported environments

| Environment | Banner color | Tab background | Auto-inject |
|---|---|---|---|
| iTerm2 (macOS) | ✅ `/color` via AppleScript | ✅ iTerm2 escape codes | ✅ ~4s delay |
| VS Code / code-server | ✅ `/color` via extension | ✅ `workbench.action.terminal.changeColor` | ✅ polls until idle |
| Other terminals | ✅ reported to user | ❌ | ❌ manual |

## Color sequence

Colors are assigned in this order (greedy farthest-point in RGB space):

`red → blue → green → pink → purple → cyan → yellow → orange`

With `/tab-setup all`, sessions are sorted oldest-first so the longest-running session always anchors at red. With `/tab-setup` (single session), the sequence rotates from the last assigned color so re-invocations always advance.

## Installation

```bash
cp -r tab-setup ~/.claude/skills/tab-setup
chmod +x ~/.claude/skills/tab-setup/scripts/*.sh
```

**VS Code / code-server only** — install the companion extension once:

```bash
bash ~/.claude/skills/tab-setup/vscode-extension/install.sh
```

Then reload the VS Code window.

## Usage

| Command | Effect |
|---|---|
| `/tab-setup` | Color + rename this tab from its CWD |
| `/tab-setup billing` | Color this tab, name it "billing" |
| `/tab-setup all` | Recolor + rename every active Claude session |

## Auto-startup (optional)

`hook-startup.sh` colors the session automatically at boot — no need to type `/tab-setup`.

Add to `~/.claude/settings.json`:

```json
"hooks": {
  "SessionStart": [{
    "matcher": "",
    "hooks": [{"type": "command", "command": "bash ~/.claude/skills/tab-setup/scripts/hook-startup.sh"}]
  }]
}
```

The script discovers the session by matching `/dev/tty` against live session files (working around the `CLAUDE_SESSION_ID=''` limitation in `SessionStart` hooks), then dispatches to the correct injection mechanism based on the detected environment.

Tune the delay if `/color` fires before Claude's first prompt is ready:

```bash
TAB_SETUP_INJECT_DELAY=6 bash hook-startup.sh
```

## Requirements

- Claude Code CLI
- Python 3 (stdlib only — no pip dependencies)
- **iTerm2** (macOS) — for tab background color and auto-injection
- **VS Code extension** (code-server / VS Code) — for auto-injection; see installation above
