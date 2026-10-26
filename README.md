# tab-setup

A Claude Code skill that gives each terminal tab a unique high-contrast color and renames it after its working directory — automatically, across all open sessions.

## What it does

- Injects **`/color`** and **`/rename`** into the Claude Code session to update the banner
- Tracks session→color assignments in `~/.claude/tab-colors.json` and prunes dead ones automatically
- Assigns colors from a pre-computed high-contrast sequence so adjacent sessions never look similar
- Avoids name collisions: if two sessions share a project name, the second gets `project (color)` appended
- Dead sessions are pruned lazily on the next run — every reader drops entries whose process is gone, so no background process is needed

## Supported environments

| Environment | Banner color | Tab background | Auto-inject |
|---|---|---|---|
| iTerm2 (macOS) | ✅ `/color` via AppleScript | ✅ iTerm2 escape codes | ✅ polls until ready (~1s) |
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

### Updating

Claude runs the skill from `~/.claude/skills/tab-setup`, **not** from this repo, so
pulling changes (or merging a PR) does not update the copy Claude executes. After any
`git pull`, re-sync the installed copy:

```bash
bash scripts/install.sh
```

It copies the skill files into place, verifies the installed scripts match the repo,
and warns if anything is still stale. Changes take effect on the **next** Claude session.
When a VS Code-family server (VS Code, code-server, or Cursor) is detected, it also
(re)installs the companion extension automatically — **reload the window** to activate it.

Once installed, you can also update from inside Claude — `install.sh` records the repo
location, so this pulls the latest and re-installs (extension included) in one step:

```
/tab-setup update
```

**VS Code / code-server** — `install.sh` installs the companion extension for you. To
install it on its own (or if you skipped `install.sh`):

```bash
bash ~/.claude/skills/tab-setup/vscode-extension/install.sh
```

Either way, reload the VS Code window to activate it.

## Usage

| Command | Effect |
|---|---|
| `/tab-setup` | Color + rename this tab from its CWD |
| `/tab-setup billing` | Color this tab, name it "billing" |
| `/tab-setup all` | Recolor + rename every active Claude session |

## Auto-startup (optional)

By default you trigger this skill by typing `/tab-setup`. If you'd rather have every
session color itself automatically at boot — no typing — register `hook-startup.sh` as
a **Claude Code `SessionStart` hook**.

> **Note:** this is a change to **Claude Code's own configuration**, not to the skill.
> The skill only provides the script; the hook is what makes Claude run it on startup.
> Installing/updating the skill does **not** enable auto-startup — you opt in here, once.

### 1. Edit your Claude Code settings

Open `~/.claude/settings.json` (global, applies to every project) and add a
`SessionStart` hook. **Merge** it into any existing `hooks` block — don't overwrite
hooks you already have (e.g. `Notification`, `Stop`):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/skills/tab-setup/scripts/hook-startup.sh"
          }
        ]
      }
    ]
  }
}
```

For a per-project hook instead of global, put the same block in
`<project>/.claude/settings.json`.

### 2. Verify it's wired up

```bash
# Should print the command string with no error:
jq -e '.hooks.SessionStart[].hooks[].command' ~/.claude/settings.json

