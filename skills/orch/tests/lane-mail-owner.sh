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
# the ask's deadline field, the box `events` stamps, the owner ask's required
# recommendation, the cursor `events` refuses, the reply's delivery id and
# the referenced mailbox's read lock.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
# Canonical at creation: lane-mail records an attachment at its physical path,
# so every expectation built from LANE or BOX must name the same one.
TMP_ROOT="$(mktemp -d)" || { echo "lane-mail-owner: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-mail-owner: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-mail-owner: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# mutant_scripts and mutate_file, the two halves of the controls at the end.
# shellcheck source=lib/growth-state.sh
source "$REPO_ROOT/skills/orch/tests/lib/growth-state.sh"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

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
  mkdir -p "$LANE/tmp"
  printf '{"overseer":{"server":"7000","pane":"%%0"}}\n' > "$LANE/tmp/workflow-state-oversee.json"
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
owner_ask 'Which?' a,b a
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
ask --item overseer --to owner --options a,b --recommend a,b --file $F|2=lane-mail: recommend-invalid=a,b
ask --item overseer --to owner --file $F|2=lane-mail: recommend-required=owner
ask --item overseer --to owner --options a,b --wait 5 --file $F|2=lane-mail: recommend-required=owner
ask --item overseer --to owner --recommend a --file $F|2=lane-mail: option-required=--options
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
send --item overseer --re $OWNER_NOTE --file $F|2=lane-mail: ask-unknown=$OWNER_NOTE
send --item overseer --directive --host --root $LANE --delivery-id k --file $F|2=lane-mail: option-conflict=--host,--delivery-id
send --item overseer --directive --default --file $F|2=lane-mail: option-unknown=--default
resolve --item KEN-1 --id x --default|2=lane-mail: overseer-only=KEN-1
resolve --item overseer --default|2=lane-mail: option-required=--id
resolve --item overseer --id x|2=lane-mail: ask-unknown=x
resolve --item overseer --id x --default --text $F|2=lane-mail: option-conflict=--text,--default
resolve --item overseer --id 1790000000-1-1 --default|2=lane-mail: ask-unknown=1790000000-1-1
resolve --item overseer --id $PEER_ASK --text $F|2=lane-mail: ask-unknown=$PEER_ASK
resolve --item overseer --id $NOTE_TO_OWNER --text $F|2=lane-mail: ask-unknown=$NOTE_TO_OWNER
drain --item overseer --after 0 --to owner|2=lane-mail: option-unknown=--to
inbox --item overseer --due|2=lane-mail: option-unknown=--due
events --item overseer --after 0|2=lane-mail: events-no-cursor=--after
pending --item overseer --after 3|2=lane-mail: option-unknown=--after
ROWS
lm notice --item overseer --to owner --file "$(text n 'Reply.')" --ref "$OWNER_NOTE"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" 'select(.text == "Reply.") | .ref')" "0=$OWNER_NOTE" \
  "a reply names the owner note it answers"

# The host worker sends a voice request as an owner note with --delivery-id.
# A reply carries that id only when --ref names the delivered request; a plain
# owner note and an unreferenced notice produce no reply-delivery field.
while IFS='|' read -r name delivery referenced has_delivery; do
  new_repo "reply_$name"
  args=(send --item overseer --directive --file "$(text d 'Owner request.')")
  [[ -z "$delivery" ]] || args+=(--delivery-id "$delivery")
  lm "${args[@]}"
  assert_eq "$RC" "0" "$name: the owner request lands"
  OWNER_NOTE="$(field "$BOX/to-lane.jsonl" '.id')"
  args=(notice --item overseer --to owner --file "$(text n 'Reply.')")
  WANT_REF=""; WANT_DELIVERY=""
  if [[ "$referenced" == yes ]]; then
    args+=(--ref "$OWNER_NOTE")
    WANT_REF="$OWNER_NOTE"; WANT_DELIVERY="$delivery"
  fi
  lm "${args[@]}"
  assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '[.ref // "", has("re_delivery_id"), .re_delivery_id // ""] | map(tostring) | join("|")')" \
    "0=$WANT_REF|$has_delivery|$WANT_DELIVERY" "$name: the notice carries only the referenced delivery"
  lm events --item overseer
  assert_eq "$RC=$(jq -r 'select(.kind == "notice") | [.box, has("re_delivery_id"), .re_delivery_id // ""] | map(tostring) | join("|")' <<<"$OUT")" \
    "0=to-overseer|$has_delivery|$WANT_DELIVERY" "$name: events exports the reply binding without a lookup"
