#!/usr/bin/env bash
# Surface: macOS suite eligibility, classification discovery and native replacement.
# Inputs: tools/macos-test-contracts{,.json}, skills/orch/tests/run-all.sh,
# skills/github/tests/native-contracts.test.sh and the runner's sourced libraries.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)"
mkdir -p "$ROOT/tmp"
exec python3 - "$ROOT" "$BASH" <<'PY'
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1])
BASH = sys.argv[2]
sys.argv = [sys.argv[0]]


class NativeContracts(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(dir=ROOT / "tmp")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        (self.root / "tools").mkdir()
        self.owner = self.root / "tools/macos-test-contracts"
        shutil.copyfile(ROOT / "tools/macos-test-contracts", self.owner)
        self.owner.chmod(0o755)
        self.contracts = {f"skills/demo/tests/{name}.sh": classification
                          for name, classification in (("native", "native"), ("mixed", "mixed"),
                              ("unresolved", "unresolved"), ("duplicate", "linux-duplicate"),
                              ("bash4", "linux-only"))}
        self.data = {"contracts": self.contracts, "native_replacements": {}, "linux_only_shards": []}
        for path in self.contracts:
            suite = self.root / path
            suite.parent.mkdir(parents=True, exist_ok=True)
            suite.write_text('printf "%s\\n" ' + suite.stem + '\n')
        self.save()

    def save(self):
        self.owner.with_suffix(".json").write_text(json.dumps(self.data))

    def call(self, mode, paths=()):
        return subprocess.run([str(self.owner), mode], input="\n".join(paths),
                              cwd=self.root, capture_output=True, text=True, timeout=60)

    def test_classification_and_discovery(self):
        self.assertEqual(self.call("--check").returncode, 0)
        expected = list(self.contracts)[:3]
        answer = self.call("--filter", self.contracts)
        self.assertEqual((answer.returncode, answer.stdout.splitlines()), (0, expected))
        self.contracts[expected[0]] = "linux-duplicate"
        self.save()
        self.assertNotEqual(self.call("--filter", self.contracts).stdout.splitlines(), expected)

    def test_unknown_and_absent_suites_refuse(self):
        future = "skills/demo/tests/future.sh"
        (self.root / future).touch()
        self.assertEqual(self.call("--check").returncode, 2)
        answer = self.call("--filter", [*self.contracts, future])
        self.assertEqual((answer.returncode, answer.stdout), (2, ""))
        (self.root / future).unlink()
        (self.root / next(iter(self.contracts))).unlink()
        self.assertEqual(self.call("--check").returncode, 2)

    def test_native_replacement_must_exist_and_remain_native(self):
        source = "skills/demo/tests/mixed.sh"
        replacement = "skills/demo/tests/native.sh"
        self.data["native_replacements"][source] = replacement
        self.save()
        self.assertEqual(self.call("--filter", [source, replacement]).stdout.splitlines(), [replacement])
        self.assertEqual(self.call("--filter", [source]).returncode, 2)
        for defect in ("classification", "absent"):
            with self.subTest(defect=defect):
                if defect == "classification":
                    self.contracts[replacement] = "linux-duplicate"
                    self.save()
                else:
                    self.contracts[replacement] = "native"
                    self.save()
                    (self.root / replacement).unlink()
                answer = self.call("--filter", [source, replacement])
                self.assertEqual((answer.returncode, answer.stdout), (2, ""))

    def test_real_runner_applies_profile_before_launch(self):
        files = ("skills/orch/tests/run-all.sh", "skills/orch/tests/lib/git-env.sh",
                 "skills/orch/scripts/lib/lane-state.sh", "skills/github/scripts/lib/group-leader.sh")
        for path in files:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, target)
        argv = [BASH, str(self.root / files[0]), "--battery", str(self.root / "skills/demo/tests")]
        environment = os.environ | {"RUN_ALL_NATIVE_CONTRACTS": str(self.owner)}
        native = self.root / "skills/demo/tests/native.sh"
        native.write_text('[ -z "${RUN_ALL_NATIVE_CONTRACTS:-}" ] || exit 1\n' + native.read_text())
        answer = subprocess.run(argv, env=environment, capture_output=True, text=True, timeout=60)
        self.assertEqual(answer.returncode, 0, answer.stderr)
        started = {line.removeprefix("start suite=") for line in answer.stdout.splitlines() if line.startswith("start suite=")}
        self.assertEqual(started, {"native", "mixed", "unresolved"})
        runner = self.root / files[0]
        original = runner.read_text()
        self.assertEqual(original.count('unset RUN_ALL_NATIVE_CONTRACTS'), 1)
        runner.write_text(original.replace('unset RUN_ALL_NATIVE_CONTRACTS', ': || unset RUN_ALL_NATIVE_CONTRACTS'))
        answer = subprocess.run(argv, env=environment, capture_output=True, text=True, timeout=60)
        self.assertEqual(answer.returncode, 1)
        runner.write_text(original)
        (self.root / "skills/demo/tests/future.sh").write_text("exit 0\n")
        answer = subprocess.run(argv, env=environment, capture_output=True, text=True, timeout=60)
        self.assertEqual(answer.returncode, 2)
        self.assertNotIn("start suite=", answer.stdout)
        # Removing the profile is the control for the real runner boundary.
        environment.pop("RUN_ALL_NATIVE_CONTRACTS")
        answer = subprocess.run(argv, env=environment, capture_output=True, text=True, timeout=60)
        self.assertEqual(answer.returncode, 0, answer.stderr)
        self.assertIn("start suite=future", answer.stdout)
        self.assertIn("start suite=duplicate", answer.stdout)

    def test_native_wrapper_reports_each_child_failure(self):
        target = self.root / "skills/github/tests"
        target.mkdir(parents=True)
        wrapper = target / "native-contracts.test.sh"
        source = (ROOT / "skills/github/tests/native-contracts.test.sh").read_text()
        wrapper.write_text(source)
        for name, code in (("pr-merge", 1), ("pr-view", 0)):
            (target / (name + ".test.sh")).write_text('[ "$1" = --native ] || exit 2\necho ' + name + '\nexit ' + str(code) + '\n')
        def run():
            return subprocess.run([BASH, str(wrapper)], capture_output=True, text=True, timeout=60)
        answer = run()
        self.assertEqual((answer.returncode, answer.stdout.splitlines()), (1, ["pr-merge", "pr-view"]))
        self.assertIn("native-contracts: failed=pr-merge", answer.stderr)
        self.assertEqual(source.count('    fail=1'), 1)
        wrapper.write_text(source.replace('    fail=1', '    fail=0'))
        self.assertNotEqual(run().returncode, 1)


unittest.main()
PY
