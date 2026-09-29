#!/usr/bin/env bash
# `slack listen` on its Socket Mode connection, against the fake's WebSocket
# and the real lane-mail. The rows: listen with no SLACK_APP_TOKEN refused,
# the first connection journaled
# `connect` and shown connected, an owner message landing from its event
# alone, its eyes mark set at once and every envelope acknowledged, the
# first reply in an ask's thread landing as the answer, a reply under a
# thread past SLACK_THREAD_DAYS left unrouted, an envelope lost with its
# connection delivered by the history read of the reconnect, journaled
# `disconnect` and `reconnect`, Slack's `disconnect` envelope answered with a
# new connection, and a relay that cannot reconnect shown reconnecting. Each
# message event is awaited three seconds at most, the acceptance bound; the
# relay polls every second but reads Slack's history only on a connect, so
# only the event path can land a message in that time. The controls: no
# acknowledgement, events unread, no history read on reconnect, and the
# thread-age check gone from the event path.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack listen: Socket Mode ==="

# landed ROOT DELIVERY_ID — the text of the envelope keyed DELIVERY_ID, awaited
# three seconds at most: the event path's bound. Empty when none landed.
landed() {
  local tries=0 file text
  file="$(sk_box "$1")/to-lane.jsonl"
  while [ "$tries" -lt 30 ]; do
    if [ -f "$file" ]; then
      text="$(jq -r --arg d "$2" 'select(.delivery_id == $d) | .text' "$file")"
      if [ -n "$text" ]; then printf '%s' "$text"; return 0; fi
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  return 0
}
# lines ROOT KIND — the `at`-less shape of each journal line of KIND, one per line
lines() { jq -r --arg k "$2" 'select(.t == $k) | [.t, (.reason // "")] | join(" ")' "$(sk_journal "$1")"; }
# awaited CMD... — CMD's output once it is non-empty, three seconds at most
awaited() {
  local tries=0 out
  while [ "$tries" -lt 30 ]; do
    out="$("$@")"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    tries=$((tries + 1))
    sleep 0.1
  done
  return 0
}
opened_at_least() { [ "$(sk_state .opened)" -ge "$1" ] && echo yes; } # N
unacked() { sk_state '(.sent - .acks) | length'; }
field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; } # LINE KEY
connection() { sk_run -- listen --status --root "$1"; field "$OUT" connection; } # ROOT
# relay ROOT — sk_relay_start, then a stop of the suite unless the relay holds
# its connection, so no row reads an event path that was never open.
relay() {
  sk_relay_start "$1"
  [ "$(connection "$1")" = connected ] || { printf 'relay on %s did not connect\n' "$1" >&2; exit 1; }
}

# --- settings ------------------------------------------------------------------
ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
sk_run -- listen --root "$ROOT"
assert_eq "$RC=$ERR1" "2=slack: setting-missing=SLACK_APP_TOKEN" "listen with no SLACK_APP_TOKEN is refused before anything runs"

# --- the first connection: an owner message lands from its event -------------------
relay "$ROOT"
assert_eq "$(lines "$ROOT" connect)|$(connection "$ROOT")" "connect |connected" "the first connection is journaled connect and shown connected"
assert_has "$(cat "$SK_TMP/relay.out")" "slack: connected=" "the relay prints the connection"
TS1="$(sk_inject C001 U001 'Ship it now.')"
assert_eq "$(landed "$ROOT" "C001:$TS1")" "Ship it now." "an owner message lands from its event within three seconds, keyed channel:ts"
assert_eq "$(awaited sk_reactions C001 "$TS1")" "eyes" "its eyes mark is set as it lands"
assert_eq "$(sk_state '.sent | length')=$(unacked)" "$(sk_state '.sent | length')=0" "every envelope sent is acknowledged by its envelope_id"

# --- an ask's thread: the first reply is the answer ------------------------------------
sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text q 'Cut it?')" --options yes,no --recommend no >"$SK_TMP/ask.out"
ASK="$(sed 's/^id=//' "$SK_TMP/ask.out")"
ask_ts() { sk_state '.messages.C001[] | select(.text | contains("Cut it?")) | .ts'; }
ASK_TS="$(awaited ask_ts)"
R1="$(sk_inject C001 U002 'yes' "$ASK_TS")"
answer() { [ -f "$(sk_box "$ROOT")/to-lane.jsonl" ] && jq -r 'select(.kind == "answer") | [.re, .delivery_id, .text] | join(" ")' "$(sk_box "$ROOT")/to-lane.jsonl"; }
assert_eq "$(awaited answer)" "$ASK C001:$R1 yes" "the first reply in the ask's thread lands from its event as the answer"
sk_relay_stop

# --- a reply under a thread past SLACK_THREAD_DAYS: not routed -----------------------------
BETA="$(sk_new_root beta)"
sk_bind "$BETA"
sk_rebind_at "$BETA" "$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400))')"
OLD="$(sk_inject C002 U001 'an old topic' '' "\"ts\": \"$(python3 -c 'import time; print("%.6f" % (time.time() - 8 * 86400))')\"")"
YOUNG="$(sk_inject C002 U001 'a young topic')"
sk_poll "$BETA"
relay "$BETA"
OR="$(sk_inject C002 U001 'under the old one' "$OLD")"
YR="$(sk_inject C002 U001 'under the young one' "$YOUNG")"
assert_eq "$(landed "$BETA" "C002:$YR")|$(landed "$BETA" "C002:$OR")" "under the young one|" \
  "a reply event under a young thread lands, and one under a thread past SLACK_THREAD_DAYS does not"
