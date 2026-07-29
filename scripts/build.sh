#!/bin/bash
# Modified by lihao505 for Agent Notch, 2026.
# Build a signed Agent Notch archive for release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/AgentNotch.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
TEAM_ID="${AGENT_NOTCH_DEVELOPMENT_TEAM:-}"

if [ -z "$TEAM_ID" ]; then
    echo "ERROR: AGENT_NOTCH_DEVELOPMENT_TEAM is required for a signed release build."
    echo "Example: AGENT_NOTCH_DEVELOPMENT_TEAM=ABCDE12345 ./scripts/build.sh"
    exit 1
fi

echo "=== Building Agent Notch ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"
xcodebuild archive \
    -project ClaudeIsland.xcodeproj \
    -scheme ClaudeIsland \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID"

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_PATH/Agent Notch.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: expected app was not exported at $APP_PATH"
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "=== Build complete: $APP_PATH ==="
echo "Next: ./scripts/create-release.sh"
