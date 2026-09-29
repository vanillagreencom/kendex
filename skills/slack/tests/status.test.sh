#!/usr/bin/env bash
# `slack listen --status`: the doctor's row per root, `never` before a relay
# ran, `ok` inside two poll intervals plus five seconds of the last poll,
# `stale` past it, `failing` when the last poll was refused, the refused and
# open counts, and the connection: as the relay recorded it while the record
# is fresh, `disconnected` since the last poll once it is stale. The controls
# plant a mutant whose freshness bound never expires, so a stale record reads
# ok, and one that shows a stale record's connection as recorded.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack listen --status ==="

ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
STATUS="$ROOT/tmp/slack/status.json"
# row — one status read; LINE is the root's row and OUT the whole print.
row() { sk_run -- listen --status --root "$ROOT"; LINE="$(printf '%s' "$OUT" | sed -n '1p')"; }
field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; } # LINE KEY

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

# --- controls: the freshness bound and the stale connection -----------------------
sk_mutant stale-connection verbs.py '        if fresh:\n            connection, since' '        if True:\n            connection, since'
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
