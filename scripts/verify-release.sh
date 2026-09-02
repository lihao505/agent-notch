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
    ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt
    ThirdPartyLicenses/swift-markdown-0.8.0-LICENSE.txt
    ThirdPartyLicenses/swift-cmark-0.8.0-COPYING.txt
    AgentBridge/README.md AgentBridge/install.sh AgentBridge/uninstall.sh
    AgentBridge/bin/notch-bridge.py AgentBridge/bin/codex-relay.py
    ClaudeIsland/Services/Chat/AgentTransport.swift
    ClaudeIslandTests/ProcessExecutorTests.swift
    ClaudeIslandTests/AgentTransportTests.swift
    ClaudeIslandTests/SessionStoreLifecycleTests.swift
    ClaudeIslandTests/PermissionRoutingTests.swift
    ClaudeIslandTests/ConversationParserIndexTests.swift
)
for file in "${required_files[@]}"; do
    [ -s "$file" ] || fail "required release file is missing or empty: $file"
done

# Apache-2.0 section 4(b): every currently modified upstream source must carry
# a prominent notice. This checked-in list also works in shallow CI clones that
# do not have the upstream remote configured.
modified_upstream_sources=(
    ClaudeIsland/App/AppDelegate.swift
    ClaudeIsland/App/ClaudeIslandApp.swift
    ClaudeIsland/App/ScreenObserver.swift
    ClaudeIsland/App/WindowManager.swift
    ClaudeIsland/Core/ClaudePaths.swift
    ClaudeIsland/Core/NotchGeometry.swift
    ClaudeIsland/Core/NotchViewModel.swift
    ClaudeIsland/Core/Settings.swift
    ClaudeIsland/Models/ChatMessage.swift
    ClaudeIsland/Models/SessionEvent.swift
    ClaudeIsland/Models/SessionPhase.swift
    ClaudeIsland/Models/SessionState.swift
    ClaudeIsland/Resources/claude-island-state.py
    ClaudeIsland/Services/Chat/ChatHistoryManager.swift
    ClaudeIsland/Services/Hooks/HookInstaller.swift
    ClaudeIsland/Services/Hooks/HookSocketServer.swift
    ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift
    ClaudeIsland/Services/Session/ConversationParser.swift
    ClaudeIsland/Services/Shared/ProcessExecutor.swift
    ClaudeIsland/Services/Shared/ProcessTreeBuilder.swift
    ClaudeIsland/Services/Shared/TerminalAppRegistry.swift
    ClaudeIsland/Services/State/SessionStore.swift
    ClaudeIsland/Services/Update/NotchUserDriver.swift
    ClaudeIsland/UI/Components/ProcessingSpinner.swift
    ClaudeIsland/UI/Components/TerminalColors.swift
    ClaudeIsland/UI/Views/ChatView.swift
    ClaudeIsland/UI/Views/ClaudeInstancesView.swift
    ClaudeIsland/UI/Views/NotchHeaderView.swift
    ClaudeIsland/UI/Views/NotchMenuView.swift
    ClaudeIsland/UI/Views/NotchView.swift
    ClaudeIsland/UI/Window/NotchViewController.swift
    ClaudeIsland/UI/Window/NotchWindow.swift
    ClaudeIsland/UI/Window/NotchWindowController.swift
    scripts/build.sh
    scripts/create-release.sh
    scripts/generate-keys.sh
)
for file in "${modified_upstream_sources[@]}"; do
    [ -f "$file" ] || fail "modified upstream source is missing: $file"
    grep -Fq 'Modified by lihao505 for Agent Notch, 2026.' "$file" ||
        fail "modified upstream source lacks a prominent modification notice: $file"
done

# If a local upstream ref is available, additionally catch newly modified
# upstream sources that have not yet been added to the static CI list.
if git rev-parse --verify upstream/main^{commit} >/dev/null 2>&1; then
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        grep -Fq 'Modified by lihao505 for Agent Notch, 2026.' "$file" ||
            fail "newly modified upstream source lacks a prominent notice: $file"
    done < <(git diff --diff-filter=M --name-only upstream/main...HEAD -- \
        '*.swift' '*.py' '*.sh')
fi

