"""The mailbox, read and written through the root's own lane-mail alone.

The relay keys every delivery it makes with `--delivery-id channel:ts`. Its
journal skips a stamp it already carried; for any stamp the journal lost,
the crash between the append and the mark, the mailbox's locked
check-and-append is the judge: a repeat of a key that landed is answered
with the envelope it landed as, and the relay records that id exactly as it
records a first landing.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Dict, List, Set, Tuple

from refusals import Refusal

LANE_MAIL = Path(".agents/skills/orch/scripts/lane-mail")


class LaneMail:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.script = root / LANE_MAIL
        if not os.access(self.script, os.X_OK):
            raise Refusal("orch-missing", str(root))

    def _run(self, *args: str) -> Tuple[int, str, str]:
        proc = subprocess.run(
            [str(self.script), *args],
            cwd=str(self.root),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr

    def events(self) -> List[Dict]:
        code, out, err = self._run("events", "--item", "overseer")
        if code != 0:
            raise Refusal("lane-mail-failed", _first(err))
        envelopes = []
        for raw in out.splitlines():
            if raw.strip():
                envelopes.append(json.loads(raw))
        return envelopes

    def _text_file(self, text: str) -> str:
        directory = self.root / "tmp" / "slack"
        directory.mkdir(parents=True, exist_ok=True)
        handle = tempfile.NamedTemporaryFile("w", dir=str(directory), prefix="text-", suffix=".txt", delete=False)
        with handle:
            handle.write(text + "\n")
        return handle.name

    def send_directive(self, text: str, delivery_id: str) -> str:
        """Append an owner directive; returns the envelope id it landed as,
        whether on this call or on the earlier one this key repeats."""
        path = self._text_file(text)
        try:
            code, out, err = self._run(
                "send", "--item", "overseer", "--directive", "--delivery-id", delivery_id, "--file", path
            )
        finally:
            os.unlink(path)
        if code == 0:
            return _field(out, "id=")
        first = _first(err)
        if first.startswith(f"lane-mail: delivery-repeated={delivery_id} id="):
            return first.rsplit("id=", 1)[1].strip()
        raise Refusal("lane-mail-failed", first)

    def read_directives(self) -> Set[str]:
        """The ids of the directives the overseer has read: those on a line
        at or below to-lane.cursor, as `drain --receipts` lists them. A
        cursor it reports `missed` has read none."""
        code, out, err = self._run("drain", "--item", "overseer", "--after", "0", "--receipts")
        if code != 0:
            raise Refusal("lane-mail-failed", _first(err))
        lines = out.splitlines()
        header = next((i for i, raw in enumerate(lines) if raw.startswith("receipts cursor=")), None)
        if header is None:
            raise Refusal("lane-mail-failed", f"drain without receipts: {_first(out)}")
        cursor = lines[header].split()[1][len("cursor="):]
        if cursor == "missed":
            return set()
        read = set()
        for raw in lines[header + 1:]:
            number, env_id = raw.split()[:2]
            if int(number) <= int(cursor):
                read.add(env_id)
        return read

    def resolve(self, ask_id: str, text: str, delivery_id: str) -> Tuple[str, str]:
        """Close an owner ask; returns ("resolved", answer id) or
        ("resolved-already", the answer that already stands)."""
        path = self._text_file(text)
        try:
            code, out, err = self._run(
                "resolve", "--item", "overseer", "--id", ask_id, "--text", path, "--delivery-id", delivery_id
            )
        finally:
            os.unlink(path)
        if code == 0:
            return "resolved", _field(out, "answer=")
        first = _first(err)
        if first.startswith(f"lane-mail: resolved-already={ask_id} id="):
            return "resolved-already", first.rsplit("id=", 1)[1].strip()
        raise Refusal("lane-mail-failed", first)


def _first(text: str) -> str:
    return text.splitlines()[0] if text.strip() else "(no output)"


def _field(receipt: str, marker: str) -> str:
    for word in receipt.split():
        if word.startswith(marker):
            return word[len(marker):]
    raise Refusal("lane-mail-failed", f"receipt without {marker}: {_first(receipt)}")
