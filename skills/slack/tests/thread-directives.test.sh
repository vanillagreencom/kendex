#!/usr/bin/env bash
# Thread pointers through the real relay and lane-mail, with no history read
# between live events. Journal replay caches each parent across relay starts.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start --page 2
echo "=== slack thread directives ==="
ROOT="$(sk_new_root pointers)"
sk_bind "$ROOT"
CH="$(sk_channel "$ROOT")"
sk_poll "$ROOT"

# A post outside the relay has no envelope. Its parent is fetched once even
# when the relay restarts between replies, and its excerpt stays bounded.
LONG="$(python3 -c 'print("First line\n" + "x" * 310)')"
sk_run -- post --root "$ROOT" --text "$LONG"
PARENT="$(sk_state ".messages.${CH}[-1].ts")"
sk_ctl /_test/calls-reset >/dev/null
for text in first second; do
  REPLY="$(sk_inject "$CH" U001 "$text" "$PARENT")"
  sk_event "$ROOT" "$CH" "$REPLY"
  assert_eq "$RC" "0" "the $text reply under an unbound parent lands"
done
sk_lm "$ROOT" inbox --item overseer >"$SK_TMP/inbox"
assert_eq "$(jq -s --arg ts "$PARENT" '[.[] | {thread_ts, parent}] | unique | . == [{thread_ts:$ts, parent:{ts:$ts,author:"bot",excerpt:("First line " + ("x" * 289))}}]' "$SK_TMP/inbox")" \
  "true" "inbox prints the same bounded parent pointer on both replies without an envelope"
assert_eq "$(sk_state '[.calls[] | select(. == "conversations.replies")] | length')" "1" "the unbound parent is read from Slack once across two starts"

# Relay posts carry their own envelope in the journal and need no API read.
sk_lm "$ROOT" notice --item overseer --to owner --file "$(sk_text notice 'The release shipped.')" >/dev/null
NOTICE="$(jq -r 'select(.kind == "notice") | .id' "$(sk_box "$ROOT")/to-overseer.jsonl")"
sk_poll "$ROOT"
POST="$(sk_state ".messages.${CH}[] | select(.text == \"The release shipped.\") | .ts")"
sk_ctl /_test/calls-reset >/dev/null
REPLY="$(sk_inject "$CH" U002 'Thanks.' "$POST")"
sk_event "$ROOT" "$CH" "$REPLY"
assert_eq "$(jq --arg d "$CH:$REPLY" --arg ts "$POST" --arg envelope "$NOTICE" 'select(.delivery_id == $d) | {thread_ts,parent} == {thread_ts:$ts,parent:{ts:$ts,author:"bot",excerpt:"The release shipped.",envelope:$envelope}}' "$(sk_box "$ROOT")/to-lane.jsonl")" \
  "true" "a reply under a relay notice carries its envelope"
assert_eq "$(sk_state '[.calls[] | select(. == "conversations.replies")] | length')" "0" "the relay notice parent comes from the journal without a Slack read"

TOP="$(sk_inject "$CH" U001 'A new topic.')"
sk_event "$ROOT" "$CH" "$TOP"
assert_eq "$(jq -r --arg d "$CH:$TOP" 'select(.delivery_id == $d) | has("thread_ts") or has("parent")' "$(sk_box "$ROOT")/to-lane.jsonl")" "false" "a top-level directive carries neither pointer field"

sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text ask 'Proceed?')" --options yes,no --recommend no >/dev/null
sk_poll "$ROOT"
ASK_TS="$(sk_state ".messages.${CH}[] | select(.text | contains(\"Proceed?\")) | .ts")"
ANSWER="$(sk_inject "$CH" U001 yes "$ASK_TS")"
sk_event "$ROOT" "$CH" "$ANSWER"
assert_eq "$(jq -r --arg d "$CH:$ANSWER" 'select(.delivery_id == $d) | [.kind, has("thread_ts"), has("parent")] | @json' "$(sk_box "$ROOT")/to-lane.jsonl")" '["answer",false,false]' "an open ask answer carries no pointer"
# Retained relay roots have envelopes before their parent cache is populated.
mkdir -p "$ROOT/tmp/progress-reports"
printf '# Report\n' > "$ROOT/tmp/progress-reports/replay.md"
sk_lm "$ROOT" notice --item overseer --to owner --attach "$ROOT/tmp/progress-reports/replay.md" --file "$(sk_text report 'Retained report.')" >/dev/null
REPORT="$(jq -r 'select(.attach) | .id' "$(sk_box "$ROOT")/to-overseer.jsonl")"
sk_poll "$ROOT"
sk_poll "$ROOT"
REPORT_TS="$(jq -r 'select(.t == "bound") | .ts' "$(sk_journal "$ROOT")")"
ASK_ID="$(jq -r 'select(.kind == "ask") | .id' "$(sk_box "$ROOT")/to-overseer.jsonl")"
sk_lm "$ROOT" resolve --item overseer --id "$ASK_ID" >/dev/null || exit 1
for root in "$POST" "$ASK_TS" "$REPORT_TS" "$TOP"; do
  case "$root" in "$POST") envelope="$NOTICE" ;; "$ASK_TS") envelope="$ASK_ID" ;; "$REPORT_TS") envelope="$REPORT" ;; "$TOP") envelope="" ;; esac
  jq -c --arg ts "$root" 'if (.t == "out" and .thread == $ts) or (.t == "bound" and .ts == $ts) then del(.parent) else . end' "$(sk_journal "$ROOT")" > "$SK_TMP/legacy-journal"
  mv -- "$SK_TMP/legacy-journal" "$(sk_journal "$ROOT")"
  REPLAY="$(sk_inject "$CH" U001 'Retained context.' "$root")"
  sk_event "$ROOT" "$CH" "$REPLAY"
  assert_eq "$(jq -r --arg d "$CH:$REPLAY" 'select(.delivery_id == $d) | .parent.envelope // ""' "$(sk_box "$ROOT")/to-lane.jsonl")" "$envelope" \
    "replay preserves only the envelope of a relay-posted root $root"
done

NONOWNER="$(sk_inject "$CH" U999 'Not mine.' "$PARENT")"
sk_event "$ROOT" "$CH" "$NONOWNER"
assert_eq "$(sk_state ".messages.${CH}[-1].text")" "Only the channel's owners steer this session; this message is not routed." "a non-owner reply receives NOT_OWNER"

BROADCAST="$(sk_inject "$CH" U001 'Also in the channel.' "$PARENT" '"subtype":"thread_broadcast"')"
sk_event "$ROOT" "$CH" "$BROADCAST"
assert_eq "$(jq -r --arg d "$CH:$BROADCAST" 'select(.delivery_id == $d) | .thread_ts' "$(sk_box "$ROOT")/to-lane.jsonl")" "$PARENT" "an owner thread broadcast routes with its pointer"
for subtype in message_changed message_deleted; do
  IGNORED="$(sk_inject "$CH" U001 'Not a new reply.' "$PARENT" "\"subtype\":\"$subtype\"")"
  sk_event "$ROOT" "$CH" "$IGNORED"
  assert_eq "$(jq -s --arg d "$CH:$IGNORED" '[.[] | select(.delivery_id == $d)] | length' "$(sk_box "$ROOT")/to-lane.jsonl")" "0" "$subtype stays ignored"
done