done <<'ROWS'
delivered|voice:request-1|yes|true
plain||yes|false
unreferenced|voice:request-1|no|false
ROWS

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
lm send --item overseer --directive --file "$(text d 'Unread directive.')"
lm pending --item overseer
assert_eq "$(jq -r '.kind' <<<"$OUT" | sort | uniq -c | awk '{ print $2 "=" $1 }' | paste -sd, -)" "ask=2,directive=1" \
  "pending without --to lists every ask and the unread directive"
lm pending --item overseer --to owner
assert_eq "$RC=$(jq -r '.id' <<<"$OUT" | paste -sd, -)" "0=$DUE,$LATER" \
  "pending --to owner lists the owner asks and no directive"
lm pending --item overseer --to peer
assert_eq "$RC=$OUT" "0=" "pending --to peer lists none of them"
lm pending --item overseer --to owner --due
assert_eq "$RC=$(jq -r '.id' <<<"$OUT" | paste -sd, -)" "0=$DUE" \
  "--due keeps the ask whose deadline has passed alone, not the later one"
# A cursor read that missed, the lock standing beside no cursor, refuses the
# listing that would print directives against it and nothing else: the asks
# --to and --due keep read no cursor, so the watch's deadline step and the
# report's Waiting on you row list them whatever the cursor read did.
touch "$BOX/to-lane.cursor.lock"
lm pending --item overseer
assert_eq "$RC=$ERR" "2=lane-mail: mail-read-failed=overseer cursor=missed" \
  "a bare pending over a cursor read that missed is refused"
lm pending --item overseer --to owner
assert_eq "$RC=$(jq -r '.id' <<<"$OUT" | paste -sd, -)" "0=$DUE,$LATER" \
  "pending --to owner over the same missed read lists the owner asks, reading no cursor"
lm pending --item overseer --to owner --due
assert_eq "$RC=$(jq -r '.id' <<<"$OUT" | paste -sd, -)" "0=$DUE" "and --due lists the due one"
rm -f -- "${BOX:?}/to-lane.cursor.lock"

# --- resolve, exactly once ----------------------------------------------------
new_repo resolve
owner_ask 'Cut the scanner?' cut,keep cut 0
lm resolve --item overseer --id "$ASK" --default
ANSWER="$(field "$BOX/to-lane.jsonl" 'select(.kind == "resolution") | .id')"
assert_eq "$RC=$OUT" "0=lane-mail: resolved id=$ASK by=default answer=$ANSWER" "resolve --default prints the resolution"
assert_eq "$(field "$BOX/to-lane.jsonl" 'select(.kind == "answer") | [.kind, .re, .by, .text, .from] | join(" ")')" \
  "answer $ASK default cut overseer:resolve" \
  "the default answer carries the recommendation and comes from the overseer"
lm pending --item overseer --to owner
assert_eq "$RC=$OUT" "0=" "a resolved ask is no longer pending"
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$ERR=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "2=lane-mail: resolved-already=$ASK id=$ANSWER=2" \
  "a second resolution is refused, naming the answer, and appends nothing"
lm resolve --item overseer --id "$ASK" --text "$(text a 'keep it')"
assert_eq "$RC=$ERR" "2=lane-mail: resolved-already=$ASK id=$ANSWER" "later text for a resolved ask is refused too"

