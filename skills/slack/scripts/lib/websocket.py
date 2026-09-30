"""A WebSocket client, RFC 6455, for the relay's one Socket Mode connection.

Built here, not declared as a dependency: the package runs on the Python 3.8
standard library alone, with no package manager on the control VM or in the
catalog, and Socket Mode needs only a small part of the protocol. What it
holds: the opening handshake over TCP or TLS, masked text frames out, text
messages in, fragmented or whole, a ping answered with a pong, a ping of its
own after a silence, and the close handshake. No extension, subprotocol,
compression or binary message: Slack's Socket Mode sends none, and a frame
this client cannot read closes the connection, which the relay meets as a
drop and answers with a reconnect and a history read.

Every failure, the handshake included, is `Closed` with the reason as text.
"""

from __future__ import annotations

import base64
import hashlib
import os
import socket
import ssl
import struct
import time
import urllib.parse
from typing import Callable, Optional

# RFC 6455 § 1.3: the key the server hashes into Sec-WebSocket-Accept.
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
CONNECT_SECONDS = 30
READ_BYTES = 64 * 1024
# Frames the client needs: RFC 6455 § 5.2 opcodes.
CONTINUATION, TEXT, BINARY, CLOSE, PING, PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA


class Closed(Exception):
    """The connection is gone or never opened; the text says why."""


def accept_key(key: str) -> str:
    """The Sec-WebSocket-Accept a server answers `key` with."""
    return base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()


