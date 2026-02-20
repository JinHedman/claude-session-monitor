#!/usr/bin/env bash
# Install Claude Session Monitor hook into ~/.claude/settings.json
set -euo pipefail

HOOK_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-monitor-hook.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"

# Ensure hook script is executable
chmod +x "$HOOK_SCRIPT"

echo "Installing Claude Session Monitor hook..."
echo "Hook script: $HOOK_SCRIPT"

# Create directories
mkdir -p "$HOME/.claude"
mkdir -p "$HOME/.claude/monitor/sessions"

# If settings.json doesn't exist, create a minimal one
if [ ! -f "$SETTINGS_FILE" ]; then
  echo '{}' > "$SETTINGS_FILE"
fi

# Use python3 to safely merge hooks into existing settings
python3 << PYEOF
import json, sys, os

settings_file = os.path.expanduser("~/.claude/settings.json")
hook_script = "$HOOK_SCRIPT"

with open(settings_file, 'r') as f:
    settings = json.load(f)

def make_hook(hook_type):
    return {
        "type": "command",
        "command": f"CLAUDE_HOOK_TYPE={hook_type} '{hook_script}'",
        "async": True
    }

hooks = settings.get("hooks", {})

hook_types = [
    "SessionStart", "SessionEnd", "UserPromptSubmit",
    "Stop", "Notification",
    "SubagentStart", "SubagentStop",
    "PreToolUse", "PostToolUse", "PostToolUseFailure",
]

for hook_type in hook_types:
    existing = hooks.get(hook_type, [])

    # Remove any existing monitor hooks (to update async/command format)
    cleaned = []
    found = False
    for rule in existing:
        if isinstance(rule, dict) and "hooks" in rule:
            new_hooks = [h for h in rule["hooks"] if hook_script not in h.get("command", "")]
            if len(new_hooks) < len(rule["hooks"]):
                found = True
            if new_hooks:
                rule["hooks"] = new_hooks
                cleaned.append(rule)
            # drop empty rules
        elif isinstance(rule, dict) and "command" in rule:
            if hook_script not in rule.get("command", ""):
                cleaned.append(rule)
            else:
                found = True
        else:
            cleaned.append(rule)

    # Add fresh hook entry
    new_rule = {
        "matcher": "",
        "hooks": [make_hook(hook_type)]
    }
    hooks[hook_type] = cleaned + [new_rule]
    if found:
        print(f"  Updated {hook_type} hook")
    else:
        print(f"  Added {hook_type} hook")

settings["hooks"] = hooks

with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2)

print(f"\nHooks installed successfully in {settings_file}")
PYEOF

echo ""
echo "Done! Build and run the overlay:"
echo "  cd $(dirname "$HOOK_SCRIPT")/../overlay && swift build -c release"
echo "  .build/release/ClaudeMonitor"
