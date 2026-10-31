"""Surface: op-broker and opq, approved session, private FIFOs and protected outputs."""
import base64
from contextlib import redirect_stderr
import io
import json
import os
from pathlib import Path
import select
import shutil
import signal
import stat
import subprocess
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from desktop_world import SCRIPTS, World, load, run_case

# Records each call. Sign-in needs a terminal, as op's does. Record verbs print
# their arguments and exit 2 when asked. A call fails when HOME/expired existed
# as it started, so a whoami acknowledged before the file appears still renews.
# HOME/ack, when present, takes one byte per whoami.
OP = """import os,sys,json
home=os.environ['HOME']
expired=os.path.exists(home+'/expired')
with open(home+'/calls','a') as f:
    f.write(json.dumps({'verb':sys.argv[1], 'session':os.environ.get('OP_SESSION'), 'biometric':os.environ.get('OP_BIOMETRIC_UNLOCK_ENABLED'), 'account':os.environ.get('OP_ACCOUNT')})+'\\n')
if sys.argv[1]=='whoami' and os.path.exists(home+'/ack'):
    with open(home+'/ack','wb',buffering=0) as f: f.write(b'W')
if expired: sys.exit(1)
if sys.argv[1]=='signin' and not os.isatty(0): sys.exit(1)
elif sys.argv[1]=='signin': print('fixture-session')
elif sys.argv[1]=='read':
    reference=sys.argv[-1]
    if reference.endswith('/fail'): sys.exit(1)
    value=b'fixture-value\\n' if reference.endswith('/newline') else b'fixture-value'
    sys.stdout.buffer.write(value)
    if '--no-newline' not in sys.argv: sys.stdout.buffer.write(b'\\n')
elif sys.argv[1]!='whoami':
    print(' '.join(sys.argv[1:]))
    sys.exit(2 if 'exit-two' in sys.argv else 0)
"""


