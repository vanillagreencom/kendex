"""Jarvis mail acquisition and the single durable event-batch owner."""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import subprocess
import sys
import tempfile
import time
import uuid

LIB = Path(__file__).resolve().parent
CAP = 60 * 1024


def run(args, cwd=None, data=None):
    return subprocess.run(list(map(str, args)), cwd=cwd, input=data,
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=60)


def checked(args, cwd=None):
    result = run(args, cwd)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "command-failed " + str(args[0]))
    return result.stdout


def epoch():
    return int(checked(["date", "+%s"]).strip())


def home_root(path):
    path = Path(path).resolve()
    result = run(["git", "rev-parse", "--show-toplevel"], path)
    return Path(result.stdout.strip()).resolve() if result.returncode == 0 else path


def config(bash, root):
    return json.loads(checked([bash, LIB / "jarvis-env.sh", "config", root]))


def line_value(value, token=False):
    encoded = json.dumps(str(value), ensure_ascii=token)[1:-1]
    return encoded.replace(" ", r"\u0020") if token else encoded


def event(kind, **fields):
    return "EVENT " + kind + "".join(" %s=%s" % (key, line_value(value, True)) for key, value in fields.items()) + "\n"


def atomic_json(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as out:
        temporary = Path(out.name)
        try:
            json.dump(value, out)
            out.flush()
            os.fsync(out.fileno())
        except BaseException:
            temporary.unlink()
            raise
    try:
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def hold(root, permitted):
    # The relay owner resolves aliases, precedence and path forms. Run its
    # module in isolation because each root supplies its own installed owner.
    owner = root / ".agents/skills/slack/scripts/lib"
    if not (owner / "settings.py").is_file():
        raise RuntimeError("dependency=slack-missing")
    code = ('import json,os,sys; from pathlib import Path; '
            'sys.path.insert(0,sys.argv[1]); os.environ["SLACK_ORCH_DIR"]=sys.argv[2]; '
            'from settings import load_presence; '
            'print(json.dumps(load_presence(Path(sys.argv[3])).jarvis_session_file))')
    value = json.loads(checked([sys.executable, "-B", "-c", code, owner,
                                root / ".agents/skills/orch", root]))
    if not value:
        return "ok"
    if not permitted():
        return "skipped"
    path = Path(value)
    with path.open("a"):
        at = epoch()
        os.utime(path, (at, at))
    return "ok"


def project_roots():
    try:
        roots = run(["kendex", "project", "list"])
    except FileNotFoundError as error:
        raise RuntimeError("kendex-missing fix=install-kendex-on-host-PATH") from error
    if roots.returncode:
        raise RuntimeError("kendex-missing fix=install-kendex-on-host-PATH " + roots.stderr.strip())
    return [Path(line.strip()).expanduser().resolve() for line in roots.stdout.split("\n")
            if line.strip() and "(" not in line]


def presence_roots(permitted):
    results = []
    for root in project_roots():
        try:
            results.append((str(root), hold(root, permitted), None))
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            results.append((str(root), "failed", str(error)))
    return results


def mail_pass(bash, home, side, cursor):
    state = json.loads(json.dumps(cursor))
    events = []
    now = epoch()
    for root in project_roots():
        key = str(root)
        prior = state.get(key, {})
        next_root = json.loads(json.dumps(prior))
        mail = root / ".agents/skills/mailbox/scripts/lane-mail"
        cause = ""
        root_events = []
        try:
            if not root.is_dir():
                raise RuntimeError("root-missing")
            if not mail.is_file():
                raise RuntimeError("refresh-needed" if (root / ".agents/skills/orch").is_dir() else "no-mailbox")
            common = Path(checked([bash, LIB / "jarvis-env.sh", "common-root", root]).strip())
            for box in ("to-lane", "to-overseer"):
                before = prior.get(box, {})
                filename = common / "tmp/lane-mail/overseer" / (box + ".jsonl")
                size_read = run(["wc", "-c", str(filename)])
                size = int(size_read.stdout.split()[0]) if size_read.returncode == 0 else None
                if size is not None and size == before.get("size"):
                    continue
                args = [mail, "events", "--item", "overseer", "--box", box,
                        "--after", str(before.get("count", 0))]
                if box == "to-overseer":
                    args.append("--mark-read")
                output = checked(args, root).split("\n")
                header = re.fullmatch(r"count=(\d+) first=.*", output[0]) if output else None
                if not header:
                    raise RuntimeError("events-header-unread")
                next_root[box] = {"count": int(header[1]), "size": size}
                for row in output[1:]:
                    if not row:
                        continue
                    envelope = json.loads(row)
                    if box == "to-lane":
                        if root == home or envelope.get("kind") != "answer":
                            continue
                        metadata = "%s %s re %s" % tuple(line_value(value, True) for value in
                            (envelope["id"], envelope["kind"], envelope.get("re", "")))
                    else:
                        if envelope.get("to") != "owner":
                            continue
                        metadata = "%s %s to=owner ref=%s options=%s recommend=%s deadline=%s" % tuple(line_value(value, True) for value in (
                            envelope["id"], envelope["kind"], envelope.get("ref") or "",
                            ",".join(envelope.get("options") or []), envelope.get("recommend") or "", envelope.get("deadline") or ""))
                    # Message text can quote this protocol. Reserve boundary
                    # lines for the pass writer so a quote cannot forge cursors.
                    text = "\n".join(re.sub(r"^(EVENT |cursor:)", r" \1", line_value(line))
                                     for line in str(envelope.get("text", "")).split("\n"))[:4000]
                    root_events.append(event("mail", repo=root.name, file=box) + metadata + "\n" + text + "\n")
            receipts = checked([mail, "drain", "--item", "overseer", "--after", "0", "--receipts"], root).split("\n")
            index = next((i for i, row in enumerate(receipts) if row.startswith("receipts ")), None)
            if index is None:
                raise RuntimeError("receipts-unread")
            receipt = re.fullmatch(r"receipts cursor=(\d+) count=\d+ first=.*", receipts[index])
            if not receipt:
                raise RuntimeError("receipts-missed")
            unread = []
            for row in receipts[index + 1:]:
                parts = row.split()
                if len(parts) == 3 and int(parts[0]) > int(receipt[1]):
                    unread.append(parts)
            if unread and now - int(unread[0][2]) >= 900:
                oldest = unread[0][1]
                if prior.get("unread") != oldest:
                    root_events.append(event("overseer-unread", repo=root.name, unread=len(unread),
                                             oldest=oldest, age=str((now-int(unread[0][2]))//60) + "min"))
                next_root["unread"] = oldest
            else:
                next_root.pop("unread", None)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            cause = str(error)
        if cause:
            if prior.get("cause") != cause:
                events.append(event("root-unreachable", repo=root.name, cause=cause))
            # A failed root read commits neither of its box cursors.
            next_root = dict(prior, cause=cause)
        else:
            next_root.pop("cause", None)
            events.extend(root_events)
        state[key] = next_root
    return "".join(events) + "cursor: " + json.dumps({"side": side, "roots": state}, separators=(",", ":")) + "\n"


def complete_blocks(data, offset):
    blocks = []
    opened = None
    position = offset
    for part in data.split(b"\n")[:-1]:
        line = part + b"\n"
        boundary = line.startswith(b"EVENT ") or line.startswith(b"cursor:")
        if boundary and opened is not None:
            blocks.append([opened, position])
            opened = None
        if line.startswith(b"EVENT "):
            opened = position
        position += len(line)
    return blocks, opened if opened is not None else position


class Watch:
    def __init__(self, home, bash, settings):
        self.home, self.bash, self.settings = home, bash, settings
        self.directory = Path(os.path.expanduser(settings["JARVIS_LOG_DIR"]))
        self.directory.mkdir(parents=True, exist_ok=True)
        self.log = self.directory / "events.log"
        self.path = self.directory / "batch.json"
        self.state = json.loads(self.path.read_text()) if self.path.exists() else {
            "generation": uuid.uuid4().hex, "offset": 0, "spans": [], "due": None, "pending": None}
        self._saved = json.loads(json.dumps(self.state)) if self.path.exists() else None
        if not self.path.exists():
            self.save()
        self.cursors = self.state.get("cursors", {})
        self.state["cursors"] = self.cursors
        if self.log.exists():
            with self.log.open("rb") as source:
                source.seek(self.state.get("cursor_offset", 0))
                for line in source:
                    if not line.endswith(b"\n"):
                        break
                    if line.startswith(b"cursor: "):
                        record = json.loads(line[8:])
                        self.cursors[record["side"]] = record["roots"]
                    self.state["cursor_offset"] = source.tell()
        self.save()
        self.next_presence = {}
        self.presence_pending = {}

    def save(self):
        if self.state != self._saved:
            atomic_json(self.path, self.state)
            self._saved = json.loads(json.dumps(self.state))

    def append(self, output):
        lines = output.split("\n")
        if len(lines) < 2 or lines[-1] != "" or not lines[-2].startswith("cursor: "):
            raise RuntimeError("pass-incomplete")
        record = json.loads(lines[-2][8:])
        if len(lines) == 2 and self.cursors.get(record["side"]) == record["roots"]:
            return
        with self.log.open("ab") as out:
            fcntl.flock(out, fcntl.LOCK_EX)
            out.write(output.encode())
            out.flush()
            os.fsync(out.fileno())
            self.state["cursor_offset"] = out.tell()
        self.cursors[record["side"]] = record["roots"]
        self.save()

    def batch(self, now):
        if self.state["pending"] is None:
            offset = self.state["offset"]
            spans, end = [], offset
            if self.log.exists():
                with self.log.open("rb") as source:
                    source.seek(offset)
                    spans, end = complete_blocks(source.read(), offset)
            self.state["spans"].extend(spans)
            self.state["offset"] = end
            def block(span, header=False):
                with self.log.open("rb") as source:
                    source.seek(span[0])
                    return source.readline(span[1]-span[0]) if header else source.read(span[1]-span[0])
            eligible = [span for span in self.state["spans"] if not block(span, True).startswith(b"EVENT timeout")]
            self.state["spans"] = eligible
            if not eligible:
                self.state["due"] = None
                self.save()
                return
            if self.state["due"] is None:
                self.state["due"] = now + int(self.settings["JARVIS_WAKE_SETTLE_SECS"])
            if now < self.state["due"]:
                self.save()
                return
            owner = ("repo=" + line_value(self.home.name, True)).encode()
            ordered = sorted(eligible, key=lambda span: owner not in block(span, True).split())
            selected, retained, body = [], [], b""
            full = False
            for span in ordered:
                size = span[1] - span[0]
                if not full and len(body) + size <= CAP:
                    selected.append(span)
                    body += block(span)
                else:
                    full = True
                    retained.append(span)
            if not selected:
                raise RuntimeError("event-too-large limit=61440")
            identity = json.dumps([self.state["generation"], selected]).encode()
            self.state["pending"] = {"key": "jarvis-" + hashlib.sha256(identity).hexdigest(),
                                     "body": body.decode(), "retained": retained, "end": end}
            # Selection is durable before the mailbox append. A retry uses
            # these bytes even if the event log gained complete new blocks.
            self.save()
        pending = self.state["pending"]
        with tempfile.NamedTemporaryFile(mode="w", dir=self.directory) as payload:
            payload.write(pending["body"])
            payload.flush()
            try:
                result = run([self.home / ".agents/skills/mailbox/scripts/lane-mail", "send", "--item", "overseer",
                              "--directive", "--file", payload.name, "--delivery-id", pending["key"]], self.home)
            except (OSError, subprocess.SubprocessError) as error:
                print("watch-loop: send=pending " + str(error), file=sys.stderr)
                return
        sent = re.search(r"^lane-mail: sent item=overseer id=([^\s]+)(?:\s|$)", result.stdout, re.M)
        repeated = re.search(r"^lane-mail: delivery-repeated=" + re.escape(pending["key"]) +
                             r" id=([^\s]+)(?:\s|$)", result.stderr, re.M)
        receipt = sent if result.returncode == 0 else repeated
        if not receipt:
            print("watch-loop: send=pending " + result.stderr.strip(), file=sys.stderr)
            return
        self.state.update(spans=pending["retained"], pending=None, due=None)
        self.save()
        print("watch-loop: batch=" + pending["key"] + " id=" + receipt[1] + " inbox=overseer", flush=True)

    def live(self, now=None):
        try:
            result = run([self.bash, LIB / "jarvis-env.sh", "live", self.home])
            if result.returncode:
                return False
            at = datetime.datetime.fromisoformat(result.stdout.strip().replace("Z", "+00:00")).timestamp()
            if now is None:
                now = epoch()
            return 0 <= now - at < 300
        except (OSError, ValueError, subprocess.SubprocessError):
            return False

    def remote_command(self, args):
        # Ship the pass and its private implementation, not a remote install
        # path. Each remote root still supplies its own mailbox/settings owner.
        files = {name: base64.b64encode((LIB.parent / name).read_bytes()).decode()
                 for name in ("vm-watch.sh", "lib/watch.py", "lib/jarvis-env.sh")}
        bootstrap = """import base64,json,pathlib,subprocess,sys,tempfile
with tempfile.TemporaryDirectory(prefix='jarvis-pass-') as folder:
 root=pathlib.Path(folder)
 for name,value in json.loads(sys.argv[1]).items():
  path=root/name; path.parent.mkdir(parents=True,exist_ok=True); path.write_bytes(base64.b64decode(value))
 result=subprocess.run([sys.argv[2],str(root/'vm-watch.sh'),*sys.argv[3:]])
 sys.exit(result.returncode)
"""
        return "python3 -c " + shlex.quote(bootstrap) + " " + shlex.quote(json.dumps(files)) + " \"$BASH\" " + shlex.join(args) + "\n"

    def remote(self, host):
        args = ["--side", "host", "--cursor", json.dumps(self.cursors.get("host", {}))]
        return run(["ssh", host, "bash -s"], data=self.remote_command(args))

    def presence(self, side):
        try:
            return self._presence(side)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            return [(side, "failed", str(error))]

    def _presence(self, side):
        permitted = self.live
        if side == "local":
            return presence_roots(permitted)
        # The host resolves settings before requesting permission for each
        # actual touch. Mail reads never carry a saved renewal permission.
        with tempfile.TemporaryFile(mode="w+") as errors:
            process = subprocess.Popen(["ssh", self.settings["JARVIS_CONTROL_HOST"], "bash -s"],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
                                       text=True, bufsize=1)
            try:
                process.stdin.write(self.remote_command(["--presence"]))
                process.stdin.flush()
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    while True:
                        if not selector.select(60):
                            raise subprocess.TimeoutExpired(process.args, 60)
                        line = process.stdout.readline()
                        if not line:
                            break
                        message = json.loads(line)
                        if message["kind"] == "permission":
                            process.stdin.write("renew\n" if permitted() else "skip\n")
                            process.stdin.flush()
                        else:
                            results = message["results"]
                            process.stdin.close()
                            status = process.wait(timeout=60)
                            if status == 0:
                                return results
                            break
                errors.seek(0)
                raise RuntimeError(errors.read() or "host-presence-failed")
            finally:
                if not process.stdin.closed:
                    process.stdin.close()
                process.stdout.close()
                if process.poll() is None:
                    process.kill()
                process.wait()

    def acquire(self, now):
        outputs = []
        try:
            outputs.append(("local", mail_pass(self.bash, self.home, "local", self.cursors.get("local", {})), None))
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            outputs.append(("local", None, str(error)))
        host = self.settings["JARVIS_CONTROL_HOST"]
        if host:
            try:
                result = self.remote(host)
                outputs.append(("host", result.stdout, result.stderr.strip() or "host-pass-failed" if result.returncode else None))
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                outputs.append(("host", None, str(error)))
        return outputs

    def accept(self, outputs):
        for side, output, failure in outputs:
            if failure is not None:
                self.failed_pass(side, failure)
            else:
                self.append(output)
                self.state.pop(side + "_failure", None)
                self.save()

    def tick(self, now, outputs):
        self.accept(outputs)
        self.batch(now)

    def _poll(self, passes, pending, now):
        for side in ("local", "host") if self.settings["JARVIS_CONTROL_HOST"] else ("local",):
            work = self.presence_pending.get(side)
            if work is not None and work.done():
                self.accept_presence(side, work.result())
                del self.presence_pending[side]
            if side not in self.presence_pending and now >= self.next_presence.get(side, 0):
                self.next_presence[side] = now + 120
                self.presence_pending[side] = passes.submit(self.presence, side)
        if pending.done():
            self.tick(now, pending.result())
            pending = passes.submit(self.acquire, now)
        else:
            self.batch(now)
        return pending

    def failed_pass(self, side, cause):
        prior = self.state.get(side + "_failure", {})
        if prior.get("cause") != cause:
            self.append(event("root-unreachable", repo=self.settings["JARVIS_CONTROL_HOST"] if side == "host" else self.home.name,
                              cause=cause) + "cursor: " +
                        json.dumps({"side": side, "roots": self.cursors.get(side, {})}) + "\n")
        self.state[side + "_failure"] = {"cause": cause}
        self.save()

    def accept_presence(self, side, results):
        failures = self.state.setdefault("presence_failures", {}).setdefault(side, {})
        if any(status == "ok" for _, status, _ in results) and all(status != "failed" for _, status, _ in results):
            failures.pop(side, None)
        for root, status, cause in results:
            if status == "ok":
                failures.pop(root, None)
            elif status == "failed":
                if root not in failures:
                    self.append(event("presence-renew-failed", repo=Path(root).name, side=side, cause=cause) +
                                "cursor: " + json.dumps({"side": side, "roots": self.cursors.get(side, {})}) + "\n")
                failures[root] = cause
            elif status != "skipped":
                raise RuntimeError("presence-status-invalid")
        self.save()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("loop", "pass"))
    parser.add_argument("--bash", required=True)
    parser.add_argument("--home", default=".")
    parser.add_argument("--side", default="local")
    parser.add_argument("--cursor", default="{}")
    parser.add_argument("--presence", action="store_true")
    args = parser.parse_args()
    home = home_root(args.home)
    if args.mode == "pass":
        if args.presence:
            def permitted():
                print(json.dumps({"kind":"permission"}), flush=True)
                return sys.stdin.readline() == "renew\n"
            print(json.dumps({"kind":"results", "results":presence_roots(permitted)}), flush=True)
        else:
            print(mail_pass(args.bash, home, args.side, json.loads(args.cursor)), end="")
    else:
        settings = config(args.bash, home)
        if not re.fullmatch(r"0|[1-9][0-9]*", settings["JARVIS_WAKE_SETTLE_SECS"]):
            raise RuntimeError("settle-invalid")
        os.chdir(home)
        # A second launch can reach the same log through a repeated session
        # start. Hold the OS lock for this loop's whole lifetime.
        directory = Path(os.path.expanduser(settings["JARVIS_LOG_DIR"]))
        directory.mkdir(parents=True, exist_ok=True)
        with (directory / "watch.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            watch = Watch(home, args.bash, settings)
            # Slow SSH and mailbox reads cannot extend an already-started
            # settle. Only this thread appends results or commits batch state.
            with ThreadPoolExecutor(max_workers=3) as passes:
                pending = passes.submit(watch.acquire, epoch())
                while True:
                    pending = watch._poll(passes, pending, epoch())
                    time.sleep(1)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("jarvis: operation=failed " + str(error), file=sys.stderr)
        sys.exit(1)
