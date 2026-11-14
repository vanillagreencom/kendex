"""owner-note resolves registered routes without mail effects and sends directives."""
import json
import os
from pathlib import Path
import shlex
import shutil
import tempfile
import unittest

from mail_world import BASH, REPO, SCRIPTS, MailWorld, control_account, make_project

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
        # The overseer every world records is a session on this test's own
        # tmux server, on its own socket and reading no configuration, which
        # agent-runtime's controller status judges for lane-mail. The server
        # keeps a second window's pane after its process exited, and a third
        # window's pane was closed.
        self.socket = self.root / "reader.sock"

        def tmux(*args):
            result = self.command(["tmux", "-S", self.socket, "-f", "/dev/null", *args], self.root)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()
        tmux("new-session", "-d", "-s", "reader", "-x", "80", "-y", "24", "exec sleep 600")
        self.addCleanup(self.command, ["tmux", "-S", self.socket, "kill-server"], self.root)
        running = tmux("display-message", "-p", "-t", "=reader:", "#{pane_id}")
        tmux("set-option", "-g", "remain-on-exit", "on")
        self.dead_pane = tmux("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "=reader:", "exit 3")
        self.closed_pane = tmux("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "=reader:", "exec sleep 600")
        tmux("kill-pane", "-t", self.closed_pane)
        for _ in range(100):
            if tmux("display-message", "-p", "-t", self.dead_pane, "#{pane_dead}") == "1":
                break
            self.command(["sleep", "0.05"], self.root)
        self.assertEqual(tmux("display-message", "-p", "-t", self.dead_pane, "#{pane_dead}"), "1")
        server, start = tmux("display-message", "-p", "#{pid} #{start_time}").split()
        self.reader = {"server": server, "server_start": int(start), "pane": running, "server_socket": str(self.socket)}
        self.gone_server = self.command(["sh", "-c", "echo $$"], self.root).stdout.strip()
        # A ps that cannot run, for the one process read a record's start
        # recorded in ps's own form asks.
        self.failing_ps = self.root / "failing-ps"
        self.failing_ps.mkdir()
        (self.failing_ps / "ps").write_text("#!/bin/sh\necho ps-refused >&2\nexit 2\n")
        (self.failing_ps / "ps").chmod(0o755)
        recorded = os.environ.get("MAIL_WORLD_OVERSEER")
        os.environ["MAIL_WORLD_OVERSEER"] = json.dumps(self.reader)
        self.addCleanup(lambda: os.environ.pop("MAIL_WORLD_OVERSEER") if recorded is None
                        else os.environ.update(MAIL_WORLD_OVERSEER=recorded))
        self.executable("ssh", '#!/bin/sh\nprintf "%s\\n" "$1" >> "$SSH_LOG"\nshift\ncd "$REMOTE_HOME" || exit 1\n'
                        'HOME="$REMOTE_HOME" REGISTRY="$REMOTE_REGISTRY" TMPDIR="$REMOTE_TMP" exec sh -c "$*"\n')

    def world(self, name, remote, local):
        """Scratch roots per side, each (path, overseer recorded[, mailbox installed]); returns their paths."""
        base = self.root / name
        base.mkdir()
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

    def send(self, base, host, resolve=False):
        env = dict(self.env, SSH_LOG=str(base / "ssh.log"), REMOTE_HOME=str(base / "remote-home"),
                   REMOTE_REGISTRY=str(base / "remote-registry"), REMOTE_TMP=str(base / "remote-tmp"))
        if host:
            env["JARVIS_CONTROL_HOST"] = "host.example"
        operation = ["--resolve", "app"] if resolve else ["app", self.note]
        return self.command([BASH, self.scripts / "owner-note", *operation], self.home, env)

    def mailbox_snapshot(self, roots):
        return {str(path): path.read_bytes() for root in roots
                for path in (root / "tmp/lane-mail").rglob("*") if path.is_file()}

    def assert_destination(self, result, destination, root):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "destination": destination, "host": destination[4:] if destination.startswith("ssh:") else None,
            "user": None, "root": str(root), "mailbox": str(root / ".agents/skills/mailbox/scripts/lane-mail")})

    def test_routes(self):
        # Resolution names the first registered route; sending alone can fall
        # back after overseer-absent or fail on a missing mailbox.
        rows = (("host overseer", True, [("app", True)], [("app", True)], 0, None, "remote", "remote"),
                ("host absent", True, [("app", False)], [("app", True)], 0, None, "local", "remote"),
                ("host lists none", True, [], [("app", True)], 0, None, "local", "local"),
                ("host mailbox missing", True, [("app", True, False)], [("app", True)], 2, "send-failed=host", None, "remote"),
                ("neither", True, [("app", False)], [("app", False)], 2, "no-overseer=app", None, "remote"),
                ("unregistered", True, [], [], 2, "no-overseer=app", None, None),
                ("ambiguous", False, [], [("a/app", True), ("b/app", True)], 2, "repo-ambiguous=app", None, None),
                ("no host", False, [("app", True)], [("app", True)], 0, None, "local", "local"))
        for name, host, remote, local, code, key, lands, resolved in rows:
            with self.subTest(row=name):
                base, sides = self.world(name.replace(" ", "-"), remote, local)
                roots = [root for side in sides.values() for root in side]
                before = self.mailbox_snapshot(roots)
                resolution = self.send(base, host, resolve=True)
                self.assertEqual(self.mailbox_snapshot(roots), before)
                if resolved:
                    destination = "ssh:host.example" if resolved == "remote" else "local"
                    self.assert_destination(resolution, destination, sides[resolved][0])
                else:
                    self.assertEqual(resolution.returncode, 2, resolution.stderr)
                    self.assertEqual(resolution.stdout, "")
                    self.assertEqual(resolution.stderr.splitlines()[0], "owner-note: " + key)
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

    def test_reader_required(self, only=None):
        # The recorded overseer is judged where its record names it, on this
        # test's own tmux server: a session that stopped, a pane its process
        # left, an earlier server or a gone one has no reader, and a read that
        # fails is unjudged with agent-runtime's cause. Succession keeps the
        # predecessor's identity while pending, then publishes the opened
        # successor before either takes another turn.
        live = self.reader
        silent = str(self.root / "silent.sock")
        rows = (
            ("unnamed", {"window": "@1"}, {}, "no-reader", "live=false"),
            ("stopped", dict(live, pane=self.closed_pane), {}, "no-reader", "live=false"),
            ("dead", dict(live, pane=self.dead_pane), {}, "no-reader", "live=false"),
            ("reused", dict(live, server_start=live["server_start"] - 1), {}, "no-reader", "live=false"),
            ("server-gone", dict(live, server=self.gone_server, server_socket=str(self.root / "gone.sock")), {},
             "no-reader", "live=false"),
            ("server-unreachable", dict(live, server_socket=silent), {}, "reader-unjudged", "cause=server-unreachable"),
            ("process-unreadable", dict(live, harness_pid=live["server"], harness_start="Thu Nov 13 10:00:00 2026"),
             {"PATH": str(self.failing_ps) + os.pathsep + self.env["PATH"]}, "reader-unjudged", "cause=ps-exit-2"),
            ("pending", dict(live, pending={"harness": "claude", "model": "opus"}), {}, None, None),
            ("successor", dict(live, generation=2), {}, None, None),
            ("older", live, {}, "option-unknown", None),
            ("recorded", live, {}, None, None),
            # Managed Jarvis supplies its named-server TMUX; SSH can supply none.
            ("caller-elsewhere", live, {"TMUX": silent + ",1,0"}, None, None),
        )
        for name, record, extra, refusal, field in rows:
            if only is not None and name != only:
                continue
            for host in (False, True):
                with self.subTest(row=name, host=host):
                    base, sides = self.world(name + ("-host" if host else "-local"),
                                             [("app", True)] if host else [],
                                             [] if host else [("app", True)])
                    root = sides["remote" if host else "local"][0]
                    state = root / ".agents/skills/orch/scripts/workflow-state"
                    result = self.command([state, "set", "oversee", "controller", json.dumps(record)], root)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    if name == "older":
                        installed = root / ".agents/skills/mailbox/scripts"
                        installed.unlink()
                        shutil.copytree(REPO / "skills/mailbox/scripts", installed)
                        path = installed / "lane-mail"
                        source = path.read_text()
                        option = "    --require-reader) REQUIRE_READER=1; shift ;;\n"
                        self.assertEqual(source.count(option), 1)
                        path.write_text(source.replace(option, ""))
                    before = self.mailbox_snapshot([root])
                    original_env = self.env.copy()
                    self.env.update(extra)
                    try:
                        result = self.send(base, host)
                    finally:
                        self.env = original_env
                    if refusal:
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertEqual(result.stdout, "")
                        if field:
                            self.assertIn("lane-mail: %s=%s %s\n" % (refusal, root, field), result.stderr)
                        else:
                            self.assertIn("lane-mail: " + refusal + "=", result.stderr)
                        self.assertEqual(self.mailbox_snapshot([root]), before)
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn("owner-note: sent ", result.stdout)
                        self.assertEqual([row["text"] for row in self.box(root, "to-lane")],
                                         [NOTE.rstrip("\n") + "\n\n" + FOOTER])
                    self.assertEqual(list((base / "remote-tmp").iterdir()), [])

    def test_reader_instrument_control(self):
        # Each mutation must fail its named regression row, not a neighbouring
        # refusal: bypassing the gate or the status's live answer delivers
        # without a reader, while dropping the status's refusal reports a read
        # that failed as nobody reading.
        controls = (
            ("unnamed", '    [ "$REQUIRE_READER" -eq 0 ] || lm_peer_reader\n',
             '    [ "$REQUIRE_READER" -eq 0 ] || :\n', 0, ["directive"], None),
            ("stopped", '  elif [ "$LM_READER_LIVE" != true ]; then\n', '  elif false; then\n', 0, ["directive"], None),
            ("server-unreachable", '  elif [ -n "$LM_READER_CAUSE" ]; then\n', '  elif false; then\n', 2, [],
             "no-reader"),
        )
        for row_name, old, new, code, kinds, key in controls:
            with self.subTest(row=row_name), tempfile.TemporaryDirectory() as folder:
                package = Path(folder) / "mailbox/scripts"
                shutil.copytree(REPO / "skills/mailbox/scripts", package)
                for name in ("orch", "agent-runtime"):
                    Path(folder, name).symlink_to(REPO / "skills" / name, target_is_directory=True)
                path = package / "lane-mail"
                source = path.read_text()
                self.assertEqual(source.count(old), 1)
                mutant = source.replace(old, new)
                self.assertNotEqual(source, mutant)
                path.write_text(mutant)
                case = OwnerNote(methodName="test_reader_required")
                case.setUp()
                original_world = case.world

                def mutant_world(*args):
                    base, sides = original_world(*args)
                    for roots in sides.values():
                        for root in roots:
                            installed = root / ".agents/skills/mailbox/scripts"
                            installed.unlink()
                            installed.symlink_to(package, target_is_directory=True)
                    return base, sides

                case.world = mutant_world
                sent = []
                original_send = case.send

                def observe_send(*args):
                    result = original_send(*args)
                    sent.append(result)
                    return result

                case.send = observe_send
                try:
                    with self.assertRaises(AssertionError):
                        case.test_reader_required(only=row_name)
                    self.assertEqual(len(sent), 1)
                    self.assertEqual(sent[0].returncode, code, sent[0].stderr)
                    if code == 0:
                        self.assertIn("lane-mail: sent ", sent[0].stdout)
                        self.assertIn("owner-note: sent ", sent[0].stdout)
                    else:
                        self.assertEqual(sent[0].stdout, "")
                        self.assertIn("lane-mail: %s=" % key, sent[0].stderr)
                    root = case.root / (row_name + "-local/local/app")
                    self.assertEqual([row["kind"] for row in case.box(root, "to-lane")], kinds)
                finally:
                    case.doCleanups()

    def control_user_world(self):
        """The control host as its SSH user, holding a clone whose recorded overseer
        stopped, and as the `overseer` account the shim sudo reaches, holding the clone
        its live overseer reads; returns (ssh-user clone, overseer clone, sudo log, env)."""
        base, sides = self.world("control-user", [("app", True)], [])
        account = base / "overseer-account"
        clone = make_project(account / "dev/app")
        log = control_account(self.executable, self.bin, account, [clone])
        env = dict(self.env, SSH_LOG=str(base / "ssh.log"), REMOTE_HOME=str(base / "remote-home"),
                   REMOTE_REGISTRY=str(base / "remote-registry"), REMOTE_TMP=str(base / "remote-tmp"),
                   ACCOUNT=str(account), JARVIS_CONTROL_HOST="host.example", JARVIS_CONTROL_USER="overseer")
        return sides["remote"][0], clone, log, env

    def test_control_user(self):
        # A control host whose overseers run as another account: listing and
        # sending run there as that account, never into the SSH user's clone.
        stale, clone, log, env = self.control_user_world()
        result = self.command([BASH, self.scripts / "owner-note", "app", self.note], self.home, env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([(row["kind"], row["from"], row["text"]) for row in self.box(clone, "to-lane")],
                         [("directive", "owner", NOTE.rstrip("\n") + "\n\n" + FOOTER)])
        self.assertEqual(self.box(stale, "to-lane"), [])
        # Both accounts share this filesystem, so where the note lands cannot
        # show who sent it; the account's sudo log does.
        calls = [row.split("\t", 1) for row in log.read_text().splitlines()]
        self.assertEqual([(user, "kendex project list" in command, "owner-note " + shlex.quote(str(clone)) in command)
                          for user, command in calls], [("overseer", True, False), ("overseer", False, True)])
        resolution = self.command([BASH, self.scripts / "owner-note", "--resolve", "app"], self.home, env)
        self.assertEqual(resolution.returncode, 0, resolution.stderr)
        self.assertEqual(json.loads(resolution.stdout), {
            "destination": "ssh:host.example", "host": "host.example", "user": "overseer", "root": str(clone),
            "mailbox": str(clone / ".agents/skills/mailbox/scripts/lane-mail")})

    def test_control_user_instrument_control(self):
        # Listing and sending as the SSH user land the note in the clone whose
        # recorded overseer stopped, and must fail test_control_user.
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder) / "jarvis/scripts"
            shutil.copytree(SCRIPTS, copy)
            for name in ("mailbox", "orch"):
                Path(folder, name).symlink_to(REPO / "skills" / name, target_is_directory=True)
            path = copy / "lib/watch.py"
            source = path.read_text()
            old = "    if destination.user:\n"
            self.assertEqual(source.count(old), 1)
            mutant = source.replace(old, "    if False:\n")
            self.assertNotEqual(source, mutant)
            compile(mutant, str(path), "exec")
            path.write_text(mutant)
            case = OwnerNote(methodName="test_control_user")
            case.scripts = copy
            case.setUp()
            try:
                with self.assertRaises(AssertionError):
                    case.test_control_user()
                written = case.box(case.root / "control-user/remote/app", "to-lane")
                self.assertEqual([row["text"] for row in written], [NOTE.rstrip("\n") + "\n\n" + FOOTER])
            finally:
                case.doCleanups()

    def test_satellite_instructs_no_overseer(self):
        base, sides = self.world("satellite", [("app", True)], [("app", True)])
        listed = self.root / "kendex.log"
        self.executable("kendex", '#!/bin/sh\nprintf "%s\\n" "$*" >> "$KENDEX_LOG"\ncat "$REGISTRY"\n')
        self.env.update(KENDEX_LOG=str(listed), JARVIS_MAIN_HOST="main.example:/srv/home")
        result = self.send(base, True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stderr.split("\n")[0], "owner-note: role-satellite=main.example:/srv/home")
        self.assertEqual([self.box(root, "to-lane") for roots in sides.values() for root in roots], [[], []])
        self.assertFalse((base / "ssh.log").exists())
        self.assertFalse(listed.exists())
        resolution = self.send(base, True, resolve=True)
        self.assert_destination(resolution, "local", sides["local"][0])
        self.assertFalse((base / "ssh.log").exists())

    def test_resolve_preserves_mailbox(self):
        base, sides = self.world("read-only", [("app", True)], [("app", True)])
        roots = [root for side in sides.values() for root in side]
        for root in roots:
            self.mail(root, "send", "Already delivered", "--directive")
            self.mail(root, "notice", "Already reported", "--to", "owner")
            for options in (("inbox",), ("events", "--box", "to-overseer", "--mark-read")):
                result = self.command([root / ".agents/skills/mailbox/scripts/lane-mail", *options,
                                       "--item", "overseer"], root)
                self.assertEqual(result.returncode, 0, result.stderr)
            self.mail(root, "send", "Still unread", "--directive")
            self.mail(root, "notice", "Still unreported", "--to", "owner")
        before = self.mailbox_snapshot(roots)
        self.assertTrue(any(path.endswith("to-lane.cursor") for path in before))
        self.assertTrue(any(path.endswith("to-overseer.seen") for path in before))
        resolution = self.send(base, True, resolve=True)
        self.assert_destination(resolution, "ssh:host.example", sides["remote"][0])
        self.assertEqual(self.mailbox_snapshot(roots), before)

    def test_declared_destinations(self):
        # Each row: control/local/satellite names, selector, failed alias,
        # exit, refusal, and the only mailbox permitted to receive the note.
        rows = (
            ("satellite", "other", "other", "app", [], "", 0, None, "satellite"),
            ("local", "other", "app", "other", [], "", 0, None, "local"),
            ("duplicate", "app", "app", "other", [], "", 2, "repo-ambiguous", None),
            ("remote duplicate", "app", "other", "app", [], "", 2, "repo-ambiguous", None),
            ("selected", "app", "app", "app", ["--host", "satellite"], "control", 0, None, "satellite"),
            ("selected local", "app", "app", "app", ["--local"], "satellite", 0, None, "local"),
            ("unread", "other", "app", "other", [], "satellite", 2, "project-list-failed", None),
            ("unknown", "app", "app", "app", ["--host", "unknown"], "", 2, "destination-unknown", None),
        )
        for name, control, local, satellite, selector, failed, code, refusal, landed in rows:
            with self.subTest(row=name):
                base, sides = self.world(name.replace(" ", "-"), [(control, True)], [(local, True)])
                target = make_project(base / "satellite" / satellite)
                satellite_registry = base / "satellite-registry"
                satellite_registry.write_text(str(target)+"\n")
                self.executable("ssh", '#!/bin/sh\n'
                    '[ "$1" != "$FAIL_ALIAS" ] || { echo "transport refused" >&2; exit 255; }\n'
                    'case "$1" in control) REGISTRY=$REMOTE_REGISTRY;; satellite) REGISTRY=$SATELLITE_REGISTRY;; *) exit 94;; esac\n'
                    'shift\nexport REGISTRY\nHOME=$REMOTE_HOME TMPDIR=$REMOTE_TMP exec sh -c "$*"\n')
                env = dict(self.env, JARVIS_CONTROL_HOST="control", JARVIS_REMOTE_HOSTS="satellite satellite control",
                           FAIL_ALIAS=failed, REMOTE_HOME=str(base / "remote-home"),
                           REMOTE_TMP=str(base / "remote-tmp"), REMOTE_REGISTRY=str(base / "remote-registry"),
                           SATELLITE_REGISTRY=str(satellite_registry))
                targets = {"control": sides["remote"][0], "local": sides["local"][0], "satellite": target}
                before = self.mailbox_snapshot(targets.values())
                resolution = self.command([BASH, self.scripts / "owner-note", "--resolve", *selector, "app"], self.home, env)
                self.assertEqual(self.mailbox_snapshot(targets.values()), before)
                self.assertEqual(resolution.returncode, code, resolution.stderr)
                if landed:
                    destination = "local" if landed == "local" else "ssh:" + landed
                    self.assert_destination(resolution, destination, targets[landed])
                result = self.command([BASH, self.scripts / "owner-note", *selector, "app", self.note], self.home, env)
                self.assertEqual(result.returncode, code, result.stderr)
                if refusal:
                    self.assertTrue(result.stderr.startswith("owner-note: "+refusal+"="), result.stderr)
                    self.assertEqual(resolution.stdout, "")
                    self.assertEqual(resolution.stderr, result.stderr)
                for label, root in targets.items():
                    written = self.box(root, "to-lane")
                    self.assertEqual([row["text"] for row in written],
                                     [NOTE.rstrip("\n")+"\n\n"+FOOTER] if label == landed else [], label)

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
            old = "        return side, root, target.key"
            self.assertEqual(source.count(old), 1)
            mutant = source.replace(old, "        if side == 'local':\n            return side, root, target.key")
            self.assertNotEqual(source, mutant)
            compile(mutant, str(path), "exec")
            path.write_text(mutant)
            case = OwnerNote(methodName="test_routes")
            case.scripts = copy
            case.setUp()
            try:
                with self.assertRaises(AssertionError):
                    case.test_routes()
                for side in ("remote", "local"):
                    written = case.box(case.root / "host-overseer" / side / "app", "to-lane")
                    self.assertEqual([row["text"] for row in written],
                                     [NOTE.rstrip("\n") + "\n\n" + FOOTER], side)
            finally:
                case.doCleanups()

    def test_resolve_instrument_control(self):
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder) / "jarvis/scripts"
            shutil.copytree(SCRIPTS, copy)
            for name in ("mailbox", "orch"):
                Path(folder, name).symlink_to(REPO / "skills" / name, target_is_directory=True)
            path = copy / "lib/owner_note.py"
            source = path.read_text()
            old = '            print(json.dumps({"destination": target.key'
            self.assertEqual(source.count(old), 1)
            mutant = source.replace(old, '            send(args.bash, "host", target, root, "unwanted directive")\n' + old)
            self.assertNotEqual(source, mutant)
            compile(mutant, str(path), "exec")
            path.write_text(mutant)
            case = OwnerNote(methodName="test_resolve_preserves_mailbox")
            case.scripts = copy
            case.setUp()
            try:
                with self.assertRaises(AssertionError):
                    case.test_resolve_preserves_mailbox()
                written = case.box(case.root / "read-only/remote/app", "to-lane")
                self.assertEqual(written[-1]["text"], "unwanted directive")
            finally:
                case.doCleanups()


if __name__ == "__main__":
    unittest.main()
