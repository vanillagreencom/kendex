"""Surface: op-broker and opq, approved session, private FIFOs and protected outputs."""
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


class Broker(World):
    def start(self, body=None):
        self.executable("op", body or """import os,sys,json
with open(os.environ['HOME']+'/calls','a') as f:
    f.write(json.dumps({'verb':sys.argv[1], 'session':os.environ.get('OP_SESSION'), 'biometric':os.environ.get('OP_BIOMETRIC_UNLOCK_ENABLED'), 'account':os.environ.get('OP_ACCOUNT')})+'\\n')
if sys.argv[1]=='signin': print('fixture-session')
elif sys.argv[1]=='read':
    reference=sys.argv[-1]
    if reference.endswith('/fail'): sys.exit(1)
    value=b'fixture-value\\n' if reference.endswith('/newline') else b'fixture-value'
    sys.stdout.buffer.write(value)
    if '--no-newline' not in sys.argv: sys.stdout.buffer.write(b'\\n')
""")
        self.directory = self.root / "broker"
        process = subprocess.Popen([sys.executable, "-B", str(SCRIPTS / "op-broker"),
            "--directory", str(self.directory), "--account", "fixture-account"],
            env=self.env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

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
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()), ["requests"])
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
                    self.assertEqual(sorted(p.name for p in self.directory.iterdir()), ["requests"])
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
        duplicate = self.run_tool("op-broker", "--directory", self.directory)
        self.assertEqual(duplicate.returncode, 2)
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
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()), ["requests"])

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
        try:
            for verb, reference in (("write", "op://fixture/item/password"), ("read", "https://example.org")):
                with self.subTest(verb=verb, reference=reference):
                    module.answer(fd, json.dumps({"reply": reply, "verb": verb, "reference": reference}).encode(), str(op), {})
                    self.assertEqual(module.receive(stream, module.time.monotonic() + 5)["status"], "invalid-request")
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
