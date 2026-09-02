#!/bin/bash
# Auto-assigns a color and name to a Claude Code session at startup.
# Intended to run as a Claude Code SessionStart hook.
#
# Fully self-contained — no dependency on session-init.py or any other ai-tools script.
#
# Install: add to ~/.claude/settings.json:
#
#   "hooks": {
#     "SessionStart": [{
#       "matcher": "",
#       "hooks": [{"type": "command", "command": "bash ~/.claude/skills/tab-setup/scripts/hook-startup.sh"}]
#     }]
#   }
#
# Only acts on SessionStart source=startup|resume. On source=compact|clear it
# exits early, since injecting /color + /rename into the live prompt mid-compact
# interrupts the compaction.
#
# Note: CLAUDE_SESSION_ID is empty in SessionStart hooks (Claude Code limitation).
# Session discovery walks the PPID chain to find the parent Claude process,
# then matches its PID against session JSON files — no TTY access required.
#
# The tab name is set natively via the hook's sessionTitle output (no typing).
# Only /color still needs injecting, and the injector waits for the session to
# report ready rather than sleeping a fixed guess. Tunable:
#   TAB_SETUP_INJECT_SETTLE=0.4 TAB_SETUP_INJECT_TIMEOUT=15 bash hook-startup.sh

# SessionStart fires on five sources: startup, resume, clear, compact and fork.
# Only startup/resume should trigger colour injection. The other three all fire
# inside a session that is already running, where the injected /color is typed
# into the live prompt via `write text` — interrupting a compaction, and (because
# the injection clears the input line with Ctrl-E/Ctrl-U first) discarding
# whatever the user had already typed. Read the hook payload from stdin and bail
# on anything but startup/resume. (Missing/unparseable source falls through to
# normal behavior so a payload-format change never silently disables the hook.)
#
# resume still runs, but not for the name: the name is carried across a resume by
# the custom-title/agent-name entries this script appends to the transcript,
# which Claude replays on load (verified by resuming with the hook disabled). It
# runs so the iTerm2 tab background colour is re-emitted, since that is terminal
# state the new tab does not inherit.
#
# Only read stdin when it's piped — hook invocations always pipe the payload,
# but a manual `bash hook-startup.sh` from a terminal would hang on `cat`
# waiting for Ctrl-D.
HOOK_INPUT=""
[[ ! -t 0 ]] && HOOK_INPUT="$(cat 2>/dev/null || true)"
if [[ -n "$HOOK_INPUT" ]]; then
  SOURCE="$(printf '%s' "$HOOK_INPUT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("source",""))
except Exception: pass' 2>/dev/null)"
  case "$SOURCE" in
    compact|clear|fork)
      exit 0
      ;;
  esac
fi

TRACKING_FILE="${HOME}/.claude/tab-colors.json"
SESSIONS_DIR="${HOME}/.claude/sessions"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Injection timing. The old TAB_SETUP_INJECT_DELAY (a fixed pre-injection sleep)
# is superseded: the injector now polls the session registry for readiness.
# SETTLE  — pause after the session reports ready, before typing.
# TIMEOUT — ceiling on the wait; inject anyway past this, as the old code did.
INJECT_SETTLE="${TAB_SETUP_INJECT_SETTLE:-0.25}"
INJECT_TIMEOUT="${TAB_SETUP_INJECT_TIMEOUT:-10}"

[[ ! -f "$TRACKING_FILE" ]] && echo '{}' > "$TRACKING_FILE"

python3 - "$TRACKING_FILE" "$SESSIONS_DIR" "$SCRIPTS_DIR" "$INJECT_SETTLE" "$INJECT_TIMEOUT" <<'PYEOF'
import glob, json, os, re, subprocess, sys, time

SEQUENCE = ["red", "blue", "green", "pink", "purple", "cyan", "yellow", "orange"]
COLORS = {
    "red":    (220, 50,  47),
    "blue":   (38,  139, 210),
    "green":  (133, 153, 0),
    "yellow": (181, 137, 0),
    "purple": (108, 113, 196),
    "orange": (203, 75,  22),
    "pink":   (211, 54,  130),
    "cyan":   (42,  161, 152),
}

tracking_file, sessions_dir, scripts_dir, inject_settle, inject_timeout = sys.argv[1:]


