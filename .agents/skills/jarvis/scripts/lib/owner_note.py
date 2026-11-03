"""Send an owner directive through watch's declared destination selection."""
import argparse
from pathlib import Path
import shlex
import sys
import tempfile

LIB = Path(__file__).resolve().parent
sys.path.insert(0, str(LIB))
import watch  # noqa: E402

LANE_MAIL = ".agents/skills/mailbox/scripts/lane-mail"
FOOTER = ("Before you act on this note or delegate it: check its facts against their source and test its "
          "approach against your repository's rules and code-quality § Over-Engineering in your checkout "
          "(the system's own interface, platform first, no over-engineering). Where it is wrong, or a simpler "
          "or better route exists, adjust it, and state in your reply what you changed and why.")
# lane-mail reads --file on the machine that runs it, so the host copy is a
# mktemp file this same ssh call removes on exit, sent or refused. Arguments
# after ROOT join the send: a forward passes its --delivery-id there. The
# ${1+"$@"} form keeps an empty list legal under set -u on a Bash 3.2 host.
HOST_SEND = """set -euo pipefail
root="$1"
shift
cd -- "$root"
[ -f %(mail)s ] || { printf 'owner-note: mailbox-missing=%%s\\n' "$root" >&2; exit 2; }
note="$(mktemp)"
trap 'rm -f -- "$note"' EXIT
cat >"$note"
"$BASH" %(mail)s send --item overseer --directive --file "$note" ${1+"$@"}
""" % {"mail": LANE_MAIL}


Refusal = watch.DestinationRefusal


def send(bash, side, host, root, note):
    """The send's stdout; a timeout or a refusal of either side is a watch.Failure."""
    if side == "host":
        return watch.checked(["ssh", host, "bash -c " + shlex.quote(HOST_SEND) + " owner-note " + shlex.quote(root)],
                             data=note, operation="host-send")
    mail = Path(root) / LANE_MAIL
    if not mail.is_file():
        raise Refusal("mailbox-missing", root)
    with tempfile.NamedTemporaryFile(mode="w", prefix="owner-note-", suffix=".md") as payload:
        payload.write(note)
        payload.flush()
        return watch.checked([bash, mail, "send", "--item", "overseer", "--directive", "--file", payload.name],
                             root, operation="local-send")


def deliver(bash, repo, note, settings, host=None, local=False):
    for target, root, fallback in watch.note_routes(settings, repo, host, local):
        side = "host" if target.host else "local"
        try:
            sys.stdout.write(send(bash, side, target.host, root, note))
        except watch.Failure as error:
            if fallback and error.record["key"][1:] == ["refusal", "overseer-absent"]:
                continue
            raise Refusal("send-failed", side if fallback else target.key, str(error)) from error
        return side, root, target.key
    raise Refusal("no-overseer", repo)


def main():
    parser = argparse.ArgumentParser(prog="owner-note", description=(
        "Send FILE, then a blank line and the verify footer, as a directive to the overseer of REPO, "
        "the last path segment of a root `kendex project list` prints. JARVIS_REMOTE_HOSTS adds SSH aliases "
        "to local and JARVIS_CONTROL_HOST roots; bare selection must be unique across them. With no additional "
        "alias, try JARVIS_CONTROL_HOST first, then this machine."), epilog=(
        "A refusal prints `owner-note: KEY=VALUE` and its cause on stderr and exits 2. Keys: file-unreadable, "
        "settings-unreadable, setting-invalid, destination-unknown, project-list-failed (VALUE is the destination), repo-ambiguous, mailbox-missing "
        "(VALUE is the root), send-failed (VALUE is the side), no-overseer (no side lists a root named REPO whose "
        "lane-mail has an overseer), role-satellite (VALUE is JARVIS_MAIN_HOST: a satellite instructs no "
        "overseer, so forward the request to the main instead)."))
    parser.add_argument("--bash", required=True, help=argparse.SUPPRESS)
    selector = parser.add_mutually_exclusive_group()
    selector.add_argument("--host", help="Select this declared SSH alias only; never fall back.")
    selector.add_argument("--local", action="store_true", help="Select this machine only; never fall back.")
    parser.add_argument("repo")
    parser.add_argument("file", type=Path)
    args = parser.parse_args()
    try:
        try:
            text = args.file.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise Refusal("file-unreadable", args.file, str(error)) from error
        try:
            settings = watch.config(args.bash, watch.home_root(Path.cwd()))
            host = settings["JARVIS_CONTROL_HOST"]
        except (OSError, ValueError, RuntimeError) as error:
            raise Refusal("settings-unreadable", "JARVIS_CONTROL_HOST", str(error)) from error
        if watch.role(settings).kind != "main":
            raise Refusal("role-satellite", settings["JARVIS_MAIN_HOST"])
        note = text.rstrip("\n") + "\n\n" + FOOTER + "\n"
        side, root, destination = deliver(args.bash, args.repo, note, settings, args.host, args.local)
    except Refusal as refusal:
        key, value = refusal.args[:2]
        detail = "".join("\n" + part for part in refusal.args[2:] if part)
        print("owner-note: %s=%s%s" % (key, value, detail), file=sys.stderr)
        return 2
    print("owner-note: sent side=%s root=%s destination=%s" % (side, root, destination))
    return 0


if __name__ == "__main__":
    sys.exit(main())
