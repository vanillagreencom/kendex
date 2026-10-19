"""Scratch homes with the real mailbox and orch packages and a registered overseer."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SCRIPTS = REPO / "skills/jarvis/scripts"
BASH = os.environ["JARVIS_TEST_BASH"]
LANE_MAIL = REPO / "skills/mailbox/scripts/lane-mail"


def make_project(path, overseer=True):
    """A git checkout with mailbox and orch installed and, by default, an overseer record."""
    path.mkdir(parents=True)
    clean_git = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    subprocess.run(["git", "init", "-q", str(path)], check=True, capture_output=True, env=clean_git)
    for key, value in (("gc.auto", "0"), ("maintenance.auto", "false")):
        subprocess.run(["git", "-C", str(path), "config", key, value], check=True, env=clean_git)
    for name in ("mailbox", "orch"):
        target = path / ".agents/skills" / name
        target.mkdir(parents=True)
        target.joinpath("scripts").symlink_to(REPO / "skills" / name / "scripts", target_is_directory=True)
    if overseer:
        clean = {k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "ORCH_", "KENDEX_"))}
        state = REPO / "skills/orch/scripts/workflow-state"
        subprocess.run([str(state), "init", "oversee"], cwd=path, env=clean, check=True, capture_output=True)
        subprocess.run([str(state), "set", "oversee", "overseer", json.dumps({"pane": "%1", "server": str(os.getpid())})],
                       cwd=path, env=clean, check=True, capture_output=True)
    return path


class MailWorld(unittest.TestCase):
    """One scratch root, a PATH of shims, and a `kendex project list` registry."""

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.registry = self.root / "registry"
        self.registry.write_text("")
        self.env = {key: value for key, value in os.environ.items()
                    if key not in ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "XDG_STATE_HOME")
                    and not key.startswith(("JARVIS_", "ORCH_", "KENDEX_", "SLACK_"))}
        self.env.update(PATH=str(self.bin) + os.pathsep + os.environ["PATH"], HOME=str(self.root),
                        REGISTRY=str(self.registry), PYTHONDONTWRITEBYTECODE="1")
        self.executable("kendex", '#!/bin/sh\ncat "$REGISTRY"\n')

    def executable(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)
        return path

    def command(self, args, root, env=None):
        return subprocess.run(list(map(str, args)), cwd=root, env=env or self.env,
                              capture_output=True, text=True, timeout=60)

    def mail(self, root, verb, text, *options):
        """Run the real lane-mail VERB in root with text in a file; return its id."""
        payload = self.root / "message"
        payload.write_text(text)
        result = self.command([LANE_MAIL, verb, "--item", "overseer", "--file", payload, *options], root)
        self.assertEqual(result.returncode, 0, result.stderr)
        return (result.stdout.split("id=", 1)[1].split()[0]) if "id=" in result.stdout else None

    def box(self, root, name):
        path = root / "tmp/lane-mail/overseer" / (name + ".jsonl")
        return [json.loads(row) for row in path.read_text().splitlines()] if path.exists() else []