def find_session_by_ppid(retries=10, delay=0.3):
    """Walk the PPID chain to find the Claude process, match to session JSON.

    Ancestors are kept in order — nearest first — and the nearest one that owns a
    live session wins. Scanning session files instead (in glob order) picks an
    arbitrary match whenever more than one ancestor is a Claude session, which is
    exactly the nested case: `claude` launched from inside a Claude session has
    both the inner and outer process in its ancestry. The child's hook could then
    resolve to the OUTER session and recolour/retitle it, and under iTerm2 aim the
    /color injection at the outer session's TTY — typing into the wrong tab.
    """
    ancestor_pids = []  # ordered, nearest ancestor first
    pid = os.getpid()
    for _ in range(8):
        try:
            r = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)],
                               capture_output=True, text=True, timeout=2)
            if r.returncode != 0:
                break
            ppid = int(r.stdout.strip())
            if ppid <= 1:
                break
            ancestor_pids.append(ppid)
            pid = ppid
        except Exception:
            break

    for _ in range(retries):
        live = {}
        for f in glob.glob(os.path.join(sessions_dir, "*.json")):
            try:
                data = json.load(open(f))
                session_pid = data.get("pid")
                if not session_pid or session_pid in live:
                    continue
                os.kill(session_pid, 0)  # confirm alive
                live[session_pid] = (data.get("sessionId", ""), data.get("cwd", ""))
            except Exception:
                continue
        for candidate in ancestor_pids:  # nearest first — innermost session wins
            if candidate in live:
                session_id_, cwd_ = live[candidate]
                return candidate, session_id_, cwd_
        time.sleep(delay)
    return None, None, None


def env_reminder(project_dir):
    """Detect the active environment and return a reminder string, or None."""
    if os.path.exists(os.path.join(project_dir, "pixi.toml")):
        return "run: pixi shell"
    env_yml = os.path.join(project_dir, "environment.yml")
    if os.path.exists(env_yml):
        try:
            for line in open(env_yml):
                m = re.match(r"^name:\s*(.+)", line.strip())
                if m:
                    return f"activate: conda {m.group(1).strip()}"
        except Exception:
            pass
        return "activate: conda (see environment.yml)"
    pv = os.path.join(project_dir, ".python-version")
    if os.path.exists(pv):
        v = open(pv).read().strip()
        if v:
            return f"python {v}"
    cs = os.path.join(project_dir, ".claude-session")
    if os.path.exists(cs):
        try:
            for line in open(cs):
                m = re.match(r"^(conda|pixi|env|run):\s*(.+)", line.strip())
                if m:
                    k, v = m.group(1), m.group(2).strip()
                    return f"activate: conda {v}" if k == "conda" else f"run: {v}"
        except Exception:
            pass
    cfg = os.path.expanduser("~/.claude/session-init-config.json")
    if os.path.exists(cfg):
        try:
            d = json.load(open(cfg))
            e = d.get("default_env", "").strip()
            if e:
                return f"run: {e}"
        except Exception:
            pass
    return None


# ---------------------------------------------------------------------------
# Session discovery
# ---------------------------------------------------------------------------

claude_pid, session_id, cwd = find_session_by_ppid()
if not claude_pid:
    sys.exit(0)

project_name = os.path.basename(cwd.rstrip("/")) or "claude"

# Derive TTY device path from the Claude process (needed for iTerm2 escape codes)
try:
    r = subprocess.run(
        ["ps", "-o", "tty=", "-p", str(claude_pid)],
        capture_output=True, text=True, timeout=2,
    )
    tty_short = r.stdout.strip() if r.returncode == 0 else ""
    tty_dev = f"/dev/{tty_short}" if tty_short and tty_short != "??" else None
except Exception:
    tty_dev = None

# The session title is emitted further down, once the tab name (including any
# dedup suffix) has been computed — see "Session title" below.

# ---------------------------------------------------------------------------
# Tab color assignment
# ---------------------------------------------------------------------------

try:
    tracking = json.load(open(tracking_file))
except Exception:
    tracking = {}

# Build the set of genuinely-live Claude PIDs from the authoritative session
# registry (~/.claude/sessions/<pid>.json, one file per live session). A bare
# os.kill(pid, 0) only proves *some* process owns that PID, so a recycled PID
# would make a dead session's tracking entry read as alive — producing spurious
# name-dedup suffixes like "ai-tools (cyan)". Cross-referencing the registry
# eliminates that false positive. Fall back to os.kill only if the registry is
# unavailable (older Claude versions that don't write session files).
registry_pids = set()
for f in glob.glob(os.path.join(sessions_dir, "*.json")):
    try:
        registry_pids.add(json.load(open(f)).get("pid"))
    except Exception:
        pass
registry_pids.discard(None)

def _is_live(pid):
    if not pid:
        return False
    if registry_pids:
        return pid in registry_pids
    try:
        os.kill(pid, 0)
        return True
    except Exception:
        return False

# Prune dead sessions; skip _last cursor and malformed entries
live, used_colors = {}, set()
for sid, entry in tracking.items():
    if sid == session_id or sid == "_last" or not isinstance(entry, dict):
        continue
    if _is_live(entry.get("pid", 0)):
        live[sid] = entry
        used_colors.add(entry.get("color", ""))

