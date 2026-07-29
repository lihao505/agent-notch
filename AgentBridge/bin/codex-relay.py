#!/usr/bin/env python3
"""Line-oriented tmux relay used by the installed Agent Notch chat input."""

import argparse
import os
import shutil
import subprocess
import sys
import time


def find_codex():
    override = os.environ.get("NOTCH_CODEX_BIN")
    candidates = [
        override,
        shutil.which("codex"),
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        os.path.expanduser("~/.local/bin/codex"),
    ]
    return next(
        (path for path in candidates if path and os.access(path, os.X_OK)),
        None,
    )


def log_path(session_id):
    directory = os.path.expanduser("~/.multiagent-notch/logs")
    os.makedirs(directory, exist_ok=True)
    return os.path.join(directory, f"codex-relay-{session_id}.log")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--cwd", required=True)
    args = parser.parse_args()

    codex = find_codex()
    cwd = args.cwd if os.path.isdir(args.cwd) else os.path.expanduser("~")

    # Agent Notch sends one TextField submission followed by Enter. Reading one
    # line at a time also serializes turns: text typed while Codex is working
    # waits in the tty instead of starting a concurrent resume.
    for raw in sys.stdin:
        prompt = raw.rstrip("\r\n")
        if not prompt.strip():
            continue

        with open(log_path(args.session_id), "a") as log:
            stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
            if not codex:
                log.write(f"{stamp} Codex CLI not found\n")
                log.flush()
                continue

            log.write(f"{stamp} resume started ({len(prompt)} chars)\n")
            log.flush()
            result = subprocess.run(
                [
                    codex,
                    "exec", "resume",
                    "--all",
                    "--skip-git-repo-check",
                    args.session_id,
                    "-",
                ],
                input=prompt,
                text=True,
                cwd=cwd,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
            )
            log.write(
                f"{time.strftime('%Y-%m-%dT%H:%M:%S')} "
                f"resume exited {result.returncode}\n"
            )
            log.flush()


if __name__ == "__main__":
    main()
