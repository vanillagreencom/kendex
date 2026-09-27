"""The Slack Web API client: one method per call, honouring 429.

Every call is counted with its time so `--status` can print the calls used
in the last minute. A 429 is honoured by `Retry-After` up to RETRIES times;
an `ok: false` answer names Slack's error; an auth error is its own key
because its remedy is a new token and nothing else.

A network failure is one of two keys, by where urllib raised it. urllib wraps
every error of the request phase, the connect, the TLS handshake and the
write of the body, in `URLError`: Slack never read the request, so the call
is `slack-unreachable` and is safe to make again. An error raised bare comes
from the response phase, after the request was written: Slack may have acted
on it, so the call is `slack-response-lost`. The relay journals an envelope
post lost this way as unknown and never repeats it; a read is made again on
the next poll.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from typing import Callable, Deque, Dict, Optional

from refusals import Refusal

AUTH_ERRORS = {"invalid_auth", "not_authed", "account_inactive", "token_revoked", "token_expired"}
RETRIES = 3
TIMEOUT_SECONDS = 30
AUTH_FIX = "fix=set a live SLACK_BOT_TOKEN and restart the relay"


class Slack:
    def __init__(
        self,
        token: str,
        base_url: str,
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.token = token
        self.base_url = base_url.rstrip("/")
        self.clock = clock
        self.sleep = sleep
        self.calls: Deque[float] = deque()

    def calls_last_minute(self) -> int:
        now = self.clock()
        while self.calls and self.calls[0] < now - 60:
            self.calls.popleft()
        return len(self.calls)

    def _open(self, req: urllib.request.Request, label: str) -> bytes:
        """One counted exchange and its body. `HTTPError` is the caller's to
        judge; a network failure takes its key by the rule above."""
        self.calls.append(self.clock())
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
                return resp.read()
        except urllib.error.HTTPError:
            raise
        except urllib.error.URLError as err:
            raise Refusal("slack-unreachable", f"{label} ({err.reason})") from err
        except OSError as err:
            raise Refusal("slack-response-lost", f"{label} ({err})") from err

    def _request(self, req: urllib.request.Request, method: str) -> Dict:
        for attempt in range(RETRIES + 1):
            try:
                body = self._open(req, method)
                break
            except urllib.error.HTTPError as err:
                if err.code == 429 and attempt < RETRIES:
                    retry_after = err.headers.get("Retry-After", "1")
                    self.sleep(float(retry_after) if retry_after.replace(".", "", 1).isdigit() else 1.0)
                    continue
                if err.code == 429:
                    raise Refusal("slack-rate-limited", method) from err
                raise Refusal("slack-api-failed", f"{method} http={err.code}") from err
        try:
            answer = json.loads(body)
        except ValueError as err:
            raise Refusal("slack-api-failed", f"{method} error=not-json") from err
        if not isinstance(answer, dict):
            raise Refusal("slack-api-failed", f"{method} error=not-object")
        if not answer.get("ok"):
            error = str(answer.get("error", "unknown"))
            if error in AUTH_ERRORS:
                raise Refusal("slack-auth-failed", f"{error} {AUTH_FIX}")
            raise Refusal("slack-api-failed", f"{method} error={error}", error=error)
        return answer

    def get(self, method: str, **params: object) -> Dict:
        query = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
        req = urllib.request.Request(f"{self.base_url}/{method}?{query}")
        req.add_header("Authorization", f"Bearer {self.token}")
        return self._request(req, method)

    def post(self, method: str, **body: object) -> Dict:
        data = json.dumps({k: v for k, v in body.items() if v is not None}).encode()
        req = urllib.request.Request(f"{self.base_url}/{method}", data=data, method="POST")
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Content-Type", "application/json; charset=utf-8")
        return self._request(req, method)

    def paged(self, method: str, key: str, **params: object):
        """Every item of a cursor-paginated method, page after page."""
        cursor: Optional[str] = None
        while True:
            answer = self.get(method, cursor=cursor, limit=200, **params)
            for item in answer.get(key, []):
                yield item
            cursor = (answer.get("response_metadata") or {}).get("next_cursor") or None
            if not cursor:
                return

    def upload(self, filename: str, data: bytes, channel: str, comment: str, thread_ts: Optional[str]) -> str:
        """The three-step external upload; returns the file id."""
        ticket = self.get("files.getUploadURLExternal", filename=filename, length=len(data))
        req = urllib.request.Request(ticket["upload_url"], data=data, method="POST")
        req.add_header("Content-Type", "application/octet-stream")
        try:
            self._open(req, "upload")
        except urllib.error.HTTPError as err:
            raise Refusal("slack-api-failed", f"upload http={err.code}") from err
        done = self.post(
            "files.completeUploadExternal",
            files=[{"id": ticket["file_id"], "title": filename}],
            channel_id=channel,
            initial_comment=comment,
            thread_ts=thread_ts,
        )
        files = done.get("files") or [{"id": ticket["file_id"]}]
        return str(files[0]["id"])
