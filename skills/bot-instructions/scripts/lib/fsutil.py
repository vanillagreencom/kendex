"""Reads under the repo root, and the one decode.

Paths are ordinary joins under a root the caller already resolved.
"""

import os

from .errors import RenderError


def read_file(root, rel):
    """Bytes at `rel`, or None when it is absent."""
    try:
        with open(os.path.join(root, rel), "rb") as fh:
            return fh.read()
    except (FileNotFoundError, IsADirectoryError, NotADirectoryError):
        return None


def decode_text(raw, rel):
    """The one decode. A lossy read would make the run report on bytes the
    repo does not hold, and would write a substituted character back through
    every read-modify-write."""
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RenderError(f"{rel}: is not UTF-8 ({exc.reason})") from exc


def read_text(root, rel):
    raw = read_file(root, rel)
    if raw is None:
        return None
    return decode_text(raw, rel)


def walk(root, rel):
    """Every regular file below `rel`, repo-relative, sorted.

    A symlinked directory is not descended into: `orphan` sweeps trees named
    by the tree under judgment, and a symlinked directory there is a read out
    of the repo.
    """
    out = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, rel)):
        dirnames.sort()
        prefix = os.path.relpath(dirpath, root).replace(os.sep, "/")
        out.extend(f"{prefix}/{name}" for name in filenames)
    return sorted(out)
