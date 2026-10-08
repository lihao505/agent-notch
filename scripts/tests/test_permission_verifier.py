import copy
import importlib.util
from pathlib import Path
import subprocess
import sys
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


class ParallelPermissionVerifierTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory(prefix="notch-parallel-verifier-")
        self.addCleanup(self.root.cleanup)
        self.a = Path(self.root.name).resolve() / "A"
        self.b = Path(self.root.name).resolve() / "B"
        self.a.mkdir()
        self.b.mkdir()
        (self.a / "tool-executed").mkdir()
        self.sa, self.sb = str(uuid.uuid4()), str(uuid.uuid4())
        self.ra = self.turn(self.sa, self.a, "A", "allow", "tool-A", 0, 3)
        self.rb = self.turn(self.sb, self.b, "B", "deny", "tool-B", 1, 4)

    def turn(self, session, fixture, label, decision, tool, request, resolved):
        def row(kind, second, **values):
            return {"type": kind, "sessionId": session, "cwd": str(fixture),
                    "timestamp": f"2026-10-08T15:00:{second:02d}.000Z", **values}
        return [
            row("user", request, message={"content": "Acceptance prompt"}),
            row("assistant", request, message={"content": [{
                "type": "tool_use", "id": tool, "name": "Bash",
                "input": {"command": f"/bin/bash {fixture}/parallel-tool.sh"}}]}),
            row("attachment", resolved, attachment={
                "type": "hook_permission_decision", "hookEvent": "PermissionRequest",
                "toolUseID": tool, "decision": decision}),
            row("user", resolved, message={"content": [{
                "type": "tool_result", "tool_use_id": tool, "is_error": decision == "deny",
                "content": f"PARALLEL_ACCEPTANCE_{label}_EXECUTED" if decision == "allow"
                else "Denied by user via Agent Notch"}]}),
            row("assistant", resolved + 1, message={"content": [{
                "type": "text", "text": f"{label}_{'ALLOWED' if decision == 'allow' else 'DENIED'}"}]})
        ]

    def check(self):
        return VERIFIER.verify_parallel(self.ra, self.sa, self.a, "tool-A",
                                        self.rb, self.sb, self.b, "tool-B")

    def test_overlapping_distinct_turns_pass_with_redacted_report(self):
        report = self.check()
        self.assertTrue(report["passed"])
        for private in (self.sa, self.sb, str(self.a), "tool-A"):
            self.assertNotIn(private, str(report))

    def test_sequential_and_touching_intervals_are_not_parallel(self):
        for request in (3, 5):
            self.rb = self.turn(self.sb, self.b, "B", "deny", "tool-B", request, request + 1)
            with self.subTest(request=request), self.assertRaises(ValueError):
                self.check()

    def test_same_session_directory_or_identity_is_rejected(self):
        for session, fixture, tool in ((self.sa, self.b, "tool-B"),
                                       (self.sb, self.a, "tool-B"),
                                       (self.sb, self.b, "tool-A")):
            with self.subTest(session=session, fixture=fixture, tool=tool), self.assertRaises(ValueError):
                VERIFIER.verify_parallel(self.ra, self.sa, self.a, "tool-A",
                                         self.rb, session, fixture, tool)

    def test_cross_write_wrong_decision_and_result_are_rejected(self):
        original = copy.deepcopy(self.rb)
        for index, field, value in ((2, "toolUseID", "tool-A"), (2, "decision", "allow"),
                                    (3, "tool_use_id", "tool-A"), (3, "is_error", False),
                                    (3, "content", "unrelated error"), (4, "text", "B_ALLOWED")):
            self.rb = copy.deepcopy(original)
            target = self.rb[index]["attachment"] if index == 2 else self.rb[index]["message"]["content"][0]
            target[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check()

    def test_missing_duplicate_reordered_events_and_retries_are_rejected(self):
        original = self.rb
        for rows in (original[:-1], original + [original[2]],
                     original[:2] + original[3:4] + original[2:3] + original[4:],
                     original + [original[1]],
                     original[:2] + [copy.deepcopy(self.ra[1])] + original[2:]):
            self.rb = rows
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                self.check()

    def test_wrong_command_tool_and_session_cannot_pass(self):
        original = copy.deepcopy(self.rb)
        for key, value in (("name", "Read"), ("command", "/bin/bash /tmp/unrelated.sh")):
            self.rb = copy.deepcopy(original)
            tool = self.rb[1]["message"]["content"][0]
            (tool["input"] if key == "command" else tool)[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check()
        self.rb = copy.deepcopy(original)
        self.rb[2]["sessionId"] = self.sa
        with self.assertRaises(ValueError):
            self.check()

    def test_timestamp_missing_naive_or_contradictory_is_rejected(self):
        for timestamp in (None, "bad", "2026-10-08T15:00:01", "2026-10-08T15:00:09Z"):
            original = self.rb[1]["timestamp"]
            if timestamp is None:
                del self.rb[1]["timestamp"]
            else:
                self.rb[1]["timestamp"] = timestamp
            with self.subTest(timestamp=timestamp), self.assertRaises(ValueError):
                self.check()
            self.rb[1]["timestamp"] = original

    def test_execution_effects_and_symlinks_cannot_pass(self):
        (self.a / "tool-executed").rmdir()
        with self.assertRaises(ValueError):
            self.check()
        (self.a / "tool-executed").mkdir()
        (self.b / "tool-executed").symlink_to(self.b / "missing")
        with self.assertRaises(ValueError):
            self.check()
        (self.b / "tool-executed").unlink()
        (self.b / "tool-executed").mkdir()
        with self.assertRaises(ValueError):
            self.check()

    def test_explicit_turn_selection_does_not_claim_other_turns(self):
        old = self.turn(self.sa, self.a, "A", "deny", "old-tool", 0, 1)
        self.ra = old + self.ra
        self.assertIn("other turns", self.check()["excluded"])
        self.ra.append(self.ra[len(old) + 1])  # Duplicate selected ID anywhere is invalid.
        with self.assertRaises(ValueError):
            self.check()

    def test_prompt_boundary_is_required_and_extra_tools_in_turn_rejected(self):
        self.ra = self.ra[1:]
        with self.assertRaises(ValueError):
            self.check()
        self.ra = self.turn(self.sa, self.a, "A", "allow", "tool-A", 0, 3)
        extra = copy.deepcopy(self.ra[1])
        extra["message"]["content"][0]["id"] = "retry"
        self.ra.insert(2, extra)
        with self.assertRaises(ValueError):
            self.check()

    def test_incomplete_parallel_cli_arguments_fail_before_reading_files(self):
        result = subprocess.run([
            sys.executable, "-B", str(Path(__file__).parents[1] / "verify-claude-permission.py"),
            "--transcript", str(self.a / "missing.jsonl"), "--session-id", self.sa,
            "--fixture-dir", str(self.a), "--allow-tool-id", "tool-A"
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("all five", result.stderr)
        self.assertNotIn("No such file", result.stderr)


if __name__ == "__main__":
    unittest.main()
