#!/bin/bash
set -e

INSTALL_DIR="$HOME/.config/edid-override"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.edid-override.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== mac-edid-override installer ==="
echo ""

# Check for Xcode Command Line Tools
if ! xcode-select -p &>/dev/null; then
    echo "ERROR: Xcode Command Line Tools required."
    echo "Install with: xcode-select --install"
    exit 1
fi

# Select EDID file
EDID_FILE=""
if [ -n "$1" ]; then
    EDID_FILE="$1"
elif [ -f "$SCRIPT_DIR/edids/dell-u4025qw.bin" ]; then
    EDID_FILE="$SCRIPT_DIR/edids/dell-u4025qw.bin"
fi

if [ -z "$EDID_FILE" ] || [ ! -f "$EDID_FILE" ]; then
    echo "ERROR: No EDID file found."
    echo "Usage: ./install.sh [path/to/edid.bin]"
    echo ""
    echo "Available EDID files:"
    ls -1 "$SCRIPT_DIR/edids/"*.bin 2>/dev/null || echo "  (none found in edids/)"
    exit 1
fi

echo "EDID file: $EDID_FILE"
echo "Install dir: $INSTALL_DIR"
echo ""

# Compile
echo "Compiling..."
clang -fmodules -framework Foundation -framework CoreGraphics -framework IOKit -framework AppKit \
    -o "$SCRIPT_DIR/edid_override" "$SCRIPT_DIR/edid_override.m"
clang -fmodules -framework Foundation -framework CoreGraphics -framework IOKit \
    -o "$SCRIPT_DIR/edid_check" "$SCRIPT_DIR/edid_check.m"
echo "  OK"

# Install files
echo "Installing..."
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/edid_override" "$INSTALL_DIR/edid_override"
cp "$SCRIPT_DIR/edid_check" "$INSTALL_DIR/edid_check"
cp "$EDID_FILE" "$INSTALL_DIR/edid.bin"
chmod +x "$INSTALL_DIR/edid_override" "$INSTALL_DIR/edid_check"
echo "  Binaries installed to $INSTALL_DIR"

# Install LaunchAgent
echo "Setting up LaunchAgent..."
if launchctl list com.edid-override &>/dev/null; then
    launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
fi

sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/com.edid-override.plist" > "$LAUNCH_AGENT"
launchctl load "$LAUNCH_AGENT"
echo "  LaunchAgent installed (runs at login)"

# Run injection now
echo ""
echo "Injecting EDID..."
"$INSTALL_DIR/edid_override"

echo ""
echo "Checking display status..."
"$INSTALL_DIR/edid_check"

echo ""
echo "=== Installation complete ==="
echo ""
echo "The EDID override is now active and will auto-apply on login."
echo "You should see high refresh rate options in System Settings > Displays."
echo ""
echo "Useful commands:"
echo "  $INSTALL_DIR/edid_check       # Check current status"
echo "  $INSTALL_DIR/edid_override --reset   # Remove override"
echo "  ./uninstall.sh                       # Full uninstall"
