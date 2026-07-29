#!/bin/bash
# Modified by lihao505 for Agent Notch, 2026.
# Notarize, package, sign updates, and create an Agent Notch GitHub release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
EXPORT_PATH="$BUILD_DIR/export"
RELEASE_DIR="$PROJECT_DIR/releases"
KEYS_DIR="$PROJECT_DIR/.sparkle-keys"

GITHUB_REPO="${AGENT_NOTCH_GITHUB_REPO:-lihao505/agent-notch}"
KEYCHAIN_PROFILE="${AGENT_NOTCH_KEYCHAIN_PROFILE:-AgentNotch}"
APP_PATH="$EXPORT_PATH/Agent Notch.app"
APP_FILE_NAME="AgentNotch"

if [ "$GITHUB_REPO" = "farouqaldori/vibe-notch" ]; then
    echo "ERROR: refusing to publish Agent Notch artifacts to the upstream repository"
    exit 1
fi
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: app not found at $APP_PATH"
    echo "Run ./scripts/build.sh first."
    exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: GitHub CLI is required. Install and authenticate gh first."
    exit 1
fi
if [ ! -f "$KEYS_DIR/eddsa_private_key" ]; then
    echo "ERROR: missing Sparkle private key: $KEYS_DIR/eddsa_private_key"
    echo "Run ./scripts/generate-keys.sh once and back up the key securely."
    exit 1
fi

PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP_PATH/Contents/Info.plist")
if [ -z "$PUBLIC_KEY" ] || [ "$PUBLIC_KEY" = "AGENT_NOTCH_SPARKLE_PUBLIC_KEY_NOT_CONFIGURED" ]; then
    echo "ERROR: the app still contains the Sparkle public-key placeholder"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
TAG="v$VERSION"
DMG_PATH="$RELEASE_DIR/$APP_FILE_NAME-$VERSION.dmg"
APPCAST_DIR="$RELEASE_DIR/appcast"
DOWNLOAD_PREFIX="https://github.com/$GITHUB_REPO/releases/download/$TAG/"

echo "=== Agent Notch $VERSION ($BUILD) ==="
mkdir -p "$RELEASE_DIR" "$APPCAST_DIR"

if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    echo "ERROR: notarization profile '$KEYCHAIN_PROFILE' is not configured"
    echo "Create it with: xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\""
    exit 1
fi

NOTARY_ZIP="$BUILD_DIR/$APP_FILE_NAME-$VERSION.zip"
ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
rm -f "$NOTARY_ZIP"

rm -f "$DMG_PATH"
if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
        --volname "Agent Notch" \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "Agent Notch.app" 150 200 \
        --app-drop-link 450 200 \
        --hide-extension "Agent Notch.app" \
        "$DMG_PATH" \
        "$APP_PATH"
else
    hdiutil create \
        -volname "Agent Notch" \
        -srcfolder "$APP_PATH" \
        -ov -format UDZO \
        "$DMG_PATH"
fi

xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

SPARKLE_BIN=""
for candidate in \
    "$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin" \
    "$HOME"/Library/Developer/Xcode/DerivedData/ClaudeIsland-*/SourcePackages/artifacts/sparkle/Sparkle/bin
do
    if [ -x "$candidate/generate_appcast" ]; then
        SPARKLE_BIN="$candidate"
        break
    fi
done
if [ -z "$SPARKLE_BIN" ]; then
    echo "ERROR: Sparkle release tools were not found after building"
    exit 1
fi

rm -rf "$APPCAST_DIR"
mkdir -p "$APPCAST_DIR"
cp "$DMG_PATH" "$APPCAST_DIR/"
"$SPARKLE_BIN/generate_appcast" \
    --ed-key-file "$KEYS_DIR/eddsa_private_key" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    "$APPCAST_DIR"

APPCAST_PATH="$APPCAST_DIR/appcast.xml"
if [ ! -f "$APPCAST_PATH" ]; then
    echo "ERROR: Sparkle did not generate appcast.xml"
    exit 1
fi

if gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    echo "ERROR: release $TAG already exists; bump the version before publishing"
    exit 1
fi

RELEASE_ARGS=(release create "$TAG" "$DMG_PATH" "$APPCAST_PATH"
    --repo "$GITHUB_REPO"
    --title "Agent Notch $TAG"
    --notes "Agent Notch $TAG

See the repository release notes and known limitations before installing.
The DMG is signed, notarized, and distributed with a Sparkle appcast.")

if [ "${AGENT_NOTCH_PUBLISH:-0}" != "1" ]; then
    RELEASE_ARGS+=(--draft)
fi

gh "${RELEASE_ARGS[@]}"
echo "=== Release created: https://github.com/$GITHUB_REPO/releases/tag/$TAG ==="
if [ "${AGENT_NOTCH_PUBLISH:-0}" != "1" ]; then
    echo "The release is a draft. Perform installation QA before publishing it."
fi