# Smoke-test the script the way the hook calls it (should exit 0):
echo '{}' | bash ~/.claude/skills/tab-setup/scripts/hook-startup.sh
```

## Tests

```bash
node --test tests/session-status.test.js   # VS Code extension session lookup
bash tests/nested-session.test.sh          # nested session must not hijack its parent
bash tests/cc-status-wrap.test.sh          # iTerm2 Claude Code integration wrapper
```

`nested-session.test.sh` builds a fake `$HOME` and a real parent/child process pair,
each registering its own session file, then asserts the hook resolves to the *inner*
one. It runs the scenario 20 times by default because the failure it guards against was
order-dependent rather than consistent. Point it at a variant with
`TAB_SETUP_HOOK=/path/to/hook-startup.sh`.

The hook takes effect on the **next** session you start (not the current one). You can
review or disable it anytime from the `/hooks` menu, or by deleting the `SessionStart`
block. A broken `settings.json` silently disables *all* settings in that file, so keep
the JSON valid.

### How it works

The script works around the `CLAUDE_SESSION_ID=''` limitation in `SessionStart` hooks by
walking the PPID chain (hook → shell → claude) to identify the Claude process, then
dispatches to the correct injection mechanism based on the detected environment. No
`/dev/tty` access required — works in code-server and JupyterHub too.

### Naming

The tab name is set natively through the hook's `sessionTitle` output, so no `/rename`
is typed into the prompt and the name is in place before the first paint. It must be
nested under `hookSpecificOutput` — for `SessionStart`, Claude reads
`hookSpecificOutput.sessionTitle`, and a top-level `sessionTitle` is silently dropped.

### Tuning

Only `/color` is still injected, and the injector waits for the session to report ready
(measured ~0.7s) instead of sleeping a fixed guess, then pauses `SETTLE` before typing.
It aborts without typing anything if Claude exits first. `TAB_SETUP_INJECT_DELAY` is
superseded; the knobs are `TAB_SETUP_INJECT_SETTLE` (default `0.25`) and
`TAB_SETUP_INJECT_TIMEOUT` (integer seconds, default `10`):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "TAB_SETUP_INJECT_SETTLE=0.4 bash ~/.claude/skills/tab-setup/scripts/hook-startup.sh"
          }
        ]
      }
    ]
  }
}
```

## iTerm2's Claude Code integration

iTerm2 3.7 ships its own Claude Code integration (**iTerm2 > Install Claude Code
Integration**). It is useful — a status dot and an Idle / Working / Waiting subtitle on
every tab — but two of its side effects fight this skill:

- Its *Enter Workgroup* trigger fires whenever a `claude` job starts and renames the
  iTerm2 session to the workgroup's main-session name, **"Chat"**. iTerm2 shows the
  session name on the tab, so the title tab-setup chose disappears behind "Chat".
- Its `cc-status` hook hard-codes the subtitle colours (idle is `#888888` grey), which is
  unreadable on the saturated tab backgrounds tab-setup assigns.

`scripts/cc-status-wrap.sh` fixes both while keeping the integration. Point every hook
the integration installed at it instead of `cc-status` (it is installed on
`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`,
`PermissionRequest`, `Stop`, `StopFailure`, `SubagentStop` and `SessionEnd`):

```json
{
  "type": "command",
  "command": "~/.claude/skills/tab-setup/scripts/cc-status-wrap.sh ~/.config/iterm2/cc-status"
}
```

The wrapper runs `cc-status` itself (hooks on one event run in parallel, so a separate
hook entry would race it), then in a detached background step — no added hook latency —
sets the session name to `\(session.terminalWindowName)` so the tab follows whatever
title Claude Code sends, and recolours the status text white. The argument is optional:
without it the wrapper looks for `~/.config/iterm2/cc-status` and then iTerm2's bundle,
and **does nothing when the integration is not installed**, so the hook entries are safe
to leave in place if you later uninstall it. Outside iTerm2 it only runs `cc-status`.

Knobs (environment variables on the hook command): `TAB_SETUP_STATUS_TEXT_COLOR`
(`#rrggbb`, or `keep` for cc-status's per-state colours), `TAB_SETUP_NAME_FORMAT` (an
iTerm2 session-name expression, or `keep` to leave names alone), `TAB_SETUP_CC_STATUS`,
`TAB_SETUP_IT2`, `TAB_SETUP_REAPPLY_DELAYS`. Tests: `bash tests/cc-status-wrap.test.sh`.

## Requirements

- Claude Code CLI
- Python 3 (stdlib only — no pip dependencies)
- **iTerm2** (macOS) — for tab background color and auto-injection
- **VS Code extension** (code-server / VS Code) — for auto-injection; see installation above

## Running tests

Tests use Node's built-in runner (`node:test`, Node 18+) — no dependencies to install:

```bash
node --test
```