# A recent reply keeps the old root and directive mapping during pruning.
OLD_TS="$(python3 -c 'import time; print("%.6f" % (time.time() - 9 * 86400))')"
OLD="$(sk_inject "$CH" U001 'An old topic.' '' "\"ts\": \"$OLD_TS\"")"
sk_event "$ROOT" "$CH" "$OLD"
OLD_ID="$(jq -r --arg d "$CH:$OLD" 'select(.delivery_id == $d) | .id' "$(sk_box "$ROOT")/to-lane.jsonl")"
sk_lm "$ROOT" inbox --item overseer >/dev/null
sk_poll "$ROOT"
LATE="$(sk_inject "$CH" U001 'Continue here.' "$OLD")"
sk_event "$ROOT" "$CH" "$LATE"
assert_eq "$(jq -r --arg d "$CH:$LATE" 'select(.delivery_id == $d) | .parent.author' "$(sk_box "$ROOT")/to-lane.jsonl")" "owner" "an any-age reply carries an owner parent"
sk_run -- compact --root "$ROOT"
sk_lm "$ROOT" notice --item overseer --to owner --ref "$OLD_ID" --file "$(sk_text old-answer 'Continuing.')" >/dev/null
sk_poll "$ROOT"
assert_eq "$(sk_state ".messages.${CH}[] | select(.text == \"Continuing.\") | [.thread_ts, .reply_broadcast] | @json")" "[\"$OLD\",false]" "after pruning, a ref notice stays in its live thread"

# Controls plant defects in copies of the runtime, never in the checkout.
sk_mutant broadcast-route relay.py 'ROUTED_SUBTYPES = \{None, "file_share", "thread_broadcast"\}' 'ROUTED_SUBTYPES = {None, "file_share"}'
DROP="$(sk_inject "$CH" U001 'Broadcast dropped.' "$PARENT" '"subtype":"thread_broadcast"')"
sk_event "$ROOT" "$CH" "$DROP"
assert_eq "$(jq -s --arg d "$CH:$DROP" '[.[] | select(.delivery_id == $d)] | length' "$(sk_box "$ROOT")/to-lane.jsonl")" "0" "control: rejecting broadcast events breaks owner routing"
sk_bin_reset
sk_mutant thread-only-notice relay.py 'thread_ts=thread_ts,\n                                     \*\*' 'thread_ts=thread_ts, reply_broadcast=True,\n                                     **'
sk_lm "$ROOT" notice --item overseer --to owner --ref "$OLD_ID" --file "$(sk_text thread-only 'Thread only.')" >/dev/null
sk_poll "$ROOT"
assert_eq "$(sk_state ".messages.${CH}[] | select(.text == \"Thread only.\") | .reply_broadcast")" "true" "control: broadcasting a ref notice breaks the thread-only assertion"
sk_bin_reset
sk_mutant pointer relay.py 'parent = self\.parent_context\(thread_ts, retries=0 if path == "catch-up" else RETRIES\) if thread_ts != ts else None' 'parent = None'
DROP="$(sk_inject "$CH" U001 'Lost context.' "$PARENT")"
sk_event "$ROOT" "$CH" "$DROP"
assert_eq "$(jq -r --arg d "$CH:$DROP" 'select(.delivery_id == $d) | has("parent")' "$(sk_box "$ROOT")/to-lane.jsonl")" "false" "control: dropping the pointer breaks the envelope assertion"
sk_bin_reset

sk_mutant mailbox-pointer mailbox.py ', \*pointer\n' '\n'
DROP="$(sk_inject "$CH" U001 'Pointer not passed.' "$PARENT")"
sk_event "$ROOT" "$CH" "$DROP"
assert_eq "$(jq -r --arg d "$CH:$DROP" 'select(.delivery_id == $d) | has("parent")' "$(sk_box "$ROOT")/to-lane.jsonl")" "false" "control: omitting mailbox pointer arguments breaks directive context"
sk_bin_reset

sk_mutant cache relay.py 'if thread is not None and thread.parent is not None:' 'if thread is not None and thread.parent is not None and False:'
sk_ctl /_test/calls-reset >/dev/null
for text in uncached-one uncached-two; do
  REPLY="$(sk_inject "$CH" U001 "$text" "$PARENT")"
  sk_event "$ROOT" "$CH" "$REPLY"
done
assert_eq "$(sk_state '[.calls[] | select(. == "conversations.replies")] | length')" "2" "control: bypassing the journal cache breaks the single-read assertion"
sk_bin_reset

sk_mutant retain store.py 'str\(line.get\("thread", ""\)\) in live' 'False'
sk_run -- compact --root "$ROOT"
sk_poll "$ROOT"
assert_eq "$(jq -s --arg ts "$OLD" '[.[] | select(.t == "in" and .ts == $ts)] | length' "$(sk_journal "$ROOT")")" "0" "control: dropping old directive mappings breaks live-root retention"
sk_bin_reset

sk_summary
