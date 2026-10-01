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
            for expected in (
                template,
                template.replace(b"XCODE_SCHEME: App", b"XCODE_SCHEME: Consumer")
                .replace(b"name=iPhone 16", b"name=iPad Pro (M4)")
                .replace(b"-scheme", b"-workspace Consumer.xcworkspace -scheme")
                .replace(b"shell: bash", b"shell: bash\n        working-directory: apple"),
            ):
                if workflow.exists():
                    workflow.write_bytes(expected)
                result = subprocess.run(
                    [str(self.installer)], cwd=consumer, env=environment,
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(workflow.is_file())
                self.assertEqual(workflow.read_bytes(), expected)


runner = unittest.TextTestRunner(verbosity=2)
result = runner.run(unittest.defaultTestLoader.loadTestsFromTestCase(InstallTest))
if not result.wasSuccessful():
    sys.exit(1)

# The isolated mutant keeps the copy command text but replaces its behavior.
with tempfile.TemporaryDirectory(prefix="xcode-run-control-") as directory:
    mutant_skill = Path(directory).resolve()
    (mutant_skill / "scripts").mkdir()
    (mutant_skill / "templates").mkdir()
    (mutant_skill / "templates/mac-run.yml").write_bytes(template)
    source = InstallTest.installer.read_text()
    old = 'cat -- "$SCRIPT_DIR/../templates/mac-run.yml" > "$workflow"'
    assertions = unittest.TestCase()
    assertions.assertEqual(source.count(old), 1)
    mutated = source.replace(old, ": " + old)
    assertions.assertNotEqual(source, mutated)
    mutant = mutant_skill / "scripts/install.sh"
    mutant.write_text(mutated)
    mutant.chmod(0o755)
    InstallTest.installer = mutant
    result = runner.run(unittest.defaultTestLoader.loadTestsFromTestCase(InstallTest))
    assertions.assertEqual(len(result.failures), 1)
    assertions.assertEqual(len(result.errors), 0)
    print("must-fail control: copy behavior removed, installer test turned red")
PY