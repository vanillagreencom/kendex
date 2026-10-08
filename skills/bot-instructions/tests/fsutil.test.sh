#!/usr/bin/env bash
# Pull request checkouts can put special-file links in the orphan scan.
# A parent deadline bounds both open and read; a memory limit contains the
# original /dev/zero read in the disposable current-read control.

. "$(dirname "$0")/lib/harness.sh"
case "$(uname -s)" in MINGW* | MSYS*) export MSYS=winsymlinks:nativestrict ;; esac

repo="$(bi_rendered_repo fsutil)" || exit 1
current_read="$(bi_mutant fsutil-current-read scripts/lib/fsutil.py \
  '        fd = os.open(os.path.join(root, rel), os.O_RDONLY | getattr(os, "O_NONBLOCK", 0))' \
  '        with open(os.path.join(root, rel), "rb") as fh:
            return fh.read()')" || exit 1
blocking_open="$(bi_mutant fsutil-blocking-open scripts/lib/fsutil.py \
  'os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)' 'os.O_RDONLY')" || exit 1

if python3 - "$BI_ROOT/skills/bot-instructions" "$repo" "$current_read" "$blocking_open" <<'PY'; then
import os
from pathlib import Path
import subprocess
import sys

package, root, current_read, blocking_open = map(Path, sys.argv[1:])
rel = ".github/instructions/old.instructions.md"
link = root / rel
target = root / "retired.md"
target.write_bytes((root / ".github/instructions/code-review.md").read_bytes())
fifo = root / "input.fifo"
os.mkfifo(fifo)
assert Path("/dev/zero").is_char_device(), "/dev/zero is required by this probe"

# Only the child reads the potentially blocking path. No FIFO writer exists.
# The child selects the environment it needs for Python and git discovery.
child = """
import resource
import sys
resource.setrlimit(resource.RLIMIT_AS, (256 * 1024 * 1024, 256 * 1024 * 1024))
sys.path.insert(0, sys.argv[1])
from lib import cli
sys.exit(cli.main(["check", "--repo", sys.argv[2]]))
"""
env = {key: os.environ[key] for key in ("PATH", "SYSTEMROOT") if key in os.environ}
env["PYTHONDONTWRITEBYTECODE"] = "1"

def check(scripts):
    try:
        done = subprocess.run(
            [sys.executable, "-c", child, str(scripts), str(root)],
            capture_output=True, text=True, env=env, timeout=5,
        )
    except subprocess.TimeoutExpired:
        return None, "deadline"
    first = done.stderr.splitlines()
    return done.returncode, first[0] if first else ""

def refused(result):
    return result == (2, f"bot-instructions: source={root.resolve()}")

# A clean starting tree rules out an unrelated unreadable source. The
# regular link must produce an orphan finding, which proves its bytes read.
assert check(package / "scripts")[0] == 0, "fixture does not check clean"
for kind, destination in (("regular", target), ("device", Path("/dev/zero")), ("fifo", fifo)):
    link.symlink_to(destination)
    assert link.is_symlink(), f"{kind}: fixture did not create a link"
    try:
        actual = check(package / "scripts")
        if kind == "regular":
            assert actual == (1, "bot-instructions: findings=1"), actual
        else:
            assert refused(actual), (kind, actual)
            control = check(current_read.parent)
            assert not refused(control), (kind, "current-read control survived", control)
            print(f"control: {kind} current read rejected: {control}")
            if kind == "fifo":
                control = check(blocking_open.parent)
                assert control == (None, "deadline"), control
                print("control: FIFO blocking open reached the parent deadline")
        print(f"{kind}: scanned link met its result before the parent deadline")
    finally:
        link.unlink()

# Direct callers retain absence and regular bytes, and refuse directories.
sys.path.insert(0, str(package / "scripts"))
from lib.fsutil import read_file
from lib.errors import SourceUnavailable
assert read_file(root, "absent") is None
assert read_file(root, "retired.md/absent") is None
assert read_file(root, "retired.md") == target.read_bytes()
try:
    read_file(root, ".github/instructions")
except SourceUnavailable:
    pass
else:
    raise AssertionError("a directory was accepted as a file input")
PY
  ok 'scanned links refuse special targets and read regular targets'
else
  bad 'scanned links refuse special targets and read regular targets'
fi

bi_summary
