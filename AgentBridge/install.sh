#!/bin/bash
# Agent Notch Bridge installer
# Wires supported agents into the Agent Notch socket via the normalized bridge.
# Supported: Claude (native display hook + lifecycle helper), Codex, CodeBuddy.
#
# PermissionRequest ownership within the user config edited by this installer
# (per current official Codex Hooks docs):
#   Codex runs EVERY matching PermissionRequest hook concurrently and "any deny
#   wins". Decision hooks should be exclusive; known observation-only hooks may
#   coexist asynchronously so they cannot stall the approval. Unknown hooks are
#   treated as conflicts. Migrate only after supplying the reviewed exact old
#   command as one literal --migrate-permission argument (repeatable).
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${HOME}"
CLAUDE_DIR="${AGENT_NOTCH_CLAUDE_DIR:-${CLAUDE_CONFIG_DIR:-${HOME_DIR}/.claude}}"
STABLE_DIR="${HOME_DIR}/.multiagent-notch/bin"
BRIDGE_SRC="${REPO_DIR}/bin/notch-bridge.py"
BRIDGE_DST="${STABLE_DIR}/notch-bridge.py"
RELAY_DST="${STABLE_DIR}/codex-relay.py"
PY="/usr/bin/python3"   # stable interpreter, always present on macOS

# Apps launched from Finder inherit launchd's minimal PATH rather than the
# user's interactive shell. Include the conventional CLI install locations
# before probing Codex, CodeBuddy, or optional tmux.
PATH="${HOME_DIR}/.local/bin:${HOME_DIR}/.codex/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"
export PATH

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
#   --replace-vibe-island          fully cut over: remove the known Vibe Island
#                                  bridge commands from Claude + Codex configs
#                                  and its Claude statusLine. Both are backed up.
MIGRATE_CMDS=()
REPLACE_VI=0
OVERALL_STATUS="complete"
while [ $# -gt 0 ]; do
  case "$1" in
    --migrate-permission)
      [ $# -ge 2 ] || { echo "--migrate-permission requires a command"; exit 2; }
      MIGRATE_CMDS+=("$2"); shift 2
      ;;
    --replace-vibe-island) REPLACE_VI=1; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

echo "=== Agent Notch Bridge installer ==="

ensure_json_file() {
  local path="$1"
  local temporary="${path}.agent-notch-$$.tmp"
  mkdir -p "$(dirname "${path}")"
  if [ -L "${path}" ] && [ ! -e "${path}" ]; then
    echo "Refusing to replace dangling settings symlink: ${path}" >&2
    return 1
  fi
  if [ ! -f "${path}" ]; then
    (umask 077; printf '{}\n' > "${temporary}")
    mv "${temporary}" "${path}"
  fi
}

backup_json_file() {
  local path="$1"
  cp -p "${path}" "${path}.bak.$(date +%Y%m%dT%H%M%S).$$"
}

# 1) Copy the bridge to a stable location (independent of repo path) ----------
mkdir -p "${STABLE_DIR}"
chmod 700 "${HOME_DIR}/.multiagent-notch" "${STABLE_DIR}"
BRIDGE_TMP="${BRIDGE_DST}.agent-notch-$$.tmp"
cp "${BRIDGE_SRC}" "${BRIDGE_TMP}"
chmod 755 "${BRIDGE_TMP}"
mv "${BRIDGE_TMP}" "${BRIDGE_DST}"
echo "• bridge installed -> ${BRIDGE_DST}"

# Persist the Claude config root used by the app. Codex and CodeBuddy hooks do
# not necessarily inherit CLAUDE_CONFIG_DIR, but their synthetic transcripts
# still need to land in the directory Agent Notch is actually watching.
BRIDGE_CONFIG="${HOME_DIR}/.multiagent-notch/config.json"
BRIDGE_CONFIG_TMP="${BRIDGE_CONFIG}.agent-notch-$$.tmp"
CLAUDE_DIR_VALUE="${CLAUDE_DIR}" "${PY}" - "${BRIDGE_CONFIG_TMP}" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
with open(path, "w") as output:
    json.dump({"claude_config_dir": os.environ["CLAUDE_DIR_VALUE"]}, output)
    output.write("\n")
    output.flush()
    os.fsync(output.fileno())
