#!/usr/bin/env python3
"""A fake Slack Web API for the suites: the methods the package calls, an
in-memory workspace, and a control surface under /_test/ the suites drive.

    fake_slack.py --port-file PATH --token TOKEN [--user EMAIL=ID]... [--page N]

Control: POST /_test/message injects a message and answers its ts; GET
/_test/state dumps messages, calls, uploads and posts; POST /_test/fault
makes the next `times` calls of `method` answer `error`, HTTP `status`, or
with `drop` close the connection after reading the request and before any
response, or with `refuse` redirect to a port nothing listens on, which the
client meets as a refused connection before its request is written.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import socketserver
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BOT = "UBOT"
BOT_ID = "B01"


class Workspace:
    def __init__(self, token: str, users: dict, page: int) -> None:
        self.token = token
        self.users = users  # email -> id
        self.page = page
        self.channels: dict = {}  # id -> {id, name, members, is_private}
        self.messages: dict = {}  # channel -> [message]
        self.uploads: dict = {}  # file id -> bytes
        self.calls: list = []
        self.faults: list = []
        self.counter = 0
        self.lock = threading.Lock()
        self.dead_port = dead_port()

    def next_ts(self) -> str:
        """Slack stamps are the current time; each one here is later than the
        last, so a suite's order is the stamps' order."""
        self.counter += 1
        self.last_ts = max(time.time(), getattr(self, "last_ts", 0.0) + 0.001)
        return f"{self.last_ts:.6f}"

    def channel_by_name(self, name: str):
        for channel in self.channels.values():
            if channel["name"] == name:
                return channel
        return None

    def add_message(self, channel: str, message: dict) -> dict:
        message.setdefault("ts", self.next_ts())
        message.setdefault("type", "message")
        thread_ts = message.get("thread_ts")
        self.messages.setdefault(channel, [])
        if thread_ts and thread_ts != message["ts"]:
            for parent in self.messages[channel]:
                if parent["ts"] == thread_ts:
                    parent["reply_count"] = parent.get("reply_count", 0) + 1
                    parent["latest_reply"] = message["ts"]
        self.messages[channel].append(message)
        return message

    def top_level(self, channel: str):
        return [m for m in self.messages.get(channel, []) if not m.get("thread_ts") or m["thread_ts"] == m["ts"]]

    def thread(self, channel: str, ts: str):
        return [m for m in self.messages.get(channel, []) if m["ts"] == ts or m.get("thread_ts") == ts]

    def page_of(self, items: list, params: dict, key: str) -> dict:
        oldest = float(params.get("oldest", "0") or 0)
        items = [m for m in items if float(m["ts"]) > oldest]
        start = int(params.get("cursor", "0") or 0)
        size = min(self.page, int(params.get("limit", self.page) or self.page))
        chunk = items[start : start + size]
        answer = {"ok": True, key: chunk, "has_more": start + size < len(items)}
        answer["response_metadata"] = {"next_cursor": str(start + size) if answer["has_more"] else ""}
        return answer


class Handler(BaseHTTPRequestHandler):
    ws: Workspace

    def log_message(self, fmt, *args):  # quiet
        return

    def send_json(self, body: dict, status: int = 200, headers: dict = None) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(length) if length else b""

    def do_GET(self):
        self.dispatch()

    def do_POST(self):
        self.dispatch()

    def dispatch(self):
        url = urllib.parse.urlsplit(self.path)
        path = url.path
        params = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        raw = self.body()
        with self.ws.lock:
            if path.startswith("/_test/"):
                return self.control(path, raw)
            if path.startswith("/_upload/"):
                self.ws.uploads[path[len("/_upload/") :]] = raw
                self.ws.calls.append("upload")
                return self.send_json({"ok": True})
            if raw and self.headers.get("Content-Type", "").startswith("application/json"):
                params.update(json.loads(raw))
            method = path.lstrip("/")
            self.ws.calls.append(method)
            for fault in list(self.ws.faults):
                if fault["method"] == method and fault["times"] > 0:
                    fault["times"] -= 1
                    if fault.get("drop"):
                        self.close_connection = True
                        return None
                    if fault.get("refuse"):
                        return self.send_json({}, 302, {"Location": f"http://127.0.0.1:{self.ws.dead_port}/{method}"})
                    if fault.get("status"):
                        return self.send_json({"ok": False}, fault["status"], {"Retry-After": str(fault.get("retry_after", 0))})
                    return self.send_json({"ok": False, "error": fault["error"]})
            auth = self.headers.get("Authorization", "")
            if auth != f"Bearer {self.ws.token}":
                return self.send_json({"ok": False, "error": "invalid_auth"})
            handler = getattr(self, "m_" + method.replace(".", "_"), None)
            if handler is None:
                return self.send_json({"ok": False, "error": "unknown_method"})
            return handler(params)

    # -- control ------------------------------------------------------------

    def control(self, path: str, raw: bytes):
        ws = self.ws
        if path == "/_test/state":
            return self.send_json(
                {
                    "channels": ws.channels,
                    "messages": ws.messages,
                    "calls": ws.calls,
                    "uploads": {k: v.decode("utf-8", "replace") for k, v in ws.uploads.items()},
                }
            )
        body = json.loads(raw or b"{}")
        if path == "/_test/message":
            channel = body.pop("channel")
            ws.channels.setdefault(channel, {"id": channel, "name": channel, "members": [BOT], "is_private": True})
            message = ws.add_message(channel, body)
            return self.send_json({"ok": True, "ts": message["ts"]})
        if path == "/_test/channel":
            body.setdefault("members", [BOT])
            body.setdefault("is_private", True)
            ws.channels[body["id"]] = body
            return self.send_json({"ok": True})
        if path == "/_test/fault":
            body.setdefault("times", 1)
            ws.faults.append(body)
            return self.send_json({"ok": True})
        if path == "/_test/calls-reset":
            ws.calls.clear()
            return self.send_json({"ok": True})
        return self.send_json({"ok": False, "error": "unknown_control"}, 404)

    # -- the methods ----------------------------------------------------------

    def m_auth_test(self, params):
        self.send_json({"ok": True, "user_id": BOT, "bot_id": BOT_ID, "team_id": "T01"})

    def m_users_lookupByEmail(self, params):
        user = self.ws.users.get(params.get("email", ""))
        if user is None:
            return self.send_json({"ok": False, "error": "users_not_found"})
        self.send_json({"ok": True, "user": {"id": user, "profile": {"email": params["email"]}}})

    def m_conversations_list(self, params):
        channels = [dict(c, is_member=BOT in c["members"]) for c in self.ws.channels.values() if BOT in c["members"]]
        self.send_json({"ok": True, "channels": channels, "response_metadata": {"next_cursor": ""}})

    def m_conversations_create(self, params):
        name = params["name"]
        if self.ws.channel_by_name(name):
            return self.send_json({"ok": False, "error": "name_taken"})
        channel = {"id": f"C{len(self.ws.channels) + 1:03d}", "name": name, "members": [BOT], "is_private": True}
        self.ws.channels[channel["id"]] = channel
        self.send_json({"ok": True, "channel": channel})

    def m_conversations_info(self, params):
        channel = self.ws.channels.get(params.get("channel", ""))
        if channel is None:
            return self.send_json({"ok": False, "error": "channel_not_found"})
        self.send_json({"ok": True, "channel": dict(channel, is_member=BOT in channel["members"])})

    def m_conversations_invite(self, params):
        channel = self.ws.channels.get(params.get("channel", ""))
        if channel is None:
            return self.send_json({"ok": False, "error": "channel_not_found"})
        new = [u for u in params.get("users", "").split(",") if u and u not in channel["members"]]
        if not new:
            return self.send_json({"ok": False, "error": "already_in_channel"})
        channel["members"].extend(new)
        self.send_json({"ok": True, "channel": channel})

    def m_conversations_history(self, params):
        items = sorted(self.ws.top_level(params["channel"]), key=lambda m: float(m["ts"]), reverse=True)
        self.send_json(self.ws.page_of(items, params, "messages"))

    def m_conversations_replies(self, params):
        items = sorted(self.ws.thread(params["channel"], params["ts"]), key=lambda m: float(m["ts"]))
        self.send_json(self.ws.page_of(items, params, "messages"))

    def m_chat_postMessage(self, params):
        message = {"user": BOT, "bot_id": BOT_ID, "text": params.get("text", "")}
        if params.get("thread_ts"):
            message["thread_ts"] = params["thread_ts"]
        self.ws.channels.setdefault(params["channel"], {"id": params["channel"], "name": params["channel"], "members": [BOT], "is_private": True})
        message = self.ws.add_message(params["channel"], message)
        self.send_json({"ok": True, "channel": params["channel"], "ts": message["ts"]})

    def m_chat_update(self, params):
        for message in self.ws.messages.get(params["channel"], []):
            if message["ts"] == params["ts"]:
                message["text"] = params.get("text", "")
                message["edited"] = {"ts": self.ws.next_ts()}
                return self.send_json({"ok": True, "ts": params["ts"]})
        self.send_json({"ok": False, "error": "message_not_found"})

    def m_files_getUploadURLExternal(self, params):
        file_id = f"F{len(self.ws.uploads) + 1:03d}"
        self.ws.uploads[file_id] = b""
        host = self.headers.get("Host")
        self.send_json({"ok": True, "upload_url": f"http://{host}/_upload/{file_id}", "file_id": file_id})

    def m_files_completeUploadExternal(self, params):
        files = params.get("files", [])
        message = {
            "user": BOT,
            "bot_id": BOT_ID,
            "text": params.get("initial_comment", ""),
            "files": [{"id": f["id"], "title": f.get("title", "")} for f in files],
        }
        if params.get("thread_ts"):
            message["thread_ts"] = params["thread_ts"]
        self.ws.add_message(params["channel_id"], message)
        self.send_json({"ok": True, "files": [{"id": f["id"]} for f in files]})


class Server(ThreadingHTTPServer):
    """Bound with no name lookup: `HTTPServer.server_bind` names the host
    through `socket.getfqdn`, a reverse lookup that can stall past the
    harness's start bound on a macOS runner."""

    def server_bind(self) -> None:
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def dead_port() -> int:
    """A port the kernel just handed out and nothing listens on."""
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--user", action="append", default=[])
    parser.add_argument("--page", type=int, default=200)
    args = parser.parse_args()
    users = dict(item.split("=", 1) for item in args.user)
    Handler.ws = Workspace(args.token, users, args.page)
    server = Server(("127.0.0.1", 0), Handler)
    # Written aside and renamed, so the harness never reads a partial port.
    tmp = args.port_file + ".tmp"
    with open(tmp, "w") as handle:
        handle.write(str(server.server_port))
    os.replace(tmp, args.port_file)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
