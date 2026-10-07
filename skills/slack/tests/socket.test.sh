#!/usr/bin/env bash
# `slack listen` on its Socket Mode connection, against the fake's WebSocket
# and the real lane-mail. The rows: listen with no SLACK_APP_TOKEN refused, a
# bot token in SLACK_APP_TOKEN and an app-level token without
# connections:write each stopping the relay, the first connection journaled
# `connect` and shown connected, an owner message landing from its event
# alone, its eyes mark set and its envelope acknowledged, the first reply in
# an ask's thread landing as the answer, a reply under a thread past
# SLACK_THREAD_DAYS routed from its event, two roots on one relay each receiving its
# own channel's events and neither an unbound channel's, an event whose
# delivery lane-mail refused landing through the next poll, an
# envelope lost with its connection delivered by the history read of the
# reconnect, journaled `disconnect` and `reconnect`, a reconnect whose history
# read Slack refused delivering on a later poll, Slack's `disconnect` envelope
# answered with a new connection and the doctor row back to `ok`, a relay
# that cannot reconnect shown reconnecting, and a first start whose first poll
# was refused after its connect seeding on the next start. The relay reads Slack's history
# only on a connect or after a refused read or delivery, so between them a
# message lands by its event alone. A positive row waits up to twenty
# seconds; the `events`, `catch-up`, `re-arm` and `read-due` controls wait
# three, which tells the event path, or the pending retry of the next poll,
# from no path at all. The controls: no acknowledgement, the token type and
# the app token's scope no longer refusing the token, events unread, routing
# by channel gone, an unbound channel's event routed to the first root, no
# history read on reconnect, no retry of a refused live delivery, no history
# read after a refused read, the obsolete thread-age check restored on the event path, the
# connection error kept past a reconnect, and a journal of connection lines
# alone read as seeded.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start --page 2
echo "=== slack listen: Socket Mode ==="

# lines ROOT KIND — the `at`-less shape of each journal line of KIND, one per line
lines() { jq -r --arg k "$2" 'select(.t == $k) | [.t, (.reason // "")] | join(" ")' "$(sk_journal "$1")"; }
# awaited CMD... — CMD's output once it is non-empty, AWAIT_TRIES tenths of a second at most, 200 by default
awaited() {
  local tries=0 out
  while [ "$tries" -lt "${AWAIT_TRIES:-200}" ]; do
    out="$("$@")"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    tries=$((tries + 1))
    sleep 0.1
  done
  return 0
}
opened_at_least() { [ "$(sk_state .opened)" -ge "$1" ] && echo yes; } # N
# envelope CHANNEL TS — `sent=N unacked=M` over the envelopes that carried the
# message CHANNEL:TS alone, so no envelope from outside a row reaches its count
envelope() {
  sk_ctl /_test/state | jq -r --arg c "$1" --arg t "$2" \
    '[.sent[] | select(.channel == $c and .ts == $t) | .envelope_id] as $ids
     | "sent=\($ids | length) unacked=\($ids - .acks | length)"'
}
connection() { sk_run -- listen --status --root "$1"; field "$OUT" connection; } # ROOT
state_link() { sk_run -- listen --status --root "$1"; printf '%s %s' "$(field "$OUT" state)" "$(field "$OUT" connection)"; } # ROOT
last_poll() { jq .last_poll "$1/tmp/slack/status.json"; } # ROOT
# reconnect_polled ROOT AFTER — yes once an ok status record polled after
# AFTER, a last_poll taken before the drop, names the latest reconnect as its
# connection's start. A record is written only after a poll's catch-up, which
# can land a message before it, and `at` is a whole second, which the
# connection before the drop can share.
reconnect_polled() {
  local at
  at="$(jq -rs '[.[] | select(.t == "reconnect") | .at] | last // empty' "$(sk_journal "$1")")"
  [ -n "$at" ] && jq -e --arg at "$at" --argjson after "$2" \
    '.last_poll > $after and .last_poll_ok and .connection == "connected" and .connection_since == $at' \
    "$1/tmp/slack/status.json" >/dev/null 2>&1 && echo yes
}
texts() { jq -r .text "$(sk_box "$1")/to-lane.jsonl" | tr '\n' ' '; } # ROOT — every text in its to-lane box
# relay ROOT [--root ROOT]... — sk_relay_start, then a stop of the suite unless
# the relay holds its connection, so no row reads an event path that was never
# open.
relay() {
  sk_relay_start "$@"
  [ "$(connection "$1")" = connected ] || { printf 'relay on %s did not connect\n' "$1" >&2; exit 1; }
}

# --- settings ------------------------------------------------------------------
ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
sk_run -- listen --root "$ROOT"
assert_eq "$RC=$ERR1" "2=slack: setting-missing=SLACK_APP_TOKEN" "listen with no SLACK_APP_TOKEN is refused before anything runs"
sk_run SLACK_APP_TOKEN="$SK_TOKEN" -- listen --root "$ROOT"
assert_eq "$RC=$ERR1" \
  "2=slack: slack-auth-failed=not_allowed_token_type fix=set a live SLACK_APP_TOKEN with connections:write and restart the relay" \
  "a bot token in SLACK_APP_TOKEN stops the relay, naming the setting and its scope"
sk_ctl /_test/fault '{"method": "apps.connections.open", "error": "missing_scope"}' >/dev/null
sk_run SLACK_APP_TOKEN="$SK_APP_TOKEN" -- listen --root "$ROOT"
assert_eq "$RC=$ERR1" \
  "2=slack: slack-auth-failed=missing_scope fix=set a live SLACK_APP_TOKEN with connections:write and restart the relay" \
  "an app-level token without connections:write stops the relay, naming the setting and its scope"

