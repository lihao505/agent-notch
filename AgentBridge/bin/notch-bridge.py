#!/usr/bin/env python3
"""
Agent Notch Bridge
=======================
Normalizes hook events from ANY Claude-Code-compatible agent (Claude Code,
Codex, CodeBuddy, Gemini, Cursor, ...) and forwards them to the Agent Notch Unix socket so
they all show up in one notch.

The Agent Notch app's socket server is agent-agnostic: it only reads a small JSON
schema (session_id / cwd / event / status / tool / tool_input / tool_use_id).
This script is the translation layer.

Usage (registered as a hook command by install.sh):
    notch-bridge.py --source codex

Input : the agent's hook payload as JSON on stdin.
Output: for PermissionRequest, a decision JSON on stdout (allow/deny) that the
        agent understands; nothing otherwise.

Design notes
------------
* Event name is read from stdin `hook_event_name`; if the agent doesn't send it,
  fall back to `--event <Name>` (some agents pass it as an arg).
* PermissionRequest blocks until the notch returns a decision (or timeout), then
  emits the decision in the agent's expected wire format. Claude Code and Codex
  share the same format (verified against the codex binary schema); other agents
  can override via DECISION_FORMATTERS below.
"""
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
import uuid

DEFAULT_SOCKET = "/tmp/claude-island.sock"
# Seconds the bridge waits for a notch decision on PermissionRequest.
# MUST stay strictly below the agent's outer hook timeout (see install.sh: 300)
# so we win the race and exit 0 gracefully instead of being killed mid-flight.
PERMISSION_TIMEOUT = int(os.environ.get("NOTCH_PERMISSION_TIMEOUT", "285"))
# Fire-and-forget connect/send budget for non-permission events.
SEND_TIMEOUT = int(os.environ.get("NOTCH_SEND_TIMEOUT", "5"))
# A completed turn remains visible briefly so the user can read the result.
# Any new activity cancels the pending removal. Active sessions never expire.
COMPLETED_TTL = int(os.environ.get("NOTCH_COMPLETED_TTL", "300"))
SAFE_SESSION_ID = re.compile(r"^[A-Za-z0-9._-]+$")
RELAY_PREFIX = "multiagent-notch-codex-"
APPROVAL_POLICY_FILE = os.path.join(
    os.path.expanduser("~"), ".multiagent-notch", "approval-policy.json"
)
APPROVAL_MODES = {"ask", "auto", "trusted"}


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def parse_args(argv):
    opts = {
        "source": "unknown",
        "socket": DEFAULT_SOCKET,
        "event": None,
        "lifecycle_only": False,
        "cleanup_token": None,
        "cleanup_session": None,
        "cleanup_cwd": "",
        "cleanup_delay": COMPLETED_TTL,
    }
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--source" and i + 1 < len(argv):
            opts["source"] = argv[i + 1]; i += 2
        elif a == "--socket" and i + 1 < len(argv):
            opts["socket"] = argv[i + 1]; i += 2
        elif a == "--event" and i + 1 < len(argv):
            opts["event"] = argv[i + 1]; i += 2
        elif a == "--lifecycle-only":
            opts["lifecycle_only"] = True; i += 1
        elif a == "--cleanup-token" and i + 1 < len(argv):
            opts["cleanup_token"] = argv[i + 1]; i += 2
        elif a == "--cleanup-session" and i + 1 < len(argv):
            opts["cleanup_session"] = argv[i + 1]; i += 2
        elif a == "--cleanup-cwd" and i + 1 < len(argv):
            opts["cleanup_cwd"] = argv[i + 1]; i += 2
        elif a == "--cleanup-delay" and i + 1 < len(argv):
            try:
                opts["cleanup_delay"] = max(0, int(argv[i + 1]))
            except ValueError:
                pass
            i += 2
        else:
            i += 1
    return opts


# --------------------------------------------------------------------------- #
# Diagnostics — enable with NOTCH_BRIDGE_DEBUG=1
# --------------------------------------------------------------------------- #
def debug_log(source, raw, note=""):
    if os.environ.get("NOTCH_BRIDGE_DEBUG") != "1":
        return
    try:
        import datetime
        d = os.path.expanduser("~/.multiagent-notch/logs")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, f"{source}.log"), "a") as f:
            f.write("%s | %s | %s\n" % (
                datetime.datetime.now().isoformat(timespec="seconds"),
                note,
                (raw or "").replace("\n", " ")[:800],
            ))
    except Exception:
        pass


