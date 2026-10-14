"""Surface: jarvis-browser configured launch, detected browsers and refused input."""
import os
import sys
import unittest
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
        ]:
            with self.subTest(setting=setting, value=value):
                self.env = dict(base, **{setting: value})
                result = self.run_tool("jarvis-browser", url)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.log.exists())

    def test_platform_refusal(self):
        module = load("jarvis-browser")
        with patch.object(sys, "platform", "win32"), patch.object(sys, "argv", ["jarvis-browser", "https://example.org"]), \
             patch.dict(os.environ, JARVIS_BROWSER_PROFILE=str(self.root / "profile"), JARVIS_BROWSER_COMMAND=str(self.executable("google-chrome"))), \
             patch.object(module.os, "execv", side_effect=AssertionError("unsupported platform launched browser")):
            with self.assertRaises(SystemExit) as refused:
                module.main()
        self.assertEqual(refused.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
