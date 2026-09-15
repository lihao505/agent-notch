"""Safety/acceptance checks without an SDK, model call, or running GUI."""
import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "live_question_verifier",
    Path(__file__).parents[1] / "verify-claude-question.py",
)
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class LiveQuestionVerifierTests(unittest.TestCase):
    def event(self, name="PreToolUse"):
        return {
            "event": name, "session_id": "fixture-only", "cwd": "/tmp/notch-fixture",
            "status": VERIFIER.EVENT_STATUSES[VERIFIER.EVENT_SEQUENCE.index(name)],
            "source": "claude", "tool": "AskUserQuestion", "tool_use_id": "question-1",
            "tool_input": {"questions": [{"question": VERIFIER.QUESTION}]},
        }

    def validate(self, event):
        VERIFIER.validate_fixture_event(event, "fixture-only", "/tmp/notch-fixture")

    def test_only_own_session_directory_and_source_are_accepted(self):
        self.validate(self.event())
        for field, value in (
            ("session_id", "user-existing-session"), ("cwd", "/tmp/another-project"),
            ("cwd", None), ("cwd", "relative"), ("source", "codex"),
        ):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                self.validate({**self.event(), field: value})

    def test_filesystem_alias_of_own_directory_is_accepted(self):
        with tempfile.TemporaryDirectory(prefix="notch-verifier-", dir="/tmp") as root:
            original = Path(root) / "project"
            original.mkdir()
            alias = Path(root) / "alias"
            alias.symlink_to(original, target_is_directory=True)
            VERIFIER.validate_fixture_event(
                {**self.event(), "cwd": str(alias)}, "fixture-only", str(original)
            )

    def test_unexpected_tools_questions_and_cleanup_events_are_rejected(self):
        for change in (
            {"tool": "Bash"}, {"tool_use_id": ""}, {"tool_use_id": None},
            {"event": "SessionEnd"}, {"event": "PermissionRequest"},
            {"status": "ended"},
            {"tool_input": None}, {"tool_input": {"questions": []}},
            {"tool_input": {"questions": [None]}},
            {"tool_input": {"questions": [{"question": "unrelated question"}]}},
        ):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.validate({**self.event(), **change})

    def test_non_object_payloads_are_rejected(self):
        for event in (None, [], "anything", 3):
            with self.subTest(event=event), self.assertRaises(ValueError):
                self.validate(event)

    def test_only_complete_ordered_same_request_sequence_passes(self):
        events = [self.event(name) for name in VERIFIER.EVENT_SEQUENCE]
        self.assertTrue(VERIFIER.verified_event_sequence(events, "fixture-only"))
        invalid = [
            [], events[:-1], events + [events[-1]], list(reversed(events)),
            [events[0], events[1], {**events[2], "tool_use_id": "question-2"}, events[3]],
            [{**event, "session_id": "other-session"} for event in events],
            [events[0], {**events[1], "tool_use_id": None}, events[2], events[3]],
            [events[0], events[1], {**events[2], "tool": "Bash"}, events[3]],
            [events[0], {**events[1], "status": "processing"}, events[2], events[3]],
        ]
        for sequence in invalid:
            with self.subTest(sequence=sequence):
                self.assertFalse(VERIFIER.verified_event_sequence(sequence, "fixture-only"))


if __name__ == "__main__":
    unittest.main()
