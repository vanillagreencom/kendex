"""Send the owner's note as a directive to one repository's overseer.

The repository's own lane-mail makes the send on the machine that holds it,
and its refusal decides the route: `overseer-absent` on the control host
tries this machine.
"""
import argparse
from pathlib import Path
import shlex
import sys
import tempfile

LIB = Path(__file__).resolve().parent
sys.path.insert(0, str(LIB))
import watch  # noqa: E402

LANE_MAIL = ".agents/skills/mailbox/scripts/lane-mail"
FOOTER = ("Before you act on this note, check each fact it states against its source, and test its approach "
          "against this repository's rules and the Over-Engineering section of the code-quality skill. "
          "Say what you changed from it, and why.")
# lane-mail reads --file on the machine that runs it, so the host copy is a
# mktemp file this same ssh call removes on exit, sent or refused.
HOST_SEND = """set -euo pipefail
cd -- "$1"
[ -f %(mail)s ] || { printf 'owner-note: mailbox-missing=%%s\\n' "$1" >&2; exit 2; }
note="$(mktemp)"
trap 'rm -f -- "$note"' EXIT
cat >"$note"
"$BASH" %(mail)s send --item overseer --directive --file "$note"
""" % {"mail": LANE_MAIL}


class Refusal(Exception):
    pass


def listing(side, host):
    if side == "host":
        result = watch.run(["ssh", host, "kendex project list"], operation="project-list")
    else:
        result = watch.run(["kendex", "project", "list"], operation="project-list")
    if result.returncode:
        raise Refusal("project-list-failed", side, result.stderr.strip())
    return watch.listed_roots(result.stdout)


def send(bash, side, host, root, note):
    if side == "host":
        return watch.run(["ssh", host, "bash -c " + shlex.quote(HOST_SEND) + " owner-note " + shlex.quote(root)],
                         data=note, operation="host-send")
    mail = Path(root) / LANE_MAIL
    if not mail.is_file():
        raise Refusal("mailbox-missing", root)
    with tempfile.NamedTemporaryFile(mode="w", prefix="owner-note-", suffix=".md") as payload:
        payload.write(note)
        payload.flush()
        return watch.run([bash, mail, "send", "--item", "overseer", "--directive", "--file", payload.name],
                         root, operation="local-send")


def deliver(bash, repo, note, host):
    sides = (("host", "local") if host else ("local",))
    for side in sides:
        matches = [root for root in listing(side, host) if root.rstrip("/").rsplit("/", 1)[-1] == repo]
        if len(matches) > 1:
            raise Refusal("repo-ambiguous", repo, "side=%s roots=%s" % (side, " ".join(matches)))
        if not matches:
            continue
        result = send(bash, side, host, matches[0], note)
        first = result.stderr.split("\n", 1)[0]
        if result.returncode and first.startswith("lane-mail: overseer-absent="):
            continue
        if result.returncode:
            raise Refusal("send-failed", side, result.stderr.strip())
        sys.stdout.write(result.stdout)
        return side, matches[0]
    raise Refusal("no-overseer", repo, "sides=" + ",".join(sides))


def main():
    parser = argparse.ArgumentParser(prog="owner-note", description=(
        "Send FILE, then a blank line and the verify footer, as a directive to the overseer of REPO, "
        "the last path segment of a root `kendex project list` prints: on JARVIS_CONTROL_HOST first "
        "when it is set, then on this machine."))
    parser.add_argument("--bash", required=True, help=argparse.SUPPRESS)
    parser.add_argument("repo")
    parser.add_argument("file", type=Path)
    args = parser.parse_args()
    try:
        try:
            text = args.file.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise Refusal("file-unreadable", args.file, str(error)) from error
        try:
            host = watch.config(args.bash, watch.home_root(Path.cwd()))["JARVIS_CONTROL_HOST"]
        except (OSError, ValueError, RuntimeError) as error:
            raise Refusal("settings-unreadable", "JARVIS_CONTROL_HOST", str(error)) from error
        note = text.rstrip("\n") + "\n\n" + FOOTER + "\n"
        side, root = deliver(args.bash, args.repo, note, host)
    except Refusal as refusal:
        key, value = refusal.args[:2]
        detail = "".join("\n" + part for part in refusal.args[2:] if part)
        print("owner-note: %s=%s%s" % (key, value, detail), file=sys.stderr)
        return 2
    except watch.Failure as error:
        print("owner-note: send-failed=" + error.record["key"][0] + "\n" + str(error), file=sys.stderr)
        return 2
    print("owner-note: sent side=%s root=%s" % (side, root))
    return 0


if __name__ == "__main__":
    sys.exit(main())
