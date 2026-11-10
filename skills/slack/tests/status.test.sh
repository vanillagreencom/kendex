#!/usr/bin/env bash
# `slack listen --status`: the doctor's row per root, `never` before a relay
# ran, `ok` inside two poll intervals plus five seconds of the last poll,
# `stale` past it, `failing` when the last poll was refused or the relay has
# been reconnecting past the bound, with the last connect refusal as its fix,
# the refused and open counts, and the connection: `none` with no since for
# queue mode; otherwise as recorded while fresh, `disconnected` since the
# last poll once stale, and `unknown` since the last poll on a record the
# pre-Socket-Mode relay wrote. A control disables the queue output rule.
# Other controls plant a mutant that indexes the connection error,
# so an old record raises, one whose fallback connection_since is not the last
# poll, one whose freshness bound never expires, so a stale record reads ok,
# one that shows a stale record's connection as recorded, and one that never
# reads the connection error.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack listen --status ==="

ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
STATUS="$ROOT/tmp/slack/status.json"
# row — one status read; LINE is the root's row and OUT the whole print.
row() { sk_run -- listen --status --root "$ROOT"; LINE="$(printf '%s' "$OUT" | sed -n '1p')"; }

sk_run -- listen --status --root "$ROOT"
assert_eq "$RC=$OUT" "0=slack: slack-relay=$ROOT state=never fix=start the relay with \`slack listen --root $ROOT\`" \
  "a root no relay has polled is never, with the command to start one, and nothing else is printed"

sk_poll "$ROOT"
sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text q 'Open?')" --options a,b --recommend a >/dev/null
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text s 'xoxb-0123456789-abcdefghij')" >/dev/null
sk_poll "$ROOT"
row
assert_eq "$(field "$LINE" state)=$(field "$LINE" channel)=$(field "$LINE" open_asks)=$(field "$LINE" refused)" "ok=C001=1=1" \
  "a fresh poll is ok, with the channel, the open ask and the refused envelope counted"
assert_eq "$(field "$LINE" connection)=$(field "$LINE" connection_since)" "disconnected=$(jq -r .connection_since "$STATUS")" \
  "a --once poll opens no connection and shows disconnected since it started"

# The doctor's consumers parse these fields. Queue rows keep the disconnected
# default and start time a running pre-change relay writes; only inbound differs.
cp "$STATUS" "$SK_TMP/once.json"
while read -r inbound connection age state expected; do
  jq --arg inbound "$inbound" --arg connection "$connection" --argjson age "$age" \
    '.inbound = $inbound | .connection = $connection | .last_poll -= $age' \
    "$SK_TMP/once.json" > "$STATUS"
  row
  assert_eq "$RC=$(field "$LINE" state)=$(field "$LINE" inbound)=$(field "$LINE" connection)" \
    "0=$state=$inbound=$expected" "$inbound record age=$age reports its connection independently of freshness"
  if [ "$inbound" = queue ]; then
    assert_lacks "$LINE" " connection_since=" "queue record age=$age has no socket timestamp"
  else
    assert_eq "$(field "$LINE" connection_since)" "$(jq -r .connection_since "$STATUS")" "a fresh socket record keeps its connection timestamp"
  fi
done <<'ROWS'
socket connected 0 ok connected
queue disconnected 0 ok none
queue disconnected 30 stale none
ROWS
sk_mutant queue-connection verbs.py 'inbound == "queue"' 'False'
row
assert_eq "$(field "$LINE" connection)" "disconnected" "control: without the queue rule, a queue record reports the old socket default"
assert_has "$LINE" " connection_since=" "control: without the queue rule, a queue record reports a socket timestamp"
sk_bin_reset
cp "$SK_TMP/once.json" "$STATUS"

jq '.last_poll = (.last_poll - 30) | .connection = "connected"' "$STATUS" > "$SK_TMP/stale.json" && cp "$SK_TMP/stale.json" "$STATUS"
STALE_SINCE="$(python3 -c 'import json, sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(json.load(open(sys.argv[1]))["last_poll"])))' "$STATUS")"
row
assert_eq "$(field "$LINE" state)=$(field "$LINE" fix)" "stale=restart" "a record older than the bound is stale with a remedy"
assert_eq "$(field "$LINE" connection)=$(field "$LINE" connection_since)" "disconnected=$STALE_SINCE" \
  "a stale record's relay is gone: disconnected since its last poll, whatever connection it recorded"

