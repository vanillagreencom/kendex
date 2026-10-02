"""The verbs beside `listen`: setup, post, compact, install and status."""

from __future__ import annotations

import itertools
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Optional

from api import Slack, markdown_checked
from markup import outbound, plain
from refusals import Refusal, keyed, notice
from relay import LAUNCHER, RECONNECT_BOUND_SECONDS, mention, resolve_owner_ids
from secret import check as secret_check
from secret import checked_file
from settings import Settings, load
from store import Binding, RelayLock, compact, format_at, journal_exists, parse_at, read_binding, read_status, write_binding

UNIT = "slack-listen.service"
# Seconds between the restart and the read of the unit's state: long
# enough for a relay refusing its settings or its binding to have exited.
START_WAIT_SECONDS = 2
UNIT_TEMPLATE = Path(__file__).resolve().parents[2] / "systemd" / UNIT
CHANNEL_NAME = re.compile(r"[^a-z0-9_-]+")
TOLERATED_INVITE = {"already_in_channel", "cant_invite_self"}


def default_channel_name(root: Path, owner: str) -> str:
    local = owner.split("@", 1)[0]
    return CHANNEL_NAME.sub("-", f"{root.name}-{local}".lower()).strip("-")[:80]


def api_for(settings: Settings) -> Slack:
    return Slack(settings.token, settings.api_url)


def setup(root: Path, name: Optional[str], take: Optional[str]) -> int:
    # The relay a setup restarts starts with SLACK_APP_TOKEN or exits, so a
    # setup that would restart one refuses without it before anything runs.
    settings = load(need_app_token=unit_stands())
    api = api_for(settings)
    ids = resolve_owner_ids(api, settings.owners)
    if take:
        info = api.get("conversations.info", channel=take)["channel"]
        if not info.get("is_private"):
            raise Refusal("slack-channel-public", f"{take} fix=take a private channel, or run setup without --take")
        if not info.get("is_member"):
            raise Refusal("slack-channel-unjoined", f"{take} fix=invite the app to the channel, then run setup again")
        channel, channel_name = str(info["id"]), str(info.get("name", take))
    else:
        channel_name = name or default_channel_name(root, settings.owners[0])
        found = None
        for item in api.paged("conversations.list", "channels", types="private_channel", exclude_archived="true"):
            if item.get("name") == channel_name:
                found = item
                break
        if found is not None:
            if not found.get("is_member", True):
                raise Refusal("slack-channel-unjoined", f"{found['id']} fix=invite the app to #{channel_name}, then run setup again")
            channel = str(found["id"])
        else:
            channel = str(api.post("conversations.create", name=channel_name, is_private=True)["channel"]["id"])
    try:
        api.post("conversations.invite", channel=channel, users=",".join(ids.values()))
    except Refusal as err:
        if err.key != "slack-api-failed":
            raise
        if err.error not in TOLERATED_INVITE:
            raise Refusal(
                "slack-invite-refused",
                f"{channel} error={err.error} owners={','.join(ids)}"
                f" fix=invite the owners to #{channel_name} in Slack, then run setup again",
            ) from err
    bound_before = read_binding(root) if journal_exists(root) else None
    if bound_before is not None and bound_before.channel != channel:
        raise Refusal(
            "channel-changed",
            f"{root} channel={bound_before.channel} new={channel}"
            " fix=stop the relay and move tmp/slack/journal.jsonl aside, then run setup again",
        )
    write_binding(root, Binding(channel, channel_name, bound_before.bound_at if bound_before else f"{time.time():.6f}", list(settings.owners), ids))
    notice("bound", f"{channel} root={root} name={channel_name} owners={len(ids)}")
    restart_unit()
    return 0


def unit_stands() -> bool:
    """Whether the unit `install` wrote stands and systemctl can reach it."""
    return (unit_dir() / UNIT).is_file() and shutil.which("systemctl") is not None


def restart_unit() -> None:
    """A relay reads its settings at start, so a setup restarts the unit
    `install` wrote, where `unit_stands`."""
    if not unit_stands():
        return
    proc = subprocess.run(["systemctl", "--user", "try-restart", UNIT], check=False)
    if proc.returncode != 0:
        raise Refusal("systemctl-failed", f"systemctl --user try-restart {UNIT} exit={proc.returncode}")
    notice("restarted", UNIT)


def post(
    root: Path,
    channel: Optional[str],
    text: Optional[str],
    file: Optional[str],
    mention_owners: bool,
    thread: Optional[str],
    update: Optional[str],

) -> int:
    settings = load(need_owners=False)
    api = api_for(settings)
    binding = None
    if channel is None or mention_owners:
        try:
            binding = read_binding(root)
        except Refusal:
            if channel is None:
                raise
    channel = channel or binding.channel
    prefix = ""
    if mention_owners:
        if binding is not None and binding.owner_ids:
            prefix = mention(binding) + " "
        else:
            owners = load().owners
            prefix = " ".join(f"<@{i}>" for i in resolve_owner_ids(api, owners).values()) + " "
    body = prefix + (text or (Path(file).name if file else ""))
    body, body_arg = outbound(root, body, file_comment=bool(file), fallback=False)
    secret_check(body.encode(), "text")
    if file:
        data = checked_file(file, f"file={file}")
        file_id = api.upload(Path(file).name, data, channel, body, thread)
        notice("uploaded", f"{file_id} channel={channel}")
        return 0
    if body_arg == "markdown_text":
        markdown_checked(body, "text")
    if update:
        api.post("chat.update", channel=channel, ts=update, **{body_arg: body})
        notice("updated", f"{update} channel={channel}")
        return 0
    answer = api.post("chat.postMessage", channel=channel, **{body_arg: body}, thread_ts=thread)
    notice("posted", f"{answer['ts']} channel={channel}")
    return 0


