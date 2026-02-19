#!/usr/bin/env bash
# Install Claude Session Monitor hook into ~/.claude/settings.json
set -euo pipefail

HOOK_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-monitor-hook.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"

# Ensure hook script is executable
chmod +x "$HOOK_SCRIPT"

echo "Installing Claude Session Monitor hook..."
echo "Hook script: $HOOK_SCRIPT"

# Create ~/.claude dir if needed
mkdir -p "$HOME/.claude"

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

hook_entry = {
    "type": "command",
    "command": f"CLAUDE_HOOK_TYPE=\$CLAUDE_HOOK_TYPE {hook_script}"
}

# We need to set CLAUDE_HOOK_TYPE differently per hook type
def make_hook(hook_type):
    return {
        "type": "command",
        "command": f"CLAUDE_HOOK_TYPE={hook_type} {hook_script}"
    }

hooks = settings.get("hooks", {})

for hook_type in ["Stop", "Notification", "PostToolUse", "PreToolUse"]:
    existing = hooks.get(hook_type, [])
    # Check if our hook is already there
    already_installed = any(
        hook_script in entry.get("command", "")
        for rule in existing
        for entry in rule.get("hooks", [])
        if isinstance(rule, dict)
    )
    # Also handle if existing is a list of command objects directly
    if not already_installed:
        already_installed = any(
            hook_script in entry.get("command", "")
            for entry in existing
            if isinstance(entry, dict) and "command" in entry
        )

    if not already_installed:
        # Use the standard hooks format: list of {matcher, hooks: [...]}
        new_rule = {
            "matcher": "",
            "hooks": [make_hook(hook_type)]
        }
        if isinstance(existing, list):
            hooks[hook_type] = existing + [new_rule]
        else:
            hooks[hook_type] = [new_rule]
        print(f"  Added {hook_type} hook")
    else:
        print(f"  {hook_type} hook already installed, skipping")

settings["hooks"] = hooks

with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2)

print(f"\nHooks installed successfully in {settings_file}")
PYEOF

echo ""
echo "Done! Start the backend daemon before using:"
echo "  cd $(dirname "$HOOK_SCRIPT")/../backend && cargo run --release"
