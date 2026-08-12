#!/bin/bash
# Agent Notch Bridge installer
# Wires supported agents into the Agent Notch socket via the normalized bridge.
# Supported: Claude (native display hook + lifecycle helper), Codex, CodeBuddy.
#
# PermissionRequest ownership (per current official Codex Hooks docs):
#   Codex runs EVERY matching PermissionRequest hook concurrently and "any deny
#   wins". Decision hooks should be exclusive; known observation-only hooks may
#   coexist asynchronously so they cannot stall the approval. Unknown hooks are
#   treated as conflicts. Migrate explicitly with:
#     ./install.sh --migrate-permission "<exact old command>"   (repeatable)
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${HOME}"
STABLE_DIR="${HOME_DIR}/.multiagent-notch/bin"
BRIDGE_SRC="${REPO_DIR}/bin/notch-bridge.py"
BRIDGE_DST="${STABLE_DIR}/notch-bridge.py"
RELAY_DST="${STABLE_DIR}/codex-relay.py"
PY="/usr/bin/python3"   # stable interpreter, always present on macOS

# Exact commands this project owns across versions (basename substrings are NOT
# used — that would delete unrelated same-named scripts). Add future variants.
OUR_CMD="${PY} ${BRIDGE_DST} --source codex"
CODEBUDDY_CMD="${PY} ${BRIDGE_DST} --source codebuddy"
CLAUDE_LIFECYCLE_CMD="${PY} ${BRIDGE_DST} --source claude --lifecycle-only"
CLAUDE_INTERACTIVE_CMD="${PY} ${BRIDGE_DST} --source claude"
LEGACY_CMD="${PY} ${HOME_DIR}/.codex/hooks/vibe-notch-bridge.py"
VI_CLAUDE_CMD="/bin/sh -c '[ -x \"\$HOME/.vibe-island/bin/vibe-island-bridge\" ] && \"\$HOME/.vibe-island/bin/vibe-island-bridge\" --source claude; exit 0'"
VI_CODEX_CMD="/bin/sh -c '[ -x \"\$HOME/.vibe-island/bin/vibe-island-bridge\" ] && \"\$HOME/.vibe-island/bin/vibe-island-bridge\" --source codex; exit 0'"
VI_CLAUDE_ABS_CMD="'${HOME_DIR}/.vibe-island/bin/vibe-island-bridge' --source claude"
VI_CODEX_ABS_CMD="'${HOME_DIR}/.vibe-island/bin/vibe-island-bridge' --source codex"

# --- args --------------------------------------------------------------------
#   --migrate-permission "<cmd>"   remove this exact PR command (repeatable)
#   --take-permission              register ours as a PR owner even if benign
#                                  (observation-only) PR hooks still coexist.
#                                  Use ONLY when the real decision owner has been
#                                  migrated away — remaining hooks must not deny.
#   --replace-vibe-island          fully cut over: remove the known Vibe Island
#                                  bridge commands from Claude + Codex configs
#                                  and its Claude statusLine. Both are backed up.
MIGRATE_CMDS=()
TAKE_PERMISSION=0
REPLACE_VI=0
while [ $# -gt 0 ]; do
  case "$1" in
    --migrate-permission)
      [ $# -ge 2 ] || { echo "--migrate-permission requires a command"; exit 2; }
      MIGRATE_CMDS+=("$2"); shift 2
      ;;
    --take-permission) TAKE_PERMISSION=1; shift ;;
    --replace-vibe-island) REPLACE_VI=1; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

echo "=== Agent Notch Bridge installer ==="

# 1) Copy the bridge to a stable location (independent of repo path) ----------
mkdir -p "${STABLE_DIR}"
cp "${BRIDGE_SRC}" "${BRIDGE_DST}"
chmod 755 "${BRIDGE_DST}"
echo "• bridge installed -> ${BRIDGE_DST}"
# Current app replies through `codex exec resume` directly. Keep no hidden
# relay process or duplicate agent session alive from older installs.
rm -f "${RELAY_DST}" 2>/dev/null || true
if command -v tmux >/dev/null 2>&1; then
  while IFS= read -r relay_session; do
    case "$relay_session" in
      multiagent-notch-codex-*) tmux kill-session -t "$relay_session" 2>/dev/null || true ;;
    esac
  done < <(tmux list-sessions -F '#S' 2>/dev/null || true)