sk_relay_stop

# --- a dropped connection: the lost envelope lands on the reconnect ---------------------------
GAMMA="$(sk_new_root gamma)"
sk_bind "$GAMMA"
drop_one() { # ROOT — one envelope lost with its connection; LOST is its message's ts
  local channel
  channel="$(sk_channel "$1")"
  relay "$1"
  sk_ctl /_test/fault '{"method": "socket", "drop": true}' >/dev/null
  LOST="$(sk_inject "$channel" U001 'sent while the connection dropped')"
  LOST_TEXT="$(landed "$1" "$channel:$LOST")"
}
OPENED="$(sk_state .opened)"
drop_one "$GAMMA"
assert_eq "$(sk_state '.withheld | length')" "1" "the fake withheld one envelope and closed the connection"
assert_eq "$LOST_TEXT" "sent while the connection dropped" "the message of the lost envelope lands through the history read of the reconnect"
assert_eq "$(sk_state .opened)" "$((OPENED + 2))" "the relay opened its connection, then one new one after the drop"
assert_eq "$(lines "$GAMMA" connect)|$(lines "$GAMMA" disconnect)|$(lines "$GAMMA" reconnect)" "connect |disconnect connection ended|reconnect " \
  "the journal holds connect, the disconnect with its reason, then reconnect"
assert_eq "$(jq -r 'select(.t != "connect" and .t != "disconnect" and .t != "reconnect") | .t' "$(sk_journal "$GAMMA")" | tr '\n' ' ')" "seen start in seen mark " \
  "the directive is delivered once, then marked"

# --- Slack's disconnect envelope: a new connection -----------------------------------------
OPENED="$(sk_state .opened)"
sk_ctl /_test/socket '{"disconnect": "refresh_requested"}' >/dev/null
assert_eq "$(awaited opened_at_least $((OPENED + 1)))" "yes" "Slack's disconnect envelope is answered with a new connection"
assert_eq "$(lines "$GAMMA" disconnect | sed -n '2p')" "disconnect slack-refresh_requested" "the disconnect is journaled with Slack's reason"
TS2="$(sk_inject C003 U001 'after the refresh')"
assert_eq "$(landed "$GAMMA" "C003:$TS2")" "after the refresh" "a message after the refresh lands from its event"

# --- a relay that cannot reconnect shows reconnecting ----------------------------------------
sk_ctl /_test/fault '{"method": "apps.connections.open", "error": "internal_error", "times": 100}' >/dev/null
sk_ctl /_test/fault '{"method": "socket", "drop": true}' >/dev/null
sk_inject C003 U001 'drops the connection' >/dev/null
reconnecting() { [ "$(connection "$GAMMA")" = reconnecting ] && echo yes; }
assert_eq "$(awaited reconnecting)" "yes" "a relay whose connect Slack refuses shows reconnecting"
assert_has "$(cat "$SK_TMP/relay.err")" "slack: slack-api-failed=apps.connections.open error=internal_error" "the refused connect is printed"
sk_relay_stop
sk_ctl /_test/faults-reset >/dev/null

# --- controls, one mutant per rule -------------------------------------------------------------
sk_mutant ack relay.py 'socket\.send_text\(json\.dumps\(\{"envelope_id": envelope\["envelope_id"\]\}\)\)' 'pass'
DELTA="$(sk_new_root delta)"
sk_bind "$DELTA"
relay "$DELTA"
TS3="$(sk_inject C004 U001 'unacknowledged')"
landed "$DELTA" "C004:$TS3" >/dev/null
assert_eq "$(unacked)" "1" "control: the acknowledgement gone, the envelope stays unacknowledged"
sk_relay_stop
sk_bin_reset

sk_mutant events relay.py 'root\.on_message\(event, self\.bot_user\)' 'pass'
relay "$DELTA"
TS4="$(sk_inject C004 U001 'unread event')"
assert_eq "$(landed "$DELTA" "C004:$TS4")" "" "control: events unread, a message does not land within three seconds"
sk_relay_stop
sk_bin_reset

sk_mutant catch-up relay.py 'root\.journal\.append\(t=kind, at=self\.since\)\n            root\.caught_up = False' 'root.journal.append(t=kind, at=self.since)'
EPS="$(sk_new_root eps)"
sk_bind "$EPS"
drop_one "$EPS"
assert_eq "$LOST_TEXT" "" "control: no history read on a connect, the lost envelope's message never lands"
sk_relay_stop
sk_bin_reset

sk_mutant event-age relay.py 'if thread is None or not self\.live\(thread\):' 'if thread is None:'
relay "$BETA"
OR2="$(sk_inject C002 U001 'late under the old one' "$OLD")"
assert_eq "$(landed "$BETA" "C002:$OR2")" "late under the old one" "control: the thread-age check gone from events, a reply under the old thread lands"
sk_relay_stop
sk_bin_reset

sk_summary