new_repo resolve_text
owner_ask 'Cut the scanner?' cut,keep cut 120
lm resolve --item overseer --id "$ASK" --text "$(text a 'keep it')" --delivery-id slack:C1:1.1
ANSWER="$(field "$BOX/to-lane.jsonl" 'select(.kind == "resolution") | .id')"
assert_eq "$RC=$OUT" "0=lane-mail: resolved id=$ASK by=text answer=$ANSWER" "resolve --text prints the resolution"
assert_eq "$(field "$BOX/to-lane.jsonl" 'select(.kind == "answer") | [.by, .text, .from, .delivery_id] | join(" ")')" \
  "text keep it owner slack:C1:1.1" "the owner's answer is the owner's, carrying the delivery it came by"
lm resolve --item overseer --id "$ASK" --text "$(text a 'keep it')" --delivery-id slack:C1:1.1
assert_eq "$RC=$OUT=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "0=lane-mail: resolved id=$ASK by=text answer=$ANSWER=2" \
  "the same delivery resolving again gets the same line and appends nothing"
lm resolve --item overseer --id "$ASK" --text "$(text a 'cut it')" --delivery-id slack:C1:2.2
assert_eq "$RC=$ERR" "2=lane-mail: resolved-already=$ASK id=$ANSWER" "another delivery is refused as resolved already"
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$ERR" "2=lane-mail: resolved-already=$ASK id=$ANSWER" "the deadline's default cannot override the owner's answer"

# Slack sends distinct answers, and the deadline closes without replacing them.
new_repo answered_deadline
owner_ask 'Cut the scanner?' cut,keep cut 0
for key in slack:1 slack:2; do
  lm send --item overseer --re "$ASK" --delivery-id "$key" --file "$(text a 'keep it')"
  assert_eq "$RC" "0" "an answer lands under $key"
done
lm pending --item overseer --to owner --due
assert_eq "$(jq -r '.id' <<<"$OUT")" "$ASK" "the answered ask stays due and pending"
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$(jq -rs '[.[] | select(.kind == "answer")] | length' "$BOX/to-lane.jsonl")=$(jq -rs '[.[] | select(.kind == "answer" and .by == "default")] | length' "$BOX/to-lane.jsonl")" \
  "0=2=0" "the answered deadline closes without a recommendation answer"
lm pending --item overseer --to owner
assert_eq "$RC=$OUT" "0=" "the deadline drops the answered ask"
lm send --item overseer --re "$ASK" --delivery-id slack:1 --file "$(text a 'keep it')"
assert_eq "${ERR%% id=*}" "lane-mail: delivery-repeated=slack:1" "a replay after close still names the answer"
lm send --item overseer --re "$ASK" --delivery-id slack:3 --file "$(text a 'more words')"
assert_eq "${ERR%% id=*}" "lane-mail: resolved-already=$ASK" "new answer delivery after close is refused"

# Retained rows come from the pre-1.3 resolve --text/--default producer.
for by in text default; do
  new_repo "legacy_$by"
  owner_ask 'Retained close?' a,b a
  jq -cn --arg re "$ASK" --arg by "$by" '{id:"old-close",kind:"answer",re:$re,by:$by,text:"a",at:"2026-09-27T00:00:00Z",from:"owner"}' >"$BOX/to-lane.jsonl"
  for verb in pending drain events; do
    args=(--item overseer)
    [ "$verb" != drain ] || args+=(--after 0)
    lm "$verb" "${args[@]}"
    assert_eq "$RC" "0" "$by: $verb reads the retained mailbox"
    assert_eq "${ERR%%=*}" "lane-mail: legacy-close" "$by: $verb warns on the old closing format"
    if [ "$verb" = events ]; then
      assert_eq "$(jq -r 'select(.id == "old-close") | .mail_class' <<<"$OUT")" "close" "$by: events delegates closure to the mailbox rule"
    else
      assert_eq "$(jq -r 'select(.kind == "ask") | .id' <<<"$OUT")" "" "$by: $verb does not reopen a closed ask"
    fi
  done
  lm send --item overseer --re "$ASK" --delivery-id new:reply --file "$(text a b)"
  assert_eq "$RC=$ERR" "2=lane-mail: resolved-already=$ASK id=old-close" "$by: a retained close refuses a new answer"
  lm resolve --item overseer --id "$ASK"
  assert_eq "$RC=$ERR" "2=lane-mail: resolved-already=$ASK id=old-close" "$by: a retained close refuses another close"