# --- the first connection: an owner message lands from its event -------------------
relay "$ROOT"
assert_eq "$(lines "$ROOT" connect)|$(connection "$ROOT")" "connect |connected" "the first connection is journaled connect and shown connected"
assert_has "$(cat "$SK_TMP/relay.out")" "slack: connected=" "the relay prints the connection"
TS1="$(sk_inject C001 U001 'Ship it now.')"
assert_eq "$(landed "$ROOT" "C001:$TS1")" "Ship it now." "an owner message lands from its event, keyed channel:ts"
assert_eq "$(awaited sk_reactions C001 "$TS1")" "eyes" "its eyes mark is set as it lands"
assert_eq "$(envelope C001 "$TS1")" "sent=1 unacked=0" "the message's envelope is acknowledged by its envelope_id"

# --- an ask's thread: the first reply is the answer ------------------------------------
sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text q 'Cut it?')" --options yes,no --recommend no >"$SK_TMP/ask.out"
ASK="$(sed 's/^id=//' "$SK_TMP/ask.out")"
ask_ts() { sk_state '.messages.C001[] | select(.text | contains("Cut it?")) | .ts'; }
ASK_TS="$(awaited ask_ts)"
R1="$(sk_inject C001 U002 'yes' "$ASK_TS")"
answer() { [ -f "$(sk_box "$ROOT")/to-lane.jsonl" ] && jq -r 'select(.kind == "answer") | [.re, .delivery_id, .text] | join(" ")' "$(sk_box "$ROOT")/to-lane.jsonl"; }
assert_eq "$(awaited answer)" "$ASK C001:$R1 yes" "the first reply in the ask's thread lands from its event as the answer"
sk_relay_stop

# --- a live reply under an old thread is routed -------------------------------------------
BETA="$(sk_new_root beta)"
sk_bind "$BETA"
sk_rebind_at "$BETA" "$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400))')"
OLD="$(sk_inject C002 U001 'an old topic' '' "\"ts\": \"$(python3 -c 'import time; print("%.6f" % (time.time() - 8 * 86400))')\"")"
YOUNG="$(sk_inject C002 U001 'a young topic')"
sk_poll "$BETA"
relay "$BETA"
OR="$(sk_inject C002 U001 'under the old one' "$OLD")"
YR="$(sk_inject C002 U001 'under the young one' "$YOUNG")"
assert_eq "$(landed "$BETA" "C002:$YR")|$(landed "$BETA" "C002:$OR")" "under the young one|under the old one" \
  "reply events under young and old threads both land"
sk_relay_stop

# --- refused old-thread events stay pending outside the reconnect lookback -------
# Parent reads and lane-mail send are real transient refusals. The control
# disables only the pending retry, leaving routine history recovery intact.
while read -r failure mutant tries want_count; do
  RETRY_ROOT="$(sk_new_root "old-retry-$failure-$mutant")"
  sk_bind "$RETRY_ROOT"
  RETRY_CH="$(sk_channel "$RETRY_ROOT")"
  RETRY_PARENT="$(sk_inject "$RETRY_CH" U001 'Old retry topic.' '' "\"ts\": \"$(python3 -c 'import time; print("%.6f" % (time.time() - 8 * 86400))')\"")"
  if [ "$failure" = mail ]; then
    rm -- "${RETRY_ROOT:?}/.agents/skills/orch/scripts"
    mkdir -p "$RETRY_ROOT/.agents/skills/orch/scripts"
    cat > "$RETRY_ROOT/.agents/skills/orch/scripts/lane-mail" <<EOF
#!/usr/bin/env bash
if [ -e "$RETRY_ROOT/tmp/send-refused" ]; then
  case " \$* " in *" send "*) echo 'lane-mail: send-refused' >&2; exit 2 ;; esac
fi
exec "$SK_LANE_MAIL" "\$@"
EOF
    chmod +x "$RETRY_ROOT/.agents/skills/orch/scripts/lane-mail"
  fi
  if [ "$mutant" = retry ]; then
    sk_mutant old-live-retry relay.py 'for message in list\(self\.pending_live\.values\(\)\):' 'for message in []:'
  fi
  relay "$RETRY_ROOT"
  if [ "$failure" = parent ]; then
    sk_ctl /_test/fault '{"method":"conversations.replies","error":"internal_error","times":100}' >/dev/null
    WANT_ERROR='slack-api-failed=conversations.replies error=internal_error'
  else
    touch "$RETRY_ROOT/tmp/send-refused"
    WANT_ERROR='lane-mail-failed=lane-mail: send-refused'
  fi
  RETRY_REPLY="$(sk_inject "$RETRY_CH" U001 'Retry this old thread.' "$RETRY_PARENT")"
  assert_eq "$(awaited jq -r 'select(.last_poll_ok == false) | .last_error' "$RETRY_ROOT/tmp/slack/status.json")" \
    "$WANT_ERROR" "$failure: an old-thread live refusal stays visible in status"
  if [ "$failure" = parent ]; then
    sk_ctl /_test/faults-reset >/dev/null
  else
    rm -- "${RETRY_ROOT:?}/tmp/send-refused"
  fi
  RETRY_TEXT="$(landed "$RETRY_ROOT" "$RETRY_CH:$RETRY_REPLY" "$tries")"
  if [ -f "$(sk_box "$RETRY_ROOT")/to-lane.jsonl" ]; then
    RETRY_POINTER="$(jq -s --arg d "$RETRY_CH:$RETRY_REPLY" --arg ts "$RETRY_PARENT" \
      '[.[] | select(.delivery_id == $d and .text == "Retry this old thread." and .thread_ts == $ts and .parent == {ts:$ts,author:"owner",excerpt:"Old retry topic."})] | length' "$(sk_box "$RETRY_ROOT")/to-lane.jsonl")"
  else
    RETRY_POINTER=0
  fi
  assert_eq "$RETRY_POINTER|$([ -z "$RETRY_TEXT" ] || printf 'landed')|$(awaited jq -r 'select(.last_poll_ok == true) | .last_poll_ok' "$RETRY_ROOT/tmp/slack/status.json")" \
    "$want_count|$([ "$want_count" = 0 ] || printf 'landed')|true" \
    "$failure/$mutant: old-thread retry carries its delivery id and parent once; disabling pending retry loses it"
  sk_relay_stop
  sk_bin_reset
