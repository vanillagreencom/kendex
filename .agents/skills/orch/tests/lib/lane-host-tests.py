"""Exercise the real dispatcher with the reusable external provider stub.

The dispatcher is one surface, and its one must-fail control closes the
protocol case: a copy that forwards exec in place of stop.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest

PACKAGE = Path(__file__).resolve().parents[2]


class LaneHostTests(unittest.TestCase):
    def setUp(self):
        scratch = Path.cwd() / "tmp"
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.script = self.root / "scripts/lane-host"
        self.script.parent.mkdir()
        shutil.copy2(PACKAGE / "scripts/lane-host", self.script)
        (self.script.parent / "lib").symlink_to(PACKAGE / "scripts/lib")
        self.stub = self.root / "provider with space"
        shutil.copy2(PACKAGE / "tests/fixtures/lane-host", self.stub)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("ORCH_", "KENDEX_", "LANE_HOST_"))}
        # The slot directory is per home, so a case gets a home of its own.
        self.env.update(HOME=str(self.root / "home"), LANE_HOST_STUB_LOG=str(self.root / "calls"), LANE_HOST_STUB_FILE=str(self.root / "bytes"), LANE_HOST_STUB_LIB=str(self.script.parent / "lib"))
    def run_host(self, *args, **env):
        return subprocess.run([str(self.script), *args], cwd=self.root, env={**self.env, **env}, input=b"seed\x00data\n", capture_output=True)
    def start_host(self, *args, **env):
        return subprocess.Popen([str(self.script), *args], cwd=self.root, env={**self.env, **env}, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def admitted(self, count):
        # The stub logs a call once the provider runs, which is after its slot.
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            calls = self.root / "calls"
            if calls.exists() and calls.read_text().count("wait --item") >= count:
                return
            time.sleep(0.05)
        self.fail(f"fewer than {count} provider calls admitted")
    def test_calls_bound_per_home(self):
        env = {"ORCH_LANE_HOST": str(self.stub), "ORCH_LANE_HOST_MAX_CALLS": "2"}
        gates = [self.root / "gate-a", self.root / "gate-b", self.root / "gate-c"]
        held = [self.start_host("wait", "--item", f"TEST-{n}", **env, LANE_HOST_STUB_WAIT_GATE=str(gate)) for n, gate in enumerate(gates[:2])]
        def release():
            for gate in gates:
                gate.touch()
            for proc in held:
                proc.wait()
        self.addCleanup(release)
        self.admitted(2)
        refused = self.run_host("touch", "--item", "TEST-3", **env, ORCH_LANE_HOST_BUSY_WAIT_SECS="0")
        self.assertEqual((refused.returncode, refused.stderr.splitlines()[:1]),
                         (69, [b"lane-host: lane-host-busy count=2 cap=2 verb=touch item=TEST-3"]))
        self.assertNotIn("touch --item TEST-3", (self.root / "calls").read_text())
        waiting = self.start_host("touch", "--item", "TEST-4", **env, ORCH_LANE_HOST_BUSY_WAIT_SECS="20")
        time.sleep(0.5)
        self.assertIsNone(waiting.poll())
        gates[0].touch()
        self.assertEqual((held[0].wait(timeout=20), waiting.wait(timeout=20)), (0, 0))
        # A dispatcher killed while it held a slot leaves the slot to the next
        # take: with TEST-2 holding the other, only the reclaim admits TEST-5.
        held.append(self.start_host("wait", "--item", "TEST-2", **env, LANE_HOST_STUB_WAIT_GATE=str(gates[2])))
        self.admitted(3)
        os.kill(held[1].pid, 9)
        held[1].wait()
        admitted = self.run_host("touch", "--item", "TEST-5", **env, ORCH_LANE_HOST_BUSY_WAIT_SECS="0")
        self.assertEqual(admitted.returncode, 0, admitted.stderr)
    def test_bound_settings_refused(self):
        rows = [("0", "30", b"name=ORCH_LANE_HOST_MAX_CALLS value=0"), ("04", "30", b"name=ORCH_LANE_HOST_MAX_CALLS value=04"),
                ("x", "30", b"name=ORCH_LANE_HOST_MAX_CALLS value=x"), ("4", "-1", b"name=ORCH_LANE_HOST_BUSY_WAIT_SECS value=-1"),
                ("4", "05", b"name=ORCH_LANE_HOST_BUSY_WAIT_SECS value=05")]
        for cap, wait, fields in rows:
            with self.subTest(cap=cap, wait=wait):
                result = self.run_host("touch", "--item", "TEST-1", ORCH_LANE_HOST=str(self.stub),
                                       ORCH_LANE_HOST_MAX_CALLS=cap, ORCH_LANE_HOST_BUSY_WAIT_SECS=wait)
                self.assertEqual((result.returncode, result.stderr.splitlines()[:1]), (2, [b"lane-host: setting-invalid " + fields]))
        self.assertFalse((self.root / "calls").exists())
    def test_explicit_selection_and_settings(self):
        (self.root / "kendex.settings.toml").write_text(f'[env]\nORCH_LANE_HOST = "{self.stub}"\n')
        for env, expected in (({}, str(self.stub)), ({"ORCH_LANE_HOST": "local"}, "local")):
            with self.subTest(env=env):
                result = self.run_host("resolve", **env)
                self.assertEqual((result.returncode, result.stdout.decode().strip()), (0, expected))
        (self.root / "kendex.settings.toml").unlink()
        for env in ({}, {"DAYTONA_API_KEY": "not-a-real-key"}, {"ORCH_LANE_HOST": ""}):
            with self.subTest(env=env):
                result = self.run_host("resolve", **env)
                self.assertEqual((result.returncode, result.stdout), (0, b"local\n"))
                refused = self.run_host("create", **env)
                self.assertEqual(refused.returncode, 2)
                self.assertIn(b"host-local verb=create", refused.stderr)
        self.assertFalse((self.root / "calls").exists())
    def test_provider_protocol_and_failures(self):
        env = {"ORCH_LANE_HOST": str(self.stub)}
        args = ("create", "--item", "TEST-1", "--repo", "owner/repo", "--harness", "claude", "--account", "/account one")
        first = self.run_host(*args, **env)
        second = self.run_host(*args, "--reuse", **env)
        expected = b"ssh-target=lane.example\tpath=/srv/lane\tremote-prefix=exec bash -lc\n"
        self.assertEqual((first.returncode, first.stdout, second.stdout), (0, expected, expected))
        self.assertIn("/account\\ one", (self.root / "calls").read_text())
        self.assertEqual(self.run_host("put", "--item", "TEST-1", "/remote", **env).returncode, 0)
        result = self.run_host("cat", "--item", "TEST-1", "/remote", **env)
        self.assertEqual((result.returncode, result.stdout), (0, b"seed\x00data\n"))
        appended = self.run_host("append", "--item", "TEST-1", "/remote", **env)
        self.assertEqual(appended.returncode, 0, appended.stderr)
        result = self.run_host("cat", "--item", "TEST-1", "/remote", **env)
        self.assertEqual((result.returncode, result.stdout), (0, b"seed\x00data\nseed\x00data\n"))
        for code, notice in ((75, False), (1, True), (3, True)):
            with self.subTest(code=code):
                result = self.run_host(*args, **env, LANE_HOST_STUB_STATUS=str(code))
                self.assertEqual(result.returncode, code)
                self.assertEqual(b"host-create-failed" in result.stderr, notice)
        self.assertEqual(self.run_host("close", "--item", "TEST-1", **env, LANE_HOST_STUB_STATUS="3").returncode, 3)
        closed = self.run_host("close", "--item", "TEST-1", **env)
        self.assertEqual((closed.returncode, closed.stdout), (0, b"kept=/fleet/archive/repo/TEST-1/tmp-stub.tgz\n"))
        self.assertTrue((self.root / "calls").read_text().endswith("delete --item TEST-1\n"))
    def test_missing_provider_and_inert_help(self):
        result = self.run_host("create", ORCH_LANE_HOST="/absent/provider")
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"host-unavailable path=/absent/provider", result.stderr)
        (self.root / ".env.local").write_text("exit 91\n")
        self.assertEqual(self.run_host("--help").returncode, 0)
    def test_dispatch_protocol(self):
        original = self.script.read_text()
        rule = "  create|wait|cat|put|append|touch|stop|close|list|accounts)"
        self.assertEqual(original.count(rule), 1)
        protocol = [(("stop", "--item", "TEST-1", "--harness", "claude"), (0, True)),
                    (("wait", "--item", "TEST-1"), (0, True)),
                    (("exec", "--item", "TEST-1", "--", "true"), (2, False))]
        def observed(args):
            before = (self.root / "calls").read_text() if (self.root / "calls").exists() else ""
            result = self.run_host(*args, ORCH_LANE_HOST=str(self.stub))
            return result.returncode, args[0] in (self.root / "calls").read_text()[len(before):]
        for args, expected in protocol:
            self.assertEqual(observed(args), expected)
        self.script.write_text(original.replace(rule, rule.replace("stop", "exec")))
        self.assertNotEqual(observed(protocol[0][0]), protocol[0][1])


class LaneHostCallersTests(unittest.TestCase):
    """Every orch call of a provider verb runs scripts/lane-host, the one place
    the per-home bound is taken: a site running any other command word with a
    provider verb is a call outside the bound."""
    # A provider verb, or the caller's own argv forwarded whole, which is how
    # open-terminal's host_transport hands its verbs on.
    VERB = re.compile(r"(?:create|wait|cat|put|append|touch|stop|close|list|accounts|\$@)")
    # Keywords, `!`, environment assignments and an optional argv prefix, then
    # the command word and the word after it.
    COMMAND = re.compile(r'^(?:\s|!|(?:if|then|elif|do|while|until)\b|[A-Za-z_]\w*=(?:"[^"]*"|[^\s"]*(?=\s))'
                         r'|\$\{\w+\[@\]\+"\$\{\w+\[@\]\}"\})*("\$[^"]*")\s+("[^"]*"|[^\s;|&)]+)')
    FUNCTION = re.compile(r"^([A-Za-z_]\w*)\(\) *\{")
    SCRIPT = re.compile(r'^(?:\$\{\w+:-)?\$(?:SCRIPT_DIR|SKILLS_DIR)/([\w./-]+?)\}?$')

    def sites(self, scripts):
        """(file, line number, command word, enclosing function) per site."""
        found = []
        for path in sorted(p for p in scripts.rglob("*") if p.is_file() and p.name not in ("lane-host", "lane-host-ssh")):
            function = None
            for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                function = self.FUNCTION.match(line).group(1) if self.FUNCTION.match(line) else function
                if line.lstrip().startswith("#"):
                    continue
                for segment in re.split(r"\$\(|&&|\|\||;|\|", line):
                    match = self.COMMAND.match(segment)
                    if match and self.VERB.fullmatch(match.group(2).strip('"')):
                        found.append((path.relative_to(scripts).as_posix(), number, match.group(1), function))
        return found

    def target(self, scripts, path, word, function, depth=0):
        """`wrapper`, `provider` for a provider the package ships, `other` for
        another package script, or None: unresolved."""
        name = re.fullmatch(r'"\$\{?(\w+)\}?"', word)
        value = word.strip('"') if not name else None
        text = (scripts / path).read_text(errors="replace")
        if name and not name.group(1).isdigit():
            binding = r"^\s*" + name.group(1) + r'="([^"]*)"$'
            bound = re.findall(binding, text, re.M)
            if not bound:
                # A library reads the binding the script sourcing it made: every
                # binding of the name in the package must name one script.
                bound = [v for p in scripts.rglob("*") if p.is_file()
                         for v in re.findall(binding, p.read_text(errors="replace"), re.M)]
                named = {m.group(1) if (m := self.SCRIPT.match(v)) else None for v in bound}
                bound = bound[:1] if len(named) == 1 and None not in named else []
            value = bound[0] if len(bound) == 1 else None
        if name and name.group(1).isdigit():
            # A positional is the wrapper where every caller passes the wrapper.
            if function is None or depth > 3:
                return None
            calls = re.compile(r"(?:^|[\s;&|(])" + function + r"((?:\s+\"[^\"]*\"){" + name.group(1) + r"})")
            targets = []
            for caller in (p for p in scripts.rglob("*") if p.is_file()):
                enclosing = None
                for line in caller.read_text(errors="replace").splitlines():
                    enclosing = self.FUNCTION.match(line).group(1) if self.FUNCTION.match(line) else enclosing
                    call = calls.search(line)
                    if call and not line.lstrip().startswith("#") and enclosing != function:
                        argument = re.findall(r'"[^"]*"', call.group(1))[-1]
                        targets.append(self.target(scripts, caller.relative_to(scripts), argument, enclosing, depth + 1))
            return "wrapper" if targets and all(t == "wrapper" for t in targets) else None
        script = self.SCRIPT.match(value or "")
        if not script:
            return None
        if script.group(1) == "lane-host":
            return "wrapper"
        # The providers the package ships are named for the dispatcher, as
        # lane-host-ssh is; run directly, one bypasses the slot cap.
        return "provider" if script.group(1).startswith("lane-host-") else "other"

    def unbounded(self, scripts):
        return [(path, number, word) for path, number, word, function in self.sites(scripts)
                if self.target(scripts, path, word, function) in (None, "provider")]

    def test_every_provider_call_runs_the_wrapper(self):
        scripts = PACKAGE / "scripts"
        self.assertEqual(self.unbounded(scripts), [])
        wrapper = {(path, word) for path, _, word, function in self.sites(scripts)
                   if self.target(scripts, path, word, function) == "wrapper"}
        # Members the extractor must reach, or it is the extractor that broke.
        for member in (("lane-mail", '"$SCRIPT_DIR/lane-host"'), ("lane-close", '"$LANE_HOST"'),
                       ("lib/lane-gitfile.sh", '"$1"'), ("open-terminal", '"$SCRIPT_DIR/lane-host"')):
            self.assertIn(member, wrapper, "the site extractor no longer reaches a known wrapper call")

    def test_a_direct_provider_call_is_named(self):
        rows = [("lane-mail", '  "$ORCH_LANE_HOST" cat --item "$ITEM" /remote\n', "lane-mail"),
                ("open-terminal", '  "$LANE_HOST" touch --item "$1"\n', "open-terminal"),
                ("lanes", '  "$SCRIPT_DIR/lane-host-ssh" cat --item "$ITEM" /remote\n', "lanes"),
                ("oversee-watch", '  lane_host_fetch "$ORCH_LANE_HOST" "$1" /remote "$WORK_DIR/x" "$WORK_DIR/e"\n', "lib/lane-gitfile.sh")]
        for path, planted, named in rows:
            with self.subTest(path=path):
                scratch = Path.cwd() / "tmp"
                scratch.mkdir(exist_ok=True)
                with tempfile.TemporaryDirectory(dir=scratch) as temp:
                    scripts = Path(temp) / "scripts"
                    shutil.copytree(PACKAGE / "scripts", scripts)
                    with open(scripts / path, "a") as script:
                        script.write(planted)
                    self.assertEqual({site[0] for site in self.unbounded(scripts)}, {named}, planted)

if __name__ == "__main__":
    unittest.main()