sk_ctl /_test/fault '{"method": "conversations.history", "error": "channel_not_found", "times": 1}' >/dev/null
sk_poll "$ROOT"
row
assert_eq "$(field "$LINE" state)=${LINE#* fix=}" "failing=slack-api-failed=conversations.history error=channel_not_found" \
  "a fresh record of a refused poll is failing, with the refusal as its fix"

# since SECONDS — the UTC second SECONDS ago, as connection_since holds it
since() { python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - int(sys.argv[1]))))' "$1"; }
# reconnecting SECONDS — a fresh ok record whose relay has reconnected for SECONDS
reconnecting() {
  jq --arg s "$(since "$1")" '.last_poll_ok = true | .connection = "reconnecting" | .connection_since = $s | .connection_error = "socket-lost=connection ended"' \
    "$STATUS" > "$SK_TMP/link.json" && cp "$SK_TMP/link.json" "$STATUS"
}
sk_poll "$ROOT"
reconnecting 30
row
assert_eq "$(field "$LINE" state)=$(field "$LINE" connection)" "ok=reconnecting" "a relay reconnecting inside the bound is ok"
reconnecting 200
row
assert_eq "$(field "$LINE" state)=${LINE#* fix=}" "failing=socket-lost=connection ended" \
  "a relay reconnecting past the bound is failing, with the last connect refusal as its fix"

# old_record — a fresh ok record as the pre-Socket-Mode relay wrote it, without the connection fields
old_record() {
  sk_poll "$ROOT"
  jq '.last_poll_ok = true | del(.connection, .connection_error, .connection_since)' "$STATUS" > "$SK_TMP/old.json" && cp "$SK_TMP/old.json" "$STATUS"
}
old_record
OLD_SINCE="$(python3 -c 'import json, sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(json.load(open(sys.argv[1]))["last_poll"])))' "$STATUS")"
row
# The overseer and the succession report parse the keyed slack-relay line.
assert_eq "$RC=$(field "$LINE" slack-relay)=$(field "$LINE" state)=$(field "$LINE" connection)=$(field "$LINE" connection_since)" \
  "0=$ROOT=ok=unknown=$OLD_SINCE" \
  "a record the pre-Socket-Mode relay wrote reads its state from freshness alone, connection unknown since its last poll"

# --- controls: the freshness bound, the stale connection and the connection error -------
sk_mutant old-record verbs.py 'record\.get\("connection_error", ""\)' 'record["connection_error"]'
row
assert_eq "$RC" "1" "control: the connection error indexed directly, an old record raises"
sk_bin_reset
sk_mutant old-since verbs.py 'record\.get\("connection_since", last_poll_at\)' 'record.get("connection_since", format_at(0.0))'
row
assert_eq "$(field "$LINE" connection_since)" "1970-01-01T00:00:00Z" "control: the fallback off last_poll, an old record's connection_since is wrong"
sk_bin_reset
sk_poll "$ROOT"
reconnecting 200
sk_mutant link verbs.py 'elif link_error:' 'elif False:'
row
assert_eq "$(field "$LINE" state)" "ok" "control: the connection error unread, a relay reconnecting past the bound reads ok"
sk_bin_reset
sk_poll "$ROOT"
sk_mutant stale-connection verbs.py '        if fresh:\n            since' '        if True:\n            since'
jq '.last_poll = (.last_poll - 30) | .connection = "connected"' "$STATUS" > "$SK_TMP/stale.json" && cp "$SK_TMP/stale.json" "$STATUS"
row
assert_eq "$(field "$LINE" connection)" "connected" "control: the stale rule gone, a dead relay's record reads connected"
sk_bin_reset

sk_mutant fresh verbs.py 'fresh = age <= 2 \* int\(record\["poll_seconds"\]\) \+ 5' 'fresh = age <= 2 * int(record["poll_seconds"]) + 5 or True'
jq '.last_poll = (.last_poll - 30) | .last_poll_ok = true' "$STATUS" > "$SK_TMP/stale.json" && cp "$SK_TMP/stale.json" "$STATUS"
row
assert_eq "$(field "$LINE" state)" "ok" "control: the bound removed, a stale record reads ok"
sk_bin_reset

sk_summary