done <<'ROWS'
parent none 200 1
mail none 200 1
parent retry 30 0
ROWS

# --- a live refusal and a secondary status error share the poll's containment ---
# lane-mail refuses the send and makes status.json a directory in the same
# call. The control narrows the shared catch so this filesystem error escapes.
while read -r mode tries want; do
  STATUS_ROOT="$(sk_new_root "live-status-$mode")"
  STATUS_HEALTHY="$(sk_new_root "live-status-healthy-$mode")"
  sk_bind "$STATUS_ROOT"
  sk_bind "$STATUS_HEALTHY"
  STATUS_CH="$(sk_channel "$STATUS_ROOT")"
  STATUS_HC="$(sk_channel "$STATUS_HEALTHY")"
  STATUS_PARENT="$(sk_inject "$STATUS_CH" U001 'Old status topic.' '' "\"ts\": \"$(python3 -c 'import time; print("%.6f" % (time.time() - 8 * 86400))')\"")"
  rm -- "$STATUS_ROOT/.agents/skills/orch/scripts"
  mkdir -p "$STATUS_ROOT/.agents/skills/orch/scripts"
  cat > "$STATUS_ROOT/.agents/skills/orch/scripts/lane-mail" <<EOF
#!/usr/bin/env bash
if [ -e "$STATUS_ROOT/tmp/send-refused" ]; then
  case " \$* " in *" send "*)
    rm -- "$STATUS_ROOT/tmp/send-refused" "$STATUS_ROOT/tmp/slack/status.json" || exit 2
    mkdir "$STATUS_ROOT/tmp/slack/status.json" || exit 2
    echo 'lane-mail: send-refused' >&2; exit 2 ;;
  esac
fi
exec "$SK_LANE_MAIL" "\$@"
EOF
  chmod +x "$STATUS_ROOT/.agents/skills/orch/scripts/lane-mail"
  if [ "$mode" = control ]; then
    sk_mutant secondary-status relay.py 'except Exception as status_err:' 'except RuntimeError as status_err:'
  fi
  relay "$STATUS_ROOT" --root "$STATUS_HEALTHY"
  touch "$STATUS_ROOT/tmp/send-refused"
  STATUS_REPLY="$(sk_inject "$STATUS_CH" U001 'Retry after status failure.' "$STATUS_PARENT")"
  assert_eq "$(awaited python3 -c 'from pathlib import Path; import sys; p = Path(sys.argv[1]); print(p if p.is_dir() else "", end="")' "$STATUS_ROOT/tmp/slack/status.json")" \
    "$STATUS_ROOT/tmp/slack/status.json" "$mode: the live send refusal also breaks its status write"
  STATUS_NEXT="$(sk_inject "$STATUS_HC" U001 'Other root still receives.')"
  STATUS_TEXT="$(landed "$STATUS_HEALTHY" "$STATUS_HC:$STATUS_NEXT" "$tries")"
  if [ "$mode" = production ]; then
    assert_has "$(sed -n '1p' "$SK_TMP/relay.err")" \
      "slack: lane-mail-failed=lane-mail: send-refused root=$STATUS_ROOT status=IsADirectoryError:" \
      "the primary live refusal retains its cause and names the secondary status error"
  fi
  rmdir "$STATUS_ROOT/tmp/slack/status.json"
  STATUS_RETRIED="$(landed "$STATUS_ROOT" "$STATUS_CH:$STATUS_REPLY" "$tries")"
  # Count exact delivery values, including the old reply's parent pointer.
  if [ -f "$(sk_box "$STATUS_ROOT")/to-lane.jsonl" ]; then
    STATUS_COUNTS="$(jq -s --arg d "$STATUS_CH:$STATUS_REPLY" --arg ts "$STATUS_PARENT" \
      '[.[] | select(.delivery_id == $d and .text == "Retry after status failure." and .thread_ts == $ts and .parent == {ts:$ts,author:"owner",excerpt:"Old status topic."})] | length' "$(sk_box "$STATUS_ROOT")/to-lane.jsonl")" || exit 1
  else
    # No mailbox is created when the control stops before any delivery.
    STATUS_COUNTS=0
  fi
  assert_eq "$STATUS_COUNTS|$STATUS_RETRIED|$STATUS_TEXT" \
    "$want" "$mode: status failure containment keeps pending delivery and other-root progress; removing it fails the same instrument"
  sk_relay_stop
  sk_bin_reset
done <<'ROWS'
production 200 1|Retry after status failure.|Other root still receives.
control 30 0||
ROWS

# --- two roots on one relay: each channel's event lands in its own mailbox ------------------
# IOTA is bound, so the app is in its channel and Slack sends its events,
# but the relay is not given it.
ZETA="$(sk_new_root zeta)"
sk_bind "$ZETA"
ETA="$(sk_new_root eta)"
sk_bind "$ETA"
IOTA="$(sk_new_root iota)"
sk_bind "$IOTA"
ZC="$(sk_channel "$ZETA")"
EC="$(sk_channel "$ETA")"
IC="$(sk_channel "$IOTA")"
relay "$ZETA" --root "$ETA"
sk_inject "$IC" U001 'for no root here' >/dev/null
TZ="$(sk_inject "$ZC" U001 'for zeta')"
TE="$(sk_inject "$EC" U001 'for eta')"
assert_eq "$(landed "$ZETA" "$ZC:$TZ")|$(landed "$ETA" "$EC:$TE")|$(texts "$ZETA")|$(texts "$ETA")" "for zeta|for eta|for zeta |for eta " \
  "two roots on one relay: each channel's event lands in its own root's mailbox, not the other's and not an unbound channel's"