os.chmod(path, 0o600)
PYEOF
mv "${BRIDGE_CONFIG_TMP}" "${BRIDGE_CONFIG}"
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
# duplicate UI event; it only maintains expiry markers. The app performs the
# actual periodic cleanup, so no five-hour sleeper process is created.
if [ -f "${CLAUDE_DIR}/hooks/agent-notch-state.py" ] ||
  [ -f "${CLAUDE_DIR}/hooks/claude-island-state.py" ]; then
  CLAUDE_SETTINGS="${CLAUDE_DIR}/settings.json"
  ensure_json_file "${CLAUDE_SETTINGS}"
  backup_json_file "${CLAUDE_SETTINGS}"
  VI_COMMANDS_JSON="$("${PY}" -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${VI_CLAUDE_CMD}" "${VI_CLAUDE_ABS_CMD}")"
  CLAUDE_OUT="$(CLAUDE_CMD="${CLAUDE_LIFECYCLE_CMD}" CLAUDE_INTERACTIVE_CMD="${CLAUDE_INTERACTIVE_CMD}" VI_COMMANDS_JSON="${VI_COMMANDS_JSON}" VI_REPLACE="${REPLACE_VI}" \
  "${PY}" - "${CLAUDE_SETTINGS}" "${HOME_DIR}" "${CLAUDE_DIR}" <<'PYEOF'
import json, os, shlex, sys, uuid

p, home, claude_dir = sys.argv[1:]
p = os.path.realpath(p)
our_cmd = os.environ["CLAUDE_CMD"]
interactive_cmd = os.environ["CLAUDE_INTERACTIVE_CMD"]
vi_commands = set(json.loads(os.environ["VI_COMMANDS_JSON"]))
replace_vi = os.environ.get("VI_REPLACE") == "1"

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
    print("CLAUDE_PERM_STATUS=skipped_conflict")
    print("CLAUDE_CONFIG_CONFLICT=<settings root must be an object>")
    sys.exit(0)
hooks = cfg.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print("CLAUDE_PERM_STATUS=skipped_conflict")
    print("CLAUDE_CONFIG_CONFLICT=<hooks must be an object>")
    sys.exit(0)
claude_config_conflicts = []

def command_of(h):
    if not isinstance(h, dict):
        return ""
    command = h.get("command")
    return command.strip() if isinstance(command, str) else ""

def is_agent_notch_native(command):
    try:
        parts = shlex.split(command)
    except ValueError:
        return False
    if len(parts) != 2 or os.path.basename(parts[0]) not in ("python", "python3"):
        return False
    script = os.path.normpath(os.path.expanduser(parts[1]))
    return script in {
        os.path.normpath(os.path.join(claude_dir, "hooks", "agent-notch-state.py")),
        os.path.normpath(os.path.join(claude_dir, "hooks", "claude-island-state.py")),
    }

def edit_event(event, add_ours):
    entries = hooks.get(event, [])
    if not isinstance(entries, list):
        claude_config_conflicts.append(f"<{event} must be a list>")
        return
    out = []
    for entry in entries:
        if not isinstance(entry, dict):
            out.append(entry)
            continue
        nested = entry.get("hooks")
        if isinstance(nested, list):
            kept = []
            for hook in nested:
                if not isinstance(hook, dict):
                    kept.append(hook)
                    continue
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

# PermissionRequest should have one synchronous decision owner. This standalone
# installer enforces that invariant within the selected user settings file;
# other Claude configuration scopes remain outside its visibility.
claude_perm_status = "native_missing"
claude_conflicts = []
raw_permission_entries = hooks.get("PermissionRequest", [])
permission_entries_valid = isinstance(raw_permission_entries, list)
permission_entries = raw_permission_entries if permission_entries_valid else []
native_present = False
if not permission_entries_valid:
    claude_conflicts.append("<PermissionRequest must be a list>")
