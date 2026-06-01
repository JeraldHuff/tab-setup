#!/bin/bash
# Auto-assigns a color and name to a Claude Code session at startup.
# Intended to run as a Claude Code SessionStart hook.
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
# Note: CLAUDE_SESSION_ID is empty in SessionStart hooks (Claude Code limitation).
# This script discovers the session by matching /dev/tty against live session files.
#
# Tune the inject delay if /color fires before Claude's first prompt:
#   TAB_SETUP_INJECT_DELAY=6 bash hook-startup.sh

TRACKING_FILE="${HOME}/.claude/tab-colors.json"
SESSIONS_DIR="${HOME}/.claude/sessions"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INJECT_DELAY="${TAB_SETUP_INJECT_DELAY:-4}"

[[ ! -f "$TRACKING_FILE" ]] && echo '{}' > "$TRACKING_FILE"

python3 - "$TRACKING_FILE" "$SESSIONS_DIR" "$SCRIPTS_DIR" "$INJECT_DELAY" <<'PYEOF'
import glob, json, os, subprocess, sys, time

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

tracking_file, sessions_dir, scripts_dir, inject_delay = sys.argv[1:]
inject_delay = int(inject_delay)


def get_tty():
    # /dev/tty = controlling terminal; accessible even when stdio is redirected
    try:
        fd = os.open("/dev/tty", os.O_RDONLY | os.O_NOCTTY)
        try:
            return os.ttyname(fd)
        finally:
            os.close(fd)
    except OSError:
        pass
    for fd in [0, 1, 2]:
        try:
            if os.isatty(fd):
                return os.ttyname(fd)
        except OSError:
            pass
    # Last resort: walk the process tree for an ancestor with a TTY
    try:
        pid = os.getpid()
        for _ in range(6):
            r = subprocess.run(["ps", "-o", "ppid=,tty=", "-p", str(pid)],
                               capture_output=True, text=True, timeout=2)
            if r.returncode != 0:
                break
            parts = r.stdout.strip().split(None, 1)
            if len(parts) < 2:
                break
            ppid, tty = int(parts[0]), parts[1].strip()
            if tty and tty != "??":
                return f"/dev/{tty}"
            pid = ppid
    except Exception:
        pass
    return None


def find_session_by_tty(tty_dev, retries=10, delay=0.3):
    tty_short = tty_dev.replace("/dev/", "")
    for _ in range(retries):
        for f in glob.glob(os.path.join(sessions_dir, "*.json")):
            try:
                data = json.load(open(f))
                pid = data.get("pid")
                if not pid:
                    continue
                os.kill(pid, 0)
                r = subprocess.run(["ps", "-o", "tty=", "-p", str(pid)],
                                   capture_output=True, text=True, timeout=2)
                if r.returncode == 0 and r.stdout.strip() == tty_short:
                    return pid, data.get("sessionId", ""), data.get("cwd", "")
            except Exception:
                continue
        time.sleep(delay)
    return None, None, None


tty_dev = get_tty()
if not tty_dev:
    sys.exit(0)

claude_pid, session_id, cwd = find_session_by_tty(tty_dev)
if not claude_pid:
    sys.exit(0)

project_name = os.path.basename(cwd.rstrip("/")) or "claude"

try:
    tracking = json.load(open(tracking_file))
except Exception:
    tracking = {}

# Prune dead sessions; skip _last cursor and malformed entries
live, used_colors = {}, set()
for sid, entry in tracking.items():
    if sid == session_id or sid == "_last" or not isinstance(entry, dict):
        continue
    try:
        os.kill(entry.get("pid", 0), 0)
        live[sid] = entry
        used_colors.add(entry.get("color", ""))
    except Exception:
        pass

# Rotate from last used color
last_color = tracking.get(session_id, {}).get("color") or tracking.get("_last", "")
try:
    start = (SEQUENCE.index(last_color) + 1) % len(SEQUENCE)
except ValueError:
    start = 0
chosen = next(
    (SEQUENCE[(start + i) % len(SEQUENCE)] for i in range(len(SEQUENCE))
     if SEQUENCE[(start + i) % len(SEQUENCE)] not in used_colors),
    SEQUENCE[start]
)

# Avoid name collision: suffix color only when another live session already holds this name
existing_names = {e.get("name", "") for e in live.values()}
name = f"{project_name} ({chosen})" if project_name in existing_names else project_name

live[session_id] = {"color": chosen, "pid": claude_pid, "cwd": cwd, "name": name}
live["_last"] = chosen
with open(tracking_file, "w") as f:
    json.dump(live, f, indent=2)

# Transcript writes — universal, guarded by file existence
project_hash = cwd.replace("/", "-")
transcript = os.path.expanduser(f"~/.claude/projects/{project_hash}/{session_id}.jsonl")
if os.path.exists(transcript):
    with open(transcript, "a") as f:
        f.write(json.dumps({"type": "agent-color",  "agentColor":  chosen, "sessionId": session_id}) + "\n")
        f.write(json.dumps({"type": "custom-title", "customTitle": name,   "sessionId": session_id}) + "\n")
        f.write(json.dumps({"type": "agent-name",   "agentName":   name,   "sessionId": session_id}) + "\n")

r, g, b = COLORS[chosen]
in_iterm2 = os.environ.get("TERM_PROGRAM") == "iTerm.app"
in_vscode = bool(os.environ.get("VSCODE_IPC_HOOK_CLI"))

if in_iterm2:
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
              tell s to write text "/color " & tabColor
              delay 0.3
              tell s to write text "/rename " & tabName
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

# Watcher cleans up tracking file when the Claude process exits
watcher_sh = os.path.join(scripts_dir, "watcher.sh")
if os.path.exists(watcher_sh):
    subprocess.Popen(
        ["bash", watcher_sh, str(claude_pid), session_id],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

print(f"color={chosen} name={name}", flush=True)
PYEOF
