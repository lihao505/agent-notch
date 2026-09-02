#!/usr/bin/env python3
# Modified by lihao505 for Agent Notch, 2026.
"""
Claude Island Hook
- Sends session state to ClaudeIsland.app via Unix socket
- For PermissionRequest: waits for user decision from the app
"""
import json
import os
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


SOCKET_PATH = default_socket_path()
PERMISSION_TIMEOUT_SECONDS = 90
SEND_TIMEOUT_SECONDS = 5
APPROVAL_POLICY_FILE = os.path.join(
    os.path.expanduser("~"), ".multiagent-notch", "approval-policy.json"
)
APPROVAL_MODES = {"ask", "auto", "trusted"}
MANUAL_INTERACTION_TOOLS = {"AskUserQuestion", "ExitPlanMode"}


def current_approval_mode(session_id=None):
    """Read the app-owned approval policy; malformed or absent means ask."""
    candidate = os.environ.get("NOTCH_APPROVAL_MODE", "").strip().lower()
    if candidate in APPROVAL_MODES:
        return candidate
    try:
        with open(APPROVAL_POLICY_FILE) as policy_file:
            policy = json.load(policy_file)
        if not isinstance(policy, dict):
            return "ask"
        sessions = policy.get("sessions", {})
        if session_id and isinstance(sessions, dict):
            candidate = str(sessions.get(session_id, "")).lower()
            if candidate in APPROVAL_MODES:
                return candidate
        candidate = str(policy.get("mode", "ask")).lower()
        return candidate if candidate in APPROVAL_MODES else "ask"
    except (OSError, ValueError, TypeError, AttributeError, json.JSONDecodeError):
        return "ask"


def should_auto_approve(session_id, tool_name):
    """Auto/trusted applies to tools, never structured user interactions."""
    if tool_name in MANUAL_INTERACTION_TOOLS:
        return False
    return current_approval_mode(session_id) in ("auto", "trusted")


def get_tty():
    """Get the TTY of the Claude process (parent)"""
    import subprocess

    # Get parent PID (Claude process)
    ppid = os.getppid()

    # Try to get TTY from ps command for the parent process
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "-":
            # ps returns just "ttys001", we need "/dev/ttys001"
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    # Fallback: try current process stdin/stdout
    try:
        return os.ttyname(sys.stdin.fileno())
    except (OSError, AttributeError):
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except (OSError, AttributeError):
        pass
    return None


def send_event(state):
    """Send event to app, return response if any"""
    is_permission = state.get("status") == "waiting_for_approval"
    sock = None
    try:
        before = _private_socket_info(SOCKET_PATH)
        if before is None:
            return False if not is_permission else None

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(
            PERMISSION_TIMEOUT_SECONDS if is_permission else SEND_TIMEOUT_SECONDS
        )
        sock.connect(SOCKET_PATH)

        after = _private_socket_info(SOCKET_PATH)
        if (
            after is None
            or (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
            or _peer_uid(sock) != os.getuid()
        ):
            sock.close()
            return False if not is_permission else None

        sock.sendall(json.dumps(state).encode())

        # For permission requests, wait for response
        if is_permission:
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()
            return True

        return None
    except (socket.error, OSError, ValueError, json.JSONDecodeError):
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
        return False if not is_permission else None


def _private_socket_info(sock_path):
    """Accept only a private, same-user Unix socket (never a symlink)."""
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
    """Return the connected Unix peer UID using macOS/BSD getpeereid."""
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


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    tool_input = data.get("tool_input", {})

    # Get process info
    claude_pid = os.getppid()
    tty = get_tty()

    # Build state object
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "observed_at": time.time(),
        "pid": claude_pid,
        "tty": tty,
    }

    # Map events to status
    if event == "UserPromptSubmit":
        # User just sent a message - Claude is now processing
        state["status"] = "processing"

    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id to Swift for caching
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id so Swift can cancel the specific pending permission
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PostToolUseFailure":
        # Tool errored or was interrupted — main session continues processing
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        state["tool_error"] = data.get("error") or data.get("message")
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PermissionDenied":
        # Auto-mode classifier denied a tool call — surface to the app so the
        # user can see what was blocked instead of a silent skip
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        state["denial_reason"] = data.get("reason") or data.get("message")

    elif event == "PermissionRequest":
        # This is where we can control the permission
        state["status"] = "waiting_for_approval"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        state["response_timeout_seconds"] = PERMISSION_TIMEOUT_SECONDS
        # Claude can omit tool_use_id here. The ID only has to correlate the
        # notch button with this exact blocking socket, so an event-local opaque
        # value is safer than relying on timing-sensitive PreToolUse cache hits.
        state["tool_use_id"] = (
            data.get("tool_use_id")
            or "permission-{}-{}".format(session_id, uuid.uuid4().hex)
        )

        # Read once so a concurrent settings change cannot make the branch
        # decision and the emitted policy disagree.
        approval_mode = current_approval_mode(session_id)
        if (
            state["tool"] not in MANUAL_INTERACTION_TOOLS
            and approval_mode in ("auto", "trusted")
        ):
            # Keep the activity visible, but do not open a second blocking
            # socket when the user explicitly selected auto/trusted mode.
            state["status"] = "processing"
            state["approval_mode"] = approval_mode
            app_is_live = send_event(state) is True
            # Auto is scoped to a live Agent Notch run. If the app quit or
            # crashed, return no decision so Claude falls back to its native
            # prompt. Trusted is the explicit offline-persistent choice.
            if approval_mode == "auto" and not app_is_live:
                sys.exit(0)
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {"behavior": "allow"},
                }
            }
            print(json.dumps(output))
            sys.exit(0)

        # Send to app and wait for decision
        response = send_event(state)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                # Output JSON to approve
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"},
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                # Output JSON to deny
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via Agent Notch",
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

        # No response or "ask" - let Claude Code show its normal UI
        sys.exit(0)

    elif event == "Notification":
        notification_type = data.get("notification_type")
        # Skip permission_prompt - PermissionRequest hook handles this with better info
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    elif event == "StopFailure":
        # Turn ended via API error (rate limit, auth, billing). Mark waiting
        # so the user sees it's done (not stuck), with the error surfaced
        state["status"] = "waiting_for_input"
        state["stop_error"] = data.get("error") or data.get("message")

    elif event == "SubagentStart":
        # A subagent task is beginning — main session is still processing
        state["status"] = "processing"

    elif event == "SubagentStop":
        # SubagentStop fires when a subagent completes - main session continues processing
        state["status"] = "processing"

    elif event == "SessionStart":
        # New session starts waiting for user input
        state["status"] = "waiting_for_input"

    elif event == "SessionEnd":
        state["status"] = "ended"

    elif event == "PreCompact":
        # Context is being compacted (manual or auto)
        state["status"] = "compacting"

    elif event == "PostCompact":
        # Compaction finished — return to processing so UI exits .compacting phase
        state["status"] = "processing"

    else:
        state["status"] = "unknown"

    # Send to socket (fire and forget for non-permission events)
    send_event(state)


if __name__ == "__main__":
    main()
