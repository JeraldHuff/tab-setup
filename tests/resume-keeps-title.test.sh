#!/bin/bash
# Regression test: resuming a session the user renamed must not retitle it.
#
# Claude stores a /rename in ~/.claude/projects/<project>/<session-id>/custom-title.json
# (2.1+) and as `custom-title` transcript entries, and replays it on resume.
# hook-startup.sh used to emit the cwd-derived sessionTitle on every resume as
# well, and the hook's title won — "Holokai – staging go-live" came back as
# "app.holokai-intel.com" and Claude persisted that as the new custom title.
#
# Usage: bash tests/resume-keeps-title.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${TAB_SETUP_HOOK:-$REPO/scripts/hook-startup.sh}"
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT

PROJ="$FAKE/.claude/projects/-tmp-PROJDIR"   # Claude's name for cwd /tmp/PROJDIR
SID="RESUMED-SESSION"
USER_TITLE="Holokai – staging go-live, brand v3.4"

pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "  FAIL: $*" >&2; }

# A stand-in "claude" process: registers its session file, then runs the hook as
# its child so the PPID walk resolves to it. $1 = hook payload source,
# $2 = registry nameSource, $3 = registry name.
cat > "$FAKE/claude.sh" <<'EOC'
#!/bin/bash
printf '{"pid":%s,"sessionId":"%s","cwd":"/tmp/PROJDIR","startedAt":1,"status":"idle","name":"%s","nameSource":"%s"}' \
  "$$" "$SID" "$3" "$2" > "$FAKE_HOME/.claude/sessions/$$.json"
printf '{"source":"%s"}' "$1" | env -u TERM_PROGRAM -u VSCODE_IPC_HOOK_CLI HOME="$FAKE_HOME" \
  bash "$HOOK_PATH" 2>/dev/null
echo "__REGISTRY__"; cat "$FAKE_HOME/.claude/sessions/$$.json"
EOC
chmod +x "$FAKE/claude.sh"
export FAKE_HOME="$FAKE" HOOK_PATH="$HOOK" SID

reset() { # reset — fresh fake HOME with an existing transcript for the session
    rm -rf "$FAKE/.claude"
    mkdir -p "$FAKE/.claude/sessions" "$PROJ/$SID"
    rmdir "$PROJ/$SID"
    printf '{"type":"user","message":"hi","sessionId":"%s"}\n' "$SID" > "$PROJ/$SID.jsonl"
}
run() { # run <source> <nameSource> <name> -> sets TITLE, REGISTRY
    local out; out="$(bash "$FAKE/claude.sh" "$1" "$2" "$3")"
    TITLE="$(printf '%s' "${out%%__REGISTRY__*}" | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["sessionTitle"])
except Exception: print("<no-output>")')"
    REGISTRY="${out##*__REGISTRY__}"
}
titles_in_transcript() { grep -c '"custom-title"' "$PROJ/$SID.jsonl"; }

# --- A. resume, sidecar holds a user title ---------------------------------
reset
mkdir -p "$PROJ/$SID"
printf '{"customTitle":"%s"}' "$USER_TITLE" > "$PROJ/$SID/custom-title.json"
run resume user "$USER_TITLE"
[[ "$TITLE" == "$USER_TITLE" ]] && ok || bad "A: sidecar title lost — got '$TITLE'"
[[ "$REGISTRY" == *"\"name\":\"$USER_TITLE\""* ]] && ok || bad "A: registry name rewritten: $REGISTRY"
[[ "$(titles_in_transcript)" == 0 ]] && ok || bad "A: hook appended a custom-title to the transcript"
grep -q '"agent-color"' "$PROJ/$SID.jsonl" && ok || bad "A: colour not appended to the transcript (session-id glob)"

# --- B. resume, no sidecar; title lives in the transcript (older layout) ---
reset
printf '{"type":"custom-title","customTitle":"PROJDIR","sessionId":"%s"}\n' "$SID" >> "$PROJ/$SID.jsonl"
printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$USER_TITLE" "$SID" >> "$PROJ/$SID.jsonl"
run resume user "$USER_TITLE"
[[ "$TITLE" == "$USER_TITLE" ]] && ok || bad "B: transcript title lost — got '$TITLE'"

# --- C. resume, stored title is the hook's own -> recomputed, not frozen ---
reset
mkdir -p "$PROJ/$SID"
printf '{"customTitle":"PROJDIR (red)"}' > "$PROJ/$SID/custom-title.json"
run resume derived "projdir-c1"
[[ "$TITLE" == "PROJDIR" ]] && ok || bad "C: hook-shaped title not recomputed — got '$TITLE'"
[[ "$(titles_in_transcript)" == 1 ]] && ok || bad "C: derived title not written to the transcript"

# --- D. fresh startup, nothing stored -> derived -----------------------------
reset
run startup derived "projdir-c1"
[[ "$TITLE" == "PROJDIR" ]] && ok || bad "D: startup title — got '$TITLE'"
[[ "$REGISTRY" == *'"name":"PROJDIR"'* ]] && ok || bad "D: registry not mirrored: $REGISTRY"

echo "resume-keeps-title: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] && echo PASS || { echo FAIL >&2; exit 1; }
