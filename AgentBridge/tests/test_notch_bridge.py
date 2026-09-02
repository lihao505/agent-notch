import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch


BRIDGE_PATH = Path(__file__).parents[1] / "bin" / "notch-bridge.py"
SPEC = importlib.util.spec_from_file_location("notch_bridge", BRIDGE_PATH)
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


class SyntheticTranscriptTests(unittest.TestCase):
    def test_synthetic_transcript_uses_persisted_custom_claude_dir(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ,
            {"HOME": home, "CLAUDE_CONFIG_DIR": ""},
            clear=False,
        ):
            custom = Path(home) / "custom-claude"
            state = Path(home) / ".multiagent-notch"
            state.mkdir()
            (state / "config.json").write_text(json.dumps({
                "claude_config_dir": str(custom),
            }))

            directory, transcript = BRIDGE._synthetic_paths(
                "/tmp/demo",
                "session-1",
            )
            self.assertTrue(Path(directory).is_relative_to(custom / "projects"))
            self.assertEqual(Path(transcript).parent, Path(directory))

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


class SessionSnapshotTests(unittest.TestCase):
    def test_snapshot_is_private_and_excludes_prompt_and_tool_input(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ):
            path = BRIDGE.persist_session_snapshot({
                "session_id": "session-1",
                "cwd": "/tmp/demo",
                "source": "codex",
                "event": "PreToolUse",
                "status": "running_tool",
                "pid": 123,
                "tty": "/dev/ttys001",
                "prompt": "private prompt",
                "tool_input": {"command": "private command"},
            }, observed_at=100)

            self.assertIsNotNone(path)
            snapshot = Path(path)
            payload = json.loads(snapshot.read_text())
            self.assertEqual(payload["version"], 1)
            self.assertEqual(payload["observed_at"], 100)
            self.assertEqual(payload["session_id"], "session-1")
            self.assertEqual(payload["status"], "running_tool")
            self.assertEqual(payload["pid"], 123)
            self.assertNotIn("prompt", payload)
            self.assertNotIn("tool_input", payload)
            self.assertEqual(snapshot.stat().st_mode & 0o777, 0o600)
            self.assertEqual(snapshot.parent.stat().st_mode & 0o777, 0o700)

    def test_snapshot_directory_symlink_is_refused(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ):
            state = Path(home) / ".multiagent-notch"
            outside = Path(home) / "outside"
            state.mkdir()
            outside.mkdir()
            (state / "session-state").symlink_to(outside, target_is_directory=True)

            path = BRIDGE.persist_session_snapshot({
                "session_id": "session-1",
                "cwd": "/tmp/demo",
                "source": "codex",
                "event": "UserPromptSubmit",
                "status": "processing",
                "pid": 123,
            })

            self.assertIsNone(path)
            self.assertEqual(list(outside.iterdir()), [])

    def test_lifecycle_only_hook_persists_without_socket_delivery(self):
        payload = {
            "session_id": "claude-session-1",
            "cwd": "/tmp/demo",
            "hook_event_name": "UserPromptSubmit",
        }
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ), patch.object(
            BRIDGE.sys,
            "argv",
            ["notch-bridge.py", "--source", "claude", "--lifecycle-only"],
        ), patch.object(
            BRIDGE.sys, "stdin", io.StringIO(json.dumps(payload))
        ), patch.object(
            BRIDGE, "get_tty", return_value="/dev/ttys001"
        ), patch.object(
            BRIDGE, "process_expired_cleanups"
        ), patch.object(
            BRIDGE, "send_event"
        ) as send_event, self.assertRaises(SystemExit) as exit_context:
            BRIDGE.main()

            self.assertEqual(exit_context.exception.code, 0)
            send_event.assert_not_called()
            snapshots = list(Path(home).joinpath(
                ".multiagent-notch/session-state"
            ).glob("*.json"))
            self.assertEqual(len(snapshots), 1)
            restored = json.loads(snapshots[0].read_text())
            self.assertEqual(restored["source"], "claude")
            self.assertEqual(restored["status"], "processing")
            self.assertIsInstance(restored["observed_at"], float)

    def test_live_event_uses_one_observation_time_for_disk_and_socket(self):
        payload = {
            "session_id": "session-ordered",
            "cwd": "/tmp/demo",
            "hook_event_name": "UserPromptSubmit",
        }
        with patch.object(
            BRIDGE.sys,
            "argv",
            ["notch-bridge.py", "--source", "codex"],
        ), patch.object(
            BRIDGE.sys, "stdin", io.StringIO(json.dumps(payload))
        ), patch.object(
            BRIDGE.time, "time", return_value=1234.5
        ), patch.object(
            BRIDGE, "get_tty", return_value=None
        ), patch.object(
            BRIDGE, "process_expired_cleanups"
        ), patch.object(
            BRIDGE, "write_synthetic"
        ), patch.object(
            BRIDGE, "persist_session_snapshot"
        ) as persist, patch.object(
            BRIDGE, "send_event", return_value=True
        ) as send, self.assertRaises(SystemExit) as exit_context:
            BRIDGE.main()

        self.assertEqual(exit_context.exception.code, 0)
        persisted_state = persist.call_args.args[0]
        sent_state = send.call_args.args[1]
        self.assertEqual(persist.call_args.kwargs["observed_at"], 1234.5)
        self.assertEqual(persisted_state["observed_at"], 1234.5)
        self.assertEqual(sent_state["observed_at"], 1234.5)

    def test_terminal_event_removes_snapshot(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ):
            path = BRIDGE.persist_session_snapshot({
                "session_id": "session-1",
                "cwd": "/tmp/demo",
                "source": "codex",
                "event": "UserPromptSubmit",
                "status": "processing",
                "pid": 123,
            })
            self.assertTrue(Path(path).exists())
            self.assertTrue(BRIDGE.remove_session_snapshot("codex", "session-1"))
            self.assertFalse(Path(path).exists())


