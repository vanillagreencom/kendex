#!/usr/bin/env bash
# A running relay re-executes onto its package's new code, against the fake's
# WebSocket and a copy of the package a row edits as an update does. The
# rows: the status record and the doctor row carry the fingerprint of the
# code the relay runs; a file that changes between every two polls, an update
# still being written, is never loaded; an update that holds for two polls is
# loaded in the same process, with a new connection, a catch-up and the
# launch checkout's settings read again; a code file that cannot be read
# keeps the running code and reads failing with its refusal; a refused live
# reply under a thread past SLACK_THREAD_DAYS defers the reload on its open
# connection until the reply lands; a reply acknowledged during the settling
# poll is delivered before the reload, and its refused delivery defers it; a
# relay reconnecting, or whose connection dropped during the settling poll,
# defers it until the connection opens. A positive row waits up to twenty
# seconds, a control six. The controls: the check gone from the loop, the
# two-poll rule gone, the new image started under the loaded environment,
# the doctor row without the code, the refusal kept out of the status
# record, the held-reply check gone before the close, the queue left
# undelivered, the held-reply check gone after it, the connection check
# gone, and a drop in the queue ignored.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack listen: reload on update ==="

ALPHA="$(sk_new_root alpha)"
ROOT="$ALPHA"
sk_bind "$ROOT"
STATUS="$ROOT/tmp/slack/status.json"
# The launch checkout, whose private env file alone sets the poll interval.
SK_RUN_FROM="$SK_TMP/launch"
mkdir -p "$SK_RUN_FROM"
SK_RELAY_POLL=none

