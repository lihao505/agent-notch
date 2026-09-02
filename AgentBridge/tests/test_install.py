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
    def test_custom_claude_config_dir_is_used_and_persisted(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            claude = home / "Claude Config With Spaces"
            (claude / "hooks").mkdir(parents=True)
            (claude / "hooks/agent-notch-state.py").write_text("# native\n")
            (claude / "settings.json").write_text("{}\n")

            completed = subprocess.run(
                ["bash", str(INSTALL)],
                check=False,
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "HOME": str(home),
                    "CLAUDE_CONFIG_DIR": str(claude),
                },
            )
            self.assertEqual(completed.returncode, 0, msg=completed.stderr)
            self.assertFalse((home / ".claude/settings.json").exists())
            config = json.loads((claude / "settings.json").read_text())
            self.assertTrue(commands(config, "SessionStart"))

            bridge_config = json.loads(
                (home / ".multiagent-notch/config.json").read_text()
            )
            self.assertEqual(
                bridge_config["claude_config_dir"],
                str(claude),
            )

    def test_claude_vibe_decision_is_migrated_but_observers_are_retained(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            claude = home / ".claude"
            (claude / "hooks").mkdir(parents=True)
            (claude / "hooks/claude-island-state.py").write_text("# native\n")
            native = "python3 ~/.claude/hooks/claude-island-state.py"
            unrelated = "/opt/other/vibe-island-bridge-wrapper --observe"
            status_line = str(home / ".vibe-island/bin/vibe-island-statusline")
            (claude / "settings.json").write_text(json.dumps({
                "statusLine": {"type": "command", "command": status_line},
                "hooks": {
                    "Stop": [hook(VI_CLAUDE, 86400), hook(unrelated)],
                    "PermissionRequest": [
                        hook(VI_CLAUDE, 86400),
                        hook(native, 86400),
                    ],
                },
            }))

            env = {**os.environ, "HOME": str(home)}
            for _ in range(2):
                completed = subprocess.run(
                    ["bash", str(INSTALL)],
                    check=False,
                    capture_output=True,
                    text=True,
                    env=env,
                )
                self.assertEqual(completed.returncode, 0, msg=completed.stderr)

            config = json.loads((claude / "settings.json").read_text())
            self.assertNotIn(VI_CLAUDE, commands(config, "PermissionRequest"))
            self.assertIn(native, commands(config, "PermissionRequest"))
            self.assertIn(VI_CLAUDE, commands(config, "Stop"))
            self.assertIn(unrelated, commands(config, "Stop"))
            self.assertEqual(config["statusLine"]["command"], status_line)

    def test_codex_known_agentwatch_observer_coexists_idempotently(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            codex = home / ".codex"
            codex.mkdir()
            agentwatch = (
                "/Users/example/Projects/agentwatch/.venv/bin/python "
                "-m agentwatch.cli hook --event PermissionRequest"
            )
            (codex / "hooks.json").write_text(json.dumps({
                "hooks": {"PermissionRequest": [hook(agentwatch, 15)]}
            }))

            env = {**os.environ, "HOME": str(home)}
            for _ in range(2):
                completed = subprocess.run(
                    ["bash", str(INSTALL)],
                    check=False,
                    capture_output=True,
                    text=True,
                    env=env,
                )
                self.assertEqual(
                    completed.returncode,
                    0,
                    msg=f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
                )
                self.assertIn("known observer retained", completed.stdout)

            config = json.loads((codex / "hooks.json").read_text())
            ours = (
                f"/usr/bin/python3 {home}/.multiagent-notch/bin/"
                "notch-bridge.py --source codex"
            )
            self.assertEqual(commands(config, "PermissionRequest").count(agentwatch), 1)
            self.assertEqual(commands(config, "PermissionRequest").count(ours), 1)
            agentwatch_hook = next(
                item
                for entry in config["hooks"]["PermissionRequest"]
                for item in entry["hooks"]
                if item.get("command") == agentwatch
            )
            self.assertIs(agentwatch_hook.get("async"), True)
            ours_hook = next(
                item
                for entry in config["hooks"]["PermissionRequest"]
                for item in entry["hooks"]
                if item.get("command") == ours
            )
            self.assertEqual(ours_hook.get("timeout"), 105)

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
                        "--replace-vibe-island",
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
            for event in {
                "SessionStart", "UserPromptSubmit", "PreToolUse",
                "PostToolUse", "PreCompact", "PostCompact", "Stop",
                "SessionEnd", "SubagentStart", "SubagentStop",
            }:
                self.assertEqual(commands(codex_cfg, event).count(ours), 1)

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
                "PostToolUse", "PreCompact", "PostCompact", "Stop",
                "SessionEnd", "SubagentStart", "SubagentStop",
            }
            for event in expected_events:
                self.assertEqual(commands(config, event).count(ours), 1)
            self.assertIn(unrelated, commands(config, "Stop"))
            self.assertIn(unrelated, commands(config, "PreToolUse"))
            self.assertNotIn("PermissionRequest", config.get("hooks", {}))

    def test_codex_exact_vibe_permission_is_migrated_by_default(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            codex = home / ".codex"
            codex.mkdir()
            (codex / "hooks.json").write_text(json.dumps({
                "hooks": {
                    "PermissionRequest": [hook(VI_CODEX)],
                    "Stop": [hook(VI_CODEX)],
                    "PreToolUse": [hook(VI_CODEX)],
                }
            }))

            completed = subprocess.run(
                ["bash", str(INSTALL)],
                check=False,
                capture_output=True,
                text=True,
                env={**os.environ, "HOME": str(home)},
            )
            self.assertEqual(completed.returncode, 0, msg=completed.stderr)
            config = json.loads((codex / "hooks.json").read_text())
            ours = (
                f"/usr/bin/python3 {home}/.multiagent-notch/bin/"
                "notch-bridge.py --source codex"
            )
            self.assertNotIn(VI_CODEX, commands(config, "PermissionRequest"))
            self.assertEqual(commands(config, "PermissionRequest").count(ours), 1)
            self.assertNotIn(VI_CODEX, commands(config, "Stop"))
            self.assertIn(VI_CODEX, commands(config, "PreToolUse"))
            self.assertIn("AGENT_NOTCH_INSTALL_STATUS=complete", completed.stdout)

    def test_codex_unknown_or_non_command_permission_hook_blocks_takeover(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            codex = home / ".codex"
            codex.mkdir()
            ours = (
                f"/usr/bin/python3 {home}/.multiagent-notch/bin/"
                "notch-bridge.py --source codex"
            )
            foreign = "/opt/foreign/approval-owner"
            prompt_hook = {"type": "prompt", "prompt": "decide"}
            (codex / "hooks.json").write_text(json.dumps({
                "hooks": {
                    "PermissionRequest": [
                        hook(ours, 105),
                        hook(VI_CODEX, 105),
                        hook(foreign, 105),
                        {"hooks": [prompt_hook]},
                        {"matcher": "*"},
                    ]
                }
            }))

            completed = subprocess.run(
                ["bash", str(INSTALL)],
                check=False,
                capture_output=True,
                text=True,
                env={**os.environ, "HOME": str(home)},
            )
            self.assertEqual(completed.returncode, 0, msg=completed.stderr)
            config = json.loads((codex / "hooks.json").read_text())
            permission = config["hooks"]["PermissionRequest"]
            self.assertNotIn(ours, commands(config, "PermissionRequest"))
            self.assertNotIn(VI_CODEX, commands(config, "PermissionRequest"))
            self.assertIn(foreign, commands(config, "PermissionRequest"))
            self.assertTrue(any(entry.get("hooks") == [prompt_hook] for entry in permission))
            self.assertTrue(any("hooks" not in entry for entry in permission))
            self.assertIn("PermissionRequest → SKIPPED", completed.stdout)
            self.assertIn("AGENT_NOTCH_INSTALL_STATUS=partial", completed.stdout)

    def test_claude_custom_directory_refuses_unknown_sync_owner(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            custom = home / "custom claude"
            hooks_dir = custom / "hooks"
            hooks_dir.mkdir(parents=True)
            native_script = hooks_dir / "agent-notch-state.py"
            native_script.write_text("# native\n")
            native = f"python3 '{native_script}'"
            foreign = "/opt/foreign/claude-approval"
            settings = custom / "settings.json"
            settings.write_text(json.dumps({
                "hooks": {
                    "PermissionRequest": [
                        hook(native, 105),
                        hook(VI_CLAUDE, 105),
                        hook(foreign, 105),
                    ]
                }
            }))

            completed = subprocess.run(
                ["bash", str(INSTALL)],
                check=False,
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "HOME": str(home),
                    "AGENT_NOTCH_CLAUDE_DIR": str(custom),
                },
            )
            self.assertEqual(completed.returncode, 0, msg=completed.stderr)
            config = json.loads(settings.read_text())
            self.assertNotIn(native, commands(config, "PermissionRequest"))
            self.assertNotIn(VI_CLAUDE, commands(config, "PermissionRequest"))
            self.assertIn(foreign, commands(config, "PermissionRequest"))
            self.assertFalse((home / ".claude/settings.json").exists())
            bridge_config = json.loads(
                (home / ".multiagent-notch/config.json").read_text()
            )
            self.assertEqual(bridge_config["claude_config_dir"], str(custom))
            self.assertIn("AGENT_NOTCH_INSTALL_STATUS=partial", completed.stdout)

    def test_malformed_json_is_preserved_and_install_fails(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            codex = home / ".codex"
            codex.mkdir()
            settings = codex / "hooks.json"
            original = '{"hooks": '
            settings.write_text(original)

            completed = subprocess.run(
                ["bash", str(INSTALL)],
                check=False,
                capture_output=True,
                text=True,
                env={**os.environ, "HOME": str(home)},
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(settings.read_text(), original)

    def test_codex_malformed_hook_shapes_are_preserved_and_reported(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            codex = home / ".codex"
            codex.mkdir()
            settings = codex / "hooks.json"
            original = {
                "hooks": {
                    "Stop": [
                        "opaque-entry",
                        {"hooks": [{"type": "command", "command": 42}]},
                    ],
                    "PermissionRequest": [
                        {"hooks": [{"type": "command", "command": 42}]},
                    ],
                }
            }
            settings.write_text(json.dumps(original))

            completed = subprocess.run(
                ["bash", str(INSTALL), "--replace-vibe-island"],
                check=False,
                capture_output=True,
                text=True,
                env={**os.environ, "HOME": str(home)},
            )

            self.assertEqual(completed.returncode, 0, msg=completed.stderr)
            config = json.loads(settings.read_text())
            self.assertIn("opaque-entry", config["hooks"]["Stop"])
            self.assertTrue(any(
                hook_item.get("command") == 42
                for entry in config["hooks"]["PermissionRequest"]
                if isinstance(entry, dict)
                for hook_item in entry.get("hooks", [])
                if isinstance(hook_item, dict)
            ))
            self.assertIn("PermissionRequest → SKIPPED", completed.stdout)
            self.assertIn("AGENT_NOTCH_INSTALL_STATUS=partial", completed.stdout)

    def test_non_object_hooks_root_is_preserved_and_reported(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            codex = home / ".codex"
            codex.mkdir()
            settings = codex / "hooks.json"
            original = {"hooks": ["future-schema"]}
            settings.write_text(json.dumps(original))

            completed = subprocess.run(
                ["bash", str(INSTALL)],
                check=False,
                capture_output=True,
                text=True,
                env={**os.environ, "HOME": str(home)},
            )

            self.assertEqual(completed.returncode, 0, msg=completed.stderr)
            self.assertEqual(json.loads(settings.read_text()), original)
            self.assertIn("hooks must be an object", completed.stdout)
            self.assertIn("AGENT_NOTCH_INSTALL_STATUS=partial", completed.stdout)

    def test_conflict_remediation_output_is_data_not_shell_code(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            codex = home / ".codex"
            codex.mkdir()
            side_effect = home / "must-not-exist"
            foreign = f'/opt/owner "$(touch {side_effect})"'
            (codex / "hooks.json").write_text(json.dumps({
                "hooks": {"PermissionRequest": [hook(foreign, 105)]}
            }))

            completed = subprocess.run(
                ["bash", str(INSTALL)],
                check=False,
                capture_output=True,
                text=True,
                env={**os.environ, "HOME": str(home)},
            )

            self.assertEqual(completed.returncode, 0, msg=completed.stderr)
            self.assertFalse(side_effect.exists())
            self.assertIn("argument JSON:", completed.stdout)
            self.assertNotIn(
                "./install.sh --migrate-permission",
                completed.stdout,
            )

    def test_claude_non_list_event_is_preserved_and_reported(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            claude = home / ".claude"
            (claude / "hooks").mkdir(parents=True)
            (claude / "hooks/agent-notch-state.py").write_text("# native\n")
            settings = claude / "settings.json"
            original_pretool = {"future": "schema"}
            settings.write_text(json.dumps({
                "hooks": {"PreToolUse": original_pretool}
            }))

            completed = subprocess.run(
                ["bash", str(INSTALL)],
                check=False,
                capture_output=True,
                text=True,
                env={**os.environ, "HOME": str(home)},
            )

            self.assertEqual(completed.returncode, 0, msg=completed.stderr)
            config = json.loads(settings.read_text())
            self.assertEqual(config["hooks"]["PreToolUse"], original_pretool)
            self.assertIn("PreToolUse must be a list", completed.stdout)
            self.assertIn("AGENT_NOTCH_INSTALL_STATUS=partial", completed.stdout)

    def test_codebuddy_non_list_event_is_preserved_and_reported(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            codebuddy = home / ".codebuddy"
            codebuddy.mkdir()
            settings = codebuddy / "settings.json"
            original_stop = {"future": "schema"}
            settings.write_text(json.dumps({
                "hooks": {"Stop": original_stop}
            }))

            completed = subprocess.run(
                ["bash", str(INSTALL)],
                check=False,
                capture_output=True,
                text=True,
                env={**os.environ, "HOME": str(home)},
            )

            self.assertEqual(completed.returncode, 0, msg=completed.stderr)
            config = json.loads(settings.read_text())
            self.assertEqual(config["hooks"]["Stop"], original_stop)
            self.assertIn("skipped events", completed.stdout)
            self.assertIn("AGENT_NOTCH_INSTALL_STATUS=partial", completed.stdout)

    def test_finder_path_new_file_mode_and_settings_symlink(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            local_bin = home / ".local/bin"
            local_bin.mkdir(parents=True)
            for executable in ("codex", "codebuddy"):
                path = local_bin / executable
                path.write_text("#!/bin/sh\nexit 0\n")
                path.chmod(0o755)

            codebuddy = home / ".codebuddy"
            codebuddy.mkdir()
            target = home / "managed-codebuddy.json"
            target.write_text("{}")
            settings_link = codebuddy / "settings.json"
            settings_link.symlink_to(target)

            completed = subprocess.run(
                ["bash", str(INSTALL)],
                check=False,
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "HOME": str(home),
                    "PATH": "/usr/bin:/bin",
                },
            )
            self.assertEqual(completed.returncode, 0, msg=completed.stderr)
            codex_settings = home / ".codex/hooks.json"
            self.assertTrue(codex_settings.exists())
            self.assertEqual(codex_settings.stat().st_mode & 0o777, 0o600)
            self.assertTrue(settings_link.is_symlink())
            config = json.loads(target.read_text())
            self.assertIn("Stop", config["hooks"])
            self.assertEqual(
                (home / ".multiagent-notch").stat().st_mode & 0o777,
                0o700,
            )

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

    def test_uninstall_preserves_unknown_hook_shapes_and_removes_owned_hooks(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            home = Path(temporary_home)
            state = home / ".multiagent-notch"
            (state / "bin").mkdir(parents=True)
            claude = home / ".claude"
            codebuddy = home / ".codebuddy"
            codex = home / ".codex"
            claude.mkdir()
            codebuddy.mkdir()
            codex.mkdir()

            bridge = state / "bin/notch-bridge.py"
            codex_owned = f"/usr/bin/python3 {bridge} --source codex"
            buddy_owned = f"/usr/bin/python3 {bridge} --source codebuddy"
            claude_owned = (
                f"/usr/bin/python3 {bridge} --source claude --lifecycle-only"
            )
            foreign = "/opt/foreign/observer"

            def malformed(owned):
                return {
                    "hooks": {
                        "Stop": [
                            "opaque-entry",
                            {
                                "future": "shape",
                                "hooks": [
                                    42,
                                    {"type": "command", "command": foreign},
                                    {"type": "command", "command": owned},
                                ],
                            },
                        ],
                        "FutureEvent": {"opaque": True},
                    }
                }

            files = {
                codex / "hooks.json": malformed(codex_owned),
                codebuddy / "settings.json": malformed(buddy_owned),
                claude / "settings.json": malformed(claude_owned),
            }
            for path, value in files.items():
                path.write_text(json.dumps(value))

            completed = subprocess.run(
                ["bash", str(UNINSTALL)],
                check=False,
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "HOME": str(home),
                    "CLAUDE_CONFIG_DIR": str(claude),
                    "PATH": "/usr/bin:/bin",
                    "TMUX_TMPDIR": str(home),
                },
            )

            self.assertEqual(completed.returncode, 0, msg=completed.stderr)
            for path, original in files.items():
                updated = json.loads(path.read_text())
                self.assertEqual(
                    updated["hooks"]["FutureEvent"],
                    original["hooks"]["FutureEvent"],
                )
                stop = updated["hooks"]["Stop"]
                self.assertIn("opaque-entry", stop)
                nested = next(item["hooks"] for item in stop if isinstance(item, dict))
                self.assertIn(42, nested)
                self.assertTrue(any(
                    isinstance(item, dict) and item.get("command") == foreign
                    for item in nested
                ))
                self.assertFalse(any(
                    isinstance(item, dict)
                    and item.get("command", "").startswith(
                        f"/usr/bin/python3 {bridge}"
                    )
                    for item in nested
                ))


if __name__ == "__main__":
    unittest.main()
