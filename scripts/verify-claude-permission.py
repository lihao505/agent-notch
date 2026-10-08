#!/usr/bin/env python3
"""Read-only verifier for an isolated real CLI Allow/Deny acceptance transcript.

This does not generate requests, click the UI, or change approval policies.
Pair the report with native pending-card and diagnostics observations.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shlex
import uuid


def collect(rows, session_id, fixture):
    uuid.UUID(session_id)
    fixture = Path(fixture).resolve()
    tools, decisions, results, replies = [], [], [], []
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ValueError("non-object transcript row")
        if row.get("type") not in ("user", "assistant", "attachment"):
            continue
        if (row.get("sessionId") != session_id
                or Path(row.get("cwd", "")).resolve() != fixture):
            raise ValueError("row belongs to another session or directory")
        attachment = row.get("attachment") or {}
        if not isinstance(attachment, dict):
            raise ValueError("invalid attachment")
        if attachment.get("type") == "hook_permission_decision":
            if attachment.get("hookEvent") != "PermissionRequest":
                raise ValueError("decision is not from PermissionRequest")
            decisions.append((index, attachment))
        message = row.get("message") or {}
        if not isinstance(message, dict):
            raise ValueError("invalid message")
        content = message.get("content", [])
        if not isinstance(content, list):
            if row.get("type") == "user" and isinstance(content, str):
                continue  # Real prompts are strings; tools/results are arrays.
            raise ValueError("invalid message content")
        for block in content:
            if not isinstance(block, dict):
                raise ValueError("invalid message block")
            if block.get("type") == "tool_use":
                tools.append((index, block))
            elif block.get("type") == "tool_result":
                results.append((index, block))
            elif row.get("type") == "assistant" and block.get("type") == "text":
                replies.append((index, block.get("text", "").strip()))

    return tools, decisions, results, replies


def verify(rows, session_id, fixture):
    fixture = Path(fixture).resolve()
    tools, decisions, results, replies = collect(rows, session_id, fixture)
    if not (len(tools) == len(decisions) == len(results) == len(replies) == 2):
        raise ValueError("expected exactly two tools, decisions, results and final replies")
    seen = set()
    for ordinal, (stage, decision, reply) in enumerate((
            ("allow", "allow", "ALLOWED"), ("deny", "deny", "DENIED"))):
        tool_at, tool = tools[ordinal]
        decision_at, evidence = decisions[ordinal]
        result_at, result = results[ordinal]
        reply_at, final_reply = replies[ordinal]
        identity = tool.get("id")
        if not isinstance(identity, str) or not identity or identity in seen:
            raise ValueError("missing or reused tool identity")
        seen.add(identity)
        tokens = shlex.split(tool.get("input", {}).get("command", ""))
        if (tool.get("name") != "Bash" or len(tokens) != 3
                or tokens[0] != "/bin/bash"
                or Path(tokens[1]).resolve() != fixture / "approval-tool.sh"
                or tokens[2] != stage):
            raise ValueError("unexpected command in acceptance fixture")
        if (evidence.get("toolUseID") != identity
                or result.get("tool_use_id") != identity
                or evidence.get("decision") != decision):
            raise ValueError("decision/result does not match its exact request")
        if not tool_at < decision_at < result_at < reply_at:
            raise ValueError("request/decision/result/reply order is invalid")
        if ordinal == 1 and tool_at <= replies[0][0]:
            raise ValueError("requests are not two sequential acceptance turns")
        if final_reply != reply:
            raise ValueError("unexpected final reply")
        if result.get("is_error") is not (stage == "deny"):
            raise ValueError("tool success does not match the decision")
        if stage == "allow" and result.get("content", "").strip() != (
                "PERMISSION_ACCEPTANCE_allow_EXECUTED"):
            raise ValueError("allowed tool did not return the fixture marker")
        if stage == "deny" and result.get("content") != "Denied by user via Agent Notch":
            raise ValueError("denied tool did not receive the notch rejection")
    allowed_marker = fixture / "allow-executed"
    denied_marker = fixture / "deny-executed"
    if allowed_marker.is_symlink() or not allowed_marker.is_dir():
        raise ValueError("allowed fixture did not execute")
    if denied_marker.is_symlink() or denied_marker.exists():
        raise ValueError("denied fixture unexpectedly executed")
    return {"passed": True, "scope": "real CLI PermissionRequest transcript and fixture effects",
            "requests": 2, "identity_preserved": True, "allowed_executed": True,
            "denied_not_executed": True,
            "excluded": ["native UI observation", "timeout", "parallel requests"]}


def parallel_turn(rows, session_id, fixture, tool_id, label, decision):
    """Select one explicitly identified prompt turn, not a favorable log suffix."""
    fixture = Path(fixture).resolve()
    all_tools, _, _, _ = collect(rows, session_id, fixture)
    matches = [index for index, tool in all_tools if tool.get("id") == tool_id]
    if len(matches) != 1:
        raise ValueError("selected tool identity is missing or duplicated")
    tool_at = matches[0]
    prompts = [index for index, row in enumerate(rows)
               if row.get("type") == "user"
               and isinstance((row.get("message") or {}).get("content"), str)]
    preceding = [index for index in prompts if index < tool_at]
    if not preceding:
        raise ValueError("selected tool has no prompt boundary")
    start = preceding[-1]
    end = next((index for index in prompts if index > tool_at), len(rows))
    turn = rows[start:end]
    tools, decisions, results, replies = collect(turn, session_id, fixture)
    if not (len(tools) == len(decisions) == len(results) == 1):
        raise ValueError("parallel acceptance turn must contain exactly one request/decision/result")
    request_at, tool = tools[0]
    decision_at, evidence = decisions[0]
    result_at, result = results[0]
    finals = [(index, reply) for index, reply in replies if index > result_at]
    if len(finals) != 1:
        raise ValueError("expected one final reply after the parallel result")
    reply_at, reply = finals[0]
    if not request_at < decision_at < result_at < reply_at:
        raise ValueError("parallel request/decision/result/reply order is invalid")
    tokens = shlex.split(tool.get("input", {}).get("command", ""))
    if (tool.get("name") != "Bash" or len(tokens) != 2
            or tokens[0] != "/bin/bash"
            or Path(tokens[1]).resolve() != fixture / "parallel-tool.sh"):
        raise ValueError("unexpected command in parallel acceptance fixture")
    if (tool.get("id") != tool_id or evidence.get("toolUseID") != tool_id
            or result.get("tool_use_id") != tool_id
            or evidence.get("decision") != decision):
        raise ValueError("parallel decision/result does not match its exact request")
    allowed = decision == "allow"
    if result.get("is_error") is not (not allowed):
        raise ValueError("parallel tool success does not match its decision")
    expected_result = (f"PARALLEL_ACCEPTANCE_{label}_EXECUTED" if allowed
                       else "Denied by user via Agent Notch")
    if result.get("content", "").strip() != expected_result:
        raise ValueError("unexpected parallel tool result")
    if reply != f"{label}_{'ALLOWED' if allowed else 'DENIED'}":
        raise ValueError("unexpected parallel final reply")
    times = []
    for index in (request_at, decision_at, result_at, reply_at):
        timestamp = datetime.fromisoformat(turn[index].get("timestamp", "").replace("Z", "+00:00"))
        if timestamp.utcoffset() is None:
            raise ValueError("parallel timestamps must have an explicit timezone")
        times.append(timestamp)
    if times != sorted(times):
        raise ValueError("parallel timestamps contradict transcript order")
    marker = fixture / "tool-executed"
    if marker.is_symlink() or (not marker.is_dir() if allowed else marker.exists()):
        raise ValueError("parallel fixture execution does not match its decision")
    return times[:2]


def verify_parallel(allow_rows, allow_session, allow_fixture, allow_tool,
                    deny_rows, deny_session, deny_fixture, deny_tool):
    if (uuid.UUID(allow_session) == uuid.UUID(deny_session)
            or Path(allow_fixture).resolve() == Path(deny_fixture).resolve()
            or not allow_tool or not deny_tool or allow_tool == deny_tool):
        raise ValueError("parallel acceptance requires distinct sessions, directories and tool identities")
    a_request, a_decision = parallel_turn(
        allow_rows, allow_session, allow_fixture, allow_tool, "A", "allow")
    b_request, b_decision = parallel_turn(
        deny_rows, deny_session, deny_fixture, deny_tool, "B", "deny")
    if max(a_request, b_request) >= min(a_decision, b_decision):
        raise ValueError("tool request intervals do not overlap; sequential runs are not parallel evidence")
    return {"passed": True, "scope": "two real CLI turns with overlapping tool request intervals",
            "requests": 2, "identity_preserved": True, "allowed_executed": True,
            "denied_not_executed": True,
            "excluded": ["native UI observation", "timeout", "same-session FIFO", "other turns"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transcript", required=True, type=Path)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--fixture-dir", required=True, type=Path)
    parser.add_argument("--parallel-transcript", type=Path,
                        help="B denied transcript; primary transcript is A allowed")
    parser.add_argument("--parallel-session-id")
    parser.add_argument("--parallel-fixture-dir", type=Path)
    parser.add_argument("--allow-tool-id", help="Exact A request in its complete prompt turn")
    parser.add_argument("--deny-tool-id", help="Exact B request in its complete prompt turn")
    args = parser.parse_args()
    parallel_args = (args.parallel_transcript, args.parallel_session_id,
                     args.parallel_fixture_dir, args.allow_tool_id, args.deny_tool_id)
    if any(value is not None for value in parallel_args) and not all(parallel_args):
        parser.error("parallel mode requires all five parallel/identity arguments")
    try:
        with args.transcript.open() as source:
            rows = [json.loads(line) for line in source if line.strip()]
        if args.parallel_transcript:
            with args.parallel_transcript.open() as source:
                parallel_rows = [json.loads(line) for line in source if line.strip()]
            report = verify_parallel(rows, args.session_id, args.fixture_dir, args.allow_tool_id,
                                     parallel_rows, args.parallel_session_id,
                                     args.parallel_fixture_dir, args.deny_tool_id)
        else:
            report = verify(rows, args.session_id, args.fixture_dir)
    except (OSError, ValueError, TypeError, AttributeError) as error:
        parser.exit(1, "Permission acceptance failed: " + str(error) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
