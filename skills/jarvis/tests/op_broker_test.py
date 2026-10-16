"""Surface: op-broker and opq, approved session, private FIFOs and protected outputs."""
import base64
import json
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from desktop_world import SCRIPTS, World, load, run_case

# Records each call. Sign-in needs a terminal, as op's does. Record verbs print
# their arguments and exit 2 when asked, and every call fails once HOME/expired
# exists. HOME/ack, when present, takes one byte per whoami.
OP = """import os,sys,json
home=os.environ['HOME']
with open(home+'/calls','a') as f:
    f.write(json.dumps({'verb':sys.argv[1], 'session':os.environ.get('OP_SESSION'), 'biometric':os.environ.get('OP_BIOMETRIC_UNLOCK_ENABLED'), 'account':os.environ.get('OP_ACCOUNT')})+'\\n')
if sys.argv[1]=='whoami' and os.path.exists(home+'/ack'):
    with open(home+'/ack','wb',buffering=0) as f: f.write(b'W')
if os.path.exists(home+'/expired'): sys.exit(1)
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
    def start(self, body=None, args=None, terminal=True):
        self.executable("op", body or OP)
        self.directory = self.root / "broker"
        if args is None:
            args = ["--directory", str(self.directory), "--account", "fixture-account"]
        # Only a broker whose stdin is a terminal may start an interactive sign-in.
        if terminal:
            controller, stdin = os.openpty()
            self.addCleanup(os.close, controller)
        else:
            stdin = subprocess.DEVNULL
        process = subprocess.Popen([sys.executable, "-B", str(SCRIPTS / "op-broker"), *args],
            env=self.env, stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
        duplicate = self.run_tool("op-broker", "--directory", self.directory, input=b"")
        self.assertEqual(duplicate.returncode, 2)
        self.assertEqual(duplicate.stderr.splitlines()[0], b"op-broker: directory=busy")
        self.assertEqual([call["verb"] for call in self.calls()], ["signin", "whoami"])
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
                module.answer(fd, json.dumps(request).encode(), "not-installed", {})
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
            # The unknown verb carries every field a known verb would accept.
            for request in ({"verb": "write", "reference": "op://fixture/item/password", "args": ["whoami"], "path": str(script)},
                            {"verb": "read", "reference": "https://example.org"},
                            {"verb": "op", "args": []}, {"verb": "op", "args": "whoami"}, {"verb": "op", "args": ["whoami", 1]},
                            {"verb": "script", "path": "relative-script"}):
                if request["verb"] in ("op", "script") and sys.platform != "linux":
                    continue
                with self.subTest(request=request):
                    module.answer(fd, json.dumps(dict(request, reply=reply)).encode(), str(op), {})
                    self.assertEqual(module.receive(stream, module.time.monotonic() + 5)["status"], "invalid-request")
            self.assertFalse((self.root / "ran").exists())
            # A request that bypasses opq meets the broker's own platform rule.
            with patch.object(module, "sys", SimpleNamespace(platform="darwin")):
                for request in ({"verb": "op", "args": ["whoami"]}, {"verb": "script", "path": str(script)}):
                    with self.subTest(platform="darwin", verb=request["verb"]):
                        module.answer(fd, json.dumps(dict(request, reply=reply)).encode(), str(op), {})
                        self.assertEqual(module.receive(stream, module.time.monotonic() + 5)["status"], "platform-unsupported")
            self.assertFalse((self.root / "ran").exists())
            outside = self.root / "outside"
            os.mkfifo(outside, 0o600)
            outside_fd = os.open(outside, os.O_RDWR | os.O_NONBLOCK)
            try:
                module.answer(fd, json.dumps({"reply": "../outside", "verb": "read", "reference": "op://fixture/item/password"}).encode(), str(op), {})
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
        for path, form in [*forms, (link, "symlink"), (self.root / "missing-script", "missing")]:
            with self.subTest(form=form):
                self.refused(self.opq("@" + str(path), output=output), output, b"op-client: script=private-owner-required")
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

    def test_service_form_platform(self):
        module = load("lib/op_fifo.py")
        with patch.object(module, "sys", SimpleNamespace(platform="darwin")), \
             patch.object(sys, "argv", ["op-broker"]), \
             patch.dict(os.environ, JARVIS_OP_DIRECTORY=str(self.root / "broker")), \
             patch.object(module, "broker", side_effect=AssertionError("unsupported platform started a broker")):
            with self.assertRaises(SystemExit) as refused:
                module.main("broker")
        self.assertEqual(refused.exception.code, 2)

    @unittest.skipUnless(sys.platform == "linux", "op requests are Linux only")
    def test_keepalive(self):
        # A timer test: it waits real keepalive intervals of one second.
        ack_path = self.root / "ack"
        os.mkfifo(ack_path, 0o600)
        ack = os.open(ack_path, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, ack)

        def whoami(seconds):
            return bool(select.select([ack], [], [], seconds)[0]) and os.read(ack, 1) == b"W"

        self.env.update(JARVIS_OP_KEEPALIVE_SECS="1", OP_SESSION="fixture-session")
        process = self.start(terminal=False)
        self.assertTrue(whoami(5), "startup whoami")
        self.assertFalse(whoami(2.5), "keepalive ran before a successful call")
        output = self.root / "record"
        self.assertEqual(self.record(self.opq("op", "--", "vault", "list", output=output), output)[0], 0)
        self.assertTrue(whoami(10), "keepalive did not renew the idle session")
        (self.root / "expired").touch()
        self.assertTrue(whoami(10), "keepalive did not meet the expired session")
        self.assertTrue(select.select([process.stderr], [], [], 10)[0])
        self.assertEqual(process.stderr.readline(), b"op-broker: session=expired\n")
        self.assertEqual(self.record(self.opq("op", "--", "vault", "list", output=output), output)[0], 1)
        self.assertFalse(whoami(3.5), "keepalive continued after the session expired")
        self.assertIsNone(process.poll())
        process.terminate()
        _, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(stderr, b"")

    @unittest.skipUnless(sys.platform == "linux", "caller work runs on Linux only")
    def test_work_process_group(self):
        module = load("lib/op_fifo.py")
        # The descendant holds the work's stdout and this test's pipe, and sleeps past the deadline.
        work = self.executable("work", "import subprocess,sys,time\n"
            "subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'],pass_fds=(int(sys.argv[1]),))\n"
            "sys.stdout.write('out'); sys.stdout.flush()\n"
            "if sys.argv[2]=='stay': time.sleep(60)\n"
            "sys.exit(3)\n")
        for mode, deadline, expected in (("exit", 10, (3, b"out")), ("stay", 0.5, None)):
            with self.subTest(mode=mode):
                held, holder = os.pipe()
                try:
                    argv = [str(work), str(holder), mode]
                    with patch.object(module, "CALL_SECONDS", deadline):
                        if expected is None:
                            with self.assertRaises(subprocess.TimeoutExpired):
                                module.run_work(argv, self.env, (holder,))
                        else:
                            result = module.run_work(argv, self.env, (holder,))
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