fi
echo "• Codex replies use direct CLI resume (legacy hidden relays removed)."

# 2) Claude Code -------------------------------------------------------------
# Agent Notch keeps owning display/approval. Our lifecycle-only hook emits no
# duplicate UI event; it only schedules/cancels completed-session cleanup.
if [ -f "${HOME_DIR}/.claude/hooks/agent-notch-state.py" ] ||
   [ -f "${HOME_DIR}/.claude/hooks/claude-island-state.py" ]; then
  CLAUDE_SETTINGS="${HOME_DIR}/.claude/settings.json"
  mkdir -p "$(dirname "${CLAUDE_SETTINGS}")"
  [ -f "${CLAUDE_SETTINGS}" ] || echo '{}' > "${CLAUDE_SETTINGS}"
  cp "${CLAUDE_SETTINGS}" "${CLAUDE_SETTINGS}.bak.$(date +%Y%m%dT%H%M%S)"
  VI_COMMANDS_JSON="$("${PY}" -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${VI_CLAUDE_CMD}" "${VI_CLAUDE_ABS_CMD}")"
  CLAUDE_CMD="${CLAUDE_LIFECYCLE_CMD}" CLAUDE_INTERACTIVE_CMD="${CLAUDE_INTERACTIVE_CMD}" VI_COMMANDS_JSON="${VI_COMMANDS_JSON}" VI_REPLACE="${REPLACE_VI}" \
  "${PY}" - "${CLAUDE_SETTINGS}" "${HOME_DIR}" <<'PYEOF'
import json, os, sys

p, home = sys.argv[1:]
our_cmd = os.environ["CLAUDE_CMD"]
interactive_cmd = os.environ["CLAUDE_INTERACTIVE_CMD"]
vi_commands = set(json.loads(os.environ["VI_COMMANDS_JSON"]))
replace_vi = os.environ.get("VI_REPLACE") == "1"

with open(p) as f:
    cfg = json.load(f)
hooks = cfg.setdefault("hooks", {})

def command_of(h):
    return (h.get("command") or "").strip()

def edit_event(event, add_ours):
    entries = hooks.get(event, [])
    entries = entries if isinstance(entries, list) else []
    out = []
    for entry in entries:
        nested = entry.get("hooks")
        if isinstance(nested, list):
            kept = []
            for hook in nested:
                command = command_of(hook)
                if command in (our_cmd, interactive_cmd):
                    continue
                # Approval decisions must have one owner. Migrate only the
                # exact known Vibe Island decision command from
                # PermissionRequest even during a normal install; retain its
                # observation hooks and status line unless full replacement
                # was explicitly requested.
                if command in vi_commands and (
                    replace_vi or event == "PermissionRequest"
                ):
                    continue
                kept.append(hook)
            if not kept:
                continue
            entry = dict(entry)
            entry["hooks"] = kept
        out.append(entry)
    if add_ours:
        out.append({"matcher": "*", "hooks": [{
            "type": "command", "command": our_cmd, "timeout": 5
        }]})
    if out:
        hooks[event] = out
    else:
        hooks.pop(event, None)

for event in list(hooks):
    edit_event(event, add_ours=False)
for event in ("SessionStart", "UserPromptSubmit", "PreToolUse",
              "PostToolUse", "Stop"):
    edit_event(event, add_ours=True)

# Structured interactions need a blocking PreToolUse round trip. The native
# Agent Notch hook remains the display observer; this narrowly-scoped hook owns
# only AskUserQuestion and ExitPlanMode answers.
hooks.setdefault("PreToolUse", []).append({
    "matcher": "AskUserQuestion|ExitPlanMode",
    "hooks": [{
        "type": "command",
        "command": interactive_cmd,
        "timeout": 105,
    }],
})

