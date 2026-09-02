#!/bin/bash
# Regression test: a nested Claude session must not hijack its parent's session.
#
# hook-startup.sh identifies "its" Claude process by walking the PPID chain. When
# `claude` is launched from inside another Claude session, BOTH the inner and the
# outer process are ancestors of the hook. If the hook resolves to the outer one
# it recolours and retitles the wrong session — and under iTerm2 it aims the
# /color injection at the outer session's TTY, typing into the wrong tab.
#
# The bug was order-dependent (it scanned session files in glob order), so this
# runs the scenario repeatedly rather than once.
#
# Usage: bash tests/nested-session.test.sh [iterations]
set -uo pipefail

ITERATIONS="${1:-20}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# TAB_SETUP_HOOK lets this run against a variant (e.g. to confirm it catches the bug)
HOOK="${TAB_SETUP_HOOK:-$REPO/scripts/hook-startup.sh}"
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT

mkdir -p "$FAKE/.claude/sessions"

# Two stand-in "claude" processes. Each registers a session file keyed by its own
# pid, with a distinct cwd so the hook's emitted sessionTitle reveals which one it
# resolved to. outer runs inner as a child, so outer stays alive as an ancestor.
cat > "$FAKE/outer.sh" <<'EOS'
#!/bin/bash
printf '{"pid":%s,"sessionId":"OUTER-SESSION","cwd":"/tmp/OUTERDIR","startedAt":1,"status":"idle"}' \
  "$$" > "$FAKE_HOME/.claude/sessions/$$.json"
bash "$FAKE_HOME/inner.sh"
EOS

cat > "$FAKE/inner.sh" <<'EOS'
#!/bin/bash
printf '{"pid":%s,"sessionId":"INNER-SESSION","cwd":"/tmp/INNERDIR","startedAt":1,"status":"idle"}' \
  "$$" > "$FAKE_HOME/.claude/sessions/$$.json"
echo '{"source":"startup"}' | env -u TERM_PROGRAM -u VSCODE_IPC_HOOK_CLI HOME="$FAKE_HOME" \
  bash "$HOOK_PATH" 2>/dev/null
EOS
chmod +x "$FAKE/outer.sh" "$FAKE/inner.sh"

export FAKE_HOME="$FAKE" HOOK_PATH="$HOOK"
pass=0; fail=0
for _ in $(seq 1 "$ITERATIONS"); do
    rm -f "$FAKE/.claude/sessions"/*.json
    title=$(bash "$FAKE/outer.sh" | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["sessionTitle"])
except Exception: print("<no-output>")')
    case "$title" in
        INNERDIR*) pass=$((pass+1)) ;;
        *) fail=$((fail+1)); echo "  resolved to '$title' (expected INNERDIR)" >&2 ;;
    esac
done

echo "nested-session: $pass/$ITERATIONS resolved to the inner session"
if [ "$fail" -ne 0 ]; then
    echo "FAIL: $fail run(s) hijacked the outer session" >&2
    exit 1
fi
echo "PASS"