sk_relay_stop

# --- an event whose delivery lane-mail refused: the next poll lands it ---------------
# THETA's lane-mail refuses one `send` while tmp/send-refused stands, and
# removes the file as it refuses.
THETA="$(sk_new_root theta)"
rm -- "${THETA:?}/.agents/skills/orch/scripts"
mkdir -p "$THETA/.agents/skills/orch/scripts"
cat > "$THETA/.agents/skills/orch/scripts/lane-mail" <<EOF
#!/usr/bin/env bash
if [ -e "${THETA:?}/tmp/send-refused" ]; then
  case " \$* " in *" send "*) rm -- "${THETA:?}/tmp/send-refused"; echo 'lane-mail: send-refused' >&2; exit 2 ;; esac
fi
exec "$SK_LANE_MAIL" "\$@"
EOF
chmod +x "$THETA/.agents/skills/orch/scripts/lane-mail"
sk_bind "$THETA"
TC="$(sk_channel "$THETA")"
relay "$THETA"
touch "$THETA/tmp/send-refused"
TT="$(sk_inject "$TC" U001 'refused once')"
assert_eq "$(landed "$THETA" "$TC:$TT")" "refused once" "an event whose delivery lane-mail refused lands through the next poll's pending retry"
assert_has "$(cat "$SK_TMP/relay.err")" "slack: lane-mail-failed=lane-mail: send-refused" "the refused event delivery is printed"
sk_relay_stop

# --- a dropped connection: the lost envelope lands on the reconnect ---------------------------
GAMMA="$(sk_new_root gamma)"
sk_bind "$GAMMA"
GC="$(sk_channel "$GAMMA")"
drop_one() { # ROOT [TRIES] — one envelope lost with its connection; LOST is its message's ts
  local channel
  channel="$(sk_channel "$1")"
  relay "$1"
  sk_ctl /_test/fault '{"method": "socket", "drop": true}' >/dev/null
  LOST="$(sk_inject "$channel" U001 'sent while the connection dropped')"
  LOST_TEXT="$(landed "$1" "$channel:$LOST" "${2:-200}")"
}
OPENED="$(sk_state .opened)"
drop_one "$GAMMA"
assert_eq "$(sk_state '.withheld | length')" "1" "the fake withheld one envelope and closed the connection"
assert_eq "$LOST_TEXT" "sent while the connection dropped" "the message of the lost envelope lands through the history read of the reconnect"
assert_eq "$(sk_state .opened)" "$((OPENED + 2))" "the relay opened its connection, then one new one after the drop"
assert_eq "$(lines "$GAMMA" connect)|$(lines "$GAMMA" disconnect)|$(lines "$GAMMA" reconnect)" "connect |disconnect connection ended|reconnect " \
  "the journal holds connect, the disconnect with its reason, then reconnect"
# The landing precedes the poll's `in`, `mark` and `seen` rows; `seen` is the last.
awaited jq -r --arg ts "$LOST" 'select(.t == "seen" and .ts == $ts) | .ts' "$(sk_journal "$GAMMA")" >/dev/null
assert_eq "$(jq -r 'select(.t != "connect" and .t != "disconnect" and .t != "reconnect") | .t' "$(sk_journal "$GAMMA")" | tr '\n' ' ')" "seen start in mark seen " \
  "the directive is delivered once, then marked"

# --- Slack's disconnect envelope: a new connection -----------------------------------------
OPENED="$(sk_state .opened)"
POLLED_AT="$(last_poll "$GAMMA")"
sk_ctl /_test/socket '{"disconnect": "refresh_requested"}' >/dev/null
assert_eq "$(awaited opened_at_least $((OPENED + 1)))" "yes" "Slack's disconnect envelope is answered with a new connection"
assert_eq "$(lines "$GAMMA" disconnect | sed -n '2p')" "disconnect slack-refresh_requested" "the disconnect is journaled with Slack's reason"
TS2="$(sk_inject "$GC" U001 'after the refresh')"
assert_eq "$(landed "$GAMMA" "$GC:$TS2")" "after the refresh" "a message after the refresh lands from its event"
awaited reconnect_polled "$GAMMA" "$POLLED_AT" >/dev/null
assert_eq "$(state_link "$GAMMA")" "ok connected" "after the refresh the doctor row reads ok and connected"

# --- a relay that cannot reconnect shows reconnecting ----------------------------------------
sk_ctl /_test/fault '{"method": "apps.connections.open", "error": "internal_error", "times": 100}' >/dev/null
sk_ctl /_test/fault '{"method": "socket", "drop": true}' >/dev/null
sk_inject "$GC" U001 'drops the connection' >/dev/null
reconnecting() { [ "$(connection "$GAMMA")" = reconnecting ] && echo yes; }
assert_eq "$(awaited reconnecting)" "yes" "a relay whose connect Slack refuses shows reconnecting"
assert_has "$(cat "$SK_TMP/relay.err")" "slack: slack-api-failed=apps.connections.open error=internal_error" "the refused connect is printed"
sk_relay_stop
sk_ctl /_test/faults-reset >/dev/null

# --- a reconnect whose history read Slack refused: a later poll reads it ---------------------
KAPPA="$(sk_new_root kappa)"
sk_bind "$KAPPA"
KC="$(sk_channel "$KAPPA")"
# refused_read [TRIES] — drop the connection with one envelope withheld and
# refuse the reconnect's history read; KAPPA_TEXT is what landed of it.
refused_read() {
  relay "$KAPPA"
  OPENED="$(sk_state .opened)"
  sk_ctl /_test/fault '{"method": "conversations.history", "error": "internal_error"}' >/dev/null
  sk_ctl /_test/fault '{"method": "socket", "drop": true}' >/dev/null
  KT="$(sk_inject "$KC" U001 'sent while the read was refused')"
  KAPPA_TEXT="$(landed "$KAPPA" "$KC:$KT" "${1:-200}")"
}
refused_read
assert_eq "$KAPPA_TEXT|$(sk_state .opened)" "sent while the read was refused|$((OPENED + 1))" \
  "a reconnect whose history read Slack refused delivers the message on a later poll, with no second reconnect"
