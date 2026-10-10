#!/usr/bin/env bash
# Owner notice routing through the real relay and lane-mail. Slack supplies
# channel:ts delivery ids and thread pointers; the host worker supplies an
# operation id for voice. A pane note and an owner ask carry no delivery id.
set -euo pipefail
. "$(dirname "$0")/lib/harness.sh"
set -e

sk_fake_start
echo "=== slack owner notices ==="
ROOT="$(sk_new_root notices)"
sk_bind "$ROOT"
CH="$(sk_channel "$ROOT")"
sk_poll "$ROOT"

TOP="$(sk_inject "$CH" U001 'Slack request.')"
sk_poll "$ROOT"
SLACK_TOP="$(jq -r --arg d "$CH:$TOP" 'select(.delivery_id == $d) | .id' "$(sk_box "$ROOT")/to-lane.jsonl")"
REPLY="$(sk_inject "$CH" U001 'Slack follow-up.' "$TOP")"
sk_poll "$ROOT"
SLACK_REPLY="$(jq -r --arg d "$CH:$REPLY" 'select(.delivery_id == $d) | .id' "$(sk_box "$ROOT")/to-lane.jsonl")"

sk_lm "$ROOT" send --item overseer --directive --delivery-id cc364a44 --file "$(sk_text voice 'Voice request.')" >/dev/null
sk_lm "$ROOT" send --item overseer --directive --file "$(sk_text terminal 'Terminal request.')" >/dev/null
# An operation id with a colon still lacks Slack's channel form.
sk_lm "$ROOT" send --item overseer --directive --delivery-id "cc364a44:$TOP" --file "$(sk_text colon 'Operation request.')" >/dev/null
VOICE="$(jq -r 'select(.text == "Voice request.") | .id' "$(sk_box "$ROOT")/to-lane.jsonl")"
TERMINAL="$(jq -r 'select(.text == "Terminal request.") | .id' "$(sk_box "$ROOT")/to-lane.jsonl")"
COLON="$(jq -r 'select(.text == "Operation request.") | .id' "$(sk_box "$ROOT")/to-lane.jsonl")"

# Thread pointers also identify Slack when the event lacks its delivery id.
POINTER_TS="$(sk_inject "$CH" U001 'Thread pointer request.' "$TOP")"
sk_poll "$ROOT"
POINTER="$(jq -r --arg d "$CH:$POINTER_TS" 'select(.delivery_id == $d) | .id' "$(sk_box "$ROOT")/to-lane.jsonl")"
sk_event_filter "$ROOT" "if .id == \"$POINTER\" then del(.delivery_id) else . end"

sk_lm "$ROOT" ask --item overseer --to owner --options yes,no --recommend no --file "$(sk_text ask 'Proceed?')" >/dev/null
ASK="$(jq -r 'select(.kind == "ask") | .id' "$(sk_box "$ROOT")/to-overseer.jsonl")"
sk_poll "$ROOT"
ASK_TS="$(sk_state ".messages.${CH}[] | select(.text | contains(\"Proceed?\")) | .ts")"

while IFS='|' read -r name ref expected; do
  args=()
  [ -z "$ref" ] || args=(--ref "$ref")
  sk_lm "$ROOT" notice --item overseer --to owner ${args[@]+"${args[@]}"} --file "$(sk_text "$name" "$name reply.")" >/dev/null
  sk_poll "$ROOT"
  assert_eq "$RC|$(sk_state "[.messages.${CH}[] | select(.user == \"UBOT\" and .text == \"$name reply.\") | .thread_ts] | @json")" \
    "0|$expected" "$name reply stays in its medium and thread"
done <<EOF
voice|$VOICE|[]
terminal|$TERMINAL|[]
operation-colon|$COLON|[]
slack-top|$SLACK_TOP|["$TOP"]
slack-thread|$SLACK_REPLY|["$TOP"]
thread-pointer|$POINTER|["$TOP"]
progress||[null]
ask-ruling|$ASK|["$ASK_TS"]
EOF

sk_poll "$ROOT"
assert_eq "$RC" "0" "a restart with suppressed replies succeeds"
assert_eq "$(sk_state "[.messages.${CH}[] | select(.user == \"UBOT\" and (.text == \"voice reply.\" or .text == \"terminal reply.\"))] | length")" "0" "suppressed replies stay absent across relay starts"

# The copied relay keeps the classifier but bypasses its posting decision.
sk_mutant reply-medium relay.py 'if not ref or owner_ask else "skip"' 'if True or not ref or owner_ask else "skip"'
sk_lm "$ROOT" notice --item overseer --to owner --ref "$VOICE" --file "$(sk_text control 'Control reply.')" >/dev/null
sk_poll "$ROOT"
assert_eq "$RC" "0" "the mutant reaches notice posting"
if (
  SK_PASS=0 SK_FAIL=0
  assert_eq "$(sk_state "[.messages.${CH}[] | select(.user == \"UBOT\" and .text == \"Control reply.\") | .thread_ts] | @json")" "[]" "voice reply stays in its medium and thread"
  sk_summary
) > "$SK_TMP/control.out"; then
  bad "control: bypassing the medium check must turn the routing assertion red"
else
  assert_has "$(cat "$SK_TMP/control.out")" 'FAIL voice reply stays in its medium and thread' "control: bypassing the medium check turns the routing assertion red"
fi
sk_bin_reset

sk_summary
