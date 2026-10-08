#!/usr/bin/env python3
"""Read-only verifier for an isolated real CLI Allow/Deny acceptance transcript.

This does not generate requests, click the UI, or change approval policies.
Pair the report with native pending-card and diagnostics observations.
"""
import argparse
import json
from pathlib import Path
import shlex
import uuid


def verify(rows, session_id, fixture):
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transcript", required=True, type=Path)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--fixture-dir", required=True, type=Path)
    args = parser.parse_args()
    try:
        with args.transcript.open() as source:
            rows = [json.loads(line) for line in source if line.strip()]
        report = verify(rows, args.session_id, args.fixture_dir)
    except (OSError, ValueError, TypeError, AttributeError) as error:
        parser.exit(1, "Permission acceptance failed: " + str(error) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
