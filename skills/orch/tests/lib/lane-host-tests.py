"""Exercise the real dispatcher with the reusable external provider stub."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PACKAGE = Path(__file__).resolve().parents[2]


class LaneHostTests(unittest.TestCase):
    def setUp(self):
        scratch = Path.cwd() / "tmp"
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.script = self.root / "scripts/lane-host"
        self.script.parent.mkdir()
        shutil.copy2(PACKAGE / "scripts/lane-host", self.script)
        shutil.copytree(PACKAGE / "scripts/lib", self.script.parent / "lib")
        self.stub = self.root / "provider with space"
        shutil.copy2(PACKAGE / "tests/fixtures/lane-host", self.stub)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("ORCH_", "KENDEX_", "LANE_HOST_"))}
        self.env.update(LANE_HOST_STUB_LOG=str(self.root / "calls"), LANE_HOST_STUB_FILE=str(self.root / "bytes"),
                        LANE_HOST_STUB_LIB=str(self.script.parent / "lib"))

    def run_host(self, *args, **env):
        return subprocess.run([str(self.script), *args], cwd=self.root,
                              env={**self.env, **env}, input=b"seed\x00data\n", capture_output=True)

    def test_explicit_selection_and_settings(self):
        (self.root / "kendex.settings.toml").write_text(f'[env]\nORCH_LANE_HOST = "{self.stub}"\n')
        for env, expected in (({}, str(self.stub)), ({"ORCH_LANE_HOST": "local"}, "local")):
            with self.subTest(env=env):
                result = self.run_host("resolve", **env)
                self.assertEqual((result.returncode, result.stdout.decode().strip()), (0, expected))
        (self.root / "kendex.settings.toml").unlink()
        for env in ({}, {"DAYTONA_API_KEY": "not-a-real-key"}, {"ORCH_LANE_HOST": ""}):
            with self.subTest(env=env):
                result = self.run_host("resolve", **env)
                self.assertEqual((result.returncode, result.stdout), (0, b"local\n"))
                refused = self.run_host("create", **env)
                self.assertEqual(refused.returncode, 2)
                self.assertIn(b"host-local verb=create", refused.stderr)
        self.assertFalse((self.root / "calls").exists())

    def test_provider_protocol_and_failures(self):
        env = {"ORCH_LANE_HOST": str(self.stub)}
        args = ("create", "--item", "TEST-1", "--repo", "owner/repo", "--harness", "claude", "--account", "/account one")
        first = self.run_host(*args, **env)
        second = self.run_host(*args, "--reuse", **env)
        expected = b"ssh-target=lane.example\tpath=/srv/lane\tremote-prefix=exec bash -lc\n"
        self.assertEqual((first.returncode, first.stdout, second.stdout), (0, expected, expected))
        self.assertIn("/account\\ one", (self.root / "calls").read_text())
        self.assertEqual(self.run_host("put", "--item", "TEST-1", "/remote", **env).returncode, 0)
        result = self.run_host("cat", "--item", "TEST-1", "/remote", **env)
        self.assertEqual((result.returncode, result.stdout), (0, b"seed\x00data\n"))
        appended = self.run_host("append", "--item", "TEST-1", "/remote", **env)
        self.assertEqual(appended.returncode, 0, appended.stderr)
        result = self.run_host("cat", "--item", "TEST-1", "/remote", **env)
        self.assertEqual((result.returncode, result.stdout), (0, b"seed\x00data\nseed\x00data\n"))
        for code, notice in ((75, False), (1, True), (3, True)):
            with self.subTest(code=code):
                result = self.run_host(*args, **env, LANE_HOST_STUB_STATUS=str(code))
                self.assertEqual(result.returncode, code)
                self.assertEqual(b"host-create-failed" in result.stderr, notice)
        self.assertEqual(self.run_host("close", "--item", "TEST-1", **env, LANE_HOST_STUB_STATUS="3").returncode, 3)
        closed = self.run_host("close", "--item", "TEST-1", **env)
        self.assertEqual((closed.returncode, closed.stdout), (0, b"kept=/fleet/archive/repo/TEST-1/tmp-stub.tgz\n"))
        self.assertTrue((self.root / "calls").read_text().endswith("delete --item TEST-1\n"))

    def test_missing_provider_and_inert_help(self):
        result = self.run_host("create", ORCH_LANE_HOST="/absent/provider")
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"host-unavailable path=/absent/provider", result.stderr)
        (self.root / ".env.local").write_text("exit 91\n")
        self.assertEqual(self.run_host("--help").returncode, 0)

    def test_controls_dispatch_guards(self):
        original = self.script.read_text()
        shutil.copy2(self.stub, self.root / "local")
        self.env["PATH"] = str(self.root) + os.pathsep + self.env["PATH"]
        cases = [
            ('exit "$status"', 'exit 0', str(self.stub), "75", 75),
            ('if [[ "$host" == local ]]; then', 'if false; then', "local", "0", 2),
            ('if [[ ! -x "$host" || -d "$host" ]]; then', 'if false; then', "/absent/provider", "0", 2),
        ]
        for fragment, replacement, host, status, expected in cases:
            with self.subTest(fragment=fragment):
                self.assertEqual(original.count(fragment), 1)
                self.script.write_text(original.replace(fragment, replacement))
                result = self.run_host("create", ORCH_LANE_HOST=host, LANE_HOST_STUB_STATUS=status)
                self.assertNotEqual(result.returncode, expected)


if __name__ == "__main__":
    unittest.main()
