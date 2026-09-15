#!/usr/bin/env python3
"""Opt-in real Claude CLI/SDK -> production Bridge question wire test.

Requires the official claude-agent-sdk and a signed-in Claude CLI. Default:
temporary fixture socket. With --app: relay to the running native notch and
answer manually. Only fixture data enters the new non-persistent session.
"""
import argparse
import asyncio
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid
from unittest.mock import patch


BRIDGE_PATH = Path(__file__).resolve().parents[1] / "AgentBridge/bin/notch-bridge.py"
QUESTION = "Which transport test answer should be returned?"
EVENT_SEQUENCE = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]
EVENT_STATUSES = ["processing", "waiting_for_approval", "processing", "waiting_for_input"]


def validate_fixture_event(event, session_id, cwd):
    """Never forward or clean up an unrelated session received on the relay."""
    if (not isinstance(event, dict)
            or event.get("session_id") != session_id or event.get("source") != "claude"
            or not isinstance(event.get("cwd"), str)
            or not os.path.isabs(event["cwd"])
            or os.path.realpath(event["cwd"]) != os.path.realpath(cwd)):
        raise ValueError("event does not belong to this isolated fixture")
    if event.get("event") not in EVENT_SEQUENCE:
        raise ValueError("unexpected fixture lifecycle event")
    if event.get("status") != EVENT_STATUSES[EVENT_SEQUENCE.index(event["event"])]:
        raise ValueError("unexpected fixture lifecycle status")
    if event["event"] in ("PreToolUse", "PostToolUse"):
        if (event.get("tool") != "AskUserQuestion"
                or not isinstance(event.get("tool_use_id"), str)
                or not event["tool_use_id"].strip()):
            raise ValueError("unexpected tool or missing request identity")
    if event["event"] == "PreToolUse":
        tool_input = event.get("tool_input")
        questions = tool_input.get("questions") if isinstance(tool_input, dict) else None
        if (not isinstance(questions, list) or len(questions) != 1
                or not isinstance(questions[0], dict)
                or questions[0].get("question") != QUESTION):
            raise ValueError("unexpected question in isolated fixture")


def verified_event_sequence(events, session_id):
    return (
        [event.get("event") for event in events] == EVENT_SEQUENCE
        and [event.get("status") for event in events] == EVENT_STATUSES
        and all(event.get("session_id") == session_id for event in events)
        and isinstance(events[1].get("tool_use_id"), str)
        and bool(events[1]["tool_use_id"].strip())
        and events[1]["tool_use_id"] == events[2].get("tool_use_id")
        and events[1].get("tool") == events[2].get("tool") == "AskUserQuestion"
    )


def run_isolated_hook(socket_path, bridge_path):
    """Keep production normalization/transport/formatting, isolate persistence."""
    spec = importlib.util.spec_from_file_location("live_notch_bridge", bridge_path)
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    isolated = {
        name: (lambda *args, **kwargs: None)
        for name in (
            "debug_log", "persist_session_snapshot", "remove_session_snapshot",
            "schedule_cleanup", "cancel_scheduled_cleanup", "process_expired_cleanups",
        )
    }
    with patch.multiple(bridge, **isolated), patch.object(
        sys, "argv", [str(bridge_path), "--source", "claude", "--socket", socket_path]
    ):
        bridge.main()