done

# Inject jq failures only in the selected scan, not envelope construction.
FAULT_DIR="$TMP_ROOT/jq-fault"
mkdir -p "$FAULT_DIR"
REAL_JQ="$(command -v jq)" || exit 1
cat >"$FAULT_DIR/jq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  case "$arg" in
    *'select(overseer_mail_class == "close"'*)
      [ "$JQ_FAULT" != closure ] || { printf 'jq-fault=closure\n' >&2; exit 5; } ;;
    *'select(.kind == "answer" and .re == $re)'*)
      [ "$JQ_FAULT" != answers ] || { printf 'jq-fault=answers\n' >&2; exit 5; } ;;
  esac
done
exec "$REAL_JQ" "$@"
SH
chmod +x "$FAULT_DIR/jq"
export REAL_JQ
while read -r verb fault; do
  new_repo "scan_${verb}_${fault}"
  owner_ask 'Faulted read?' a,b a
  args=(--item overseer)
  if [ "$verb" = send ]; then
    args+=(--re "$ASK" --delivery-id fault:reply --file "$(text a b)")
  else
    args+=(--id "$ASK" --default)
  fi
  PATH="$FAULT_DIR:$PATH" JQ_FAULT="$fault" lm "$verb" "${args[@]}"
  assert_eq "$RC=$ERR" "2=lane-mail: mail-read-failed=overseer" "$verb/$fault: an operational failure is not a close"
  assert_eq "$(tail -n 1 "$TMP_ROOT/err")" "jq-fault=$fault" "$verb/$fault: the dependency diagnostic survives"
  assert_eq "$(wc -l <"$BOX/to-lane.jsonl" | tr -d ' ')" "0" "$verb/$fault: failed scans append no words"
done <<'ROWS'
send closure
resolve closure
resolve answers
ROWS

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

# --- threaded owner directive storage ------------------------------------------
new_repo pointer
POINTER="$(text parent '{"ts":"1.1","author":"bot","excerpt":"A release.","envelope":"NOTICE-1"}')"
lm send --item overseer --directive --delivery-id C1:2.2 --file "$(text reply 'Continue.')" --thread-ts 1.1 --parent "$POINTER"
lm inbox --item overseer
assert_eq "$RC=$(jq -c '{thread_ts,parent}' <<<"$OUT")" \
  '0={"thread_ts":"1.1","parent":{"ts":"1.1","author":"bot","excerpt":"A release.","envelope":"NOTICE-1"}}' \
  "inbox preserves both thread pointer fields on the stored envelope"
for flag in --thread-ts --parent; do
  case "$flag" in --thread-ts) value=1.1 ;; --parent) value="$POINTER" ;; esac
  lm send --item overseer --directive --file "$(text reply 'Incomplete.')" "$flag" "$value"
  assert_eq "$RC=$ERR" "2=lane-mail: option-conflict=--thread-ts,--parent" "a single $flag refuses an incomplete pointer"
