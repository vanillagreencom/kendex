#!/usr/bin/env bash
# The keepalive inside websocket.py's `WebSocket.recv`, the one check that
# finds a connection the network dropped with no close, and the read the
# relay makes. A WebSocket over a socket pair runs on an injected clock; each
# check is a `recv` that waits no time, and the peer reads what the client
# sent. The rows: no ping before `idle` silent seconds, a ping at `idle`, no
# drop before `idle` more, `Closed` at `idle` more with no frame, and any
# frame resetting the timer. The control removes the `Closed` branch, so a
# silent connection is never dropped.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

echo "=== websocket.py: keepalive ==="

# keepalive — one `row=value` line per row, from the websocket.py beside SK_BIN
keepalive() {
  python3 - "$(dirname "$SK_BIN")/lib" <<'PY'
import socket, struct, sys
sys.path.insert(0, sys.argv[1])
from websocket import PING, TEXT, Closed, WebSocket

IDLE = 30
now = [0.0]


def pair():
    client, peer = socket.socketpair()
    peer.setblocking(False)
    return WebSocket(client, b"", IDLE, lambda: now[0]), peer


def sent(peer):
    """The opcodes of the frames the client sent since the last read."""
    try:
        data = peer.recv(65536)
    except BlockingIOError:
        return "none"
    ops = []
    while data:
        size = data[1] & 0x7F
        ops.append("ping" if data[0] & 0x0F == PING else str(data[0] & 0x0F))
        data = data[2 + 4 + size :]
    return ",".join(ops)


def check(ws):
    try:
        ws.recv(0)
        return "open"
    except Closed:
        return "closed"


ws, peer = pair()
now[0] = IDLE - 1
print(f"before-idle={check(ws)}:{sent(peer)}")
now[0] = IDLE
print(f"at-idle={check(ws)}:{sent(peer)}")
now[0] = 2 * IDLE - 1
print(f"before-drop={check(ws)}:{sent(peer)}")
now[0] = 2 * IDLE
print(f"at-drop={check(ws)}")

ws, peer = pair()
now[0] = IDLE
check(ws)
sent(peer)
now[0] = IDLE + 5
peer.sendall(struct.pack("!BB", 0x80 | TEXT, 2) + b"hi")
ws.recv(1)
now[0] = 2 * IDLE + 4
print(f"frame-resets={check(ws)}:{sent(peer)}")
now[0] = 2 * IDLE + 5
print(f"idle-after-frame={check(ws)}:{sent(peer)}")
PY
}
row() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; } # NAME

OUT="$(keepalive)"
assert_eq "$(row before-idle)" "open:none" "no ping before idle silent seconds"
assert_eq "$(row at-idle)" "open:ping" "a ping goes out after idle silent seconds"
assert_eq "$(row before-drop)" "open:none" "no drop before idle more seconds pass"
assert_eq "$(row at-drop)" "closed" "Closed once idle more seconds pass with no frame"
assert_eq "$(row frame-resets)|$(row idle-after-frame)" "open:none|open:ping" \
  "a frame resets the timer: no drop at the old bound, a new ping idle seconds after the frame"

# --- control: the drop branch gone ---------------------------------------------
sk_mutant drop websocket.py 'raise Closed\(f"no frame in \{int\(2 \* self\.idle\)\}s"\)' 'return self.idle'
OUT="$(keepalive)"
assert_eq "$(row at-drop)" "open" "control: the Closed branch gone, a silent connection is never dropped"
sk_bin_reset

# --- TLS floor: emulate the Python 3.8/3.9 default before wrapping --------------
tls_floor() {
  env -i PATH="$PATH" PYTHONDONTWRITEBYTECODE=1 python3 - "$(dirname "$SK_BIN")/lib" <<'PY'
import socket, ssl, sys
from unittest.mock import Mock, patch
sys.path.insert(0, sys.argv[1])
from websocket import Closed, WebSocket

ctx = Mock(spec=ssl.SSLContext, minimum_version=ssl.TLSVersion.TLSv1)
sock = Mock(spec=socket.socket)


def wrap(raw, server_hostname):
    assert ctx.minimum_version == ssl.TLSVersion.TLSv1_2, ctx.minimum_version
    assert raw is sock and server_hostname == "slack.test"
    raise OSError("TLS floor inspected")


ctx.wrap_socket.side_effect = wrap
with patch("websocket.ssl.create_default_context", return_value=ctx), patch(
    "websocket.socket.create_connection", return_value=sock
):
    try:
        WebSocket.connect("wss://slack.test/socket", 30)
    except Closed as err:
        assert str(err) == "handshake (TLS floor inspected)", str(err)
    else:
        raise AssertionError("wrap_socket did not inspect the TLS floor")
PY
}
RC=0
tls_floor || RC=$?
assert_eq "$RC" "0" "wss context requires TLS 1.2 before wrap_socket"

sk_mutant tls-floor websocket.py 'ctx.minimum_version = ssl.TLSVersion.TLSv1_2' 'pass'
RC=0
tls_floor 2>"$SK_TMP/tls-control.err" || RC=$?
assert_eq "$RC" "1" "control: an unset TLS floor fails the same assertion"
sk_bin_reset

sk_summary
