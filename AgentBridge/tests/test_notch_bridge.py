import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


BRIDGE_PATH = Path(__file__).parents[1] / "bin" / "notch-bridge.py"
SPEC = importlib.util.spec_from_file_location("notch_bridge", BRIDGE_PATH)
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


class SyntheticTranscriptTests(unittest.TestCase):
    def test_codebuddy_transcript_has_native_source_and_title(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ):
            BRIDGE.write_synthetic(
                "codebuddy",
                "buddy-session-1",
                "/tmp/codebuddy-demo",
                "UserPromptSubmit",
                {
                    "session_id": "buddy-session-1",
                    "prompt": "接入新的 agent",
                },
            )
            BRIDGE.write_synthetic(
                "codebuddy",
                "buddy-session-1",
                "/tmp/codebuddy-demo",
                "PreToolUse",
                {
                    "session_id": "buddy-session-1",
                    "tool_name": "Edit",
                    "tool_input": {"file_path": "AgentSource.swift"},
                    "tool_use_id": "buddy-tool-1",
                },
            )

            transcript = next(
                Path(home).joinpath(".claude/projects").rglob(
                    "buddy-session-1.jsonl"
                )
            )
            rows = [
                json.loads(line)
                for line in transcript.read_text().splitlines()
            ]
            self.assertEqual(rows[0]["summary"], "CodeBuddy · 接入新的 agent")
            self.assertTrue(
                all(row.get("source") == "codebuddy" for row in rows)
            )
            self.assertEqual(
                rows[-1]["message"]["content"][0]["name"],
                "Edit",
            )

    def test_codex_transcript_is_complete_and_deduplicated(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ):
            base = {
                "session_id": "session-1",
                "turn_id": "turn-1",
                "cwd": "/tmp/demo.project",
            }
            BRIDGE.write_synthetic(
                "codex",
                base["session_id"],
                base["cwd"],
                "UserPromptSubmit",
                {**base, "prompt": "Build the feature"},
            )
            BRIDGE.write_synthetic(
                "codex",
                base["session_id"],
                base["cwd"],
                "PreToolUse",
                {
                    **base,
                    "tool_name": "Shell",
                    "tool_input": {"command": "npm test"},
                    "tool_use_id": "tool-1",
                },
            )
            stop = {**base, "last_assistant_message": "Implemented and verified."}
            BRIDGE.write_synthetic(
                "codex", base["session_id"], base["cwd"], "Stop", stop
            )
            BRIDGE.write_synthetic(
                "codex",
                base["session_id"],
                base["cwd"],
                "SubagentStop",
                {**base, "last_assistant_message": "Child-only response"},
            )
            BRIDGE.write_synthetic(
                "codex", base["session_id"], base["cwd"], "Stop", stop
            )

            transcript = next(
                Path(home).joinpath(".claude/projects").rglob("session-1.jsonl")
            )
            rows = [json.loads(line) for line in transcript.read_text().splitlines()]

            self.assertEqual(
                [row["type"] for row in rows],
                ["summary", "user", "assistant", "assistant"],
            )
            self.assertEqual(rows[0]["summary"], "Codex · Build the feature")
            self.assertTrue(all(row.get("uuid") for row in rows))
            self.assertEqual(rows[2]["message"]["content"][0]["id"], "tool-1")
            self.assertEqual(
                rows[3]["message"]["content"][0]["text"],
                "Implemented and verified.",
            )
            self.assertTrue(all(row.get("source") == "codex" for row in rows))

    def test_codex_uses_real_sidebar_title_when_available(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ):
            codex_dir = Path(home) / ".codex"
            codex_dir.mkdir()
            (codex_dir / "session_index.jsonl").write_text(json.dumps({
                "id": "session-1",
                "thread_name": "修复登录权限",
            }) + "\n")
            BRIDGE.write_synthetic(
                "codex",
                "session-1",
                "/tmp/demo",
                "UserPromptSubmit",
                {
                    "session_id": "session-1",
                    "turn_id": "turn-1",
                    "prompt": "这是一条与侧边栏标题不同的很长原始提示",
                },
            )
            transcript = next(
                Path(home).joinpath(".claude/projects").rglob("session-1.jsonl")
            )
            raw = transcript.read_text()
            self.assertIn('"type":"summary"', raw)
            self.assertIn('"type":"user"', raw)
            first = json.loads(raw.splitlines()[0])
            self.assertEqual(first["summary"], "Codex · 修复登录权限")

    def test_tracked_spaced_jsonl_is_migrated_before_deduplication(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ):
            directory = Path(home) / ".claude/projects/-tmp-demo"
            directory.mkdir(parents=True)
            transcript = directory / "session-1.jsonl"
            entry = {
                "uuid": "entry-1",
                "type": "user",
                "message": {"role": "user", "content": "hello"},
            }
            transcript.write_text(json.dumps(entry) + "\n")

            index = Path(home) / ".multiagent-notch/synthetic-files.txt"
            index.parent.mkdir()
            index.write_text(str(transcript) + "\n")

            BRIDGE._append_jsonl(
                str(directory),
                str(transcript),
                entry,
                "session-1",
            )

            raw = transcript.read_text()
            self.assertIn('"type":"user"', raw)
            self.assertNotIn('"type": "user"', raw)
            self.assertEqual(len(raw.splitlines()), 1)

    def test_claude_keeps_its_native_transcript(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ):
            BRIDGE.write_synthetic(
                "claude",
                "session-1",
                "/tmp/demo",
                "UserPromptSubmit",
                {"prompt": "Do not synthesize this"},
            )
            self.assertFalse(Path(home).joinpath(".claude").exists())