done
lm send --item overseer --directive --file "$(text reply 'Broken.')" --thread-ts 1.1 --parent "$(text broken '{')"
assert_eq "$RC=$ERR" "2=lane-mail: file-unreadable=$TMP_ROOT/broken.txt" "a truncated parent file never lands a directive"
lm send --item overseer --file "$(text reply 'Wrong target.')" --thread-ts 1.1 --parent "$POINTER"
assert_eq "$RC=$ERR" "2=lane-mail: option-unknown=--thread-ts" "thread pointers are for overseer owner directives only"
INVALID_POINTER="$(text invalid-parent '{"ts":"1.1","author":"other","excerpt":"A release."}')"
lm send --item overseer --directive --file "$(text reply 'Wrong author.')" --thread-ts 1.1 --parent "$INVALID_POINTER"
assert_eq "$RC=$ERR" "2=lane-mail: file-unreadable=$INVALID_POINTER" "a parent outside Slack's owner or bot kinds is refused"

# Missing jq must name the dependency before parsing a readable parent.
BASH_BIN="$(command -v bash)"
RC=0
OUT="$(env -i PATH= "$BASH_BIN" "$LANE_MAIL" send --item overseer --directive --file "$POINTER" --thread-ts 1.1 --parent "$POINTER" 2>"$TMP_ROOT/err")" || RC=$?
assert_eq "$RC=$(sed -n '1p' "$TMP_ROOT/err")" "2=lane-mail: command-missing=jq" "a threaded send names missing jq, not the readable parent"

# --- events -------------------------------------------------------------------
new_repo events
owner_ask 'Cut the scanner?' cut,keep cut 0
lm resolve --item overseer --id "$ASK" --default
lm send --item overseer --directive --file "$(text d 'Owner wrote.')"
lm events --item overseer
assert_eq "$RC=$(jq -r '[.box, (.line | tostring), .kind] | join(":")' <<<"$OUT" | paste -sd, -)" \
  "0=to-overseer:1:ask,to-lane:1:answer,to-lane:2:resolution,to-lane:3:directive" \
  "events prints both files, the resolved ask and its answer included, each naming its box"
lm events --item overseer
assert_eq "$(jq -r '.kind' <<<"$OUT" | paste -sd, -)=$([[ -e "$BOX/to-lane.cursor" ]] && echo cursor || echo no-cursor)" \
  "ask,answer,resolution,directive=no-cursor" "events consumes nothing: a second read prints the same and moves no cursor"
printf 'interrupted\n\n' >> "$BOX/to-overseer.jsonl"
lm notice --item overseer --to owner --file "$(text after-gap 'After the interrupted lines.')"
printf 'interrupted\n' >> "$BOX/to-overseer.jsonl"
lm events --item overseer
assert_eq "$RC=$(jq -r 'select(.box == "to-overseer") | "\(.line)/\(.count)"' <<<"$OUT" | paste -sd, -)" "0=1/5,4/5" \
  "events keeps physical offsets and counts across filtered lines left by an interrupted writer"

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

new_repo control_pointer
mutant pointer-fields '+ (if $thread == "" then {} else {thread_ts: $thread, parent: $parent} end)' '+ {}'
lm send --item overseer --directive --delivery-id C1:2.2 --file "$(text reply 'Continue.')" --thread-ts 1.1 --parent "$POINTER"
lm inbox --item overseer
assert_eq "$(jq -r 'has("parent") or has("thread_ts")' <<<"$OUT")" "false" "control: omitted pointer fields break the inbox assertion"
LANE_MAIL_BIN="$LANE_MAIL"

new_repo control_pointer_pair
mutant pointer-pair '[ -n "$THREAD_TS" ] && [ -n "$PARENT" ] || refuse option-conflict '\''--thread-ts,--parent'\''' '[ -n "$THREAD_TS" ] && [ -n "$PARENT" ] || :'
lm send --item overseer --directive --file "$(text reply 'Incomplete.')" --thread-ts 1.1
assert_eq "$ERR" "lane-mail: file-unreadable=" "control: omitting the pair guard loses its incomplete-pointer refusal"
LANE_MAIL_BIN="$LANE_MAIL"

