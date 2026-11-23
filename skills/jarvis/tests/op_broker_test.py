"""Surface: op-broker and opq, approved session, private socket, allow list, request log and protected outputs."""
import base64
from contextlib import redirect_stderr
import io
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import signal
import socket
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


# What the default allow list grants: every reference and op argument list the end-to-end rows below request.
FIXTURE_GRANTS = {"read": ["op://fixture/item/" + field for field in ("password", "newline", "fail", "slow")],
                  "op": [["vault", "list"], ["item", "get", "Fixture Item", "--fields", "password", "--reveal"],
                         ["item", "edit", "fixture", "exit-two"], ["item", "get", "first"], ["item", "get", "restarted"],
                         ["item", "get", "fixture"]]}
# The caller an in-process answer sees. End-to-end rows on Linux record this test process as the controller of
# the home's controller record, so every client it starts is jarvis-session; macOS proves no caller, so any key
# serves there.
CALLER = "jarvis-fixture.service"
HOST_CALLER = "jarvis-session" if sys.platform == "linux" else None
PROTECTION = "unit" if sys.platform == "linux" else "listed-any-caller"
LOG_FIELDS = ["time", "protection", "caller", "verb", "reference", "outcome", "cause"]
# The FIFO broker a consumer's unit still runs after a refresh brings opq's socket transport: op-broker and
# lib/op_fifo.py as 7ae1357d3 last changed them on main. Delete it with op_fifo.fifo_exchange.
FIFO_BROKER = Path(__file__).resolve().parent / "fixtures" / "fifo_broker" / "op-broker"


def request_fields(line):
    """Parse one request log line, the record a session reads to check who read what."""
    prefix = "op-broker: request "
    if isinstance(line, bytes):
        line = line.decode()
    assert line.startswith(prefix), line
    pairs = [field.split("=", 1) for field in line[len(prefix):].rstrip("\n").split(" ")]
    assert [key for key, _ in pairs] == LOG_FIELDS, line
    fields = dict(pairs)
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", fields.pop("time")), line
    fields["reference"] = json.loads(fields["reference"])
    return fields


def start_ticks(pid):
    """The start of pid in clock ticks after boot, field 22 of /proc/PID/stat (proc(5)), as agent-runtime records it."""
    return int(Path("/proc/%d/stat" % pid).read_text().rpartition(")")[2].split()[19])


def logged(caller, verb, reference, outcome, cause, protection=PROTECTION):
    return {"protection": protection, "caller": caller or "unverified",
            "verb": verb, "reference": reference, "outcome": outcome, "cause": cause}


class Platform:
    """sys as op_fifo sees it on another platform; every other attribute reads the live sys, so its streams stay real."""

    def __init__(self, name):
        self.platform = name

    def __getattr__(self, name):
        return getattr(sys, name)