assert_has "$(cat "$SK_TMP/relay.err")" "slack: slack-api-failed=conversations.history error=internal_error" "the reconnect's history read was refused"
sk_relay_stop
sk_ctl /_test/faults-reset >/dev/null

# --- a first start refused after its connect: the next start still seeds ---------------------
# refused_first ROOT — ROOT adopts C888, which holds owner messages from
# before the binding; a relay connects and its first poll is refused, an
# owner SLACK_OWNERS adds being unknown to Slack, then a poll with the bound
# owners follows.
for n in 1 2 3; do sk_inject C888 U001 "before the binding $n" >/dev/null; done
refused_first() {
  sk_run -- setup --root "$1" --take C888
  relay "$1" SLACK_OWNERS="$OWNERS,nobody@example.test"
  sk_relay_stop
  FIRST_LINES="$(jq -r .t "$(sk_journal "$1")" | tr '\n' ' ')"
  sk_poll "$1"
}
MU="$(sk_new_root mu)"
refused_first "$MU"
assert_eq "$FIRST_LINES" "connect " "the refused first poll leaves a journal of the connect line alone"
assert_eq "$RC=$([ ! -f "$(sk_box "$MU")/to-lane.jsonl" ] || texts "$MU")" "0=" "the next start seeds, and the channel's earlier messages are not delivered"
assert_eq "$(jq -r 'select(.t == "seen" or .t == "start") | .t' "$(sk_journal "$MU")" | tr '\n' ' ')" "seen start " "the next start journals both seeds"

# --- delivery timing and diagnostics, with the same assertions on mutants ---
for variant in normal late-ack worker-ack no-mark no-notice; do
  case "$variant" in
    late-ack) sk_mutant delivery-ack relay.py '(        if envelope.get\("envelope_id"\):\n)(            socket.send_text[^\n]+)' '\1            self.deliver(envelope)\n\2' ;;
    worker-ack) sk_mutant delivery-reader relay.py '            socket.send_text\(json.dumps\(\{"envelope_id": envelope\["envelope_id"\]\}\)\)([\s\S]*?def deliver\(self, envelope: Dict\) -> None:\n        """[^\n]+\n)' '            pass\1        if envelope.get("envelope_id"):\n            self.socket.send_text(json.dumps({"envelope_id": envelope["envelope_id"]}))\n' ;;
    no-mark) sk_mutant delivery-mark relay.py '(        notice\("delivered", f"ts=\{ts\} id=\{envelope\} path=\{path\}"\)\n)        self.mark_seen\(\[ts\]\)' '\1        pass' ;;
    no-notice) sk_mutant delivery-notice relay.py '        notice\("delivered", f"ts=\{ts\} id=\{envelope\} path=\{path\}"\)' '        pass' ;;
  esac
  SLOW="$(sk_new_root "delivery-$variant")"
  sk_bind "$SLOW"
  SC="$(sk_channel "$SLOW")"
  rm -- "${SLOW:?}/.agents/skills/orch/scripts"
  mkdir -p "$SLOW/.agents/skills/orch/scripts"
  cat > "$SLOW/.agents/skills/orch/scripts/lane-mail" <<EOF
#!/usr/bin/env python3
import json, os, pathlib, sys, time, urllib.request
if sys.argv[1] == "send" and not pathlib.Path("tmp/send-start").exists():
    state = json.load(urllib.request.urlopen("$SK_URL/_test/state"))
    sent = [e["envelope_id"] for e in state["sent"] if e["channel"] == "$SC"]
    pathlib.Path("tmp/send-start").write_text(str(all(e in state["acks"] for e in sent)))
    time.sleep(4)  # Real wait: the next envelope must be acked during mailbox work.
os.execv("$SK_LANE_MAIL", ["$SK_LANE_MAIL", *sys.argv[1:]])
EOF
  chmod +x "$SLOW/.agents/skills/orch/scripts/lane-mail"
  relay "$SLOW" SLACK_POLL_SECONDS=60
  SA="$(sk_inject "$SC" U001 'Slow A')"
  START="$(awaited cat "$SLOW/tmp/send-start" 2>/dev/null)"
  SB="$(sk_inject "$SC" U001 'Fast B')"
  sk_ctl /_test/socket "{\"ping\":\"slow-$variant\"}" >/dev/null
  sleep 0.5 # Observe B while A still holds the worker, before any poll.
  ACK_B="$(envelope "$SC" "$SB")"
  PONG_B="$(sk_ctl /_test/state | jq --arg p "slow-$variant" '[.pongs[] | select(. == $p)] | length')"
  landed "$SLOW" "$SC:$SB" >/dev/null
  ID="$(jq -r --arg d "$SC:$SA" 'select(.delivery_id == $d) | .id' "$(sk_box "$SLOW")/to-lane.jsonl")"
  case "$variant" in
    late-ack) sk_assert_red "$START" True 'control: ack follows slow delivery' ;;
    worker-ack) sk_assert_red "$ACK_B" 'sent=1 unacked=0' 'control: worker ack waits behind A' ;;
    no-mark) sk_assert_red "$(sk_reactions "$SC" "$SA")" eyes 'control: live delivery mark removed' ;;
    no-notice) sk_assert_red "$(grep -Fc "slack: delivered=ts=$SA id=$ID path=live" "$SK_TMP/relay.out")" 1 'control: delivery notice removed' ;;
    normal)
      assert_eq "$START|$ACK_B" 'True|sent=1 unacked=0' 'A ack precedes send; B ack does not wait for A'
      assert_eq "$PONG_B" 1 'slow mailbox does not block pong'
      assert_eq "$(sk_reactions "$SC" "$SA")" eyes 'live delivery gets eyes before a poll'
      assert_eq "$(grep -Fc "slack: delivered=ts=$SA id=$ID path=live" "$SK_TMP/relay.out")" 1 'one live delivery notice identifies mailbox id'
      ;;
  esac
  sk_relay_stop
  sk_bin_reset
