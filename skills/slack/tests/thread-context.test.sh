#!/usr/bin/env bash
# A thread reply's parent carries every thread message its reader generation
# has not been delivered, through the real relay, lane-mail and overseer record.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start --page 2
echo "=== slack thread context ==="
ROOT="$(sk_new_root context)"
sk_bind "$ROOT"
CH="$(sk_channel "$ROOT")"
sk_poll "$ROOT"
RECORD="$ROOT/tmp/workflow-state-oversee.json"
generation() { jq -c ".overseer.generation = $1" "$RECORD" > "$SK_TMP/record" && mv -- "$SK_TMP/record" "$RECORD"; } # N
post() { sk_run -- post --root "$ROOT" --text "$1" ${2:+--thread "$2"}; sk_state ".messages.${CH}[-1].ts"; } # TEXT [THREAD]
reply() { REPLY="$(sk_inject "$CH" U001 "$1" "$2")"; sk_event "$ROOT" "$CH" "$REPLY"; } # TEXT THREAD
# The [author, ts] pairs of the delivered reply's parent.thread.
carried() { jq -c --arg d "$CH:$1" 'select(.delivery_id == $d) | [.parent.thread[] | [.author, .ts]]' "$(sk_box "$ROOT")/to-lane.jsonl"; } # TS
pairs() { printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != "") | split(" "))'; } # "AUTHOR TS"...

ROOT_TS="$(post 'Plan A or plan B?')"
A1="$(post 'Plan A is cheaper.' "$ROOT_TS")"
ASIDE="$(sk_inject "$CH" U999 'A non-owner aside.' "$ROOT_TS")"
reply 'Which is faster?' "$ROOT_TS"; R1="$REPLY"
assert_eq "$(carried "$R1")" "$(pairs "app $ROOT_TS" "app $A1" "owner $R1")" "the first reply carries the whole thread, both sides, and no non-owner"
assert_eq "$(jq -r --arg d "$CH:$R1" 'select(.delivery_id == $d) | .parent.thread[0].text' "$(sk_box "$ROOT")/to-lane.jsonl")" \
  "Plan A or plan B?" "each carried message keeps its text"
A2="$(post 'Plan B is faster.' "$ROOT_TS")"
reply 'Take plan B.' "$ROOT_TS"; R2="$REPLY"
assert_eq "$(carried "$R2")" "$(pairs "app $A2" "owner $R2")" "the second reply carries only what its generation has not been delivered"

generation 1
reply 'Status?' "$ROOT_TS"; R3="$REPLY"
assert_eq "$(carried "$R3")" "$(pairs "app $ROOT_TS" "app $A1" "owner $R1" "app $A2" "owner $R2" "owner $R3")" \
  "a successor generation's first reply carries the whole thread again"
reply 'Go on.' "$ROOT_TS"; R4="$REPLY"
assert_eq "$(carried "$R4")" "$(pairs "owner $R4")" "the successor's second reply carries only its own message"
for pair in "$R1 $R2" "$R3 $R4"; do
  set -- $pair
  assert_eq "$(jq -s --arg a "$CH:$1" --arg b "$CH:$2" '[.[] | select(.delivery_id == $a or .delivery_id == $b) | .parent.thread[].ts] | length == (unique | length)' "$(sk_box "$ROOT")/to-lane.jsonl")" \
    "true" "no message reaches generation of $1 twice"
done

# An unreadable generation refuses the delivery rather than guess a reader.
generation '"x"'
reply 'Unreadable reader.' "$ROOT_TS" 2>"$SK_TMP/refused.err"
assert_eq "$RC=$(carried "$REPLY")" "1=" "a record whose generation cannot be read refuses the delivery"

# Controls plant defects in copies of the runtime, never in the checkout.
sk_mutant reader relay.py 'raise Refusal\("lane-mail-failed", f"\{command\} \{\(proc[^\n]*' 'return 0'
reply 'Read as zero.' "$ROOT_TS"
assert_eq "$RC" "0" "control: reading an unreadable generation as 0 breaks the refusal assertion"
sk_bin_reset
generation 2
sk_mutant mark relay.py 'mark = thread\.reads\.get\(generation\) if thread is not None else None' 'mark = None'
reply 'Unmarked one.' "$ROOT_TS"
reply 'Unmarked two.' "$ROOT_TS"
assert_has "$(carried "$REPLY")" "$ROOT_TS" "control: ignoring the delivery mark repeats the thread to its generation"
sk_bin_reset
generation 3
sk_mutant one-reader relay.py 'return int\(generation\)\n' 'return 0\n'
reply 'Same reader.' "$ROOT_TS"
assert_lacks "$(carried "$REPLY")" "$ROOT_TS" "control: one generation for every reader withholds the thread from a successor"
sk_bin_reset
generation 4
sk_mutant anyone relay.py 'return "owner" if message.get\("user"\) in owner_ids else None' 'return "owner"'
reply 'Everyone counts.' "$ROOT_TS"
assert_has "$(carried "$REPLY")" "$ASIDE" "control: carrying a non-owner's message breaks the owner-only assertion"
sk_bin_reset

sk_summary
