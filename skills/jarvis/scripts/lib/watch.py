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


def event(kind, **fields):
    return "EVENT " + kind + "".join(" %s=%s" % pair for pair in fields.items()) + "\n"


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


def hold(root, settings):
    value = settings["SLACK_JARVIS_SESSION_FILE"]
    if not value:
        return
    path = Path(os.path.expanduser(value))
    if not path.is_absolute():
        path = root / path
    # The relay owns the path contract. An absent parent is a renewal failure,
    # rather than permission to create a second presence location.
    with path.open("a"):
        at = epoch()
        os.utime(path, (at, at))


def mail_pass(bash, home, side, cursor, renew=False):
    state = json.loads(json.dumps(cursor))
    events = []
    try:
        roots = run(["kendex", "project", "list"])
    except FileNotFoundError as error:
        raise RuntimeError("kendex-missing fix=install-kendex-on-host-PATH") from error
    if roots.returncode:
        raise RuntimeError("kendex-missing fix=install-kendex-on-host-PATH " + roots.stderr.strip())
    now = epoch()
    for line in roots.stdout.splitlines():
        if not line.strip() or "(" in line:
            continue
        root = Path(line.strip()).expanduser().resolve()
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
                output = checked(args, root).splitlines()
                header = re.fullmatch(r"count=(\d+) first=.*", output[0]) if output else None
                if not header:
                    raise RuntimeError("events-header-unread")
                next_root[box] = {"count": int(header[1]), "size": size}
                for row in output[1:]:
                    envelope = json.loads(row)
                    if box == "to-lane":
                        if root == home or envelope.get("kind") != "answer":
                            continue
                        metadata = "%s %s re %s" % (envelope["id"], envelope["kind"], envelope.get("re", ""))
                    else:
                        if envelope.get("to") != "owner":
                            continue
                        metadata = "%s %s to=owner ref=%s options=%s recommend=%s deadline=%s" % (
                            envelope["id"], envelope["kind"], envelope.get("ref") or "",
                            ",".join(envelope.get("options") or []), envelope.get("recommend") or "", envelope.get("deadline") or "")
                    # Message text can quote this protocol. Reserve boundary
                    # lines for the pass writer so a quote cannot forge cursors.
                    text = re.sub(r"(?m)^(EVENT |cursor:)", r" \1", str(envelope.get("text", "")))[:4000]
                    root_events.append(event("mail", repo=root.name, file=box) + metadata + "\n" + text + "\n")
            receipts = checked([mail, "drain", "--item", "overseer", "--after", "0", "--receipts"], root).splitlines()
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
            cause = str(error).splitlines()[0]
        if cause:
            if prior.get("cause") != cause:
                events.append(event("root-unreachable", repo=root.name, cause=shlex.quote(cause)))
            # A failed root read commits neither of its box cursors.
            next_root = dict(prior, cause=cause)
        else:
            next_root.pop("cause", None)
            events.extend(root_events)
        if renew:
            try:
                hold(root, config(bash, root))
                next_root.pop("presence_failure", None)
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                if not prior.get("presence_failure"):
                    events.append(event("presence-renew-failed", repo=root.name, side=side))
                next_root["presence_failure"] = str(error)
        state[key] = next_root
    return "".join(events) + "cursor: " + json.dumps({"side": side, "roots": state}, separators=(",", ":")) + "\n"