# --------------------------------------------------------------------------- #
# TTY discovery (lets the notch focus the right terminal window)
# --------------------------------------------------------------------------- #
def get_tty():
    import subprocess
    ppid = os.getppid()
    try:
        r = subprocess.run(["ps", "-p", str(ppid), "-o", "tty="],
                           capture_output=True, text=True, timeout=2)
        tty = r.stdout.strip()
        if tty and tty not in ("??", "-"):
            return tty if tty.startswith("/dev/") else "/dev/" + tty
    except Exception:
        pass
    for fd in (sys.stdin, sys.stdout):
        try:
            return os.ttyname(fd.fileno())
        except (OSError, AttributeError):
            pass
    return None


def _tmux_path():
    for candidate in (
        shutil.which("tmux"),
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
    ):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return None


def _relay_session_name(session_id):
    if not SAFE_SESSION_ID.fullmatch(session_id):
        raise ValueError("unsafe session id")
    return RELAY_PREFIX + session_id


def ensure_codex_relay(session_id, cwd):
    """Return the hidden relay pane's (pid, tty), or None if unavailable."""
    try:
        tmux = _tmux_path()
        relay = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "codex-relay.py")
        if not tmux or not os.path.isfile(relay):
            return None

        name = _relay_session_name(session_id)
        exists = subprocess.run(
            [tmux, "has-session", "-t", name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=1,
            check=False,
        ).returncode == 0
        if not exists:
            working_directory = cwd if os.path.isdir(cwd) else os.path.expanduser("~")
            command = " ".join(shlex.quote(part) for part in (
                sys.executable,
                relay,
                "--session-id", session_id,
                "--cwd", working_directory,
            ))
            subprocess.run(
                [
                    tmux, "new-session", "-d",
                    "-s", name,
                    "-c", working_directory,
                    command,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2,
                check=False,
            )

        panes = subprocess.run(
            [
                tmux, "list-panes", "-t", name,
                "-F", "#{pane_pid}\t#{pane_tty}",
            ],
            capture_output=True,
            text=True,
            timeout=1,
            check=False,
        )
        first = panes.stdout.strip().splitlines()[0]
        pid_text, tty = first.split("\t", 1)
        return int(pid_text), tty
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return None


def stop_codex_relay(session_id):
    try:
        tmux = _tmux_path()
        if tmux:
            subprocess.run(
                [tmux, "kill-session", "-t", _relay_session_name(session_id)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=1,
                check=False,
            )
    except (OSError, ValueError, subprocess.SubprocessError):
        pass


# --------------------------------------------------------------------------- #
# Socket I/O
# --------------------------------------------------------------------------- #
# --------------------------------------------------------------------------- #
# Synthetic transcript — gives Codex sessions a TITLE and TASK line.
#
# Agent Notch derives the session title (first user message / summary) and the
# activity line from a Claude-format JSONL at:
#     ~/.claude/projects/<cwd with '/' and '.' -> '-'>/<session_id>.jsonl
# Codex produces no such file, so we synthesize a minimal one from the prompt
# (UserPromptSubmit) and tool calls (PreToolUse). The app already watches that
# path for any session in the "processing" phase, so it picks these up live.
# Disable with NOTCH_NO_SYNTHETIC=1.
# --------------------------------------------------------------------------- #
def _iso_now():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _synthetic_paths(cwd, session_id):
    if not SAFE_SESSION_ID.fullmatch(session_id):
        raise ValueError("unsafe session id")
    proj = cwd.replace("/", "-").replace(".", "-")
    d = os.path.expanduser("~/.claude/projects/" + proj)
    return d, os.path.join(d, session_id + ".jsonl")


def _compact_tracked_synthetic(path):
    """Migrate our older spaced JSON rows to Agent Notch's compact format."""
    try:
        idx = os.path.expanduser("~/.multiagent-notch/synthetic-files.txt")
        with open(idx) as index_file:
            tracked = {line.strip() for line in index_file if line.strip()}
        if path not in tracked:
            return

        with open(path) as existing_file:
            original = existing_file.read()
        if '"type": "' not in original:
            return

        compact_lines = []
        for line in original.splitlines():
            if line.strip():
                compact_lines.append(json.dumps(
                    json.loads(line),
                    ensure_ascii=False,
                    separators=(",", ":"),
                ))
        compact = "\n".join(compact_lines) + "\n"
        if compact == original:
            return

        temporary = f"{path}.compact-{uuid.uuid4().hex}.tmp"
        try:
            with open(temporary, "w") as output:
                output.write(compact)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    except (OSError, ValueError, json.JSONDecodeError):
        # A display-only migration must never interfere with an agent turn.
        return


def _append_jsonl(directory, path, obj, session_id):
    os.makedirs(directory, exist_ok=True)
    if os.path.exists(path):
        _compact_tracked_synthetic(path)
    # Hook delivery may be retried. Keep synthetic transcript entries stable
    # so a retry cannot duplicate a prompt, tool call, or assistant response.
    entry_id = obj.get("uuid")
    if entry_id and os.path.exists(path):
        try:
            with open(path) as existing_file:
                if any(
                    json.loads(line).get("uuid") == entry_id
                    for line in existing_file
                    if line.strip()
                ):
                    return
        except (OSError, ValueError, json.JSONDecodeError):
            pass
    with open(path, "a") as f:
        # Agent Notch's incremental parser first checks for the exact literals
        # `"type":"user"` / `"type":"assistant"` before decoding JSON.
        f.write(json.dumps(
            obj,
            ensure_ascii=False,
            separators=(",", ":"),
        ) + "\n")
    # Track written files so uninstall can clean them (Codex ids look like
    # Claude ids, so a filename alone isn't distinguishable otherwise).
    try:
        idx_dir = os.path.expanduser("~/.multiagent-notch")
        os.makedirs(idx_dir, exist_ok=True)
        idx = os.path.join(idx_dir, "synthetic-files.txt")
        existing = set()
        if os.path.exists(idx):
            with open(idx) as f:
                existing = set(l.strip() for l in f)
        if path not in existing:
            with open(idx, "a") as f:
                f.write(path + "\n")
    except Exception:
        pass


def _stable_id(session_id, event, data, content):
    turn_id = data.get("turn_id") or ""
    tool_use_id = data.get("tool_use_id") or ""
    basis = "|".join((session_id, turn_id, event, tool_use_id, content))
    return str(uuid.uuid5(uuid.NAMESPACE_URL, basis))


def _source_title(source, prompt):
    markers = {
        "codex": "Codex",
        "codebuddy": "CodeBuddy",
        "gemini": "🔵 Gemini",
        "cursor": "🟣 Cursor",
    }
    label = markers.get(source.lower(), f"⚪️ {source.title()}")
    clean_prompt = " ".join(prompt.split())
    if len(clean_prompt) > 42:
        clean_prompt = clean_prompt[:39] + "..."
    return f"{label} · {clean_prompt}"


def _codex_thread_title(session_id):
    """Return Codex Desktop's sidebar title for this hook session, if known."""
    index = os.path.expanduser("~/.codex/session_index.jsonl")
    try:
        matched = None
        with open(index) as f:
            for line in f:
                if session_id not in line:
                    continue
                row = json.loads(line)
                if row.get("id") == session_id:
                    title = (row.get("thread_name") or "").strip()
                    if title:
                        matched = title
        return matched
    except (OSError, ValueError, json.JSONDecodeError):
        return None


def write_synthetic(source, session_id, cwd, event, data):
    if source == "claude":          # Claude has a real transcript already
        return
    if os.environ.get("NOTCH_NO_SYNTHETIC") == "1":
        return
    if not cwd or not session_id or session_id == "unknown":
        return
    try:
        directory, path = _synthetic_paths(cwd, session_id)
        ts = _iso_now()
        if event == "UserPromptSubmit":
            prompt = (data.get("prompt") or "").strip()
            if prompt:
                title_text = (
                    _codex_thread_title(session_id)
                    if source.lower() == "codex"
                    else None
                ) or prompt
                title = _source_title(source, title_text)
                _append_jsonl(directory, path, {
                    "uuid": _stable_id(session_id, "AgentSummary", data, title),
                    "type": "summary",
                    "summary": title,
                    "timestamp": ts,
                    "source": source,
                }, session_id)
                _append_jsonl(directory, path, {
                    "uuid": _stable_id(session_id, event, data, prompt),
                    "type": "user",
                    "message": {"role": "user", "content": prompt},
                    "timestamp": ts,
                    "source": source,
                }, session_id)
        elif event == "PreToolUse":
            tool = data.get("tool_name") or "Tool"
            tin = data.get("tool_input")
            tin = tin if isinstance(tin, dict) else {}
            tool_id = data.get("tool_use_id") or _stable_id(
                session_id, event, data, json.dumps(tin, sort_keys=True)
            )
            _append_jsonl(directory, path, {
                "uuid": _stable_id(session_id, event, data, tool_id),
                "type": "assistant",
                "message": {"role": "assistant",
                            "content": [{
                                "type": "tool_use",
                                "id": tool_id,
                                "name": tool,
                                "input": tin,
                            }]},
                "timestamp": ts,
                "source": source,
            }, session_id)
        elif event == "Stop":
            reply = (data.get("last_assistant_message") or "").strip()
            if reply:
                _append_jsonl(directory, path, {
                    "uuid": _stable_id(session_id, event, data, reply),
                    "type": "assistant",
                    "message": {
                        "role": "assistant",
                        "content": [{"type": "text", "text": reply}],
                    },
                    "timestamp": ts,
                    "source": source,
                }, session_id)
    except Exception:
        pass  # never let transcript writing break the hook


def send_event(sock_path, state, expect_reply):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        # Long budget only when we actually block for a decision; otherwise a
        # short budget so a hung socket can't stall the agent's turn.
        s.settimeout(PERMISSION_TIMEOUT if expect_reply else SEND_TIMEOUT)
        s.connect(sock_path)
        s.sendall(json.dumps(state).encode())
        if expect_reply:
            resp = s.recv(4096)
            s.close()
            if resp:
                return json.loads(resp.decode())
        else:
            s.close()
        return None
    except (socket.error, OSError, json.JSONDecodeError):
        return None


# --------------------------------------------------------------------------- #
# Completed-session cleanup
# --------------------------------------------------------------------------- #
ACTIVE_EVENTS = {
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PostToolUseFailure", "PermissionRequest", "PermissionDenied",
    "SubagentStart", "SubagentStop", "PreCompact", "PostCompact",
}


def _cleanup_marker(source, session_id):
    key = uuid.uuid5(uuid.NAMESPACE_URL, f"{source}|{session_id}").hex
    directory = os.path.expanduser("~/.multiagent-notch/session-cleanup")
    return directory, os.path.join(directory, key + ".json")


def cancel_scheduled_cleanup(source, session_id):
    _, marker = _cleanup_marker(source, session_id)
    try:
        os.unlink(marker)
    except FileNotFoundError:
        pass
    except OSError:
        pass


def schedule_cleanup(source, session_id, cwd, sock_path, delay=None):
    """Schedule removal after Stop; a later active event invalidates the token."""
    ttl = COMPLETED_TTL if delay is None else max(0, delay)
    if ttl < 0 or not session_id or session_id == "unknown":
        return None

    directory, marker = _cleanup_marker(source, session_id)
    token = uuid.uuid4().hex
    try:
        os.makedirs(directory, exist_ok=True)
        temporary = marker + "." + token + ".tmp"
        with open(temporary, "w") as f:
            json.dump({"token": token, "created_at": time.time()}, f)
        os.replace(temporary, marker)
        subprocess.Popen(
            [
                sys.executable,
                os.path.abspath(__file__),
                "--source", source,
                "--socket", sock_path,
                "--cleanup-token", token,
                "--cleanup-session", session_id,
                "--cleanup-cwd", cwd,
                "--cleanup-delay", str(ttl),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
        return token
    except (OSError, ValueError):
        return None


def run_cleanup_job(opts):
    """Detached worker: remove only if no newer activity replaced the token."""
    token = opts["cleanup_token"]
    session_id = opts["cleanup_session"]
    if not token or not session_id:
        return
    time.sleep(opts["cleanup_delay"])
    _, marker = _cleanup_marker(opts["source"], session_id)
    try:
        with open(marker) as f:
            current = json.load(f)
        if current.get("token") != token:
            return
        send_event(opts["socket"], {
            "session_id": session_id,
            "cwd": opts["cleanup_cwd"],
            "event": "SessionExpired",
            "status": "ended",
            "source": opts["source"],
        }, expect_reply=False)
        if opts["source"] == "codex":
            stop_codex_relay(session_id)
        os.unlink(marker)
    except (OSError, ValueError, json.JSONDecodeError):
        return


# --------------------------------------------------------------------------- #
# Event -> status mapping (shared across agents)
# --------------------------------------------------------------------------- #
def map_status(event):
    return {
        "SessionStart": "waiting_for_input",
        "UserPromptSubmit": "processing",
        "PreToolUse": "running_tool",
        "PostToolUse": "processing",
        "PostToolUseFailure": "processing",
        "PermissionRequest": "waiting_for_approval",
        "PermissionDenied": "processing",
        "SubagentStart": "processing",
        "SubagentStop": "processing",
        "Stop": "waiting_for_input",
        "StopFailure": "waiting_for_input",
        "Notification": "notification",
        "SessionEnd": "ended",
        "PreCompact": "compacting",
        "PostCompact": "processing",
    }.get(event, "unknown")


def permission_tool_use_id(session_id, supplied_id=None):
    """Return an id the app can use to keep this blocking socket pending.

    Codex PermissionRequest payloads frequently omit tool_use_id.  The bridge
    itself owns the blocking hook socket, so an event-local opaque id is enough
    to correlate the notch button with that exact connection; it never needs
    to be understood by Codex.
    """
    if supplied_id:
        return str(supplied_id)
    return "permission-{}-{}".format(session_id, uuid.uuid4().hex)


def current_approval_mode(session_id=None):
    """Read the app-owned approval policy; malformed or absent means ask.

    The environment override makes the bridge easy to integration-test without
    touching a user's persistent setting. It is intentionally restricted to
    the same three known values.
    """
    candidate = os.environ.get("NOTCH_APPROVAL_MODE", "").strip().lower()
    if candidate in APPROVAL_MODES:
        return candidate
    try:
        with open(APPROVAL_POLICY_FILE) as f:
            policy = json.load(f)
        sessions = policy.get("sessions", {})
        if session_id and isinstance(sessions, dict):
            candidate = str(sessions.get(session_id, "")).lower()
            if candidate in APPROVAL_MODES:
                return candidate
        candidate = str(policy.get("mode", "ask")).lower()
        return candidate if candidate in APPROVAL_MODES else "ask"
    except (OSError, ValueError, TypeError, AttributeError, json.JSONDecodeError):
        return "ask"


# --------------------------------------------------------------------------- #
# PermissionRequest decision -> agent wire format
# Claude Code and Codex share this schema. Add per-source overrides here.
# --------------------------------------------------------------------------- #
def format_decision(source, decision, reason):
    behavior = "allow" if decision == "allow" else "deny"
    inner = {"behavior": behavior}
    if behavior == "deny":
        inner["message"] = reason or "Denied via Agent Notch"
    return {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": inner,
        }
    }


DECISION_FORMATTERS = {}  # source -> callable(decision, reason) -> dict override


def format_interactive_decision(decision, reason, updated_input):
    """Claude Code PreToolUse response for questions and plan review."""
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow" if decision == "allow" else "deny",
        }
    }
    specific = output["hookSpecificOutput"]
    if reason:
        specific["permissionDecisionReason"] = reason
    if decision == "allow" and isinstance(updated_input, dict):
        specific["updatedInput"] = updated_input
    return output


# --------------------------------------------------------------------------- #
def main():
    opts = parse_args(sys.argv[1:])
    source = opts["source"]

    if opts["cleanup_token"]:
        run_cleanup_job(opts)
        sys.exit(0)

    raw = sys.stdin.read()
    debug_log(source, raw, note="recv")

    try:
        data = json.loads(raw) if raw.strip() else {}
    except (json.JSONDecodeError, ValueError):
        # Never fail an agent's turn because of us.
        sys.exit(0)

    event = data.get("hook_event_name") or opts["event"] or ""
    session_id = data.get("session_id") or f"{source}-{os.getppid()}"
    cwd = data.get("cwd", "")
    tool_input = data.get("tool_input", {})
    status = map_status(event)
    is_interactive_pretool = (
        event == "PreToolUse"
        and data.get("tool_name") in ("AskUserQuestion", "ExitPlanMode")
        and source.lower() == "claude"
    )
    if is_interactive_pretool:
        status = "waiting_for_approval"

    if event in ACTIVE_EVENTS:
        cancel_scheduled_cleanup(source, session_id)

    if opts["lifecycle_only"]:
        if event == "Stop":
            schedule_cleanup(source, session_id, cwd, opts["socket"])
        sys.exit(0)

    # Write the synthetic transcript BEFORE emitting the socket event, so the
    # file exists when the app starts watching this session's JSONL.
    write_synthetic(source, session_id, cwd, event, data)

    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "status": status,
        "pid": os.getppid(),
        "tty": get_tty(),
        # extra field ignored by the app but handy for future app-side theming
        "source": source,
    }
    if source.lower() == "codex":
        relay = ensure_codex_relay(session_id, cwd)
        if relay:
            state["pid"], state["tty"] = relay

    if event in ("PreToolUse", "PostToolUse", "PostToolUseFailure",
                 "PermissionRequest", "PermissionDenied"):
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        tuid = data.get("tool_use_id")
        if event == "PermissionRequest":
            # Keep the accepted Unix socket open in HookSocketServer even when
            # Codex does not provide a native tool_use_id. Without this, the
            # UI renders Allow/Deny but has no pending connection to answer.
            state["tool_use_id"] = permission_tool_use_id(session_id, tuid)
        elif tuid:
            state["tool_use_id"] = tuid

    if event == "Notification":
        ntype = data.get("notification_type")
        if ntype == "permission_prompt":
            sys.exit(0)  # handled by PermissionRequest with richer data
        state["notification_type"] = ntype
        state["message"] = data.get("message")
        state["status"] = "waiting_for_input" if ntype == "idle_prompt" else "notification"

    # ---- PermissionRequest: block for a decision, then answer the agent ---- #
    if event == "PermissionRequest":
        approval_mode = current_approval_mode(session_id)
        if approval_mode in ("auto", "trusted"):
            # Preserve a visible activity update, but never open a second,
            # blocking permission socket. This is strictly for ordinary tool
            # permissions; AskUserQuestion / ExitPlanMode stay manual below.
            state["status"] = "processing"
            state["approval_mode"] = approval_mode
            send_event(opts["socket"], state, expect_reply=False)
            fmt = DECISION_FORMATTERS.get(source, format_decision)
            out = fmt(source, "allow", "") if fmt is format_decision \
                else fmt("allow", "")
            print(json.dumps(out))
            debug_log(source, json.dumps(out), note=f"{approval_mode}-decision")
            sys.exit(0)

        resp = send_event(opts["socket"], state, expect_reply=True)
        if resp:
            decision = resp.get("decision", "ask")
            reason = resp.get("reason", "")
            if decision in ("allow", "deny"):
                fmt = DECISION_FORMATTERS.get(source, format_decision)
                out = fmt(source, decision, reason) if fmt is format_decision \
                    else fmt(decision, reason)
                print(json.dumps(out))
                debug_log(source, json.dumps(out), note="decision")
        # "ask" / no response -> let the agent show its own prompt
        sys.exit(0)

    # AskUserQuestion and ExitPlanMode are PreToolUse interactions, not normal
    # PermissionRequest decisions. Echoing updatedInput is required; allow
    # alone would leave Claude Code blocked at its terminal prompt.
    if is_interactive_pretool:
        resp = send_event(opts["socket"], state, expect_reply=True)
        if resp:
            decision = resp.get("decision", "ask")
            reason = resp.get("reason", "")
            updated_input = resp.get("updated_input")
            if decision in ("allow", "deny"):
                out = format_interactive_decision(
                    decision,
                    reason,
                    updated_input,
                )
                print(json.dumps(out))
                debug_log(source, json.dumps(out), note="interactive-decision")
        # No response is fail-open: Claude Code shows its native terminal UI.
        sys.exit(0)

    # ---- Fire-and-forget for everything else ---- #
    send_event(opts["socket"], state, expect_reply=False)
    if event == "Stop":
        schedule_cleanup(source, session_id, cwd, opts["socket"])
    sys.exit(0)


if __name__ == "__main__":
    main()
