#!/bin/bash
# Tests for scripts/cc-status-wrap.sh: it must run cc-status with the hook payload
# untouched, propagate its exit code, and only then fix the iTerm2 session —
# and must do nothing at all when the integration isn't installed.
#
# cc-status and it2 are replaced by stubs that log what they were called with.
#
# Usage: bash tests/cc-status-wrap.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAP="${TAB_SETUP_WRAP:-$REPO/scripts/cc-status-wrap.sh}"
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT

mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/cc-status" <<'EOS'
#!/bin/bash
cat > "$STUB_LOG.payload"
echo "cc-status $*" >> "$STUB_LOG"
exit "${STUB_CC_RC:-0}"
EOS
cat > "$FAKE/bin/it2" <<'EOS'
#!/bin/bash
echo "it2 $*" >> "$STUB_LOG"
EOS
chmod +x "$FAKE/bin/cc-status" "$FAKE/bin/it2"

pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "  FAIL: $*" >&2; }
check() { # check <desc> <condition...>
    local desc="$1"; shift
    if "$@"; then ok; else bad "$desc"; fi
}

run() { # run <event> <env assignments...> ; stdin payload built from event
    local event="$1"; shift
    : > "$STUB_LOG"; : > "$STUB_LOG.payload"
    printf '{"session_id":"abc","hook_event_name":"%s","cwd":"/tmp"}' "$event" \
      | env "$@" TAB_SETUP_IT2="$FAKE/bin/it2" TAB_SETUP_REAPPLY_DELAYS="0" \
            bash "$WRAP" "$FAKE/bin/cc-status"
    local rc=$?
    sleep 0.4   # the fix runs detached; give it a moment to log
    return $rc
}

export STUB_LOG="$FAKE/log"

echo "1. not installed → exit 0, nothing runs"
: > "$STUB_LOG"
printf '{"hook_event_name":"Stop"}' | env TAB_SETUP_CC_STATUS="$FAKE/nope" \
    ITERM_SESSION_ID="w0t0p0:UUID-1" TAB_SETUP_IT2="$FAKE/bin/it2" bash "$WRAP"
check "exit 0 when cc-status is absent" test $? -eq 0
check "no stub calls when absent" test ! -s "$STUB_LOG"

echo "2. PreToolUse in iTerm2 → payload forwarded, recolour only"
run PreToolUse ITERM_SESSION_ID="w0t1p0:UUID-2"
check "payload reaches cc-status verbatim" \
    grep -q '"hook_event_name":"PreToolUse"' "$STUB_LOG.payload"
check "cc-status runs first" test "$(head -n1 "$STUB_LOG")" = "cc-status "
check "text colour set on the right session" \
    grep -q -- 'it2 session set-status --session UUID-2 --text-color #ffffff' "$STUB_LOG"
check "no rename on a tool event" bash -c "! grep -q set-name '$STUB_LOG'"

echo "3. Stop → recolour and rename with the title-following expression"
run Stop ITERM_SESSION_ID="w0t1p0:UUID-3"
check "rename to terminalWindowName expression" \
    grep -q -- 'it2 session set-name \\(session.terminalWindowName) --session UUID-3' "$STUB_LOG"

echo "4. SessionStart → fix applied, then re-applied per TAB_SETUP_REAPPLY_DELAYS"
run SessionStart ITERM_SESSION_ID="w0t1p0:UUID-4"
check "two set-name calls (initial + one re-apply)" \
    test "$(grep -c set-name "$STUB_LOG")" -eq 2

echo "5. SessionEnd → cc-status only"
run SessionEnd ITERM_SESSION_ID="w0t1p0:UUID-5"
check "no it2 calls on SessionEnd" bash -c "! grep -q '^it2' '$STUB_LOG'"

echo "6. not in iTerm2 → cc-status only"
run Stop ITERM_SESSION_ID=
check "cc-status still ran" grep -q '^cc-status' "$STUB_LOG"
check "no it2 calls outside iTerm2" bash -c "! grep -q '^it2' '$STUB_LOG'"

echo "7. cc-status exit code is propagated"
run Stop ITERM_SESSION_ID="w0t1p0:UUID-7" STUB_CC_RC=3
check "exit code 3 propagated" test $? -eq 3

echo "8. keep/keep → no it2 calls"
run Stop ITERM_SESSION_ID="w0t1p0:UUID-8" TAB_SETUP_STATUS_TEXT_COLOR=keep TAB_SETUP_NAME_FORMAT=keep
check "nothing changed when both knobs are keep" bash -c "! grep -q '^it2' '$STUB_LOG'"

echo "cc-status-wrap: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