for entry in permission_entries:
    if not isinstance(entry, dict):
        claude_conflicts.append("<unrecognized PermissionRequest entry>")
        continue
    nested = entry.get("hooks")
    if not isinstance(nested, list):
        claude_conflicts.append("<unrecognized PermissionRequest entry>")
        continue
    for hook in nested:
        if not isinstance(hook, dict):
            claude_conflicts.append("<unrecognized PermissionRequest hook>")
            continue
        command = command_of(hook)
        if is_agent_notch_native(command):
            native_present = True
        elif hook.get("async") is not True:
            claude_conflicts.append(
                command or "<non-string/non-command synchronous hook>"
            )

if claude_conflicts:
    cleaned = []
    for entry in permission_entries:
        if not isinstance(entry, dict):
            cleaned.append(entry)
            continue
        nested = entry.get("hooks")
        if not isinstance(nested, list):
            cleaned.append(entry)
            continue
        kept = [hook for hook in nested if not is_agent_notch_native(command_of(hook))]
        if kept:
            updated = dict(entry)
            updated["hooks"] = kept
            cleaned.append(updated)
    if cleaned:
        hooks["PermissionRequest"] = cleaned
    else:
        hooks.pop("PermissionRequest", None)
    claude_perm_status = "skipped_conflict"
elif native_present:
    claude_perm_status = "registered"

# Structured interactions need a blocking PreToolUse round trip. The native
# Agent Notch hook remains the display observer; this narrowly-scoped hook owns
# only AskUserQuestion and ExitPlanMode answers.
pretool_entries = hooks.get("PreToolUse", [])
if isinstance(pretool_entries, list):
    pretool_entries.append({
        "matcher": "AskUserQuestion|ExitPlanMode",
        "hooks": [{
            "type": "command",
            "command": interactive_cmd,
            "timeout": 105,
        }],
    })
    hooks["PreToolUse"] = pretool_entries
else:
    claude_config_conflicts.append("<PreToolUse must be a list>")

if replace_vi:
    status_line = cfg.get("statusLine")
    if isinstance(status_line, dict):
        raw_command = status_line.get("command")
        command = raw_command.strip() if isinstance(raw_command, str) else ""
        known = {
            os.path.join(home, ".vibe-island/bin/vibe-island-statusline"),
            "$HOME/.vibe-island/bin/vibe-island-statusline",
        }
        if command in known:
            cfg.pop("statusLine", None)

atomic_write_json(p, cfg)
print("CLAUDE_PERM_STATUS=" + claude_perm_status)
for conflict in sorted(set(claude_conflicts)):
    print("CLAUDE_CONFLICT=" + conflict)
for conflict in sorted(set(claude_config_conflicts)):
    print("CLAUDE_CONFIG_CONFLICT=" + conflict)
PYEOF
  )"
  CLAUDE_PERM_STATUS="$(printf '%s\n' "$CLAUDE_OUT" | sed -n 's/^CLAUDE_PERM_STATUS=//p')"
  if [ "${CLAUDE_PERM_STATUS}" = "registered" ]; then
    echo "• Claude: Agent Notch owns PermissionRequest in the selected user settings file."
    echo "          Other Claude configuration scopes may still add hooks at runtime."
  else
    OVERALL_STATUS="partial"
    echo "• Claude: PermissionRequest → SKIPPED (another synchronous owner remains):"
    while IFS= read -r line; do
      case "$line" in CLAUDE_CONFLICT=*) echo "    - ${line#CLAUDE_CONFLICT=}" ;; esac
    done <<< "$CLAUDE_OUT"
  fi
  if printf '%s\n' "${CLAUDE_OUT}" | grep -q '^CLAUDE_CONFIG_CONFLICT='; then
    OVERALL_STATUS="partial"
    echo "• Claude: incompatible hook schemas were preserved and skipped:"
    while IFS= read -r line; do
      case "$line" in CLAUDE_CONFIG_CONFLICT=*) echo "    - ${line#CLAUDE_CONFIG_CONFLICT=}" ;; esac
    done <<< "${CLAUDE_OUT}"
  fi
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
  ensure_json_file "${CODEX_HOOKS}"
  backup_json_file "${CODEX_HOOKS}"

  # Build JSON args for the python editor.
  OWNED_JSON="$("${PY}" -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${OUR_CMD}" "${LEGACY_CMD}")"
  MIGRATE_JSON="$("${PY}" -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${MIGRATE_CMDS[@]}")"
  VI_COMMANDS_JSON="$("${PY}" -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${VI_CODEX_CMD}" "${VI_CODEX_ABS_CMD}")"

  PY_OUT="$(OUR_CMD="${OUR_CMD}" OWNED_JSON="${OWNED_JSON}" MIGRATE_JSON="${MIGRATE_JSON}" VI_COMMANDS_JSON="${VI_COMMANDS_JSON}" VI_REPLACE="${REPLACE_VI}" \
  "${PY}" - "$CODEX_HOOKS" <<'PYEOF'