done

# Initial discovery spans history; reconnect reads from the saved position.
for variant in normal horizon; do
  if [ "$variant" = horizon ]; then
    sk_mutant reconnect-position relay.py 'oldest = position if self.discovered or ' 'oldest = position if '
  fi
  POS="$(sk_new_root "positions-$variant")"
  sk_bind "$POS"
  PC="$(sk_channel "$POS")"
  for n in 1 2 3 4 5; do PT="$(sk_inject "$PC" U001 "Parent $n")"; done
  sk_poll "$POS"
  sk_inject "$PC" U001 'Missed reply under retained parent' "$PT" >/dev/null
  sk_recovery "$POS" positions
  assert_eq "$RC=$(printf '%s\n' "$OUT" | tail -n 1 | jq -r .error)" '0=' "$variant: reconnect probe completes without a refusal"
  COUNTS="$(printf '%s\n' "$OUT" | tail -n 1 | jq -r '[.polls[] | [.[] | select(.method == "conversations.history")] | length] | join("/")')"
  if [ "$variant" = normal ]; then
    assert_eq "$COUNTS" 3/1 'reconnect does not repeat history pages with no new roots'
    assert_eq "$(printf '%s\n' "$OUT" | tail -n 1 | jq -r '[.polls[1][] | select(.method == "conversations.replies")] | length')" 5 'reconnect preserves retained eligible parent discovery'
  else
    sk_assert_red "$COUNTS" 3/1 'control: resetting history to horizon repeats pages'
  fi
  sk_bin_reset
done

# Shipped direct posts and ignored parents can get their first reply offline.
# Ignored parents also carry the bot's rejection, adding a replies page.
while read -r kind author reply_calls excerpt; do
  for variant in normal incomplete; do
    FIRST="$(sk_new_root "first-$kind-$variant")"
    sk_bind "$FIRST"
    FC="$(sk_channel "$FIRST")"
    case "$kind" in
      text) sk_run -- post --root "$FIRST" --text "$excerpt" ;;
      file) sk_run -- post --root "$FIRST" --file "$(sk_text first-file 'Report bytes.')" --text "$excerpt" ;;
      not-owner) sk_inject "$FC" U999 "$excerpt" >/dev/null ;;
      no-text) excerpt=""; sk_inject "$FC" U001 '' >/dev/null ;;
    esac
    FP="$(sk_state ".messages.${FC}[-1].ts")"
    for n in 1 2 3 4; do LAST="$(sk_inject "$FC" U001 "Later parent $n")"; done
    jq -cn --arg c "$FC" --arg ts "$FP" \
      '[{channel:$c,user:"U001",text:"First offline reply.",thread_ts:$ts}]' >"$SK_TMP/first-reply.json"
    if [ "$variant" = incomplete ]; then
      sk_mutant first-discovery relay.py 'if float\(m\["ts"\]\) >= horizon or m.get\("latest_reply"\)' 'if m.get("latest_reply")'
    fi
    sk_ctl /_test/calls-reset >/dev/null
    sk_recovery "$FIRST" positions "$SK_TMP/first-reply.json"
    PROBE="$(printf '%s\n' "$OUT" | tail -n 1)"
    FR="$(printf '%s\n' "$PROBE" | jq -r '.injected[0]')"
    assert_eq "$RC=$(printf '%s\n' "$PROBE" | jq -r '[.error, ([.polls[] | [.[] | select(.method == "conversations.history")] | length] | join("/")), .polls[1][0].oldest] | join("|")')" \
      "0=|3/1|$LAST" "$kind/$variant: reconnect history uses the saved position, not discovery pages"
    FIRST_ID="$(jq -r --arg d "$FC:$FR" 'select(.delivery_id == $d) | .id' "$(sk_box "$FIRST")/to-lane.jsonl")"
    FIRST_CONTEXT="$(jq -s --arg d "$FC:$FR" --arg ts "$FP" --arg a "$author" --arg e "$excerpt" \
      '[.[] | select(.delivery_id == $d) | {text,thread_ts,parent}] == [{text:"First offline reply.",thread_ts:$ts,parent:{ts:$ts,author:$a,excerpt:$e}}]' "$(sk_box "$FIRST")/to-lane.jsonl")"
    FIRST_LOGS="$(printf '%s\n' "$OUT" | grep -Fxc "slack: delivered=ts=$FR id=$FIRST_ID path=catch-up")"
    RESULT="$FIRST_CONTEXT|$(sk_reactions "$FC" "$FR")|$FIRST_LOGS"
    if [ "$variant" = normal ]; then
      assert_eq "$RESULT" 'true|eyes|1' "$kind: first offline reply lands once with parent context, eyes and its ts/mailbox notice"
      assert_eq "$(printf '%s\n' "$PROBE" | jq -r '[.polls[] | [.[] | select(.method == "conversations.replies")] | length] | join("/")')" \
        "$reply_calls" "$kind: history caches reply-free parents without a parent fetch and reconnect reads every retained parent's pages"
      assert_eq "$(jq -s --arg ts "$FP" '[.[] | select(.t == "parent" and .ts == $ts)] | length' "$(sk_journal "$FIRST")")" \
        1 "$kind: the parent record persists once before narrowing history"
    else
      sk_assert_red "$RESULT" 'true|eyes|1' "$kind: incomplete discovery loses the first reply"
      assert_eq "$RESULT" 'false||0' "$kind: incomplete discovery produces neither a delivery, eyes nor a notice"
    fi
    sk_bin_reset
  done
