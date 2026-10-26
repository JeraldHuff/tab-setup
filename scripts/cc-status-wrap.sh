#!/bin/bash
# cc-status-wrap.sh — let tab-setup coexist with iTerm2's Claude Code integration.
#
# iTerm2 3.7's "Install Claude Code Integration" puts its `cc-status` binary on
# every Claude Code hook event in ~/.claude/settings.json. cc-status reports the
# session state to iTerm2, which draws it as a tab subtitle (Idle / Working /
# Waiting) plus a coloured dot. Two side effects of the integration fight tab-setup:
#
#   1. Its "Enter Workgroup" trigger fires when a `claude` job starts and renames
#      the iTerm2 *session* to the workgroup's main-session name — "Chat" by
#      default. iTerm2 shows the session name on the tab, so the title Claude Code
#      sends (the one tab-setup chose) is hidden behind "Chat".
#   2. cc-status hard-codes the subtitle text colours (idle is #888888 grey),
#      which is unreadable on the saturated tab backgrounds tab-setup assigns.
#
# Replace each cc-status hook command with this script. It runs cc-status itself
# — hooks on one event run in parallel, so a second hook entry would race it —
# then, in a detached background step so the hook adds no latency:
#   - sets the session name to an expression that follows the terminal title,
#     so whatever Claude Code titles the tab shows through again;
#   - re-colours the status text (the dot keeps cc-status's state colour).
#
# Usage (as the hook command, for every event the integration installed on):
#   ~/.claude/skills/tab-setup/scripts/cc-status-wrap.sh [/path/to/cc-status]
#
# Detection: the script does nothing (exit 0) unless the integration is present,
# i.e. a cc-status binary is found — the argument, TAB_SETUP_CC_STATUS,
# ~/.config/iterm2/cc-status (the symlink iTerm2 installs), or iTerm2's bundle.
# Outside iTerm2 (no ITERM_SESSION_ID) it only runs cc-status.
#
# Env knobs:
#   TAB_SETUP_STATUS_TEXT_COLOR  subtitle text colour, #rrggbb (default #ffffff);
#                                "keep" leaves cc-status's per-state colours alone
#   TAB_SETUP_NAME_FORMAT        iTerm2 session-name expression (default
#                                '\(session.terminalWindowName)'); "keep" disables
#                                the rename so a name set in iTerm2 itself sticks
#   TAB_SETUP_CC_STATUS          cc-status path (overrides auto-detection; a
#                                non-executable value means "not installed")
#   TAB_SETUP_IT2                it2 path (default: PATH, then next to cc-status)
#   TAB_SETUP_REAPPLY_DELAYS     seconds between re-applies after SessionStart
#                                (default "2 3"): the Enter Workgroup trigger can
#                                fire after the hook, so the fix is re-run twice
set -u

# Hooks always pipe the JSON payload; only read stdin when it is piped so a
# manual run from a terminal doesn't hang on `cat`.
HOOK_INPUT=""
[[ ! -t 0 ]] && HOOK_INPUT="$(cat 2>/dev/null || true)"

# --- 1. Is the integration installed? -------------------------------------
CC_STATUS=""
if [[ -n "${1:-}" ]]; then
    [[ -x "$1" ]] && CC_STATUS="$1"
elif [[ -n "${TAB_SETUP_CC_STATUS:-}" ]]; then
    [[ -x "$TAB_SETUP_CC_STATUS" ]] && CC_STATUS="$TAB_SETUP_CC_STATUS"
else
    for cand in "$HOME/.config/iterm2/cc-status" \
                "/Applications/iTerm.app/Contents/Resources/utilities/cc-status"; do
        [[ -x "$cand" ]] && { CC_STATUS="$cand"; break; }
    done
fi
[[ -z "$CC_STATUS" ]] && exit 0   # not installed: nothing to report, nothing to undo

# --- 2. Run cc-status exactly as the integration would -------------------
printf '%s' "$HOOK_INPUT" | "$CC_STATUS"
RC=$?

# --- 3. Undo the integration's tab side effects (iTerm2 only) -------------
SID="${ITERM_SESSION_ID:-}"
SID="${SID#*:}"                       # "w0t1p0:UUID" -> "UUID"
[[ -z "$SID" ]] && exit "$RC"

IT2="${TAB_SETUP_IT2:-}"
[[ -z "$IT2" ]] && IT2="$(command -v it2 2>/dev/null || true)"
if [[ -z "$IT2" || ! -x "$IT2" ]]; then
    IT2="$(dirname "$(readlink -f "$CC_STATUS" 2>/dev/null || printf '%s' "$CC_STATUS")")/it2"
fi
[[ -x "$IT2" ]] || exit "$RC"

TEXT_COLOR="${TAB_SETUP_STATUS_TEXT_COLOR:-#ffffff}"
NAME_FORMAT="${TAB_SETUP_NAME_FORMAT:-\\(session.terminalWindowName)}"
REAPPLY_DELAYS="${TAB_SETUP_REAPPLY_DELAYS:-2 3}"

EVENT="$(printf '%s' "$HOOK_INPUT" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

# SessionEnd: cc-status has just cleared the status; don't recreate it.
[[ "$EVENT" == "SessionEnd" ]] && exit "$RC"

# The rename only needs to happen when the workgroup could have renamed us (a
# new `claude` job: SessionStart) plus once per turn as a safety net. Tool
# events (PreToolUse/PostToolUse) only recolour.
RENAME=0
case "$EVENT" in
    SessionStart|UserPromptSubmit|Stop|"") RENAME=1 ;;
esac

apply() {
    if [[ "$TEXT_COLOR" != "keep" ]]; then
        "$IT2" session set-status --session "$SID" --text-color "$TEXT_COLOR"
    fi
    if [[ "$RENAME" == 1 && "$NAME_FORMAT" != "keep" ]]; then
        "$IT2" session set-name "$NAME_FORMAT" --session "$SID"
    fi
}

# Detached: stdio closed so Claude Code's hook runner doesn't wait on us.
(
    apply
    if [[ "$EVENT" == "SessionStart" ]]; then
        for d in $REAPPLY_DELAYS; do
            sleep "$d"
            apply
        done
    fi
) >/dev/null 2>&1 </dev/null &

exit "$RC"
