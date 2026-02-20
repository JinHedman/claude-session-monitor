#!/usr/bin/env bash
# Automated tests for claude-session-monitor
# Covers: hook script, agent lifecycle, state machine, tab index resolution,
#         field persistence, race conditions, edge cases.
# Usage: bash test/test-hooks.sh
# Exits 0 on all pass, 1 on any failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

TEST_SESSIONS_DIR="$(mktemp -d)"
HOOK_PY="$(mktemp)"
TAB_INDEX_PY="$(mktemp)"
trap 'rm -rf "$TEST_SESSIONS_DIR" "$HOOK_PY" "$TAB_INDEX_PY"' EXIT

PASS=0
FAIL=0
TOTAL_SECTIONS=0

pass() {
  PASS=$((PASS + 1))
  printf '  \033[32m✓\033[0m %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  \033[31m✗\033[0m %s — %s\n' "$1" "${2:-}"
}

section() {
  TOTAL_SECTIONS=$((TOTAL_SECTIONS + 1))
  echo ""
  printf '\033[1;34m━━ %s\033[0m\n' "$1"
}

# ─── Write the hook python logic to a temp file ─────────────────────
# This is a faithful copy of the python block in claude-monitor-hook.sh,
# minus the fcntl locking (not needed in single-threaded tests).
cat > "$HOOK_PY" << 'PYEOF'
import json, sys, os, time, tempfile

sessions_dir = os.environ["SESSIONS_DIR"]
fallback_hook_type = os.environ.get("FALLBACK_HOOK_TYPE", "")

try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)

session_id = data.get("session_id", "")
if not session_id:
    sys.exit(0)

if "/" in session_id or "\\" in session_id or session_id.startswith("."):
    sys.exit(0)

hook_type = data.get("hook_event_name", "") or fallback_hook_type
if not hook_type:
    sys.exit(0)

if hook_type == "SessionEnd":
    path = os.path.join(sessions_dir, session_id + ".json")
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    sys.exit(0)

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

session_path = os.path.join(sessions_dir, session_id + ".json")
existing = {}
try:
    with open(session_path, "r") as f:
        existing = json.load(f)
except Exception:
    pass

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
PYEOF

# ─── Write the Ghostty tab-index python (extracted from TerminalFocus.swift) ──
cat > "$TAB_INDEX_PY" << 'PYEOF'
import sys, subprocess, os

# In test mode, read mock ps output from env var instead of running ps
mock_ps = os.environ.get("MOCK_PS_OUTPUT", "")
ghostty_pid = int(sys.argv[1])
target_tty = sys.argv[2]

if mock_ps:
    lines = mock_ps.strip().split("\n")
else:
    ps = subprocess.run(['ps', '-eo', 'pid,ppid,tty'], capture_output=True, text=True)
    lines = ps.stdout.strip().split("\n")

direct = []
for line in lines[1:]:
    parts = line.split()
    if len(parts) >= 3:
        pid, ppid, tty = int(parts[0]), int(parts[1]), parts[2]
        if ppid == ghostty_pid and tty not in ('??', 'TTY'):
            direct.append((pid, tty))
direct.sort()
ttys = [t for _, t in direct]
if target_tty in ttys:
    print(ttys.index(target_tty) + 1)
else:
    sys.exit(1)
PYEOF

# ─── Helpers ────────────────────────────────────────────────────────

