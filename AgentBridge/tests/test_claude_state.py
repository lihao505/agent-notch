import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch


SCRIPT_PATH = (
    Path(__file__).parents[2]
    / "ClaudeIsland"
    / "Resources"
    / "claude-island-state.py"
)
SPEC = importlib.util.spec_from_file_location("agent_notch_claude_state", SCRIPT_PATH)
STATE_HOOK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STATE_HOOK)


class ClaudeApprovalPolicyTests(unittest.TestCase):
    def test_socket_path_is_uid_scoped_and_overrideable(self):
        with patch.dict(os.environ, {"AGENT_NOTCH_SOCKET": ""}, clear=False):
            self.assertEqual(
                STATE_HOOK.default_socket_path(),
                f"/tmp/agent-notch-{os.getuid()}.sock",
            )
        with patch.dict(
            os.environ,
            {"AGENT_NOTCH_SOCKET": "/tmp/test-agent-notch.sock"},
            clear=False,
        ):
            self.assertEqual(
                STATE_HOOK.default_socket_path(),
                "/tmp/test-agent-notch.sock",
            )

    def test_socket_authentication_rejects_public_path_and_wrong_peer(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "agent-notch.sock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.addCleanup(server.close)
            server.bind(path)
            server.listen(1)

            with patch.object(STATE_HOOK, "SOCKET_PATH", path):
                os.chmod(path, 0o666)
                self.assertFalse(STATE_HOOK.send_event({"status": "processing"}))

                os.chmod(path, 0o600)
                with patch.object(
                    STATE_HOOK, "_peer_uid", return_value=os.getuid() + 1
                ):
                    self.assertFalse(
                        STATE_HOOK.send_event({"status": "processing"})
                    )
                connection, _ = server.accept()
                connection.close()

    def test_connected_peer_uid_matches_current_user(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        self.assertEqual(STATE_HOOK._peer_uid(left), os.getuid())

    def test_session_override_and_default_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            policy = Path(directory) / "approval-policy.json"
            policy.write_text(json.dumps({
                "mode": "trusted",
                "sessions": {"manual-session": "ask"},
            }))
            with patch.object(
                STATE_HOOK, "APPROVAL_POLICY_FILE", str(policy)
            ), patch.dict(
                os.environ, {"NOTCH_APPROVAL_MODE": ""}, clear=False
            ):
                self.assertEqual(
                    STATE_HOOK.current_approval_mode("manual-session"),
                    "ask",
                )
                self.assertEqual(
                    STATE_HOOK.current_approval_mode("other-session"),
                    "trusted",
                )

    def test_interactive_tools_are_never_auto_approved(self):
        with patch.object(
            STATE_HOOK, "current_approval_mode", return_value="trusted"
        ):
            self.assertFalse(
                STATE_HOOK.should_auto_approve("session-1", "AskUserQuestion")
            )
            self.assertFalse(
                STATE_HOOK.should_auto_approve("session-1", "ExitPlanMode")
            )
            self.assertTrue(
                STATE_HOOK.should_auto_approve("session-1", "Bash")
            )

    def test_trusted_permission_outputs_allow_without_blocking(self):
        payload = {
            "session_id": "session-1",
            "cwd": "/tmp/demo",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": {"command": "pwd"},
        }
        sent = []
        stdout = io.StringIO()
        with patch.object(
            STATE_HOOK, "current_approval_mode", return_value="trusted"
        ), patch.object(
            STATE_HOOK, "get_tty", return_value=None
        ), patch.object(
            STATE_HOOK, "send_event", side_effect=lambda state: sent.append(state)
        ), patch.object(
            STATE_HOOK.sys, "stdin", io.StringIO(json.dumps(payload))
        ), patch.object(
            STATE_HOOK.sys, "stdout", stdout
        ), self.assertRaises(SystemExit) as exit_context:
            STATE_HOOK.main()

        self.assertEqual(exit_context.exception.code, 0)
        output = json.loads(stdout.getvalue())
        self.assertEqual(
            output["hookSpecificOutput"]["decision"]["behavior"],
            "allow",
        )
        self.assertEqual(sent[0]["status"], "processing")

    def test_auto_permission_requires_live_app(self):
        payload = {
            "session_id": "session-auto",
            "cwd": "/tmp/demo",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": {"command": "pwd"},
        }
        stdout = io.StringIO()
        with patch.object(
            STATE_HOOK, "current_approval_mode", return_value="auto"
        ), patch.object(
            STATE_HOOK, "get_tty", return_value=None
        ), patch.object(
            STATE_HOOK, "send_event", return_value=False
        ), patch.object(
            STATE_HOOK.sys, "stdin", io.StringIO(json.dumps(payload))
        ), patch.object(
            STATE_HOOK.sys, "stdout", stdout
        ), self.assertRaises(SystemExit) as exit_context:
            STATE_HOOK.main()

        self.assertEqual(exit_context.exception.code, 0)
        self.assertEqual(stdout.getvalue(), "")

    def test_auto_permission_allows_with_live_app(self):
        payload = {
            "session_id": "session-auto",
            "cwd": "/tmp/demo",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": {"command": "pwd"},
        }
        stdout = io.StringIO()
        with patch.object(
            STATE_HOOK, "current_approval_mode", return_value="auto"
        ), patch.object(
            STATE_HOOK, "get_tty", return_value=None
        ), patch.object(
            STATE_HOOK, "send_event", return_value=True
        ), patch.object(
            STATE_HOOK.sys, "stdin", io.StringIO(json.dumps(payload))
        ), patch.object(
            STATE_HOOK.sys, "stdout", stdout
        ), self.assertRaises(SystemExit):
            STATE_HOOK.main()

        self.assertEqual(
            json.loads(stdout.getvalue())["hookSpecificOutput"]["decision"][
                "behavior"
            ],
            "allow",
        )

    def test_manual_permission_gets_an_event_local_socket_id(self):
        payload = {
            "session_id": "session-manual",
            "cwd": "/tmp/demo",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": {"command": "pwd"},
        }
        sent = []
        stdout = io.StringIO()

        def answer(state):
            sent.append(state)
            return {"decision": "allow"}

        with patch.object(
            STATE_HOOK, "current_approval_mode", return_value="ask"
        ), patch.object(
            STATE_HOOK, "get_tty", return_value=None
        ), patch.object(
            STATE_HOOK, "send_event", side_effect=answer
        ), patch.object(
            STATE_HOOK.sys, "stdin", io.StringIO(json.dumps(payload))
        ), patch.object(
            STATE_HOOK.sys, "stdout", stdout
        ), self.assertRaises(SystemExit) as exit_context:
            STATE_HOOK.main()

        self.assertEqual(exit_context.exception.code, 0)
        self.assertEqual(sent[0]["status"], "waiting_for_approval")
        self.assertTrue(
            sent[0]["tool_use_id"].startswith(
                "permission-session-manual-"
            )
        )
        self.assertEqual(
            json.loads(stdout.getvalue())["hookSpecificOutput"]["decision"][
                "behavior"
            ],
            "allow",
        )


if __name__ == "__main__":
    unittest.main()
