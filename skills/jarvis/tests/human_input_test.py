"""Surface: human-input pointer, keyboard, capture and operation-specific dependencies."""
import stat
import unittest
from desktop_world import World


class HumanInput(World):
    def setUp(self):
        super().setUp()
        self.env["WAYLAND_DISPLAY"] = "test-wayland"

    def test_input_commands(self):
        self.executable("ydotool")
        self.executable("wtype", "import os,sys,json\nwith open(os.environ['TOOL_LOG'],'a') as f: f.write(json.dumps([sys.argv[1:],sys.stdin.read()])+'\\n')\n")
        for args, expected, typed in [
            (("move", "15", "25"), ["mousemove", "--absolute", "-x", "15", "-y", "25"], None),
            (("click", "right"), ["click", "0xC1"], None),
            (("key", "Return"), [["-k", "Return"], ""], b""),
            (("type",), [["-"], "fixture text"], b"fixture text"),
        ]:
            with self.subTest(args=args):
                result = self.run_tool("human-input", *args, input=typed)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(self.calls()[-1], expected)

    def test_capture_exclusive(self):
        self.executable("grim", "import sys\nsys.stdout.buffer.write(b'fixture-image')\n")
        self.assertEqual(self.run_tool("human-input", "shot", "relative.png").returncode, 2)
        output = self.root / "capture.png"
        result = self.run_tool("human-input", "shot", output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_bytes(), b"fixture-image")
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        result = self.run_tool("human-input", "shot", output)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_bytes(), b"fixture-image")

    def test_dependencies_platform_and_failed_capture(self):
        for args in (("move", "1", "2"), ("type",), ("shot", str(self.root / "shot"))):
            with self.subTest(args=args):
                self.assertEqual(self.run_tool("human-input", *args, input=b"").returncode, 2)
        self.executable("grim", "import sys\nsys.exit(1)\n")
        output = self.root / "failed-shot"
        self.assertEqual(self.run_tool("human-input", "shot", output).returncode, 1)
        self.assertFalse(output.exists())
        self.executable("wtype")
        self.env.pop("WAYLAND_DISPLAY")
        self.assertEqual(self.run_tool("human-input", "type", input=b"").returncode, 2)


if __name__ == "__main__":
    unittest.main()