async def verify(cli, bridge_path, app_socket=None):
    from claude_agent_sdk import (
        ClaudeAgentOptions, ClaudeSDKClient, HookMatcher, PermissionResultDeny,
        ResultMessage,
    )
    from importlib.metadata import version

    events = []
    fallbacks = []
    errors = []
    marker = "NOTCH_WIRE_" + secrets.token_hex(12)
    session_id = str(uuid.uuid4())
    # Deliberately exceeds the old 4096-byte recv limit. The marker is never
    # included in the model prompt; a matching final reply proves consumption.
    answer = "多行答案分包测试。\n" * 600 + "\n" + marker
    response_bytes = 0
    question_count = 0
    app_forwarded = False
    pending_relays = set()
    cli_version = subprocess.check_output([cli, "--version"], text=True, timeout=10).strip()
    app_bridge = None
    if app_socket:
        spec = importlib.util.spec_from_file_location("app_notch_bridge", bridge_path)
        app_bridge = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(app_bridge)
        if app_bridge._private_socket_info(app_socket) is None:
            raise RuntimeError("Start Agent Notch first; its private socket is unavailable")
        # Match the explicit command-hook budget, independent of the shell
        # running this verifier. Only this imported test module is changed.
        app_bridge.PERMISSION_TIMEOUT = 90

    with tempfile.TemporaryDirectory(prefix="notch-claude-", dir="/tmp") as root:
        socket_path = str(Path(root) / "fixture.sock")
        if app_socket:
            print(json.dumps({"waiting_for": "native notch question",
                              "fixture_project": Path(root).name,
                              "question": QUESTION, "answer_marker": marker}, indent=2), flush=True)

        async def respond(reader, writer):
            nonlocal response_bytes, question_count, app_forwarded
            task = asyncio.current_task()
            pending_relays.add(task)
            try:
                wire = bytearray()
                while len(wire) <= 131072:
                    chunk = await asyncio.wait_for(reader.read(65536), timeout=5)
                    if not chunk:
                        raise ValueError("bridge disconnected before a complete event")
                    wire.extend(chunk)
                    try:
                        event = json.loads(wire)
                        break
                    except (ValueError, UnicodeError):
                        continue
                else:
                    raise ValueError("oversized fixture event")
                validate_fixture_event(event, session_id, root)
                events.append({key: event.get(key) for key in (
                    "event", "status", "session_id", "tool_use_id", "tool"
                )})
                if app_socket and event.get("event") != "PreToolUse":
                    app_forwarded = True
                    if not await asyncio.to_thread(app_bridge.send_event, app_socket, event, False):
                        raise RuntimeError("could not deliver lifecycle event to Agent Notch")
                if event.get("event") == "PreToolUse":
                    tool_input = event.get("tool_input", {})
                    question_count += 1
                    if app_socket:
                        app_forwarded = True
                        # Only the real UI may answer. Reuse the production
                        # authenticated transport to relay this exact request.
                        decision = await asyncio.to_thread(
                            app_bridge.send_event, app_socket, event, True
                        )
                        if not decision:
                            raise RuntimeError("the app did not return a question answer")
                    else:
                        decision = {
                            "decision": "allow",
                            "updated_input": {**tool_input, "answers": {QUESTION: answer}},
                        }
                    response = json.dumps(decision, ensure_ascii=False).encode()
                    response_bytes = len(response)
                    # Exercise stream framing and UTF-8 splits on the real run.
                    for offset in range(0, len(response), 997):
                        writer.write(response[offset:offset + 997])
                        await writer.drain()
                        await asyncio.sleep(0.002)
            except Exception as error:
                errors.append(type(error).__name__ + ": " + str(error))
            finally:
                try:
                    writer.close()
                    await writer.wait_closed()
                except OSError:
                    pass
                finally:
                    pending_relays.discard(task)

        async def hook(payload, _tool_use_id, _context):
            process = await asyncio.create_subprocess_exec(
                sys.executable, str(Path(__file__).resolve()),
                "--hook", "--socket", socket_path, "--bridge", str(bridge_path),
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1",
                     "NOTCH_PERMISSION_TIMEOUT": "10"},
            )
            try:
                output, _ = await asyncio.wait_for(
                    process.communicate(json.dumps(payload).encode()), timeout=15
                )
            except BaseException:
                if process.returncode is None:
                    process.kill()
                await process.wait()
                raise
            if process.returncode:
                raise RuntimeError("isolated bridge hook failed")
            return json.loads(output) if output.strip() else {}

        async def reject_fallback(tool_name, _tool_input, _context):
            fallbacks.append(tool_name)
            return PermissionResultDeny(message="The test must be answered by the bridge.")

        options = ClaudeAgentOptions(
            cli_path=cli, cwd=root, session_id=session_id, tools=["AskUserQuestion"],
            permission_mode="default", can_use_tool=reject_fallback,
            setting_sources=[], mcp_servers={}, strict_mcp_config=True,
            max_turns=3, max_budget_usd=0.50,
            system_prompt="You are a harmless protocol fixture. Only ask the requested "
                          "question once, then return the last line of the tool answer.",
            extra_args={"no-session-persistence": None, "no-chrome": None,
                        "disable-slash-commands": None},
            hooks={name: [HookMatcher(hooks=[hook])] for name in (
                "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"
            )},
        )
        if app_socket:
            # Exercise real CLI command hooks, not SDK hook callbacks, while
            # leaving the user's persistent hook configuration untouched.
            hook_command = shlex.join([
                sys.executable, str(Path(__file__).resolve()), "--hook", "--socket",
                socket_path, "--bridge", str(bridge_path),
            ])
            options.hooks = None
            options.settings = json.dumps({"hooks": {
                name: [{"matcher": "", "hooks": [{
                    "type": "command", "command": hook_command, "timeout": 105,
                }]}] for name in ("UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop")
            }})
            options.env = {"PYTHONDONTWRITEBYTECODE": "1", "NOTCH_PERMISSION_TIMEOUT": "90"}
        result = None
        server = await asyncio.start_unix_server(respond, path=socket_path)
        os.chmod(socket_path, 0o600)
        try:
            async with server, ClaudeSDKClient(options=options) as client:
                await client.query(
                    f'Call AskUserQuestion exactly once with question "{QUESTION}", '
                    'header "Transport", options "First" and "Second" (each with a '
                    'short description), multiSelect false. A test host will supply a '
                    'custom multiline answer. Then output only its final non-empty line. '
                    'Do not invent or answer the question yourself.'
                )
                async for message in client.receive_response():
                    if isinstance(message, ResultMessage):
                        result = message
            if pending_relays:
                await asyncio.gather(*list(pending_relays))
        finally:
            if app_socket and app_forwarded:
                # Only the UUID generated by this invocation may be removed,
                # including on failure/timeout. Never trust arbitrary peer IDs.
                cleaned_up = await asyncio.to_thread(app_bridge.send_event, app_socket, {
                    "session_id": session_id, "cwd": root, "source": "claude",
                    "event": "SessionEnd", "status": "ended",
                }, False)
                if not cleaned_up:
                    errors.append("could not send fixture session cleanup to the app")

        answer_consumed = result is not None and (result.result or "").strip() == marker
        identity_preserved = verified_event_sequence(events, session_id)
        passed = (result is not None and not result.is_error
                  and answer_consumed and question_count == 1 and identity_preserved
                  and (app_socket is not None or response_bytes > 4096)
                  and not fallbacks and not errors)
        report = {
            "passed": passed, "scope": (
                "real CLI command hooks, production bridge and native notch UI"
                if app_socket else "real CLI/SDK and production bridge; fixture UI"
            ),
            "cli_version": cli_version,
            "bridge_sha256": hashlib.sha256(bridge_path.read_bytes()).hexdigest(),
            "sdk_version": version("claude-agent-sdk"), "response_bytes": response_bytes,
            "answer_consumed": answer_consumed, "identity_preserved": identity_preserved,
            "result_subtype": result.subtype if result else None,
            "fallback_permission_calls": fallbacks, "events": events, "errors": errors,
            "excluded": (["session persistence", "PermissionRequest", "persistent hook registration"]
                         if app_socket else ["native notch UI", "session persistence", "PermissionRequest"]),
        }
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="Run one real Claude test turn")
    parser.add_argument("--claude", default=shutil.which("claude"))
    parser.add_argument("--bridge", type=Path, default=BRIDGE_PATH,
                        help="Bridge script to verify (defaults to the repository copy)")
    parser.add_argument("--app", action="store_true",
                        help="Forward to the running notch; answer its question manually")
    parser.add_argument("--hook", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--socket", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.hook:
        if not args.socket:
            parser.error("hook requires a private socket path")
        run_isolated_hook(args.socket, args.bridge.resolve())
    elif args.live:
        if not args.claude:
            parser.error("Claude CLI not found; pass --claude /path/to/claude")
        async def bounded_run():
            async with asyncio.timeout(150):
                return await verify(args.claude, args.bridge.resolve(),
                                    f"/tmp/agent-notch-{os.getuid()}.sock" if args.app else None)
        raise SystemExit(0 if asyncio.run(bounded_run()) else 1)
    else:
        parser.error("Pass --live to opt into a real model call (up to $0.50 API budget)")


if __name__ == "__main__":
    main()