# Persistence lookup via project-colors.json (keyed by cwd, watcher-safe).
# PID is stored alongside the color to distinguish /clear from claude -c:
#   /clear    → same cwd, same PID  → reuse regardless of used_colors
#   claude -c → same cwd, new PID   → reuse only if color not held by another live session
#   fresh     → no entry or color occupied → rotate
project_colors_file = os.path.expanduser("~/.claude/project-colors.json")
try:
    project_colors = json.load(open(project_colors_file))
except Exception:
    project_colors = {}

proj = project_colors.get(cwd, {})
proj_color = proj.get("color")
same_process = proj.get("pid") == claude_pid

if proj_color in SEQUENCE and (same_process or proj_color not in used_colors):
    chosen = proj_color
else:
    # Rotate from last used color; skip colors already held by live sessions
    last_color = tracking.get("_last", "")
    try:
        start = (SEQUENCE.index(last_color) + 1) % len(SEQUENCE)
    except ValueError:
        start = 0
    chosen = next(
        (SEQUENCE[(start + i) % len(SEQUENCE)] for i in range(len(SEQUENCE))
         if SEQUENCE[(start + i) % len(SEQUENCE)] not in used_colors),
        SEQUENCE[start]
    )

# Recompute the disambiguation suffix every boot from the CURRENTLY live
# sessions — never inherit a stale "(color)" label from project-colors.json.
# The suffix is only added when another live session already holds the plain
# project name; once that conflict clears, the label drops on the next boot.
existing_names = {e.get("name", "") for e in live.values()}
name = f"{project_name} ({chosen})" if project_name in existing_names else project_name

# ---------------------------------------------------------------------------
# Session title — native, no /rename injection
# ---------------------------------------------------------------------------
#
# The hook already knows the name: it computed it just above from the cwd. So it
# hands the name straight back to Claude on stdout instead of typing a /rename
# into the TUI. This applies before the first paint, with no delay and no race.
#
# Must be nested under hookSpecificOutput. For SessionStart, Claude reads
# `hookSpecificOutput.sessionTitle`; a top-level "sessionTitle" is not in the
# base hook-output schema and is silently dropped by the parser.
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "sessionTitle": name,
    }
}), flush=True)

# Mirror the name into the session registry so `claude --resume` lists the tab
# name rather than Claude's auto-derived one. Skipped when the user has renamed
# the session themselves (nameSource == "user"), so a deliberate rename sticks.
for f in glob.glob(os.path.join(sessions_dir, "*.json")):
    try:
        data = json.load(open(f))
        if data.get("sessionId") != session_id:
            continue
        if data.get("nameSource") != "user" and data.get("name") != name:
            data["name"] = name
            with open(f, "w") as wf:
                # Compact separators match how Claude writes this file; the
                # default ", "/": " would reformat it on every launch.
                json.dump(data, wf, separators=(",", ":"))
        break
    except Exception:
        pass

# Write to both stores; project-colors.json is the durable persistence layer
live[session_id] = {"color": chosen, "pid": claude_pid, "cwd": cwd, "name": name}
live["_last"] = chosen
with open(tracking_file, "w") as f:
    json.dump(live, f, indent=2)

project_colors[cwd] = {"color": chosen, "name": name, "pid": claude_pid}
with open(project_colors_file, "w") as f:
    json.dump(project_colors, f, indent=2)

# Transcript writes — universal, guarded by file existence
project_hash = cwd.replace("/", "-")
transcript = os.path.expanduser(f"~/.claude/projects/{project_hash}/{session_id}.jsonl")
if os.path.exists(transcript):
    with open(transcript, "a") as f:
        f.write(json.dumps({"type": "agent-color",  "agentColor":  chosen, "sessionId": session_id}) + "\n")
        f.write(json.dumps({"type": "custom-title", "customTitle": name,   "sessionId": session_id}) + "\n")
        f.write(json.dumps({"type": "agent-name",   "agentName":   name,   "sessionId": session_id}) + "\n")

# ---------------------------------------------------------------------------
# Terminal color injection
# ---------------------------------------------------------------------------

r, g, b = COLORS[chosen]
in_iterm2 = os.environ.get("TERM_PROGRAM") == "iTerm.app"
in_vscode = bool(os.environ.get("VSCODE_IPC_HOOK_CLI"))

