#!/usr/bin/env bash
# lane-mail's owner channel: the typed fields an overseer ask and notice carry,
# `resolve` closing an owner ask exactly once, `--delivery-id` landing a send
# once under the lock, `events` reading both files, and `pending --to` and
# `--due`. Each case builds an overseer checkout under TMP_ROOT and drives the
# real script; the lane-side verbs are tests/lane-mail.sh. The must-fail
# controls close the file, one per rule, each a copy of lane-mail or the
# library it sources with that rule removed: the one resolution, the delivery
# id, the attachment's confinement, the audience and deadline filters, the
# cursor rule, the reply's owner-ask read, the owner-note class a reply names,
# the ask's deadline field and the box `events` stamps.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# mutant_scripts and mutate_file, the two halves of the controls at the end.
# shellcheck source=lib/growth-state.sh
source "$REPO_ROOT/skills/orch/tests/lib/growth-state.sh"

PASS=0
FAIL=0
assert_eq() { # GOT WANT LABEL
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$3" "$2" "$1"
  fi
}

# A fresh overseer checkout: a repository whose `.agents` tree holds the orch
# scripts, so `--item overseer` resolves its own mailbox and `--attach` finds
# workflow-state beside lane-mail.
LANE=""
BOX=""
new_repo() { # NAME
  LANE="$TMP_ROOT/$1"
  mkdir -p "$LANE/.agents/skills/orch"
  git -C "$LANE" init -q
  git -C "$LANE" config gc.auto 0
  git -C "$LANE" config maintenance.auto false
  ln -sfn "$REPO_ROOT/skills/orch/scripts" "$LANE/.agents/skills/orch/scripts"
  BOX="$LANE/tmp/lane-mail/overseer"
}

RC=0
OUT=""
ERR=""
lm() { # ARGS...
  RC=0
  OUT="$(cd "$LANE" && env -u ORCH_ASK_WAIT_MINUTES -u ORCH_PROGRESS_REPORT_DIR \
    "${LANE_MAIL_BIN:-$LANE_MAIL}" "$@" 2>"$TMP_ROOT/err")" || RC=$?
  ERR="$(head -n 1 "$TMP_ROOT/err")"
}

text() { # NAME CONTENT
  printf '%s\n' "$2" > "$TMP_ROOT/$1.txt"
  printf '%s' "$TMP_ROOT/$1.txt"
}

# owner_ask CONTENT [OPTIONS] [RECOMMEND] [WAIT] — sets ASK to the id.
ASK=""
owner_ask() {
  local args=(ask --item overseer --to owner --file "$(text q "$1")")
  [[ -z "${2:-}" ]] || args+=(--options "$2")
  [[ -z "${3:-}" ]] || args+=(--recommend "$3")
  [[ -z "${4:-}" ]] || args+=(--wait "$4")
  lm "${args[@]}"
  ASK="${OUT#id=}"
}

# field FILE JQ — one jq read of the mailbox file.
field() { jq -r "$2" < "$1"; }

echo "=== lane-mail owner channel ==="

# --- the owner ask's fields ---------------------------------------------------
new_repo fields
owner_ask 'Cut the scanner?' cut,keep cut 30
assert_eq "$RC=${OUT%%=*}" "0=id" "an owner ask prints its id"
assert_eq "$(field "$BOX/to-overseer.jsonl" '[.to, .recommend, (.wait | tostring), .from] | join(" ")')" \
  "owner cut 30 overseer" "the ask carries its audience, recommendation and wait as fields"
assert_eq "$(field "$BOX/to-overseer.jsonl" '(.deadline | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) - (.at | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)')" \
  "1800" "the deadline is the stamp plus the wait, in seconds"
owner_ask 'Which first?' a,b
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" 'select(.text == "Which first?") | [has("recommend"), has("wait"), has("deadline")] | map(tostring) | join(",")')" \
  "0=false,false,false" "an ask with no recommendation carries no deadline"

