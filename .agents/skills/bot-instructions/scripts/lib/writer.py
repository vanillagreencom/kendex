"""The write phase: the marker gate, then atomic replacement.

Every replacement is temp-write-then-rename, so an interrupt leaves the old
bytes and never a truncated file. That matters most for `AGENTS.md`, the
doctrine root three of the five bots read.
"""

import os

from . import fsutil, marker as marker_mod
from .constants import MARKER_TOKEN
from .errors import RenderError


def replace(root, rel, data=None, transform=None, require_marker=True):
    """Replace `rel` with `data`, atomically, behind the marker gate.

    `transform` is the read-modify-write form: it is handed the file's current
    text, or None when the path is absent, and returns the bytes to write, or
    None to leave the file alone. Any ownership decision that content settles
    belongs inside it. Returns True when a write happened.

    Exactly one of `data` and `transform`. Neither is a caller that would
    write None; both is `data` silently dropped by the transform branch.
    """
    if (data is None) == (transform is None):
        raise RenderError(
            f"{rel}: writer.replace takes exactly one of data= and transform=; "
            f"got {'neither' if data is None else 'both'}"
        )
    existing = fsutil.read_text(root, rel)
    if require_marker and existing is not None and not marker_mod.owns(rel, existing):
        raise RenderError(
            f"{rel}: its first line is not the {MARKER_TOKEN!r} marker, so it is the "
            "repo's own file and render will not replace it — run `adopt` to take it "
            "over. A quotation of the marker, a denial of it, or a line that merely "
            "holds the words is the repo saying something about this package"
        )
    if transform is not None:
        data = transform(existing)
        if data is None:
            return False
    if isinstance(data, str):
        data = data.encode("utf-8")
    target = os.path.join(root, rel)
    parent = os.path.dirname(target)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = f"{target}.bot-instructions-tmp.{os.getpid()}"
    try:
        with open(tmp, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, target)
    except BaseException:
        # Every exit that is not the rename removes the temp file, so a re-run
        # is not refused by the debris of the run before it.
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return True
