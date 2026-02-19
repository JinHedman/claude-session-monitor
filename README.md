# Claude Session Monitor

A macOS overlay app that shows active Claude CLI sessions in a floating glass panel — like Apple's notification center, with Claude's purple palette.

## Architecture

```
Claude CLI → end hook fires → POST http://localhost:9147/api/events
                                         ↓
                                   Rust daemon (axum)
                                   SQLite ~/.claude-monitor/sessions.db
                                         ↓ WebSocket broadcast
                                   Swift overlay (NSPanel)
                                   Menu bar icon + glass cards
```

## Components

| Path | What it does |
|------|-------------|
| `hook/` | Shell scripts triggered by Claude hooks |
| `backend/` | Rust axum daemon, port 9147 |
| `overlay/` | Swift macOS menu-bar overlay |

## Quick Start

### 1. Start the backend

```bash
cd backend
cargo build --release
./target/release/claude-monitor
```

Or install as a LaunchAgent so it runs at login:
```bash
cp target/release/claude-monitor /usr/local/bin/claude-monitor
cp com.claude.monitor.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.claude.monitor.plist
```

### 2. Install the Claude hook

```bash
cd hook
./install-hook.sh
```

This merges the hook into `~/.claude/settings.json` for these event types:
- `Stop` — session ended
- `Notification` — needs user input (green dot)
- `PostToolUse` — tool used / subagent spawned
- `PreToolUse` — activity heartbeat

### 3. Build and run the overlay

```bash
cd overlay
swift build -c release
.build/release/ClaudeMonitor
```

The app lives in the menu bar. Click the icon to show/hide the overlay.

## UI

- **Glass panel** — right side of screen, always on top, blurs content behind it
- **Session cards** — one per active Claude session
  - Purple pulsing dot = active
  - Green solid dot = waiting for your input
  - Gray dot = completed
- **Expand/collapse** — click a card to reveal individual subagents
- **Menu bar icon** — purple `● N` when sessions active, amber when input needed

## Backend API

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/events` | Receive hook event |
| `GET` | `/api/sessions` | List active sessions with agents |
| `DELETE` | `/api/sessions/:id` | Mark session completed |
| `GET` | `/health` | Health check |
| `WS` | `/ws` | Real-time session updates |

## Hook Event Schema

```json
{
  "event_type": "stop | notification | task_started | tool_use",
  "session_id": "uuid",
  "project_path": "/path/to/project",
  "project_name": "my-project",
  "agent_name": "main",
  "parent_session_id": null,
  "needs_input": false,
  "tool_name": null
}
```