# The wait no ask names is the setting, read from the checkout's own file.
new_repo wait_setting
printf '[env]\nORCH_ASK_WAIT_MINUTES = "7"\n' > "$LANE/kendex.settings.toml"
owner_ask 'Settle it?' yes,no yes
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.wait')" "0=7" "an ask with no --wait takes ORCH_ASK_WAIT_MINUTES"
printf '[env]\nORCH_ASK_WAIT_MINUTES = "soon"\n' > "$LANE/kendex.settings.toml"
owner_ask 'Settle it?' yes,no yes
assert_eq "$RC=$ERR" "2=lane-mail: minutes-invalid=ORCH_ASK_WAIT_MINUTES=soon" \
  "a setting that is no number of minutes refuses the ask"
new_repo wait_default
owner_ask 'Settle it?' yes,no yes
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.wait')" "0=120" "with no setting the wait is 120 minutes"

# --- refusals, one row per rule -----------------------------------------------
new_repo refusals
lm notice --item overseer --to owner --file "$(text n 'A note.')"
NOTE_TO_OWNER="$(field "$BOX/to-overseer.jsonl" '.id')"
lm send --item overseer --directive --file "$(text d 'Owner wrote.')"
OWNER_NOTE="$(field "$BOX/to-lane.jsonl" '.id')"
owner_ask 'Which?' a,b
ASK_TO_OWNER="$ASK"
lm resolve --item overseer --id "$ASK_TO_OWNER" --text "$(text a 'a')"
RESOLUTION="$(field "$BOX/to-lane.jsonl" 'select(.kind == "answer") | .id')"
# A peer ask leaves the asker's own record in this mailbox with `to: peer`,
# which resolve closes no more than it closes this overseer's own notice; the
# peer's ask the other way lands in to-lane.jsonl beside the owner's notes.
REFUSALS="$LANE"
new_repo peer
lm peer ask --repo refusals --file "$(text q 'Mine?')" --options yes,no
INBOUND_PEER="${OUT#id=}"
LANE="$REFUSALS"; BOX="$LANE/tmp/lane-mail/overseer"
lm peer ask --repo peer --file "$(text q 'Yours?')" --options yes,no
PEER_ASK="${OUT#id=}"
# ARGS|WANT (rc=first stderr line); F is the message file. A --ref answers an
# owner note or an owner ask; a notice of this overseer's own, a peer's line
# and a resolution are none of them.
F="$TMP_ROOT/q.txt"
while IFS='|' read -r args want; do
  # shellcheck disable=SC2086  # a row's arguments are its own words.
  lm $args
  assert_eq "$RC=$ERR" "$want" "refused: $args"
