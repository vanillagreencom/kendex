"""The verbs beside `listen`: setup, post, compact, install and status."""

from __future__ import annotations

import datetime
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

from api import Slack
from refusals import Refusal, keyed, notice
from relay import mention, resolve_owner_ids
from secret import check as secret_check
from settings import Settings, load
from store import Binding, compact, read_binding, read_status, write_binding

UNIT = "slack-listen.service"
UNIT_TEMPLATE = Path(__file__).resolve().parents[2] / "systemd" / UNIT
LAUNCHER = Path(__file__).resolve().parents[1] / "slack"
CHANNEL_NAME = re.compile(r"[^a-z0-9_-]+")
TOLERATED_INVITE = {"already_in_channel", "cant_invite_self", "cant_invite"}


def default_channel_name(root: Path, owner: str) -> str:
    local = owner.split("@", 1)[0]
    return CHANNEL_NAME.sub("-", f"{root.name}-{local}".lower()).strip("-")[:80]


def api_for(settings: Settings) -> Slack:
    return Slack(settings.token, settings.api_url)


def setup(root: Path, name: Optional[str], take: Optional[str]) -> int:
    settings = load()
    api = api_for(settings)
    ids = resolve_owner_ids(api, settings.owners)
    if take:
        info = api.get("conversations.info", channel=take)["channel"]
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
        error = err.value.rsplit("error=", 1)[-1]
        if err.key != "slack-api-failed" or error not in TOLERATED_INVITE:
            raise
    write_binding(root, Binding(channel, channel_name, list(settings.owners), ids))
    notice("bound", f"{channel} root={root} name={channel_name} owners={len(ids)}")
    restart_unit()
    return 0


def restart_unit() -> None:
    """A relay reads its settings at start, so a setup restarts the unit
    `install` wrote, where one stands and systemctl can reach it."""
    if not (unit_dir() / UNIT).is_file() or shutil.which("systemctl") is None:
        return
    subprocess.run(["systemctl", "--user", "try-restart", UNIT], check=False)
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
    secret_check(body.encode(), "text")
    if update:
        api.post("chat.update", channel=channel, ts=update, text=body)
        notice("updated", f"{update} channel={channel}")
        return 0
    if file:
        try:
            data = Path(file).read_bytes()
        except OSError as err:
            raise Refusal("file-unreadable", file) from err
        secret_check(data, f"file={file}")
        file_id = api.upload(Path(file).name, data, channel, body, thread)
        notice("uploaded", f"{file_id} channel={channel}")
        return 0
    answer = api.post("chat.postMessage", channel=channel, text=body, thread_ts=thread)
    notice("posted", f"{answer['ts']} channel={channel}")
    return 0


def compact_roots(roots: List[Path]) -> int:
    settings = load(need_token=False, need_owners=False)
    cutoff = datetime.datetime.now(datetime.timezone.utc).timestamp() - settings.thread_days * 86400
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
        raise Refusal("systemctl-missing", f"run: systemctl --user daemon-reload && systemctl --user enable --now {UNIT}")
    for args in (["daemon-reload"], ["enable", "--now", UNIT]):
        proc = subprocess.run(["systemctl", "--user", *args], check=False)
        if proc.returncode != 0:
            raise Refusal("systemctl-failed", f"systemctl --user {' '.join(args)} exit={proc.returncode}")
    notice("enabled", UNIT)
    return 0


def status(roots: List[Path], now: float) -> int:
    settings = load(need_token=False, need_owners=False)
    total = 0.0
    for root in roots:
        record = read_status(root)
        if record is None:
            print(keyed("slack-relay", f"{root} state=never fix=start the relay with `slack listen --root {root}`"))
            continue
        age = now - float(record["last_poll"])
        fresh = age <= 2 * int(record["poll_seconds"]) + 5
        if fresh and record["last_poll_ok"]:
            state = "ok"
        elif fresh:
            state = "failing"
        else:
            state = "stale"
        fix = "" if state == "ok" else " fix=restart the relay and read its last lines"
        unknown = record.get("unknown") or []
        total += float(record.get("budget_per_minute", 0))
        print(
            keyed(
                "slack-relay",
                f"{root} state={state} channel={record['channel']} last_poll_age={int(age)}s"
                f" last_delivered_ts={record.get('last_delivered_ts') or '-'}"
                f" open_asks={len(record.get('open_asks') or [])} oldest_unknown={unknown[0] if unknown else '-'}"
                f" refused={len(record.get('refused') or [])} calls_last_minute={record.get('calls_last_minute', 0)}"
                f" budget_per_minute={record.get('budget_per_minute', 0)}{fix}",
            )
        )
    print(keyed("slack-relay-budget", f"{round(total, 1)} poll_seconds={settings.poll_seconds}"))
    return 0
