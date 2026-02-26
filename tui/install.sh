#!/usr/bin/env bash
# Install claude-monitor TUI to /usr/local/bin
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Building claude-monitor..."
cd "$SCRIPT_DIR"
go build -o /tmp/claude-monitor .

# macOS 26+ requires explicit ad-hoc codesign (linker-signed alone causes SIGKILL)
echo "Signing..."
codesign --force -s - /tmp/claude-monitor

echo "Installing..."
sudo cp /tmp/claude-monitor /usr/local/bin/claude-monitor

echo "Installed to /usr/local/bin/claude-monitor"
echo ""
echo "Usage:"
echo "  Open a dedicated Ghostty tab and run: claude-monitor"
echo ""
echo "Optional: add shell alias"
echo "  alias cm='claude-monitor'"
