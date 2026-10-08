import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
import uuid


SPEC = importlib.util.spec_from_file_location(
    "permission_verifier", Path(__file__).parents[1] / "verify-claude-permission.py"
)
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class PermissionVerifierTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory(prefix="notch-permission-verifier-")
        self.addCleanup(self.root.cleanup)
        self.fixture = Path(self.root.name).resolve()
        (self.fixture / "allow-executed").mkdir()
        self.session = str(uuid.uuid4())
        self.rows = []
        for stage, reply in (("allow", "ALLOWED"), ("deny", "DENIED")):
            identity = "tool-" + stage
            self.rows.extend([
                self.row("assistant", message={"content": [{
                    "type": "tool_use", "id": identity, "name": "Bash",
                    "input": {"command": f"/bin/bash {self.fixture}/approval-tool.sh {stage}"}
                }]}),
                self.row("attachment", attachment={
                    "type": "hook_permission_decision", "hookEvent": "PermissionRequest",
                    "toolUseID": identity, "decision": stage
                }),
                self.row("user", message={"content": [{
                    "type": "tool_result", "tool_use_id": identity,
                    "is_error": stage == "deny", "content": (
                        "PERMISSION_ACCEPTANCE_allow_EXECUTED" if stage == "allow"
                        else "Denied by user via Agent Notch")
                }]}),
                self.row("assistant", message={"content": [{"type": "text", "text": reply}]})
            ])

    def row(self, kind, **values):
        return {"type": kind, "sessionId": self.session, "cwd": str(self.fixture), **values}

    def check(self, rows=None):
        return VERIFIER.verify(self.rows if rows is None else rows, self.session, self.fixture)

    def test_complete_exact_request_sequence_passes_with_redacted_report(self):
        report = self.check()
        self.assertTrue(report["passed"])
        self.assertNotIn(self.session, str(report))
        self.assertNotIn(str(self.fixture), str(report))

    def test_other_session_or_directory_is_rejected(self):
        for field, value in (("sessionId", str(uuid.uuid4())), ("cwd", "/tmp/unrelated")):
            rows = copy.deepcopy(self.rows)
            rows[0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check(rows)

    def test_cross_request_decision_or_result_is_rejected(self):
        for index, field in ((1, "toolUseID"), (2, "tool_use_id")):
            rows = copy.deepcopy(self.rows)
            target = rows[index]["attachment"] if index == 1 else rows[index]["message"]["content"][0]
            target[field] = "tool-deny"
            with self.subTest(index=index), self.assertRaises(ValueError):
                self.check(rows)

    def test_reused_identity_and_wrong_final_reply_are_rejected(self):
        rows = copy.deepcopy(self.rows)
        rows[4]["message"]["content"][0]["id"] = "tool-allow"
        with self.assertRaises(ValueError):
            self.check(rows)
        rows = copy.deepcopy(self.rows)
        rows[7]["message"]["content"][0]["text"] = "ALLOWED"
        with self.assertRaises(ValueError):
            self.check(rows)

    def test_interleaved_requests_are_not_sequential_acceptance(self):
        rows = self.rows[:3] + self.rows[4:5] + self.rows[3:4] + self.rows[5:]
        with self.assertRaises(ValueError):
            self.check(rows)

    def test_wrong_decision_or_result_cannot_pass(self):
        mutations = [(1, "decision", "deny"), (2, "is_error", True),
                     (2, "content", "fake marker"), (6, "is_error", False),
                     (6, "content", "unrelated tool error")]
        for index, key, value in mutations:
            rows = copy.deepcopy(self.rows)
            target = rows[index]["attachment"] if index == 1 else rows[index]["message"]["content"][0]
            target[key] = value
            with self.subTest(index=index, key=key), self.assertRaises(ValueError):
                self.check(rows)

    def test_wrong_order_duplicate_and_missing_events_are_rejected(self):
        for rows in (self.rows[:1] + self.rows[2:3] + self.rows[1:2] + self.rows[3:],
                     self.rows + self.rows[1:2], self.rows[:-1]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                self.check(rows)

    def test_unexpected_command_or_tool_is_rejected(self):
        for key, value in (("name", "Read"), ("command", "/bin/bash /tmp/unrelated.sh allow")):
            rows = copy.deepcopy(self.rows)
            tool = rows[0]["message"]["content"][0]
            (tool["input"] if key == "command" else tool)[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check(rows)

    def test_missing_execution_and_unexpected_denied_execution_are_rejected(self):
        (self.fixture / "allow-executed").rmdir()
        with self.assertRaises(ValueError):
            self.check()
        (self.fixture / "allow-executed").mkdir()
        (self.fixture / "deny-executed").mkdir()
        with self.assertRaises(ValueError):
            self.check()

    def test_malformed_rows_and_non_permission_decisions_are_rejected(self):
        rows = copy.deepcopy(self.rows)
        rows[1]["attachment"]["hookEvent"] = "PreToolUse"
        for invalid in ([None], rows):
            with self.assertRaises(ValueError):
                self.check(invalid)

    def test_invalid_message_shapes_cannot_hide_extra_tools(self):
        for value in (None, 42, {"type": "tool_use"}, "fake assistant text"):
            rows = copy.deepcopy(self.rows)
            rows.append(self.row("assistant", message={"content": value}))
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.check(rows)

    def test_execution_marker_symlinks_are_rejected(self):
        (self.fixture / "deny-executed").symlink_to(self.fixture / "missing")
        with self.assertRaises(ValueError):
            self.check()


if __name__ == "__main__":
    unittest.main()
