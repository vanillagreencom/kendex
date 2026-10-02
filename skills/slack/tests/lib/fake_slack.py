#!/usr/bin/env python3
"""A fake Slack Web API for the suites: the methods the package calls, an
in-memory workspace, and a control surface under /_test/ the suites drive.

    fake_slack.py --port-file PATH --token TOKEN --app-token TOKEN
                  [--user EMAIL=ID]... [--page N]

Control: POST /_test/message injects a message and answers its ts; POST
/_test/file holds `content` as file `id`, which GET /_files/<id> serves to the
bot token as Slack's url_private_download does, typed `type` when given and
application/octet-stream when not; GET
/_test/state dumps messages, calls, uploads and posts, each message the app
posted or edited naming its body's argument in `body_arg`; POST /_test/fault
makes the next `times` calls of `method` answer `error`, HTTP `status`, or
with `drop` close the connection after reading the request and before any
response, or with `refuse` redirect to a reserved port nothing listens on,
which refuses or times out before the redirected request is written, or with
`signin` Slack's sign-in page, or with `cut` a body the connection closes
halfway through: `length` under its full Content-Length, `chunked` inside
its first chunk, or with `chunked: true` the whole file in two chunks and
no Content-Length. API cuts run the method before cutting its response.
An optional `ts` limits a fault to that thread. A download's method is `download`.
POST /_test/delete removes a parent and its replies by channel and ts.

Socket Mode: apps.connections.open, called with the app token, answers the
URL of a WebSocket on this same port. Its first frame is Slack's `hello`;
every message the workspace gains after that, the app's own included, goes
to the newest open connection as an `events_api` envelope, and the client's
acknowledgements are kept. A `socket` fault with `drop` withholds the next
envelope and closes that connection with no close frame, as a network drop
does; POST /_test/faults-reset drops every pending fault; POST /_test/socket
with `disconnect: REASON` sends Slack's `disconnect` envelope. Each token
used on a method of the other answers `not_allowed_token_type`, as Slack
does. /_test/state carries `sent`, each envelope's `envelope_id` with the
`channel` and `ts` of the message it carried, the `acks` and `withheld`
envelope ids, and the count of connections `opened`.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import select
import socket
import socketserver
import struct
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BOT = "UBOT"
BOT_ID = "B01"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
SIGNIN = b"<!DOCTYPE html><html><head><title>Slack</title></head><body>Sign in to Slack</body></html>"


class Conn:
    """One server side of a Socket Mode connection: frames out unmasked,
    each closed with no close frame when the suite drops it."""

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.open = True
        self.buf = b""

    def send(self, text: str, opcode: int = 0x1) -> None:
        data = text.encode() if isinstance(text, str) else text
        size = len(data)
        if size < 126:
            head = struct.pack("!BB", 0x80 | opcode, size)
        elif size < 1 << 16:
            head = struct.pack("!BBH", 0x80 | opcode, 126, size)
        else:
            head = struct.pack("!BBQ", 0x80 | opcode, 127, size)
        try:
            self.sock.sendall(head + data)
        except OSError:
            self.close()

    def close(self) -> None:
        self.open = False
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def frames(self):
        """Every whole client frame buffered, unmasked, as (opcode, payload)."""
        while len(self.buf) >= 2:
            size, offset = self.buf[1] & 0x7F, 2
            if size == 126:
                size, offset = struct.unpack("!H", self.buf[2:4])[0], 4
            elif size == 127:
                size, offset = struct.unpack("!Q", self.buf[2:10])[0], 10
            if len(self.buf) < offset + 4 + size:
                return
            mask = self.buf[offset : offset + 4]
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(self.buf[offset + 4 : offset + 4 + size]))
            opcode = self.buf[0] & 0x0F
            self.buf = self.buf[offset + 4 + size :]
            yield opcode, data


class Workspace:
    def __init__(self, token: str, app_token: str, users: dict, page: int) -> None:
        self.token = token
        self.app_token = app_token
        self.sockets: list = []  # every connection opened, newest last
        self.sent: list = []
        self.acks: list = []
        self.pongs: list = []
        self.withheld: list = []
        self.users = users  # email -> id
        self.page = page
        self.channels: dict = {}  # id -> {id, name, members, is_private}
        self.messages: dict = {}  # channel -> [message]
        self.uploads: dict = {}  # file id -> bytes
        self.files: dict = {}  # file id -> (bytes, content type) a download serves
        self.calls: list = []
        self.faults: list = []
        self.counter = 0
        self.lock = threading.Lock()


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
        self.push(channel, message)
        return message

    def push(self, channel: str, message: dict) -> None:
        """The message as an events_api envelope to the newest open
        connection, or withheld by a `socket` drop fault; none with no
        connection open, as Slack sends none."""
        live = [conn for conn in self.sockets if conn.open]
        if not live:
            return
        self.counter += 1
        env_id = f"E{self.counter:04d}"
        event = dict(message, channel=channel, channel_type="group")
        event.pop("body_arg", None)
        for fault in self.faults:
            if fault["method"] == "socket" and fault["times"] > 0 and fault.get("drop"):
                fault["times"] -= 1
                self.withheld.append(env_id)
                live[-1].close()
                return
        envelope = {
            "envelope_id": env_id,
            "type": "events_api",
            "accepts_response_payload": False,
            "retry_attempt": 0,
            "payload": {"type": "event_callback", "event": event},
        }
        self.sent.append({"envelope_id": env_id, "channel": channel, "ts": message["ts"]})
        live[-1].send(json.dumps(envelope))


    def top_level(self, channel: str):
        return [m for m in self.messages.get(channel, []) if not m.get("thread_ts") or m["thread_ts"] == m["ts"]]

    def thread(self, channel: str, ts: str):
        message = next((m for m in self.messages.get(channel, []) if m["ts"] == ts), None)
        if message is not None:
            ts = message.get("thread_ts") or ts
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
        if getattr(self, "response_cut", None):
            how, self.response_cut = self.response_cut, None
            return self.send_cut(how, json.dumps(body).encode())
        self.send_bytes(json.dumps(body).encode(), "application/json", status, headers)

    def send_bytes(self, data: bytes, content_type: str, status: int = 200, headers: dict = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_cut(self, how: str, data: bytes) -> None:
        """Half of `data`, then the connection closed: a response Slack's
        side cut short."""
        half = data[: len(data) // 2]
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        if how == "length":
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(half)
        elif how == "chunked":
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"%x\r\n" % len(data) + half)
        else:
            raise ValueError(f"cut={how}")
        self.wfile.flush()
        self.close_connection = True

    def send_chunked(self, data: bytes, content_type: str) -> None:
        """`data` whole in two chunks, with no Content-Length."""
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        half = len(data) // 2
        for part in (data[:half], data[half:]):
            if part:
                self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
        self.wfile.write(b"0\r\n\r\n")

    def body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(length) if length else b""

    def do_GET(self):
        if urllib.parse.urlsplit(self.path).path == "/_socket":
            return self.socket_mode()
        self.dispatch()

    def socket_mode(self):
        """The WebSocket handshake, `hello`, then the client's frames until
        it or the suite closes the connection."""
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        conn = Conn(self.connection)
        with self.ws.lock:
            self.ws.sockets.append(conn)
            conn.send(json.dumps({"type": "hello"}))
        while conn.open:
            readable, _, _ = select.select([conn.sock], [], [], 0.05)
            if not readable:
                continue
            try:
                chunk = conn.sock.recv(65536)
            except OSError:
                chunk = b""
            with self.ws.lock:
                if not chunk:
                    conn.close()
                    break
                conn.buf += chunk
                for opcode, data in conn.frames():
                    if opcode == 0x1:
                        self.ws.acks.append(json.loads(data)["envelope_id"])
                    elif opcode == 0x9:
                        conn.send(data, 0xA)
                    elif opcode == 0xA:
                        self.ws.pongs.append(data.decode())
                    elif opcode == 0x8:
                        conn.send(data, 0x8)
                        conn.close()

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
            method = "download" if path.startswith("/_files/") else path.lstrip("/")
            token = self.ws.app_token if method == "apps.connections.open" else self.ws.token
            self.ws.calls.append(method)
            for fault in list(self.ws.faults):
                if fault["method"] == method and fault["times"] > 0 and (
                    "ts" not in fault or fault["ts"] == params.get("ts")
                ):
                    fault["times"] -= 1
                    if fault.get("drop"):
                        self.close_connection = True
                        return None
                    if fault.get("refuse"):
                        port = self.server.refusal_socket.getsockname()[1]
                        return self.send_json({}, 302, {"Location": f"http://127.0.0.1:{port}/{method}"})
                    if fault.get("signin"):
                        return self.send_bytes(SIGNIN, "text/html; charset=utf-8")
                    if fault.get("cut"):
                        if method == "download":
                            return self.send_cut(fault["cut"], self.ws.files[path[len("/_files/") :]][0])
                        self.response_cut = fault["cut"]
                        break
                    if fault.get("chunked"):
                        return self.send_chunked(*self.ws.files[path[len("/_files/") :]])
                    if fault.get("status"):
                        return self.send_json({"ok": False}, fault["status"], {"Retry-After": str(fault.get("retry_after", 0))})
                    return self.send_json({"ok": False, "error": fault["error"]})
            auth = self.headers.get("Authorization", "")
            if auth in (f"Bearer {self.ws.token}", f"Bearer {self.ws.app_token}") and auth != f"Bearer {token}":
                return self.send_json({"ok": False, "error": "not_allowed_token_type"})
            if auth != f"Bearer {token}":
                return self.send_json({"ok": False, "error": "invalid_auth"})
            if method == "download":
                served = self.ws.files.get(path[len("/_files/") :])
                if served is None:
                    return self.send_json({"ok": False}, 404)
                return self.send_bytes(*served)
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
                    "sent": ws.sent,
                    "acks": ws.acks,
                    "pongs": ws.pongs,
                    "withheld": ws.withheld,
                    "opened": len(ws.sockets),
                }
            )
        body = json.loads(raw or b"{}")
        if path == "/_test/message":
            channel = body.pop("channel")
            ws.channels.setdefault(channel, {"id": channel, "name": channel, "members": [BOT], "is_private": True})
            message = ws.add_message(channel, body)
            return self.send_json({"ok": True, "ts": message["ts"]})
        if path == "/_test/delete":
            ws.messages[body["channel"]] = [m for m in ws.messages[body["channel"]]
                                             if m["ts"] != body["ts"] and m.get("thread_ts") != body["ts"]]
            return self.send_json({"ok": True})
        if path == "/_test/channel":
            body.setdefault("members", [BOT])
            body.setdefault("is_private", True)
            ws.channels[body["id"]] = body
            return self.send_json({"ok": True})
        if path == "/_test/fault":
            body.setdefault("times", 1)
            ws.faults.append(body)
            return self.send_json({"ok": True})
        if path == "/_test/file":
            ws.files[body["id"]] = (body["content"].encode(), body.get("type") or "application/octet-stream")
            return self.send_json({"ok": True})
        if path == "/_test/socket":
            live = [conn for conn in ws.sockets if conn.open]
            if live and body.get("disconnect"):
                live[-1].send(json.dumps({"type": "disconnect", "reason": body["disconnect"]}))
            if live and body.get("ping"):
                live[-1].send(body["ping"].encode(), 0x9)
            return self.send_json({"ok": bool(live)})
        if path == "/_test/faults-reset":
            ws.faults.clear()
            return self.send_json({"ok": True})
        if path == "/_test/calls-reset":
            ws.calls.clear()
            return self.send_json({"ok": True})
        return self.send_json({"ok": False, "error": "unknown_control"}, 404)

    # -- the methods ----------------------------------------------------------

    def m_apps_connections_open(self, params):
        host = self.headers.get("Host")
        self.send_json({"ok": True, "url": f"ws://{host}/_socket"})

    def m_auth_test(self, params):
        self.send_json({"ok": True, "user_id": BOT, "bot_id": BOT_ID, "team_id": "T01"})

    def m_users_lookupByEmail(self, params):
        user = self.ws.users.get(params.get("email", ""))
        if user is None:
            return self.send_json({"ok": False, "error": "users_not_found"})
        self.send_json({"ok": True, "user": {"id": user, "profile": {"email": params["email"]}}})

    def m_users_info(self, params):
        """A user's display name is the local part of the address the suite
        gave it."""
        for email, user in self.ws.users.items():
            if user == params.get("user"):
                name = email.split("@")[0]
                return self.send_json({"ok": True, "user": {"id": user, "name": name, "profile": {"display_name": name}}})
        self.send_json({"ok": False, "error": "user_not_found"})

    def m_conversations_list(self, params):
        channels = [dict(c, is_member=BOT in c["members"]) for c in self.ws.channels.values() if BOT in c["members"]]
        self.send_json({"ok": True, "channels": channels, "response_metadata": {"next_cursor": ""}})

    def m_conversations_create(self, params):
        name = params["name"]
        if self.ws.channel_by_name(name):
            return self.send_json({"ok": False, "error": "name_taken"})
        channel = {"id": f"C{len(self.ws.channels) + 1:03d}", "name": name, "members": [BOT], "is_private": True}
        self.ws.channels[channel["id"]] = channel
        self.ws.messages[channel["id"]] = []
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
        if not any(m["ts"] == params["ts"] for m in self.ws.messages.get(params["channel"], [])):
            return self.send_json({"ok": False, "error": "thread_not_found"})
        items = sorted(self.ws.thread(params["channel"], params["ts"]), key=lambda m: float(m["ts"]))
        self.send_json(self.ws.page_of(items, params, "messages"))

    def body_of(self, params):
        """The message body and the argument it came in, `markdown_text` or
        `text`, kept on the message as `body_arg` for the suites; None
        after answering Slack's `markdown_text_conflict` for both at once,
        or `msg_blocks_too_long` for a `markdown_text` past its 12,000
        characters, the error Slack gives the block it makes of that text."""
        if "markdown_text" in params:
            if "text" in params or "blocks" in params:
                self.send_json({"ok": False, "error": "markdown_text_conflict"})
                return None
            if len(params["markdown_text"]) > 12000:
                self.send_json({"ok": False, "error": "msg_blocks_too_long"})
                return None
            return params["markdown_text"], "markdown_text"
        return params.get("text", ""), "text"

    def m_chat_postMessage(self, params):
        body = self.body_of(params)
        if body is None:
            return None
        message = {"user": BOT, "bot_id": BOT_ID, "text": body[0], "body_arg": body[1]}
        message["reply_broadcast"] = params.get("reply_broadcast", False)
        if params.get("thread_ts"):
            message["thread_ts"] = params["thread_ts"]
        self.ws.channels.setdefault(params["channel"], {"id": params["channel"], "name": params["channel"], "members": [BOT], "is_private": True})
        message = self.ws.add_message(params["channel"], message)
        self.send_json({"ok": True, "channel": params["channel"], "ts": message["ts"]})

    def m_chat_update(self, params):
        body = self.body_of(params)
        if body is None:
            return None
        for message in self.ws.messages.get(params["channel"], []):
            if message["ts"] == params["ts"]:
                message["text"], message["body_arg"] = body
                message["edited"] = {"ts": self.ws.next_ts()}
                return self.send_json({"ok": True, "ts": params["ts"]})
        self.send_json({"ok": False, "error": "message_not_found"})

    def reacted(self, params):
        """The message a reactions call names and its reaction names, or
        None when the channel holds no such message."""
        for message in self.ws.messages.get(params["channel"], []):
            if message["ts"] == params["timestamp"]:
                return message, [r["name"] for r in message.setdefault("reactions", [])]
        return None, []

    def m_reactions_add(self, params):
        message, names = self.reacted(params)
        if message is None:
            return self.send_json({"ok": False, "error": "message_not_found"})
        if params["name"] in names:
            return self.send_json({"ok": False, "error": "already_reacted"})
        message["reactions"].append({"name": params["name"], "users": [BOT], "count": 1})
        self.send_json({"ok": True})

    def m_reactions_remove(self, params):
        message, names = self.reacted(params)
        if message is None:
            return self.send_json({"ok": False, "error": "message_not_found"})
        if params["name"] not in names:
            return self.send_json({"ok": False, "error": "no_reaction"})
        message["reactions"] = [r for r in message["reactions"] if r["name"] != params["name"]]
        self.send_json({"ok": True})

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

    def __init__(self, address: tuple[str, int], handler: type[BaseHTTPRequestHandler]) -> None:
        # Hold this port without listening so concurrent fake servers cannot
        # accept a redirected refusal probe.
        self.refusal_socket = socket.socket()
        try:
            self.refusal_socket.bind(("127.0.0.1", 0))
            super().__init__(address, handler)
        except BaseException:
            self.refusal_socket.close()
            raise

    def server_bind(self) -> None:
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

    def server_close(self) -> None:
        try:
            super().server_close()
        finally:
            self.refusal_socket.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--app-token", required=True)
    parser.add_argument("--user", action="append", default=[])
    parser.add_argument("--page", type=int, default=200)
    args = parser.parse_args()
    users = dict(item.split("=", 1) for item in args.user)
    Handler.ws = Workspace(args.token, args.app_token, users, args.page)
    with Server(("127.0.0.1", 0), Handler) as server:
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
