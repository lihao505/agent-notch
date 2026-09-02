#!/bin/bash
# Agent Notch Bridge uninstaller — removes ONLY our own hooks (exact command
# match, never basename substrings), leaves Agent Notch's native Claude hook and
# unrelated hooks untouched.
set -e
HOME_DIR="${HOME}"
PY="/usr/bin/python3"
PATH="${HOME_DIR}/.local/bin:${HOME_DIR}/.codex/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"
export PATH
STABLE_DIR="${HOME_DIR}/.multiagent-notch/bin"
BRIDGE_DST="${STABLE_DIR}/notch-bridge.py"
BRIDGE_CONFIG="${HOME_DIR}/.multiagent-notch/config.json"
CLAUDE_DIR="${AGENT_NOTCH_CLAUDE_DIR:-${CLAUDE_CONFIG_DIR:-}}"
if [ -z "${CLAUDE_DIR}" ] && [ -f "${BRIDGE_CONFIG}" ]; then
  CLAUDE_DIR="$(${PY} - "${BRIDGE_CONFIG}" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as source:
        value = json.load(source).get("claude_config_dir", "")
    print(value if isinstance(value, str) else "")
except (OSError, ValueError, AttributeError):
    print("")
PYEOF
)"
fi
CLAUDE_DIR="${CLAUDE_DIR:-${HOME_DIR}/.claude}"

# Exact commands this project has ever registered (keep in sync with install.sh).
OUR_CMD="${PY} ${BRIDGE_DST} --source codex"
CODEBUDDY_CMD="${PY} ${BRIDGE_DST} --source codebuddy"
CLAUDE_LIFECYCLE_CMD="${PY} ${BRIDGE_DST} --source claude --lifecycle-only"
CLAUDE_INTERACTIVE_CMD="${PY} ${BRIDGE_DST} --source claude"
LEGACY_CMD="${PY} ${HOME_DIR}/.codex/hooks/vibe-notch-bridge.py"
RELAY_PREFIX="multiagent-notch-codex-"

echo "=== Agent Notch Bridge uninstaller ==="

backup_json_file() {
  local path="$1"
  cp -p "${path}" "${path}.bak.$(date +%Y%m%dT%H%M%S).$$"
}

CODEX_HOOKS="${HOME_DIR}/.codex/hooks.json"
if [ -f "${CODEX_HOOKS}" ]; then
  backup_json_file "${CODEX_HOOKS}"
  OWNED_JSON="$("${PY}" -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${OUR_CMD}" "${LEGACY_CMD}")"
  OWNED_JSON="${OWNED_JSON}" "${PY}" - "$CODEX_HOOKS" <<'PYEOF'
import json, os, sys, uuid
p = os.path.realpath(sys.argv[1])
owned = set(json.loads(os.environ["OWNED_JSON"]))

def atomic_write_json(path, value):
    mode = os.stat(path).st_mode & 0o777
    temporary = f"{path}.agent-notch-{os.getpid()}-{uuid.uuid4().hex}.tmp"
    try:
        with open(temporary, "w") as output:
            json.dump(value, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
with open(p) as f:
    cfg = json.load(f)
if not isinstance(cfg, dict):
    print("  Codex hooks skipped (settings root is not an object)")
    sys.exit(0)
hooks = cfg.get("hooks", {})
if not isinstance(hooks, dict):
    print("  Codex hooks skipped (hooks is not an object)")
    sys.exit(0)

def command_of(hook):
    if not isinstance(hook, dict):
        return ""
    command = hook.get("command")
    return command.strip() if isinstance(command, str) else ""

for ev in list(hooks.keys()):
    entries = hooks[ev]
    if not isinstance(entries, list):
        continue
    out = []
    for e in entries:
        if not isinstance(e, dict):
            out.append(e)
            continue
        hs = e.get("hooks")
        if isinstance(hs, list):
            hs2 = [h for h in hs if command_of(h) not in owned]
            if not hs2:
                continue
            e = dict(e); e["hooks"] = hs2
        out.append(e)
    if out:
        hooks[ev] = out
    else:
        del hooks[ev]
atomic_write_json(p, cfg)
print("  Codex hooks cleaned (exact-match only)")
PYEOF
  echo "• Codex: our hooks removed (backup made)"
fi

# Remove only our observation hooks from CodeBuddy.
CODEBUDDY_SETTINGS="${HOME_DIR}/.codebuddy/settings.json"
if [ -f "${CODEBUDDY_SETTINGS}" ]; then
  backup_json_file "${CODEBUDDY_SETTINGS}"
  OWNED_JSON="$("${PY}" -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${CODEBUDDY_CMD}")"
  OWNED_JSON="${OWNED_JSON}" "${PY}" - "${CODEBUDDY_SETTINGS}" <<'PYEOF'
import json, os, sys, uuid
p = os.path.realpath(sys.argv[1])
owned = set(json.loads(os.environ["OWNED_JSON"]))

