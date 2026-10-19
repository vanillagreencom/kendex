"""owner-note routes one directive through each side's own lane-mail, host first."""
from pathlib import Path
import shutil
import tempfile
import unittest

from mail_world import BASH, REPO, SCRIPTS, MailWorld, make_project

NOTE = "Check the release notes.\nThen report.\n"
# The overseer's directive 1792369993-3375997-24882 fixes these exact bytes.
FOOTER = ("Before you act on this note or delegate it: check its facts against their source and test its "
          "approach against your repository's rules and code-quality § Over-Engineering in your checkout "
          "(the system's own interface, platform first, no over-engineering). Where it is wrong, or a simpler "
          "or better route exists, adjust it, and state in your reply what you changed and why.")


class OwnerNote(MailWorld):
    scripts = SCRIPTS

    def setUp(self):
        super().setUp()
        self.home = make_project(self.root / "home", overseer=False)
        self.note = self.root / "note.md"
        self.note.write_text(NOTE)
        self.executable("ssh", '#!/bin/sh\nprintf "%s\\n" "$1" >> "$SSH_LOG"\nshift\ncd "$REMOTE_HOME" || exit 1\n'
                        'HOME="$REMOTE_HOME" REGISTRY="$REMOTE_REGISTRY" TMPDIR="$REMOTE_TMP" exec sh -c "$*"\n')

    def world(self, name, remote, local):
        """Scratch roots per side, each (path, overseer recorded[, mailbox installed]); returns their paths."""
        base = self.root / name
        sides = {}
        for side, rows in (("remote", remote), ("local", local)):
            sides[side] = []
            for path, overseer, *mailbox in rows:
                root = make_project(base / side / path, overseer=overseer)
                if mailbox == [False]:
                    shutil.rmtree(root / ".agents/skills/mailbox")
                sides[side].append(root)
        (base / "remote-home").mkdir()
        (base / "remote-tmp").mkdir()
        (base / "remote-registry").write_text("".join(str(path) + "\n" for path in sides["remote"]))
        self.registry.write_text("".join(str(path) + "\n" for path in sides["local"]) +
                                 str(self.root / "elsewhere") + " (folder not found)\n")
        return base, sides

    def send(self, base, host):
        env = dict(self.env, SSH_LOG=str(base / "ssh.log"), REMOTE_HOME=str(base / "remote-home"),
                   REMOTE_REGISTRY=str(base / "remote-registry"), REMOTE_TMP=str(base / "remote-tmp"))
        if host:
            env["JARVIS_CONTROL_HOST"] = "host.example"
        return self.command([BASH, self.scripts / "owner-note", "app", self.note], self.home, env)

    def test_routes(self):
        # Each row: host set, host roots, local roots, exit, refusal key=value, the side that lands.
        rows = (("host overseer", True, [("app", True)], [("app", True)], 0, None, "remote"),
                ("host absent", True, [("app", False)], [("app", True)], 0, None, "local"),
                ("host lists none", True, [], [("app", True)], 0, None, "local"),
                ("host mailbox missing", True, [("app", True, False)], [("app", True)], 2, "send-failed=host", None),
                ("neither", True, [("app", False)], [("app", False)], 2, "no-overseer=app", None),
                ("ambiguous", False, [], [("a/app", True), ("b/app", True)], 2, "repo-ambiguous=app", None),
                ("no host", False, [("app", True)], [("app", True)], 0, None, "local"))
        for name, host, remote, local, code, key, lands in rows:
            with self.subTest(row=name):
                base, sides = self.world(name.replace(" ", "-"), remote, local)
                result = self.send(base, host)
                self.assertEqual(result.returncode, code, result.stderr)
                if key is not None:
                    self.assertTrue(result.stderr.startswith("owner-note: " + key + "\n"), result.stderr)
                for side, roots in sides.items():
                    for root in roots:
                        rows_written = self.box(root, "to-lane")
                        if side == lands:
                            self.assertEqual([(row["kind"], row["from"], row["text"]) for row in rows_written],
                                             [("directive", "owner", NOTE.rstrip("\n") + "\n\n" + FOOTER)])
                            self.assertEqual(rows_written[0]["text"].count(FOOTER), 1)
                        else:
                            self.assertEqual(rows_written, [], "%s %s" % (side, root))
                self.assertEqual(list((base / "remote-tmp").iterdir()), [])
                calls = (base / "ssh.log").read_text().splitlines() if (base / "ssh.log").exists() else []
                if host:
                    self.assertEqual(set(calls), {"host.example"})
                else:
                    self.assertEqual(calls, [])

    def test_instrument_control(self):
        # A route that also sends on this machine after the host took the note
        # must fail the host row.
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder) / "jarvis/scripts"
            shutil.copytree(SCRIPTS, copy)
            for name in ("mailbox", "orch"):
                Path(folder, name).symlink_to(REPO / "skills" / name, target_is_directory=True)
            path = copy / "lib/owner_note.py"
            source = path.read_text()
            old = "            raise Refusal(\"send-failed\", side, str(error)) from error\n        return side, matches[0]\n"
            self.assertEqual(source.count(old), 1)
            path.write_text(source.replace(old, "            raise Refusal(\"send-failed\", side, str(error)) from error\n"
                                                "        if side == 'local':\n            return side, matches[0]\n"))
            case = OwnerNote(methodName="test_routes")
            case.scripts = copy
            case.setUp()
            try:
                with self.assertRaises(AssertionError):
                    case.test_routes()
            finally:
                case.doCleanups()


if __name__ == "__main__":
    unittest.main()
