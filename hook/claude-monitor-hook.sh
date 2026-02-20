#!/usr/bin/env bash
# Claude Session Monitor Hook
# Configured in ~/.claude/settings.json

set -uo pipefail

BACKEND_URL="${CLAUDE_MONITOR_URL:-http://localhost:9147}"
HOOK_TYPE="${CLAUDE_HOOK_TYPE:-unknown}"

# Resolve binary paths relative to this script's location (works after install)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BACKEND_BIN="${CLAUDE_MONITOR_BACKEND_BIN:-$PROJECT_ROOT/backend/target/release/claude-monitor}"
OVERLAY_BIN="${CLAUDE_MONITOR_OVERLAY_BIN:-$PROJECT_ROOT/overlay/.build/release/ClaudeMonitor}"

# Auto-start backend and overlay if not already running
ensure_services_running() {
  if ! lsof -i :9147 -sTCP:LISTEN -t >/dev/null 2>&1; then
    if [ -x "$BACKEND_BIN" ]; then
      nohup "$BACKEND_BIN" >> /tmp/claude-monitor-backend.log 2>&1 &
      sleep 0.3
    fi
  fi

  if ! pgrep -xq "ClaudeMonitor" 2>/dev/null; then
    if [ -x "$OVERLAY_BIN" ]; then
      nohup "$OVERLAY_BIN" >> /tmp/claude-monitor-overlay.log 2>&1 &
    fi
  fi
}

ensure_services_running

# Read stdin (Claude provides JSON event data)
INPUT=$(cat)

# Extract fields from the JSON input
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || echo "")
CWD=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || echo "")
TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null || echo "")
TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('transcript_path',''))" 2>/dev/null || echo "")
MESSAGE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null || echo "")
NOTIFICATION_TYPE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('notification_type',''))" 2>/dev/null || echo "")

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

PROJECT_NAME=$(basename "${CWD:-unknown}")

build_payload() {
  local event_type="$1"
  local needs_input="${2:-false}"
  local agent_name="${3:-main}"
  local parent_session_id="${4:-}"

  python3 -c "
import json, sys
payload = {
    'event_type': '$event_type',
    'session_id': '$SESSION_ID',
    'project_path': '$CWD',
    'project_name': '$PROJECT_NAME',
    'agent_name': '$agent_name',
    'parent_session_id': '$parent_session_id' if '$parent_session_id' else None,
    'needs_input': '$needs_input' == 'true',
    'tool_name': '$TOOL_NAME' if '$TOOL_NAME' else None,
    'transcript_path': '$TRANSCRIPT_PATH' if '$TRANSCRIPT_PATH' else None,
    'message': '$MESSAGE' if '$MESSAGE' else None,
}
print(json.dumps(payload))
"
}

send_event() {
  local payload="$1"
  curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    --max-time 2 \
    "${BACKEND_URL}/api/events" \
    > /dev/null 2>&1 &
}

case "$HOOK_TYPE" in
  SessionStart)
    # Register session as active when it starts/resumes
    PAYLOAD=$(build_payload "session_start" "false" "main" "")
    send_event "$PAYLOAD"
    ;;
  SessionEnd)
    # Mark session completed so it's removed from the overlay
    PAYLOAD=$(build_payload "session_end" "false" "main" "")
    send_event "$PAYLOAD"
    ;;
  UserPromptSubmit)
    # User submitted a new prompt — set session back to active immediately
    PAYLOAD=$(build_payload "user_prompt" "false" "main" "")
    send_event "$PAYLOAD"
    ;;
  Stop)
    # Claude finished a turn — mark idle (stays visible, awaiting next prompt)
    PAYLOAD=$(build_payload "stop" "false" "main" "")
    send_event "$PAYLOAD"
    ;;
  Notification)
    # permission_prompt notification type = needs permission; idle_prompt = waiting for input
    if [ "$NOTIFICATION_TYPE" = "permission_prompt" ] || \
       echo "$MESSAGE" | grep -qiE "(permission|approve|allow|confirm|unsafe|dangerous|trust|grant)"; then
      PAYLOAD=$(build_payload "needs_permission" "true" "main" "")
    else
      PAYLOAD=$(build_payload "notification" "true" "main" "")
    fi
    send_event "$PAYLOAD"
    ;;
  SubagentStart)
    # A subagent was spawned
    PAYLOAD=$(build_payload "subagent_start" "false" "subagent" "$SESSION_ID")
    send_event "$PAYLOAD"
    ;;
  SubagentStop)
    # A subagent finished
    PAYLOAD=$(build_payload "subagent_stop" "false" "subagent" "$SESSION_ID")
    send_event "$PAYLOAD"
    ;;
  PostToolUse)
    if [ "$TOOL_NAME" = "Task" ]; then
      # Fallback subagent tracking via PostToolUse (SubagentStart covers this now)
      PAYLOAD=$(build_payload "task_started" "false" "subagent" "$SESSION_ID")
      send_event "$PAYLOAD"
    fi
    ;;
  PreToolUse)
    PAYLOAD=$(build_payload "tool_use" "false" "main" "")
    send_event "$PAYLOAD"
    ;;
  *)
    exit 0
    ;;
esac

exit 0