if replace_vi:
    status_line = cfg.get("statusLine")
    if isinstance(status_line, dict):
        command = (status_line.get("command") or "").strip()
        known = {
            os.path.join(home, ".vibe-island/bin/vibe-island-statusline"),
            "$HOME/.vibe-island/bin/vibe-island-statusline",
        }
        if command in known:
            cfg.pop("statusLine", None)

with open(p, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
  echo "• Claude: Agent Notch owns PermissionRequest; known Vibe Island decision hook migrated."
  echo "          Other Vibe Island observation hooks stay installed."
  if [ "${REPLACE_VI}" = "1" ]; then
    echo "• Claude: known Vibe Island hooks/statusLine removed (backup made)."
  fi
else
  echo "• Claude: Agent Notch native hook not found — launch Agent Notch.app once"
fi

# 3) Codex -------------------------------------------------------------------
CODEX_HOOKS="${HOME_DIR}/.codex/hooks.json"
if command -v codex >/dev/null 2>&1 || [ -f "${CODEX_HOOKS}" ]; then
  mkdir -p "$(dirname "${CODEX_HOOKS}")"
  [ -f "${CODEX_HOOKS}" ] || echo '{"hooks":{}}' > "${CODEX_HOOKS}"
  cp "${CODEX_HOOKS}" "${CODEX_HOOKS}.bak.$(date +%Y%m%dT%H%M%S)"

  # Build JSON args for the python editor.
  OWNED_JSON="$("${PY}" -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${OUR_CMD}" "${LEGACY_CMD}")"
  MIGRATE_JSON="$("${PY}" -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${MIGRATE_CMDS[@]}")"
  VI_COMMANDS_JSON="$("${PY}" -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${VI_CODEX_CMD}" "${VI_CODEX_ABS_CMD}")"

  PY_OUT="$(OUR_CMD="${OUR_CMD}" OWNED_JSON="${OWNED_JSON}" MIGRATE_JSON="${MIGRATE_JSON}" VI_COMMANDS_JSON="${VI_COMMANDS_JSON}" TAKE="${TAKE_PERMISSION}" VI_REPLACE="${REPLACE_VI}" \
  "${PY}" - "$CODEX_HOOKS" <<'PYEOF'
import json, os, re, sys

p = sys.argv[1]
our_cmd  = os.environ["OUR_CMD"]
owned    = set(json.loads(os.environ["OWNED_JSON"]))     # exact commands we own
migrate  = set(json.loads(os.environ["MIGRATE_JSON"]))   # exact cmds user removes
vi_commands = set(json.loads(os.environ["VI_COMMANDS_JSON"]))

with open(p) as f:
    cfg = json.load(f)
hooks = cfg.setdefault("hooks", {})

def cmd_of(h):
    return (h.get("command") or "").strip()

def strip_cmds(entries, remove):
    """Remove hooks whose EXACT command is in `remove`; drop empties."""
    out = []
    for e in entries:
        hs = e.get("hooks")
        if isinstance(hs, list):
            hs2 = [h for h in hs if cmd_of(h) not in remove]
            if not hs2:
                continue
            e = dict(e); e["hooks"] = hs2
        out.append(e)
    return out

def our_entry(timeout):
    return {"hooks": [{"type": "command", "command": our_cmd, "timeout": timeout}]}

def is_known_observer(command):
    """Known telemetry hook that never returns an approval decision.

    Keep this deliberately strict. Generic substring matching here could
    silently turn an unknown decision hook into a co-owner.
    """
    return re.fullmatch(
        r"/.+/agentwatch/\.venv/bin/python(?:3)? -m "
        r"agentwatch\.cli hook --event PermissionRequest",
        command,
    ) is not None

def make_known_observers_async(entries):
    """Make vetted notification-only hooks non-blocking for Codex.

    Official Codex behavior guarantees async hooks cannot approve or deny.
    """
    output = []
    for entry in entries:
        updated_entry = dict(entry)
        nested = entry.get("hooks")
        if isinstance(nested, list):
            updated_hooks = []
            for hook in nested:
                updated_hook = dict(hook)
                if is_known_observer(cmd_of(hook)):
                    updated_hook["async"] = True
                updated_hooks.append(updated_hook)
            updated_entry["hooks"] = updated_hooks
        output.append(updated_entry)
    return output