def complete_blocks(data, offset):
    blocks = []
    opened = None
    position = offset
    for line in data[offset:].splitlines(keepends=True):
        if not line.endswith(b"\n"):
            break
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
        if not self.path.exists():
            self.save()
        self.cursors = {}
        if self.log.exists():
            for line in self.log.read_bytes().splitlines(keepends=True):
                if line.startswith(b"cursor: ") and line.endswith(b"\n"):
                    record = json.loads(line[8:])
                    self.cursors[record["side"]] = record["roots"]
        self.next_presence = 0

    def save(self):
        atomic_json(self.path, self.state)

    def append(self, output):
        lines = output.splitlines(keepends=True)
        if not lines or not lines[-1].startswith("cursor: ") or not lines[-1].endswith("\n"):
            raise RuntimeError("pass-incomplete")
        record = json.loads(lines[-1][8:])
        with self.log.open("ab") as out:
            fcntl.flock(out, fcntl.LOCK_EX)
            out.write(output.encode())
            out.flush()
            os.fsync(out.fileno())
        self.cursors[record["side"]] = record["roots"]

    def batch(self, now):
        if self.state["pending"] is None:
            data = self.log.read_bytes() if self.log.exists() else b""
            spans, end = complete_blocks(data, self.state["offset"])
            self.state["spans"].extend(spans)
            self.state["offset"] = end
            eligible = [span for span in self.state["spans"] if not data[span[0]:span[1]].startswith(b"EVENT timeout")]
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
            owner = ("repo=" + self.home.name).encode()
            ordered = sorted(eligible, key=lambda span: owner not in data[span[0]:span[1]].split(b"\n", 1)[0].split())
            selected, retained, body = [], [], b""
            full = False
            for span in ordered:
                block = data[span[0]:span[1]]
                if not full and len(body) + len(block) <= CAP:
                    selected.append(span)
                    body += block
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

    def live(self, now):
        result = run([self.bash, LIB / "jarvis-env.sh", "live", self.home])
        if result.returncode:
            return False
        try:
            at = datetime.datetime.fromisoformat(result.stdout.strip().replace("Z", "+00:00")).timestamp()
            return 0 <= now - at < 300
        except ValueError:
            return False

    def remote(self, host, renew):
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
        args = ["--side", "host", "--cursor", json.dumps(self.cursors.get("host", {}))]
        if renew:
            args.append("--renew")
        command = "python3 -c " + shlex.quote(bootstrap) + " " + shlex.quote(json.dumps(files)) + " \"$BASH\" " + shlex.join(args)
        return run(["ssh", host, "bash -s"], data=command + "\n")

    def acquire(self, now):
        outputs = []
        presence = now >= self.next_presence
        renew = presence and self.live(now)
        if presence:
            self.next_presence = now + 120
        try:
            outputs.append(("local", mail_pass(self.bash, self.home, "local", self.cursors.get("local", {}), renew), None, renew))
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            outputs.append(("local", None, str(error), renew))
        host = self.settings["JARVIS_CONTROL_HOST"]
        if host:
            try:
                result = self.remote(host, renew)
                outputs.append(("host", result.stdout, result.stderr.strip() or "host-pass-failed" if result.returncode else None, renew))
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                outputs.append(("host", None, str(error), renew))
        return outputs

    def accept(self, outputs):
        for side, output, failure, renew in outputs:
            if failure is not None:
                self.failed_pass(side, failure, renew)
            else:
                self.append(output)
                self.state.pop(side + "_failure", None)
                self.save()

    def tick(self, now, outputs):
        self.accept(outputs)
        self.batch(now)

    def _poll(self, passes, pending, now):
        if pending.done():
            self.tick(now, pending.result())
            pending = passes.submit(self.acquire, now)
        else:
            self.batch(now)
        return pending

    def failed_pass(self, side, cause, renew):
        kind = "presence-renew-failed" if renew else "root-unreachable"
        prior = self.state.get(side + "_failure", {})
        if prior.get("kind") != kind or (not renew and prior.get("cause") != cause):
            self.append(event(kind, repo=self.settings["JARVIS_CONTROL_HOST"] if side == "host" else self.home.name,
                              cause=shlex.quote(cause)) + "cursor: " +
                        json.dumps({"side": side, "roots": self.cursors.get(side, {})}) + "\n")
        self.state[side + "_failure"] = {"kind": kind, "cause": cause}
        self.save()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("loop", "pass"))
    parser.add_argument("--bash", required=True)
    parser.add_argument("--home", default=".")
    parser.add_argument("--side", default="local")
    parser.add_argument("--cursor", default="{}")
    parser.add_argument("--renew", action="store_true")
    args = parser.parse_args()
    home = home_root(args.home)
    if args.mode == "pass":
        print(mail_pass(args.bash, home, args.side, json.loads(args.cursor), args.renew), end="")
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
            with ThreadPoolExecutor(max_workers=1) as passes:
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
