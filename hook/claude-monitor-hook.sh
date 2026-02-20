#!/usr/bin/env bash
# Claude Session Monitor Hook — file-based IPC
# Writes JSON session files to ~/.claude/monitor/sessions/
# Configured in ~/.claude/settings.json

set -uo pipefail

SESSIONS_DIR="$HOME/.claude/monitor/sessions"
mkdir -p "$SESSIONS_DIR"

# Resolve binary paths relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OVERLAY_BIN="${CLAUDE_MONITOR_OVERLAY_BIN:-$PROJECT_ROOT/overlay/.build/release/ClaudeMonitor}"

# Auto-start overlay if not running
if ! pgrep -xq "ClaudeMonitor" 2>/dev/null; then
  if [ -x "$OVERLAY_BIN" ]; then
    nohup "$OVERLAY_BIN" >> /tmp/claude-monitor-overlay.log 2>&1 &
  fi
fi

# Capture the TTY of the parent process (Claude's shell)
CLAUDE_TTY=""
_claude_pid=$(ps -p $$ -o ppid= 2>/dev/null | tr -d ' ')
if [ -n "$_claude_pid" ]; then
  CLAUDE_TTY=$(ps -p "$_claude_pid" -o tty= 2>/dev/null | tr -d ' ')
  [ "$CLAUDE_TTY" = "??" ] && CLAUDE_TTY=""
fi

# Read stdin and pipe to python3.
# hook_event_name comes from the JSON stdin (Claude provides it).
# CLAUDE_HOOK_TYPE env var is fallback only.
cat | FALLBACK_HOOK_TYPE="${CLAUDE_HOOK_TYPE:-}" SESSIONS_DIR="$SESSIONS_DIR" CLAUDE_TTY="$CLAUDE_TTY" python3 -c '
import json, sys, os, time, tempfile, fcntl

sessions_dir = os.environ["SESSIONS_DIR"]
fallback_hook_type = os.environ.get("FALLBACK_HOOK_TYPE", "")

try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)

session_id = data.get("session_id", "")
if not session_id:
    sys.exit(0)

# Reject path traversal
if "/" in session_id or "\\" in session_id or session_id.startswith("."):
    sys.exit(0)

# Use hook_event_name from JSON (preferred), fall back to env var
hook_type = data.get("hook_event_name", "") or fallback_hook_type
if not hook_type:
    sys.exit(0)

# SessionEnd: delete the session file and exit
if hook_type == "SessionEnd":
    path = os.path.join(sessions_dir, session_id + ".json")
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    sys.exit(0)

# Detect permission from Notification messages
is_permission = False
if hook_type == "Notification":
    notification_type = data.get("notification_type", "")
    message = data.get("message", "")
    if notification_type == "permission_prompt":
        is_permission = True
    elif message:
        keywords = ("permission", "approve", "allow", "confirm", "unsafe", "dangerous", "trust", "grant")
        if any(kw in message.lower() for kw in keywords):
            is_permission = True

# File-level lock to prevent concurrent hooks from losing accumulated state
session_path = os.path.join(sessions_dir, session_id + ".json")
lock_path = session_path + ".lock"
lock_fd = open(lock_path, "w")
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    # Read existing session file to preserve accumulated state (agents list)
    existing = {}
    try:
        with open(session_path, "r") as f:
            existing = json.load(f)
    except Exception:
        pass

    # Accumulate agents: preserve across event overwrites
    agents = existing.get("agents", {})
    agent_id = data.get("agent_id", "") or data.get("agent_name", "")
    if hook_type == "SubagentStart" and agent_id:
        agents[agent_id] = {
            "agent_id": agent_id,
            "agent_name": data.get("agent_name", ""),
            "agent_type": data.get("agent_type", ""),
            "status": "active",
            "started_at": time.time(),
        }
    elif hook_type == "SubagentStop" and agent_id and agent_id in agents:
        agents[agent_id]["status"] = "completed"
        agents[agent_id]["stopped_at"] = time.time()

    event = {
        "session_id": session_id,
        "hook_event_name": hook_type,
        "timestamp": time.time(),
        "cwd": existing.get("cwd", "") or data.get("cwd", ""),
        "notification_type": data.get("notification_type", ""),
        "message": data.get("message", ""),
        "tool_name": data.get("tool_name", ""),
        "tool_input": data.get("tool_input", ""),
        "agent_name": data.get("agent_name", ""),
        "agent_id": data.get("agent_id", ""),
        "agent_type": data.get("agent_type", ""),
        "transcript_path": data.get("transcript_path", "") or existing.get("transcript_path", ""),
        "user_prompt": data.get("user_prompt", "") or existing.get("user_prompt", ""),
        "reason": data.get("reason", ""),
        "is_permission": is_permission,
        "is_interrupt": data.get("is_interrupt", False),
        "tty": os.environ.get("CLAUDE_TTY", "") or existing.get("tty", ""),
        "agents": agents,
    }

    # Atomic write: unique temp file then rename
    fd, tmp_path = tempfile.mkstemp(dir=sessions_dir, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(event, f)
        os.rename(tmp_path, session_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
'

exit 0