new_repo control_pointer_shape
mutant pointer-shape '(.author == "owner" or .author == "bot")' 'true'
INVALID_POINTER="$(text invalid-parent '{"ts":"1.1","author":"other","excerpt":"A release."}')"
lm send --item overseer --directive --file "$(text reply 'Wrong author.')" --thread-ts 1.1 --parent "$INVALID_POINTER"
assert_eq "$RC" "0" "control: omitting parent author validation admits an unsupported author"
LANE_MAIL_BIN="$LANE_MAIL"

new_repo control_resolve
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Cut?' cut,keep cut 0
LANE_MAIL_BIN="$LANE_MAIL" lm resolve --item overseer --id "$ASK" --default
mutant resolve-twice 'lm_append_local "$TO_LANE" "$LINE" lm_guard_close' 'lm_append_local "$TO_LANE" "$LINE"'
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "0=3" \
  "control: without the resolve guard a second resolution lands"

new_repo control_answered_deadline
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Cut?' cut,keep cut 0
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --re "$ASK" --delivery-id slack:1 --file "$(text a 'keep')"
mutant default-overrides '[ ! -s "$WORK_DIR/owner.answers" ] || return 0' ': "$WORK_DIR/owner.answers"'
lm resolve --item overseer --id "$ASK" --default
assert_eq "$(field "$BOX/to-lane.jsonl" 'select(.kind == "answer" and .by == "default") | .text')" "cut" \
  "control: bypassing the answered default guard adds a recommendation answer"

# Keep the legacy row, but remove only its classification from the shared owner.
new_repo control_legacy_close
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Retained?' a,b a
jq -cn --arg re "$ASK" '{id:"old-close",kind:"answer",re:$re,by:"text",text:"a"}' >"$BOX/to-lane.jsonl"
CLASS_DIR="$(mutant_scripts mutants/legacy-close lib/mailbox-append.sh)" || exit 1
mutate_file "$CLASS_DIR/lib/mailbox-append.sh" 'or mailbox_legacy_close then' 'or false then'
LANE_MAIL_BIN="$CLASS_DIR/lane-mail" lm pending --item overseer --to owner
CONTROL_RC=0
CONTROL_OUT="$(
  FAIL=0
  assert_eq "$OUT" "" "legacy close remains closed"
  [[ "$FAIL" -eq 0 ]]
)" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" "1" "control: losing the legacy closure rule reopens the ask"

new_repo control_guard_error
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Faulted?' a,b a
CLASS_DIR="$(mutant_scripts mutants/guard-error lib/mailbox-append.sh)" || exit 1
mutate_file "$CLASS_DIR/lib/mailbox-append.sh" '*) return 5 ;;' '*) return 4 ;;'
PATH="$FAULT_DIR:$PATH" JQ_FAULT=closure LANE_MAIL_BIN="$CLASS_DIR/lane-mail" lm send --item overseer --re "$ASK" --delivery-id fault:reply --file "$(text a b)"
CONTROL_RC=0
CONTROL_OUT="$(
  FAIL=0
  assert_eq "$RC=$ERR" "2=lane-mail: mail-read-failed=overseer" "failed scan remains an operational error"
  [[ "$FAIL" -eq 0 ]]
)" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" "1" "control: collapsing guard errors loses the operational refusal"

new_repo control_delivery
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --directive --file "$(text d 'Once.')" --delivery-id k1
mutant delivery-twice 'lm_append_local "$TO_LANE" "$LINE" lm_guard_delivery' 'lm_append_local "$TO_LANE" "$LINE"'
lm send --item overseer --directive --file "$(text d 'Once.')" --delivery-id k1
assert_eq "$RC=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "0=2" \
  "control: without the delivery guard the retry lands a second time"

new_repo control_answer_closed
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Which?' a,b a
LANE_MAIL_BIN="$LANE_MAIL" lm resolve --item overseer --id "$ASK"
mutant answer-after-close $'  lm_guard_resolve "$1"\n}' $'  : "$1"\n}'
lm send --item overseer --re "$ASK" --delivery-id new:reply --file "$(text a 'b')"
assert_eq "$RC" "0" "control: bypassing the answer close guard admits a reply after close"

