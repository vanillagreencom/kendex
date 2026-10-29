#!/usr/bin/env bash
# Real consumer files prove delivery and preservation. unittest owns assertions.
set -euo pipefail
TEST_DIR="$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
TEST_DIR="$(cd -- "$TEST_DIR" && pwd -P)" || exit 1
python3 - "$TEST_DIR/.." <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

skill = Path(sys.argv[1]).resolve()
template = (skill / "templates/mac-run.yml").read_bytes()


class InstallTest(unittest.TestCase):
    installer = skill / "scripts/install.sh"

    def test_install(self):
        with tempfile.TemporaryDirectory(prefix="xcode-run-consumer-") as directory:
            consumer = Path(directory).resolve()
            environment = {"PATH": os.defpath, "HOME": str(consumer), "LC_ALL": "C"}
            workflow = consumer / ".github/workflows/mac-run.yml"
            for row, expected in (
                ("fresh", template),
                ("configured", template.replace(b"XCODE_SCHEME: App", b"XCODE_SCHEME: Consumer")
                 .replace(b"name=iPhone 16", b"name=iPad Pro (M4)")
                 .replace(b"-scheme", b"-workspace Consumer.xcworkspace -scheme")
                 .replace(b"shell: bash", b"shell: bash\n        working-directory: apple")),
            ):
                if workflow.exists():
                    workflow.write_bytes(expected)
                result = subprocess.run(
                    [str(self.installer)], cwd=consumer, env=environment,
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 0, f"{row}: installer failed: {result.stderr}")
                self.assertTrue(workflow.is_file())
                self.assertEqual(workflow.read_bytes(), expected, f"{row}: workflow bytes differ")


    def test_install_controls(self):
        # Each isolated mutant keeps the matched text and disables only its behavior.
        source = self.installer.read_text()
        copy = 'cat -- "$SCRIPT_DIR/../templates/mac-run.yml" > "$workflow"'
        for rule, old, new, failure_assertion in (
            ("copy", copy, ": " + copy, "fresh: workflow bytes differ"),
            ("preservation", "  exit 0", "  : exit 0", "configured: installer failed"),
        ):
            with self.subTest(rule=rule), tempfile.TemporaryDirectory(prefix="xcode-run-control-") as directory:
                mutant_skill = Path(directory).resolve()
                (mutant_skill / "scripts").mkdir()
                (mutant_skill / "templates").mkdir()
                (mutant_skill / "templates/mac-run.yml").write_bytes(template)
                self.assertEqual(source.count(old), 1)
                mutated = source.replace(old, new)
                self.assertNotEqual(source, mutated)
                mutant = mutant_skill / "scripts/install.sh"
                mutant.write_text(mutated)
                mutant.chmod(0o755)
                case = InstallTest("test_install")
                case.installer = mutant
                result = unittest.TestResult()
                case.run(result)
                self.assertEqual(len(result.failures), 1)
                self.assertEqual(len(result.errors), 0)
                self.assertIn(failure_assertion, result.failures[0][1])
                print(f"must-fail control: {rule} behavior removed, assertion turned red: {failure_assertion}")


# Install, launch and capture name one device; `booted` can pick another booted simulator.
class DeviceTest(unittest.TestCase):
    workflow = template.decode()

    def test_device(self):
        calls = [line.split()[2:4] for line in self.workflow.splitlines()
                 if line.split()[:2] == ["xcrun", "simctl"]]
        operations = {operation for operation, _ in calls}
        for required in ("bootstatus", "install", "launch", "io"):
            self.assertIn(required, operations, f"simctl {required} missing")
        for operation, device in calls:
            self.assertEqual(device, '"$simulator"', f"simctl {operation} device differs")


    def test_device_controls(self):
        workflow = self.workflow
        capture = 'xcrun simctl io "$simulator" screenshot'
        for rule, new, failure_assertion in (
            ("capture device", "xcrun simctl io booted screenshot", "simctl io device differs"),
            ("capture presence", ": " + capture, "simctl io missing"),
        ):
            with self.subTest(rule=rule):
                self.assertEqual(workflow.count(capture), 1)
                case = DeviceTest("test_device")
                case.workflow = workflow.replace(capture, new)
                result = unittest.TestResult()
                case.run(result)
                self.assertEqual(len(result.failures), 1)
                self.assertEqual(len(result.errors), 0)
                self.assertIn(failure_assertion, result.failures[0][1])
                print(f"must-fail control: {rule} removed, assertion turned red: {failure_assertion}")


# run-all.sh reads the outer unittest summary; rejected mutants are passing controls.
unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