# code_of — 12 hex characters of one sha256 over SK_BIN's launcher and its
# lib/*.py in byte order, hashed here and not by the package
code_of() {
  local scripts="${SK_BIN%/*}"
  (export LC_ALL=C; cat -- "$scripts/slack" "$scripts"/lib/*.py) \
    | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])'
}
row() { sk_run -- listen --status --root "$ROOT"; LINE="$OUT"; }
# row_until KEY WANT SECONDS — the doctor row once KEY reads WANT, or the
# last one read SECONDS from now
row_until() {
  local end=$((SECONDS + $3))
  row
  while [ "$(field "$LINE" "$1")" != "$2" ] && [ "$SECONDS" -lt "$end" ]; do
    sleep 0.1
    row
  done
}
pid() { jq -r .pid "$STATUS"; }
reloads() { grep -c '^slack: reloading=' "$SK_TMP/relay.out"; }
# closes — the connections ROOT's journal records closed for a reload
closes() { jq -r 'select(.t == "disconnect" and .reason == "reload") | .t' "$(sk_journal "$ROOT")" | wc -l | tr -d ' '; }
# fresh NAME — ROOT a new bound root whose lane-mail `mailer` writes, OLD a
# parent past SLACK_THREAD_DAYS in its channel OC
fresh() {
  ROOT="$(sk_new_root "$1")"
  STATUS="$ROOT/tmp/slack/status.json"
  sk_bind "$ROOT"
  OC="$(sk_channel "$ROOT")"
  OLD="$(sk_inject "$OC" U001 'an old topic' '' "\"ts\": \"$(python3 -c 'import time; print("%.6f" % (time.time() - 8 * 86400))')\"")"
  rm -- "${ROOT:?}/.agents/skills/orch/scripts"
  mkdir -p "$ROOT/.agents/skills/orch/scripts"
}
# mailer — ROOT's lane-mail for the package copy in use: `send` refused while
# tmp/send-refused stands. While tmp/race holds a count, each `events` call,
# one per poll, raises it: the first appends an update to relay.py, which the
# next poll reads and the one after settles, and the third holds that
# settling poll after writing tmp/held.
mailer() {
  cat > "$ROOT/.agents/skills/orch/scripts/lane-mail" <<EOF
#!/usr/bin/env bash
case "\$1" in
  send) [ ! -e "$ROOT/tmp/send-refused" ] || { echo 'lane-mail: send-refused' >&2; exit 2; } ;;
  events)
    if [ -e "$ROOT/tmp/race" ]; then
      n=\$((\$(cat "$ROOT/tmp/race") + 1))
      printf '%s\n' "\$n" > "$ROOT/tmp/race"
      [ "\$n" != 1 ] || printf '# update\n' >> "${SK_BIN%/*}/lib/relay.py"
      if [ "\$n" = 3 ]; then
        rm -- "$ROOT/tmp/race"
        touch "$ROOT/tmp/held"
        sleep 3 # Real wait: the reply arrives while the settling poll runs.
      fi
    fi ;;
esac
exec "$SK_LANE_MAIL" "\$@"
EOF
  chmod +x "$ROOT/.agents/skills/orch/scripts/lane-mail"
}
# held — a reply under OLD whose delivery lane-mail refuses; RT is its ts
held() {
  touch "$ROOT/tmp/send-refused"
  RT="$(sk_inject "$OC" U001 'held across the reload' "$OLD")"
}
# settling ACTION — the update the mailer writes, and ACTION run while the
# poll that settles it runs
settling() {
  local tries=0
  printf '0\n' > "$ROOT/tmp/race"
  while [ ! -e "$ROOT/tmp/held" ] && [ "$tries" -lt 100 ]; do tries=$((tries + 1)); sleep 0.1; done
  [ -e "$ROOT/tmp/held" ] || { printf 'the settling poll never ran on %s\n' "$ROOT" >&2; exit 1; }
  "$1"
}
# outage — the connection dropped and every connect refused
outage() {
  sk_ctl /_test/fault '{"method": "apps.connections.open", "error": "internal_error", "times": 100}' >/dev/null
  sk_ctl /_test/fault '{"method": "socket", "drop": true}' >/dev/null
  sk_inject "$OC" U001 'drops the connection' >/dev/null
  row_until connection reconnecting 20
}
# start NAME — a relay over ROOT on the package copy NAME sk_copy or
# sk_mutant made, polling every second
start() {
  printf 'export SLACK_POLL_SECONDS=1\n' > "$SK_RUN_FROM/.env.local"
  sk_relay_start "$ROOT"
  row
  [ "$(field "$LINE" connection)" = connected ] || { printf 'relay on %s did not connect\n' "$ROOT" >&2; exit 1; }
}
# churn — relay.py rewritten every fifth of a second for five seconds, so no
# two polls a second apart read the same file, then one last edit
churn() {
  local n=0
  while [ "$n" -lt 25 ]; do
    printf '# churn %s\n' "$n" >> "${SK_BIN%/*}/lib/relay.py"
    sleep 0.2
    n=$((n + 1))
  done
  printf '# update\n' >> "${SK_BIN%/*}/lib/relay.py"
}

# --- an update that holds for two polls is loaded; one still being written is not ---
sk_copy live
C0="$(code_of)"
start
PID="$(pid)"
row
assert_eq "$(field "$LINE" code)=$(jq -r .code "$STATUS")" "$C0=$C0" \
  "the status record and the doctor row carry the fingerprint of the code the relay runs"
assert_eq "$(jq -r .poll_seconds "$STATUS")" "1" "the relay reads the poll interval from the launch checkout"
sk_ctl /_test/calls-reset >/dev/null
printf 'export SLACK_POLL_SECONDS=2\n' > "$SK_RUN_FROM/.env.local"
churn
C1="$(code_of)"
row_until code "$C1" 20
assert_eq "$(field "$LINE" code)=$(pid)" "$C1=$PID" "an update that holds for two polls is loaded in the same process"
assert_eq "$(reloads)=$(grep '^slack: reloading=' "$SK_TMP/relay.out")" "1=slack: reloading=$C1 running=$C0" \
  "a file that changed between every two polls was never loaded"
assert_eq "$(jq -r 'select(.t == "connect") | .t' "$(sk_journal "$ROOT")" | wc -l | tr -d ' ')" "2" \
  "the new image journals a connect of its own"
assert_eq "$(sk_state '[.calls[] | select(. == "apps.connections.open" or . == "conversations.history")] | unique | join(",")')" \
  "apps.connections.open,conversations.history" "the new image opens a connection and reads the channel's history"
assert_eq "$(jq -r .poll_seconds "$STATUS")" "2" "the new image reads the launch checkout's settings again"

# --- an unreadable code file keeps the running code ---
ln -s "$SK_TMP/missing" "${SK_BIN%/*}/lib/zz.py"
row_until state failing 20
assert_eq "$(field "$LINE" state)=${LINE#* fix=}" "failing=code-unreadable=${SK_BIN%/*}/lib/zz.py (No such file or directory)" \
  "an unreadable code file reads failing, with the refusal as its fix"
assert_eq "$(field "$LINE" code)=$(pid)=$(reloads)" "$C1=$PID=1" "an unreadable code file keeps the running code"
rm -- "${SK_BIN%/*}/lib/zz.py"
row_until state ok 20
assert_eq "$(field "$LINE" state)=$(field "$LINE" code)=$(reloads)" "ok=$C1=1" \
  "once the file reads again the relay is ok on the same code"
sk_relay_stop

# --- a held reply defers the reload on its open connection --------------------------
fresh deferred
sk_copy deferred
mailer
C0="$(code_of)"
start
held
row_until state failing 20
printf '# update\n' >> "${SK_BIN%/*}/lib/relay.py"
C1="$(code_of)"
row_until code "$C1" 6 # Real wait: two polls past the update, so a reload would have started.
assert_eq "$(field "$LINE" code)=$(reloads)=$(closes)" "$C0=0=0" \
  "a refused live reply under an old thread defers the reload, the connection kept"
rm -- "${ROOT:?}/tmp/send-refused"
row_until code "$C1" 20
assert_eq "$(landed "$ROOT" "$OC:$RT" 1)=$(field "$LINE" code)" "held across the reload=$C1" \
  "the held reply lands, then the relay reloads"
sk_relay_stop

# --- a reply acknowledged in the settling poll is delivered before the reload ------
fresh drained
sk_copy drained
mailer
C0="$(code_of)"
start
settling held
C1="$(code_of)"
row_until code "$C1" 6 # Real wait: past the held poll, so a reload would have started.
assert_eq "$(field "$LINE" code)=$(reloads)=$(closes)" "$C0=0=1" \
  "a reply the close delivered and lane-mail refused defers the reload, its connection opened again"
rm -- "${ROOT:?}/tmp/send-refused"
row_until code "$C1" 20
assert_eq "$(landed "$ROOT" "$OC:$RT" 1)=$(field "$LINE" code)" "held across the reload=$C1" \
  "the reply acknowledged in the settling poll lands, then the relay reloads"
sk_relay_stop

# --- a relay reconnecting defers the reload until the connection opens -------------
fresh outage
sk_copy outage
mailer
C0="$(code_of)"
start
PID="$(pid)"
outage
printf '# update\n' >> "${SK_BIN%/*}/lib/relay.py"
C1="$(code_of)"
row_until code "$C1" 6 # Real wait: two polls past the update, so a reload would have started.
assert_eq "$(field "$LINE" code)=$(field "$LINE" connection)=$(reloads)" "$C0=reconnecting=0" \
  "a relay reconnecting defers the reload"
sk_ctl /_test/faults-reset >/dev/null
row_until code "$C1" 20
assert_eq "$(field "$LINE" code)=$(pid)" "$C1=$PID" "once the connection opens the relay reloads"
sk_relay_stop

# --- a connection dropped in the settling poll defers the reload -------------------
fresh dropped
sk_copy dropped
mailer
C0="$(code_of)"
start
settling outage
C1="$(code_of)"
row_until code "$C1" 6 # Real wait: past the held poll, so a reload would have started.
assert_eq "$(field "$LINE" code)=$(field "$LINE" connection)=$(reloads)" "$C0=reconnecting=0" \
  "a connection dropped in the settling poll defers the reload"
sk_ctl /_test/faults-reset >/dev/null
row_until code "$C1" 20
assert_eq "$(field "$LINE" code)" "$C1" "once the connection opens again the relay reloads"
sk_relay_stop

# --- controls ---------------------------------------------------------------------
ROOT="$ALPHA"
STATUS="$ROOT/tmp/slack/status.json"
sk_mutant unchecked relay.py 'if self\.settled and self\.close_for_reload\(\):' 'if False:'
start
PID="$(pid)"
printf '# update\n' >> "${SK_BIN%/*}/lib/relay.py"
C1="$(code_of)"
row_until code "$C1" 6
sk_assert_red "$(field "$LINE" code)=$(pid)" "$C1=$PID" "control: the check gone from the loop, an update is never loaded"
sk_relay_stop

sk_mutant unsettled relay.py 'reading != self\.code and reading == self\.reading' 'reading != self.code'
start
churn
sleep 2 # two polls past the last edit, so the last reload has started
sk_assert_red "$(reloads)" "1" "control: the two-poll rule gone, a file still being written is loaded"
sk_relay_stop

sk_mutant loaded-env relay.py '\*sys\.argv\[1:\]\], CALLER_ENV\)' '*sys.argv[1:]], dict(os.environ))'
start
printf 'export SLACK_POLL_SECONDS=2\n' > "$SK_RUN_FROM/.env.local"
printf '# update\n' >> "${SK_BIN%/*}/lib/relay.py"
C1="$(code_of)"
row_until code "$C1" 20
sk_assert_red "$(field "$LINE" code)=$(jq -r .poll_seconds "$STATUS")" "$C1=2" \
  "control: the new image started under the loaded environment keeps the old settings"
sk_relay_stop

sk_mutant row-code verbs.py "code=\{record\.get\('code'\) or '-'\}" 'code=-'
row
sk_assert_red "$(field "$LINE" code)" "$(jq -r .code "$STATUS")" "control: the doctor row without the code"

sk_mutant unreported relay.py 'return f"\{err\.key\}=\{err\.value\}"' 'return ""'
start
ln -s "$SK_TMP/missing" "${SK_BIN%/*}/lib/zz.py"
row_until state failing 6
sk_assert_red "$(field "$LINE" state)" "failing" "control: the refusal kept out of the status record, an unreadable file reads ok"
sk_relay_stop

fresh churn
sk_mutant churn relay.py 'if self\.socket is None or any\(root\.pending_live for root in self\.roots\):' 'if self.socket is None:'
mailer
start
held
row_until state failing 20
printf '# update\n' >> "${SK_BIN%/*}/lib/relay.py"
sleep 4 # Real wait: two polls past the update, so a close would have run.
sk_assert_red "$(closes)" "0" "control: the held-reply check gone before the close, a held reply closes the connection"
sk_relay_stop

fresh undrained
sk_mutant undrained relay.py '(                closed = envelope\n            else:\n)                self\.deliver\(envelope\)' '\1                pass'
mailer
start
settling held
rm -- "${ROOT:?}/tmp/send-refused"
sk_assert_red "$(landed "$ROOT" "$OC:$RT" 60)" "held across the reload" \
  "control: the queue left undelivered, a reply acknowledged in the settling poll is lost"
sk_relay_stop

fresh unheld
sk_mutant unheld relay.py 'return not any\(root\.pending_live for root in self\.roots\)' 'return True'
mailer
start
settling held
row_until code "$(code_of)" 6
rm -- "${ROOT:?}/tmp/send-refused"
sk_assert_red "$(landed "$ROOT" "$OC:$RT" 60)" "held across the reload" \
  "control: the held-reply check gone after the close, a reply the close refused is lost"
sk_relay_stop

fresh unconnected
sk_mutant unconnected relay.py 'if self\.socket is None or any\(' 'if any('
mailer
C0="$(code_of)"
start
outage
printf '# update\n' >> "${SK_BIN%/*}/lib/relay.py"
row_until code "$(code_of)" 6
sk_assert_red "$(field "$LINE" code)" "$C0" "control: the connection check gone, a relay reconnecting reloads"
sk_relay_stop
sk_ctl /_test/faults-reset >/dev/null

fresh undropped
sk_mutant undropped relay.py '                closed = envelope\n' '                pass\n'
mailer
C0="$(code_of)"
start
settling outage
row_until code "$(code_of)" 6
sk_assert_red "$(field "$LINE" code)" "$C0" "control: a drop in the queue ignored, a relay whose connection dropped reloads"
sk_relay_stop
sk_ctl /_test/faults-reset >/dev/null

sk_summary