class SessionCleanupTests(unittest.TestCase):
    def test_completed_turn_default_retention_is_five_hours(self):
        self.assertEqual(BRIDGE.COMPLETED_TTL, 5 * 60 * 60)

    def test_active_event_cancels_pending_completed_cleanup(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ), patch.object(BRIDGE.subprocess, "Popen") as popen:
            token = BRIDGE.schedule_cleanup(
                "codex", "session-1", "/tmp/demo", "/tmp/notch.sock", delay=300
            )
            marker = Path(BRIDGE._cleanup_marker("codex", "session-1")[1])
            self.assertTrue(token)
            self.assertTrue(marker.exists())
            popen.assert_called_once()

            BRIDGE.cancel_scheduled_cleanup("codex", "session-1")
            self.assertFalse(marker.exists())

    def test_cleanup_worker_sends_ended_only_for_current_token(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ), patch.object(BRIDGE, "send_event") as send_event:
            directory, marker = BRIDGE._cleanup_marker("codex", "session-1")
            Path(directory).mkdir(parents=True)
            Path(marker).write_text(json.dumps({"token": "current"}))
            opts = {
                "source": "codex",
                "socket": "/tmp/notch.sock",
                "cleanup_token": "current",
                "cleanup_session": "session-1",
                "cleanup_cwd": "/tmp/demo",
                "cleanup_delay": 0,
            }
            BRIDGE.run_cleanup_job(opts)
            send_event.assert_called_once()
            state = send_event.call_args.args[1]
            self.assertEqual(state["status"], "ended")
            self.assertFalse(Path(marker).exists())

    def test_stale_cleanup_worker_cannot_remove_resumed_session(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ), patch.object(BRIDGE, "send_event") as send_event:
            directory, marker = BRIDGE._cleanup_marker("codex", "session-1")
            Path(directory).mkdir(parents=True)
            Path(marker).write_text(json.dumps({"token": "newer"}))
            BRIDGE.run_cleanup_job({
                "source": "codex",
                "socket": "/tmp/notch.sock",
                "cleanup_token": "old",
                "cleanup_session": "session-1",
                "cleanup_cwd": "/tmp/demo",
                "cleanup_delay": 0,
            })
            send_event.assert_not_called()
            self.assertTrue(Path(marker).exists())

    def test_unsafe_session_id_cannot_escape_transcript_directory(self):
        with self.assertRaises(ValueError):
            BRIDGE._synthetic_paths("/tmp/demo", "../../outside")