done <<'ROWS'
text bot 0/5 Direct text topic.
file bot 0/5 Direct file topic.
not-owner owner 0/6 Ignored topic.
no-text owner 0/6 empty
ROWS

# --- a reconnect's catch-up under Slack's rate limit ---------------------------------------
# The drop withholds a reply's envelope, so the reconnect's catch-up alone can
# land it. In the `rate` row Slack answers that catch-up's history read, then
# its thread read, with 429 and a Retry-After past the poll interval. Each
# ends its poll's catch-up, so the poll after the reconnect records ok and
# connected within one interval, a live message lands from its event, and the
# first poll past the second Retry-After lands the reply. `none` reconnects
# with no limit; `control` waits out the Retry-After again.
deliveries() { jq -s --arg d "$2" '[.[] | select(.delivery_id == $d)] | length' "$(sk_box "$1")/to-lane.jsonl"; } # ROOT DELIVERY_ID
for row in rate none control; do
  [ "$row" != control ] || sk_mutant rate-wait api.py 'if err\.code == 429 and attempt < retries:' 'if err.code == 429 and attempt < RETRIES:'
  RATE="$(sk_new_root "rate-$row")"
  sk_bind "$RATE"
  RC_CH="$(sk_channel "$RATE")"
  relay "$RATE" SLACK_POLL_SECONDS=3
  TOPIC="$(sk_inject "$RC_CH" U001 'Rate topic.')"
  landed "$RATE" "$RC_CH:$TOPIC" >/dev/null
  POLLED_AT="$(last_poll "$RATE")"
  if [ "$row" != none ]; then
    sk_ctl /_test/fault '{"method":"conversations.history","status":429,"retry_after":5}' >/dev/null
    sk_ctl /_test/fault '{"method":"conversations.replies","status":429,"retry_after":5}' >/dev/null
  fi
  sk_ctl /_test/fault '{"method": "socket", "drop": true}' >/dev/null
  OFFLINE="$(sk_inject "$RC_CH" U001 'Reply while dropped.' "$TOPIC")"
  # One poll interval: the poll after the reconnect runs at once.
  POLLED="$(AWAIT_TRIES=30 awaited reconnect_polled "$RATE" "$POLLED_AT")"
  LIVE="$(sk_inject "$RC_CH" U001 'Live during the limit.')"
  LIVE_TEXT="$(landed "$RATE" "$RC_CH:$LIVE" 30)"
  if [ "$row" = control ]; then
    sk_assert_red "$POLLED|$LIVE_TEXT" 'yes|Live during the limit.' 'control: a catch-up that waits out Retry-After holds the poll and the live message'
  else
    assert_eq "$POLLED|$LIVE_TEXT|$(state_link "$RATE")" 'yes|Live during the limit.|ok connected' \
      "$row: the poll after the reconnect records ok and connected within one interval, and a live message lands from its event"
    OFFLINE_TEXT="$(landed "$RATE" "$RC_CH:$OFFLINE")"
    # The relay prints each delivery notice after its mailbox append.
    awaited grep -E "^slack: delivered=ts=$LIVE id=[^ ]+ path=live\$" "$SK_TMP/relay.out" >/dev/null
    awaited grep -E "^slack: delivered=ts=$OFFLINE id=[^ ]+ path=catch-up\$" "$SK_TMP/relay.out" >/dev/null
    assert_eq "$OFFLINE_TEXT|$(deliveries "$RATE" "$RC_CH:$OFFLINE")|$(deliveries "$RATE" "$RC_CH:$LIVE")" 'Reply while dropped.|1|1' \
      "$row: a later poll finishes the catch-up, and each message lands once"
    assert_eq "$(grep -Ec "^slack: delivered=ts=$LIVE id=[^ ]+ path=live\$" "$SK_TMP/relay.out")|$(grep -Ec "^slack: delivered=ts=$OFFLINE id=[^ ]+ path=catch-up\$" "$SK_TMP/relay.out")" \
      '1|1' "$row: the live message lands from its event and the withheld reply from the catch-up"
    WANT_LIMITED=0
    [ "$row" = none ] || WANT_LIMITED=2
    assert_eq "$(grep -Ec '^slack: slack-rate-limited=conversations\.(history|replies)$' "$SK_TMP/relay.err")" "$WANT_LIMITED" \
      "$row: each rate-limited catch-up read is printed once"
  fi
  sk_relay_stop
  sk_ctl /_test/faults-reset >/dev/null
  sk_bin_reset
done

# Settled eyes failures retain a retry and print the actual Slack cause.
for failure in no_reaction message_not_found internal_error mutant; do
  if [ "$failure" = mutant ]; then
    sk_mutant eyes-cause relay.py 'if method == "reactions.add" and name == SEEN and err.error != "already_reacted" or err.error not in MARK_SETTLED:' 'if err.error not in MARK_SETTLED:'
    failure=no_reaction
    CONTROL=yes
  else
    CONTROL=no
  fi
  sk_ctl /_test/fault "{\"method\":\"reactions.add\",\"error\":\"$failure\"}" >/dev/null
  ER="$(sk_new_root "eyes-$failure")"
  sk_bind "$ER"
  EC2="$(sk_channel "$ER")"
  ET="$(sk_inject "$EC2" U001 'Eyes refused')"
  sk_event "$ER" "$EC2" "$ET" 2>"$SK_TMP/eyes.err"
  if [ "$CONTROL" = yes ]; then
    sk_assert_red "$(grep -c '^slack: slack-api-failed=reactions.add error=no_reaction' "$SK_TMP/eyes.err")" 1 'control: settled eyes failure becomes silent'
  else
    assert_has "$(cat "$SK_TMP/eyes.err")" "slack: slack-api-failed=reactions.add error=$failure" 'refused eyes prints a keyed cause'
    sk_poll "$ER"
    assert_eq "$(sk_reactions "$EC2" "$ET")" eyes 'refused eyes retries on the next poll'
  fi
  sk_bin_reset