done <<ROWS
ask --item overseer --file $F|2=lane-mail: option-required=--to
ask --item KEN-1 --to owner --file $F|2=lane-mail: option-unknown=--to
ask --item overseer --to peer --file $F|2=lane-mail: to-invalid=peer
ask --item overseer --to nobody --file $F|2=lane-mail: to-invalid=nobody
ask --item overseer --to owner --options a,b --recommend c --file $F|2=lane-mail: recommend-invalid=c
ask --item overseer --to owner --recommend a --file $F|2=lane-mail: option-required=--options
ask --item overseer --to owner --options a,b --wait 5 --file $F|2=lane-mail: option-required=--recommend
ask --item overseer --to owner --options a,b --recommend a --wait 5m --file $F|2=lane-mail: minutes-invalid=--wait
notice --item KEN-1 --ref $OWNER_NOTE --file $F|2=lane-mail: option-unknown=--ref
notice --item overseer --to owner --ref no/such --file $F|2=lane-mail: ref-invalid=no/such
notice --item overseer --to owner --ref 1790000000-1-1 --file $F|2=lane-mail: ref-unknown=1790000000-1-1
notice --item overseer --to owner --ref $NOTE_TO_OWNER --file $F|2=lane-mail: ref-unknown=$NOTE_TO_OWNER
notice --item overseer --to owner --ref $ASK_TO_OWNER --file $F|0=
notice --item overseer --to owner --ref $PEER_ASK --file $F|2=lane-mail: ref-unknown=$PEER_ASK
notice --item overseer --to owner --ref $INBOUND_PEER --file $F|2=lane-mail: ref-unknown=$INBOUND_PEER
notice --item overseer --to owner --ref $RESOLUTION --file $F|2=lane-mail: ref-unknown=$RESOLUTION
notice --item KEN-1 --attach x --file $F|2=lane-mail: option-unknown=--attach
send --item overseer --re $OWNER_NOTE --file $F|2=lane-mail: resolve-required=$OWNER_NOTE
send --item overseer --directive --host --root $LANE --delivery-id k --file $F|2=lane-mail: option-conflict=--host,--delivery-id
send --item overseer --directive --default --file $F|2=lane-mail: option-unknown=--default
resolve --item KEN-1 --id x --default|2=lane-mail: overseer-only=KEN-1
resolve --item overseer --default|2=lane-mail: option-required=--id
resolve --item overseer --id x|2=lane-mail: option-required=--text
resolve --item overseer --id x --default --text $F|2=lane-mail: option-conflict=--text,--default
resolve --item overseer --id 1790000000-1-1 --default|2=lane-mail: ask-unknown=1790000000-1-1
resolve --item overseer --id $PEER_ASK --text $F|2=lane-mail: ask-unknown=$PEER_ASK
resolve --item overseer --id $NOTE_TO_OWNER --text $F|2=lane-mail: ask-unknown=$NOTE_TO_OWNER
drain --item overseer --after 0 --to owner|2=lane-mail: option-unknown=--to
inbox --item overseer --due|2=lane-mail: option-unknown=--due
ROWS
lm notice --item overseer --to owner --file "$(text n 'Reply.')" --ref "$OWNER_NOTE"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" 'select(.text == "Reply.") | .ref')" "0=$OWNER_NOTE" \
  "a reply names the owner note it answers"

# --- the attachment's confinement --------------------------------------------
new_repo attach
REPORTS="$(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" progress-report-path)"
REPORTS="${REPORTS%/*}"
echo "a report" > "$REPORTS/09-26-01-00.md"
mkdir -p "$REPORTS/deeper" "$LANE/elsewhere"
echo "nested" > "$REPORTS/deeper/09-26-01-01.md"
echo "outside" > "$LANE/elsewhere/09-26-01-02.md"
ln -s "$LANE/elsewhere/09-26-01-02.md" "$REPORTS/09-26-01-03.md"
ln -s "$REPORTS" "$LANE/reports-link"
# PATH|WANT
while IFS='|' read -r path want; do
  lm notice --item overseer --to owner --file "$(text n 'Report.')" --attach "$path"
  assert_eq "$RC=$ERR" "$want" "attach $path"
done <<ROWS
$REPORTS/09-26-01-00.md|0=
tmp/progress-reports/09-26-01-00.md|0=
$REPORTS/deeper/09-26-01-01.md|2=lane-mail: attach-outside=$REPORTS/deeper/09-26-01-01.md
$LANE/elsewhere/09-26-01-02.md|2=lane-mail: attach-outside=$LANE/elsewhere/09-26-01-02.md
$REPORTS/09-26-01-03.md|2=lane-mail: attach-outside=$REPORTS/09-26-01-03.md
$LANE/reports-link/09-26-01-00.md|0=
$REPORTS|2=lane-mail: attach-outside=$REPORTS
ROWS
assert_eq "$(field "$BOX/to-overseer.jsonl" '.attach' | sort -u)" "$(cd "$REPORTS" && pwd -P)/09-26-01-00.md" \
  "every accepted attachment is recorded at its one physical path"

# --- pending --to and --due ---------------------------------------------------
new_repo pending
owner_ask 'Due now?' a,b a 0
DUE="$ASK"
owner_ask 'Due later?' a,b b 120
LATER="$ASK"
owner_ask 'Open ended?'
OPEN="$ASK"
lm send --item overseer --directive --file "$(text d 'Unread directive.')"
lm pending --item overseer
assert_eq "$(jq -r '.kind' <<<"$OUT" | sort | uniq -c | awk '{ print $2 "=" $1 }' | paste -sd, -)" "ask=3,directive=1" \
  "pending without --to lists every ask and the unread directive"