package_lock='ClaudeIsland.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
[ -s "$package_lock" ] || fail "Swift package lock file is missing: $package_lock"
python3 - "$package_lock" <<'PYEOF' || fail "Swift package versions or revisions drifted"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    resolved = json.load(handle)

expected = {
    "sparkle": ("2.9.4", "b6496a74a087257ef5e6da1c5b29a447a60f5bd7"),
    "swift-markdown": ("0.8.0", "3c6f9523da3a1ec2fd829673e472d95b8097a3b8"),
    "swift-cmark": ("0.8.0", "924936d0427cb25a61169739a7660230bffa6ea6"),
}
pins = {pin["identity"]: pin["state"] for pin in resolved.get("pins", [])}
for identity, (version, revision) in expected.items():
    state = pins.get(identity)
    if state is None:
        raise SystemExit(f"missing package pin: {identity}")
    if state.get("version") != version or state.get("revision") != revision:
        raise SystemExit(
            f"unexpected {identity} pin: "
            f"{state.get('version')} / {state.get('revision')}"
        )
PYEOF

check_sha256() {
    expected="$1"
    file="$2"
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    [ "$actual" = "$expected" ] ||
        fail "third-party license hash mismatch: $file"
}
check_sha256 389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe \
    ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt
check_sha256 167beb36f181bd163c93c6feb45c68e5f9462fe1af55b278f7bfd1df20e673a3 \
    ThirdPartyLicenses/swift-markdown-0.8.0-LICENSE.txt
check_sha256 c22e885f33b821bddb24cf007145e5540655b6c0f403e49e6c76a93c28e6d9a9 \
    ThirdPartyLicenses/swift-cmark-0.8.0-COPYING.txt

grep -Fq 'BSD-2-Clause' THIRD_PARTY_NOTICES.md ||
    fail "swift-cmark must be identified as BSD-2-Clause"
grep -Fq 'ThirdPartyLicenses in Resources' ClaudeIsland.xcodeproj/project.pbxproj ||
    fail "third-party license directory is not included in app resources"
grep -Fq 'CodeBuddy 集成目前标记为 Experimental' README.md ||
    fail "README must label CodeBuddy as Experimental"
grep -Fq 'CodeBuddy（Experimental）' docs/RELEASE_CHECKLIST.md ||
    fail "release checklist must keep CodeBuddy marked Experimental"
grep -Fq 'def persist_session_snapshot(state, observed_at=None):' \
    AgentBridge/bin/notch-bridge.py ||
    fail "bridge must persist lifecycle state for mid-turn app launches"
grep -Fq 'restoreBridgeSessionSnapshots()' \
    ClaudeIsland/Services/State/SessionStore.swift ||
    fail "app must restore bridge state on launch"
grep -Fq '"observed_at": observed_at' AgentBridge/bin/notch-bridge.py ||
    fail "bridge events must carry their lifecycle observation time"
grep -Fq 'discoverCodexTasks(' \
    ClaudeIsland/Services/Session/ConversationParser.swift ||
    fail "app must discover Codex turns even when the start hook is missed"
grep -Fq 'codexLifecycleInitialReadOffset(' \
    ClaudeIsland/Services/Session/ConversationParser.swift ||
    fail "Codex discovery must recover lifecycle boundaries from long rollouts"
grep -Fq 'hasRecentNativeCodexActivity' \
    ClaudeIsland/Services/State/SessionStore.swift ||
    fail "native Codex discoveries must survive state persistence"
grep -Fq 'AsyncStream.makeStream' \
    ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift ||
    fail "hook lifecycle events must use one ordered consumer"
grep -Fq 'AgentNotchCoreTests' ClaudeIsland.xcodeproj/project.pbxproj ||
    fail "Swift lifecycle test target is missing"
grep -Fq 'Test Swift lifecycle core' .github/workflows/ci.yml ||
    fail "CI must execute the Swift lifecycle tests"
if grep -RqE 'allowSessionFallback|sendPermissionResponseBySession' \
    ClaudeIsland --include='*.swift'; then
    fail "production permission routing must not use a session-only fallback"
fi
grep -Fq '~/.multiagent-notch/session-state/' PRIVACY.md ||
    fail "privacy notice must disclose offline session snapshots"

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
