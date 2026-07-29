import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid


RELAY = Path(__file__).parents[1] / "bin" / "codex-relay.py"


class CodexRelayTests(unittest.TestCase):
    def test_prompt_is_forwarded_on_stdin_to_same_thread(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            capture = root / "capture.json"
            fake_codex = root / "codex"
            fake_codex.write_text(
                "#!/usr/bin/python3\n"
                "import json, os, sys\n"
                "with open(os.environ['NOTCH_CAPTURE'], 'w') as f:\n"
                "    json.dump({'argv': sys.argv[1:], 'stdin': sys.stdin.read()}, f)\n"
            )
            fake_codex.chmod(0o755)

            subprocess.run(
                [
                    "/usr/bin/python3", str(RELAY),
                    "--session-id", "thread-123",
                    "--cwd", temporary,
                ],
                input="直接从刘海回复\n",
                text=True,
                check=True,
                env={
                    **os.environ,
                    "HOME": temporary,
                    "NOTCH_CODEX_BIN": str(fake_codex),
                    "NOTCH_CAPTURE": str(capture),
                },
            )

            call = json.loads(capture.read_text())
            self.assertEqual(call["stdin"], "直接从刘海回复")
            self.assertEqual(call["argv"], [
                "exec", "resume",
                "--all",
                "--skip-git-repo-check",
                "thread-123",
                "-",
            ])

    def test_tmux_send_keys_reaches_codex_stdin(self):
        tmux = shutil.which("tmux")
        if not tmux:
            self.skipTest("tmux is not installed")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tmux_tmp = root / "tmux"
            tmux_tmp.mkdir(mode=0o700)
            capture = root / "capture.json"
            fake_codex = root / "codex"
            fake_codex.write_text(
                "#!/usr/bin/python3\n"
                "import json, os, sys\n"
                "with open(os.environ['NOTCH_CAPTURE'], 'w') as f:\n"
                "    json.dump({'argv': sys.argv[1:], 'stdin': sys.stdin.read()}, f)\n"
            )
            fake_codex.chmod(0o755)

            session = "relay-test-" + uuid.uuid4().hex
            env = {**os.environ, "TMUX_TMPDIR": str(tmux_tmp)}
            command = " ".join(shlex.quote(part) for part in [
                "/usr/bin/env",
                f"HOME={temporary}",
                f"NOTCH_CODEX_BIN={fake_codex}",
                f"NOTCH_CAPTURE={capture}",
                "/usr/bin/python3",
                str(RELAY),
                "--session-id", "thread-456",
                "--cwd", temporary,
            ])
            try:
                subprocess.run(
                    [tmux, "new-session", "-d", "-s", session, command],
                    check=True,
                    env=env,
                )
                subprocess.run(
                    [tmux, "send-keys", "-t", session, "-l", "刘海端到端回复"],
                    check=True,
                    env=env,
                )
                subprocess.run(
                    [tmux, "send-keys", "-t", session, "Enter"],
                    check=True,
                    env=env,
                )

                deadline = time.time() + 3
                while time.time() < deadline and not capture.exists():
                    time.sleep(0.05)
                self.assertTrue(capture.exists())
                call = json.loads(capture.read_text())
                self.assertEqual(call["stdin"], "刘海端到端回复")
                self.assertEqual(call["argv"][-2:], ["thread-456", "-"])
            finally:
                subprocess.run(
                    [tmux, "kill-server"],
                    check=False,
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )


if __name__ == "__main__":
    unittest.main()