def atomic_write_json(path, value):
    mode = os.stat(path).st_mode & 0o777
    temporary = f"{path}.agent-notch-{os.getpid()}-{uuid.uuid4().hex}.tmp"
    try:
        with open(temporary, "w") as output:
            json.dump(value, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
with open(p) as f:
    cfg = json.load(f)
if not isinstance(cfg, dict):
    print("  CodeBuddy hooks skipped (settings root is not an object)")
    sys.exit(0)
hooks = cfg.get("hooks", {})
if not isinstance(hooks, dict):
    print("  CodeBuddy hooks skipped (hooks is not an object)")
    sys.exit(0)

def command_of(hook):
    if not isinstance(hook, dict):
        return ""
    command = hook.get("command")
    return command.strip() if isinstance(command, str) else ""

for event in list(hooks):
    entries = hooks[event]
    if not isinstance(entries, list):
        continue
    cleaned = []
    for entry in entries:
        if not isinstance(entry, dict):
            cleaned.append(entry)
            continue
        nested = entry.get("hooks")
        if isinstance(nested, list):
            kept = [
                hook for hook in nested
                if command_of(hook) not in owned
            ]
            if not kept:
                continue
            entry = dict(entry)
            entry["hooks"] = kept
        cleaned.append(entry)
    if cleaned:
        hooks[event] = cleaned
    else:
        hooks.pop(event, None)
atomic_write_json(p, cfg)
PYEOF
  echo "• CodeBuddy: our observation hooks removed (backup made)"
fi

# Remove only our lifecycle helper from Claude. Native Agent Notch remains.
CLAUDE_SETTINGS="${CLAUDE_DIR}/settings.json"
if [ -f "${CLAUDE_SETTINGS}" ]; then
  backup_json_file "${CLAUDE_SETTINGS}"
  OWNED_JSON="$("${PY}" -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${CLAUDE_LIFECYCLE_CMD}" "${CLAUDE_INTERACTIVE_CMD}")"
  OWNED_JSON="${OWNED_JSON}" "${PY}" - "${CLAUDE_SETTINGS}" <<'PYEOF'
import json, os, sys, uuid
p = os.path.realpath(sys.argv[1])
owned = set(json.loads(os.environ["OWNED_JSON"]))

def atomic_write_json(path, value):
    mode = os.stat(path).st_mode & 0o777
    temporary = f"{path}.agent-notch-{os.getpid()}-{uuid.uuid4().hex}.tmp"
    try:
        with open(temporary, "w") as output:
            json.dump(value, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
with open(p) as f:
    cfg = json.load(f)
if not isinstance(cfg, dict):
    print("  Claude hooks skipped (settings root is not an object)")
    sys.exit(0)
hooks = cfg.get("hooks", {})
if not isinstance(hooks, dict):
    print("  Claude hooks skipped (hooks is not an object)")
    sys.exit(0)

def command_of(hook):
    if not isinstance(hook, dict):
        return ""
    command = hook.get("command")
    return command.strip() if isinstance(command, str) else ""

for event in list(hooks):
    entries = hooks[event]
    if not isinstance(entries, list):
        continue
    out = []
    for entry in entries:
        if not isinstance(entry, dict):
            out.append(entry)
            continue
        nested = entry.get("hooks")
        if isinstance(nested, list):
            kept = [
                hook for hook in nested
                if command_of(hook) not in owned
            ]
            if not kept:
                continue
            entry = dict(entry)
            entry["hooks"] = kept
        out.append(entry)
    if out:
        hooks[event] = out
    else:
        hooks.pop(event, None)
atomic_write_json(p, cfg)
PYEOF
  echo "• Claude: cleanup + interactive hooks removed (native hook kept)"
fi

# Remove synthetic transcripts we wrote into the selected Claude projects
# directory (tracked in an
# index so we never touch Claude's own session files).
IDX="${HOME_DIR}/.multiagent-notch/synthetic-files.txt"
if [ -f "${IDX}" ]; then
  n="$("${PY}" - "${IDX}" "${CLAUDE_DIR}/projects" <<'PYEOF'
import os, sys
index, root = sys.argv[1:]
root = os.path.realpath(root)
removed = 0
with open(index) as f:
    for raw in f:
        path = raw.strip()
        if not path:
            continue
        resolved = os.path.realpath(path)
        if os.path.commonpath((root, resolved)) != root:
            continue
        try:
            os.remove(resolved)
            removed += 1
        except FileNotFoundError:
            pass
print(removed)
PYEOF
)"
  echo "• removed ${n} synthetic Codex transcript(s)"
fi

# Stop only tmux sessions created by this project; never touch user sessions.
if command -v tmux >/dev/null 2>&1; then
  while IFS= read -r relay_session; do
    case "${relay_session}" in
      "${RELAY_PREFIX}"*) tmux kill-session -t "${relay_session}" 2>/dev/null || true ;;
    esac
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
  echo "• stopped Codex chat relay sessions"
fi

rm -rf "${HOME_DIR}/.multiagent-notch"
echo "• removed ~/.multiagent-notch"
echo "Done. (Claude's native Agent Notch hook was left untouched.)"