done

# --- controls, one mutant per rule -------------------------------------------------------------
sk_mutant ack relay.py 'socket\.send_text\(json\.dumps\(\{"envelope_id": envelope\["envelope_id"\]\}\)\)' 'pass'
DELTA="$(sk_new_root delta)"
sk_bind "$DELTA"
DC="$(sk_channel "$DELTA")"
relay "$DELTA"
TS3="$(sk_inject "$DC" U001 'unacknowledged')"
landed "$DELTA" "$DC:$TS3" >/dev/null
assert_eq "$(envelope "$DC" "$TS3")" "sent=1 unacked=1" "control: the acknowledgement gone, the envelope stays unacknowledged"
sk_relay_stop
sk_bin_reset

sk_mutant token-type api.py '"token_expired",\n    "not_allowed_token_type",' '"token_expired",'
sk_relay_start "$ROOT" SLACK_APP_TOKEN="$SK_TOKEN"
assert_eq "$(connection "$ROOT")" "reconnecting" "control: the token type no longer judged, a bot token in SLACK_APP_TOKEN leaves the relay reconnecting"
sk_relay_stop
sk_bin_reset

sk_mutant app-scope api.py 'if error in AUTH_ERRORS or error == "missing_scope" and self\.scope:' 'if error in AUTH_ERRORS:'
sk_ctl /_test/fault '{"method": "apps.connections.open", "error": "missing_scope", "times": 100}' >/dev/null
sk_relay_start "$ROOT"
assert_eq "$(connection "$ROOT")" "reconnecting" "control: missing_scope no longer refusing the app token, the relay stays reconnecting"
sk_relay_stop
sk_ctl /_test/faults-reset >/dev/null
sk_bin_reset

sk_mutant events relay.py 'root\.on_message\(event, self\.bot_user\)' 'pass'
relay "$DELTA"
TS4="$(sk_inject "$DC" U001 'unread event')"
assert_eq "$(landed "$DELTA" "$DC:$TS4" 30)" "" "control: events unread, a message does not land within the short bound"
sk_relay_stop
sk_bin_reset

sk_mutant routing relay.py 'root = self\.by_channel\.get\(str\(event\.get\("channel", ""\)\)\)' 'root = self.roots[0]'
relay "$ZETA" --root "$ETA"
TE2="$(sk_inject "$EC" U001 'for eta again')"
assert_eq "$(landed "$ZETA" "$ZC:$TE2")" "for eta again" "control: routing by channel gone, eta's message lands in zeta's mailbox"
sk_relay_stop
sk_bin_reset

sk_mutant unbound relay.py 'root = self\.by_channel\.get\(str\(event\.get\("channel", ""\)\)\)' 'root = self.by_channel.get(str(event.get("channel", ""))) or self.roots[0]'
relay "$ZETA" --root "$ETA"
TI="$(sk_inject "$IC" U001 'unbound, routed anyway')"
assert_eq "$(landed "$ZETA" "$ZC:$TI")" "unbound, routed anyway" "control: an unbound channel's event falls to the first root, and lands in zeta's mailbox"
sk_relay_stop
sk_bin_reset


sk_mutant catch-up relay.py 'root\.journal\.append\(t=kind, at=self\.since\)\n            root\.due = set\(\)' 'root.journal.append(t=kind, at=self.since)'
EPS="$(sk_new_root eps)"
sk_bind "$EPS"
drop_one "$EPS" 30
assert_eq "$LOST_TEXT" "" "control: no history read on a connect, the lost envelope's message never lands"
sk_relay_stop
sk_bin_reset

sk_mutant read-due relay.py '        horizon = self\.settings\.horizon\(self\.clock\(\)\)\n        position = self\.state\.seen_ts' '        self.due = None\n        horizon = self.settings.horizon(self.clock())\n        position = self.state.seen_ts'
refused_read 30
assert_eq "$KAPPA_TEXT" "" "control: the read marked done before Slack answers, the refused reconnect's message does not land within the short bound"
sk_relay_stop
sk_ctl /_test/faults-reset >/dev/null
sk_bin_reset

sk_mutant event-age relay.py '        if thread_ts == ts:\n            self.bind_file_share\(message\)' '        if thread_ts != ts and float(thread_ts) < self.settings.horizon(self.clock()):\n            return\n        if thread_ts == ts:\n            self.bind_file_share(message)'
relay "$BETA"
OR2="$(sk_inject C002 U001 'late under the old one' "$OLD")"
assert_eq "$(landed "$BETA" "C002:$OR2")" "" "control: the obsolete live age gate loses the old-thread reply"
sk_relay_stop
sk_bin_reset

sk_mutant seeded relay.py 'if not self\.state\.seeded:' 'if not __import__("store").journal_exists(self.path):'
NU="$(sk_new_root nu)"
refused_first "$NU"
assert_eq "$(texts "$NU")" "before the binding 1 before the binding 2 before the binding 3 " \
  "control: any journal read as seeded, the channel's earlier messages are delivered"
sk_bin_reset

sk_mutant link-clear relay.py 'self\.set_connection\("connected"\)\n        self\.connection_error = ""' 'self.set_connection("connected")'
relay "$GAMMA"
OPENED="$(sk_state .opened)"
POLLED_AT="$(last_poll "$GAMMA")"
sk_ctl /_test/socket '{"disconnect": "refresh_requested"}' >/dev/null
awaited opened_at_least $((OPENED + 1)) >/dev/null
TS5="$(sk_inject "$GC" U001 'after the refresh, error kept')"
landed "$GAMMA" "$GC:$TS5" >/dev/null
awaited reconnect_polled "$GAMMA" "$POLLED_AT" >/dev/null
assert_eq "$(state_link "$GAMMA")" "failing connected" "control: the connection error kept past a reconnect, the refreshed relay's row reads failing"
sk_relay_stop
sk_bin_reset

sk_summary