lm pending --item overseer --to owner
assert_eq "$RC=$(jq -r '.id' <<<"$OUT" | paste -sd, -)" "0=$DUE,$LATER,$OPEN" \
  "pending --to owner lists the owner asks and no directive"
lm pending --item overseer --to peer
assert_eq "$RC=$OUT" "0=" "pending --to peer lists none of them"
lm pending --item overseer --to owner --due
assert_eq "$RC=$(jq -r '.id' <<<"$OUT" | paste -sd, -)" "0=$DUE" \
  "--due keeps the ask whose deadline has passed alone: not the later one, not the one with none"
# A cursor read that missed, the lock standing beside no cursor, refuses the
# listing that would print directives against it and nothing else: the asks
# --to and --due keep read no cursor, so the watch's deadline step and the
# report's Waiting on you row list them whatever the cursor read did.
touch "$BOX/to-lane.cursor.lock"
lm pending --item overseer
assert_eq "$RC=$ERR" "2=lane-mail: mail-read-failed=overseer cursor=missed" \
  "a bare pending over a cursor read that missed is refused"
lm pending --item overseer --to owner
assert_eq "$RC=$(jq -r '.id' <<<"$OUT" | paste -sd, -)" "0=$DUE,$LATER,$OPEN" \
  "pending --to owner over the same missed read lists the owner asks, reading no cursor"
lm pending --item overseer --to owner --due
assert_eq "$RC=$(jq -r '.id' <<<"$OUT" | paste -sd, -)" "0=$DUE" "and --due lists the due one"
rm -f -- "${BOX:?}/to-lane.cursor.lock"

# --- resolve, exactly once ----------------------------------------------------
new_repo resolve
owner_ask 'Cut the scanner?' cut,keep cut 0
lm resolve --item overseer --id "$ASK" --default
ANSWER="$(field "$BOX/to-lane.jsonl" '.id')"
assert_eq "$RC=$OUT" "0=lane-mail: resolved id=$ASK by=default answer=$ANSWER" "resolve --default prints the resolution"
assert_eq "$(field "$BOX/to-lane.jsonl" '[.kind, .re, .by, .text, .from] | join(" ")')" \
  "answer $ASK default cut overseer:resolve" \
  "the default answer carries the recommendation and comes from the overseer"
lm pending --item overseer --to owner
assert_eq "$RC=$OUT" "0=" "a resolved ask is no longer pending"
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$ERR=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "2=lane-mail: resolved-already=$ASK id=$ANSWER=1" \
  "a second resolution is refused, naming the answer, and appends nothing"
lm resolve --item overseer --id "$ASK" --text "$(text a 'keep it')"
assert_eq "$RC=$ERR" "2=lane-mail: resolved-already=$ASK id=$ANSWER" "later text for a resolved ask is refused too"

new_repo resolve_text
owner_ask 'Cut the scanner?' cut,keep cut 120
lm resolve --item overseer --id "$ASK" --text "$(text a 'keep it')" --delivery-id slack:C1:1.1
ANSWER="$(field "$BOX/to-lane.jsonl" '.id')"
assert_eq "$RC=$OUT" "0=lane-mail: resolved id=$ASK by=text answer=$ANSWER" "resolve --text prints the resolution"
assert_eq "$(field "$BOX/to-lane.jsonl" '[.by, .text, .from, .delivery_id] | join(" ")')" \
  "text keep it owner slack:C1:1.1" "the owner's answer is the owner's, carrying the delivery it came by"
lm resolve --item overseer --id "$ASK" --text "$(text a 'keep it')" --delivery-id slack:C1:1.1
assert_eq "$RC=$OUT=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "0=lane-mail: resolved id=$ASK by=text answer=$ANSWER=1" \
  "the same delivery resolving again gets the same line and appends nothing"