class Broker(World):
    def start(self, body=None, args=None, terminal=True, leader=False):
        self.executable("op", body or OP)
        self.directory = self.root / "broker"
        if args is None:
            args = ["--directory", str(self.directory), "--account", "fixture-account"]
        # Only a broker whose stdin is a terminal may start an interactive sign-in. A leader broker starts its own
        # session, as the systemd unit does, so no terminal of the test's reaches its calls.
        if terminal:
            controller, stdin = os.openpty()
            self.addCleanup(os.close, controller)
        else:
            stdin = subprocess.DEVNULL
        process = subprocess.Popen([sys.executable, "-B", str(SCRIPTS / "op-broker"), *args],
            env=self.env, stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=leader)
        if terminal:
            os.close(stdin)

        def stop():
            if process.poll() is None:
                process.terminate()
            try:
                process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=10)
                self.fail("broker did not stop")

        self.addCleanup(stop)
        self.assertTrue(select.select([process.stdout], [], [], 10)[0], "broker did not report readiness")
        self.assertEqual(process.stdout.readline(), b"op-broker: state=ready\n")
        return process

    def test_optional_op_refusal(self):
        result = self.run_tool("op-broker", "--directory", self.root / "missing")
        self.assertEqual(result.returncode, 2)
        # Tool consumers use the stable dependency key, not the explanation.
        self.assertEqual(result.stderr.splitlines()[0], b"op-broker: optional-dependency=op")
        self.assertFalse((self.root / "missing").exists())

    def test_session_and_parallel_clients(self):
        process = self.start()
        outputs = [self.root / name for name in ("one", "two")]
        clients = [subprocess.Popen([sys.executable, "-B", str(SCRIPTS / "opq"), "--directory",
                   str(self.directory), "read", "op://fixture/item/password", "--output", str(output)],
                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for output in outputs]
        try:
            for client, output in zip(clients, outputs):
                stdout, stderr = client.communicate(timeout=15)
                self.assertEqual(client.returncode, 0, stderr)
                self.assertEqual(stdout, b"")
                self.assertEqual(output.read_bytes(), b"fixture-value")
                self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        finally:
            for client in clients:
                if client.poll() is None:
                    client.kill()
                    client.communicate(timeout=10)
        calls = self.calls()
        self.assertEqual([call["verb"] for call in calls], ["signin", "whoami", "read", "read"])
        for call in calls[1:]:
            self.assertEqual(call["session"], "fixture-session")
            self.assertEqual(call["biometric"], "false")
            self.assertEqual(call["account"], "fixture-account")
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()), ["lock", "requests"])
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)
        process.terminate()
        _, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertFalse(self.directory.exists())

    def test_exact_field_bytes(self):
        self.start()
        for field, expected in (("password", b"fixture-value"), ("newline", b"fixture-value\n")):
            with self.subTest(field=field):
                output = self.root / field
                result = self.run_tool("opq", "--directory", self.directory, "read",
                                       "op://fixture/item/" + field, "--output", output)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_bytes(), expected)

    def test_cancelled_clients(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                ack_path, release_path = self.root / "ack", self.root / "release"
                os.mkfifo(ack_path, 0o600)
                os.mkfifo(release_path, 0o600)
                ack = os.open(ack_path, os.O_RDWR | os.O_NONBLOCK)
                release = os.open(release_path, os.O_RDWR | os.O_NONBLOCK)
                process = self.start("""import os,sys
if sys.argv[1]=='signin': print('fixture-session')
elif sys.argv[1]=='read':
    if sys.argv[-1].endswith('/slow'):
        with open(os.environ['HOME']+'/ack','wb',buffering=0) as f: f.write(b'R')
        with open(os.environ['HOME']+'/release','rb',buffering=0) as f: f.read(1)
    sys.stdout.write('fixture-value')
""")
                output = self.root / "cancelled"
                client = subprocess.Popen([sys.executable, "-B", str(SCRIPTS / "opq"), "--directory",
                    str(self.directory), "read", "op://fixture/item/slow", "--output", str(output)],
                    env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    self.assertTrue(select.select([ack], [], [], 5)[0], "op did not acknowledge the slow read")
                    self.assertEqual(os.read(ack, 1), b"R")
                    client.send_signal(signum)
                    stdout, stderr = client.communicate(timeout=5)
                    self.assertEqual(client.returncode, 128 + signum)
                    self.assertEqual(stdout, b"")
                    self.assertEqual(stderr.splitlines()[0], b"op-client: request=cancelled")
                    self.assertFalse(output.exists())
                    self.assertEqual(sorted(p.name for p in self.directory.iterdir()), ["lock", "requests"])
                    os.write(release, b"R")
                    result = self.run_tool("opq", "--directory", self.directory, "read",
                                           "op://fixture/item/password", "--output", self.root / "normal")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((self.root / "normal").read_bytes(), b"fixture-value")
                    (self.root / "normal").unlink()
                finally:
                    if client.poll() is None:
                        client.kill()
                        client.communicate(timeout=5)
                    process.send_signal(signum)
                    _, stderr = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 0, stderr)
                    os.close(ack)
                    os.close(release)
                    ack_path.unlink()
                    release_path.unlink()

    def test_fifo_creation_capabilities(self):
        module = load("lib/op_fifo.py")
        root = self.root / "fifo-world"
        root.mkdir(mode=0o700)
        directory = module.open_directory(root)
        real_mkfifo = module.os.mkfifo
        try:
            for supported in (True, False):
                with self.subTest(dir_fd=supported):
                    def mkfifo(path, mode, **kwargs):
                        if not supported and "dir_fd" in kwargs:
                            raise NotImplementedError("fixture has no mkfifoat")
                        # A capable fixture delegates through the absolute path
                        # even on a host whose own Python lacks mkfifoat.
                        real_mkfifo(root / path if kwargs else path, mode)

                    with patch.object(module.os, "mkfifo", mkfifo), \
                         patch.object(module.os, "supports_dir_fd", {mkfifo} if supported else set()):
                        try:
                            module.create_fifo(directory, root, "reply")
                        except NotImplementedError:
                            self.fail("FIFO creation used an unavailable capability")
                        stream = module.open_fifo(directory, "reply", os.O_RDWR)
                        os.close(stream)
                        with self.assertRaises(FileExistsError):
                            module.create_fifo(directory, root, "reply")
                    (root / "reply").unlink()
        finally:
            os.close(directory)

    def test_noninteractive_deadline(self):
        result = run_case(Path(__file__), "--deadline-worker", dict(os.environ), timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"deadline": True, "reaped": True, "child_status": -signal.SIGTERM})

    def test_read_failure_and_existing_output(self):
        self.start()
        output = self.root / "secret"
        output.write_bytes(b"existing")
        result = self.run_tool("opq", "--directory", self.directory, "read", "op://fixture/item/password", "--output", output)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_bytes(), b"existing")
        output.unlink()
        result = self.run_tool("opq", "--directory", self.directory, "read", "op://fixture/item/fail", "--output", output)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()), ["lock", "requests"])

    def test_private_transport(self):
        module = load("lib/op_fifo.py")
        directory = self.root / "transport"
        directory.mkdir(mode=0o700)
        fd = module.open_directory(directory)
        try:
            path = directory / "reply"
            for form in ("regular", "public-fifo", "symlink"):
                with self.subTest(form=form):
                    if form == "regular":
                        path.write_text("keep")
                        path.chmod(0o600)
                    elif form == "public-fifo":
                        os.mkfifo(path, 0o644)
                    else:
                        path.symlink_to(self.root / "outside")
                    with self.assertRaises((module.Refusal, OSError)):
                        module.open_fifo(fd, "reply", os.O_RDWR)
                    path.unlink()
            for request in ({"reply": "../outside", "verb": "read", "reference": "op://fixture/item/password"},
                            {"reply": "bad.reply"}, [], "not-json"):
                module.answer(fd, json.dumps(request).encode(), "not-installed", {}, "session")
            self.assertFalse((self.root / "outside").exists())
        finally:
            os.close(fd)
        directory.chmod(0o755)
        with self.assertRaises(module.Refusal):
            module.open_directory(directory)

    def test_transport_owner_and_symlinks(self):
        module = load("lib/op_fifo.py")
        directory = self.root / "private"
        directory.mkdir(mode=0o700)
        link = self.root / "link"
        link.symlink_to(directory, target_is_directory=True)
        with self.assertRaises(OSError):
            module.open_directory(link)
        fd = module.open_directory(directory)
        try:
            os.mkfifo(directory / "reply", 0o600)
            actual_stat = os.fstat

            def foreign(handle):
                info = actual_stat(handle)
                return SimpleNamespace(st_uid=info.st_uid + 1, st_mode=info.st_mode)

            with patch.object(module.os, "fstat", side_effect=foreign):
                with self.assertRaises(module.Refusal):
                    module.open_directory(directory)
                with self.assertRaises(module.Refusal):
                    module.open_fifo(fd, "reply", os.O_RDWR)
        finally:
            os.close(fd)

    def test_request_contract(self):
        module = load("lib/op_fifo.py")
        directory = self.root / "requests"
        directory.mkdir(mode=0o700)
        fd = module.open_directory(directory)
        op = self.executable("read-fixture", "import sys\nsys.stdout.write('fixture-value')\n")
        reply = "0" * 32 + ".reply"
        os.mkfifo(directory / reply, 0o600)
        stream = module.open_fifo(fd, reply, os.O_RDWR)
        script = self.script("private-script")
        try:
            # The unknown verb carries every field a known verb would accept. Linux is
            # patched in so the shape checks behind macOS's platform refusal run everywhere.
            for request in ({"verb": "write", "reference": "op://fixture/item/password", "args": ["whoami"], "path": str(script)},
                            {"verb": "read", "reference": "https://example.org"},
                            {"verb": "op", "args": []}, {"verb": "op", "args": "whoami"}, {"verb": "op", "args": ["whoami", 1]},
                            {"verb": "script", "path": "relative-script"}):
                with self.subTest(request=request), patch.object(module, "sys", SimpleNamespace(platform="linux")):
                    module.answer(fd, json.dumps(dict(request, reply=reply)).encode(), str(op), {}, "session")
                    self.assertEqual(module.receive(stream, module.time.monotonic() + 5)["status"], "invalid-request")
            self.assertFalse((self.root / "ran").exists())
            # A request that bypasses opq meets the broker's own platform rule.
            with patch.object(module, "sys", SimpleNamespace(platform="darwin")):
                for request in ({"verb": "op", "args": ["whoami"]}, {"verb": "script", "path": str(script)}):
                    with self.subTest(platform="darwin", verb=request["verb"]):
                        module.answer(fd, json.dumps(dict(request, reply=reply)).encode(), str(op), {}, "session")
                        self.assertEqual(module.receive(stream, module.time.monotonic() + 5)["status"], "platform-unsupported")
            self.assertFalse((self.root / "ran").exists())
            outside = self.root / "outside"
            os.mkfifo(outside, 0o600)
            outside_fd = os.open(outside, os.O_RDWR | os.O_NONBLOCK)
            try:
                module.answer(fd, json.dumps({"reply": "../outside", "verb": "read", "reference": "op://fixture/item/password"}).encode(), str(op), {}, "session")
                self.assertFalse(select.select([outside_fd], [], [], 0)[0])
            finally:
                os.close(outside_fd)
        finally:
            os.close(stream)
            os.close(fd)

    def script(self, name, body="", mode=0o700):
        # Every script marks HOME/ran, so a refusal shows that nothing ran.
        path = self.root / name
        path.write_text("#!/bin/sh\n: > \"$HOME/ran\"\n" + body)
        path.chmod(mode)
        return path

    def opq(self, *words, output, directory=True):
        location = ("--directory", self.directory) if directory else ()
        return self.run_tool("opq", *location, "--output", output, *words)

    def record(self, result, output):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        content = json.loads(output.read_bytes())
        output.unlink()
        return content["exit"], base64.b64decode(content["stdout"])

    def refused(self, result, output, key):
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stderr.splitlines()[0], key)
        self.assertFalse(output.exists())

    @unittest.skipUnless(sys.platform == "linux", "op requests are Linux only")
    def test_op_request_record(self):
        self.start()
        output = self.root / "record"
        for words, status in ((["vault", "list"], 0), (["item", "get", "Fixture Item", "--fields", "password", "--reveal"], 0),
                              (["item", "edit", "fixture", "exit-two"], 2)):
            with self.subTest(words=words):
                self.assertEqual(self.record(self.opq("op", "--", *words, output=output), output),
                                 (status, (" ".join(words) + "\n").encode()))
        calls = self.calls()
        self.assertEqual([call["verb"] for call in calls], ["signin", "whoami", "vault", "item", "item"])
        for call in calls[1:]:
            self.assertEqual((call["session"], call["biometric"], call["account"]), ("fixture-session", "false", "fixture-account"))
        output.write_bytes(b"existing")
        self.assertEqual(self.opq("op", "--", "vault", "list", output=output).returncode, 2)
        self.assertEqual(output.read_bytes(), b"existing")
        output.unlink()
        try:
            oversized = self.opq("op", "--", "item", "create", "x" * 5000, output=output)
        except subprocess.TimeoutExpired:
            self.fail("an oversized request reached the broker")
        self.refused(oversized, output, b"op-client: request=too-large")
        self.assertEqual(len(self.calls()), 5)

    @unittest.skipUnless(sys.platform == "linux", "@SCRIPT requests are Linux only")
    def test_script_request(self):
        self.start()
        output = self.root / "record"
        script = self.script("private-script", 'printf "%s %s" "$OP_SESSION" "$OP_ACCOUNT"\nexit 3\n')
        self.assertEqual(self.record(self.opq("@" + str(script), output=output), output), (3, b"fixture-session fixture-account"))
        (self.root / "ran").unlink()
        link = self.root / "link-script"
        link.symlink_to(script)
        forms = [(self.script(oct(mode) + "-script", mode=mode), oct(mode)) for mode in (0o755, 0o750, 0o600)]
        for path, form, key in [*((path, form, b"op-client: script=private-owner-required") for path, form in forms),
                                (link, "symlink", b"op-client: script=private-owner-required"),
                                (self.root / "missing-script", "missing", b"op-client: script=not-found")]:
            with self.subTest(form=form):
                self.refused(self.opq("@" + str(path), output=output), output, key)
                self.assertFalse((self.root / "ran").exists())
        self.refused(self.opq("@relative-script", output=output), output, b"op-client: path=absolute-required")

    @unittest.skipUnless(sys.platform == "linux", "the no-argument broker is Linux only")
    def test_service_form(self):
        self.env.update(JARVIS_OP_DIRECTORY=str(self.root / "broker"), OP_ACCOUNT="service-account", OP_SESSION="service-session")
        output = self.root / "record"
        for run in ("first", "restarted"):
            with self.subTest(run=run):
                process = self.start(args=[], terminal=False)
                for words in (["vault", "list"], ["item", "get", run]):
                    self.assertEqual(self.record(self.opq("op", "--", *words, output=output, directory=False), output)[0], 0)
                process.kill()
                process.communicate(timeout=10)
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()), ["lock", "requests"])
        calls = self.calls()
        self.assertEqual([call["verb"] for call in calls], ["whoami", "vault", "item"] * 2)
        self.assertTrue(all((call["session"], call["account"]) == ("service-session", "service-account") for call in calls))
        for missing, key in (("OP_SESSION", b"op-broker: session=OP_SESSION-required"),
                             ("JARVIS_OP_DIRECTORY", b"op-broker: setting=JARVIS_OP_DIRECTORY")):
            with self.subTest(missing=missing):
                env = {name: value for name, value in self.env.items() if name != missing}
                result = subprocess.run([sys.executable, "-B", str(SCRIPTS / "op-broker")], env=env,
                                        stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stderr.splitlines()[0], key)
        self.assertEqual(len(self.calls()), 6)

    @unittest.skipUnless(sys.platform == "linux", "a reused directory is Linux only")
    def test_directory_states(self):
        self.executable("op", OP)
        self.env["OP_SESSION"] = "fixture-session"
        directory = self.root / "broker"
        reply = "0" * 32 + ".reply"

        def existing(entries, mode=0o700):
            def prepare():
                directory.mkdir()
                directory.chmod(mode)
                for name, kind in entries.items():
                    if kind == stat.S_IFIFO:
                        os.mkfifo(directory / name, 0o600)
                    else:
                        (directory / name).write_text("keep")
                        (directory / name).chmod(0o600)
            return prepare

        def snapshot():
            if not directory.exists():
                return None
            return {path.name: (stat.S_IFMT(path.lstat().st_mode), path.read_text() if path.is_file() else None)
                    for path in directory.iterdir()}

        def running():
            return self.start(args=["--directory", str(directory)], terminal=False)

        def refusal():
            process = subprocess.Popen([sys.executable, "-B", str(SCRIPTS / "op-broker"), "--directory", str(directory)],
                                       env=self.env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                _, stderr = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=10)
                self.fail("the broker served a directory it must refuse")
            return process.returncode, stderr

        # Every state the broker's directory can be in when a broker starts over it. A
        # refusal leaves every entry as it was and makes no op call.
        rows = (
            ("absent", lambda: None, None, None),
            ("leftover", existing({"lock": stat.S_IFREG, "requests": stat.S_IFIFO, reply: stat.S_IFIFO}), None,
             {reply: (stat.S_IFIFO, None)}),
            ("foreign-entry", existing({"lock": stat.S_IFREG, "notes": stat.S_IFREG}), b"op-broker: directory=foreign", None),
            ("foreign-requests", existing({"requests": stat.S_IFREG}), b"op-broker: directory=foreign", None),
            ("foreign-reply", existing({reply: stat.S_IFREG}), b"op-broker: directory=foreign", None),
            ("public", existing({}, mode=0o755), b"op-broker: directory=private-owner-required", None),
            ("busy", running, b"op-broker: directory=busy", None),
        )
        for state, prepare, key, after in rows:
            with self.subTest(state=state):
                held = prepare()
                try:
                    before, calls = snapshot(), len(self.calls()) if self.log.exists() else 0
                    if key is None:
                        process = running()
                        process.terminate()
                        _, stderr = process.communicate(timeout=10)
                        self.assertEqual(process.returncode, 0, stderr)
                        self.assertEqual(snapshot(), after)
                    else:
                        status, stderr = refusal()
                        self.assertEqual(status, 2, stderr)
                        self.assertEqual(stderr.splitlines()[0], key)
                        self.assertEqual(snapshot(), before)
                        self.assertEqual(len(self.calls()) if self.log.exists() else 0, calls)
                finally:
                    if held is not None:
                        held.terminate()
                        held.communicate(timeout=10)
                    if directory.exists():
                        directory.chmod(0o700)
                        shutil.rmtree(directory)

    def test_broker_platform(self):
        module = load("lib/op_fifo.py")
        configured, reused = self.root / "broker", self.root / "existing"
        reused.mkdir(mode=0o700)
        # Each condition that makes a broker Linux only, met on macOS: nothing is created and no session starts.
        for form, argv, env, key in (("configured-directory", ["op-broker"], {"JARVIS_OP_DIRECTORY": str(configured)},
                                      "platform=unsupported"),
                                     ("reused-directory", ["op-broker", "--directory", str(reused)], {}, "directory=exists")):
            with self.subTest(form=form):
                with patch.object(module, "sys", SimpleNamespace(platform="darwin")), \
                     patch.object(sys, "argv", argv), patch.dict(os.environ, env), \
                     patch.object(module.shutil, "which", return_value=str(self.root / "op")), \
                     patch.object(module, "session", side_effect=module.Refusal("session=reached")), \
                     redirect_stderr(io.StringIO()) as stderr:
                    with self.assertRaises(SystemExit) as refused:
                        module.main("broker")
                self.assertEqual((refused.exception.code, stderr.getvalue().splitlines()[0]), (2, "op-broker: " + key))
                self.assertFalse(configured.exists())
                self.assertEqual(list(reused.iterdir()), [])

    def test_keep_session(self):
        module = load("lib/op_fifo.py")
        # Every way op whoami can end, and the line the broker's journal carries for it.
        rows = (("renewed", subprocess.CompletedProcess([], 0, b""), ""),
                ("unreachable", subprocess.CompletedProcess([], 1, b""), "op-broker: keepalive=failed exit=1\n"),
                ("not-run", FileNotFoundError("op"), "op-broker: keepalive=failed\n"),
                ("deadline", subprocess.TimeoutExpired(["op", "whoami"], 30), "op-broker: keepalive=failed\n"))
        for state, outcome, diagnostic in rows:
            with self.subTest(state=state):
                effect = outcome if isinstance(outcome, BaseException) else (lambda *_: outcome)
                with patch.object(module, "call_op", side_effect=effect) as call, redirect_stderr(io.StringIO()) as stderr:
                    renewed = module.keep_session("op", {}, "session")
                self.assertEqual((renewed, stderr.getvalue()), (state == "renewed", diagnostic))
                call.assert_called_once_with(["op", "whoami"], {})

    def test_session_routes(self):
        # Records each call; a vault list also acknowledges on HOME/ack, so the renewal is observed, not slept for.
        # A vault list fails when HOME/expired existed as it started, as an app lock makes it fail.
        body = """import os,sys,json
home=os.environ['HOME']
expired=os.path.exists(home+'/expired')
with open(home+'/calls','a') as f:
    f.write(json.dumps({'verb':sys.argv[1], 'session':os.environ.get('OP_SESSION'), 'biometric':os.environ.get('OP_BIOMETRIC_UNLOCK_ENABLED')})+'\\n')
if sys.argv[1:3]==['vault','list']:
    with open(home+'/ack','wb',buffering=0) as f: f.write(b'V')
    if expired: sys.exit(1)
elif sys.argv[1]=='read': sys.stdout.write('fixture-value')
"""
        ack_path = self.root / "ack"
        os.mkfifo(ack_path, 0o600)
        ack = os.open(ack_path, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, ack)
        self.env["JARVIS_OP_KEEPALIVE_SECS"] = "1"
        # A broker without a terminal, with each value of JARVIS_OP_APP_INTEGRATION, and with neither input.
        # OP_SESSION alone is the service tests' route.
        rows = (("app-integration", {"JARVIS_OP_APP_INTEGRATION": "1"}, None),
                ("both", {"JARVIS_OP_APP_INTEGRATION": "1", "OP_SESSION": "fixture-session"},
                 b"op-broker: session=route-conflict"),
                ("neither", {}, b"op-broker: session=OP_SESSION-required"),
                ("empty-setting", {"JARVIS_OP_APP_INTEGRATION": ""}, b"op-broker: session=OP_SESSION-required"),
                ("unknown-setting", {"JARVIS_OP_APP_INTEGRATION": "yes"}, b"op-broker: setting=JARVIS_OP_APP_INTEGRATION"))
        base = dict(self.env)
        for route, settings, key in rows:
            with self.subTest(route=route):
                self.env = dict(base, **settings)
                self.log.unlink(missing_ok=True)
                if key is not None:
                    self.executable("op", body)
                    process = subprocess.Popen([sys.executable, "-B", str(SCRIPTS / "op-broker"), "--directory",
                                                str(self.root / "broker")], env=self.env, stdin=subprocess.DEVNULL,
                                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    try:
                        _, stderr = process.communicate(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate(timeout=10)
                        self.fail("the broker served a route it must refuse")
                    self.assertEqual(process.returncode, 2, stderr)
                    self.assertEqual(stderr.splitlines()[0], key)
                    self.assertFalse(self.log.exists())
                    continue
                process = self.start(body, args=["--directory", str(self.root / "broker")], terminal=False)

                def read():
                    output = self.root / "value"
                    result = self.run_tool("opq", "--directory", self.directory, "read", "op://fixture/item/password",
                                           "--output", output)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(output.read_bytes(), b"fixture-value")
                    output.unlink()

                def renewal(seconds):
                    return bool(select.select([ack], [], [], seconds)[0]) and os.read(ack, 1) == b"V"

                read()
                self.assertTrue(renewal(10), "keepalive did not renew the app approval")
                # A failed renewal disarms the keepalive, so a locked app raises no prompt with no request pending.
                (self.root / "expired").touch()
                self.assertTrue(renewal(10), "keepalive did not renew after a success")
                self.assertTrue(select.select([process.stderr], [], [], 10)[0], "keepalive did not meet the failure")
                self.assertEqual(process.stderr.readline(), b"op-broker: keepalive=failed exit=1\n")
                # That vault list has exited; drop any acknowledgement a slow test left behind it.
                try:
                    os.read(ack, 4096)
                except BlockingIOError:
                    pass
                self.assertFalse(renewal(2.5), "keepalive renewed after a failed renewal")
                (self.root / "expired").unlink()
                # A caller's successful call arms it again.
                read()
                self.assertTrue(renewal(10), "a successful call did not arm the keepalive again")
                process.terminate()
                _, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stderr)
                calls = self.calls()
                self.assertEqual({call["verb"] for call in calls}, {"read", "vault"})
                for call in calls:
                    self.assertEqual((call["session"], call["biometric"]), (None, "true"))

    @unittest.skipUnless(sys.platform == "linux", "op requests are Linux only")
    def test_keepalive(self):
        # A timer test: it waits real keepalive intervals of one second.
        ack_path = self.root / "ack"
        os.mkfifo(ack_path, 0o600)
        ack = os.open(ack_path, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, ack)

        def whoami(seconds):
            return bool(select.select([ack], [], [], seconds)[0]) and os.read(ack, 1) == b"W"

        self.env["OP_SESSION"] = "fixture-session"
        output = self.root / "record"
        # Without the setting, a broker never renews, even after a successful call.
        process = self.start(terminal=False)
        self.assertTrue(whoami(5), "startup whoami")
        self.assertEqual(self.record(self.opq("op", "--", "vault", "list", output=output), output)[0], 0)
        self.assertFalse(whoami(2.5), "keepalive ran without JARVIS_OP_KEEPALIVE_SECS")
        process.terminate()
        _, stderr = process.communicate(timeout=10)
        self.assertEqual((process.returncode, stderr), (0, b""))
        self.env["JARVIS_OP_KEEPALIVE_SECS"] = "1"
        process = self.start(terminal=False)
        self.assertTrue(whoami(5), "startup whoami")
        self.assertFalse(whoami(2.5), "keepalive ran before a successful call")
        self.assertEqual(self.record(self.opq("op", "--", "vault", "list", output=output), output)[0], 0)
        self.assertTrue(whoami(10), "keepalive did not renew the idle session")
        # A failed renewal, then a failed call, leave the keepalive armed until op answers again.
        (self.root / "expired").touch()
        failed = b"op-broker: keepalive=failed exit=1\n"
        self.assertTrue(select.select([process.stderr], [], [], 10)[0], "keepalive did not meet the failure")
        self.assertEqual(process.stderr.readline(), failed)
        self.assertEqual(self.record(self.opq("op", "--", "vault", "list", output=output), output)[0], 1)
        self.assertTrue(select.select([process.stderr], [], [], 10)[0], "keepalive stopped after a failed renewal")
        self.assertEqual(process.stderr.readline(), failed)
        # That whoami has exited, and the next starts one interval later, after the failure ends.
        try:
            os.read(ack, 4096)
        except BlockingIOError:
            pass
        (self.root / "expired").unlink()
        self.assertTrue(whoami(10), "keepalive did not renew after the failure ended")
        self.assertTrue(whoami(10), "keepalive did not continue after the failure ended")
        self.assertIsNone(process.poll())
        process.terminate()
        _, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(stderr, b"")

    @unittest.skipUnless(sys.platform == "linux", "caller work runs on Linux only")
    def test_work_process_group(self):
        module = load("lib/op_fifo.py")
        # The descendant holds the work's stdout and this test's pipe, and sleeps past the deadline.
        work = self.executable("work", "import os,signal,subprocess,sys,time\n"
            "subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'],pass_fds=(int(sys.argv[1]),))\n"
            "sys.stdout.write('out'); sys.stdout.flush()\n"
            "if sys.argv[2]=='stay': time.sleep(60)\n"
            "if sys.argv[2]=='signal': os.kill(os.getpid(), signal.SIGTERM)\n"
            "if sys.argv[2]=='kill': os.kill(os.getpid(), signal.SIGKILL)\n"
            "sys.exit(3)\n")
        # Each launch form: the work leads its session, or op_tty.py leads it on a terminal with the work as its child.
        rows = [(terminal, mode, deadline, expected) for terminal in (False, True)
                for mode, deadline, expected in (("exit", 10, (3, b"out")), ("signal", 10, (-signal.SIGTERM, b"out")),
                                                 ("kill", 10, (-signal.SIGKILL, b"out")), ("stay", 0.5, None))]
        for terminal, mode, deadline, expected in rows:
            with self.subTest(terminal=terminal, mode=mode):
                held, holder = os.pipe()
                try:
                    argv = [str(work), str(holder), mode]
                    with patch.object(module, "CALL_SECONDS", deadline), redirect_stderr(io.StringIO()):
                        if expected is None:
                            with self.assertRaises(subprocess.TimeoutExpired):
                                module.run_work(argv, self.env, (holder,), stderr=True, terminal=terminal)
                        else:
                            result = module.run_work(argv, self.env, (holder,), stderr=True, terminal=terminal)
                            self.assertEqual((result.returncode, result.stdout), expected)
                    os.close(holder)
                    holder = None
                    # End of file proves every process holding the pipe has ended.
                    self.assertTrue(select.select([held], [], [], 5)[0], "a descendant outlived the work")
                    self.assertEqual(os.read(held, 1), b"")
                finally:
                    os.close(held)
                    if holder is not None:
                        os.close(holder)


    @unittest.skipUnless(sys.platform == "linux", "op and @SCRIPT requests are Linux only")
    def test_call_terminal(self):
        # Records, for each call, what the 1Password app reads to name the caller in its approval prompt: whether
        # op leads its own session, whether the session has a terminal, and whether the leader's executable reads.
        body = """import json,os,sys
home=os.environ['HOME']
leader=os.getsid(0)
try:
    os.close(os.open('/dev/tty', os.O_RDWR)); terminal=True
except OSError: terminal=False
try:
    os.readlink('/proc/%d/exe' % leader); readable=True
except OSError: readable=False
with open(home+'/calls','a') as f:
    f.write(json.dumps({'verb':sys.argv[1], 'led':leader!=os.getpid(), 'terminal':terminal, 'leader_exe':readable})+'\\n')
if sys.argv[1:3]==['vault','list'] and os.path.exists(home+'/ack'):
    with open(home+'/ack','wb',buffering=0) as f: f.write(b'V')
if sys.argv[1]=='read': sys.stdout.write('fixture-value')
"""
        ack_path = self.root / "ack"
        os.mkfifo(ack_path, 0o600)
        ack = os.open(ack_path, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, ack)
        script = self.script("probe-script", 'op script-probe\n')
        output = self.root / "record"
        # The OP_SESSION route never asks the app: an op or @SCRIPT request leads a new session with no terminal.
        rows = (("app-integration", {"JARVIS_OP_APP_INTEGRATION": "1", "JARVIS_OP_KEEPALIVE_SECS": "1"},
                 {"read", "item", "script-probe", "vault"}, {"led": True, "terminal": True, "leader_exe": True}),
                ("session", {"OP_SESSION": "fixture-session"}, {"item", "script-probe"}, {"terminal": False}))
        base = dict(self.env)
        for route, settings, verbs, expected in rows:
            with self.subTest(route=route):
                self.env = dict(base, **settings)
                self.log.unlink(missing_ok=True)
                process = self.start(body, args=["--directory", str(self.root / "broker")], terminal=False, leader=True)
                result = self.run_tool("opq", "--directory", self.directory, "read", "op://fixture/item/password",
                                       "--output", output)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_bytes(), b"fixture-value")
                output.unlink()
                self.assertEqual(self.record(self.opq("op", "--", "item", "get", "fixture", output=output), output)[0], 0)
                self.assertEqual(self.record(self.opq("@" + str(script), output=output), output)[0], 0)
                if "vault" in verbs:
                    self.assertTrue(select.select([ack], [], [], 10)[0], "keepalive did not renew")
                process.terminate()
                _, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stderr)
                calls = [call for call in self.calls() if call["verb"] in verbs]
                self.assertEqual({call["verb"] for call in calls}, verbs)
                for call in calls:
                    self.assertEqual({key: call[key] for key in expected}, expected, call["verb"])

    @unittest.skipUnless(sys.platform == "linux", "op and @SCRIPT requests are Linux only")
    def test_failed_call_journal(self):
        module = load("lib/op_fifo.py")
        # Prints on stderr, then waits on its terminal, or with none forever: only the deadline ends it.
        stall = self.executable("stall", "import os,signal,sys\n"
            "sys.stderr.write('fixture-stderr\\n'); sys.stderr.flush()\n"
            "try: terminal=os.open('/dev/tty', os.O_RDONLY)\n"
            "except OSError: signal.pause()\n"
            "os.read(terminal, 1)\n")
        script = self.script("stall-script", 'exec "$HOME/bin/stall"\n')
        missing = self.root / "missing-op"
        directory = self.root / "requests"
        directory.mkdir(mode=0o700)
        fd = module.open_directory(directory)
        reply = "0" * 32 + ".reply"
        os.mkfifo(directory / reply, 0o600)
        stream = module.open_fifo(fd, reply, os.O_RDWR)
        deadline = ["op-broker: run=failed cause=deadline seconds=0.5"]
        spawn = ["op-broker: run=failed cause=spawn errno=ENOENT"]
        read = {"verb": "read", "reference": "op://fixture/item/password"}
        op_request = {"verb": "op", "args": ["vault", "list"]}
        # Each call a deadline or a failed start ends, under each launch form. Only the stderr of a call whose
        # arguments the broker chooses reaches the journal, and no reply carries stderr.
        rows = (("op-deadline", op_request, stall, "session", "run-failed", deadline),
                ("op-deadline-terminal", op_request, stall, "app-integration", "run-failed", deadline),
                ("read-deadline-terminal", read, stall, "app-integration", "read-failed",
                 deadline + ["op-broker: stderr=fixture-stderr"]),
                ("script-deadline-terminal", {"verb": "script", "path": str(script)}, stall, "app-integration",
                 "run-failed", deadline),
                ("op-spawn", op_request, missing, "session", "run-failed", spawn),
                ("op-spawn-terminal", op_request, missing, "app-integration", "run-failed", spawn),
                ("read-spawn-terminal", read, missing, "app-integration", "read-failed", spawn))
        try:
            for name, request, op, route, status, lines in rows:
                with self.subTest(row=name), patch.object(module, "CALL_SECONDS", 0.5), \
                     redirect_stderr(io.StringIO()) as journal:
                    module.answer(fd, json.dumps(dict(request, reply=reply)).encode(), str(op), self.env, route)
                    self.assertEqual(module.receive(stream, module.time.monotonic() + 5), {"status": status})
                    self.assertEqual(journal.getvalue().splitlines(), lines)
        finally:
            os.close(stream)
            os.close(fd)

def deadline_worker():
    world = World()
    world.setUp()
    module = load("lib/op_fifo.py")
    op = world.executable("op", "import signal\nprint('ready',flush=True)\nsignal.pause()\n")
    real_popen = subprocess.Popen
    owned = []

    def launch(*args, **kwargs):
        child = real_popen(*args, **kwargs)
        owned.append(child)
        if not select.select([child.stdout], [], [], 2)[0] or child.stdout.readline() != b"ready\n":
            raise AssertionError("owned op did not acknowledge readiness")
        return child

    deadline = False
    try:
        with patch.object(module.subprocess, "Popen", side_effect=launch), patch.object(module, "CALL_SECONDS", 0.02):
            try:
                module.call_op([str(op), "read"], world.env)
            except subprocess.TimeoutExpired:
                deadline = True
        print(json.dumps({"deadline": deadline, "reaped": owned[0].returncode is not None,
                          "child_status": owned[0].returncode}))
    finally:
        for child in owned:
            if child.poll() is None:
                child.kill()
                child.wait()
        world.doCleanups()


if __name__ == "__main__":
    if sys.argv[1:] == ["--deadline-worker"]:
        deadline_worker()
    else:
        unittest.main()