# --- optional full cut-over: strip ALL vibe-island hooks (named removal) ----- #
if os.environ.get("VI_REPLACE") == "1":
    dropped = 0
    for ev in list(hooks.keys()):
        ents = hooks[ev]
        if not isinstance(ents, list):
            continue
        out = []
        for e in ents:
            hs = e.get("hooks")
            if isinstance(hs, list):
                before = len(hs)
                hs2 = [h for h in hs if cmd_of(h) not in vi_commands]
                dropped += before - len(hs2)
                if not hs2:
                    continue
                e = dict(e); e["hooks"] = hs2
            out.append(e)
        if out:
            hooks[ev] = out
        else:
            del hooks[ev]
    print("VI_DROPPED=%d" % dropped)

# --- observation events: safe to coexist; always (re)register ours ---------- #
OBS = {"SessionStart": 5, "UserPromptSubmit": 5, "PreToolUse": 10,
       "PostToolUse": 5, "Stop": 5, "SubagentStop": 5}
for ev, t in OBS.items():
    cur = hooks.get(ev, [])
    cur = cur if isinstance(cur, list) else []
    cur = strip_cmds(cur, owned)          # remove our old copies (exact)
    cur.append(our_entry(t))
    hooks[ev] = cur

# --- PermissionRequest: exclusive decision owner --------------------------- #
pr = hooks.get("PermissionRequest", [])
pr = pr if isinstance(pr, list) else []
pr = strip_cmds(pr, owned | migrate)      # remove our old + user-migrated cmds
pr = make_known_observers_async(pr)

# any remaining PR hook is a foreign potential decision owner
remaining = [cmd_of(h) for e in pr for h in e.get("hooks", []) if cmd_of(h)]
take = os.environ.get("TAKE") == "1"
observer_only = bool(remaining) and all(is_known_observer(c) for c in remaining)
perm_status = "registered"
conflicts = []
if remaining and not take and not observer_only:
    perm_status = "skipped_conflict"
    conflicts = sorted(set(remaining))
else:
    if observer_only:
        perm_status = "registered_observer_coexist"
        conflicts = sorted(set(remaining))
    elif remaining:                  # explicit override; caller accepts the risk
        perm_status = "registered_coexist"
        conflicts = sorted(set(remaining))
    pr.append(our_entry(105))
hooks["PermissionRequest"] = pr
if not hooks["PermissionRequest"]:
    del hooks["PermissionRequest"]

with open(p, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

# machine-readable summary for the shell
print("PERM_STATUS=%s" % perm_status)
print("OBS_COUNT=%d" % len(OBS))
for c in conflicts:
    print("CONFLICT=%s" % c)
PYEOF
)"
  echo "• Codex: observation hooks wired (6 events)."
  PERM_STATUS="$(printf '%s\n' "$PY_OUT" | sed -n 's/^PERM_STATUS=//p')"
  if [ "$PERM_STATUS" = "registered" ]; then
    echo "• Codex: PermissionRequest → sole owner within ~/.codex/hooks.json ✅"
  elif [ "$PERM_STATUS" = "registered_observer_coexist" ]; then
    echo "• Codex: PermissionRequest → Agent Notch owns approvals ✅ (known observer retained):"
    while IFS= read -r line; do
      case "$line" in CONFLICT=*) echo "    - ${line#CONFLICT=}" ;; esac
    done <<< "$PY_OUT"
  elif [ "$PERM_STATUS" = "registered_coexist" ]; then
    echo "• Codex: PermissionRequest → Agent Notch owns approvals ✅ (coexisting hooks must be observation-only):"
    while IFS= read -r line; do
      case "$line" in CONFLICT=*) echo "    - ${line#CONFLICT=}" ;; esac
    done <<< "$PY_OUT"
  else
    echo "• Codex: PermissionRequest → SKIPPED (another approval hook already owns it):"
    while IFS= read -r line; do
      case "$line" in
        CONFLICT=*) echo "    - ${line#CONFLICT=}" ;;
      esac
    done <<< "$PY_OUT"
    echo "    To let Agent Notch own approvals instead, re-run with (per command):"
    while IFS= read -r line; do
      case "$line" in
        CONFLICT=*) printf '      ./install.sh --migrate-permission %s\n' "\"${line#CONFLICT=}\"" ;;
      esac
    done <<< "$PY_OUT"
  fi