import json, os, re, sys, uuid

p = os.path.realpath(sys.argv[1])
our_cmd  = os.environ["OUR_CMD"]
owned    = set(json.loads(os.environ["OWNED_JSON"]))     # exact commands we own
migrate  = set(json.loads(os.environ["MIGRATE_JSON"]))   # exact cmds user removes
vi_commands = set(json.loads(os.environ["VI_COMMANDS_JSON"]))

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
    print("PERM_STATUS=skipped_conflict")
    print("CONFIG_CONFLICT=<settings root must be an object>")
    sys.exit(0)
hooks = cfg.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print("PERM_STATUS=skipped_conflict")
    print("CONFIG_CONFLICT=<hooks must be an object>")
    sys.exit(0)
config_conflicts = []

def cmd_of(h):
    if not isinstance(h, dict):
        return ""
    command = h.get("command")
    return command.strip() if isinstance(command, str) else ""

def strip_cmds(entries, remove):
    """Remove hooks whose EXACT command is in `remove`; drop empties."""
    out = []
    for e in entries:
        if not isinstance(e, dict):
            out.append(e)
            continue
        hs = e.get("hooks")
        if isinstance(hs, list):
            hs2 = [
                h for h in hs
                if not isinstance(h, dict) or cmd_of(h) not in remove
            ]
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
        if not isinstance(entry, dict):
            output.append(entry)
            continue
        updated_entry = dict(entry)
        nested = entry.get("hooks")
        if isinstance(nested, list):
            updated_hooks = []
            for hook in nested:
                if not isinstance(hook, dict):
                    updated_hooks.append(hook)
                    continue
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
            if not isinstance(e, dict):
                out.append(e)
                continue
            hs = e.get("hooks")
            if isinstance(hs, list):
                before = len(hs)
                hs2 = [
                    h for h in hs
                    if not isinstance(h, dict) or cmd_of(h) not in vi_commands
                ]
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
OBS = {
    "SessionStart": 5,
    "UserPromptSubmit": 5,
    "PreToolUse": 10,
    "PostToolUse": 5,
    "PreCompact": 5,
    "PostCompact": 5,
    "Stop": 5,
    "SessionEnd": 5,
    "SubagentStart": 5,
    "SubagentStop": 5,
}
for ev, t in OBS.items():
    cur = hooks.get(ev, [])
    if not isinstance(cur, list):
        config_conflicts.append(f"<{ev} must be a list>")
        continue
    cur = strip_cmds(cur, owned)          # remove our old copies (exact)
    if ev == "Stop":
        # The known Vibe Island Codex Stop bridge prints continue=true, which
        # Codex 0.145 rejects in real TTY turns. Only its two exact commands
        # are migrated here; all other observation hooks remain untouched.
        cur = strip_cmds(cur, vi_commands)
    cur.append(our_entry(t))
    hooks[ev] = cur

# --- PermissionRequest: one decision owner within this user file ----------- #
raw_pr = hooks.get("PermissionRequest", [])
pr_is_list = isinstance(raw_pr, list)
pr = strip_cmds(raw_pr, owned | migrate | vi_commands) if pr_is_list else raw_pr
# The two known Vibe Island decision commands are exact-migrated by default.
# Commands that merely contain a similar basename remain foreign conflicts.
if pr_is_list:
    pr = make_known_observers_async(pr)

