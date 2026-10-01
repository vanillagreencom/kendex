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
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

from refusals import Refusal, keyed
from store import parse_at

LANE_MAIL = Path(".agents/skills/orch/scripts/lane-mail")
FIELD_CHOICES = {"box": ("to-overseer", "to-lane"), "kind": ("ask", "notice", "answer", "directive", "resolution")}


class LaneMail:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.script = root / LANE_MAIL
        self.reported_fields: Set[Tuple[str, str]] = set()
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
        """Validated envelopes from lane-mail; absent position metadata
        disables master-read suppression, never delivery of that envelope."""
        code, out, err = self._run("events", "--item", "overseer")
        if code != 0:
            raise Refusal("lane-mail-failed", err.strip() or _first(err))
        if err:
            sys.stderr.write(err)
        envelopes = []
        for raw in out.splitlines():
            if raw.strip():
                envelope = json.loads(raw)
                # lane-mail writes these fields; optional owner-channel fields
                # are checked here before routing or formatting consumes them.
                invalid = False
                for field in (
                    "id", "at", "box", "kind", "text", "from", "to", "ref", "re", "by", "attach", "recommend", "deadline", "mail_class"
                ):
                    required = field in ("id", "at", "box", "kind", "text") or field == "re" and envelope.get("kind") == "answer"
                    value = envelope.get(field)
                    if field not in envelope and not required:
                        continue
                    if not isinstance(value, str) or (field != "text" and required and not value):
                        self.bad_field(envelope.get("id"), field)
                        invalid = True
                    elif field in ("at", "deadline") and value:
                        try:
                            parse_at(value)
                        except ValueError:
                            self.bad_field(envelope.get("id"), field)
                            invalid = True
                    elif value not in FIELD_CHOICES.get(field, (value,)):
                        self.bad_field(envelope.get("id"), field)
                        invalid = True
                options = envelope.get("options", [])
                if not isinstance(options, list) or not all(isinstance(option, str) for option in options):
                    self.bad_field(envelope.get("id"), "options")
                    invalid = True
                if invalid:
                    continue
                # events filters invalid JSON rows, so its output index cannot
                # replace a physical line number supplied by lane-mail.
                for field in ("line", "count"):
                    value = envelope.get(field)
                    if type(value) is not int or value < 1:
                        self.bad_field(envelope["id"], field)
                        envelope[field] = None
                envelopes.append(envelope)
        return envelopes

    def bad_field(self, env_id: object, field: str) -> None:
        """One keyed system journal diagnostic per envelope field per process.
        Envelope bodies never enter the diagnostic."""
        env_id = env_id if isinstance(env_id, str) and env_id else "unknown"
        pair = (env_id, field)
        if pair not in self.reported_fields:
            self.reported_fields.add(pair)
            print(keyed("envelope-field", f"{self.root} id={env_id} field={field}"), file=sys.stderr, flush=True)

    def _text_file(self, text: str) -> str:
        directory = self.root / "tmp" / "slack"
        directory.mkdir(parents=True, exist_ok=True)
        handle = tempfile.NamedTemporaryFile("w", dir=str(directory), prefix="text-", suffix=".txt", delete=False)
        with handle:
            handle.write(text + "\n")
        return handle.name

    def send_directive(self, text: str, delivery_id: str, parent: Optional[Dict] = None) -> str:
        """Append an owner directive with its optional thread pointer.
        Returns the envelope id, including on a repeated delivery."""
        path = self._text_file(text)
        context = None
        try:
            context = self._text_file(json.dumps(parent)) if parent is not None else None
            pointer = ["--thread-ts", parent["ts"], "--parent", context] if parent is not None else []
            code, out, err = self._run(
                "send", "--item", "overseer", "--directive", "--delivery-id", delivery_id, "--file", path, *pointer
            )
        finally:
            os.unlink(path)
            if context is not None:
                os.unlink(context)
        if code == 0:
            return _field(out, "id=")
        first = _first(err)
        if first.startswith(f"lane-mail: delivery-repeated={delivery_id} id="):
            return first.rsplit("id=", 1)[1].strip()
        raise Refusal("lane-mail-failed", err.strip() or first)

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

    def answer(self, ask_id: str, text: str, delivery_id: str) -> Tuple[str, str]:
        """Deliver an answer without closing; the mailbox judges repeats
        before closure, so a replay never becomes a directive."""
        path = self._text_file(text)
        try:
            code, out, err = self._run(
                "send", "--item", "overseer", "--re", ask_id, "--file", path, "--delivery-id", delivery_id
            )
        finally:
            os.unlink(path)
        if code == 0:
            return "answered", _field(out, "id=")
        first = _first(err)
        if first.startswith(f"lane-mail: delivery-repeated={delivery_id} id="):
            return "answered", first.rsplit("id=", 1)[1].strip()
        if first.startswith(f"lane-mail: resolved-already={ask_id} id="):
            return "resolved-already", first.rsplit("id=", 1)[1].strip()
        raise Refusal("lane-mail-failed", err.strip() or first)


def _first(text: str) -> str:
    return text.splitlines()[0] if text.strip() else "(no output)"


def _field(receipt: str, marker: str) -> str:
    for word in receipt.split():
        if word.startswith(marker):
            return word[len(marker):]
    raise Refusal("lane-mail-failed", f"receipt without {marker}: {_first(receipt)}")