class WebSocket:
    def __init__(
        self, sock: socket.socket, buffered: bytes, idle: float, clock: Callable[[], float] = time.monotonic
    ) -> None:
        self.sock = sock
        self.buf = bytearray(buffered)
        # Seconds of silence before `recv` pings, and as many again with no
        # frame before it reads the connection as dropped.
        self.idle = idle
        self.clock = clock
        self.parts: list = []
        # The clock when a frame last arrived, and when an unanswered ping
        # went out; `_keepalive` judges both.
        self.heard = clock()
        self.pinged: Optional[float] = None

    @classmethod
    def connect(cls, url: str, idle: float) -> "WebSocket":
        """The opening handshake to a ws:// or wss:// URL; `idle` as the
        constructor states it."""
        parts = urllib.parse.urlsplit(url)
        if parts.scheme not in ("ws", "wss") or not parts.hostname:
            raise Closed(f"url {parts.scheme}://{parts.hostname}")
        port = parts.port or (443 if parts.scheme == "wss" else 80)
        path = (parts.path or "/") + (f"?{parts.query}" if parts.query else "")
        try:
            sock = socket.create_connection((parts.hostname, port), timeout=CONNECT_SECONDS)
        except OSError as err:
            raise Closed(f"connect ({err})") from err
        try:
            if parts.scheme == "wss":
                ctx = ssl.create_default_context()
                ctx.minimum_version = ssl.TLSVersion.TLSv1_2
                sock = ctx.wrap_socket(sock, server_hostname=parts.hostname)
            key = base64.b64encode(os.urandom(16)).decode()
            request = (
                f"GET {path} HTTP/1.1\r\nHost: {parts.netloc}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            )
            sock.sendall(request.encode())
            head = b""
            while b"\r\n\r\n" not in head:
                chunk = sock.recv(READ_BYTES)
                if not chunk:
                    raise Closed("handshake ended before its headers")
                head += chunk
            head, rest = head.split(b"\r\n\r\n", 1)
            lines = head.decode("latin-1").split("\r\n")
            status = lines[0].split(" ", 2)
            if len(status) < 2 or status[1] != "101":
                raise Closed(f"handshake status {lines[0]}")
            headers = {k.strip().lower(): v.strip() for k, _, v in (line.partition(":") for line in lines[1:])}
            if headers.get("sec-websocket-accept") != accept_key(key):
                raise Closed("handshake accept key mismatch")
        except OSError as err:
            sock.close()
            raise Closed(f"handshake ({err})") from err
        except Closed:
            sock.close()
            raise
        # The connect timeout bounded the handshake; `recv` sets its own.
        return cls(sock, rest, idle)

    def send_text(self, text: str) -> None:
        self._send(TEXT, text.encode())

    def _send(self, opcode: int, payload: bytes) -> None:
        """One final frame, masked as every client frame must be."""
        size = len(payload)
        if size < 126:
            head = struct.pack("!BB", 0x80 | opcode, 0x80 | size)
        elif size < 1 << 16:
            head = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, size)
        else:
            head = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, size)
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        try:
            # `_fill` leaves the socket on its read's short timeout.
            self.sock.settimeout(CONNECT_SECONDS)
            self.sock.sendall(head + mask + masked)
        except OSError as err:
            raise Closed(f"send ({err})") from err

    def _keepalive(self) -> float:
        """A ping after `idle` seconds with no frame, and `Closed` when
        `idle` more pass with no frame in answer: a connection the network
        dropped without a word reads as open until then. Returns the
        seconds until the next check is due, always more than zero."""
        now = self.clock()
        if self.pinged is not None:
            if now - self.pinged >= self.idle:
                raise Closed(f"no frame in {int(2 * self.idle)}s")
            return self.pinged + self.idle - now
        if now - self.heard >= self.idle:
            self._send(PING, b"")
            self.pinged = now
            return self.idle
        return self.heard + self.idle - now

    def recv(self, timeout: float) -> Optional[str]:
        """The next text message, or None once `timeout` seconds pass with
        none. Every wait for a frame first runs the keepalive, so no caller
        can skip it. A ping is answered and a close is returned before
        `Closed` is raised."""
        deadline = self.clock() + max(timeout, 0.0)
        while True:
            frame = self._frame()
            if frame is None:
                due = self._keepalive()
                remaining = deadline - self.clock()
                if remaining <= 0:
                    return None
                self._fill(min(remaining, due))
                continue
            self.heard = self.clock()
            self.pinged = None
            fin, opcode, payload = frame
            if opcode == PING:
                self._send(PONG, payload)
            elif opcode == PONG:
                continue
            elif opcode == CLOSE:
                code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else 1005
                self.close(code)
                raise Closed(f"closed by server code={code}")
            elif opcode in (TEXT, CONTINUATION):
                if (opcode == TEXT) == bool(self.parts):
                    self.close(1002)
                    raise Closed("frame out of sequence")
                self.parts.append(payload)
                if fin:
                    data, self.parts = b"".join(self.parts), []
                    try:
                        return data.decode()
                    except UnicodeDecodeError as err:
                        self.close(1007)
                        raise Closed("text not UTF-8") from err
            else:
                self.close(1003)
                raise Closed(f"opcode {opcode}")

    def _fill(self, timeout: float) -> None:
        try:
            self.sock.settimeout(timeout)
            chunk = self.sock.recv(READ_BYTES)
        except socket.timeout:
            return
        except OSError as err:
            raise Closed(f"read ({err})") from err
        if not chunk:
            raise Closed("connection ended")
        self.buf.extend(chunk)

    def _frame(self):
        """One whole frame off the buffer as (fin, opcode, payload), or None
        while it is still arriving."""
        if len(self.buf) < 2:
            return None
        first, second = self.buf[0], self.buf[1]
        if second & 0x80:
            self.close(1002)
            raise Closed("server frame masked")
        size, offset = second & 0x7F, 2
        if size == 126:
            if len(self.buf) < 4:
                return None
            size, offset = struct.unpack("!H", self.buf[2:4])[0], 4
        elif size == 127:
            if len(self.buf) < 10:
                return None
            size, offset = struct.unpack("!Q", self.buf[2:10])[0], 10
        if len(self.buf) < offset + size:
            return None
        payload = bytes(self.buf[offset : offset + size])
        del self.buf[: offset + size]
        return bool(first & 0x80), first & 0x0F, payload

    def close(self, code: int = 1000) -> None:
        """The close frame, sent when the socket still takes it, then the
        socket closed."""
        try:
            self._send(CLOSE, struct.pack("!H", code))
        except Closed:
            # A socket that no longer takes the frame is already what this
            # call leaves it: gone.
            pass
        try:
            self.sock.close()
        except OSError:
            pass
