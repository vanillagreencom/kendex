"""Exercise the shipped report against committed trees through real Git."""
import errno
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest
from desktop_world import SCRIPTS, World

START = "2026-10-01T00:00:00+00:00"
END = "2026-10-02T00:00:00+00:00"


def rows(output):
    # The report is consumed by audit workflows. Parse its machine-read fields.
    return [dict((key, json.loads(value) if value.startswith('"') else value)
                 for key, value in re.findall(r'(\w+)=("(?:\\.|[^"\\])*"|\S+)', line))
            for line in output.splitlines()]


class Report(World):
    def setUp(self):
        super().setUp()
        self.real_git = shutil.which("git")
        self.bash = os.environ.get("JARVIS_TEST_BASH") or shutil.which("bash")
        self.assertIsNotNone(self.real_git)
        self.assertIsNotNone(self.bash)
        self.bin.joinpath("python3").symlink_to(sys.executable)
        self.clean = dict(self.env)
        self.executable("git", "import json,os,subprocess,sys\n"
                        "data=sys.stdin.buffer.read() if '--batch-check' in sys.argv else None\n"
                        "with open(os.environ['TOOL_LOG'],'a') as f:\n"
                        " f.write(json.dumps({'args':sys.argv[1:], 'input':data.decode() if data else None})+'\\n')\n"
                        f"r=subprocess.run([{self.real_git!r},*sys.argv[1:]],input=data)\n"
                        "sys.exit(r.returncode)\n")
        # The report must ignore all four redirecting Git variables together.
        self.env.update({key: str(self.root / "wrong") for key in
                         ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")})
        self.repo = self.new_repo("report repo")

    def git(self, repo, *args, env=None):
        return subprocess.run([self.real_git, "-C", str(repo), *args], env=env or self.clean,
                              capture_output=True, check=True, timeout=30).stdout

    def new_repo(self, name):
        repo = self.root / name
        repo.mkdir()
        self.git(repo, "init", "-q")
        for key, value in (("user.name", "Fixture"), ("user.email", "fixture@example.invalid"),
                           ("gc.auto", "0"), ("maintenance.auto", "false")):
            self.git(repo, "config", key, value)
        return repo

    def commit(self, repo, files, date):
        for name, data in files.items():
            path = repo / name
            if data is None:
                path.unlink()
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
        self.git(repo, "add", "-A")
        env = dict(self.clean, GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
        self.git(repo, "commit", "-qm", "fixture", env=env)
        return self.git(repo, "rev-parse", "HEAD").decode().strip()

    def audit(self, *repos, since=START, until=END, extra=()):
        return subprocess.run([self.bash, str(SCRIPTS / "docs-audit"), "--since", since,
                               "--until", until, *extra, *map(str, repos or (self.repo,))],
                              env=self.env, capture_output=True, text=True, timeout=30)

    def fixture(self):
        template = {"path": "adopted.md", "template": "templates/workflow.md", "templateHash": "fixture"}
        odd = "odd\n\udcff.md"
        try:
            (self.repo / odd).write_bytes(b"odd\n")
        except OSError as error:
            if error.errno != errno.EILSEQ:
                raise
            # Keep newline coverage when the filesystem rejects the invalid byte sequence.
            odd = "odd\nname.md"
        old = {"changed.md": b"old\n", "removed.md": b"remove\n", "becomes-generated.md": b"hand\n",
               odd: b"odd\n"}
        new = {"changed.md": b"old and new\n", "added.md": b"new\n", "manual.md": b"manual\n",
               odd: b"odd\n"}
        inventory_old = json.dumps(["generated.md", "manual.md", template]).encode()
        inventory_new = json.dumps(["generated.md", "becomes-generated.md", template]).encode()
        excluded = {name: (name + " excluded\n").encode() for name in
                    ("plans/p.md", "deep/plans/p.md", "research/r.md", "deep/research/r.md",
                     "node_modules/n.md", "deep/node_modules/n.md", "fixtures/f.md", "deep/fixtures/f.md",
                     "changelog.d/added/a.md", "CHANGELOG.md", "generated.md", "adopted.md", "unrelated.bin")}
        base = self.commit(self.repo, dict(excluded, **old, **{"manual.md": b"generated before\n",
                           ".kendex-generated.json": inventory_old}), START)
        head = self.commit(self.repo, dict(new, **{"removed.md": None,
                           ".kendex-generated.json": inventory_new}), END)
        return base, head, old, new

    def test_committed_snapshots_and_selected_object_budget(self):
        base, head, old, new = self.fixture()
        self.repo.joinpath(".kendex-generated.json").write_text("[]")
        self.repo.joinpath("changed.md").write_text("pending " * 100)
        result = self.audit(since="2026-10-01T02:00:00+02:00")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        report = rows(result.stdout)
        self.assertEqual({key: report[0][key] for key in ("base", "head", "since", "until", "md_files", "md_bytes")},
                         dict(base=base, head=head, since=START, until=END, md_files="4->4", md_bytes="20->27"))
        self.assertEqual(report[0]["repo_path"], str(self.repo))
        self.assertEqual([(r["path"], r["delta_bytes"], r["bytes"]) for r in report[1:]],
                         [("changed.md", "8", "12"), ("manual.md", "7", "7"), ("added.md", "4", "4")])
        calls = self.calls()
        batches = [call for call in calls if "--batch-check" in call["args"]]
        expected_ids = [sorted({self.git(self.repo, "rev-parse", f"{rev}:{path}").decode().strip()
                                for path in selected}) for rev, selected in ((base, old), (head, new))]
        self.assertEqual([call["input"].splitlines() for call in batches], expected_ids)
        content = [call["args"][-1] for call in calls if "blob" in call["args"]]
        self.assertEqual(content, [self.git(self.repo, "rev-parse", f"{rev}:.kendex-generated.json").decode().strip()
                                   for rev in (base, head)])
        self.assertTrue(all("-l" not in call["args"] for call in calls if "ls-tree" in call["args"]))
        evidence = os.environ.get("DOCS_AUDIT_EVIDENCE")
        if evidence:
            proof = ["# KEN-4102 committed fixture evidence", f"base={base}\nhead={head}"]
            for rev, selected in ((base, old), (head, new)):
                inventory = self.git(self.repo, "show", f"{rev}:.kendex-generated.json").decode()
                proof.append(f"## {rev}\n\nCommitted inventory: `{inventory}`\n\nSelected Markdown:")
                for path in sorted(selected):
                    actual = self.git(self.repo, "show", f"{rev}:{path}")
                    self.assertEqual(actual, selected[path])
                    proof.append(f"- {json.dumps(path)}: {len(actual)} bytes; {actual!r}")
            proof.append("## Actual report\n\n```text\n" + result.stdout + "```")
            Path(evidence).write_text("\n\n".join(proof) + "\n")

    def test_input_contract(self):
        base, head, old, new = self.fixture()
        empty = self.new_repo("empty docs")
        empty_id = self.commit(empty, {".kendex-generated.json": b"[]"}, START)
        unborn = self.new_repo("unborn")
        missing_inventory = self.new_repo("no inventory")
        self.commit(missing_inventory, {"readme.md": b"x"}, START)
        invalid = self.new_repo("invalid inventory")
        self.commit(invalid, {".kendex-generated.json": b"{}"}, START)
        missing_head_inventory = self.new_repo("missing head inventory")
        self.commit(missing_head_inventory, {".kendex-generated.json": b"[]"}, START)
        self.commit(missing_head_inventory, {".kendex-generated.json": None, "r.md": b"x"}, END)
        shallow = self.root / "shallow"
        self.git(self.root, "clone", "-q", "--depth=1", self.repo.as_uri(), str(shallow))
        unavailable = self.new_repo("unavailable selected blob")
        self.commit(unavailable, {".kendex-generated.json": b"[]", "r.md": b"unique missing\n"}, START)
        oid = self.git(unavailable, "rev-parse", "HEAD:r.md").decode().strip()
        (unavailable / ".git/objects" / oid[:2] / oid[2:]).unlink()
        cases = [("empty", empty, {}, 0, "0->0", "0->0"),
                 ("unchanged", self.repo, {"until": START}, 0, "4->4", "20->20"),
                 ("top zero", self.repo, {"extra": ("--top", "0")}, 0, "4->4", "20->27"),
                 ("missing repo", self.root / "absent", {}, 1, None, None),
                 ("unborn", unborn, {}, 1, None, None),
                 ("missing base", self.repo, {"since": "2026-09-01T00:00:00Z"}, 1, None, None),
                 ("missing head", self.repo, {"since": "2026-09-01T00:00:00Z", "until": "2026-09-02T00:00:00Z"}, 1, None, None),
                 ("shallow", shallow, {}, 1, None, None),
                 ("missing base inventory", missing_inventory, {}, 1, None, None),
                 ("missing head inventory", missing_head_inventory, {}, 1, None, None),
                 ("invalid inventory", invalid, {}, 1, None, None),
                 ("missing object", unavailable, {}, 1, None, None)]
        for name, repo, options, status, count, size in cases:
            with self.subTest(name=name):
                result = self.audit(repo, **options)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                report = rows(result.stdout)
                self.assertEqual(len(report), 1)
                if status:
                    self.assertEqual(report[0]["status"], "unread")
                    self.assertTrue(report[0]["cause"])
                    self.assertNotIn("md_bytes", report[0])
                    self.assertNotIn("base", report[0])
                else:
                    self.assertEqual((report[0]["md_files"], report[0]["md_bytes"]), (count, size))
                    self.assertEqual(report[0]["base"], empty_id if repo == empty else base)
        result = self.audit(self.root / "absent", empty)
        self.assertEqual(result.returncode, 1)
        self.assertEqual([r.get("status", "measured") for r in rows(result.stdout)], ["unread", "measured"])
        for options in ({"since": "yesterday"}, {"since": "2026-10-01T00:00:00"},
                        {"since": "2026-10-01T00:00:00+02:99"},
                        {"since": END, "until": START}, {"extra": ("--top", "-1")}):
            with self.subTest(options=options):
                self.assertEqual(self.audit(**options).returncode, 2)

    def test_generated_exclusion_control(self):
        copy = self.root / "control"
        scripts = copy / "scripts"
        tests = copy / "tests"
        scripts.mkdir(parents=True)
        tests.mkdir()
        source = (SCRIPTS / "docs-audit").read_text()
        match = "and path not in generated"
        self.assertEqual(source.count(match), 1)
        mutated = source.replace(match, "and (path not in generated or True)")
        self.assertNotEqual(source, mutated)
        scripts.joinpath("docs-audit").write_text(mutated)
        for name in ("docs-audit.test.sh", "docs_audit_test.py", "desktop_world.py"):
            shutil.copyfile(Path(__file__).parent / name, tests / name)
        env = dict(self.clean, JARVIS_TOOL_SCRIPTS=str(scripts), PATH=str(Path(sys.executable).parent) + os.pathsep + os.defpath)
        result = subprocess.run([self.bash, str(tests / "docs-audit.test.sh"),
                                 "Report.test_committed_snapshots_and_selected_object_budget"],
                                env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("AssertionError", result.stderr)
        self.assertIn("'7->7'", result.stderr)
        self.assertIn("'4->4'", result.stderr)


if __name__ == "__main__":
    unittest.main()
