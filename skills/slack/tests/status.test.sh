#!/usr/bin/env bash
# `slack listen --status`: the doctor's row per root, `never` before a relay
# ran, `ok` inside two poll intervals plus five seconds of the last poll,
# `stale` past it, `failing` when the last poll was refused, the refused and
# open counts, and the summed call budget. The control plants a mutant whose
# freshness bound never expires, so a stale record reads ok.
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
assert_eq "$RC=$(printf '%s' "$OUT" | sed -n '1p')" "0=slack: slack-relay=$ROOT state=never fix=start the relay with \`slack listen --root $ROOT\`" \
  "a root no relay has polled is never, with the command to start one"
assert_eq "$(printf '%s' "$OUT" | sed -n '2p')" "slack: slack-relay-budget=0.0 poll_seconds=1" "the budget line sums nothing"

sk_poll "$ROOT"
sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text q 'Open?')" --options a,b --recommend a >/dev/null
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text s 'xoxb-0123456789-abcdefghij')" >/dev/null
sk_poll "$ROOT"
row
assert_eq "$(field "$LINE" state)=$(field "$LINE" channel)=$(field "$LINE" open_asks)=$(field "$LINE" refused)" "ok=C001=1=1" \
  "a fresh poll is ok, with the channel, the open ask and the refused envelope counted"
assert_eq "$(field "$LINE" budget_per_minute)" "120.0" "the budget is (1 + open asks) reads per poll at 60/SLACK_POLL_SECONDS"
assert_eq "$(printf '%s' "$OUT" | sed -n '2p')" "slack: slack-relay-budget=120.0 poll_seconds=1" "the budget line sums the roots"
sk_run SLACK_POLL_SECONDS=15 -- listen --status --root "$ROOT"
assert_eq "$(printf '%s' "$OUT" | sed -n '2p')" "slack: slack-relay-budget=120.0 poll_seconds=15" \
  "the budget is the relay's record, not this shell's setting"

jq '.last_poll = (.last_poll - 30)' "$STATUS" > "$SK_TMP/stale.json" && cp "$SK_TMP/stale.json" "$STATUS"
row
assert_eq "$(field "$LINE" state)=$(field "$LINE" fix)" "stale=restart" "a record older than the bound is stale with a remedy"

sk_ctl /_test/fault '{"method": "conversations.history", "error": "channel_not_found", "times": 1}' >/dev/null
sk_poll "$ROOT"
row
assert_eq "$(field "$LINE" state)=${LINE#* fix=}" "failing=slack-api-failed=conversations.history error=channel_not_found" \
  "a fresh record of a refused poll is failing, with the refusal as its fix"

# --- control: the freshness bound ------------------------------------------------
sk_mutant fresh verbs.py 'fresh = age <= 2 \* int\(record\["poll_seconds"\]\) \+ 5' 'fresh = age <= 2 * int(record["poll_seconds"]) + 5 or True'
jq '.last_poll = (.last_poll - 30) | .last_poll_ok = true' "$STATUS" > "$SK_TMP/stale.json" && cp "$SK_TMP/stale.json" "$STATUS"
row
assert_eq "$(field "$LINE" state)" "ok" "control: the bound removed, a stale record reads ok"
sk_bin_reset

sk_summary