lm resolve --item overseer --id "$ASK" --text "$(text a 'cut it')" --delivery-id slack:C1:2.2
assert_eq "$RC=$ERR" "2=lane-mail: resolved-already=$ASK id=$ANSWER" "another delivery is refused as resolved already"
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$ERR" "2=lane-mail: resolved-already=$ASK id=$ANSWER" "the deadline's default cannot override the owner's answer"

new_repo resolve_no_recommend
owner_ask 'What do you want to work on?'
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$ERR=$([[ -e "$BOX/to-lane.jsonl" ]] && echo written || echo nothing)" \
  "2=lane-mail: recommend-missing=$ASK=nothing" "an ask with no recommendation has no default"
lm resolve --item overseer --id "$ASK" --text "$(text a 'KEN-7')"
assert_eq "$RC=${OUT%% answer=*}" "0=lane-mail: resolved id=$ASK by=text" "it is answered by text"

# --- the delivery id under the lock -------------------------------------------
new_repo delivery
lm send --item overseer --directive --file "$(text d 'From Slack.')" --delivery-id slack:C1:3.3
FIRST="$(field "$BOX/to-lane.jsonl" '.id')"
assert_eq "$RC=${OUT%% bytes=*}=$(field "$BOX/to-lane.jsonl" '.delivery_id')" \
  "0=lane-mail: sent item=overseer id=$FIRST=slack:C1:3.3" "a send records its delivery id and prints its receipt"
lm send --item overseer --directive --file "$(text d 'From Slack.')" --delivery-id slack:C1:3.3
assert_eq "$RC=$ERR=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "2=lane-mail: delivery-repeated=slack:C1:3.3 id=$FIRST=1" \
  "the same delivery again is refused, naming the envelope that landed, and appends nothing"
lm send --item overseer --directive --file "$(text d 'From Slack.')" --delivery-id slack:C1:4.4
assert_eq "$RC=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "0=2" \
  "the same words under another delivery id land: the id is the judge, not the minute window"

# --- events -------------------------------------------------------------------
new_repo events
owner_ask 'Cut the scanner?' cut,keep cut 0
lm resolve --item overseer --id "$ASK" --default
lm send --item overseer --directive --file "$(text d 'Owner wrote.')"
lm events --item overseer
assert_eq "$RC=$(jq -r '[.box, .kind] | join(":")' <<<"$OUT" | paste -sd, -)" \
  "0=to-overseer:ask,to-lane:answer,to-lane:directive" \
  "events prints both files, the resolved ask and its answer included, each naming its box"
lm events --item overseer
assert_eq "$(jq -r '.kind' <<<"$OUT" | paste -sd, -)=$([[ -e "$BOX/to-lane.cursor" ]] && echo cursor || echo no-cursor)" \
  "ask,answer,directive=no-cursor" "events consumes nothing: a second read prints the same and moves no cursor"

# --- controls, one per rule ---------------------------------------------------
# mutant NAME OLD NEW — a private lane-mail with OLD, which occurs once,
# replaced by NEW, beside links to the shipped rest; lm runs it until the next
# real-script row resets LANE_MAIL_BIN.
mutant() {
  local dir
  dir="$(mutant_scripts "mutants/$1" lane-mail)" || exit 1
  mutate_file "$dir/lane-mail" "$2" "$3"
  LANE_MAIL_BIN="$dir/lane-mail"
}

new_repo control_resolve
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Cut?' cut,keep cut 0
LANE_MAIL_BIN="$LANE_MAIL" lm resolve --item overseer --id "$ASK" --default
mutant resolve-twice 'lm_append_local "$TO_LANE" "$LINE" lm_guard_resolve' 'lm_append_local "$TO_LANE" "$LINE"'
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "0=2" \
  "control: without the resolve guard a second resolution lands"