def permission_conflicts(entries):
    conflicts = []
    for entry_index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            conflicts.append(f"<unrecognized entry {entry_index}>")
            continue
        nested = entry.get("hooks")
        if not isinstance(nested, list):
            conflicts.append(f"<entry {entry_index} has no hooks list>")
            continue
        for hook_index, hook in enumerate(nested):
            if not isinstance(hook, dict):
                conflicts.append(
                    f"<unrecognized hook {entry_index}:{hook_index}>"
                )
                continue
            command = cmd_of(hook)
            # This exact AgentWatch command is the only audited observer. The
            # installer forces it async above; every other hook can decide.
            if is_known_observer(command) and hook.get("async") is True:
                continue
            conflicts.append(
                command or f"<hook {entry_index}:{hook_index} has no command>"
            )
    return sorted(set(conflicts))

conflicts = (
    permission_conflicts(pr)
    if pr_is_list
    else ["<PermissionRequest must be a list>"]
)
if pr_is_list:
    if pr:
        hooks["PermissionRequest"] = pr
    else:
        hooks.pop("PermissionRequest", None)
observer_commands = []
if pr_is_list and not conflicts:
    observer_commands = [
        cmd_of(hook)
        for entry in pr
        for hook in entry.get("hooks", [])
        if isinstance(hook, dict) and is_known_observer(cmd_of(hook))
    ]
perm_status = "registered"
if conflicts:
    perm_status = "skipped_conflict"
else:
    if observer_commands:
        perm_status = "registered_observer_coexist"
    pr.append(our_entry(105))
    hooks["PermissionRequest"] = pr

atomic_write_json(p, cfg)

# machine-readable summary for the shell
print("PERM_STATUS=%s" % perm_status)
print("OBS_COUNT=%d" % len(OBS))
for c in conflicts:
    print("CONFLICT=%s" % c)
for c in sorted(set(config_conflicts)):
    print("CONFIG_CONFLICT=%s" % c)
PYEOF
)"
  echo "• Codex: observation hooks wired (10 events)."
  PERM_STATUS="$(printf '%s\n' "$PY_OUT" | sed -n 's/^PERM_STATUS=//p')"
  if [ "$PERM_STATUS" = "registered" ]; then
    echo "• Codex: PermissionRequest → user-file owner in ~/.codex/hooks.json ✅"
    echo "         Plugin, project, or managed scopes may still add runtime hooks."
  elif [ "$PERM_STATUS" = "registered_observer_coexist" ]; then
    echo "• Codex: PermissionRequest → user-file owner (known observer retained) ✅"
    echo "         Plugin, project, or managed scopes may still add runtime hooks."
    while IFS= read -r line; do
      case "$line" in CONFLICT=*) echo "    - ${line#CONFLICT=}" ;; esac
    done <<< "$PY_OUT"
  else
    OVERALL_STATUS="partial"
    echo "• Codex: PermissionRequest → SKIPPED (another approval hook already owns it):"
    while IFS= read -r line; do
      case "$line" in
        CONFLICT=*) echo "    - ${line#CONFLICT=}" ;;
      esac
    done <<< "$PY_OUT"
    echo "    To migrate one owner, copy its exact command from the list above and"
    echo "    pass it as ONE literal --migrate-permission argument. Review it first;"
    echo "    the installer deliberately does not print executable shell commands."
    while IFS= read -r line; do
      case "$line" in
        CONFLICT=*) printf '      argument JSON: %s\n' "$(CONFLICT_VALUE="${line#CONFLICT=}" "${PY}" -c 'import json,os; print(json.dumps(os.environ["CONFLICT_VALUE"]))')" ;;
      esac
    done <<< "$PY_OUT"
  fi
  if printf '%s\n' "${PY_OUT}" | grep -q '^CONFIG_CONFLICT='; then
    OVERALL_STATUS="partial"
    echo "• Codex: incompatible hook schemas were preserved and skipped:"
    while IFS= read -r line; do
      case "$line" in CONFIG_CONFLICT=*) echo "    - ${line#CONFIG_CONFLICT=}" ;; esac
    done <<< "${PY_OUT}"
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
  ensure_json_file "${CODEBUDDY_SETTINGS}"
  backup_json_file "${CODEBUDDY_SETTINGS}"

  CODEBUDDY_OUT="$(CODEBUDDY_CMD="${CODEBUDDY_CMD}" "${PY}" - "${CODEBUDDY_SETTINGS}" <<'PYEOF'
