"""The secret-value check every outbound text and file passes.

The pattern is the orch skill's `references/secret-value.ere`, read from the
orch install beside this package. Its header fixes the reader: exactly one
line that is neither empty nor a comment, compiled case-insensitive and
multi-line over bytes. Zero or several such lines is a refusal, never an
empty pattern.
"""

from __future__ import annotations

import re
from pathlib import Path

from refusals import Refusal

PATTERN_FILE = Path(__file__).resolve().parents[3] / "orch" / "references" / "secret-value.ere"


def pattern() -> "re.Pattern[bytes]":
    try:
        lines = PATTERN_FILE.read_bytes().split(b"\n")
    except OSError as err:
        raise Refusal("secret-pattern-invalid", f"{PATTERN_FILE} ({err.strerror})") from err
    candidates = [line for line in lines if line.strip() and not line.lstrip().startswith(b"#")]
    if len(candidates) != 1:
        raise Refusal("secret-pattern-invalid", f"{PATTERN_FILE} lines={len(candidates)}")
    return re.compile(candidates[0], re.I | re.M)


def check(data: bytes, what: str) -> None:
    """Refuse `what` when its bytes match the pattern anywhere."""
    if pattern().search(data):
        raise Refusal("secret-value", what)
