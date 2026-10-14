"""Scratch and executable fixtures shared by the packaged desktop tool suites."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(os.environ.get("JARVIS_TOOL_SCRIPTS", Path(__file__).resolve().parents[1] / "scripts"))


def load(name):
    path = SCRIPTS / name
    loader = importlib.machinery.SourceFileLoader(name.replace("/", "_"), str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class World(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="jarvis-tools-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls"
        self.env = {"PATH": str(self.bin), "HOME": str(self.root), "PYTHONDONTWRITEBYTECODE": "1",
                    "TOOL_LOG": str(self.log)}

    def executable(self, name, body=None):
        if body is None:
            body = "import json,os,sys\nwith open(os.environ['TOOL_LOG'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
        path = self.bin / name
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o755)
        return path

    def run_tool(self, name, *args, input=None):
        return subprocess.run([sys.executable, "-B", str(SCRIPTS / name), *map(str, args)],
                              cwd=self.root, env=self.env, input=input, capture_output=True, timeout=15)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]