class SessionCleanupTests(unittest.TestCase):
    def test_completed_turn_default_retention_is_five_hours(self):
        self.assertEqual(BRIDGE.COMPLETED_TTL, 5 * 60 * 60)

    def test_active_event_cancels_pending_completed_cleanup(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ):
            token = BRIDGE.schedule_cleanup(
                "codex", "session-1", "/tmp/demo", "/tmp/notch.sock", delay=300
            )
            marker = Path(BRIDGE._cleanup_marker("codex", "session-1")[1])
            self.assertTrue(token)
            self.assertTrue(marker.exists())
            metadata = json.loads(marker.read_text())
            self.assertEqual(metadata["session_id"], "session-1")
            self.assertEqual(metadata["source"], "codex")
            self.assertAlmostEqual(
                metadata["expires_at"] - metadata["created_at"],
                300,
            )

            BRIDGE.cancel_scheduled_cleanup("codex", "session-1")
            self.assertFalse(marker.exists())

    def test_expired_marker_sends_ended_without_sleep_worker(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ), patch.object(BRIDGE, "send_event", return_value=True) as send_event:
            directory, marker = BRIDGE._cleanup_marker("codex", "session-1")
            Path(directory).mkdir(parents=True)
            Path(marker).write_text(json.dumps({
                "token": "current",
                "source": "codex",
                "session_id": "session-1",
                "cwd": "/tmp/demo",
                "expires_at": 99,
            }))
            count = BRIDGE.process_expired_cleanups("/tmp/notch.sock", now=100)
            self.assertEqual(count, 1)
            send_event.assert_called_once()
            state = send_event.call_args.args[1]
            self.assertEqual(state["status"], "ended")
            self.assertFalse(Path(marker).exists())

    def test_expired_marker_is_retried_when_app_is_offline(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ), patch.object(BRIDGE, "send_event", return_value=False) as send_event:
            directory, marker = BRIDGE._cleanup_marker("codex", "session-1")
            Path(directory).mkdir(parents=True)
            Path(marker).write_text(json.dumps({
                "token": "current",
                "source": "codex",
                "session_id": "session-1",
                "cwd": "/tmp/demo",
                "expires_at": 99,
            }))
            snapshot = BRIDGE.persist_session_snapshot({
                "session_id": "session-1",
                "cwd": "/tmp/demo",
                "source": "codex",
                "event": "Stop",
                "status": "waiting_for_input",
                "pid": 123,
            }, observed_at=90)

            count = BRIDGE.process_expired_cleanups("/tmp/notch.sock", now=100)

            self.assertEqual(count, 0)
            send_event.assert_called_once()
            self.assertTrue(Path(marker).exists())
            self.assertFalse(Path(snapshot).exists())

    def test_invalid_marker_missing_fields_does_not_crash(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ):
            directory, marker = BRIDGE._cleanup_marker("codex", "session-1")
            Path(directory).mkdir(parents=True)
            Path(marker).write_text("{}")

            count = BRIDGE.process_expired_cleanups("/tmp/notch.sock", now=100)

            self.assertEqual(count, 0)
            self.assertFalse(Path(marker).exists())

    def test_cleanup_directory_symlink_is_refused(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ):
            state = Path(home) / ".multiagent-notch"
            outside = Path(home) / "outside"
            state.mkdir()
            outside.mkdir()
            victim = outside / ("a" * 32 + ".json")
            victim.write_text("{}")
            (state / "session-cleanup").symlink_to(outside, target_is_directory=True)

            count = BRIDGE.process_expired_cleanups("/tmp/notch.sock", now=100)

            self.assertEqual(count, 0)
            self.assertTrue(victim.exists())

    def test_cleanup_marker_symlink_is_refused(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ):
            directory, marker = BRIDGE._cleanup_marker("codex", "session-1")
            Path(directory).mkdir(parents=True)
            victim = Path(home) / "victim.json"
            victim.write_text("{}")
            Path(marker).symlink_to(victim)

            count = BRIDGE.process_expired_cleanups("/tmp/notch.sock", now=100)

            self.assertEqual(count, 0)
            self.assertTrue(Path(marker).is_symlink())
            self.assertTrue(victim.exists())

    def test_cleanup_directory_and_marker_require_current_user_ownership(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ):
            directory, marker = BRIDGE._cleanup_marker("codex", "session-1")
            Path(directory).mkdir(parents=True)
            Path(marker).write_text("{}")
            current_uid = os.getuid()

            with patch.object(BRIDGE.os, "getuid", return_value=current_uid + 1):
                self.assertIsNone(
                    BRIDGE._real_private_directory(directory, create=False)
                )
                self.assertFalse(BRIDGE._regular_cleanup_marker(marker))

    def test_future_marker_remains_without_emitting(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ), patch.object(BRIDGE, "send_event") as send_event:
            directory, marker = BRIDGE._cleanup_marker("codex", "session-1")
            Path(directory).mkdir(parents=True)
            Path(marker).write_text(json.dumps({
                "token": "newer",
                "source": "codex",
                "session_id": "session-1",
                "cwd": "/tmp/demo",
                "expires_at": 101,
            }))
            count = BRIDGE.process_expired_cleanups("/tmp/notch.sock", now=100)
            self.assertEqual(count, 0)
            send_event.assert_not_called()
            self.assertTrue(Path(marker).exists())

    def test_legacy_marker_is_removed_after_original_retention(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(
            os.environ, {"HOME": home}, clear=False
        ), patch.object(BRIDGE, "send_event") as send_event:
            directory, marker = BRIDGE._cleanup_marker("codex", "session-1")
            Path(directory).mkdir(parents=True)
            Path(marker).write_text(json.dumps({
                "token": "legacy",
                "created_at": 100,
            }))

            count = BRIDGE.process_expired_cleanups(
                "/tmp/notch.sock",
                now=100 + BRIDGE.COMPLETED_TTL + 1,
            )

            self.assertEqual(count, 1)
            send_event.assert_not_called()
            self.assertFalse(Path(marker).exists())

    def test_default_socket_is_uid_scoped_and_overrideable(self):
        with patch.dict(os.environ, {"AGENT_NOTCH_SOCKET": ""}, clear=False):
            self.assertEqual(
                BRIDGE.default_socket_path(),
                f"/tmp/agent-notch-{os.getuid()}.sock",
            )
        with patch.dict(
            os.environ,
            {"AGENT_NOTCH_SOCKET": "/tmp/custom-agent-notch.sock"},
            clear=False,
        ):
            self.assertEqual(
                BRIDGE.default_socket_path(),
                "/tmp/custom-agent-notch.sock",
            )

    def test_unsafe_session_id_cannot_escape_transcript_directory(self):
        with self.assertRaises(ValueError):
            BRIDGE._synthetic_paths("/tmp/demo", "../../outside")


class InteractiveDecisionTests(unittest.TestCase):
    def test_socket_path_requires_private_mode_and_current_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "agent-notch.sock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.addCleanup(server.close)
            server.bind(path)
            os.chmod(path, 0o600)

            self.assertIsNotNone(BRIDGE._private_socket_info(path))
            os.chmod(path, 0o666)
            self.assertIsNone(BRIDGE._private_socket_info(path))
            os.chmod(path, 0o600)
            current_uid = os.getuid()
            with patch.object(BRIDGE.os, "getuid", return_value=current_uid + 1):
                self.assertIsNone(BRIDGE._private_socket_info(path))

    def test_socket_symlink_is_never_trusted(self):
        with tempfile.TemporaryDirectory() as directory:
            socket_path = Path(directory) / "real.sock"
            link_path = Path(directory) / "linked.sock"
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.addCleanup(server.close)
            server.bind(str(socket_path))
            os.chmod(socket_path, 0o600)
            link_path.symlink_to(socket_path)

            self.assertIsNone(BRIDGE._private_socket_info(str(link_path)))

    def test_connected_peer_uid_is_verified(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        self.assertEqual(BRIDGE._peer_uid(left), os.getuid())

    def test_send_event_rejects_peer_with_different_uid(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "agent-notch.sock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.addCleanup(server.close)
            server.bind(path)
            os.chmod(path, 0o600)
            server.listen(1)

            with patch.object(BRIDGE, "_peer_uid", return_value=os.getuid() + 1):
                self.assertFalse(BRIDGE.send_event(path, {"event": "Stop"}, False))
            connection, _ = server.accept()
            connection.close()

    def test_codex_permission_decision_matches_official_schema(self):
        self.assertEqual(
            BRIDGE.format_decision("codex", "allow", ""),
            {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {"behavior": "allow"},
                }
            },
        )
        self.assertEqual(
            BRIDGE.format_decision("codex", "deny", "unsafe"),
            {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {
                        "behavior": "deny",
                        "message": "unsafe",
                    },
                }
            },
        )

    def test_default_permission_timeout_is_bounded(self):
        self.assertEqual(BRIDGE.PERMISSION_TIMEOUT, 90)

    def test_timeout_environment_values_are_safely_bounded(self):
        with patch.dict(os.environ, {"TEST_TIMEOUT": "not-a-number"}, clear=False):
            self.assertEqual(BRIDGE.bounded_env_seconds("TEST_TIMEOUT", 7), 7)
        with patch.dict(os.environ, {"TEST_TIMEOUT": "-5"}, clear=False):
            self.assertEqual(
                BRIDGE.bounded_env_seconds("TEST_TIMEOUT", 7),
                0.1,
            )
        with patch.dict(os.environ, {"TEST_TIMEOUT": "999"}, clear=False):
            self.assertEqual(
                BRIDGE.bounded_env_seconds("TEST_TIMEOUT", 7),
                90,
            )
        with patch.dict(os.environ, {"TEST_TIMEOUT": "nan"}, clear=False):
            self.assertEqual(BRIDGE.bounded_env_seconds("TEST_TIMEOUT", 7), 7)

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

    def test_auto_permission_requires_live_app(self):
        payload = {
            "session_id": "session-auto",
            "cwd": "/tmp/demo",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Shell",
            "tool_input": {"command": "pwd"},
        }
        stdout = io.StringIO()
        with patch.object(
            BRIDGE, "current_approval_mode", return_value="auto"
        ), patch.object(
            BRIDGE, "get_tty", return_value=None
        ), patch.object(
            BRIDGE, "write_synthetic"
        ), patch.object(
            BRIDGE, "process_expired_cleanups"
        ), patch.object(
            BRIDGE, "persist_session_snapshot"
        ), patch.object(
            BRIDGE, "send_event", return_value=False
        ), patch.object(
            BRIDGE.sys, "stdin", io.StringIO(json.dumps(payload))
        ), patch.object(
            BRIDGE.sys, "stdout", stdout
        ), self.assertRaises(SystemExit) as exit_context:
            BRIDGE.main()

        self.assertEqual(exit_context.exception.code, 0)
        self.assertEqual(stdout.getvalue(), "")

    def test_auto_permission_allows_when_app_is_live(self):
        payload = {
            "session_id": "session-auto",
            "cwd": "/tmp/demo",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Shell",
            "tool_input": {"command": "pwd"},
        }
        stdout = io.StringIO()
        with patch.object(
            BRIDGE, "current_approval_mode", return_value="auto"
        ), patch.object(
            BRIDGE, "get_tty", return_value=None
        ), patch.object(
            BRIDGE, "write_synthetic"
        ), patch.object(
            BRIDGE, "process_expired_cleanups"
        ), patch.object(
            BRIDGE, "persist_session_snapshot"
        ), patch.object(
            BRIDGE, "send_event", return_value=True
        ), patch.object(
            BRIDGE.sys, "stdin", io.StringIO(json.dumps(payload))
        ), patch.object(
            BRIDGE.sys, "stdout", stdout
        ), self.assertRaises(SystemExit):
            BRIDGE.main()

        self.assertEqual(
            json.loads(stdout.getvalue())["hookSpecificOutput"]["decision"][
                "behavior"
            ],
            "allow",
        )

    def test_trusted_permission_allows_while_app_is_offline(self):
        payload = {
            "session_id": "session-trusted",
            "cwd": "/tmp/demo",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Shell",
            "tool_input": {"command": "pwd"},
        }
        stdout = io.StringIO()
        with patch.object(
            BRIDGE, "current_approval_mode", return_value="trusted"
        ), patch.object(
            BRIDGE, "get_tty", return_value=None
        ), patch.object(
            BRIDGE, "write_synthetic"
        ), patch.object(
            BRIDGE, "process_expired_cleanups"
        ), patch.object(
            BRIDGE, "persist_session_snapshot"
        ), patch.object(
            BRIDGE, "send_event", return_value=False
        ), patch.object(
            BRIDGE.sys, "stdin", io.StringIO(json.dumps(payload))
        ), patch.object(
            BRIDGE.sys, "stdout", stdout
        ), self.assertRaises(SystemExit):
            BRIDGE.main()

        self.assertEqual(
            json.loads(stdout.getvalue())["hookSpecificOutput"]["decision"][
                "behavior"
            ],
            "allow",
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
