#!/usr/bin/env bash
# Surface: slack listen --status. Inputs: scripts/, tests/lib/harness.sh,
# tests/lib/fake_slack.py, tests/lib/tracker_stub.py and skills/orch/.
# The overseer and succession report parse the keyed slack-relay line.
# A directory at binding.json proves an OS read failure, also under root.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
sk_poll "$ROOT"
STATUS="$ROOT/tmp/slack/status.json"
BINDING="$ROOT/tmp/slack/binding.json"
cp "$BINDING" "$SK_TMP/binding.json"

while read -r binding connection age state cause; do
  rm -rf -- "$BINDING"
  case "$binding" in
    present) cp "$SK_TMP/binding.json" "$BINDING" ;;
    unreadable) mkdir "$BINDING" ;;
  esac
  jq --arg connection "$connection" --argjson age "$age" \
    '.last_poll = (now - $age) | .last_poll_ok = true | .connection = $connection | .connection_error = ""' \
    "$STATUS" > "$SK_TMP/status.json"
  cp "$SK_TMP/status.json" "$STATUS"
  sk_run -- listen --status --root "$ROOT"
  assert_eq "$RC=$(field "$OUT" state)=$(field "$OUT" cause)" "0=$state=${cause#-}" \
    "$binding binding with $connection at age $age reports its cause"
  if [ "$state" = failing ]; then
    assert_eq "${OUT#* fix=}" "slack setup --take C001 --root $ROOT" "the remedy keeps the bound channel and root"
  else
    assert_eq "$(field "$OUT" channel)=$(field "$OUT" connection)=$(field "$OUT" fix)" \
      "C001=$connection=" "a readable binding keeps the existing status fields"
  fi
done <<'ROWS'
present connected 0 ok -
present reconnecting 0 ok -
present disconnected 0 ok -
missing connected 0 failing binding-missing
missing reconnecting 0 failing binding-missing
missing connected 30 failing binding-missing
unreadable connected 0 failing binding-unreadable
ROWS

# The missing root must fail without hiding another root's healthy row.
rm -rf -- "$BINDING"
sk_bind "$ROOT"
sk_poll "$ROOT"
OTHER="$(sk_new_root beta)"
sk_bind "$OTHER"
sk_poll "$OTHER"
jq '.connection = "connected"' "$STATUS" > "$SK_TMP/status.json"
cp "$SK_TMP/status.json" "$STATUS"
rm -- "$BINDING"
sk_run -- listen --status --root "$ROOT" --root "$OTHER"
LINE="$(printf '%s\n' "$OUT" | sed -n '2p')"
assert_eq "$RC=$(field "$LINE" slack-relay)=$(field "$LINE" state)" "0=$OTHER=ok" "another bound root keeps its status"

# A record-only mutant no longer reads binding.json and misses the failure.
sk_mutant record-only verbs.py 'root / "tmp/slack/binding\.json"' 'root / "tmp/slack/status.json"'
sk_run -- listen --status --root "$ROOT"
assert_eq "$(field "$OUT" state)=$(field "$OUT" cause)" "ok=" "control: reading only the relay record misses the deleted binding"
sk_bin_reset
sk_summary