import json, os, sys, uuid

p = os.path.realpath(sys.argv[1])
our_cmd = os.environ["CODEBUDDY_CMD"]

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
    print("CODEBUDDY_CONFLICT=<settings root must be an object>")
    sys.exit(0)
hooks = cfg.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print("CODEBUDDY_CONFLICT=<hooks must be an object>")
    sys.exit(0)

def command_of(hook):
    if not isinstance(hook, dict):
        return ""
    command = hook.get("command")
    return command.strip() if isinstance(command, str) else ""

def strip_ours(entries):
    entries = entries if isinstance(entries, list) else []
    cleaned = []
    for entry in entries:
        if not isinstance(entry, dict):
            cleaned.append(entry)
            continue
        nested = entry.get("hooks")
        if isinstance(nested, list):
            kept = [
                hook for hook in nested
                if not isinstance(hook, dict) or command_of(hook) != our_cmd
            ]
            if not kept:
                continue
            entry = dict(entry)
            entry["hooks"] = kept
        cleaned.append(entry)
    return cleaned

for event in list(hooks):
    if not isinstance(hooks[event], list):
        continue
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
    "PostCompact": 5,
    "Stop": 5,
    "SessionEnd": 5,
    "SubagentStart": 5,
    "SubagentStop": 5,
}
codebuddy_conflicts = []
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
    existing = hooks.get(event, [])
    if not isinstance(existing, list):
        # Preserve unfamiliar schemas instead of replacing user-owned data.
        codebuddy_conflicts.append(event)
        continue
    existing.append(entry)
    hooks[event] = existing

atomic_write_json(p, cfg)
for event in codebuddy_conflicts:
    print("CODEBUDDY_CONFLICT=" + event)
PYEOF
  )"
  if printf '%s\n' "${CODEBUDDY_OUT}" | grep -q '^CODEBUDDY_CONFLICT='; then
    OVERALL_STATUS="partial"
    echo "• CodeBuddy: incompatible event schemas preserved; skipped events:"
    while IFS= read -r line; do
      case "$line" in CODEBUDDY_CONFLICT=*) echo "    - ${line#CODEBUDDY_CONFLICT=}" ;; esac
    done <<< "${CODEBUDDY_OUT}"
  fi
  echo "• CodeBuddy: observation hooks wired where compatible; native approvals kept."
else
  echo "• CodeBuddy: not detected — skipped"
fi

# 5) Clean up the earlier ad-hoc bridge copy, if present ----------------------
rm -f "${HOME_DIR}/.codex/hooks/vibe-notch-bridge.py" \
      "${HOME_DIR}/.codex/hooks/vibe-notch-bridge.log" 2>/dev/null || true

cat <<EOF

=== Done ===
Claude  : native Agent Notch display + expiry-marker lifecycle helper.
Codex   : observation events wired. For it to actually fire, do the TWO one-time
          steps in docs/codex-trust.md (restart Codex + trust the hook).
CodeBuddy: observation events wired; restart CodeBuddy/WorkBuddy once so new
           sessions load ~/.codebuddy/settings.json. Native approvals stay native.

Cleanup : Stop sessions stay visible for NOTCH_COMPLETED_TTL seconds (default
          18000 / five hours). Agent Notch's periodic scan removes them; bridge
          markers are processed by later events, without sleeper processes.

If PermissionRequest was SKIPPED, review the conflict text and pass the exact
command as one literal --migrate-permission argument. The installer intentionally
does not generate a copy-paste shell command from configuration content.

Verify:  export NOTCH_BRIDGE_DEBUG=1  (in the shell that launches Codex)
         cat ~/.multiagent-notch/logs/codex.log   # after a Codex action
EOF

echo "AGENT_NOTCH_INSTALL_STATUS=${OVERALL_STATUS}"
