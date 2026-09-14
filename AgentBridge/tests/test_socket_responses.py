"""Real private-socket regressions for the production question/approval bridge."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch


SPEC = importlib.util.spec_from_file_location(
    "notch_socket_bridge", Path(__file__).parents[1] / "bin/notch-bridge.py"
)
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


class SocketResponseTests(unittest.TestCase):
    def exchange(self, chunks, delay=0, budget=1):
        """Use the real transport/peer check, never the user's app socket."""
        errors = []
        with tempfile.TemporaryDirectory(prefix="notch-wire-", dir="/tmp") as root:
            path = str(Path(root) / "test.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                os.chmod(path, 0o600)
                server.listen(1)
                server.settimeout(2)

                def respond():
                    try:
                        connection, _ = server.accept()
                        with connection:
                            connection.settimeout(2)
                            self.assertEqual(
                                json.loads(connection.recv(4096)),
                                {"event": "PreToolUse"},
                            )
                            for chunk in chunks:
                                if delay:
                                    time.sleep(delay)
                                connection.sendall(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        pass  # Expected when the bridge rejects a response.
                    except Exception as error:
                        errors.append(error)

                worker = threading.Thread(target=respond, daemon=True)
                worker.start()
                try:
                    with patch.object(BRIDGE, "PERMISSION_TIMEOUT", budget):
                        response = BRIDGE.send_event(
                            path, {"event": "PreToolUse"}, expect_reply=True
                        )
                finally:
                    worker.join(timeout=3)
                self.assertFalse(worker.is_alive(), "fixture socket did not close")
                if errors:
                    raise errors[0]
                return response

    def test_long_multiline_answer_is_not_truncated(self):
        response = {
            "decision": "allow",
            "updated_input": {
                "questions": [{"question": "What should change?"}],
                "answers": {"What should change?": "保留原任务与多行答案。\n" * 1200},
            },
        }
        wire = json.dumps(response, ensure_ascii=False).encode()
        self.assertGreater(len(wire), 4096)
        self.assertEqual(self.exchange([wire]), response)

    def test_fragmented_response_preserves_split_utf8(self):
        response = {"decision": "deny", "reason": "请补充计划 📝\n再提交"}
        wire = json.dumps(response, ensure_ascii=False).encode()
        split = wire.index("请".encode()) + 1
        self.assertEqual(
            self.exchange([wire[:split], wire[split:]], delay=0.01), response
        )

    def test_short_approval_still_works(self):
        self.assertEqual(
            self.exchange([b'{"decision":"allow"}']), {"decision": "allow"}
        )

    def test_invalid_responses_return_to_native_permission_flow(self):
        for wire in (b"", b'{"decision":', b"[]", b"null", b'"allow"',
                     b'{"reason":"\xff"}', b'{"decision":"allow"}garbage'):
            with self.subTest(wire=wire):
                self.assertIsNone(self.exchange([wire]))

    def test_response_size_limit_accepts_boundary_and_rejects_overflow(self):
        wire = b'{"decision":"deny","reason":"' + b"x" * 2048 + b'"}'
        with patch.object(BRIDGE, "MAX_RESPONSE_BYTES", len(wire)):
            self.assertEqual(self.exchange([wire]), json.loads(wire))
        with patch.object(BRIDGE, "MAX_RESPONSE_BYTES", len(wire) - 1):
            self.assertIsNone(self.exchange([wire]))

    def test_incomplete_response_times_out_without_a_decision(self):
        self.assertIsNone(self.exchange([b'{"decision":'], delay=0.1, budget=0.02))

    def test_deadline_is_not_extended_when_bytes_keep_arriving(self):
        connection = Mock()
        connection.recv.return_value = b" "
        with patch.object(BRIDGE.time, "monotonic", side_effect=[10, 10.5, 11]):
            self.assertIsNone(BRIDGE.read_socket_response(connection, deadline=11))
        self.assertEqual(connection.recv.call_count, 2)
        self.assertEqual(
            [call.args[0] for call in connection.settimeout.call_args_list],
            [1, 0.5],
        )

    def test_expired_deadline_does_not_read(self):
        connection = Mock()
        with patch.object(BRIDGE.time, "monotonic", return_value=12):
            self.assertIsNone(BRIDGE.read_socket_response(connection, deadline=11))
        connection.recv.assert_not_called()

    def test_decoder_recursion_failure_returns_no_decision(self):
        with patch.object(BRIDGE, "read_socket_response", side_effect=RecursionError):
            self.assertIsNone(self.exchange([b'{"decision":"allow"}']))


if __name__ == "__main__":
    unittest.main()
