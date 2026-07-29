#!/bin/bash
# Sync this repo's skill files into Claude Code's installed skill location.
#
# Claude runs the skill from ~/.claude/skills/tab-setup, NOT from this repo.
# After pulling changes (e.g. a merged PR), run this so the installed copy
# Claude actually executes matches the repo. Safe to run repeatedly.
#
# Usage: bash scripts/install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${HOME}/.claude/skills/tab-setup"

echo "Installing tab-setup skill"
echo "  from: $REPO_DIR"
echo "  to:   $DEST"

mkdir -p "$DEST/scripts"

# Skill files Claude reads at runtime.
cp "$REPO_DIR/SKILL.md"            "$DEST/SKILL.md"
cp "$REPO_DIR/README.md"           "$DEST/README.md"
cp "$REPO_DIR/scripts/hook-startup.sh" "$DEST/scripts/hook-startup.sh"
cp "$REPO_DIR/scripts/setup.sh"        "$DEST/scripts/setup.sh"
cp "$REPO_DIR/scripts/sync-all.sh"     "$DEST/scripts/sync-all.sh"
cp "$REPO_DIR/scripts/install.sh"      "$DEST/scripts/install.sh"
cp "$REPO_DIR/scripts/update.sh"       "$DEST/scripts/update.sh"

# VS Code extension source — kept in the skill dir so the documented
# vscode-extension/install.sh path stays valid after a script-based install.
# Copy the tree wholesale rather than naming files: an enumerated copy silently
# omitted lib/ once extension.js started requiring it, which left the deployed
# fallback path ("run vscode-extension/install.sh manually") installing an
# extension that threw at activation. rm -rf first so files dropped upstream
# don't linger as a stale deployed copy.
rm -rf "$DEST/vscode-extension"
cp -r "$REPO_DIR/vscode-extension" "$DEST/vscode-extension"

chmod +x "$DEST/scripts/"*.sh "$DEST/vscode-extension/install.sh"

# Record where this repo lives so `update.sh` knows what to git-pull.
# Written to the skill root (not scripts/) so it doesn't break the verify diff.
printf '%s\n' "$REPO_DIR" > "$DEST/.repo-path"

# Verify the installed files match the repo so a silent stale copy can't linger.
# vscode-extension/ is checked too: it's the tree whose enumerated copy used to
# drop lib/, and that omission was invisible until the extension host logged a
# failed activation.
if diff -rq "$REPO_DIR/scripts" "$DEST/scripts" >/dev/null \
   && diff -rq "$REPO_DIR/vscode-extension" "$DEST/vscode-extension" >/dev/null; then
    echo "Done — installed scripts and extension match the repo."
else
    echo "Warning: installed files still differ from the repo after copy:" >&2
    diff -rq "$REPO_DIR/scripts" "$DEST/scripts" >&2 || true
    diff -rq "$REPO_DIR/vscode-extension" "$DEST/vscode-extension" >&2 || true
    exit 1
fi

# Rebuild the VS Code extension when a VS Code-family server is present, so the
# integrated-terminal injection path picks up extension.js changes without a
# separate manual step. Skipped silently on machines with no such server (e.g.
# a plain iTerm setup), since the extension is irrelevant there.
if [[ -d "$HOME/.local/share/code-server/extensions" \
   || -d "$HOME/.cursor-server" \
   || -d "$HOME/.vscode-server" ]]; then
    echo "VS Code-family server detected — (re)installing the companion extension…"
    if bash "$REPO_DIR/vscode-extension/install.sh"; then
        echo "Extension installed. Reload the VS Code window to activate it."
    else
        echo "Warning: extension install failed — run vscode-extension/install.sh manually." >&2
    fi
fi

echo "Note: changes take effect on the next Claude session (the hook fires at SessionStart)."