new_repo control_answer_pending
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Which?' a,b a
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --re "$ASK" --delivery-id first:reply --file "$(text a 'b')"
mutant answer-closes-pending 'if $envelope.to == "owner" then $closed else $done end' 'if $envelope.to == "owner" then $done else $done end'
lm pending --item overseer --to owner
assert_eq "$RC=$OUT" "0=" "control: pending drops an answered ask when it judges answers as closes"

new_repo control_answer_unknown
mutant answer-without-ask $'      lm_owner_ask "$MSGID"\n      BY=text' $'      : "$MSGID"\n      BY=text'
lm send --item overseer --re unknown --delivery-id new:reply --file "$(text a 'b')"
assert_eq "$RC" "0" "control: bypassing the owner ask lookup admits an answer with no ask"

new_repo control_close_class
CLASS_DIR="$(mutant_scripts mutants/close-class lib/mailbox-append.sh)" || exit 1
rm -- "$CLASS_DIR/lane-mail"
cp -p -- "$LANE_MAIL" "$CLASS_DIR/lane-mail"
mutate_file "$CLASS_DIR/lib/mailbox-append.sh" 'if .kind == "resolution" or mailbox_legacy_close then "close"' 'if .kind == "resolution" or mailbox_legacy_close then "stray"'
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Which?' a,b a
LANE_MAIL_BIN="$LANE_MAIL" lm resolve --item overseer --id "$ASK"
LANE_MAIL_BIN="$CLASS_DIR/lane-mail" lm resolve --item overseer --id "$ASK"
assert_eq "$RC=$(field "$BOX/to-lane.jsonl" '.kind' | wc -l | tr -d ' ')" "0=2" \
  "control: losing the close class permits a second close"

new_repo control_ref
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Which?' a,b a
mutant ref-lane-only 'lm_owner_ask_find "$REF" ||' 'false ||'
lm notice --item overseer --to owner --file "$(text n 'Ruled.')" --ref "$ASK"
assert_eq "$RC=$ERR" "2=lane-mail: ref-unknown=$ASK" "control: without the to-overseer read a reply naming an owner ask is refused"

# The host worker's delivered request is a valid --ref. Fail only that
# to-lane.jsonl lock in a private dependency copy, without a real wait; the
# notice's to-overseer.jsonl append must still work under its own lock.
new_repo ref_lock
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --directive --file "$(text d 'Voice request.')" --delivery-id voice:request-1
assert_eq "$RC" "0" "the request for the failed reference lock lands"
OWNER_NOTE="$(field "$BOX/to-lane.jsonl" '.id')"
REF_LOCK_DIR="$(mutant_scripts fixtures/ref-lock lib/file-lock.sh)" || exit 1
mutate_file "$REF_LOCK_DIR/lib/file-lock.sh" \
  'orch_take_lock() { # FD LOCK_FILE WAIT_SECONDS' \
  'orch_take_lock() { [ "$2" != "$TO_LANE" ] || return 1 # FD LOCK_FILE WAIT_SECONDS'
LANE_MAIL_BIN="$REF_LOCK_DIR/lane-mail" lm notice --item overseer --to owner --file "$(text n 'Unreferenced notice.')"
assert_eq "$RC=$ERR" "0=" "the failed reference lock does not block the notice append lock"
LANE_MAIL_BIN="$REF_LOCK_DIR/lane-mail" lm notice --item overseer --to owner --file "$(text n 'Voice reply.')" --ref "$OWNER_NOTE"
REF_LOCK_WANT="2=lane-mail: lock-failed=$BOX/to-lane.jsonl"
REF_LOCK_ASSERTION="a reply refuses the failed reference read lock and names its mailbox"
assert_eq "$RC=$ERR" "$REF_LOCK_WANT" "$REF_LOCK_ASSERTION"
assert_eq "$(wc -l < "$BOX/to-overseer.jsonl" | tr -d ' ')" "1" \
  "the failed reference read appends no reply"

