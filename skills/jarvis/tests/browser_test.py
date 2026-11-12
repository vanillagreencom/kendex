"""Surface: jarvis-browser configured launch, detected browsers, reports, launchers and refused input."""
from contextlib import redirect_stdout, redirect_stderr
import http.client
import io
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch
from desktop_world import SCRIPTS, World, load, run_case


class Browser(World):
    def test_profile_and_url(self):
        for configured in (True, False):
            with self.subTest(configured=configured):
                name = "browser with spaces" if configured else "google-chrome"
                browser = self.executable(name)
                if configured:
                    self.env["JARVIS_BROWSER_COMMAND"] = str(browser)
                else:
                    self.env.pop("JARVIS_BROWSER_COMMAND", None)
                profile = self.root / "assistant profile"
                self.env.update(JARVIS_BROWSER_PROFILE=str(profile), JARVIS_BROWSER_PORT="9333")
                url = "https://example.org/task?q=one&other=two"
                result = self.run_tool("jarvis-browser", url)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls()[-1], ["--user-data-dir=" + str(profile),
                    "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=9333", "--no-first-run", url])
                browser.unlink()

    def test_refused_inputs(self):
        self.executable("google-chrome")
        base = dict(self.env, JARVIS_BROWSER_PROFILE=str(self.root / "profile"))
        for setting, value, url in [
            ("JARVIS_BROWSER_PROFILE", "relative", "https://example.org"),
            ("JARVIS_BROWSER_PORT", "65536", "https://example.org"),
            ("JARVIS_BROWSER_PORT", "not-a-port", "https://example.org"),
            ("JARVIS_BROWSER_COMMAND", "missing-browser", "https://example.org"),
            ("JARVIS_BROWSER_PROFILE", str(self.root / "profile"), "javascript:alert(1)"),
            ("JARVIS_BROWSER_DOWNLOADS", "relative-downloads", "https://example.org"),
            ("JARVIS_BROWSER_PROFILE", str(self.root / "profile"), None),
        ]:
            with self.subTest(setting=setting, value=value):
                self.env = dict(base, **{setting: value})
                result = self.run_tool("jarvis-browser", *([url] if url else []))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.log.exists())

    def test_downloads_and_class(self):
        self.executable("google-chrome")
        # The first launch's profile parent does not exist yet; Chromium creates a nested profile itself.
        profile, downloads = self.root / "profiles" / "assistant", self.root / "downloads"
        self.env.update(JARVIS_BROWSER_PROFILE=str(profile), JARVIS_BROWSER_DOWNLOADS=str(downloads),
                        JARVIS_BROWSER_CLASS="jarvis-assistant")
        preferences = profile / "Default/Preferences"
        kept = {"profile": {"name": "assistant"}, "download": {"prompt_for_download": True}}
        url = "https://example.org"
        for state in ("first-launch", "closed", "open"):
            with self.subTest(state=state):
                if state != "first-launch":
                    preferences.parent.mkdir(parents=True, exist_ok=True)
                    preferences.write_text(json.dumps(kept))
                if state == "open":
                    (profile / "SingletonLock").symlink_to("host-1234")
                result = self.run_tool("jarvis-browser", url)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls()[-1][-2:], ["--class=jarvis-assistant", url])
                expected = {"download": {"default_directory": str(downloads), "prompt_for_download": False}}
                if state == "closed":
                    expected = dict(kept, download=dict(kept["download"], default_directory=str(downloads)))
                elif state == "open":
                    expected = kept
                self.assertEqual(json.loads(preferences.read_text()) if preferences.exists() else None, expected)
                self.assertEqual(sorted(path.name for path in preferences.parent.iterdir()), ["Preferences"])

    def test_port_and_shim(self):
        for configured, expected in (("9444", b"9444\n"), (None, b"9222\n")):
            with self.subTest(port=configured):
                self.env.pop("JARVIS_BROWSER_PORT", None)
                if configured:
                    self.env["JARVIS_BROWSER_PORT"] = configured
                result = self.run_tool("jarvis-browser", "--port")
                self.assertEqual((result.returncode, result.stdout), (0, expected), result.stderr)
        result = self.run_tool("jarvis-browser", "--shim")
        self.assertEqual(result.returncode, 0, result.stderr)
        shim = Path(result.stdout.decode().rstrip("\n"))
        self.assertTrue(shim.is_absolute())
        launchers = ("xdg-open", "x-www-browser", "www-browser")
        self.assertEqual([name for name in launchers if not os.access(shim / name, os.X_OK)], [])
        self.assertFalse(self.log.exists())
        # The launchers run the script through its own interpreter lookup.
        for name in ("bash", "python3"):
            self.bin.joinpath(name).symlink_to(shutil.which(name) if name == "bash" else sys.executable)
        ack_path = self.root / "ack"
        os.mkfifo(ack_path, 0o600)
        ack = os.open(ack_path, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, ack)
        release_path = self.root / "release"
        os.mkfifo(release_path, 0o600)
        release = os.open(release_path, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, release)

        def acknowledged(byte):
            return bool(select.select([ack], [], [], 10)[0]) and os.read(ack, 1) == byte

        # The browser stays open until the test releases it, so a launcher that waits for it times out.
        self.executable("google-chrome", "import json,os,sys\n"
            "with open(os.environ['TOOL_LOG'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
            "with open(os.environ['HOME']+'/ack','wb',buffering=0) as f: f.write(b'B')\n"
            "with open(os.environ['HOME']+'/release','rb',buffering=0) as f: f.read(1)\n"
            "with open(os.environ['HOME']+'/ack','wb',buffering=0) as f: f.write(b'E')\n")
        profile = str(self.root / "profile")
        for name in launchers:
            with self.subTest(launcher=name):
                url = "https://example.org/device?name=" + name
                # A refused request reaches the caller with the driver's own key and status.
                self.env.pop("JARVIS_BROWSER_PROFILE", None)
                launched = len(self.calls()) if self.log.exists() else 0
                refused = subprocess.run([str(shim / name), url], env=self.env, capture_output=True, timeout=15)
                self.assertEqual(refused.returncode, 2, refused.stderr)
                self.assertEqual(refused.stderr.splitlines()[0], b"jarvis-browser: setting=JARVIS_BROWSER_PROFILE")
                self.assertEqual(len(self.calls()) if self.log.exists() else 0, launched)
                self.env["JARVIS_BROWSER_PROFILE"] = profile
                try:
                    result = subprocess.run([str(shim / name), url], env=self.env, capture_output=True, timeout=10)
                except subprocess.TimeoutExpired:
                    self.fail("the launcher waited for the browser")
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
                self.assertTrue(acknowledged(b"B"), "the launcher did not open the browser")
                self.assertEqual(self.calls()[-1][-1], url)
                self.assertIn("--user-data-dir=" + profile, self.calls()[-1])
                os.write(release, b"R")
                self.assertTrue(acknowledged(b"E"), "the released browser did not finish")

    def test_platform_refusal(self):
        module = load("jarvis-browser")
        browser = str(self.executable("google-chrome"))
        # A tool's platform must not change native stdlib executable lookup.
        for available in (browser, None):
            with self.subTest(browser=available), \
                 patch.object(module, "sys", SimpleNamespace(platform="win32")), \
                 patch.object(sys, "argv", ["jarvis-browser", "https://example.org"]), \
                 patch.dict(os.environ, JARVIS_BROWSER_PROFILE=str(self.root / "profile"), JARVIS_BROWSER_COMMAND=browser), \
                 patch.object(module.shutil, "which", return_value=available) as lookup, \
                 patch.object(module.os, "execv", side_effect=AssertionError("unsupported platform launched browser")):
                with self.assertRaises(SystemExit) as refused:
                    module.main()
                self.assertEqual(refused.exception.code, 2)
                lookup.assert_not_called()

    def test_profile_endpoints(self):
        self.bin.joinpath("ps").symlink_to(shutil.which("ps"))
        # The normal suite supplies only Chromium's external HTTP/file
        # interface. JARVIS_TEST_CHROMIUM selects a real browser command.
        # The fixture serves from socketserver.TCPServer: http.server.HTTPServer's
        # bind runs socket.getfqdn, a reverse lookup that stalls on macOS runners
        # past the 10-second endpoint deadline.
        browser = os.environ.get("JARVIS_TEST_CHROMIUM") or str(self.executable("chromium-fixture", '''import http.server,json,os,socketserver,sys,uuid
from pathlib import Path
profile=Path(next(arg.split('=',1)[1] for arg in sys.argv if arg.startswith('--user-data-dir=')))
port=int(next(arg.split('=',1)[1] for arg in sys.argv if arg.startswith('--remote-debugging-port=')))
assert 0 < port < 65536, sys.argv
with open(os.environ["TOOL_LOG"],"a") as log: log.write(json.dumps(sys.argv[1:])+"\\n")
profile.mkdir(parents=True,exist_ok=True)
marker=profile/'fixture-ready'
if marker.exists(): sys.exit(0)
target='/devtools/browser/'+str(uuid.uuid4())
url=sys.argv[-1]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        value={'webSocketDebuggerUrl':'ws://127.0.0.1:'+str(self.server.server_address[1])+target} if self.path=='/json/version' else [{'url':url}]
        body=json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self,*args): pass
server=socketserver.TCPServer(('127.0.0.1',port),Handler)
marker.write_text(str(server.server_address[1])+'\\n'+target+'\\n')
server.serve_forever()
'''))
        children = []

        def stop_children():
            for child in children:
                if child.poll() is None:
                    child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)

        self.addCleanup(stop_children)
        urls, ports, profiles = [], [], []
        self.env.update(JARVIS_BROWSER_COMMAND=browser, JARVIS_BROWSER_PORT="0")
        missing = self.run_tool("jarvis-browser", "--port")
        self.assertEqual(missing.returncode, 2)
        for name in ("first", "second"):
            page = self.root / (name + ".html")
            page.write_text("<title>" + name + "</title>")
            urls.append(page.as_uri())
            profile = self.root / (name + " profile")
            profiles.append(profile)
            self.env["JARVIS_BROWSER_PROFILE"] = str(profile)
            with self.root.joinpath(name + ".log").open("wb") as log:
                children.append(subprocess.Popen([sys.executable, "-B", str(SCRIPTS / "jarvis-browser"), urls[-1]],
                    env=self.env, cwd=self.root, stdout=log, stderr=log))
        for index, profile in enumerate(profiles):
            self.env["JARVIS_BROWSER_PROFILE"] = str(profile)
            result = self.run_tool("jarvis-browser", "--port")
            self.assertEqual(result.returncode, 0, result.stderr)
            port = int(result.stdout)
            self.assertTrue(profile.joinpath("JarvisDebuggingPort").is_file(), result.stderr)
            record = json.loads(profile.joinpath("JarvisDebuggingPort").read_text())
            self.assertEqual(port, record["port"])
            self.assertEqual(record["pid"], children[index].pid)
            self.assertGreater(port, 0)
            ports.append(port)
            self.assertIsNone(children[index].poll())
            # A second invocation reuses this live profile; detached readiness
            # must accept that native launcher exiting successfully.
            reused = self.run_tool("jarvis-browser", "--detach", urls[index])
            self.assertEqual(reused.returncode, 0, reused.stderr)
            self.assertEqual(self.run_tool("jarvis-browser", "--port").stdout, result.stdout)
        self.assertNotEqual(*ports)
        if not os.environ.get("JARVIS_TEST_CHROMIUM"):
            self.assertTrue(self.calls())
            for argv in self.calls():
                self.assertNotIn("--remote-debugging-port=0", argv)
        for index, port in enumerate(ports):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
                try:
                    connection.request("GET", "/json/list")
                    pages = [page["url"] for page in json.load(connection.getresponse())]
                finally:
                    connection.close()
                if urls[index] in pages:
                    break
                time.sleep(0.02)
            self.assertIn(urls[index], pages)
            self.assertNotIn(urls[1 - index], pages)
        # An old target or a recycled PID from another profile cannot make
        # a stored port look ready, even before the first target is discovered.
        marker = profiles[-1] / "JarvisDebuggingPort"
        self.assertFalse(marker.is_symlink())
        saved = marker.read_text()
        record = json.loads(saved)
        for changed in (dict(record, port=ports[0]), dict(record, pid=children[0].pid, target=None)):
            with self.subTest(record=changed):
                marker.write_text(json.dumps(changed))
                module = load("jarvis-browser")
                output, errors = io.StringIO(), io.StringIO()
                clock = SimpleNamespace(monotonic=Mock(side_effect=[0, 11]), sleep=Mock())
                with patch.dict(os.environ, self.env, clear=True), \
                     patch.object(sys, "argv", ["jarvis-browser", "--port"]), \
                     patch.object(module, "time", clock), \
                     redirect_stdout(output), redirect_stderr(errors):
                    with self.assertRaises(SystemExit) as refused:
                        module.main()
                self.assertEqual((refused.exception.code, output.getvalue()), (2, ""), errors.getvalue())
                self.assertIn("endpoint=unavailable", errors.getvalue())
                clock.sleep.assert_not_called()
        marker.write_text(saved)
        # An absolute browser command with restricted PATH must not lose its
        # healthy profile record when the required process probe is unavailable.
        probe = self.bin / "ps"
        probe.unlink()
        for state in ("missing", "nonzero"):
            if state == "nonzero":
                self.executable("ps", "import sys\nsys.exit(7)\n")
            calls = self.log.read_bytes() if self.log.exists() else None
            for arguments in (("--port",), ("--detach", urls[-1]), (urls[-1],), ("--stop",)):
                with self.subTest(probe=state, arguments=arguments):
                    refused = self.run_tool("jarvis-browser", *arguments)
                    self.assertEqual((refused.returncode, refused.stdout), (2, b""), refused.stderr)
                    key = b"stop=failed cause=process-unread" if arguments == ("--stop",) else b"process-probe=failed command=ps"
                    self.assertIn(key, refused.stderr)
                    self.assertEqual(marker.read_text(), saved)
                    self.assertIsNone(children[-1].poll())
                    self.assertEqual(self.log.read_bytes() if self.log.exists() else None, calls)
            fresh = self.root / ("unread-start-" + state)
            with patch.dict(self.env, JARVIS_BROWSER_PROFILE=str(fresh)):
                refused = self.run_tool("jarvis-browser", "--detach", "about:blank")
            self.assertEqual((refused.returncode, refused.stdout), (2, b""), refused.stderr)
            self.assertIn(b"process-probe=failed command=ps", refused.stderr)
            self.assertFalse(fresh.exists())
            self.assertEqual(self.log.read_bytes() if self.log.exists() else None, calls)
        probe.unlink()
        probe.symlink_to(shutil.which("ps"))
        self.assertEqual(self.run_tool("jarvis-browser", "--port").stdout, str(ports[-1]).encode()+b"\n")
        failed = self.executable("failed-browser", "import sys\nsys.exit(23)\n")
        self.env.update(JARVIS_BROWSER_COMMAND=str(failed), JARVIS_BROWSER_PROFILE=str(self.root / "never-ready"))
        refused = self.run_tool("jarvis-browser", "--detach", urls[0])
        self.assertEqual((refused.returncode, refused.stdout), (2, b""), refused.stderr)

    def test_detached_record_failure_stops_browser(self):
        self.bin.joinpath("ps").symlink_to(shutil.which("ps"))
        module = load("jarvis-browser")
        browser = self.executable("browser", "import signal\nsignal.pause()\n")
        environment = dict(self.env, JARVIS_BROWSER_COMMAND=str(browser), JARVIS_BROWSER_PORT="0",
                           JARVIS_BROWSER_PROFILE=str(self.root / "record-failure"))
        children = []
        popen = subprocess.Popen

        def launch(*args, **kwargs):
            child = popen(*args, **kwargs)
            if args[0][0] == str(browser):
                children.append(child)
                self.addCleanup(lambda: child.wait(timeout=5))
                self.addCleanup(lambda: child.poll() is None and child.kill())
            return child

        with patch.dict(os.environ, environment, clear=True), \
             patch.object(sys, "argv", ["jarvis-browser", "--detach", "about:blank"]), \
             patch.object(module.subprocess, "Popen", side_effect=launch), \
             patch.object(module, "write_json", side_effect=OSError("record write refused")):
            with self.assertRaises(SystemExit) as refused:
                module.main()
        self.assertEqual(refused.exception.code, 2)
        self.assertEqual(len(children), 1)
        self.assertIsNotNone(children[0].poll())

    def test_process_probe_failures(self):
        module = load("jarvis-browser")
        profile = self.root / "probe-profile"
        profile.mkdir()
        record = profile / "JarvisDebuggingPort"
        record.write_text(json.dumps({"pid": 0, "port": 9333, "target": None}))
        saved = record.read_bytes()
        browser = str(self.executable("browser"))
        environment = dict(self.env, JARVIS_BROWSER_PROFILE=str(profile), JARVIS_BROWSER_PORT="0",
                           JARVIS_BROWSER_COMMAND=browser)
        for failure, cause in ((FileNotFoundError(2, "missing"), "cause=unavailable errno=2"),
                               (subprocess.TimeoutExpired("ps", 5), "cause=timeout"),
                               (subprocess.CompletedProcess("ps", 7), "cause=exit status=7")):
            for arguments in (("--port",), ("--detach", "about:blank"), ("about:blank",), ("--stop",)):
                with self.subTest(failure=type(failure).__name__, arguments=arguments):
                    kwargs = {"side_effect": failure} if isinstance(failure, Exception) else {"return_value": failure}
                    with patch.dict(os.environ, environment, clear=True), \
                         patch.object(sys, "argv", ["jarvis-browser", *arguments]), \
                         patch.object(module.subprocess, "run", **kwargs), \
                         patch.object(module.subprocess, "Popen") as launch, \
                         patch.object(module.os, "execv") as execute, redirect_stderr(io.StringIO()):
                        if arguments == ("--stop",):
                            with self.assertRaises(SystemExit) as refused:
                                module.main()
                            self.assertEqual(refused.exception.code, 2)
                        else:
                            with self.assertRaises(module.ProcessProbeError) as refused:
                                module.main()
                            self.assertEqual(str(refused.exception), cause)
                        launch.assert_not_called()
                        execute.assert_not_called()
                    self.assertEqual(record.read_bytes(), saved)

    def test_profile_endpoint_control(self):
        with tempfile.TemporaryDirectory(prefix="jarvis-endpoint-control-") as scratch:
            scripts = Path(scratch) / "scripts"
            scripts.mkdir()
            source = SCRIPTS / "jarvis-browser"
            original = source.read_text()
            before, after = "print(profile_port(profile))", 'print("9222")'
            self.assertEqual(original.count(before), 1)
            changed = original.replace(before, after)
            self.assertNotEqual(changed, original)
            target = scripts / "jarvis-browser"
            env = dict(os.environ, JARVIS_TOOL_SCRIPTS=str(scripts))
            target.write_text(original)
            clean = run_case(Path(__file__).resolve(), "Browser.test_profile_endpoints", env, timeout=90)
            self.assertEqual(clean.returncode, 0, clean.stderr)
            port_argument = '"--remote-debugging-port=" + port'
            self.assertEqual(original.count(port_argument), 1)
            for mutation in (changed, original.replace(port_argument, '"--remote-debugging-port=0"')):
                with self.subTest(mutation=mutation != changed):
                    self.assertNotEqual(mutation, original)
                    target.write_text(mutation)
                    result = run_case(Path(__file__).resolve(), "Browser.test_profile_endpoints", env, timeout=90)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(b"FAIL: test_profile_endpoints", result.stderr)
                    self.assertNotIn(b"ERROR:", result.stderr)


if __name__ == "__main__":
    unittest.main()