class Broker(World):
    def setUp(self):
        super().setUp()
        self.allowed = self.root / "allow.json"
        self.home = self.root / "home"
        self.home.mkdir()
        self.env.update(XDG_STATE_HOME=str(self.root / "state"), XDG_CONFIG_HOME=str(self.root / "config"),
                        XDG_DATA_HOME=str(self.root / "data"), XDG_CACHE_HOME=str(self.root / "cache"))
        # op-broker starts through its own #! line, as the unit's ExecStart= does, which finds python3 on PATH.
        (self.bin / "python3").symlink_to(sys.executable)
        # The home is its own repository, so its orch settings place its controller record wherever the scratch
        # stands.
        for words in (("init", "-q"), ("config", "gc.auto", "0"), ("config", "maintenance.auto", "false")):
            subprocess.run(["git", "-C", str(self.home), *words], check=True, capture_output=True,
                           env={"PATH": os.environ["PATH"], "HOME": str(self.root), "GIT_CONFIG_NOSYSTEM": "1"})
        self.fleet = self.root / "orch-state" / "workflow-state-oversee.json"
        self.settings = "[env]\nORCH_STATE_DIR = " + json.dumps(str(self.fleet.parent)) + "\n"
        (self.home / "kendex.settings.toml").write_text(self.settings)
        if sys.platform == "linux":
            # What the broker's controller read runs: the runtime wrappers under bash, which digest their sources
            # with find, sort, sha256sum, cut, wc and awk; git, which places the record; and ps, which reads an
            # lstart start. The runtimes' cache stays the caller's, whatever HOME is.
            for tool in ("bash", "find", "sort", "sha256sum", "cut", "wc", "awk", "git", "ps"):
                (self.bin / tool).symlink_to(shutil.which(tool))
            cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "kendex/agent-runtime"
            self.env["AGENT_RUNTIME_CACHE"] = os.environ.get("AGENT_RUNTIME_CACHE") or str(cache)

    def allow(self, grants, caller=None):
        """Write the allow list with one entry, for the caller end-to-end clients are unless caller names another."""
        self.callers({caller or HOST_CALLER or "jarvis-any.service": grants})

    def record_controller(self, controller):
        """Write the home's controller record, orch's fleet record, holding controller."""
        self.fleet.parent.mkdir(exist_ok=True)
        self.fleet.write_text(json.dumps({"controller": controller}))

    def own_controller(self, start=None):
        """A controller that is this test process, under its own start unless start names another."""
        return {"runtime": "tmux", "generation": 1, "harness": "claude", "harness_pid": os.getpid(),
                "harness_start": start or "ticks:%d" % start_ticks(os.getpid()), "seat": "jarvis"}

    def callers(self, callers):
        self.allowed.write_text(json.dumps({"callers": callers}))
        self.allowed.chmod(0o600)

    def start(self, body=None, args=None, terminal=True, leader=False, grants=FIXTURE_GRANTS, protection=PROTECTION,
              home=True, directory=None, launch=(str(SCRIPTS / "op-broker"),), controller=None):
        """Start a broker and wait for its readiness line; protection None is the FIFO broker's line, which names none.
        On Linux the home's controller is controller, otherwise this test process."""
        self.executable("op", body or OP)
        self.directory = directory or self.root / "broker"
        if grants is not None:
            self.allow(grants)
        if sys.platform == "linux":
            self.record_controller(controller or self.own_controller())
        if home:
            self.env["JARVIS_OP_HOME"] = str(self.home)
        else:
            self.env.pop("JARVIS_OP_HOME", None)
        if args is None:
            args = ["--directory", str(self.directory), "--account", "fixture-account", "--allow-list", str(self.allowed),
                    "--home", str(self.home)]
        # Only a broker whose stdin is a terminal may start an interactive sign-in. A leader broker starts its own
        # session, as the systemd unit does, so no terminal of the test's reaches its calls.
        if terminal:
            controller, stdin = os.openpty()
            self.addCleanup(os.close, controller)
        else:
            stdin = subprocess.DEVNULL
        process = subprocess.Popen([*launch, *args],
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
        self.assertEqual(process.stdout.readline(), b"op-broker: state=ready"
                         + (b"" if protection is None else b" protection=" + protection.encode()) + b"\n")
        return process

    def journal(self, process):
        """Return the broker's next stderr line that is not a request log line."""
        while True:
            self.assertTrue(select.select([process.stderr], [], [], 10)[0], "broker wrote no journal line")
            line = process.stderr.readline()
            if not line.startswith(b"op-broker: request "):
                return line

    def exchange(self, module, line, op, route="session", caller=CALLER, env=None):
        """Answer one request line in process over a socket pair; return the reply and the broker's stderr lines."""
        broker_end, client_end = socket.socketpair()
        try:
            client_end.sendall(line + b"\n")
            identity = (caller, None if caller else "caller=unverified")
            with patch.object(module, "peer_caller", return_value=identity), redirect_stderr(io.StringIO()) as stderr:
                module.answer(broker_end, op, {} if env is None else env, route, self.allowed, None)
            reply = json.loads(module.receive(client_end.fileno(), module.time.monotonic() + 5))
        finally:
            broker_end.close()
            client_end.close()
        return reply, stderr.getvalue().splitlines()

    def test_optional_op_refusal(self):
        result = self.run_tool("op-broker", "--directory", self.root / "missing", "--allow-list", self.allowed)
        self.assertEqual(result.returncode, 2)
        # Tool consumers use the stable dependency key, not the explanation.
        self.assertEqual(result.stderr.splitlines()[0], b"op-broker: optional-dependency=op")
        self.assertFalse((self.root / "missing").exists())

    def test_session_and_parallel_clients(self):
        # Each Python process that processes the user site directory names its program in HOME/user-site.
        user_site = Path(subprocess.run([sys.executable, "-c", "import site; print(site.getusersitepackages())"],
                                        env=self.env, capture_output=True, check=True, text=True).stdout.strip())
        user_site.mkdir(parents=True)
        (user_site / "usercustomize.py").write_text(
            "import os, sys\nwith open(os.environ['HOME'] + '/user-site', 'a') as f:\n"
            "    f.write(os.path.basename(sys.argv[0]) + '\\n')\n")
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
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()), ["lock", "requests.sock"])
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)
        process.terminate()
        _, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertFalse(self.directory.exists())
        # The clients run Python with the user site directory, and the broker, which holds the session, without it.
        programs = (self.root / "user-site").read_text().split()
        self.assertIn("opq", programs)
        self.assertNotIn("op-broker", programs)

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
                    self.assertEqual(sorted(p.name for p in self.directory.iterdir()), ["lock", "requests.sock"])
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
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()), ["lock", "requests.sock"])

    def test_private_transport(self):
        module = load("lib/op_fifo.py")
        directory = self.root / "transport"
        directory.mkdir(mode=0o700)
        fd = module.open_directory(directory)
        try:
            path = directory / "requests.sock"
            for form in ("regular", "public-socket", "symlink"):
                with self.subTest(form=form):
                    if form == "regular":
                        path.write_text("keep")
                        path.chmod(0o600)
                    elif form == "public-socket":
                        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stray:
                            stray.bind(str(path))
                        path.chmod(0o644)
                    else:
                        path.symlink_to(self.root / "outside")
                    with self.assertRaises(module.Refusal):
                        module.check_socket(fd)
                    path.unlink()
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
            listener = module.listen(fd, directory)
            listener.close()
            module.check_socket(fd)
            actual_fstat, actual_stat = os.fstat, os.stat

            def foreign(info):
                return SimpleNamespace(st_uid=info.st_uid + 1, st_mode=info.st_mode)

            with patch.object(module.os, "fstat", side_effect=lambda handle: foreign(actual_fstat(handle))), \
                 patch.object(module.os, "stat", side_effect=lambda *a, **k: foreign(actual_stat(*a, **k))):
                with self.assertRaises(module.Refusal):
                    module.open_directory(directory)
                with self.assertRaises(module.Refusal):
                    module.check_socket(fd)
        finally:
            os.close(fd)

    def test_request_contract(self):
        module = load("lib/op_fifo.py")
        op = self.executable("read-fixture", "import sys\nsys.stdout.write('fixture-value')\n")
        script = self.script("private-script")
        # Every request is listed, so only the shape checks can refuse it.
        self.allow({"read": ["op://fixture/item/password"], "op": [["whoami"]], "script": [str(script)]}, CALLER)
        # The unknown verb carries every field a known verb would accept. Linux is patched in so the
        # shape checks behind macOS's platform refusal run everywhere.
        rows = ((b'{"verb": "write", "reference": "op://fixture/item/password", "args": ["whoami"], "path": '
                 + json.dumps(str(script)).encode() + b'}', "invalid", None),
                (b'{"verb": "read", "reference": "https://example.org"}', "read", "https://example.org"),
                (b'{"verb": "op", "args": []}', "op", []), (b'{"verb": "op", "args": "whoami"}', "op", "whoami"),
                (b'{"verb": "op", "args": ["whoami", 1]}', "op", ["whoami", 1]),
                (b'{"verb": "script", "path": "relative-script"}', "script", "relative-script"),
                (b"[]", "invalid", None), (b"not-json", "invalid", None),
                # A verb no dict lookup accepts.
                (b'{"verb": []}', "invalid", None), (b'{"verb": {}}', "invalid", None),
                # A listed read padded past the longest line opq sends.
                (b'{"verb": "read", "reference": "op://fixture/item/password", "pad": "' + b"x" * 5000 + b'"}',
                 "invalid", None))
        for line, verb, reference in rows:
            with self.subTest(line=line[:60]), patch.object(module, "sys", Platform("linux")):
                reply, stderr = self.exchange(module, line, str(op))
                self.assertEqual(reply, {"status": "invalid-request"})
                self.assertEqual([request_fields(entry) for entry in stderr],
                                 [dict(logged(CALLER, verb, reference, "invalid-request", "request=invalid"),
                                       protection="unit")])
        self.assertFalse((self.root / "ran").exists())
        # A request that bypasses opq meets the broker's own platform rule.
        with patch.object(module, "sys", Platform("darwin")):
            for request in ({"verb": "op", "args": ["whoami"]}, {"verb": "script", "path": str(script)}):
                with self.subTest(platform="darwin", verb=request["verb"]):
                    reply, _ = self.exchange(module, json.dumps(request).encode(), str(op))
                    self.assertEqual(reply, {"status": "platform-unsupported"})
        self.assertFalse((self.root / "ran").exists())

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
        # The socket path is past Linux's 108-byte sun_path; broker and opq both name it through their descriptors.
        self.start(directory=self.root / ("d" * 200))
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
        self.refused(self.opq("op", "--", "item", "delete", "fixture", output=output), output, b"op-client: op=not-allowed")
        self.assertEqual(len(self.calls()), 5)

    @unittest.skipUnless(sys.platform == "linux", "@SCRIPT requests are Linux only")
    def test_script_request(self):
        output = self.root / "record"
        script = self.script("private-script", 'printf "%s %s" "$OP_SESSION" "$OP_ACCOUNT"\nexit 3\n')
        unlisted = self.script("unlisted-script")
        link = self.root / "link-script"
        forms = [(self.root / (oct(mode) + "-script"), mode) for mode in (0o755, 0o750, 0o600)]
        listed = [script, link, self.root / "missing-script", *(path for path, _ in forms)]
        self.start(grants=dict(FIXTURE_GRANTS, script=[str(path) for path in listed]))
        self.refused(self.opq("@" + str(unlisted), output=output), output, b"op-client: script=not-allowed")
        self.assertFalse((self.root / "ran").exists())
        self.assertEqual(self.record(self.opq("@" + str(script), output=output), output), (3, b"fixture-session fixture-account"))
        (self.root / "ran").unlink()
        link.symlink_to(script)
        forms = [(self.script(path.name, mode=mode), oct(mode)) for path, mode in forms]
        for path, form, key in [*((path, form, b"op-client: script=private-owner-required") for path, form in forms),
                                (link, "symlink", b"op-client: script=private-owner-required"),
                                (self.root / "missing-script", "missing", b"op-client: script=not-found")]:
            with self.subTest(form=form):
                self.refused(self.opq("@" + str(path), output=output), output, key)
                self.assertFalse((self.root / "ran").exists())
        self.refused(self.opq("@relative-script", output=output), output, b"op-client: path=absolute-required")

    @unittest.skipUnless(sys.platform == "linux", "the no-argument broker is Linux only")
    def test_service_form(self):
        self.env.update(JARVIS_OP_DIRECTORY=str(self.root / "broker"), JARVIS_OP_ALLOW_LIST=str(self.allowed),
                        OP_ACCOUNT="service-account", OP_SESSION="service-session")
        output = self.root / "record"
        for run in ("first", "restarted"):
            with self.subTest(run=run):
                process = self.start(args=[], terminal=False)
                for words in (["vault", "list"], ["item", "get", run]):
                    self.assertEqual(self.record(self.opq("op", "--", *words, output=output, directory=False), output)[0], 0)
                process.kill()
                process.communicate(timeout=10)
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()), ["lock", "requests.sock"])
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

        def existing(entries, mode=0o700):
            def prepare():
                directory.mkdir()
                directory.chmod(mode)
                for name, kind in entries.items():
                    if kind == stat.S_IFIFO:
                        os.mkfifo(directory / name, 0o600)
                    elif kind == stat.S_IFSOCK:
                        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as leftover:
                            leftover.bind(str(directory / name))
                        (directory / name).chmod(0o600)
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
            return self.start(args=["--directory", str(directory), "--allow-list", str(self.allowed)], terminal=False,
                              grants=None)

        def refusal():
            process = subprocess.Popen([sys.executable, "-B", str(SCRIPTS / "op-broker"), "--directory", str(directory),
                                        "--allow-list", str(self.allowed)],
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
            ("leftover", existing({"lock": stat.S_IFREG, "requests.sock": stat.S_IFSOCK}), None, None),
            ("foreign-entry", existing({"lock": stat.S_IFREG, "notes": stat.S_IFREG}), b"op-broker: directory=foreign", None),
            ("foreign-requests", existing({"requests.sock": stat.S_IFREG}), b"op-broker: directory=foreign", None),
            # A FIFO broker's crash leaves its request FIFO, and a killed client its reply FIFO: a restart removes them.
            ("fifo-broker", existing({"lock": stat.S_IFREG, "requests": stat.S_IFIFO, "0" * 32 + ".reply": stat.S_IFIFO}),
             None, None),
            ("fifo-reply", existing({"f" * 32 + ".reply": stat.S_IFIFO}), None, None),
            ("foreign-fifo-name", existing({"requests": stat.S_IFREG}), b"op-broker: directory=foreign", None),
            ("foreign-reply-name", existing({"F" * 32 + ".reply": stat.S_IFIFO}), b"op-broker: directory=foreign", None),
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
                                     ("reused-directory", ["op-broker", "--directory", str(reused), "--allow-list",
                                                           str(self.allowed)], {}, "directory=exists")):
            with self.subTest(form=form):
                with patch.object(module, "sys", Platform("darwin")), \
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
        module = load("lib/op_fifo.py")
        self.executable("op", OP)
        # Service configuration comes from these environment settings. Refusals must precede any op call or ready FIFO.
        rows = (("app-keepalive", {"JARVIS_OP_APP_INTEGRATION": "1", "JARVIS_OP_KEEPALIVE_SECS": "1"},
                 "keepalive=unsupported cause=per-terminal-authorization"),
                ("both", {"JARVIS_OP_APP_INTEGRATION": "1", "OP_SESSION": "fixture-session",
                          "JARVIS_OP_KEEPALIVE_SECS": "1"}, "session=route-conflict"),
                ("invalid-interval", {"JARVIS_OP_APP_INTEGRATION": "1", "JARVIS_OP_KEEPALIVE_SECS": "bad"},
                 "setting=JARVIS_OP_KEEPALIVE_SECS"),
                ("neither", {}, "session=OP_SESSION-required"),
                ("empty-setting", {"JARVIS_OP_APP_INTEGRATION": ""}, "session=OP_SESSION-required"),
                ("unknown-setting", {"JARVIS_OP_APP_INTEGRATION": "yes"}, "setting=JARVIS_OP_APP_INTEGRATION"))
        directory = self.root / "broker"
        for platform in ("linux", "darwin"):
            for route, settings, key in rows:
                with self.subTest(platform=platform, route=route), \
                     patch.object(module, "sys", Platform(platform)), \
                     patch.object(sys, "argv", ["op-broker", "--directory", str(directory), "--allow-list",
                                                str(self.allowed)]), \
                     patch.dict(os.environ, dict(self.env, **settings), clear=True), \
                     patch.object(module.os, "isatty", return_value=False), \
                     patch.object(module.select, "select", side_effect=AssertionError("broker entered request loop")), \
                     redirect_stderr(io.StringIO()) as stderr, patch.object(sys, "stdout", new_callable=io.StringIO) as stdout:
                    with self.assertRaises(SystemExit) as refused:
                        module.main("broker")
                    self.assertEqual((refused.exception.code, stderr.getvalue().splitlines()[0]), (2, "op-broker: " + key))
                    self.assertEqual(stdout.getvalue(), "")
                    self.assertFalse(self.log.exists())
                    self.assertFalse(directory.exists())

        # App calls without keepalive still use the native approval route. This fixture proves broker wiring, not approval.
        self.env["JARVIS_OP_APP_INTEGRATION"] = "1"
        process = self.start(terminal=False)
        output = self.root / "value"
        result = self.run_tool("opq", "--directory", self.directory, "read", "op://fixture/item/password",
                               "--output", output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_bytes(), b"fixture-value")
        self.assertEqual([(call["verb"], call["session"], call["biometric"]) for call in self.calls()],
                         [("read", None, "true")])
        process.terminate()
        _, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertFalse(self.directory.exists())

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
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual([request_fields(line)["outcome"] for line in stderr.splitlines()], ["ok"])
        self.env["JARVIS_OP_KEEPALIVE_SECS"] = "1"
        process = self.start(terminal=False)
        self.assertTrue(whoami(5), "startup whoami")
        self.assertFalse(whoami(2.5), "keepalive ran before a successful call")
        self.assertEqual(self.record(self.opq("op", "--", "vault", "list", output=output), output)[0], 0)
        self.assertTrue(whoami(10), "keepalive did not renew the idle session")
        # A failed renewal, then a failed call, leave the keepalive armed until op answers again.
        (self.root / "expired").touch()
        failed = b"op-broker: keepalive=failed exit=1\n"
        self.assertEqual(self.journal(process), failed, "keepalive did not meet the failure")
        self.assertEqual(self.record(self.opq("op", "--", "vault", "list", output=output), output)[0], 1)
        self.assertEqual(self.journal(process), failed, "keepalive stopped after a failed renewal")
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
        self.assertEqual([line for line in stderr.splitlines() if not line.startswith(b"op-broker: request ")], [])

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
if sys.argv[1]=='read': sys.stdout.write('fixture-value')
"""
        script = self.script("probe-script", 'op script-probe\n')
        output = self.root / "record"
        # The OP_SESSION route never asks the app: an op or @SCRIPT request leads a new session with no terminal.
        rows = (("app-integration", {"JARVIS_OP_APP_INTEGRATION": "1"},
                 {"read", "item", "script-probe"}, {"led": True, "terminal": True, "leader_exe": True}),
                ("session", {"OP_SESSION": "fixture-session"}, {"item", "script-probe"}, {"terminal": False}))
        base = dict(self.env)
        for route, settings, verbs, expected in rows:
            with self.subTest(route=route):
                self.env = dict(base, **settings)
                self.log.unlink(missing_ok=True)
                process = self.start(body, args=["--directory", str(self.root / "broker"), "--allow-list", str(self.allowed)],
                                     terminal=False, leader=True, grants=dict(FIXTURE_GRANTS, script=[str(script)]))
                result = self.run_tool("opq", "--directory", self.directory, "read", "op://fixture/item/password",
                                       "--output", output)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_bytes(), b"fixture-value")
                output.unlink()
                self.assertEqual(self.record(self.opq("op", "--", "item", "get", "fixture", output=output), output)[0], 0)
                self.assertEqual(self.record(self.opq("@" + str(script), output=output), output)[0], 0)
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
        self.allow({"read": ["op://fixture/item/password"], "op": [["vault", "list"]], "script": [str(script)]}, CALLER)
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
        for name, request, op, route, status, lines in rows:
            with self.subTest(row=name), patch.object(module, "CALL_SECONDS", 0.5):
                reply, stderr = self.exchange(module, json.dumps(request).encode(), str(op), route, env=self.env)
                self.assertEqual(reply, {"status": status})
                self.assertEqual(stderr[:-1], lines)
                self.assertEqual(request_fields(stderr[-1])["outcome"], status)

    def test_caller_identity(self):
        module = load("lib/op_fifo.py")
        manager = "0::/user.slice/user-1000.slice/user@1000.service"
        # A helper agent's scope beside the session's, its wrapper shell in its unit, the user manager and init.
        # Each process: parent, start ticks, cgroup text.
        tree = {30: (20, 900, "0::/agents.slice/agent-confine-20-1.scope\n"),
                20: (10, 250, "0::/agents.slice/agent-confine-20-1.scope\n"),
                10: (2, 200, manager + "/app.slice/jarvis-neon.service\n"),
                2: (1, 100, manager + "/init.scope\n"), 1: (0, 1, "0::/init.scope\n")}
        session = (20, 250)

        def wrapper(cgroup):
            """The tree with the wrapper shell, process 10, in cgroup."""
            return {**tree, 10: (2, 200, cgroup)}

        def proc(processes, change=None):
            """A /proc reader over processes; change, (name, pid, replacement), swaps a process once name is read."""
            processes = dict(processes)

            def read(name):
                pid, _, entry = name.partition("/")
                if int(pid) not in processes:
                    raise FileNotFoundError(name)
                parent, started, cgroup = processes[int(pid)]
                text = cgroup if entry == "cgroup" else "%s (a) b) S %d %s %d 0 0\n" % (
                    pid, parent, " ".join(["0"] * 17), started)
                if change is not None and name == change[0]:
                    processes[change[1]] = change[2]
                return text
            return read

        rows = (("helper-agent", 30, tree, None, None, "jarvis-neon.service"),
                ("session-descendant", 30, tree, session, None, "jarvis-session"),
                ("session-itself", 20, tree, session, None, "jarvis-session"),
                ("stale-record", 30, tree, (20, 251), None, "jarvis-neon.service"),
                ("record-elsewhere", 30, tree, (99, session[1]), None, "jarvis-neon.service"),
                ("peer-in-unit", 10, tree, None, None, "jarvis-neon.service"),
                ("hybrid-cgroup", 30, wrapper("12:pids:/user.slice\n" + manager + "/app.slice/jarvis-a.service\n"), None, None,
                 "jarvis-a.service"),
                ("no-unit", 30, wrapper(manager + "/app.slice/shell.scope\n"), None, None,
                 "caller=unverified"),
                ("unsafe-unit-name", 30, wrapper(manager + "/app.slice/evil name.service\n"),
                 None, None, "caller=unverified"),
                # The agent exits as its parent is read: init or a subreaper adopts its child.
                ("parent-changed", 30, tree, None, ("20/stat", 30, (2, 900, tree[30][2])), "caller=unverified"),
                # The peer exits as its parent is read and a new process takes its id.
                ("id-reused", 30, tree, None, ("20/stat", 30, (20, 901, tree[30][2])), "caller=unverified"),
                ("parent-gone", 30, {pid: entry for pid, entry in tree.items() if pid != 20}, None, None,
                 "caller=unverified"),
                ("peer-gone", 31, tree, None, None, "caller=unverified"))
        for name, pid, processes, recorded, change, expected in rows:
            with self.subTest(row=name):
                read = proc(processes, change)
                if expected.startswith("caller="):
                    with self.assertRaises(module.Refusal) as refused:
                        module.chain_caller(pid, recorded, read)
                    self.assertEqual(str(refused.exception), expected)
                else:
                    self.assertEqual(module.chain_caller(pid, recorded, read), expected)

    def test_record_read_past_its_bound_names_its_stderr(self):
        # A runtime wrapper that builds its program before it answers opens its stderr with setup-building; a
        # read the bound ends journals that line, never an empty cause.
        module = load("lib/op_fifo.py")
        building = self.executable("building", "import sys,time\n"
            "sys.stderr.write('agent-runtime: setup-building key=k run=/s\\n'); sys.stderr.flush(); time.sleep(30)\n")
        journal = io.StringIO()
        with patch.object(module, "RECORD_SECONDS", 1), redirect_stderr(journal):
            with self.assertRaises(module.Refusal) as refused:
                module.runtime_result("agent-runtime-controller-status", [str(building)], self.root)
        self.assertEqual(str(refused.exception), "record=unreadable")
        self.assertEqual(journal.getvalue().splitlines(), [
            "op-broker: record=unreadable operation=agent-runtime-controller-status cause=TimeoutExpired",
            "op-broker: stderr=agent-runtime: setup-building key=k run=/s"])

    def test_session_call_past_its_deadline_names_its_stderr(self):
        # jarvis-session's one deadline ends a wrapper still building its program; the call journals the stderr it
        # held under the operation's line and its TimeoutExpired stands, so the caller's record-unreadable stands.
        with patch.dict(os.environ, {"JARVIS_BASH": shutil.which("bash")}):
            module = load("lib/session.py")
        building = self.executable("building", "import sys,time\n"
            "sys.stderr.write('orch-runtime: setup-building key=k run=/s\\n'); sys.stderr.flush(); time.sleep(30)\n")
        session = SimpleNamespace(deadline=module.time.monotonic() + 1, home=str(self.root), env=dict(os.environ))
        journal = io.StringIO()
        with redirect_stderr(journal), self.assertRaises(subprocess.TimeoutExpired):
            module.Session.run(session, [str(building), "state", "path", "--fleet"], check=False)
        lines = journal.getvalue().splitlines()
        self.assertEqual(len(lines), 2, lines)
        self.assertRegex(lines[0], r"^jarvis-session: operation=\S+/building state path timeout=")
        self.assertEqual(lines[1], "orch-runtime: setup-building key=k run=/s")

    @unittest.skipUnless(sys.platform == "linux", "only Linux names a jarvis-session caller")
    def test_controller_record_states(self):
        module = load("lib/op_fifo.py")
        own = (os.getpid(), start_ticks(os.getpid()))
        lstart = subprocess.run(["ps", "-o", "lstart=", "-p", str(os.getpid())], check=True, text=True,
                                capture_output=True, env=dict(os.environ, LC_ALL="C", TZ="UTC")).stdout.split()
        settings = self.home / "kendex.settings.toml"
        # Each state of the controller record the broker reads, in the broker's environment; None names no
        # session caller.
        rows = (("live", lambda: self.record_controller(self.own_controller()), own),
                ("pid-text", lambda: self.record_controller(dict(self.own_controller(), harness_pid=str(own[0]))), own),
                ("no-record", lambda: None, None),
                ("no-controller", lambda: self.record_controller(None), None),
                # This process's id under another start: the recorded controller ended and its id was reused.
                ("ended", lambda: self.record_controller(self.own_controller("ticks:%d" % (own[1] + 1))), None),
                # agent-runtime reads this live, in a form the parent chain cannot compare.
                ("lstart-start", lambda: self.record_controller(self.own_controller("lstart:" + " ".join(lstart))),
                 "record=unreadable"),
                ("not-json", lambda: self.fleet.write_text("{"), "record=unreadable"),
                ("settings-unreadable", lambda: settings.write_text("[env"), "record=unreadable"))
        for name, prepare, expected in rows:
            with self.subTest(row=name):
                settings.write_text(self.settings)
                if self.fleet.exists():
                    self.fleet.unlink()
                prepare()
                with patch.dict(os.environ, self.env, clear=True), redirect_stderr(io.StringIO()):
                    if expected == "record=unreadable":
                        with self.assertRaises(module.Refusal) as refused:
                            module.session_process(self.home)
                        self.assertEqual(str(refused.exception), expected)
                    else:
                        self.assertEqual(module.session_process(self.home), expected)
        self.assertIsNone(module.session_process(None))
        with self.assertRaises(module.Refusal) as refused:
            module.session_process(self.root / "no-home")
        self.assertEqual(str(refused.exception), "home=unreadable")

    @unittest.skipUnless(sys.platform == "linux", "only Linux proves a caller")
    def test_tmux_session_caller(self):
        password = "op://fixture/item/password"
        tmux = shutil.which("tmux")
        label = "jarvis-broker-" + self.root.name

        def run(*args, timeout=10):
            return subprocess.run([tmux, "-L", label, "-f", os.devnull, *args], env=self.env, check=True, text=True,
                                  capture_output=True, timeout=timeout)

        # The Jarvis session as agent-runtime leaves it: its harness, the shell here, in a pane of its own tmux
        # server, which no service unit holds, recorded as the home's controller. tmux 3.8 prints a tab in this
        # format as "_", and none of these fields holds a blank. The shell saves no history into the scratch as it
        # ends after the test.
        created = run("new-session", "-d", "-s", "jarvis", "-n", "jarvis", "-e", "HISTFILE=", "-P", "-F",
                      "#{socket_path} #{pid} #{start_time} #{pane_id}", shutil.which("bash"), "--noprofile", "--norc")
        self.addCleanup(subprocess.run, [tmux, "-L", label, "kill-server"], env=self.env, capture_output=True,
                        timeout=10)
        server_socket, server, started, pane = created.stdout.split()
        harness = int(run("display-message", "-p", "-t", pane, "#{pane_pid}").stdout)
        process = self.start(grants={"read": [password]}, controller={
            "runtime": "tmux", "generation": 1, "server": server, "server_start": int(started),
            "server_socket": server_socket, "pane": pane, "harness": "claude", "harness_pid": harness,
            "harness_start": "ticks:%d" % start_ticks(harness), "seat": "jarvis"})
        output, status = self.root / "value", self.root / "status"

        def logged_request():
            self.assertTrue(select.select([process.stderr], [], [], 10)[0], "broker logged no request")
            return request_fields(process.stderr.readline())

        # A request from the harness's own command line is the session's, and its listed secret serves.
        command = shlex.join([sys.executable, "-B", str(SCRIPTS / "opq"), "--directory", str(self.directory),
                              "--output", str(output), "read", password])
        signal_done = shlex.join([tmux, "-L", label, "wait-for", "-S", "served"])
        run("send-keys", "-t", pane, command + "; echo $? > " + shlex.quote(str(status)) + "; " + signal_done, "Enter")
        run("wait-for", "served", timeout=30)
        self.assertEqual(logged_request(), logged("jarvis-session", "read", password, "ok", "listed"))
        self.assertEqual((status.read_text(), output.read_bytes()), ("0\n", b"fixture-value"))
        output.unlink()
        # This test process runs outside the session's process tree, and the list names no other caller.
        result = self.opq("read", password, output=output)
        self.refused(result, output, b"op-client: read=not-allowed")
        fields = logged_request()
        self.assertNotEqual(fields["caller"], "jarvis-session")
        cause = "caller=unverified" if fields["caller"] == "unverified" else "caller=unlisted"
        self.assertEqual(fields, logged(fields["caller"], "read", password, "not-allowed", cause))
        self.assertEqual([call["verb"] for call in self.calls()].count("read"), 1)

    def test_allow_list_states(self):
        module = load("lib/op_fifo.py")
        valid = {"callers": {"jarvis-neon.service": {"read": ["op://Vault/Neon/credential"]},
                             "jarvis-session": {"read": ["op://Vault/Session/token"],
                                                "op": [["item", "list", "--vault", "Vault"]]},
                             "jarvis-auditor-*.service": {"read": ["op://Vault/Audit/credential"]},
                             "jarvis-watch-loop.service": {"script": ["/home/user/bin/env-secret-sync"]}}}

        def written(document, mode=0o600):
            def prepare(path):
                path.write_text(document if isinstance(document, str) else json.dumps(document))
                path.chmod(mode)
                return path
            return prepare

        def entry(value):
            return written({"callers": {"jarvis-neon.service": value}})

        def linked(path):
            written(valid)(self.root / "target.json")
            path.symlink_to(self.root / "target.json")
            return path

        def directory(path):
            path.mkdir(mode=0o600)
            return path

        def under_file(path):
            written(valid)(path)
            return path / "allow.json"

        # Every state of the list file, and the cause each refusal logs; None reads the callers.
        rows = (("valid", written(valid), None), ("empty", written({"callers": {}}), None),
                ("missing", lambda path: path, "list=missing"),
                ("unreadable", under_file, "list=unreadable"),
                ("symlink", linked, "list=not-private"), ("public", written(valid, 0o644), "list=not-private"),
                ("directory", directory, "list=not-private"),
                ("not-json", written("{"), "list=invalid"), ("not-object", written([]), "list=invalid"),
                ("extra-key", written(dict(valid, version=1)), "list=invalid"),
                ("callers-list", written({"callers": []}), "list=invalid"),
                ("two-patterns", written({"callers": {"jarvis-*-*.service": {}}}), "list=invalid"),
                ("scope-key", written({"callers": {"agent-confine-*.scope": {}}}), "list=invalid"),
                ("session-pattern", written({"callers": {"jarvis-session*": {}}}), "list=invalid"),
                ("empty-key", written({"callers": {"": {}}}), "list=invalid"),
                ("unsafe-key", written({"callers": {"evil name.service": {}}}), "list=invalid"),
                ("unknown-verb", entry({"reads": []}), "list=invalid"),
                ("not-reference", entry({"read": ["https://example.org"]}), "list=invalid"),
                ("empty-args", entry({"op": [[]]}), "list=invalid"),
                ("flat-args", entry({"op": ["vault", "list"]}), "list=invalid"),
                ("relative-script", entry({"script": ["bin/sync"]}), "list=invalid"))
        for index, (name, prepare, key) in enumerate(rows):
            with self.subTest(row=name):
                path = prepare(self.root / ("list-%d" % index))
                if key is None:
                    self.assertEqual(module.read_allow_list(path), json.loads(path.read_text())["callers"])
                else:
                    with self.assertRaises(module.Refusal) as refused:
                        module.read_allow_list(path)
                    self.assertEqual(str(refused.exception), key)

    def test_caller_entries(self):
        module = load("lib/op_fifo.py")
        exact, pattern, other = {"read": ["op://v/exact/f"]}, {"read": ["op://v/pattern/f"]}, {"read": []}
        rows = (("exact-wins", {"jarvis-auditor-1.service": exact, "jarvis-auditor-*.service": pattern,
                                "*.service": other}, "jarvis-auditor-1.service", exact),
                ("one-pattern", {"jarvis-auditor-*.service": pattern, "jarvis-neon-*.service": other},
                 "jarvis-auditor-1.service", pattern),
                ("two-patterns", {"jarvis-auditor-*.service": pattern, "*-1.service": other}, "jarvis-auditor-1.service",
                 "caller=ambiguous"),
                ("session-exact", {"jarvis-session": exact, "*.service": other}, "jarvis-session", exact),
                ("session-unlisted", {"*.service": other}, "jarvis-session", "caller=unlisted"),
                ("empty-generated-part", {"jarvis-auditor-*.service": pattern}, "jarvis-auditor-.service",
                 "caller=unlisted"),
                ("unlisted", {"jarvis-neon.service": exact}, "jarvis-other.service", "caller=unlisted"))
        for name, callers, caller, expected in rows:
            with self.subTest(row=name):
                if isinstance(expected, dict):
                    self.assertIs(module.caller_entry(callers, caller), expected)
                else:
                    with self.assertRaises(module.Refusal) as refused:
                        module.caller_entry(callers, caller)
                    self.assertEqual(str(refused.exception), expected)

    @unittest.skipUnless(sys.platform == "linux", "verified callers and caller work are Linux only")
    def test_caller_requests(self):
        module = load("lib/op_fifo.py")
        self.executable("op", OP)
        op = str(self.bin / "op")
        script = self.script("listed-script")
        other = self.script("other-script")
        neon = "op://fixture/neon/password"
        session = "op://fixture/session item/password"
        self.callers({"jarvis-neon.service": {"read": [neon], "op": [["vault", "list"]], "script": [str(script)]},
                      "jarvis-session": {"read": [session]}})
        journal = []
        read = lambda reference: {"verb": "read", "reference": reference}
        # Each verb, for a listed caller, a pattern caller, an unlisted caller and an unverified one.
        rows = (("jarvis-neon.service", read(neon), "ok", "listed"),
                ("jarvis-neon.service", read(session), "not-allowed", "reference=unlisted"),
                ("jarvis-session", read(session), "ok", "listed"),
                ("jarvis-session", read(neon), "not-allowed", "reference=unlisted"),
                ("jarvis-other.service", read(neon), "not-allowed", "caller=unlisted"),
                (None, read(neon), "not-allowed", "caller=unverified"),
                ("jarvis-neon.service", {"verb": "op", "args": ["vault", "list"]}, "ok", "listed"),
                ("jarvis-neon.service", {"verb": "op", "args": ["vault", "list", "--format", "json"]}, "not-allowed",
                 "reference=unlisted"),
                ("jarvis-session", {"verb": "op", "args": ["vault", "list"]}, "not-allowed", "reference=unlisted"),
                (None, {"verb": "op", "args": ["vault", "list"]}, "not-allowed", "caller=unverified"),
                ("jarvis-neon.service", {"verb": "script", "path": str(other)}, "not-allowed", "reference=unlisted"),
                (None, {"verb": "script", "path": str(script)}, "not-allowed", "caller=unverified"),
                ("jarvis-neon.service", {"verb": "script", "path": str(script)}, "ok", "listed"))
        for caller, request, outcome, cause in rows:
            with self.subTest(caller=caller, request=request):
                calls = len(self.calls()) if self.log.exists() else 0
                ran = (self.root / "ran").exists()
                reply, stderr = self.exchange(module, json.dumps(request).encode(), op, caller=caller, env=self.env)
                journal.extend(stderr)
                self.assertEqual(reply["status"], outcome)
                subject = request[{"read": "reference", "op": "args", "script": "path"}[request["verb"]]]
                self.assertEqual([request_fields(line) for line in stderr],
                                 [dict(logged(caller, request["verb"], subject, outcome, cause), protection="unit")])
                if outcome == "not-allowed":
                    self.assertEqual(reply, {"status": "not-allowed"})
                    self.assertEqual((len(self.calls()) if self.log.exists() else 0, (self.root / "ran").exists()),
                                     (calls, ran))
        self.assertTrue((self.root / "ran").exists(), "the listed script did not run")
        self.assertNotIn("fixture-value", "\n".join(journal))
        # A list the broker cannot use refuses every caller and every verb.
        self.allowed.unlink()
        for caller, request, _, _ in rows:
            with self.subTest(list="missing", caller=caller, request=request):
                reply, stderr = self.exchange(module, json.dumps(request).encode(), op, caller=caller, env=self.env)
                self.assertEqual((reply, request_fields(stderr[-1])["cause"]), ({"status": "not-allowed"}, "list=missing"))

    def test_listed_any_caller(self):
        module = load("lib/op_fifo.py")
        self.executable("op", OP)
        self.allow({"read": ["op://fixture/item/password"]}, "jarvis-neon.service")
        # macOS proves no caller: a reference any entry lists serves, any other refuses, and so does a missing list.
        with patch.object(module, "sys", Platform("darwin")):
            for reference, outcome, cause in (("op://fixture/item/password", "ok", "listed"),
                                              ("op://fixture/item/newline", "not-allowed", "reference=unlisted")):
                with self.subTest(reference=reference):
                    reply, stderr = self.exchange(module, json.dumps({"verb": "read", "reference": reference}).encode(),
                                                  str(self.bin / "op"), env=self.env)
                    self.assertEqual(reply["status"], outcome)
                    self.assertEqual([request_fields(line) for line in stderr],
                                     [dict(logged(None, "read", reference, outcome, cause), protection="listed-any-caller")])
            self.allowed.unlink()
            reply, stderr = self.exchange(module, b'{"verb": "read", "reference": "op://fixture/item/password"}',
                                          str(self.bin / "op"), env=self.env)
            self.assertEqual((reply, request_fields(stderr[-1])["cause"]), ({"status": "not-allowed"}, "list=missing"))

    def test_listed_reads(self):
        password = "op://fixture/item/password"
        process = self.start(grants={"read": [password]})
        caller = HOST_CALLER
        output = self.root / "value"

        def request(reference):
            result = self.run_tool("opq", "--directory", self.directory, "read", reference, "--output", output)
            self.assertTrue(select.select([process.stderr], [], [], 10)[0], "broker logged no request")
            return result, request_fields(process.stderr.readline())

        # The verified caller's listed reference serves.
        result, fields = request(password)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_bytes(), b"fixture-value")
        output.unlink()
        self.assertEqual(fields, logged(caller, "read", password, "ok", "listed"))
        # A reference the caller's entry does not list never reaches op.
        result, fields = request("op://fixture/item/newline")
        self.refused(result, output, b"op-client: read=not-allowed")
        self.assertEqual(fields, logged(caller, "read", "op://fixture/item/newline", "not-allowed", "reference=unlisted"))
        # An entry for another caller serves this one only on macOS, which proves no caller.
        self.allow({"read": [password]}, "jarvis-other.service")
        result, fields = request(password)
        if sys.platform == "linux":
            self.refused(result, output, b"op-client: read=not-allowed")
            self.assertEqual(fields, logged(caller, "read", password, "not-allowed", "caller=unlisted"))
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
            output.unlink()
        self.allowed.unlink()
        result, fields = request(password)
        self.refused(result, output, b"op-client: read=not-allowed")
        self.assertEqual(fields, logged(caller, "read", password, "not-allowed", "list=missing"))
        self.assertEqual([call["verb"] for call in self.calls()].count("read"), 1 if sys.platform == "linux" else 2)
        process.terminate()
        _, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertNotIn(b"fixture-value", stderr)

    @unittest.skipUnless(sys.platform == "linux", "SO_PEERCRED is Linux only")
    def test_unverified_peer(self):
        module = load("lib/op_fifo.py")
        # The parent chain names a verified caller, so only the peer's user can refuse it.
        rows = (("same-user", 0, ("jarvis-session", None)), ("other-user", 1, (None, "caller=unverified")))
        for name, offset, expected in rows:
            ends = socket.socketpair()
            try:
                with self.subTest(row=name), patch.object(module, "chain_caller", return_value="jarvis-session"), \
                     patch.object(module.os, "getuid", return_value=os.getuid() + offset):
                    self.assertEqual(module.peer_caller(ends[0], None), expected)
            finally:
                for end in ends:
                    end.close()

    def test_list_settings(self):
        password = "op://fixture/item/password"
        output = self.root / "value"

        def request(process, *words):
            result = self.opq(*words, output=output)
            self.assertTrue(select.select([process.stderr], [], [], 10)[0], "broker logged no request")
            return result, request_fields(process.stderr.readline())

        def stop(process):
            process.terminate()
            _, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)

        # No list: every request serves, as before the list existed, and the log still names the caller.
        process = self.start(args=["--directory", str(self.root / "broker"), "--home", str(self.home)], grants=None,
                             protection="none")
        rows = [(["read", password], "read", password), (["read", "op://fixture/item/newline"], "read",
                                                           "op://fixture/item/newline")]
        if sys.platform == "linux":
            rows.append((["op", "--", "item", "delete", "fixture"], "op", ["item", "delete", "fixture"]))
        for words, verb, subject in rows:
            with self.subTest(list="unset", verb=verb, subject=subject):
                result, fields = request(process, *words)
                self.assertEqual(result.returncode, 0, result.stderr)
                output.unlink()
                self.assertEqual(fields, logged(HOST_CALLER, verb, subject, "ok", "list=unset", protection="none"))
        stop(process)
        if sys.platform != "linux":
            return
        # A list but no home: the recorded session process is no jarvis-session caller, so its entry serves nobody.
        process = self.start(args=["--directory", str(self.root / "broker"), "--allow-list", str(self.allowed)],
                             grants={"read": [password]}, home=False)
        result, fields = request(process, "read", password)
        self.refused(result, output, b"op-client: read=not-allowed")
        self.assertNotEqual(fields["caller"], "jarvis-session")
        cause = "caller=unverified" if fields["caller"] == "unverified" else "caller=unlisted"
        self.assertEqual(fields, logged(fields["caller"], "read", password, "not-allowed", cause))
        stop(process)

    def test_fifo_broker(self):
        # A refresh replaces opq but restarts no broker unit, so opq still reaches the FIFO broker the unit started.
        self.start(args=["--directory", str(self.root / "broker"), "--account", "fixture-account"], grants=None,
                   protection=None, launch=(sys.executable, "-B", str(FIFO_BROKER)))
        output = self.root / "value"
        result = self.opq("read", "op://fixture/item/password", output=output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_bytes(), b"fixture-value")
        output.unlink()
        if sys.platform == "linux":
            self.assertEqual(self.record(self.opq("op", "--", "vault", "list", output=output), output),
                             (0, b"vault list\n"))
        # Each client removes its reply FIFO, so a broker that restarts over the directory finds only the FIFO broker's.
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()), ["lock", "requests"])

    def test_socket_path_bound(self):
        module = load("lib/op_fifo.py")
        # The socket path, directory and separator included, of a directory named n bytes long under the root.
        fixed = len(os.fsencode(self.root / "requests.sock")) + 1
        self.assertLess(fixed, module.SUN_PATH - 1, "the scratch root leaves no room for a directory name")
        longest, too_long = (self.root / ("d" * (module.SUN_PATH - extra - fixed)) for extra in (1, 0))

        def served(directory):
            """Bind the broker's socket in directory, connect a client to it and return the bytes one line carries."""
            directory.mkdir(mode=0o700)
            broker, client = module.open_directory(directory), module.open_directory(directory)
            try:
                with module.listen(broker, directory) as listener, socket.socket(socket.AF_UNIX) as connection:
                    connection.connect(module.socket_address(client, directory))
                    connection.sendall(b"line\n")
                    self.assertTrue(select.select([listener], [], [], 5)[0], "the client did not connect")
                    accepted, _ = listener.accept()
                    with accepted:
                        return module.receive(accepted.fileno(), module.time.monotonic() + 5)
            finally:
                os.close(broker)
                os.close(client)
                shutil.rmtree(directory)

        output = self.root / "out"
        with patch.object(module, "sys", Platform("darwin")):
            # macOS names it by path: the longest directory whose socket path fits sun_path serves.
            self.assertEqual(served(longest), b"line")
            # One byte longer refuses before anything exists.
            with patch.object(sys, "argv", ["op-broker", "--directory", str(too_long)]), \
                    redirect_stderr(io.StringIO()) as stderr:
                with self.assertRaises(SystemExit) as refused:
                    module.main("broker")
            self.assertEqual((refused.exception.code, stderr.getvalue().splitlines()[0]),
                             (2, "op-broker: directory=path-too-long"))
            self.assertFalse(too_long.exists())
            # A FIFO broker a refresh left running there has no socket path to bound, and opq still reaches it.
            self.start(args=["--directory", str(too_long), "--account", "fixture-account"], grants=None,
                       protection=None, directory=too_long, launch=(sys.executable, "-B", str(FIFO_BROKER)))
            for signum in (signal.SIGTERM, signal.SIGINT):
                self.addCleanup(signal.signal, signum, signal.getsignal(signum))
            with patch.object(sys, "argv", ["opq", "--directory", str(too_long), "--output", str(output), "read",
                                            "op://fixture/item/password"]):
                module.main("client")
            self.assertEqual(output.read_bytes(), b"fixture-value")


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
