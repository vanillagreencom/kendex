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

A file download is no API method: Slack answers it with the file, an HTTP
status, or, when the app lacks `files:read`, its sign-in page with 200. A
body that ends short of its Content-Length reads as a clean end in
http.client, so the download counts the bytes itself. A chunked body cut
short raises http.client's own `HTTPException`. The download refuses it as
`file-not-fetched`; an API response cut short is `slack-response-lost`.
"""

from __future__ import annotations

import http.client
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from typing import BinaryIO, Callable, Deque, Dict, Optional

from refusals import Refusal

# Slack's answers that no retry mends, since the token itself is wrong;
# not_allowed_token_type is a token of another type under the setting, such
# as an app-level token in SLACK_BOT_TOKEN.
AUTH_ERRORS = {
    "invalid_auth",
    "not_authed",
    "account_inactive",
    "token_revoked",
    "token_expired",
    "not_allowed_token_type",
}
RETRIES = 3
TIMEOUT_SECONDS = 30
COPY_BYTES = 64 * 1024
# The cap chat.postMessage and chat.update put on `markdown_text`.
MARKDOWN_LIMIT = 12000


def markdown_checked(text: str, what: str) -> None:
    """Refuses a `markdown_text` body, the argument Slack renders as
    standard Markdown, past MARKDOWN_LIMIT characters: `text-too-long`
    naming `what`, before any call."""
    if len(text) > MARKDOWN_LIMIT:
        raise Refusal("text-too-long", f"{what} chars={len(text)} limit={MARKDOWN_LIMIT}")


class Slack:
    def __init__(
        self,
        token: str,
        base_url: str,
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
        token_name: str = "SLACK_BOT_TOKEN",
        scope: str = "",
    ) -> None:
        self.token = token
        # The setting a refused token is named by in the refusal's fix=.
        self.token_name = token_name
        # The one scope every call of this client needs, `connections:write`
        # for the app-level token: Slack's missing_scope then refuses the
        # token. Empty for the bot token, whose missing scope refuses one
        # method alone.
        self.scope = scope
        self.base_url = base_url.rstrip("/")
        self.clock = clock
        self.sleep = sleep
        self.calls: Deque[float] = deque()

    def calls_last_minute(self) -> int:
        now = self.clock()
        while self.calls and self.calls[0] < now - 60:
            self.calls.popleft()
        return len(self.calls)

    def _open(self, req: urllib.request.Request, label: str, read: Callable = lambda resp: resp.read()):
        """One counted exchange, its response handed to `read`, the body
        whole by default. `HTTPError` is the caller's to judge; a network
        failure takes its key by the rule above."""
        self.calls.append(self.clock())
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
                return read(resp)
        except urllib.error.HTTPError:
            raise
        except urllib.error.URLError as err:
            raise Refusal("slack-unreachable", f"{label} ({err.reason})") from err
        except (OSError, http.client.HTTPException) as err:
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
            if error in AUTH_ERRORS or error == "missing_scope" and self.scope:
                held = f" with {self.scope}" if self.scope else ""
                raise Refusal("slack-auth-failed", f"{error} fix=set a live {self.token_name}{held} and restart the relay")
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

    def download(self, url: str, size: Optional[int], out: BinaryIO) -> None:
        """A message's file from its `url_private_download`, streamed into
        `out`; `size` is the byte count the message's `files[]` entry gives,
        None when it gives none. Refused `file-not-fetched` with the HTTP
        status, with the bytes of a body that ended short of its
        Content-Length, with http.client's error on a chunked body cut
        short, or with the sign-in page Slack sends in place of the file: an
        HTML answer of any length but `size`, so an HTML file the owner sent
        is saved whatever its type, and one of unknown size is not. The key
        has no EXPLAIN entry: `Relay.fetch_files` writes its value into the
        message and never prints it."""

        def copy(resp) -> None:
            declared = resp.headers.get("Content-Length")
            copied = 0
            try:
                while True:
                    chunk = resp.read(COPY_BYTES)
                    if not chunk:
                        break
                    out.write(chunk)
                    copied += len(chunk)
            except http.client.HTTPException as err:
                raise Refusal("file-not-fetched", f"download ({err})") from err
            if declared is not None and declared.strip().isdigit() and copied != int(declared):
                raise Refusal("file-not-fetched", f"truncated {copied} of {declared.strip()} bytes")
            if resp.headers.get_content_type() == "text/html" and copied != size:
                raise Refusal("file-not-fetched", f"HTTP {resp.status} sign-in page, the app needs files:read")

        req = urllib.request.Request(url)
        req.add_header("Authorization", f"Bearer {self.token}")
        try:
            self._open(req, "download", copy)
        except urllib.error.HTTPError as err:
            raise Refusal("file-not-fetched", f"HTTP {err.code}") from err


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