def thread(root: Path, ts: str, limit: Optional[int]) -> int:
    """Print an explicitly requested thread, oldest first, as plain text."""
    settings = load(need_owners=False)
    api = api_for(settings)
    messages = api.paged("conversations.replies", "messages", channel=read_binding(root).channel, ts=ts)
    selected = itertools.islice(messages, limit) if limit is not None else messages
    for message in sorted(selected, key=lambda m: float(m["ts"])):
        print(plain(str(message.get("text") or ""), lambda user: user))
    return 0


def compact_roots(roots: List[Path]) -> int:
    """Every root's relay lock is held from before its read until the verb
    exits, so a running relay refuses it and no append of the relay's lands
    on a replaced file. The relay compacts under its own lock."""
    settings = load(need_token=False, need_owners=False)
    cutoff = settings.horizon(time.time())
    locks = [RelayLock(root) for root in roots]
    for lock in locks:
        lock.acquire()
    for root in roots:
        dropped = compact(root, cutoff)
        notice("compacted", f"{root} dropped={dropped}")
    return 0


def unit_dir() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME", "").strip() or str(Path.home() / ".config")
    return Path(base) / "systemd" / "user"


def install(roots: List[Path], print_only: bool) -> int:
    for root in roots:
        read_binding(root)
    template = UNIT_TEMPLATE.read_text()
    exec_line = " ".join([str(LAUNCHER), "listen", *[f"--root {r}" for r in roots]])
    unit = template.replace("@EXEC_START@", exec_line).replace("@WORKING_DIRECTORY@", str(roots[0]))
    if print_only:
        sys.stdout.write(unit)
        return 0
    target = unit_dir() / UNIT
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(unit)
    except OSError as err:
        raise Refusal("unit-unwritable", f"{target} ({err.strerror})") from err
    notice("installed", str(target))
    if shutil.which("systemctl") is None:
        raise Refusal(
            "systemctl-missing",
            f"run: systemctl --user daemon-reload && systemctl --user enable {UNIT} && systemctl --user restart {UNIT}",
        )
    # `restart` starts a stopped unit and replaces a running one, so a
    # reinstall that adds a root is served by a relay on the new ExecStart;
    # `enable --now` would leave a running relay on the old one.
    for args in (["daemon-reload"], ["enable", UNIT], ["restart", UNIT]):
        proc = subprocess.run(["systemctl", "--user", *args], check=False)
        if proc.returncode != 0:
            raise Refusal("systemctl-failed", f"systemctl --user {' '.join(args)} exit={proc.returncode}")
    notice("enabled", UNIT)
    # A simple unit's restart returns once the relay is forked, so a relay that
    # refuses at start is seen only by asking again after it had time to exit.
    time.sleep(START_WAIT_SECONDS)
    proc = subprocess.run(["systemctl", "--user", "is-active", UNIT], stdout=subprocess.PIPE, text=True, check=False)
    state = proc.stdout.strip() or f"exit={proc.returncode}"
    if state != "active":
        raise Refusal("unit-inactive", f"{UNIT} state={state} fix=journalctl --user -u {UNIT}")
    notice("active", UNIT)
    return 0


def status(roots: List[Path], now: float) -> int:
    for root in roots:
        record = read_status(root)
        if record is None:
            print(keyed("slack-relay", f"{root} state=never fix=start the relay with `slack listen --root {root}`"))
            continue
        age = now - float(record["last_poll"])
        fresh = age <= 2 * int(record["poll_seconds"]) + 5
        # A connect refused past the bound keeps owner messages from
        # arriving though every poll succeeds.
        link_error = record["connection_error"]
        if record["connection"] == "reconnecting" and now - parse_at(record["connection_since"]) <= RECONNECT_BOUND_SECONDS:
            link_error = ""
        if not fresh:
            state, fix = "stale", " fix=restart the relay and read its last lines"
        elif not record["last_poll_ok"]:
            state, fix = "failing", f" fix={record.get('last_error') or 'read the relay log'}"
        elif link_error:
            state, fix = "failing", f" fix={link_error}"
        else:
            state, fix = "ok", ""
        # A stale record's relay is gone, whatever connection it recorded.
        if fresh:
            connection, since = record["connection"], record["connection_since"]
        else:
            connection, since = "disconnected", format_at(float(record["last_poll"]))
        unknown = record.get("unknown") or []
        held = f" held-by={record['held_by']}" if record.get("held_by") else ""
        print(
            keyed(
                "slack-relay",
                f"{root} state={state} channel={record['channel']} code={record.get('code') or '-'} last_poll_age={int(age)}s"
                f" connection={connection} connection_since={since}"
                f" last_delivered_ts={record.get('last_delivered_ts') or '-'}"
                f" open_asks={len(record.get('open_asks') or [])} oldest_unknown={unknown[0] if unknown else '-'}"
                f" refused={len(record.get('refused') or [])} calls_last_minute={record.get('calls_last_minute', 0)}"
                f"{held}{fix}",
            )
        )
    return 0
