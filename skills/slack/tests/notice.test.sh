#!/usr/bin/env bash
# Owner notice routing through the real relay and lane-mail. Slack supplies
# channel:ts delivery ids and thread pointers; the host worker supplies an
# operation id for voice. A pane note and an owner ask carry no delivery id.
# A satellite's jarvis-session forward supplies a forward-<sha256> key and a
# final provenance line, written here as literal text: its answers thread
# under one root that quotes the request and the confirmation it cites.
set -euo pipefail
. "$(dirname "$0")/lib/harness.sh"
set -e

sk_fake_start
# Jarvis produces the deadline event; the real mailbox and relay judge each
# candidate with fake time. Shared send recovery remains in recovery.test.sh.
for page_case in accepted read no-event unanswered ordinary foreign same-basename legacy seed horizon hold-read hold-release read-during-prepare missed invalid capability refusal-accepted refusal-read unknown; do
  ROOT="$(sk_new_root "page $page_case")"
  sk_bind "$ROOT"
  PAGE_RC=0
  env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    SLACK_ORCH_DIR="$SK_ROOT/skills/orch" SLACK_BOT_TOKEN="$SK_TOKEN" \
    SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" SLACK_JARVIS_SESSION_FILE=tmp/page-presence \
    python3 "$SK_ROOT/skills/slack/tests/lib/owner_unread_probe.py" "${SK_BIN%/*}/lib" "$ROOT" "$page_case" \
    "$SK_ROOT/skills/jarvis/scripts/lib/watch.py" >"$SK_TMP/page-$page_case.log" 2>&1 || PAGE_RC=$?
  assert_eq "$PAGE_RC" 0 "$page_case: canonical unread page admission and root status"
  [ "$PAGE_RC" -eq 0 ] || cat "$SK_TMP/page-$page_case.log"
done

sk_mutant unread-action relay.py '            self.post_owner_unread\(events\)' '            pass # self.post_owner_unread(events)'
ROOT="$(sk_new_root page-control)"
sk_bind "$ROOT"
PAGE_RC=0
env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
  GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
  SLACK_ORCH_DIR="$SK_ROOT/skills/orch" SLACK_BOT_TOKEN="$SK_TOKEN" \
  SLACK_OWNERS="$OWNERS" SLACK_API_URL="$SK_URL" \
  python3 "$SK_ROOT/skills/slack/tests/lib/owner_unread_probe.py" "${SK_BIN%/*}/lib" "$ROOT" accepted \
  "$SK_ROOT/skills/jarvis/scripts/lib/watch.py" >"$SK_TMP/page-control.log" 2>&1 || PAGE_RC=$?
sk_assert_red "$PAGE_RC" 0 'control: removing the page action fails the accepted-delivery assertion'
assert_has "$(cat "$SK_TMP/page-control.log")" "AssertionError: ('page-count', 'accepted', 0, 1)" \
  'control fails specifically because the eligible page did not land'

sk_bin_reset

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

# forward_line KEY [METHOD] [WORDS] — a provenance line as the satellite writes it
forward_line() {
  printf 'forwarded-request: satellite=px13 request-ref=vgs-audit:aud-1 request-at=2026-11-02T14:03:07.120Z confirmation-ref=vgs-audit:aud-2 confirmed-at=2026-11-02T14:03:21Z key=%s confirmation-method=%s confirmation-text=%s' \
    "$1" "${2:-words}" "${3:-\"Yes.\"}"
}
# forward_directive NAME KEY TEXT — an owner directive keyed KEY; prints its id
forward_directive() {
  sk_lm "$ROOT" send --item overseer --directive --delivery-id "$2" --file "$(sk_text "$1" "$3")" >/dev/null || exit 1
  jq -r --arg d "$2" 'select(.delivery_id == $d) | .id' "$(sk_box "$ROOT")/to-lane.jsonl"
}
forward_key() { printf 'forward-%064x' "$1"; } # N — a distinct well-formed key
FWD_BARE="$(forward_directive forward-bare "$(forward_key 1)" 'Bare forward request.')"
FWD_KEY="$(forward_directive forward-key "$(forward_key 2)" "Mismatched forward request.

$(forward_line "$(forward_key 12)")")"
FWD_REV3="$(forward_directive forward-rev3 "$(forward_key 3)" "Revision 3 forward request.

forwarded-request: satellite=px13 request=e1 request-at=2026-11-02T14:03:07Z confirmation=e2 confirmation-key=c1 caller=owner key=$(forward_key 3) confirmation-text=\"forward\"")"
FWD_QUOTE="$(forward_directive forward-quote "$(forward_key 4)" "Unquoted forward request.

$(forward_line "$(forward_key 4)" words '"yes')")"
FWD_NULL="$(forward_directive forward-null "$(forward_key 8)" "Wordless forward request.

$(forward_line "$(forward_key 8)" words null)")"

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
forward-bare|$FWD_BARE|[]
forward-key|$FWD_KEY|[]
forward-rev3|$FWD_REV3|[]
forward-quote|$FWD_QUOTE|[]
forward-null|$FWD_NULL|[]
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

# --- a forwarded directive's answers thread under one root ------------------------
roots() { sk_state "[.messages.${CH}[] | select(.user == \"UBOT\" and .thread_ts == null and (.text | startswith(\"Forwarded from \")))]"; }
threads_of() { sk_state "[.messages.${CH}[] | select(.user == \"UBOT\" and .text == \"$1\") | .thread_ts] | @json"; } # TEXT
answer() { sk_lm "$ROOT" notice --item overseer --to owner --ref "$1" --file "$(sk_text answer "$2")" >/dev/null; } # REF TEXT

KEY_F="$(forward_key 5)"
FWD="$(forward_directive forwarded "$KEY_F" "Book the dentist for Tuesday.

$(forward_line "$KEY_F")")"
answer "$FWD" 'Forwarded progress.'
answer "$FWD" 'Forwarded answer.'
sk_poll "$ROOT"
ROOT_TS="$(roots | jq -r '.[0].ts')"
assert_eq "$RC|$(roots | jq -r 'length')|$(roots | jq -r '.[0].text')" "0|1|Forwarded from px13:

Book the dentist for Tuesday.

Confirmed \"Yes.\" at 2026-11-02T14:03:21Z (vgs-audit:aud-2); request vgs-audit:aud-1 at 2026-11-02T14:03:07.120Z." \
  "a notice on a forwarded directive posts one root quoting the request and its citation"
assert_eq "$(threads_of 'Forwarded progress.')|$(threads_of 'Forwarded answer.')" "[\"$ROOT_TS\"]|[\"$ROOT_TS\"]" \
  "both answers sit in the root's thread"
answer "$FWD" 'Forwarded after restart.'
sk_poll "$ROOT"
assert_eq "$RC|$(roots | jq -r 'length')|$(threads_of 'Forwarded after restart.')" "0|1|[\"$ROOT_TS\"]" \
  "a later relay process threads a third answer under the same root"

KEY_V="$(forward_key 6)"
FWD_VOICE="$(forward_directive forwarded-voice "$KEY_V" "voice-request: caller=owner operation=op-7
Call the garage.

$(forward_line "$KEY_V" voice null)")"
answer "$FWD_VOICE" 'Garage answer.'
sk_poll "$ROOT"
VOICE_ROOT="$(roots | jq -c '[.[] | select(.text | contains("Call the garage."))]')"
assert_eq "$RC|$(jq -r 'length' <<<"$VOICE_ROOT")|$(jq -r '.[0].text' <<<"$VOICE_ROOT")" "0|1|Forwarded from px13:

voice-request: caller=owner operation=op-7
Call the garage.

Confirmed by voice at 2026-11-02T14:03:21Z (vgs-audit:aud-2); request vgs-audit:aud-1 at 2026-11-02T14:03:07.120Z." \
  "a forwarded voice request posts its root, unlike a direct voice directive"
assert_eq "$(threads_of 'Garage answer.')" "[$(jq -c '.[0].ts' <<<"$VOICE_ROOT")]" "the voice request's answer sits in its root's thread"

KEY_R="$(forward_key 7)"
FWD_RETRY="$(forward_directive forwarded-retry "$KEY_R" "Renew the parking permit.

$(forward_line "$KEY_R")")"
answer "$FWD_RETRY" 'Permit answer.'
sk_ctl /_test/fault '{"method": "chat.postMessage", "error": "not_in_channel", "times": 1}' >/dev/null
sk_poll "$ROOT"
assert_eq "$RC|$(roots | jq -r '[.[] | select(.text | contains("parking permit"))] | length')|$(threads_of 'Permit answer.')" "1|0|[]" \
  "a root Slack refuses posts neither the root nor its answer"
sk_poll "$ROOT"
RETRY_ROOT="$(roots | jq -c '[.[] | select(.text | contains("parking permit")) | .ts]')"
assert_eq "$RC|$(jq -r 'length' <<<"$RETRY_ROOT")|$(threads_of 'Permit answer.')" "0|1|$RETRY_ROOT" \
  "the next poll posts the root and threads the answer under it"

# Without the key comparison a forward- directive whose line names another key posts.
sk_mutant forward-key relay.py ' or line\["key"\] != delivery_id' ''
answer "$FWD_KEY" 'Control forward.'
sk_poll "$ROOT"
sk_assert_red "$RC|$(threads_of 'Control forward.')" "0|[]" "control: dropping the key comparison posts a mismatched forward"
sk_bin_reset


sk_summary
