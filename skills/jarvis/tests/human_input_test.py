"""Surface: human-input pointer, keyboard, capture and operation-specific dependencies."""
import stat
import sys
import unittest
from types import SimpleNamespace
from desktop_world import SCRIPTS, World, run_case


class HumanInput(World):
    def setUp(self):
        super().setUp()
        self.env["WAYLAND_DISPLAY"] = "test-wayland"

    @unittest.skipUnless(sys.platform == "linux", "desktop operations require Linux")
    def test_input_commands(self):
        self.executable("ydotool")
        self.executable("hyprctl")
        self.executable("wtype", "import os,sys,json\nwith open(os.environ['TOOL_LOG'],'a') as f: f.write(json.dumps([sys.argv[1:],sys.stdin.read()])+'\\n')\n")
        for args, expected, typed in [
            (("move", "15", "25"), ["mousemove", "--absolute", "-x", "15", "-y", "25"], None),
            (("click", "right"), ["click", "0xC1"], None),
            (("key", "Return"), [["-k", "Return"], ""], b""),
            (("type",), [["-d", "70", "-"], "fixture text"], b"fixture text"),
            (("type", "--delay", "85"), [["-d", "85", "-"], "fixture text"], b"fixture text"),
        ]:
            with self.subTest(args=args):
                result = self.run_tool("human-input", *args, input=typed)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(self.calls()[-1], expected)

    @unittest.skipUnless(sys.platform == "linux", "desktop operations require Linux")
    def test_move_backends(self):
        self.executable("ydotool")
        move = ("move", "10", "20")
        dispatched = ["hyprctl", "dispatch", "hl.dsp.cursor.move({ x = 10, y = 20 })"]
        absolute = ["mousemove", "--absolute", "-x", "10", "-y", "20"]
        # Released hyprctl prints the compositor reply; a legacy dispatcher rejection exits zero.
        for signature, available, args, reply, exit_status, status, expected in (
            ("fixture-hyprland", True, move, b"ok\n", 0, 0, dispatched),
            ("fixture-hyprland", True, move, b"Invalid dispatcher\n", 0, 1, dispatched),
            ("fixture-hyprland", True, move, b"", 0, 1, dispatched),
            ("fixture-hyprland", True, move, b"error: dispatch failed\n", 7, 1, dispatched),
            ("fixture-hyprland", True, move, b"ok\n", 1, 1, dispatched),
            (None, True, move, b"", 0, 0, absolute),
            ("", True, move, b"", 0, 0, absolute),
            ("fixture-hyprland", False, move, b"", 0, 0, absolute),
            ("fixture-hyprland", True, ("click", "right"), b"", 0, 0, ["click", "0xC1"]),
        ):
            with self.subTest(signature=signature, hyprctl=available, args=args, reply=reply, exit_status=exit_status):
                if signature is None:
                    self.env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
                else:
                    self.env["HYPRLAND_INSTANCE_SIGNATURE"] = signature
                hyprctl = self.executable("hyprctl", "import json,os,sys\n"
                    "with open(os.environ['TOOL_LOG'],'a') as f: f.write(json.dumps(['hyprctl',*sys.argv[1:]])+'\\n')\n"
                    f"sys.stdout.buffer.write({reply!r})\nsys.exit({exit_status})\n")
                if not available:
                    hyprctl.unlink()
                self.log.write_text("")
                result = self.run_tool("human-input", *args)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(self.calls(), [expected])

    @unittest.skipUnless(sys.platform == "linux", "desktop operations require Linux")
    def test_move_backend_control(self):
        source = (SCRIPTS / "human-input").read_text()
        for guard, replacement in (
            ('if args.verb == "move" and os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):',
             'if args.verb == "move" and os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and False:'),
            ('(hyprctl and result.stdout.strip() != b"ok")',
             '(hyprctl and result.stdout.strip() != b"ok" and False)'),
        ):
            with self.subTest(guard=guard):
                self.assertEqual(source.count(guard), 1)
                changed = source.replace(guard, replacement, 1)
                self.assertNotEqual(changed, source)
                (self.root / "human-input").write_text(changed)
                env = dict(self.env, JARVIS_TOOL_SCRIPTS=str(self.root))
                result = run_case(__file__, "HumanInput.test_move_backends", env)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn(b"FAIL: test_move_backends", result.stderr)

    @unittest.skipUnless(sys.platform == "linux", "desktop operations require Linux")
    def test_capture_exclusive(self):
        self.executable("grim", "import json,os,sys\n"
            "with open(os.environ['TOOL_LOG'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
            "sys.stdout.buffer.write(b'fixture-image')\n")
        self.assertEqual(self.run_tool("human-input", "shot", "relative.png").returncode, 2)
        for name, options, expected in (
            ("full", (), ["-"]),
            ("rectangle", ("--rectangle", "10,20 300x400"), ["-g", "10,20 300x400", "-"]),
        ):
            with self.subTest(capture=name):
                output = self.root / (name + ".png")
                result = self.run_tool("human-input", "shot", output, *options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls()[-1], expected)
                self.assertEqual(output.read_bytes(), b"fixture-image")
                self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
                result = self.run_tool("human-input", "shot", output, *options)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output.read_bytes(), b"fixture-image")

    @unittest.skipUnless(sys.platform == "linux", "desktop operations require Linux")
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

    def test_platform_refusal(self):
        from unittest.mock import patch
        from desktop_world import load
        module = load("human-input")
        for platform, display, command in (
            ("darwin", "fixture-wayland", "/fixture/wtype"),
            ("darwin", "fixture-wayland", None),
            ("linux", "", "/fixture/wtype"),
            ("linux", "", None),
        ):
            with self.subTest(platform=platform, command=command), patch.object(module, "sys", SimpleNamespace(platform=platform)), \
                 patch.object(sys, "argv", ["human-input", "type"]), \
                 patch.dict(module.os.environ, WAYLAND_DISPLAY=display), \
                 patch.object(module.shutil, "which", return_value=command) as lookup, \
                 patch.object(module.subprocess, "run", return_value=SimpleNamespace(returncode=0)):
                with self.assertRaises(SystemExit) as refusal:
                    module.main()
                self.assertEqual(refusal.exception.code, 2)
                lookup.assert_not_called()

    @unittest.skipUnless(sys.platform == "linux", "desktop operations require Linux")
    def test_typing_deadline(self):
        from unittest.mock import patch
        from desktop_world import load
        module = load("human-input")
        # A caller can supply more stdin than a fixed operation deadline permits at the selected delay.
        with patch.object(sys, "argv", ["human-input", "type", "--delay", "85"]), \
             patch.dict(module.os.environ, WAYLAND_DISPLAY="fixture-wayland"), \
             patch.object(module.shutil, "which", return_value="/fixture/wtype"), \
             patch.object(module.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run:
            module.main()
        self.assertIsNone(run.call_args.kwargs["timeout"])


if __name__ == "__main__":
    unittest.main()
