# Claude Session Monitor

A TUI (terminal UI) that runs in a Ghostty tab and shows active Claude CLI sessions in real time.

## Architecture

```
Claude CLI → hook fires → JSON files → TUI reads & displays
```

The hook writes one JSON file per session to `~/.claude/monitor/sessions/`. The TUI polls
that directory and renders a live table of sessions, states, and activity.

## Quick Start

### 1. Install the hook

Add the hook to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse":  [{ "hooks": [{ "type": "command", "command": "/path/to/hook/claude-monitor-hook.sh" }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "/path/to/hook/claude-monitor-hook.sh" }] }],
    "Notification":[{ "hooks": [{ "type": "command", "command": "/path/to/hook/claude-monitor-hook.sh" }] }],
    "Stop":        [{ "hooks": [{ "type": "command", "command": "/path/to/hook/claude-monitor-hook.sh" }] }]
  }
}
```

### 2. Build and install the TUI

```bash
cd tui && ./install.sh
```

This builds the Go binary and installs it to `/usr/local/bin/claude-monitor`.

### 3. Open a Ghostty tab and run

```bash
claude-monitor
```

Keep this tab open while working. It updates automatically as Claude sessions start and end.

## UI

The TUI shows a table of active sessions with their state and recent activity.

| Key | Action |
|-----|--------|
| `up` / `down` | Navigate sessions |
| `Enter` / `f` | Focus the selected session's Ghostty tab |
| `d` | Dismiss an idle session |
| `q` | Quit |

## Session States

| State | Color | Meaning |
|-------|-------|---------|
| active | orange | Claude is running a tool |
| waiting | green | Claude is waiting for your input |
| permission | red | Claude needs permission approval |
| idle | gray | Session is quiet / no recent activity |

## Tab Focusing

Pressing `Enter` or `f` on a session focuses the corresponding Ghostty tab. The TUI
writes a terminal title escape sequence to the session's TTY at the moment you press
the key, waits 200 ms for Ghostty to register it, then clicks the matching Window menu
item.

**Works in both environments:**

- **Direct Ghostty tab** — the hook captures the TTY of the Claude process and stores
  it in the session JSON. The TUI writes the OSC title directly to that TTY.
- **Inside tmux** — the hook runs `tmux display-message -p "#{client_tty}"` to find
  the outer Ghostty terminal's TTY and stores it as `ghostty_tty`. The TUI uses that
  field so the title reaches Ghostty rather than being intercepted by tmux.

> **Why write at click time?** Claude Code continuously resets the tab title to
> `⠂ Claude Code` while active. Writing the title at the moment you press `f` (when
> Claude is typically idle / waiting) means the title persists long enough for the
> Window menu lookup to succeed.

## Development

Build and run without installing:

```bash
cd tui && go build -o /tmp/claude-monitor . && /tmp/claude-monitor
```

Run tests:

```bash
cd tui && go test ./... -v
```