if in_iterm2 and tty_dev:
    try:
        with open(tty_dev, "w") as tty_f:
            tty_f.write(f"\033]6;1;bg;red;brightness;{r}\007")
            tty_f.write(f"\033]6;1;bg;green;brightness;{g}\007")
            tty_f.write(f"\033]6;1;bg;blue;brightness;{b}\007")
            tty_f.flush()
    except Exception:
        pass

    # AppleScript now types only /color — the tab name is set natively via the
    # hook's sessionTitle output above, so /rename is no longer injected. That
    # also drops the 0.3s pause that separated the two commands.
    ascript_path = os.path.expanduser("~/.claude/tab-setup-hook.applescript")
    with open(ascript_path, "w") as f:
        f.write("""on run argv
  set ttyDevice to item 1 of argv
  set tabColor to item 2 of argv
  try
    tell application "iTerm2"
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if tty of s = ttyDevice then
              -- Prepend Ctrl-E then Ctrl-U so anything the user has typed into
              -- the prompt is cleared before the command is entered. Ctrl-E
              -- moves to end-of-line and Ctrl-U kills to start, so the whole
              -- line is cleared regardless of cursor position. Without this,
              -- write text appends to the input buffer and the typed text merges
              -- into "/color", corrupting it. (These are Claude Code's own
              -- readline bindings, so they behave identically across terminals.)
              tell s to write text ((character id 5) & (character id 21) & "/color " & tabColor)
              return
            end if
          end repeat
        end repeat
      end repeat
    end tell
  end try
end run
""")

    # Wait for readiness instead of sleeping a fixed guess.
    #
    # The old code slept 4s unconditionally, which cost ~4.8s to first colour and
    # had a worse failure mode: it matched the iTerm2 session purely by TTY and
    # never checked Claude was still there, so quitting inside the window typed
    # "/color <name>" into whatever shell inherited the terminal. The poller
    # below aborts instead, and fires as soon as the session is actually up
    # (measured ~0.7s: the registry file gains a "status" field once it is).
    session_json = os.path.join(sessions_dir, f"{claude_pid}.json")
    poller = r"""
sess="$1"; pid="$2"; ascript="$3"; ttydev="$4"; color="$5"; settle="$6"; timeout="$7"
timeout="${timeout%%.*}"; timeout="${timeout:-10}"   # bash arithmetic is integer-only
deadline=$(( $(date +%s) + timeout ))
while :; do
  kill -0 "$pid" 2>/dev/null || exit 0   # Claude exited  — never inject
  [ -f "$sess" ] || exit 0               # session gone   — never inject
  status=$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' "$sess" 2>/dev/null | head -1)
  case "$status" in ""|busy) ;; *) break ;; esac
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.1
done
sleep "$settle"
kill -0 "$pid" 2>/dev/null || exit 0     # re-check: quit during the settle window
[ -f "$sess" ] || exit 0
exec osascript "$ascript" "$ttydev" "$color"
"""
    subprocess.Popen(
        ["bash", "-c", poller, "tab-setup-inject",
         session_json, str(claude_pid), ascript_path, tty_dev, chosen,
         inject_settle, inject_timeout],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
elif in_vscode:
    pending_file = os.path.expanduser("~/.claude/.pending-color")
    with open(pending_file, "w") as f:
        f.write(f"session_id={session_id}\ncolor={chosen}\nname={name}\n")
else:
    sys.stderr.write(f"tab-setup: not in iTerm2 or VS Code — run /color {chosen} and /rename {name}\n")
    sys.stderr.flush()

# Dead sessions are pruned lazily: every reader (setup.sh, hook-startup.sh,
# sync-all.sh) drops entries whose PID is no longer alive on its next run, so
# no background watcher is needed to clean up the tracking file.

# ---------------------------------------------------------------------------
# Startup reminders
# ---------------------------------------------------------------------------

# Handoff reminder — surfaces next action from .ai/HANDOFF.md if present
handoff_path = os.path.join(cwd, ".ai", "HANDOFF.md")
if os.path.exists(handoff_path):
    try:
        content = open(handoff_path).read()
        objective, next_action = None, None
        m = re.search(r"##\s*Objective\s*\n+(.*?)(?:\n##|\Z)", content, re.DOTALL)
        if m:
            for line in m.group(1).split("\n"):
                line = line.strip()
                if line and not line.startswith("<!--"):
                    objective = line
                    break
        m = re.search(r"##\s*Next actions\s*\n+(.*?)(?:\n##|\Z)", content, re.DOTALL)
        if m:
            for line in m.group(1).split("\n"):
                line = line.strip()
                if line and not line.startswith("<!--") and re.match(r"^\d+\.", line):
                    next_action = re.sub(r"^\d+\.\s*", "", line)
                    break
        summary = " → ".join(filter(None, [objective, next_action]))
        if summary:
            sys.stderr.write(f"[resume] {summary}\n")
            sys.stderr.flush()
    except Exception:
        pass

# Environment reminder
reminder = env_reminder(cwd)
if reminder:
    sys.stderr.write(f"[env] {reminder}\n")
    sys.stderr.flush()
PYEOF