new_repo control_delivery
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --directive --file "$(text d 'Once.')" --delivery-id k1
mutant delivery-twice 'lm_append_local "$TO_LANE" "$LINE" lm_guard_delivery' 'lm_append_local "$TO_LANE" "$LINE"'
lm send --item overseer --directive --file "$(text d 'Once.')" --delivery-id k1
assert_eq "$RC=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "0=2" \
  "control: without the delivery guard the retry lands a second time"

new_repo control_ref
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Which?' a,b
mutant ref-lane-only 'lm_owner_ask_find "$REF" ||' 'false ||'
lm notice --item overseer --to owner --file "$(text n 'Ruled.')" --ref "$ASK"
assert_eq "$RC=$ERR" "2=lane-mail: ref-unknown=$ASK" "control: without the to-overseer read a reply naming an owner ask is refused"

# The owner-note class lives in lib/mailbox-append.sh, which a mutant of
# lane-mail cannot reach: the copied library files a peer's line as an owner
# note.
new_repo control_ref_class
CLASS_REPO="$LANE"
new_repo control_ref_peer
LANE_MAIL_BIN="$LANE_MAIL" lm peer ask --repo control_ref_class --file "$(text q 'Mine?')" --options yes,no
INBOUND_PEER="${OUT#id=}"
LANE="$CLASS_REPO"
CLASS_DIR="$(mutant_scripts mutants/ref-class lib/mailbox-append.sh)" || exit 1
mutate_file "$CLASS_DIR/lib/mailbox-append.sh" 'then "peer"' 'then "owner-note"'
LANE_MAIL_BIN="$CLASS_DIR/lane-mail" lm notice --item overseer --to owner --file "$(text n 'Re.')" --ref "$INBOUND_PEER"
assert_eq "$RC=$ERR" "0=" "control: with every sender an owner a reply names a peer's ask"

new_repo control_deadline
mutant no-deadline ', deadline: (($now + ($wait | tonumber) * 60) | todate)' ''
owner_ask 'Cut?' cut,keep cut 30
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '[has("wait"), has("deadline")] | map(tostring) | join(",")')" "0=true,false" \
  "control: without the deadline clause an ask carries its wait and no deadline"

new_repo control_box
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --directive --file "$(text d 'Owner wrote.')"
mutant boxless ' + {box: "to-lane"}' ''
lm events --item overseer
assert_eq "$RC=$(jq -r '.box // "none"' <<<"$OUT")" "0=none" "control: without the box field a to-lane envelope names no file"

new_repo control_attach
mkdir -p "$LANE/elsewhere"
echo "outside" > "$LANE/elsewhere/x.md"
mutant attach-anywhere '[ "$dir" = "$reports" ] || refuse attach-outside "$ATTACH"' ':'
lm notice --item overseer --to owner --file "$(text n 'R.')" --attach "$LANE/elsewhere/x.md"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.attach')" "0=$LANE/elsewhere/x.md" \
  "control: without the directory rule a file anywhere is attached"

new_repo control_to
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Owner?' a,b a 120
mutant to-unfiltered 'select($to == "" or $envelope.to == $to)' 'select(true)'
lm pending --item overseer --to peer
assert_eq "$RC=$(jq -r '.to' <<<"$OUT")" "0=owner" "control: without the audience filter --to peer lists the owner's ask"

new_repo control_due
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Later?' a,b a 120
mutant due-unfiltered 'select($due == 0 or ' 'select(true or '
lm pending --item overseer --to owner --due
assert_eq "$RC=$(jq -r '.wait' <<<"$OUT")" "0=120" "control: without the deadline filter --due lists an ask not yet due"

new_repo control_cursor
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Cursor?' a,b a 0
touch "$BOX/to-lane.cursor.lock"
mutant cursor-for-asks 'if [ "$LISTS_DIRECTIVES" -eq 1 ]; then' 'if [ "$VERB" = pending ] || [ "$RECEIPTS" -eq 1 ]; then'
lm pending --item overseer --to owner
assert_eq "$RC=$ERR" "2=lane-mail: mail-read-failed=overseer cursor=missed" \
  "control: with the cursor read for every pending a missed read refuses the asks --to keeps"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
