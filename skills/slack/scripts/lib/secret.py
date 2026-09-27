"""The secret-value check every outbound text and file passes.

The pattern is the orch skill's `references/secret-value.ere`, read from the
orch install the launcher names in SLACK_ORCH_DIR, the one place the
package's layout is spelled. Its header fixes the reader: exactly one line
that is neither empty nor a comment, compiled case-insensitive and
multi-line over bytes. Zero or several such lines is a refusal, never an
empty pattern.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

from refusals import Refusal

ORCH_DIR = "SLACK_ORCH_DIR"


def pattern_file() -> Path:
    orch = os.environ.get(ORCH_DIR, "")
    if orch == "":
        raise Refusal("orch-missing", f"{ORCH_DIR} unset: run the package through scripts/slack")
    return Path(orch) / "references" / "secret-value.ere"


def pattern() -> "re.Pattern[bytes]":
    path = pattern_file()
    try:
        lines = path.read_bytes().split(b"\n")
    except OSError as err:
        raise Refusal("secret-pattern-invalid", f"{path} ({err.strerror})") from err
    candidates = [line for line in lines if line.strip() and not line.lstrip().startswith(b"#")]
    if len(candidates) != 1:
        raise Refusal("secret-pattern-invalid", f"{path} lines={len(candidates)}")
    return re.compile(candidates[0], re.I | re.M)


def check(data: bytes, what: str) -> None:
    """Refuse `what` when its bytes match the pattern anywhere."""
    if pattern().search(data):
        raise Refusal("secret-value", what)


def checked_file(path: str, what: str) -> bytes:
    """The bytes of a file to send: unreadable is `file-unreadable`, a match
    is `secret-value` naming `what`."""
    try:
        data = Path(path).read_bytes()
    except OSError as err:
        raise Refusal("file-unreadable", path) from err
    check(data, what)
    return data