run_hook() {
  # Second arg = TTY. Default "ttys042" if omitted, but "" means genuinely empty.
  local tty_val
  if [ $# -ge 2 ]; then tty_val="$2"; else tty_val="ttys042"; fi
  echo "$1" | SESSIONS_DIR="$TEST_SESSIONS_DIR" CLAUDE_TTY="$tty_val" FALLBACK_HOOK_TYPE="" python3 "$HOOK_PY"
}

read_field() {
  python3 -c "
import json, sys
with open('$TEST_SESSIONS_DIR/$1.json') as f:
    d = json.load(f)
v = d.get('$2', '')
# Print booleans as Python-style
if isinstance(v, bool):
    print('True' if v else 'False')
else:
    print(v)
" 2>/dev/null
}

read_nested() {
  # read_nested <session_id> <key1> <key2> ...
  local session_id="$1"; shift
  local py_keys=""
  for k in "$@"; do py_keys="$py_keys['$k']"; done
  python3 -c "
import json
with open('$TEST_SESSIONS_DIR/$session_id.json') as f:
    d = json.load(f)
v = d$py_keys
if isinstance(v, bool):
    print('True' if v else 'False')
else:
    print(v)
" 2>/dev/null
}

read_agent_field() {
  python3 -c "
import json
with open('$TEST_SESSIONS_DIR/$1.json') as f:
    d = json.load(f)
print(d.get('agents', {}).get('$2', {}).get('$3', ''))
" 2>/dev/null
}

read_agent_count() {
  python3 -c "
import json
with open('$TEST_SESSIONS_DIR/$1.json') as f:
    d = json.load(f)
print(len(d.get('agents', {})))
" 2>/dev/null
}

read_agent_ids() {
  python3 -c "
import json
with open('$TEST_SESSIONS_DIR/$1.json') as f:
    d = json.load(f)
print(' '.join(sorted(d.get('agents', {}).keys())))
" 2>/dev/null
}

active_agent_count() {
  python3 -c "
import json
with open('$TEST_SESSIONS_DIR/$1.json') as f:
    d = json.load(f)
print(sum(1 for a in d.get('agents', {}).values() if a.get('status') == 'active'))
" 2>/dev/null
}

completed_agent_count() {
  python3 -c "
import json
with open('$TEST_SESSIONS_DIR/$1.json') as f:
    d = json.load(f)
print(sum(1 for a in d.get('agents', {}).values() if a.get('status') == 'completed'))
" 2>/dev/null
}

check_field() {
  local actual
  actual=$(read_field "$1" "$2")
  if [ "$actual" = "$3" ]; then
    pass "$4"
  else
    fail "$4" "expected '$3', got '$actual'"
  fi
}

file_exists() {
  [ -f "$TEST_SESSIONS_DIR/$1.json" ]
}

file_count() {
  ls "$TEST_SESSIONS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' '
}

run_tab_index() {
  # run_tab_index <ghostty_pid> <target_tty> <mock_ps_output>
  MOCK_PS_OUTPUT="$3" python3 "$TAB_INDEX_PY" "$1" "$2" 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════
echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║   Claude Session Monitor — Test Suite         ║"
echo "╚═══════════════════════════════════════════════╝"

# ════════════════════════════════════════════════════════════════════
# SECTION 1: Basic Hook Events
# ════════════════════════════════════════════════════════════════════

section "1. Basic Hook Events"

# SessionStart
run_hook '{"session_id":"s1","hook_event_name":"SessionStart","cwd":"/Users/test/myproject","transcript_path":"/tmp/s1.jsonl"}'
if file_exists "s1"; then
  pass "SessionStart creates file"
  check_field "s1" "hook_event_name" "SessionStart" "hook_event_name correct"
  check_field "s1" "tty" "ttys042" "TTY captured from env"
  check_field "s1" "cwd" "/Users/test/myproject" "CWD captured"
  check_field "s1" "transcript_path" "/tmp/s1.jsonl" "transcript_path captured"
else
  fail "SessionStart creates file"
fi

# UserPromptSubmit
run_hook '{"session_id":"s1","hook_event_name":"UserPromptSubmit","user_prompt":"Fix the login bug"}'
check_field "s1" "hook_event_name" "UserPromptSubmit" "UserPromptSubmit event"
check_field "s1" "user_prompt" "Fix the login bug" "user_prompt captured"

# PreToolUse
run_hook '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash"}'
check_field "s1" "hook_event_name" "PreToolUse" "PreToolUse event"
check_field "s1" "tool_name" "Bash" "tool_name captured"

# PostToolUse
run_hook '{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/test.txt"}}'
check_field "s1" "hook_event_name" "PostToolUse" "PostToolUse event"

# Notification (permission)
run_hook '{"session_id":"s1","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow Bash?"}'
check_field "s1" "is_permission" "True" "permission_prompt → is_permission=True"

# Notification (keyword-based permission detection)
run_hook '{"session_id":"s1","hook_event_name":"Notification","notification_type":"","message":"Please approve this dangerous action"}'
check_field "s1" "is_permission" "True" "keyword 'approve'+'dangerous' → is_permission=True"

# Notification (non-permission)
run_hook '{"session_id":"s1","hook_event_name":"Notification","notification_type":"info","message":"Build completed successfully"}'
check_field "s1" "is_permission" "False" "info notification → is_permission=False"

# Stop
run_hook '{"session_id":"s1","hook_event_name":"Stop","reason":"assistant_turn_complete"}'
check_field "s1" "hook_event_name" "Stop" "Stop event"
check_field "s1" "reason" "assistant_turn_complete" "reason captured"

# PostToolUseFailure with interrupt
run_hook '{"session_id":"s1","hook_event_name":"PostToolUseFailure","tool_name":"Bash","is_interrupt":true}'
check_field "s1" "hook_event_name" "PostToolUseFailure" "PostToolUseFailure event"
check_field "s1" "is_interrupt" "True" "is_interrupt=True"

# PostToolUseFailure without interrupt
run_hook '{"session_id":"s1","hook_event_name":"PostToolUseFailure","tool_name":"Bash","is_interrupt":false}'
check_field "s1" "is_interrupt" "False" "is_interrupt=False when not interrupted"

# SessionEnd
run_hook '{"session_id":"s1","hook_event_name":"SessionEnd"}'
if ! file_exists "s1"; then
  pass "SessionEnd deletes file"
else
  fail "SessionEnd deletes file" "file still exists"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 2: Field Persistence (CWD, TTY, transcript, user_prompt)
# ════════════════════════════════════════════════════════════════════

section "2. Field Persistence Across Events"

# Start session with all fields
run_hook '{"session_id":"s2","hook_event_name":"SessionStart","cwd":"/Users/test/project-alpha","transcript_path":"/tmp/s2.jsonl","user_prompt":"","tty":""}' "ttys005"

# CWD must not be overwritten by later events (first CWD sticks)
run_hook '{"session_id":"s2","hook_event_name":"PostToolUse","cwd":"/Users/test/project-alpha/overlay","tool_name":"Bash"}' "ttys005"
check_field "s2" "cwd" "/Users/test/project-alpha" "CWD preserved (first sticks, subdirectory ignored)"

# Even completely different CWDs don't overwrite
run_hook '{"session_id":"s2","hook_event_name":"PostToolUse","cwd":"/tmp/build","tool_name":"Bash"}' "ttys005"
check_field "s2" "cwd" "/Users/test/project-alpha" "CWD preserved (unrelated path ignored)"

# Empty CWD doesn't clear existing
run_hook '{"session_id":"s2","hook_event_name":"PostToolUse","cwd":"","tool_name":"Read"}' "ttys005"
check_field "s2" "cwd" "/Users/test/project-alpha" "CWD preserved (empty doesn't clear)"

# transcript_path persists
run_hook '{"session_id":"s2","hook_event_name":"PostToolUse","transcript_path":"","tool_name":"Bash"}' "ttys005"
check_field "s2" "transcript_path" "/tmp/s2.jsonl" "transcript_path preserved (empty doesn't clear)"

# user_prompt: hook uses "latest non-empty wins" (overlay does "first wins" in memory)
run_hook '{"session_id":"s2","hook_event_name":"UserPromptSubmit","user_prompt":"First prompt"}' "ttys005"
check_field "s2" "user_prompt" "First prompt" "user_prompt set on first non-empty"
run_hook '{"session_id":"s2","hook_event_name":"UserPromptSubmit","user_prompt":"Second prompt"}' "ttys005"
check_field "s2" "user_prompt" "Second prompt" "user_prompt: latest non-empty wins in JSON"

# user_prompt: empty doesn't clear existing
run_hook '{"session_id":"s2","hook_event_name":"PostToolUse","user_prompt":"","tool_name":"Bash"}' "ttys005"
check_field "s2" "user_prompt" "Second prompt" "user_prompt preserved when new is empty"

# TTY: hook uses "latest non-empty env wins" (in practice same terminal = same TTY)
# Using same TTY throughout to match real behavior
check_field "s2" "tty" "ttys005" "TTY set from env"

# TTY: empty env falls back to existing
run_hook '{"session_id":"s2","hook_event_name":"PostToolUse","tool_name":"Bash"}' ""
check_field "s2" "tty" "ttys005" "TTY preserved when env is empty"

# Cleanup
run_hook '{"session_id":"s2","hook_event_name":"SessionEnd"}'

# ════════════════════════════════════════════════════════════════════
# SECTION 3: Agent Lifecycle (start, accumulate, stop, teardown)
# ════════════════════════════════════════════════════════════════════

section "3. Agent Lifecycle"

run_hook '{"session_id":"s3","hook_event_name":"SessionStart","cwd":"/tmp/agenttest"}'

# Start first agent (Explore)
run_hook '{"session_id":"s3","hook_event_name":"SubagentStart","agent_id":"a001","agent_name":"","agent_type":"Explore"}'
actual=$(read_agent_count "s3")
if [ "$actual" = "1" ]; then pass "1 agent after first SubagentStart"; else fail "1 agent after first SubagentStart" "got $actual"; fi
check_field "s3" "agent_id" "a001" "agent_id on event level"
actual=$(read_agent_field "s3" "a001" "status")
if [ "$actual" = "active" ]; then pass "agent a001 status=active"; else fail "agent a001 status=active" "got '$actual'"; fi
actual=$(read_agent_field "s3" "a001" "agent_type")
if [ "$actual" = "Explore" ]; then pass "agent a001 type=Explore"; else fail "agent a001 type=Explore" "got '$actual'"; fi

# Start second agent (Bash) — both should coexist
run_hook '{"session_id":"s3","hook_event_name":"SubagentStart","agent_id":"a002","agent_name":"","agent_type":"Bash"}'
actual=$(read_agent_count "s3")
if [ "$actual" = "2" ]; then pass "2 agents after second SubagentStart"; else fail "2 agents after second SubagentStart" "got $actual"; fi
actual=$(read_agent_field "s3" "a002" "agent_type")
if [ "$actual" = "Bash" ]; then pass "agent a002 type=Bash"; else fail "agent a002 type=Bash" "got '$actual'"; fi

# Agents persist through non-agent events
run_hook '{"session_id":"s3","hook_event_name":"PostToolUse","tool_name":"Read"}'
actual=$(read_agent_count "s3")
if [ "$actual" = "2" ]; then pass "agents persist through PostToolUse"; else fail "agents persist through PostToolUse" "got $actual"; fi

run_hook '{"session_id":"s3","hook_event_name":"UserPromptSubmit","user_prompt":"test"}'
actual=$(read_agent_count "s3")
if [ "$actual" = "2" ]; then pass "agents persist through UserPromptSubmit"; else fail "agents persist through UserPromptSubmit" "got $actual"; fi

run_hook '{"session_id":"s3","hook_event_name":"Notification","notification_type":"info","message":"hello"}'
actual=$(read_agent_count "s3")
if [ "$actual" = "2" ]; then pass "agents persist through Notification"; else fail "agents persist through Notification" "got $actual"; fi

run_hook '{"session_id":"s3","hook_event_name":"Stop","reason":"done"}'
actual=$(read_agent_count "s3")
if [ "$actual" = "2" ]; then pass "agents persist through Stop"; else fail "agents persist through Stop" "got $actual"; fi

# Stop first agent
run_hook '{"session_id":"s3","hook_event_name":"SubagentStop","agent_id":"a001","agent_type":"Explore"}'
actual=$(read_agent_field "s3" "a001" "status")
if [ "$actual" = "completed" ]; then pass "agent a001 status=completed after SubagentStop"; else fail "agent a001 status=completed" "got '$actual'"; fi
# Second agent still active
actual=$(read_agent_field "s3" "a002" "status")
if [ "$actual" = "active" ]; then pass "agent a002 still active"; else fail "agent a002 still active" "got '$actual'"; fi
# Total count still 2 (completed agents remain in JSON until overlay filters them)
actual=$(read_agent_count "s3")
if [ "$actual" = "2" ]; then pass "total agents=2 (completed stays in JSON)"; else fail "total agents=2" "got $actual"; fi

# Active vs completed counts
actual=$(active_agent_count "s3")
if [ "$actual" = "1" ]; then pass "1 active agent"; else fail "1 active agent" "got $actual"; fi
actual=$(completed_agent_count "s3")
if [ "$actual" = "1" ]; then pass "1 completed agent"; else fail "1 completed agent" "got $actual"; fi

# Stop second agent
run_hook '{"session_id":"s3","hook_event_name":"SubagentStop","agent_id":"a002","agent_type":"Bash"}'
actual=$(active_agent_count "s3")
if [ "$actual" = "0" ]; then pass "0 active agents after all stopped"; else fail "0 active agents" "got $actual"; fi
actual=$(completed_agent_count "s3")
if [ "$actual" = "2" ]; then pass "2 completed agents"; else fail "2 completed agents" "got $actual"; fi

# Start a third agent after others completed
run_hook '{"session_id":"s3","hook_event_name":"SubagentStart","agent_id":"a003","agent_name":"","agent_type":"researcher"}'
actual=$(read_agent_count "s3")
if [ "$actual" = "3" ]; then pass "3 total agents (2 completed + 1 new active)"; else fail "3 total agents" "got $actual"; fi
actual=$(active_agent_count "s3")
if [ "$actual" = "1" ]; then pass "1 active agent (new one)"; else fail "1 active agent" "got $actual"; fi

# Cleanup
run_hook '{"session_id":"s3","hook_event_name":"SessionEnd"}'

# ════════════════════════════════════════════════════════════════════
# SECTION 4: Agent Edge Cases
# ════════════════════════════════════════════════════════════════════

section "4. Agent Edge Cases"

run_hook '{"session_id":"s4","hook_event_name":"SessionStart","cwd":"/tmp/edgetest"}'

# SubagentStop for nonexistent agent (should not crash or create phantom agent)
run_hook '{"session_id":"s4","hook_event_name":"SubagentStop","agent_id":"ghost","agent_type":"Bash"}'
actual=$(read_agent_count "s4")
if [ "$actual" = "0" ]; then pass "SubagentStop for nonexistent agent: no phantom created"; else fail "no phantom agent" "got $actual agents"; fi

# Agent with agent_name fallback (when agent_id is empty)
run_hook '{"session_id":"s4","hook_event_name":"SubagentStart","agent_id":"","agent_name":"my-custom-agent","agent_type":"Explore"}'
actual=$(read_agent_count "s4")
if [ "$actual" = "1" ]; then pass "agent created with agent_name fallback key"; else fail "agent created with name fallback" "got $actual"; fi
actual=$(read_agent_field "s4" "my-custom-agent" "agent_type")
if [ "$actual" = "Explore" ]; then pass "fallback agent has correct type"; else fail "fallback agent type" "got '$actual'"; fi

# Duplicate SubagentStart (same agent_id) overwrites, doesn't duplicate
run_hook '{"session_id":"s4","hook_event_name":"SubagentStart","agent_id":"dup1","agent_name":"","agent_type":"Bash"}'
run_hook '{"session_id":"s4","hook_event_name":"SubagentStart","agent_id":"dup1","agent_name":"","agent_type":"researcher"}'
actual=$(read_agent_count "s4")
if [ "$actual" = "2" ]; then pass "duplicate agent_id doesn't create extra entry"; else fail "no duplicate entry" "got $actual agents"; fi
actual=$(read_agent_field "s4" "dup1" "agent_type")
if [ "$actual" = "researcher" ]; then pass "duplicate SubagentStart overwrites type"; else fail "overwrite agent type" "got '$actual'"; fi

# SubagentStart with both agent_id and agent_name (agent_id takes priority as key)
run_hook '{"session_id":"s4","hook_event_name":"SubagentStart","agent_id":"real-id","agent_name":"display-name","agent_type":"Bash"}'
actual=$(read_agent_field "s4" "real-id" "agent_name")
if [ "$actual" = "display-name" ]; then pass "agent_id is key, agent_name preserved in entry"; else fail "agent keying" "got '$actual'"; fi

# Cleanup
run_hook '{"session_id":"s4","hook_event_name":"SessionEnd"}'

# ════════════════════════════════════════════════════════════════════
# SECTION 5: Multiple Concurrent Sessions
# ════════════════════════════════════════════════════════════════════

section "5. Multiple Concurrent Sessions"

run_hook '{"session_id":"multi-a","hook_event_name":"SessionStart","cwd":"/Users/test/project-a","transcript_path":"/tmp/a.jsonl"}' "ttys000"
run_hook '{"session_id":"multi-b","hook_event_name":"SessionStart","cwd":"/Users/test/project-b","transcript_path":"/tmp/b.jsonl"}' "ttys001"
run_hook '{"session_id":"multi-c","hook_event_name":"SessionStart","cwd":"/Users/test/project-c","transcript_path":"/tmp/c.jsonl"}' "ttys002"

actual=$(file_count)
if [ "$actual" = "3" ]; then pass "3 concurrent session files"; else fail "3 session files" "got $actual"; fi

# Each has independent state
check_field "multi-a" "cwd" "/Users/test/project-a" "session A has correct CWD"
check_field "multi-b" "cwd" "/Users/test/project-b" "session B has correct CWD"
check_field "multi-c" "cwd" "/Users/test/project-c" "session C has correct CWD"
check_field "multi-a" "tty" "ttys000" "session A has correct TTY"
check_field "multi-b" "tty" "ttys001" "session B has correct TTY"
check_field "multi-c" "tty" "ttys002" "session C has correct TTY"

# Add agent to session A — should not affect B or C
run_hook '{"session_id":"multi-a","hook_event_name":"SubagentStart","agent_id":"a-agent","agent_type":"Explore"}' "ttys000"
actual_a=$(read_agent_count "multi-a")
actual_b=$(read_agent_count "multi-b")
actual_c=$(read_agent_count "multi-c")
if [ "$actual_a" = "1" ] && [ "$actual_b" = "0" ] && [ "$actual_c" = "0" ]; then
  pass "agent isolated to session A (A=1, B=0, C=0)"
else
  fail "agent isolation" "A=$actual_a, B=$actual_b, C=$actual_c"
fi

# End session B — A and C remain
run_hook '{"session_id":"multi-b","hook_event_name":"SessionEnd"}'
if ! file_exists "multi-b" && file_exists "multi-a" && file_exists "multi-c"; then
  pass "SessionEnd removes only target session"
else
  fail "selective session removal"
fi

# Cleanup
run_hook '{"session_id":"multi-a","hook_event_name":"SessionEnd"}'
run_hook '{"session_id":"multi-c","hook_event_name":"SessionEnd"}'

# ════════════════════════════════════════════════════════════════════
# SECTION 6: Full Session Lifecycle Simulation
# ════════════════════════════════════════════════════════════════════

section "6. Full Session Lifecycle"

# 1. Session starts
run_hook '{"session_id":"life","hook_event_name":"SessionStart","cwd":"/Users/test/big-project","transcript_path":"/tmp/life.jsonl"}'
check_field "life" "hook_event_name" "SessionStart" "lifecycle: session started"

# 2. User submits prompt
run_hook '{"session_id":"life","hook_event_name":"UserPromptSubmit","user_prompt":"Refactor the auth module"}'
check_field "life" "user_prompt" "Refactor the auth module" "lifecycle: prompt captured"

# 3. Claude uses tools
run_hook '{"session_id":"life","hook_event_name":"PreToolUse","tool_name":"Read"}'
run_hook '{"session_id":"life","hook_event_name":"PostToolUse","tool_name":"Read"}'
run_hook '{"session_id":"life","hook_event_name":"PreToolUse","tool_name":"Edit"}'
run_hook '{"session_id":"life","hook_event_name":"PostToolUse","tool_name":"Edit"}'
check_field "life" "hook_event_name" "PostToolUse" "lifecycle: tools used"

# 4. Claude spawns an Explore agent
run_hook '{"session_id":"life","hook_event_name":"SubagentStart","agent_id":"explore-1","agent_type":"Explore"}'
actual=$(active_agent_count "life")
if [ "$actual" = "1" ]; then pass "lifecycle: Explore agent active"; else fail "lifecycle: agent active" "got $actual"; fi

# 5. More tool use while agent runs
run_hook '{"session_id":"life","hook_event_name":"PostToolUse","tool_name":"Bash"}'
actual=$(active_agent_count "life")
if [ "$actual" = "1" ]; then pass "lifecycle: agent survives tool events"; else fail "lifecycle: agent survives" "got $actual"; fi

# 6. Agent completes
run_hook '{"session_id":"life","hook_event_name":"SubagentStop","agent_id":"explore-1","agent_type":"Explore"}'
actual=$(completed_agent_count "life")
if [ "$actual" = "1" ]; then pass "lifecycle: agent completed"; else fail "lifecycle: agent completed" "got $actual"; fi

# 7. Claude needs permission
run_hook '{"session_id":"life","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow rm?"}'
check_field "life" "is_permission" "True" "lifecycle: permission needed"

# 8. User grants, submits new prompt
run_hook '{"session_id":"life","hook_event_name":"UserPromptSubmit","user_prompt":"Yes, go ahead"}'
# Hook JSON has latest prompt; overlay's SessionStore preserves first in memory
check_field "life" "user_prompt" "Yes, go ahead" "lifecycle: latest prompt in JSON"

# 9. Claude finishes
run_hook '{"session_id":"life","hook_event_name":"Stop","reason":"assistant_turn_complete"}'

# 10. All fields still intact
check_field "life" "cwd" "/Users/test/big-project" "lifecycle: CWD intact at end"
check_field "life" "transcript_path" "/tmp/life.jsonl" "lifecycle: transcript intact at end"
check_field "life" "tty" "ttys042" "lifecycle: TTY intact at end"

# 11. Session ends
run_hook '{"session_id":"life","hook_event_name":"SessionEnd"}'
if ! file_exists "life"; then pass "lifecycle: session cleaned up"; else fail "lifecycle: session cleaned up"; fi

# ════════════════════════════════════════════════════════════════════
# SECTION 7: Ghostty Tab Index Resolution
# ════════════════════════════════════════════════════════════════════

section "7. Ghostty Tab Index Resolution"

# Mock ps output: Ghostty PID 100, three tabs with login processes as direct children
MOCK_3TABS="  PID  PPID TTY
  200   100 ttys000
  300   100 ttys001
  400   100 ttys002
  500   200 ttys000
  600   300 ttys001
  700   400 ttys002"

# Tab 1 = ttys000
actual=$(run_tab_index 100 "ttys000" "$MOCK_3TABS")
if [ "$actual" = "1" ]; then pass "ttys000 → tab 1"; else fail "ttys000 → tab 1" "got '$actual'"; fi

# Tab 2 = ttys001
actual=$(run_tab_index 100 "ttys001" "$MOCK_3TABS")
if [ "$actual" = "2" ]; then pass "ttys001 → tab 2"; else fail "ttys001 → tab 2" "got '$actual'"; fi

# Tab 3 = ttys002
actual=$(run_tab_index 100 "ttys002" "$MOCK_3TABS")
if [ "$actual" = "3" ]; then pass "ttys002 → tab 3"; else fail "ttys002 → tab 3" "got '$actual'"; fi

# Unknown TTY → exit 1 (no output)
actual=$(run_tab_index 100 "ttys999" "$MOCK_3TABS")
if [ -z "$actual" ]; then pass "unknown TTY → empty (exit 1)"; else fail "unknown TTY" "got '$actual'"; fi

# Descendant processes should NOT affect tab ordering
# Here PID 150 is a deep descendant (child of 200), NOT a direct child of Ghostty
MOCK_DESCENDANTS="  PID  PPID TTY
  200   100 ttys000
  300   100 ttys001
  150   200 ttys000
  350   300 ttys001
  99    300 ttys001"

actual=$(run_tab_index 100 "ttys000" "$MOCK_DESCENDANTS")
if [ "$actual" = "1" ]; then pass "descendants don't affect ordering (ttys000=tab1)"; else fail "descendants ordering" "got '$actual'"; fi
actual=$(run_tab_index 100 "ttys001" "$MOCK_DESCENDANTS")
if [ "$actual" = "2" ]; then pass "descendants don't affect ordering (ttys001=tab2)"; else fail "descendants ordering" "got '$actual'"; fi

# PID ordering is what matters for tab index, not TTY name
# Here PID 500 has ttys002 and PID 300 has ttys001 — sorted by PID, tab1=ttys001, tab2=ttys002
MOCK_PID_ORDER="  PID  PPID TTY
  500   100 ttys002
  300   100 ttys001"

actual=$(run_tab_index 100 "ttys001" "$MOCK_PID_ORDER")
if [ "$actual" = "1" ]; then pass "PID order determines tab index (lower PID=tab1)"; else fail "PID ordering" "got '$actual'"; fi
actual=$(run_tab_index 100 "ttys002" "$MOCK_PID_ORDER")
if [ "$actual" = "2" ]; then pass "PID order determines tab index (higher PID=tab2)"; else fail "PID ordering" "got '$actual'"; fi

# Single tab
MOCK_SINGLE="  PID  PPID TTY
  200   100 ttys003"

actual=$(run_tab_index 100 "ttys003" "$MOCK_SINGLE")
if [ "$actual" = "1" ]; then pass "single tab → tab 1"; else fail "single tab" "got '$actual'"; fi

# No direct children (Ghostty running but no tabs open yet?)
MOCK_EMPTY="  PID  PPID TTY
  999   888 ttys000"

actual=$(run_tab_index 100 "ttys000" "$MOCK_EMPTY")
if [ -z "$actual" ]; then pass "no direct children → empty"; else fail "no direct children" "got '$actual'"; fi

# Tab stability: tab index should NOT change when a new agent spins up in another tab
# Scenario: 2 tabs open, agent activity doesn't change PID ordering
MOCK_STABLE="  PID  PPID TTY
  200   100 ttys000
  300   100 ttys001
  3924  200 ttys000
  4100  300 ttys001"

actual_tab1=$(run_tab_index 100 "ttys000" "$MOCK_STABLE")
actual_tab2=$(run_tab_index 100 "ttys001" "$MOCK_STABLE")
if [ "$actual_tab1" = "1" ] && [ "$actual_tab2" = "2" ]; then
  pass "tab indices stable with deep descendant processes"
else
  fail "tab stability" "tab1='$actual_tab1', tab2='$actual_tab2'"
fi

# ════════════════════════════════════════════════════════════════════
# SECTION 8: Security & Validation
# ════════════════════════════════════════════════════════════════════

section "8. Security & Validation"

# Path traversal: ../
run_hook '{"session_id":"../etc/passwd","hook_event_name":"SessionStart","cwd":"/tmp"}'
if ! file_exists "../etc/passwd"; then pass "path traversal ../ rejected"; else fail "path traversal ../"; fi

# Path traversal: .hidden
run_hook '{"session_id":".hidden","hook_event_name":"SessionStart","cwd":"/tmp"}'
if ! file_exists ".hidden"; then pass "path traversal . prefix rejected"; else fail "path traversal ."; fi

# Path traversal: embedded /
run_hook '{"session_id":"foo/bar","hook_event_name":"SessionStart","cwd":"/tmp"}'
if ! file_exists "foo/bar"; then pass "path traversal / in id rejected"; else fail "path traversal /"; fi

# Path traversal: backslash
run_hook '{"session_id":"foo\\bar","hook_event_name":"SessionStart","cwd":"/tmp"}'
actual=$(file_count)
if [ "$actual" = "0" ]; then pass "path traversal \\ rejected"; else fail "path traversal \\\\" "files exist: $actual"; fi

# Empty session_id
run_hook '{"session_id":"","hook_event_name":"SessionStart","cwd":"/tmp"}'
actual=$(file_count)
if [ "$actual" = "0" ]; then pass "empty session_id rejected"; else fail "empty session_id" "got $actual files"; fi

# Missing session_id key
run_hook '{"hook_event_name":"SessionStart","cwd":"/tmp"}'
actual=$(file_count)
if [ "$actual" = "0" ]; then pass "missing session_id rejected"; else fail "missing session_id" "got $actual files"; fi

# Missing hook_event_name
run_hook '{"session_id":"no-event","cwd":"/tmp"}'
if ! file_exists "no-event"; then pass "missing hook_event_name rejected"; else fail "missing hook_event_name"; fi

# Malformed JSON
echo "not json at all" | SESSIONS_DIR="$TEST_SESSIONS_DIR" CLAUDE_TTY="ttys042" FALLBACK_HOOK_TYPE="" python3 "$HOOK_PY" 2>/dev/null
actual=$(file_count)
if [ "$actual" = "0" ]; then pass "malformed JSON rejected"; else fail "malformed JSON" "got $actual files"; fi

# Empty input
echo "" | SESSIONS_DIR="$TEST_SESSIONS_DIR" CLAUDE_TTY="ttys042" FALLBACK_HOOK_TYPE="" python3 "$HOOK_PY" 2>/dev/null
actual=$(file_count)
if [ "$actual" = "0" ]; then pass "empty input rejected"; else fail "empty input" "got $actual files"; fi

# SessionEnd for non-existent session (should not crash)
run_hook '{"session_id":"nonexistent","hook_event_name":"SessionEnd"}'
actual=$(file_count)
if [ "$actual" = "0" ]; then pass "SessionEnd for nonexistent session is no-op"; else fail "SessionEnd nonexistent" "got $actual files"; fi

# ════════════════════════════════════════════════════════════════════
# SECTION 9: Fallback hook type from env var
# ════════════════════════════════════════════════════════════════════

section "9. Fallback Hook Type"

echo '{"session_id":"fallback-test","cwd":"/tmp/fb"}' | SESSIONS_DIR="$TEST_SESSIONS_DIR" CLAUDE_TTY="ttys042" FALLBACK_HOOK_TYPE="SessionStart" python3 "$HOOK_PY"
if file_exists "fallback-test"; then
  pass "fallback hook type from env var works"
  check_field "fallback-test" "hook_event_name" "SessionStart" "fallback: event name correct"
else
  fail "fallback hook type from env var"
fi
run_hook '{"session_id":"fallback-test","hook_event_name":"SessionEnd"}'

# JSON hook_event_name takes priority over env var
echo '{"session_id":"priority-test","hook_event_name":"PostToolUse","tool_name":"Read","cwd":"/tmp"}' | SESSIONS_DIR="$TEST_SESSIONS_DIR" CLAUDE_TTY="" FALLBACK_HOOK_TYPE="SessionStart" python3 "$HOOK_PY"
if file_exists "priority-test"; then
  check_field "priority-test" "hook_event_name" "PostToolUse" "JSON hook_event_name overrides env fallback"
else
  fail "priority test: file not created"
fi
run_hook '{"session_id":"priority-test","hook_event_name":"SessionEnd"}'

# ════════════════════════════════════════════════════════════════════
# SECTION 10: Rapid Event Sequences (simulated race conditions)
# ════════════════════════════════════════════════════════════════════

section "10. Rapid Event Sequences"

run_hook '{"session_id":"rapid","hook_event_name":"SessionStart","cwd":"/tmp/rapid"}'

# Fire 5 agents in rapid succession
for i in 1 2 3 4 5; do
  run_hook "{\"session_id\":\"rapid\",\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"rapid-$i\",\"agent_type\":\"Bash\"}"
done

actual=$(read_agent_count "rapid")
if [ "$actual" = "5" ]; then pass "5 rapid agent starts all captured"; else fail "rapid agent starts" "got $actual agents"; fi

# Stop 3 of them rapidly
for i in 1 3 5; do
  run_hook "{\"session_id\":\"rapid\",\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"rapid-$i\",\"agent_type\":\"Bash\"}"
done

actual=$(active_agent_count "rapid")
if [ "$actual" = "2" ]; then pass "2 active after stopping 3"; else fail "active after rapid stops" "got $actual"; fi
actual=$(completed_agent_count "rapid")
if [ "$actual" = "3" ]; then pass "3 completed after stopping 3"; else fail "completed after rapid stops" "got $actual"; fi

# Interleave tool events — agents should survive
for i in $(seq 1 10); do
  run_hook '{"session_id":"rapid","hook_event_name":"PostToolUse","tool_name":"Read"}'
done
actual=$(read_agent_count "rapid")
if [ "$actual" = "5" ]; then pass "all 5 agents survive 10 tool events"; else fail "agents survive tool flood" "got $actual"; fi

# Cleanup
run_hook '{"session_id":"rapid","hook_event_name":"SessionEnd"}'

# ════════════════════════════════════════════════════════════════════
# SECTION 11: Permission Detection Keywords
# ════════════════════════════════════════════════════════════════════

section "11. Permission Detection Keywords"

for keyword in permission approve allow confirm unsafe dangerous trust grant; do
  run_hook "{\"session_id\":\"perm-kw\",\"hook_event_name\":\"Notification\",\"notification_type\":\"\",\"message\":\"Please $keyword this action\",\"cwd\":\"/tmp\"}"
  actual=$(read_field "perm-kw" "is_permission")
  if [ "$actual" = "True" ]; then pass "keyword '$keyword' → is_permission=True"; else fail "keyword '$keyword'" "got '$actual'"; fi
done

# Non-permission keywords
for msg in "Build succeeded" "Tests passed" "File saved" "Compilation complete"; do
  run_hook "{\"session_id\":\"perm-kw\",\"hook_event_name\":\"Notification\",\"notification_type\":\"\",\"message\":\"$msg\",\"cwd\":\"/tmp\"}"
  actual=$(read_field "perm-kw" "is_permission")
  if [ "$actual" = "False" ]; then pass "message '$msg' → is_permission=False"; else fail "non-permission message" "'$msg' got '$actual'"; fi
done

run_hook '{"session_id":"perm-kw","hook_event_name":"SessionEnd"}'

# ════════════════════════════════════════════════════════════════════
# SECTION 12: JSON Structure Validation (overlay compatibility)
# ════════════════════════════════════════════════════════════════════

section "12. JSON Structure Validation"

run_hook '{"session_id":"json-check","hook_event_name":"SessionStart","cwd":"/tmp/project","transcript_path":"/tmp/j.jsonl"}'
run_hook '{"session_id":"json-check","hook_event_name":"SubagentStart","agent_id":"jc-agent","agent_name":"my-agent","agent_type":"Explore"}'

# Verify all required fields exist and have correct types
python3 -c "
import json, sys

with open('$TEST_SESSIONS_DIR/json-check.json') as f:
    d = json.load(f)

errors = []

# Required string fields
for field in ['session_id', 'hook_event_name', 'cwd', 'notification_type', 'message',
              'tool_name', 'tool_input', 'agent_name', 'agent_id', 'agent_type',
              'transcript_path', 'user_prompt', 'reason', 'tty']:
    if field not in d:
        errors.append(f'missing field: {field}')
    elif not isinstance(d[field], str):
        errors.append(f'{field} is not string: {type(d[field]).__name__}')

# Required bool fields
for field in ['is_permission', 'is_interrupt']:
    if field not in d:
        errors.append(f'missing field: {field}')
    elif not isinstance(d[field], bool):
        errors.append(f'{field} is not bool: {type(d[field]).__name__}')

# Required numeric field
if 'timestamp' not in d:
    errors.append('missing field: timestamp')
elif not isinstance(d['timestamp'], (int, float)):
    errors.append(f'timestamp is not number: {type(d[\"timestamp\"]).__name__}')

# Agents dict
if 'agents' not in d:
    errors.append('missing field: agents')
elif not isinstance(d['agents'], dict):
    errors.append(f'agents is not dict: {type(d[\"agents\"]).__name__}')
else:
    for key, agent in d['agents'].items():
        for afield in ['agent_id', 'agent_name', 'agent_type', 'status']:
            if afield not in agent:
                errors.append(f'agent {key} missing {afield}')
            elif not isinstance(agent[afield], str):
                errors.append(f'agent {key}.{afield} is not string')
        if 'started_at' not in agent:
            errors.append(f'agent {key} missing started_at')
        elif not isinstance(agent['started_at'], (int, float)):
            errors.append(f'agent {key}.started_at is not number')

if errors:
    for e in errors:
        print(f'FAIL: {e}')
    sys.exit(1)
else:
    print('OK')
" 2>/dev/null
if [ $? -eq 0 ]; then
  pass "JSON structure has all required fields with correct types"
else
  fail "JSON structure validation"
fi

# Verify agent entry structure
actual=$(read_agent_field "json-check" "jc-agent" "agent_id")
if [ "$actual" = "jc-agent" ]; then pass "agent entry: agent_id correct"; else fail "agent agent_id" "got '$actual'"; fi
actual=$(read_agent_field "json-check" "jc-agent" "agent_name")
if [ "$actual" = "my-agent" ]; then pass "agent entry: agent_name preserved"; else fail "agent agent_name" "got '$actual'"; fi
actual=$(read_agent_field "json-check" "jc-agent" "agent_type")
if [ "$actual" = "Explore" ]; then pass "agent entry: agent_type correct"; else fail "agent agent_type" "got '$actual'"; fi
actual=$(read_agent_field "json-check" "jc-agent" "status")
if [ "$actual" = "active" ]; then pass "agent entry: status=active"; else fail "agent status" "got '$actual'"; fi

# Verify started_at is a reasonable timestamp
python3 -c "
import json, time
with open('$TEST_SESSIONS_DIR/json-check.json') as f:
    d = json.load(f)
started = d['agents']['jc-agent']['started_at']
now = time.time()
# Should be within the last 60 seconds
if abs(now - started) < 60:
    print('OK')
else:
    print(f'FAIL: started_at={started}, now={now}')
    exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then pass "agent started_at is recent timestamp"; else fail "agent started_at timestamp"; fi

run_hook '{"session_id":"json-check","hook_event_name":"SessionEnd"}'

# ════════════════════════════════════════════════════════════════════
# SECTION 13: Atomic Write Safety
# ════════════════════════════════════════════════════════════════════

section "13. Atomic Write Safety"

# Verify no .tmp files left behind after normal operations
run_hook '{"session_id":"atomic","hook_event_name":"SessionStart","cwd":"/tmp/atomic"}'
for i in $(seq 1 20); do
  run_hook "{\"session_id\":\"atomic\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"tool$i\"}"
done
run_hook '{"session_id":"atomic","hook_event_name":"SessionEnd"}'

tmp_count=$(ls "$TEST_SESSIONS_DIR"/*.tmp 2>/dev/null | wc -l | tr -d ' ')
if [ "$tmp_count" = "0" ]; then pass "no .tmp files left behind after 20 events"; else fail "tmp cleanup" "$tmp_count .tmp files remain"; fi

# Verify no .lock files accumulate (tests don't use locking, but check anyway)
lock_count=$(ls "$TEST_SESSIONS_DIR"/*.lock 2>/dev/null | wc -l | tr -d ' ')
if [ "$lock_count" = "0" ]; then pass "no stale .lock files"; else fail "lock cleanup" "$lock_count .lock files"; fi

# ════════════════════════════════════════════════════════════════════
# SECTION 14: State Machine Transitions (overlay status logic)
# ════════════════════════════════════════════════════════════════════

section "14. State Machine Transitions (hook event sequence)"

# This tests the sequence of hook_event_name values that the overlay's resolveStatus() uses.
# We verify the JSON reflects the correct event at each step.

run_hook '{"session_id":"sm","hook_event_name":"SessionStart","cwd":"/tmp/sm"}'
check_field "sm" "hook_event_name" "SessionStart" "SM: SessionStart"

run_hook '{"session_id":"sm","hook_event_name":"UserPromptSubmit","user_prompt":"hello"}'
check_field "sm" "hook_event_name" "UserPromptSubmit" "SM: → UserPromptSubmit (active)"

run_hook '{"session_id":"sm","hook_event_name":"PreToolUse","tool_name":"Bash"}'
check_field "sm" "hook_event_name" "PreToolUse" "SM: → PreToolUse (active)"

run_hook '{"session_id":"sm","hook_event_name":"PostToolUse","tool_name":"Bash"}'
check_field "sm" "hook_event_name" "PostToolUse" "SM: → PostToolUse (active)"

run_hook '{"session_id":"sm","hook_event_name":"Stop","reason":"assistant_turn_complete"}'
check_field "sm" "hook_event_name" "Stop" "SM: → Stop (idle)"

run_hook '{"session_id":"sm","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow?"}'
check_field "sm" "hook_event_name" "Notification" "SM: → Notification/permission (needs_permission)"
check_field "sm" "is_permission" "True" "SM: is_permission=True"

run_hook '{"session_id":"sm","hook_event_name":"UserPromptSubmit","user_prompt":"yes"}'
check_field "sm" "hook_event_name" "UserPromptSubmit" "SM: → UserPromptSubmit (active again)"

run_hook '{"session_id":"sm","hook_event_name":"PostToolUseFailure","tool_name":"Bash","is_interrupt":true}'
check_field "sm" "hook_event_name" "PostToolUseFailure" "SM: → PostToolUseFailure/interrupt (waiting_input)"
check_field "sm" "is_interrupt" "True" "SM: is_interrupt=True"

run_hook '{"session_id":"sm","hook_event_name":"SubagentStart","agent_id":"sm-a","agent_type":"Explore"}'
check_field "sm" "hook_event_name" "SubagentStart" "SM: → SubagentStart (active)"

run_hook '{"session_id":"sm","hook_event_name":"SubagentStop","agent_id":"sm-a","agent_type":"Explore"}'
check_field "sm" "hook_event_name" "SubagentStop" "SM: → SubagentStop (stays at current)"

run_hook '{"session_id":"sm","hook_event_name":"Notification","notification_type":"info","message":"Task complete"}'
check_field "sm" "hook_event_name" "Notification" "SM: → Notification/info (waiting_input)"
check_field "sm" "is_permission" "False" "SM: non-permission notification"

run_hook '{"session_id":"sm","hook_event_name":"SessionEnd"}'
if ! file_exists "sm"; then pass "SM: → SessionEnd (file removed)"; else fail "SM: SessionEnd"; fi

# ════════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════╗"
printf "║  \033[32mPassed: %-5d\033[0m  \033[31mFailed: %-5d\033[0m  Total: %-5d ║\n" "$PASS" "$FAIL" "$((PASS + FAIL))"
echo "╚═══════════════════════════════════════════════╝"
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
