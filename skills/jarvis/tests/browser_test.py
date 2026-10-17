"""Surface: jarvis-browser configured launch, detected browsers, reports, launchers and refused input."""
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from desktop_world import World, load


class Browser(World):
    def test_profile_and_url(self):
        for configured in (True, False):
            with self.subTest(configured=configured):
                name = "browser with spaces" if configured else "google-chrome"
                browser = self.executable(name)
                if configured:
                    self.env["JARVIS_BROWSER_COMMAND"] = str(browser)
                else:
                    self.env.pop("JARVIS_BROWSER_COMMAND", None)
                profile = self.root / "assistant profile"
                self.env.update(JARVIS_BROWSER_PROFILE=str(profile), JARVIS_BROWSER_PORT="9333")
                url = "https://example.org/task?q=one&other=two"
                result = self.run_tool("jarvis-browser", url)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls()[-1], ["--user-data-dir=" + str(profile),
                    "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=9333", "--no-first-run", url])
                browser.unlink()

    def test_refused_inputs(self):
        self.executable("google-chrome")
        base = dict(self.env, JARVIS_BROWSER_PROFILE=str(self.root / "profile"))
        for setting, value, url in [
            ("JARVIS_BROWSER_PROFILE", "relative", "https://example.org"),
            ("JARVIS_BROWSER_PORT", "0", "https://example.org"),
            ("JARVIS_BROWSER_PORT", "not-a-port", "https://example.org"),
            ("JARVIS_BROWSER_COMMAND", "missing-browser", "https://example.org"),
            ("JARVIS_BROWSER_PROFILE", str(self.root / "profile"), "javascript:alert(1)"),
            ("JARVIS_BROWSER_DOWNLOADS", "relative-downloads", "https://example.org"),
            ("JARVIS_BROWSER_PROFILE", str(self.root / "profile"), None),
        ]:
            with self.subTest(setting=setting, value=value):
                self.env = dict(base, **{setting: value})
                result = self.run_tool("jarvis-browser", *([url] if url else []))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.log.exists())

    def test_downloads_and_class(self):
        self.executable("google-chrome")
        # The first launch's profile parent does not exist yet; Chromium creates a nested profile itself.
        profile, downloads = self.root / "profiles" / "assistant", self.root / "downloads"
        self.env.update(JARVIS_BROWSER_PROFILE=str(profile), JARVIS_BROWSER_DOWNLOADS=str(downloads),
                        JARVIS_BROWSER_CLASS="jarvis-assistant")
        preferences = profile / "Default/Preferences"
        kept = {"profile": {"name": "assistant"}, "download": {"prompt_for_download": True}}
        url = "https://example.org"
        for state in ("first-launch", "closed", "open"):
            with self.subTest(state=state):
                if state != "first-launch":
                    preferences.parent.mkdir(parents=True, exist_ok=True)
                    preferences.write_text(json.dumps(kept))
                if state == "open":
                    (profile / "SingletonLock").symlink_to("host-1234")
                result = self.run_tool("jarvis-browser", url)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls()[-1][-2:], ["--class=jarvis-assistant", url])
                expected = {"download": {"default_directory": str(downloads), "prompt_for_download": False}}
                if state == "closed":
                    expected = dict(kept, download=dict(kept["download"], default_directory=str(downloads)))
                elif state == "open":
                    expected = kept
                self.assertEqual(json.loads(preferences.read_text()) if preferences.exists() else None, expected)
                self.assertEqual(sorted(path.name for path in preferences.parent.iterdir()), ["Preferences"])

    def test_port_and_shim(self):
        for configured, expected in (("9444", b"9444\n"), (None, b"9222\n")):
            with self.subTest(port=configured):
                self.env.pop("JARVIS_BROWSER_PORT", None)
                if configured:
                    self.env["JARVIS_BROWSER_PORT"] = configured
                result = self.run_tool("jarvis-browser", "--port")
                self.assertEqual((result.returncode, result.stdout), (0, expected), result.stderr)
        result = self.run_tool("jarvis-browser", "--shim")
        self.assertEqual(result.returncode, 0, result.stderr)
        shim = Path(result.stdout.decode().rstrip("\n"))
        self.assertTrue(shim.is_absolute())
        launchers = ("xdg-open", "x-www-browser", "www-browser")
        self.assertEqual([name for name in launchers if not os.access(shim / name, os.X_OK)], [])
        self.assertFalse(self.log.exists())
        # The launchers run the script through its own interpreter lookup.
        for name in ("bash", "python3"):
            self.bin.joinpath(name).symlink_to(shutil.which(name) if name == "bash" else sys.executable)
        ack_path = self.root / "ack"
        os.mkfifo(ack_path, 0o600)
        ack = os.open(ack_path, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, ack)
        release_path = self.root / "release"
        os.mkfifo(release_path, 0o600)
        release = os.open(release_path, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, release)

        def acknowledged(byte):
            return bool(select.select([ack], [], [], 10)[0]) and os.read(ack, 1) == byte

        # The browser stays open until the test releases it, so a launcher that waits for it times out.
        self.executable("google-chrome", "import json,os,sys\n"
            "with open(os.environ['TOOL_LOG'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
            "with open(os.environ['HOME']+'/ack','wb',buffering=0) as f: f.write(b'B')\n"
            "with open(os.environ['HOME']+'/release','rb',buffering=0) as f: f.read(1)\n"
            "with open(os.environ['HOME']+'/ack','wb',buffering=0) as f: f.write(b'E')\n")
        profile = str(self.root / "profile")
        for name in launchers:
            with self.subTest(launcher=name):
                url = "https://example.org/device?name=" + name
                # A refused request reaches the caller with the driver's own key and status.
                self.env.pop("JARVIS_BROWSER_PROFILE", None)
                launched = len(self.calls()) if self.log.exists() else 0
                refused = subprocess.run([str(shim / name), url], env=self.env, capture_output=True, timeout=15)
                self.assertEqual(refused.returncode, 2, refused.stderr)
                self.assertEqual(refused.stderr.splitlines()[0], b"jarvis-browser: setting=JARVIS_BROWSER_PROFILE")
                self.assertEqual(len(self.calls()) if self.log.exists() else 0, launched)
                self.env["JARVIS_BROWSER_PROFILE"] = profile
                try:
                    result = subprocess.run([str(shim / name), url], env=self.env, capture_output=True, timeout=10)
                except subprocess.TimeoutExpired:
                    self.fail("the launcher waited for the browser")
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
                self.assertTrue(acknowledged(b"B"), "the launcher did not open the browser")
                self.assertEqual(self.calls()[-1][-1], url)
                self.assertIn("--user-data-dir=" + profile, self.calls()[-1])
                os.write(release, b"R")
                self.assertTrue(acknowledged(b"E"), "the released browser did not finish")

    def test_platform_refusal(self):
        module = load("jarvis-browser")
        browser = str(self.executable("google-chrome"))
        # A tool's platform must not change native stdlib executable lookup.
        for available in (browser, None):
            with self.subTest(browser=available), \
                 patch.object(module, "sys", SimpleNamespace(platform="win32")), \
                 patch.object(sys, "argv", ["jarvis-browser", "https://example.org"]), \
                 patch.dict(os.environ, JARVIS_BROWSER_PROFILE=str(self.root / "profile"), JARVIS_BROWSER_COMMAND=browser), \
                 patch.object(module.shutil, "which", return_value=available) as lookup, \
                 patch.object(module.os, "execv", side_effect=AssertionError("unsupported platform launched browser")):
                with self.assertRaises(SystemExit) as refused:
                    module.main()
                self.assertEqual(refused.exception.code, 2)
                lookup.assert_not_called()


if __name__ == "__main__":
    unittest.main()
