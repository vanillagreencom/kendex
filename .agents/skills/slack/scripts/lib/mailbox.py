"""Mailbox reads use the root's mailbox store; writes use its lane-mail.

The relay keys every delivery it makes with `--delivery-id channel:ts`. Its
journal skips a stamp it already carried; for any stamp the journal lost,
the crash between the append and the mark, the mailbox's locked
check-and-append is the judge: a repeat of a key that landed is answered
with the envelope it landed as, and the relay records that id exactly as it
records a first landing.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

from refusals import Refusal, keyed
from store import parse_at

LANE_MAIL = Path(".agents/skills/mailbox/scripts/lane-mail")
MAILBOX_READ_FILES = (
    LANE_MAIL.parent / "lib" / "lane-mail-store.py",
    LANE_MAIL.parent / "lib" / "mailbox-append.sh",
    LANE_MAIL.parent / "lib" / "common-root.sh",
)
LANE_MAIL_TIMEOUT_SECONDS = 30
LANE_MAIL_CLEANUP_SECONDS = 5
FIELD_CHOICES = {"box": ("to-overseer", "to-lane"), "kind": ("ask", "notice", "answer", "directive", "resolution")}


class LaneMail:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.script = root / LANE_MAIL
        self.reported_fields: Set[Tuple[str, str]] = set()
        self.reader = None
        self.snapshots: Dict = {}
        self.jq_defs = ""
        self.box: Optional[Path] = None
        if not os.access(self.script, os.X_OK):
            raise Refusal("orch-missing", str(root))

    def _run(self, *args: str) -> Tuple[int, str, str]:
        proc = subprocess.Popen(
            [str(self.script), *args],
            cwd=str(self.root),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            out, err = proc.communicate(timeout=LANE_MAIL_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired as err:
            # lane-mail owns the directory mutex. TERM must reach its waiting
            # guard too, so the shell can run the lock owner's release handler.
            try:
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    try:
                        os.killpg(proc.pid, sig)
                    except ProcessLookupError:
                        # The group can finish between the timeout and signal.
                        if proc.poll() is None:
                            raise
                    try:
                        proc.communicate(timeout=LANE_MAIL_CLEANUP_SECONDS)
                        break
                    except subprocess.TimeoutExpired:
                        if sig == signal.SIGKILL:
                            # Do not wait for pipes held outside the owned group.
                            proc.wait(timeout=LANE_MAIL_CLEANUP_SECONDS)
            finally:
                proc.stdout.close()
                proc.stderr.close()
            raise Refusal("lane-mail-failed", f"timeout={LANE_MAIL_TIMEOUT_SECONDS} command={args[0]}") from err
        return proc.returncode, out, err

    def _read_events(self, receipts: bool = False) -> Tuple[List[Dict], Optional[Tuple[int, Set[str]]]]:
        deadline = time.monotonic() + LANE_MAIL_TIMEOUT_SECONDS
        if self.reader is None:
            path = self.root / MAILBOX_READ_FILES[0]
            spec = importlib.util.spec_from_file_location("lane_mail_store", path)
            module = importlib.util.module_from_spec(spec)
            try:
                spec.loader.exec_module(module)
            except OSError as error:
                raise Refusal("orch-missing", str(path)) from error
            reader = getattr(module, "read_events", None)
            if not callable(reader):
                raise Refusal("lane-mail-failed", f"reader=read_events file={path}")
            shell = shutil.which("bash")
            if shell is None:
                raise Refusal("lane-mail-failed", "command-missing=bash")
            definitions = subprocess.run(
                [shell, "-c", 'set -euo pipefail; . "$1"; . "$2"; '
                 'mailbox_root="$(mailbox_common_root "$3")"; '
                 'printf "%s\\0%s" "$mailbox_root" "$MAILBOX_CLASS_JQ$OWNER_TRACKER_JQ"',
                 "mailbox-definitions", str(self.root / MAILBOX_READ_FILES[1]),
                 str(self.root / MAILBOX_READ_FILES[2]), str(self.root)],
                capture_output=True, text=True, timeout=max(0, deadline - time.monotonic()),
            )
            if definitions.returncode != 0:
                raise Refusal("lane-mail-failed", definitions.stderr.strip())
            # Overseer mail belongs to the main checkout; reader code and
            # relay state belong to the bound checkout. NUL preserves paths
            # containing newlines without splitting the shared definitions.
            mailbox_root, self.jq_defs = definitions.stdout.split("\0", 1)
            self.box = Path(mailbox_root) / "tmp" / "lane-mail" / "overseer"
            self.reader = reader
        try:
            return self.reader(self.box, self.jq_defs, self.snapshots,
                               receipts=receipts, timeout=max(0, deadline - time.monotonic()))
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            raise Refusal("lane-mail-failed", str(error)) from error

    def events(self) -> List[Dict]:
        """Validated envelopes from the mailbox store; absent position metadata
        disables Jarvis-read suppression, never delivery of that envelope."""
        rows, _ = self._read_events()
        envelopes = []
        for envelope in rows:
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
            draft = envelope.get("draft")
            if "draft" in envelope and not (
                isinstance(draft, dict) and all(isinstance(draft.get(key), str) and draft[key] for key in ("recipient", "medium", "text"))
            ):
                self.bad_field(envelope.get("id"), "draft")
                invalid = True
            if invalid:
                continue
            if "tracker_posted" in envelope and type(envelope["tracker_posted"]) is not bool:
                self.bad_field(envelope.get("id"), "tracker_posted")
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

    def read_receipts(self) -> Tuple[int, Set[str]]:
        """The mailbox store's read cursor and directives at or below it.
        Directive ids also judge older producers without line metadata.
        A missed cursor has read none."""
        _, receipts = self._read_events(receipts=True)
        assert receipts is not None, "the mailbox store must return requested receipts"
        return receipts

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
