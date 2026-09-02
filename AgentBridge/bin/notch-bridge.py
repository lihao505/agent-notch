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
  share the same format (verified against the current official Codex Hooks
  schema); other agents can override via DECISION_FORMATTERS below.
"""
import json
import math
import os
import re
import socket
import stat
import sys
import time
import uuid


def default_socket_path():
    """Return Agent Notch's per-user socket without touching upstream paths."""
    override = os.environ.get("AGENT_NOTCH_SOCKET", "").strip()
    if override:
        return override
    return f"/tmp/agent-notch-{os.getuid()}.sock"


DEFAULT_SOCKET = default_socket_path()


def bounded_env_seconds(name, default, minimum=0.1, maximum=90.0):
    """Read a finite timeout without letting hook configuration break turns."""
    try:
        value = float(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        return float(default)
    if not math.isfinite(value):
        return float(default)
    return min(maximum, max(minimum, value))


def bounded_env_int(name, default, minimum=0, maximum=30 * 24 * 60 * 60):
    """Read a bounded integer setting, falling back on malformed input."""
    try:
        value = int(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        return int(default)
    return min(maximum, max(minimum, value))


# Seconds the bridge waits for a notch decision on PermissionRequest.
# MUST stay strictly below the agent's outer hook timeout (see install.sh: 105)
# so we win the race and exit 0 gracefully instead of being killed mid-flight.
PERMISSION_TIMEOUT = bounded_env_seconds(
    "NOTCH_PERMISSION_TIMEOUT", 90, minimum=0.1, maximum=90
)
# Fire-and-forget connect/send budget for non-permission events.
SEND_TIMEOUT = bounded_env_seconds(
    "NOTCH_SEND_TIMEOUT", 5, minimum=0.1, maximum=5
)
# A completed turn may remain available for up to five hours. The app shows at
# most one completed row and hides it early when active work gets crowded. Any
# new activity cancels the pending removal.
COMPLETED_TTL = bounded_env_int("NOTCH_COMPLETED_TTL", 18000)
SAFE_SESSION_ID = re.compile(r"^[A-Za-z0-9._-]+$")
APPROVAL_POLICY_FILE = os.path.join(
    os.path.expanduser("~"), ".multiagent-notch", "approval-policy.json"
)
APPROVAL_MODES = {"ask", "auto", "trusted"}


def claude_config_dir():
    """Resolve the Claude root selected in Agent Notch's installer.

    Codex/CodeBuddy hook processes do not reliably inherit
    CLAUDE_CONFIG_DIR, so the installer also stores this non-secret path in
    Agent Notch's private state directory.
    """
    environment = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    if environment:
        return os.path.abspath(os.path.expanduser(environment))
    config = os.path.expanduser("~/.multiagent-notch/config.json")
    try:
        with open(config) as source:
            value = json.load(source).get("claude_config_dir", "")
        if isinstance(value, str) and value.strip():
            return os.path.abspath(os.path.expanduser(value.strip()))
    except (OSError, ValueError, TypeError, AttributeError, json.JSONDecodeError):
        pass
    return os.path.expanduser("~/.claude")


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def parse_args(argv):
    opts = {
        "source": "unknown",
        "socket": DEFAULT_SOCKET,
        "event": None,
        "lifecycle_only": False,
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
    d = os.path.join(claude_config_dir(), "projects", proj)
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
            os.chmod(temporary, 0o600)
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
    os.chmod(path, 0o600)
    # Track written files so uninstall can clean them (Codex ids look like
    # Claude ids, so a filename alone isn't distinguishable otherwise).
    try:
        idx_dir = os.path.expanduser("~/.multiagent-notch")
        os.makedirs(idx_dir, exist_ok=True)
        os.chmod(idx_dir, 0o700)
        idx = os.path.join(idx_dir, "synthetic-files.txt")
        existing = set()
        if os.path.exists(idx):
            with open(idx) as f:
                existing = set(l.strip() for l in f)
        if path not in existing:
            with open(idx, "a") as f:
                f.write(path + "\n")
        if os.path.exists(idx):
            os.chmod(idx, 0o600)
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
    s = None
    try:
        before = _private_socket_info(sock_path)
        if before is None:
            return False if not expect_reply else None

        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        # Long budget only when we actually block for a decision; otherwise a
        # short budget so a hung socket can't stall the agent's turn.
        s.settimeout(PERMISSION_TIMEOUT if expect_reply else SEND_TIMEOUT)
        s.connect(sock_path)

        # Re-check the pathname after connect to close the lstat/connect race,
        # then authenticate the connected Unix peer itself.  A predictable
        # /tmp pathname must never be enough to impersonate Agent Notch.
        after = _private_socket_info(sock_path)
        if (
            after is None
            or (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
            or _peer_uid(s) != os.getuid()
        ):
            s.close()
            return False if not expect_reply else None

        s.sendall(json.dumps(state).encode())
        if expect_reply:
            resp = s.recv(4096)
            s.close()
            if resp:
                return json.loads(resp.decode())
        else:
            s.close()
            return True
        return None
    except (socket.error, OSError, ValueError, json.JSONDecodeError):
        if s is not None:
            try:
                s.close()
            except OSError:
                pass
        return False if not expect_reply else None


def _private_socket_info(sock_path):
    """Return lstat data only for this user's private Unix socket."""
    try:
        info = os.lstat(sock_path)
    except OSError:
        return None
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        return None
    if info.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        return None
    return info


def _peer_uid(sock):
    """Return a connected Unix peer's effective UID on macOS/BSD.

    CPython does not expose ``getpeereid`` on every macOS build, so use the
    libc API as the portable fallback for the app's supported platform.  A
    missing/failed credential check is intentionally treated as untrusted.
    """
    method = getattr(sock, "getpeereid", None)
    if callable(method):
        try:
            return int(method()[0])
        except (OSError, TypeError, ValueError):
            return None
    try:
        import ctypes

        libc = ctypes.CDLL(None, use_errno=True)
        getpeereid = libc.getpeereid
        uid = ctypes.c_uint()
        gid = ctypes.c_uint()
        getpeereid.argtypes = [
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_uint),
            ctypes.POINTER(ctypes.c_uint),
        ]
        getpeereid.restype = ctypes.c_int
        if getpeereid(sock.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0:
            return None
        return int(uid.value)
    except (AttributeError, OSError, TypeError, ValueError):
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


def _session_snapshot(source, session_id):
    """Return the private path for one agent's latest lifecycle observation."""
    key = uuid.uuid5(uuid.NAMESPACE_URL, f"{source}|{session_id}").hex
    directory = os.path.expanduser("~/.multiagent-notch/session-state")
    return directory, os.path.join(directory, key + ".json")


def _real_private_directory(path, create=False):
    """Return a real private directory, never following a state-dir symlink."""
    parent = os.path.dirname(path)
    try:
        try:
            parent_info = os.lstat(parent)
        except FileNotFoundError:
            if not create:
                return None
            os.mkdir(parent, 0o700)
            parent_info = os.lstat(parent)
        if (
            stat.S_ISLNK(parent_info.st_mode)
            or not stat.S_ISDIR(parent_info.st_mode)
            or parent_info.st_uid != os.getuid()
        ):
            return None
        os.chmod(parent, 0o700)
        if create:
            try:
                os.mkdir(path, 0o700)
            except FileExistsError:
                pass
        info = os.lstat(path)
        if (
            stat.S_ISLNK(info.st_mode)
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.getuid()
        ):
            return None
        os.chmod(path, 0o700)
        return path
    except OSError:
        return None


def _regular_cleanup_marker(path):
    """Accept only an owned marker file, never a directory or symlink."""
    try:
        info = os.lstat(path)
    except OSError:
        return False
    return (
        stat.S_ISREG(info.st_mode)
        and not stat.S_ISLNK(info.st_mode)
        and info.st_uid == os.getuid()
    )


def _unlink_regular_cleanup_marker(path):
    if not _regular_cleanup_marker(path):
        return False
    try:
        os.unlink(path)
        return True
    except OSError:
        return False


def persist_session_snapshot(state, observed_at=None):
    """Atomically retain enough state for an app launched mid-turn.

    The snapshot deliberately excludes prompts and tool input. A permission
    socket cannot survive an app restart, so the reader restores any recorded
    approval wait as ordinary processing and waits for a fresh live hook.
    """
    if not isinstance(state, dict):
        return None
    source = state.get("source")
    session_id = state.get("session_id")
    cwd = state.get("cwd")
    if not all(isinstance(value, str) and value for value in (
        source, session_id, cwd
    )):
        return None

    timestamp = (
        state.get("observed_at", time.time())
        if observed_at is None
        else observed_at
    )
    try:
        timestamp = float(timestamp)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(timestamp):
        return None

    directory, path = _session_snapshot(source, session_id)
    directory = _real_private_directory(directory, create=True)
    if directory is None:
        return None
    path = os.path.join(directory, os.path.basename(path))
    if os.path.lexists(path) and not _regular_cleanup_marker(path):
        return None

    payload = {
        "version": 1,
        "observed_at": timestamp,
        "session_id": session_id,
        "cwd": cwd,
        "source": source,
        "event": state.get("event") if isinstance(state.get("event"), str) else "",
        "status": state.get("status") if isinstance(state.get("status"), str) else "unknown",
    }
    pid = state.get("pid")
    if isinstance(pid, int) and not isinstance(pid, bool) and pid > 0:
        payload["pid"] = pid
    tty = state.get("tty")
    if isinstance(tty, str) and tty:
        payload["tty"] = tty

    temporary = path + "." + uuid.uuid4().hex + ".tmp"
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(temporary, flags, 0o600)
        with os.fdopen(descriptor, "w") as output:
            json.dump(payload, output, separators=(",", ":"), sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        return path
    except (OSError, TypeError, ValueError):
        try:
            os.unlink(temporary)
        except OSError:
            pass
        return None


def remove_session_snapshot(source, session_id):
    if not isinstance(source, str) or not isinstance(session_id, str):
        return False
    _, path = _session_snapshot(source, session_id)
    return _unlink_regular_cleanup_marker(path)


def cancel_scheduled_cleanup(source, session_id):
    _, marker = _cleanup_marker(source, session_id)
    _unlink_regular_cleanup_marker(marker)


def schedule_cleanup(source, session_id, cwd, sock_path, delay=None):
    """Persist expiry metadata without creating a long-lived sleep process.

    SessionStore independently enforces the same five-hour retention while the
    app is running.  The marker is a fallback: a later bridge invocation emits
    SessionExpired for markers whose deadline passed while the app was away.
    """
    ttl = COMPLETED_TTL if delay is None else max(0, delay)
    if not session_id or session_id == "unknown":
        return None

    directory, marker = _cleanup_marker(source, session_id)
    token = uuid.uuid4().hex
    directory = _real_private_directory(directory, create=True)
    if directory is None:
        return None
    marker = os.path.join(directory, os.path.basename(marker))
    if os.path.lexists(marker) and not _regular_cleanup_marker(marker):
        return None
    temporary = marker + "." + token + ".tmp"
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(temporary, flags, 0o600)
        with os.fdopen(descriptor, "w") as f:
            created_at = time.time()
            json.dump({
                "token": token,
                "created_at": created_at,
                "expires_at": created_at + ttl,
                "source": source,
                "session_id": session_id,
                "cwd": cwd,
            }, f)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, marker)
        return token
    except (OSError, TypeError, ValueError):
        try:
            os.unlink(temporary)
        except OSError:
            pass
        return None


def process_expired_cleanups(sock_path, now=None):
    """Expire due markers during a normal hook invocation; never sleep."""
    directory = os.path.expanduser("~/.multiagent-notch/session-cleanup")
    current_time = time.time() if now is None else now
    expired = 0
    directory = _real_private_directory(directory, create=False)
    if directory is None:
        return expired
    try:
        names = os.listdir(directory)
    except OSError:
        return expired

    for name in names:
        if re.fullmatch(r"[a-f0-9]{32}\.json", name) is None:
            continue
        marker = os.path.join(directory, name)
        if not _regular_cleanup_marker(marker):
            continue
        try:
            flags = os.O_RDONLY
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            descriptor = os.open(marker, flags)
            with os.fdopen(descriptor) as marker_file:
                opened_info = os.fstat(marker_file.fileno())
                if (
                    not stat.S_ISREG(opened_info.st_mode)
                    or opened_info.st_uid != os.getuid()
                ):
                    raise OSError("cleanup marker owner/type changed")
                current = json.load(marker_file)
            if not isinstance(current, dict):
                raise ValueError("cleanup marker is not an object")
            raw_expiry = current.get("expires_at")
            if raw_expiry is None:
                # v1 markers only stored a token + creation time and cannot be
                # correlated back to a session. Let their original five-hour
                # window elapse, then remove them instead of retaining them
                # forever. SessionStore independently applies the same TTL.
                created_at = float(current.get("created_at"))
                if not math.isfinite(created_at):
                    raise ValueError("cleanup marker has invalid creation time")
                legacy_expiry = created_at + COMPLETED_TTL
                if legacy_expiry > current_time:
                    continue
                if _unlink_regular_cleanup_marker(marker):
                    expired += 1
                continue
            expiry = float(raw_expiry)
            if not math.isfinite(expiry):
                raise ValueError("cleanup marker has invalid expiry")
            if expiry > current_time:
                continue
            session_id = current.get("session_id")
            source = current.get("source")
            cwd = current.get("cwd", "")
            if not isinstance(session_id, str) or not session_id:
                raise ValueError("cleanup marker has no session id")
            if not isinstance(source, str) or not source:
                raise ValueError("cleanup marker has no source")
            if not isinstance(cwd, str):
                raise ValueError("cleanup marker has invalid cwd")
            # The completed snapshot has now outlived the UI retention window.
            # Remove it even if the app is currently offline; the cleanup marker
            # remains available to clear a separately persisted app card later.
            remove_session_snapshot(source, session_id)
            delivered = send_event(sock_path, {
                "session_id": session_id,
                "cwd": cwd,
                "event": "SessionExpired",
                "status": "ended",
                "source": source,
            }, expect_reply=False)
            # Keep the marker when the app is offline. A later normal event can
            # retry, so expiration is never silently lost.
            if delivered is True and _unlink_regular_cleanup_marker(marker):
                expired += 1
        except (KeyError, OSError, TypeError, ValueError, json.JSONDecodeError):
            # Invalid project-owned markers cannot be useful again. Removing
            # them prevents permanent state-dir growth without touching any
            # file outside this narrowly scoped directory.
            _unlink_regular_cleanup_marker(marker)
    return expired


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

    # Handle due fallback markers only after cancelling this session's marker,
    # so a resumed conversation can never be expired immediately before its
    # new activity event is delivered.
    process_expired_cleanups(opts["socket"])

    # Generate the lifecycle timestamp before any transcript or socket I/O.
    # Separate hook processes can otherwise arrive at the app out of order;
    # this observation time lets SessionStore reject a delayed older phase
    # without discarding its tool bookkeeping.
    observed_at = time.time()
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "status": status,
        "observed_at": observed_at,
        "pid": os.getppid(),
        "tty": get_tty(),
        # Extra field ignored by the socket server but used by startup restore.
        "source": source,
    }
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

    if event in ("SessionEnd", "SessionExpired") or state["status"] == "ended":
        remove_session_snapshot(source, session_id)
    else:
        persist_session_snapshot(state, observed_at=observed_at)

    if opts["lifecycle_only"]:
        if event == "Stop":
            schedule_cleanup(source, session_id, cwd, opts["socket"])
        sys.exit(0)

    # Write the synthetic transcript BEFORE emitting the socket event, so the
    # file exists when the app starts watching this session's JSONL.
    write_synthetic(source, session_id, cwd, event, data)

    # ---- PermissionRequest: block for a decision, then answer the agent ---- #
    if event == "PermissionRequest":
        state["response_timeout_seconds"] = PERMISSION_TIMEOUT
        approval_mode = current_approval_mode(session_id)
        if approval_mode in ("auto", "trusted"):
            # Preserve a visible activity update, but never open a second,
            # blocking permission socket. This is strictly for ordinary tool
            # permissions; AskUserQuestion / ExitPlanMode stay manual below.
            state["status"] = "processing"
            state["approval_mode"] = approval_mode
            app_is_live = send_event(
                opts["socket"], state, expect_reply=False
            ) is True
            # Auto is deliberately an in-app, current-run convenience. If the
            # app quit or crashed, emit no decision and let the agent show its
            # own approval prompt. Trusted is the explicit offline-persistent
            # choice and may still allow without a live socket.
            if approval_mode == "auto" and not app_is_live:
                sys.exit(0)
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
