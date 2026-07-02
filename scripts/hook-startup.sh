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
# Optional: set ANTHROPIC_API_KEY in the env block of settings.json for
# Haiku-generated session names (falls back to deterministic wordlist hash).
#
# Only acts on SessionStart source=startup|resume. On source=compact|clear it
# exits early, since injecting /color + /rename into the live prompt mid-compact
# interrupts the compaction.
#
# Note: CLAUDE_SESSION_ID is empty in SessionStart hooks (Claude Code limitation).
# Session discovery walks the PPID chain to find the parent Claude process,
# then matches its PID against session JSON files — no TTY access required.
#
# Tune the inject delay if /color fires before Claude's first prompt:
#   TAB_SETUP_INJECT_DELAY=6 bash hook-startup.sh

# SessionStart fires on several sources: startup, resume, clear, and compact.
# Only startup/resume should trigger color+name injection. On compact (and
# clear), Claude Code is mid-operation and the injected /color + /rename lines
# are submitted into the live prompt via `write text` — which interrupts the
# compaction. Read the hook payload from stdin and bail on anything but
# startup/resume. (Missing/unparseable source falls through to normal behavior
# so a payload-format change never silently disables the hook.)
HOOK_INPUT="$(cat 2>/dev/null || true)"
if [[ -n "$HOOK_INPUT" ]]; then
  SOURCE="$(printf '%s' "$HOOK_INPUT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("source",""))
except Exception: pass' 2>/dev/null)"
  case "$SOURCE" in
    compact|clear)
      exit 0
      ;;
  esac
fi

TRACKING_FILE="${HOME}/.claude/tab-colors.json"
SESSIONS_DIR="${HOME}/.claude/sessions"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INJECT_DELAY="${TAB_SETUP_INJECT_DELAY:-4}"

[[ ! -f "$TRACKING_FILE" ]] && echo '{}' > "$TRACKING_FILE"

python3 - "$TRACKING_FILE" "$SESSIONS_DIR" "$SCRIPTS_DIR" "$INJECT_DELAY" <<'PYEOF'
import glob, hashlib, json, os, re, subprocess, sys, time

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

ADJECTIVES = [
    "amber", "arctic", "blazing", "cobalt", "dappled", "drifting", "ember",
    "emerald", "feral", "gilded", "glacial", "glowing", "hollow", "indigo",
    "jade", "liminal", "lunar", "mellow", "misty", "mossy", "nested", "oblique",
    "onyx", "orbital", "pale", "phantom", "radiant", "rugged", "serene", "shaded",
    "silent", "sinuous", "solar", "spectral", "spiral", "stellar", "tidal",
    "translucent", "twilight", "verdant",
]

NOUNS = [
    "anchor", "apex", "basin", "beacon", "canopy", "cascade", "circuit", "cliff",
    "conduit", "crater", "delta", "drift", "ember", "fjord", "fractal", "glacier",
    "glyph", "grove", "harbor", "horizon", "inlet", "lattice", "ledge", "lotus",
    "mesa", "mirror", "nexus", "orbit", "outcrop", "peak", "prism", "pulse",
    "ridge", "reef", "signal", "slate", "summit", "tide", "vale", "veil",
]

tracking_file, sessions_dir, scripts_dir, inject_delay = sys.argv[1:]
inject_delay = int(inject_delay)


def find_session_by_ppid(retries=10, delay=0.3):
    """Walk PPID chain to find the Claude process, match to session JSON."""
    ancestor_pids = set()
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
            ancestor_pids.add(ppid)
            pid = ppid
        except Exception:
            break

    for _ in range(retries):
        for f in glob.glob(os.path.join(sessions_dir, "*.json")):
            try:
                data = json.load(open(f))
                session_pid = data.get("pid")
                if not session_pid:
                    continue
                os.kill(session_pid, 0)  # confirm alive
                if session_pid in ancestor_pids:
                    return session_pid, data.get("sessionId", ""), data.get("cwd", "")
            except Exception:
                continue
        time.sleep(delay)
    return None, None, None


def generate_name_via_api(project_name, api_key):
    """Call claude-haiku for a logical adjective-noun session name."""
    payload = {
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 20,
        "messages": [{"role": "user", "content":
            f"Generate a memorable 2-word adjective-noun name for a coding session "
            f"in project '{project_name}'. Reply ONLY with lowercase-hyphenated format "
            f"e.g. 'fiscal-ledger'. No explanation."}],
    }
    try:
        r = subprocess.run(
            ["curl", "-s", "-f", "https://api.anthropic.com/v1/messages",
             "-H", f"x-api-key: {api_key}",
             "-H", "anthropic-version: 2023-06-01",
             "-H", "content-type: application/json",
             "-d", json.dumps(payload), "--max-time", "5"],
            capture_output=True, text=True, timeout=8,
        )
        if r.returncode == 0:
            text = json.loads(r.stdout)["content"][0]["text"].strip().lower()
            if re.match(r"^[a-z]+-[a-z]+$", text):
                return text
    except Exception:
        pass
    return None


def generate_name_via_wordlist(project_name):
    """Deterministic adjective-noun from wordlists, keyed by project name."""
    h = int(hashlib.md5(project_name.encode()).hexdigest(), 16)
    return f"{ADJECTIVES[h % len(ADJECTIVES)]}-{NOUNS[(h >> 16) % len(NOUNS)]}"


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

# ---------------------------------------------------------------------------
# Session naming — Haiku API → wordlist fallback
# ---------------------------------------------------------------------------

api_key = os.environ.get("ANTHROPIC_API_KEY", "")
session_name = generate_name_via_api(project_name, api_key) if api_key else None
if not session_name:
    session_name = generate_name_via_wordlist(project_name)

# Official Claude Code hook output — sets the session title in the UI
print(json.dumps({"sessionTitle": session_name}), flush=True)

# Write session name into the session JSON if not already set.
for f in glob.glob(os.path.join(sessions_dir, "*.json")):
    try:
        data = json.load(open(f))
        if data.get("sessionId") != session_id:
            continue
        if not data.get("name"):
            data["name"] = session_name
            with open(f, "w") as wf:
                json.dump(data, wf)
        break
    except Exception:
        pass

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

    ascript_path = os.path.expanduser("~/.claude/tab-setup-hook.applescript")
    with open(ascript_path, "w") as f:
        f.write(f"""on run argv
  set ttyDevice to item 1 of argv
  set tabName to item 2 of argv
  set tabColor to item 3 of argv
  delay {inject_delay}
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
              -- into "/color"/"/rename", corrupting both. (These are Claude
              -- Code's own readline bindings, so they behave identically across
              -- terminals.)
              tell s to write text ((character id 5) & (character id 21) & "/color " & tabColor)
              delay 0.3
              tell s to write text ((character id 5) & (character id 21) & "/rename " & tabName)
              return
            end if
          end repeat
        end repeat
      end repeat
    end tell
  end try
end run
""")
    subprocess.Popen(
        ["nohup", "osascript", ascript_path, tty_dev, name, chosen],
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
