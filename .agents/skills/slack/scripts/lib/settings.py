"""The package's settings, read from the process environment.

The launcher loads the checkout's settings files into the environment through
kendex's one settings reader, so this module reads names and never files.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import List

from refusals import Refusal

DEFAULT_API_URL = "https://slack.com/api"
DEFAULT_POLL_SECONDS = 15
DEFAULT_THREAD_DAYS = 7
DEFAULT_MASTER_MAX_AGE = 600
# The name `listen --status` shows for the presence SLACK_MASTER_FILE marks.
MASTER = "master"
EMAIL = re.compile(r"^[^\s@,]+@[^\s@,]+$")


@dataclass
class Settings:
    token: str
    app_token: str
    owners: List[str]
    poll_seconds: int
    thread_days: int
    api_url: str
    master_file: str
    master_max_age: int

    def horizon(self, now: float) -> float:
        """SLACK_THREAD_DAYS before `now`: the one age every judge of age reads."""
        return now - self.thread_days * 86400


def _positive_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if raw == "":
        return default
    if not raw.isdigit() or int(raw) < 1:
        raise Refusal("setting-invalid", f"{name}={raw}")
    return int(raw)


def owners_from_env() -> List[str]:
    raw = os.environ.get("SLACK_OWNERS", "").strip()
    if raw == "":
        raw = os.environ.get("KENDEX_USER_EMAIL", "").strip()
    owners = [part.strip() for part in raw.split(",") if part.strip()]
    for owner in owners:
        if not EMAIL.match(owner):
            raise Refusal("setting-invalid", f"SLACK_OWNERS={owner}")
    return owners


def load(need_token: bool = True, need_owners: bool = True, need_app_token: bool = False) -> Settings:
    token = os.environ.get("SLACK_BOT_TOKEN", "").strip()
    app_token = os.environ.get("SLACK_APP_TOKEN", "").strip()
    owners = owners_from_env()
    missing = []
    if need_token and token == "":
        missing.append("SLACK_BOT_TOKEN")
    if need_app_token and app_token == "":
        missing.append("SLACK_APP_TOKEN")
    if need_owners and not owners:
        missing.append("SLACK_OWNERS")
    if missing:
        raise Refusal(
            "setting-missing", missing[0], *[("setting-missing", m) for m in missing[1:]]
        )
    return Settings(
        token=token,
        app_token=app_token,
        owners=owners,
        poll_seconds=_positive_int("SLACK_POLL_SECONDS", DEFAULT_POLL_SECONDS),
        thread_days=_positive_int("SLACK_THREAD_DAYS", DEFAULT_THREAD_DAYS),
        api_url=os.environ.get("SLACK_API_URL", "").strip() or DEFAULT_API_URL,
        master_file=os.path.expanduser(os.environ.get("SLACK_MASTER_FILE", "").strip()),
        master_max_age=_positive_int("SLACK_MASTER_MAX_AGE", DEFAULT_MASTER_MAX_AGE),
    )
