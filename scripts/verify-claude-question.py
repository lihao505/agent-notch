#!/usr/bin/env python3
"""Opt-in real Claude CLI/SDK -> production Bridge question wire test.

Requires the official claude-agent-sdk and a signed-in Claude CLI. Uses a
temporary private socket in place of the notch, NOT an installed-app/UI test.
Only fixture questions/answers enter the new, non-persistent Claude session.
"""
import argparse
import asyncio
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch


BRIDGE_PATH = Path(__file__).resolve().parents[1] / "AgentBridge/bin/notch-bridge.py"
QUESTION = "Which transport test answer should be returned?"


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


async def verify(cli, bridge_path):
    from claude_agent_sdk import (
        ClaudeAgentOptions, ClaudeSDKClient, HookMatcher, PermissionResultDeny,
        ResultMessage,
    )
    from importlib.metadata import version

    events = []
    fallbacks = []
    errors = []
    marker = "NOTCH_WIRE_" + secrets.token_hex(12)
    # Deliberately exceeds the old 4096-byte recv limit. The marker is never
    # included in the model prompt; a matching final reply proves consumption.
    answer = "多行答案分包测试。\n" * 600 + "\n" + marker
    response_bytes = 0
    question_count = 0
    cli_version = subprocess.check_output([cli, "--version"], text=True, timeout=10).strip()

    with tempfile.TemporaryDirectory(prefix="notch-claude-", dir="/tmp") as root:
        socket_path = str(Path(root) / "fixture.sock")

        async def respond(reader, writer):
            nonlocal response_bytes, question_count
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
                events.append({key: event.get(key) for key in (
                    "event", "status", "session_id", "tool_use_id", "tool"
                )})
                if event.get("event") == "PreToolUse":
                    tool_input = event.get("tool_input", {})
                    questions = tool_input.get("questions", [])
                    if (event.get("tool") != "AskUserQuestion"
                            or not event.get("tool_use_id")
                            or [item.get("question") for item in questions] != [QUESTION]):
                        raise ValueError("unexpected tool/question in isolated fixture")
                    question_count += 1
                    response = json.dumps({
                        "decision": "allow",
                        "updated_input": {**tool_input, "answers": {QUESTION: answer}},
                    }, ensure_ascii=False).encode()
                    response_bytes = len(response)
                    # Exercise stream framing and UTF-8 splits on the real run.
                    for offset in range(0, len(response), 997):
                        writer.write(response[offset:offset + 997])
                        await writer.drain()
                        await asyncio.sleep(0.002)
            except Exception as error:
                errors.append(type(error).__name__ + ": " + str(error))
            finally:
                writer.close()
                await writer.wait_closed()

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
            cli_path=cli, cwd=root, tools=["AskUserQuestion"],
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
        result = None
        server = await asyncio.start_unix_server(respond, path=socket_path)
        os.chmod(socket_path, 0o600)
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

        answer_consumed = result is not None and (result.result or "").strip() == marker
        starts = [event for event in events if event["event"] == "PreToolUse"]
        finishes = [event for event in events if event["event"] == "PostToolUse"]
        identity_preserved = (
            len(starts) == len(finishes) == 1
            and starts[0]["tool_use_id"] == finishes[0]["tool_use_id"]
            and starts[0]["session_id"] is not None
            and all(event["session_id"] == starts[0]["session_id"] for event in events)
        )
        passed = (result is not None and not result.is_error
                  and answer_consumed and question_count == 1 and identity_preserved
                  and response_bytes > 4096 and not fallbacks and not errors
                  and any(event["event"] == "PostToolUse" for event in events)
                  and any(event["event"] == "Stop" for event in events))
        report = {
            "passed": passed, "scope": "real CLI/SDK and production bridge; fixture UI",
            "cli_version": cli_version,
            "bridge_sha256": hashlib.sha256(bridge_path.read_bytes()).hexdigest(),
            "sdk_version": version("claude-agent-sdk"), "response_bytes": response_bytes,
            "answer_consumed": answer_consumed, "identity_preserved": identity_preserved,
            "result_subtype": result.subtype if result else None,
            "fallback_permission_calls": fallbacks, "events": events, "errors": errors,
            "excluded": ["native notch UI", "session persistence", "PermissionRequest"],
        }
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="Run one real Claude test turn")
    parser.add_argument("--claude", default=shutil.which("claude"))
    parser.add_argument("--bridge", type=Path, default=BRIDGE_PATH,
                        help="Bridge script to verify (defaults to the repository copy)")
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
                return await verify(args.claude, args.bridge.resolve())
        raise SystemExit(0 if asyncio.run(bounded_run()) else 1)
    else:
        parser.error("Pass --live to opt into a real model call (up to $0.50 API budget)")


if __name__ == "__main__":
    main()
