"""Process settings and each root's master presence settings.

Both use kendex's one settings reader. A root load starts from the caller's
original environment, not the launch checkout's loaded exports.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Mapping, Optional

from refusals import Refusal, keyed

DEFAULT_API_URL = "https://slack.com/api"
DEFAULT_POLL_SECONDS = 15
DEFAULT_THREAD_DAYS = 7
DEFAULT_MASTER_MAX_AGE = 600
# The name `listen --status` shows for the presence SLACK_MASTER_FILE marks.
MASTER = "master"
EMAIL = re.compile(r"^[^\s@,]+@[^\s@,]+$")
# Direct library callers have no launcher snapshot. Do not pass the internal
# transport on to lane-mail or the root settings subprocess.
CALLER_ENV = (
    json.loads(os.environ.pop("_KENDEX_SLACK_CALLER_ENV"))
    if "_KENDEX_SLACK_CALLER_ENV" in os.environ else dict(os.environ)
)
ROOT_ENV = r'''
set -euo pipefail
source "$1/scripts/lib/kendex-env.sh"
kendex_load_project_env "$2" || exit 1
export SLACK_MASTER_FILE="${SLACK_MASTER_FILE-}" SLACK_MASTER_MAX_AGE="${SLACK_MASTER_MAX_AGE-}"
exec "$3" -c 'import json, os, sys; print(json.dumps({name: os.environ.get(name, "") for name in sys.argv[1:]}))' SLACK_MASTER_FILE SLACK_MASTER_MAX_AGE
'''


@dataclass(frozen=True)
class Presence:
    """One root's hold file and freshness bound."""

    master_file: str
    master_max_age: int


@dataclass
class Settings:
    token: str
    app_token: str
    owners: List[str]
    poll_seconds: int
    thread_days: int
    api_url: str

    def horizon(self, now: float) -> float:
        """SLACK_THREAD_DAYS before `now`: the one age every judge of age reads."""
        return now - self.thread_days * 86400


def _positive_int(name: str, default: int, env: Mapping[str, str] = os.environ, root: Optional[Path] = None) -> int:
    raw = env.get(name, "").strip()
    if raw == "":
        return default
    if not raw.isdigit() or int(raw) < 1:
        where = f" root={root}" if root is not None else ""
        raise Refusal("setting-invalid", f"{name}={raw}{where}")
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


def user_handle() -> str:
    """The person whose overseer this is: KENDEX_USER_HANDLE, else the local
    part of KENDEX_USER_EMAIL. Never SLACK_OWNERS, which lists who is invited."""
    handle = os.environ.get("KENDEX_USER_HANDLE", "").strip()
    if handle:
        return handle
    email = os.environ.get("KENDEX_USER_EMAIL", "").strip()
    if email == "":
        raise Refusal("setting-missing", "KENDEX_USER_EMAIL")
    local = email.split("@", 1)[0]
    print(keyed("handle-from-email", local), file=sys.stderr, flush=True)
    return local


def load_presence(root: Path) -> Presence:
    """Read only the presence pair from this root, with caller precedence."""
    orch = os.environ.get("SLACK_ORCH_DIR", "")
    if not orch:
        raise Refusal("orch-missing", str(root))
    try:
        proc = subprocess.run(
            ["bash", "-c", ROOT_ENV, "slack-root-settings", orch, str(root), sys.executable],
            cwd=str(root), env=CALLER_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, check=False,
        )
    except OSError as err:
        raise Refusal("setting-invalid", f"root={root} settings-reader={err}") from err
    if proc.returncode != 0:
        raise Refusal("setting-invalid", f"root={root} settings-reader={proc.stderr.strip()}")
    try:
        values = json.loads(proc.stdout)
    except ValueError as err:
        raise Refusal("setting-invalid", f"root={root} settings-reader=invalid-output") from err
    path = os.path.expanduser(values["SLACK_MASTER_FILE"].strip())
    if path and not os.path.isabs(path):
        path = str(root / path)
    return Presence(
        master_file=path,
        master_max_age=_positive_int("SLACK_MASTER_MAX_AGE", DEFAULT_MASTER_MAX_AGE, values, root),
    )


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
    )