class InteractiveDecisionTests(unittest.TestCase):
    def test_permission_request_without_native_tool_id_gets_bridge_id(self):
        generated = BRIDGE.permission_tool_use_id("codex-session")
        self.assertTrue(generated.startswith("permission-codex-session-"))
        self.assertNotEqual(generated, BRIDGE.permission_tool_use_id("codex-session"))

    def test_permission_request_preserves_native_tool_id(self):
        self.assertEqual(
            BRIDGE.permission_tool_use_id("codex-session", "tool-123"),
            "tool-123",
        )

    def test_approval_policy_defaults_to_single_approval(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(
            BRIDGE, "APPROVAL_POLICY_FILE", str(Path(directory) / "missing.json")
        ), patch.dict(os.environ, {"NOTCH_APPROVAL_MODE": ""}, clear=False):
            self.assertEqual(BRIDGE.current_approval_mode(), "ask")

    def test_approval_policy_accepts_auto_and_trusted_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            policy = Path(directory) / "approval-policy.json"
            policy.write_text(json.dumps({"mode": "trusted"}))
            with patch.object(BRIDGE, "APPROVAL_POLICY_FILE", str(policy)), patch.dict(
                os.environ, {"NOTCH_APPROVAL_MODE": ""}, clear=False
            ):
                self.assertEqual(BRIDGE.current_approval_mode(), "trusted")
            with patch.dict(os.environ, {"NOTCH_APPROVAL_MODE": "auto"}, clear=False):
                self.assertEqual(BRIDGE.current_approval_mode(), "auto")

    def test_session_approval_override_wins_over_default(self):
        with tempfile.TemporaryDirectory() as directory:
            policy = Path(directory) / "approval-policy.json"
            policy.write_text(json.dumps({
                "mode": "trusted",
                "sessions": {
                    "sensitive-session": "ask",
                    "routine-session": "auto",
                },
            }))
            with patch.object(BRIDGE, "APPROVAL_POLICY_FILE", str(policy)), patch.dict(
                os.environ, {"NOTCH_APPROVAL_MODE": ""}, clear=False
            ):
                self.assertEqual(
                    BRIDGE.current_approval_mode("sensitive-session"),
                    "ask",
                )
                self.assertEqual(
                    BRIDGE.current_approval_mode("routine-session"),
                    "auto",
                )
                self.assertEqual(
                    BRIDGE.current_approval_mode("new-session"),
                    "trusted",
                )

    def test_invalid_session_override_falls_back_to_default(self):
        with tempfile.TemporaryDirectory() as directory:
            policy = Path(directory) / "approval-policy.json"
            policy.write_text(json.dumps({
                "mode": "auto",
                "sessions": {"session-1": "always"},
            }))
            with patch.object(BRIDGE, "APPROVAL_POLICY_FILE", str(policy)), patch.dict(
                os.environ, {"NOTCH_APPROVAL_MODE": ""}, clear=False
            ):
                self.assertEqual(
                    BRIDGE.current_approval_mode("session-1"),
                    "auto",
                )

    def test_non_object_policy_fails_closed_to_single_approval(self):
        with tempfile.TemporaryDirectory() as directory:
            policy = Path(directory) / "approval-policy.json"
            policy.write_text("[]")
            with patch.object(BRIDGE, "APPROVAL_POLICY_FILE", str(policy)), patch.dict(
                os.environ, {"NOTCH_APPROVAL_MODE": ""}, clear=False
            ):
                self.assertEqual(
                    BRIDGE.current_approval_mode("session-1"),
                    "ask",
                )

    def test_question_response_echoes_questions_and_answers(self):
        original = {
            "questions": [{
                "question": "Which framework?",
                "header": "Framework",
                "options": [{"label": "React"}, {"label": "Vue"}],
                "multiSelect": False,
            }],
            "answers": {"Which framework?": "React"},
        }
        output = BRIDGE.format_interactive_decision(
            "allow",
            "",
            original,
        )
        specific = output["hookSpecificOutput"]
        self.assertEqual(specific["hookEventName"], "PreToolUse")
        self.assertEqual(specific["permissionDecision"], "allow")
        self.assertEqual(specific["updatedInput"], original)

    def test_interactive_denial_never_emits_updated_input(self):
        output = BRIDGE.format_interactive_decision(
            "deny",
            "Please revise the plan",
            {"plan": "unsafe"},
        )
        specific = output["hookSpecificOutput"]
        self.assertEqual(specific["permissionDecision"], "deny")
        self.assertEqual(
            specific["permissionDecisionReason"],
            "Please revise the plan",
        )
        self.assertNotIn("updatedInput", specific)


if __name__ == "__main__":
    unittest.main()