else
  echo "• Codex: not detected — skipped"
fi

# 4) CodeBuddy ---------------------------------------------------------------
# CodeBuddy's hook schema is Claude-compatible, but it has no PermissionRequest
# event. Register observation hooks only; its native permission UI remains the
# sole decision owner.
CODEBUDDY_SETTINGS="${HOME_DIR}/.codebuddy/settings.json"
if command -v codebuddy >/dev/null 2>&1 || [ -f "${CODEBUDDY_SETTINGS}" ]; then
  mkdir -p "$(dirname "${CODEBUDDY_SETTINGS}")"
  [ -f "${CODEBUDDY_SETTINGS}" ] || echo '{}' > "${CODEBUDDY_SETTINGS}"
  cp "${CODEBUDDY_SETTINGS}" "${CODEBUDDY_SETTINGS}.bak.$(date +%Y%m%dT%H%M%S)"

  CODEBUDDY_CMD="${CODEBUDDY_CMD}" "${PY}" - "${CODEBUDDY_SETTINGS}" <<'PYEOF'
import json, os, sys

p = sys.argv[1]
our_cmd = os.environ["CODEBUDDY_CMD"]
with open(p) as f:
    cfg = json.load(f)
hooks = cfg.setdefault("hooks", {})

def command_of(hook):
    return (hook.get("command") or "").strip()

def strip_ours(entries):
    entries = entries if isinstance(entries, list) else []
    cleaned = []
    for entry in entries:
        nested = entry.get("hooks")
        if isinstance(nested, list):
            kept = [hook for hook in nested if command_of(hook) != our_cmd]
            if not kept:
                continue
            entry = dict(entry)
            entry["hooks"] = kept
        cleaned.append(entry)
    return cleaned

for event in list(hooks):
    cleaned = strip_ours(hooks[event])
    if cleaned:
        hooks[event] = cleaned
    else:
        hooks.pop(event, None)

events = {
    "SessionStart": 5,
    "UserPromptSubmit": 5,
    "PreToolUse": 10,
    "PostToolUse": 5,
    "PreCompact": 5,
    "Stop": 5,
    "SessionEnd": 5,
}
for event, timeout in events.items():
    entry = {
        "hooks": [{
            "type": "command",
            "command": our_cmd,
            "timeout": timeout,
        }]
    }
    if event in ("PreToolUse", "PostToolUse"):
        entry["matcher"] = "*"
    hooks.setdefault(event, []).append(entry)

with open(p, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
  echo "• CodeBuddy: observation hooks wired (7 events; native approvals kept)."
else
  echo "• CodeBuddy: not detected — skipped"
fi

# 5) Clean up the earlier ad-hoc bridge copy, if present ----------------------
rm -f "${HOME_DIR}/.codex/hooks/vibe-notch-bridge.py" \
      "${HOME_DIR}/.codex/hooks/vibe-notch-bridge.log" 2>/dev/null || true

cat <<EOF

=== Done ===
Claude  : native Agent Notch display + timed completed-session cleanup.
Codex   : observation events wired. For it to actually fire, do the TWO one-time
          steps in docs/codex-trust.md (restart Codex + trust the hook).
CodeBuddy: observation events wired; restart CodeBuddy/WorkBuddy once so new
           sessions load ~/.codebuddy/settings.json. Native approvals stay native.

Cleanup : Stop sessions stay visible for NOTCH_COMPLETED_TTL seconds (default
          18000 / five hours). Any new activity cancels removal; active
          projects never expire.

If PermissionRequest was SKIPPED due to a conflict, migrate explicitly, e.g.:
  ./install.sh --migrate-permission "<the exact conflicting command printed above>"

Verify:  export NOTCH_BRIDGE_DEBUG=1  (in the shell that launches Codex)
         cat ~/.multiagent-notch/logs/codex.log   # after a Codex action
EOF
