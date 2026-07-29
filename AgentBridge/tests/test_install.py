import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).parents[1]
INSTALL = REPO / "install.sh"
UNINSTALL = REPO / "uninstall.sh"
VI_CLAUDE = (
    "/bin/sh -c '[ -x \"$HOME/.vibe-island/bin/vibe-island-bridge\" ] && "
    "\"$HOME/.vibe-island/bin/vibe-island-bridge\" --source claude; exit 0'"
)
VI_CODEX = (
    "/bin/sh -c '[ -x \"$HOME/.vibe-island/bin/vibe-island-bridge\" ] && "
    "\"$HOME/.vibe-island/bin/vibe-island-bridge\" --source codex; exit 0'"
)
VI_CODEX_ABS_TEMPLATE = "'{home}/.vibe-island/bin/vibe-island-bridge' --source codex"


def hook(command, timeout=5):
    return {"hooks": [{"type": "command", "command": command, "timeout": timeout}]}


def commands(config, event=None):
    hooks = config.get("hooks", {})
    events = [event] if event else hooks
    return [
        item.get("command", "")
        for name in events
        for entry in hooks.get(name, [])
        for item in entry.get("hooks", [])
    ]


class InstallerTests(unittest.TestCase):
    def test_replace_is_exact_and_lifecycle_registration_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            claude = home / ".claude"
            (claude / "hooks").mkdir(parents=True)
            (claude / "hooks/claude-island-state.py").write_text("# native\n")
            unrelated = "/opt/other/vibe-island-bridge-wrapper --observe"
            (claude / "settings.json").write_text(json.dumps({
                "statusLine": {
                    "type": "command",
                    "command": str(home / ".vibe-island/bin/vibe-island-statusline"),
                },
                "hooks": {
                    "Stop": [hook(VI_CLAUDE, 86400), hook(unrelated)],
                    "PermissionRequest": [
                        hook(VI_CLAUDE, 86400),
                        hook("python3 ~/.claude/hooks/claude-island-state.py", 86400),
                    ],
                },
            }))

            codex = home / ".codex"
            codex.mkdir()
            vi_codex_abs = VI_CODEX_ABS_TEMPLATE.format(home=home)
            (codex / "hooks.json").write_text(json.dumps({
                "hooks": {
                    "Stop": [hook(VI_CODEX), hook(vi_codex_abs), hook(unrelated)],
                    "PermissionRequest": [hook(VI_CODEX), hook(vi_codex_abs)],
                }
            }))

            env = {**os.environ, "HOME": str(home)}
            for _ in range(2):
                subprocess.run(
                    [
                        "bash", str(INSTALL),
                        "--take-permission", "--replace-vibe-island",
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                    env=env,
                )

            claude_cfg = json.loads((claude / "settings.json").read_text())
            self.assertNotIn("statusLine", claude_cfg)
            self.assertNotIn(VI_CLAUDE, commands(claude_cfg))
            self.assertIn(unrelated, commands(claude_cfg))
            lifecycle = (
                f"/usr/bin/python3 {home}/.multiagent-notch/bin/"
                "notch-bridge.py --source claude --lifecycle-only"
            )
            interactive = (
                f"/usr/bin/python3 {home}/.multiagent-notch/bin/"
                "notch-bridge.py --source claude"
            )
            for event in (
                "SessionStart", "UserPromptSubmit", "PreToolUse",
                "PostToolUse", "Stop",
            ):
                self.assertEqual(commands(claude_cfg, event).count(lifecycle), 1)
            self.assertEqual(
                commands(claude_cfg, "PreToolUse").count(interactive),
                1,
            )
            self.assertIn(
                "python3 ~/.claude/hooks/claude-island-state.py",
                commands(claude_cfg, "PermissionRequest"),
            )

            codex_cfg = json.loads((codex / "hooks.json").read_text())
            self.assertNotIn(VI_CODEX, commands(codex_cfg))
            self.assertNotIn(vi_codex_abs, commands(codex_cfg))
            self.assertIn(unrelated, commands(codex_cfg, "Stop"))
            ours = (
                f"/usr/bin/python3 {home}/.multiagent-notch/bin/"
                "notch-bridge.py --source codex"
            )
            self.assertEqual(commands(codex_cfg, "Stop").count(ours), 1)

    def test_codebuddy_observers_are_idempotent_and_non_deciding(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            codebuddy = home / ".codebuddy"
            codebuddy.mkdir()
            unrelated = "/opt/other/codebuddy-observer --watch"
            (codebuddy / "settings.json").write_text(json.dumps({
                "hooks": {
                    "Stop": [hook(unrelated)],
                    "PreToolUse": [hook(unrelated, 9)],
                }
            }))

            fake_bin = home / "bin"
            fake_bin.mkdir()
            fake_codebuddy = fake_bin / "codebuddy"
            fake_codebuddy.write_text("#!/bin/sh\nexit 0\n")
            fake_codebuddy.chmod(0o755)
            env = {
                **os.environ,
                "HOME": str(home),
                "PATH": f"{fake_bin}:{os.environ.get('PATH', '')}",
            }

            for _ in range(2):
                subprocess.run(
                    ["bash", str(INSTALL)],
                    check=True,
                    capture_output=True,
                    text=True,
                    env=env,
                )

            config = json.loads((codebuddy / "settings.json").read_text())
            ours = (
                f"/usr/bin/python3 {home}/.multiagent-notch/bin/"
                "notch-bridge.py --source codebuddy"
            )
            expected_events = {
                "SessionStart", "UserPromptSubmit", "PreToolUse",
                "PostToolUse", "PreCompact", "Stop", "SessionEnd",
            }
            for event in expected_events:
                self.assertEqual(commands(config, event).count(ours), 1)
            self.assertIn(unrelated, commands(config, "Stop"))
            self.assertIn(unrelated, commands(config, "PreToolUse"))
            self.assertNotIn("PermissionRequest", config.get("hooks", {}))

    def test_uninstall_refuses_index_paths_outside_claude_projects(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            projects = home / ".claude/projects/demo"
            projects.mkdir(parents=True)
            owned = projects / "session.jsonl"
            owned.write_text("owned\n")
            outside = home / "keep-me.txt"
            outside.write_text("important\n")

            state = home / ".multiagent-notch"
            state.mkdir()
            (state / "synthetic-files.txt").write_text(
                f"{owned}\n{outside}\n"
            )

            subprocess.run(
                ["bash", str(UNINSTALL)],
                check=True,
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "HOME": str(home),
                    "TMUX_TMPDIR": str(home),
                },
            )
            self.assertFalse(owned.exists())
            self.assertTrue(outside.exists())


if __name__ == "__main__":
    unittest.main()
