#!/bin/bash
set -e

INSTALL_DIR="$HOME/.config/edid-override"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.edid-override.plist"

echo "=== mac-edid-override uninstaller ==="
echo ""

# Reset virtual EDID
if [ -f "$INSTALL_DIR/edid_override" ]; then
    echo "Resetting EDID override..."
    "$INSTALL_DIR/edid_override" --reset 2>/dev/null || true
fi

# Unload and remove LaunchAgent
if [ -f "$LAUNCH_AGENT" ]; then
    echo "Removing LaunchAgent..."
    launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
    rm "$LAUNCH_AGENT"
    echo "  Removed"
fi

# Remove install directory
if [ -d "$INSTALL_DIR" ]; then
    echo "Removing $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
    echo "  Removed"
fi

echo ""
echo "=== Uninstall complete ==="
echo "EDID override has been removed. Your display will use factory settings."
echo "You may need to restart or replug your display cable for changes to take effect."