# Keep the failed dependency, but bypass only lm_ref_find's acquisition in a
# private lane-mail. The same refusal assertion must turn red, while the
# reply append succeeds and carries the delivered request's binding.
rm -- "$REF_LOCK_DIR/lane-mail"
cp -p -- "$LANE_MAIL" "$REF_LOCK_DIR/lane-mail"
mutate_file "$REF_LOCK_DIR/lane-mail" 'orch_take_lock 9 "$path" 30' ': 9 "$path" 30'
LANE_MAIL_BIN="$REF_LOCK_DIR/lane-mail" lm notice --item overseer --to owner --file "$(text n 'Voice reply.')" --ref "$OWNER_NOTE"
CONTROL_RC=0
CONTROL_OUT="$(
  FAIL=0
  assert_eq "$RC=$ERR" "$REF_LOCK_WANT" "$REF_LOCK_ASSERTION"
  [[ "$FAIL" -eq 0 ]]
)" || CONTROL_RC=$?
assert_eq "$RC=$ERR=$CONTROL_RC" "0==1" \
  "control: the reference-lock assertion fails when only its acquisition is bypassed"
assert_eq "$(field "$BOX/to-overseer.jsonl" 'select(has("ref")) | .re_delivery_id')" "voice:request-1" \
  "control: the unlocked reference read permits the bound reply to land"

new_repo control_reply_delivery
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --directive --file "$(text d 'Voice request.')" --delivery-id voice:request-1
OWNER_NOTE="$(field "$BOX/to-lane.jsonl" '.id')"
mutant reply-unbound '+ (if $re_delivery == "" then {} else {re_delivery_id: $re_delivery} end)' '+ {}'
lm notice --item overseer --to owner --file "$(text n 'Voice reply.')" --ref "$OWNER_NOTE"
lm events --item overseer
# Run the binding assertion against the old envelope behavior. Its failure is
# the control's expected result, not a failure of this suite.
CONTROL_RC=0
CONTROL_OUT="$(
  assert_eq "$(jq -r 'select(.kind == "notice") | .re_delivery_id // ""' <<<"$OUT")" \
    "voice:request-1" "the exported reply carries its request's delivery id"
  [[ "$FAIL" -eq 0 ]]
)" || CONTROL_RC=$?
assert_eq "$RC=$CONTROL_RC" "0=1" "control: the reply-binding assertion fails without the copied field"

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
mutant boxless 'box: $box, line: $line' 'line: $line'
lm events --item overseer
assert_eq "$RC=$(jq -r '.box // "none"' <<<"$OUT")" "0=none" "control: without the box field a to-lane envelope names no file"

new_repo control_lines
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --directive --file "$(text d 'Owner wrote.')"
mutant lineless '{box: $box, line: $line, count: $count}' '{box: $box, line: 0, count: $count}'
lm events --item overseer
assert_eq "$RC=$(jq -r '.line' <<<"$OUT")" "0=0" "control: without physical numbering an envelope has no usable cursor position"

new_repo control_recommend
mutant recommend-optional 'if [ "$VERB:$ITEM" = ask:overseer ]; then' 'if [ -n "$RECOMMEND" ]; then'
lm ask --item overseer --to owner --options a,b --file "$(text q 'Which?')"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" 'has("deadline")')" "0=false" \
  "control: with the rule judged only where a recommendation is given an owner ask lands with no deadline"

new_repo control_events_cursor
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --directive --file "$(text d 'Owner wrote.')"
mutant events-cursor 'events) refuse events-no-cursor --after ;;' 'events) ;;'
lm events --item overseer --after 0
assert_eq "$RC=$(jq -r '.kind' <<<"$OUT")" "0=directive" \
  "control: without the events rule --after is taken and dropped"

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
