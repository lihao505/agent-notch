#!/bin/bash
# Fast, non-destructive release gate used locally and by CI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

required_files=(
    LICENSE.md NOTICE README.md PRIVACY.md SECURITY.md CONTRIBUTING.md
    THIRD_PARTY_NOTICES.md docs/ASSET_PROVENANCE.md docs/RELEASE_CHECKLIST.md
    AgentBridge/README.md AgentBridge/install.sh AgentBridge/uninstall.sh
    AgentBridge/bin/notch-bridge.py AgentBridge/bin/codex-relay.py
)
for file in "${required_files[@]}"; do
    [ -s "$file" ] || fail "required release file is missing or empty: $file"
done

forbidden_pattern='https://vibenotch\.app|https://github\.com/farouqaldori|PRODUCT_BUNDLE_IDENTIFIER = com\.celestial\.ClaudeIsland|com\.farouqaldori\.ClaudeIsland'
if grep -REn \
    --exclude='*.md' \
    --exclude='*.pyc' \
    "$forbidden_pattern" \
    README.md ClaudeIsland scripts
then
    fail "runtime or release files still reference upstream infrastructure"
fi

grep -Eq 'PRODUCT_BUNDLE_IDENTIFIER = io\.github\.lihao505\.AgentNotch;' \
    ClaudeIsland.xcodeproj/project.pbxproj ||
    fail "Agent Notch bundle identifier is not configured"
grep -Eq '<string>Agent Notch</string>' ClaudeIsland/Info.plist ||
    fail "Agent Notch display name is not configured"
grep -Eq 'lihao505/agent-notch/releases/latest/download/appcast\.xml' ClaudeIsland/Info.plist ||
    fail "owned update feed is not configured"
if grep -En 'DEVELOPMENT_TEAM = 2DKS5U9LV4;' ClaudeIsland.xcodeproj/project.pbxproj; then
    fail "upstream Apple Developer team is still configured"
fi

python3 -m plistlib ClaudeIsland/Info.plist >/dev/null
bash -n scripts/build.sh scripts/create-release.sh scripts/generate-keys.sh \
    AgentBridge/install.sh AgentBridge/uninstall.sh
python3 -B -m unittest discover -s AgentBridge/tests -v

echo "Release metadata and scripts verified."
