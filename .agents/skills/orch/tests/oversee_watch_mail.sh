#!/usr/bin/env bash
# oversee-watch's lane-mail pass: what a lane's mailbox makes the watch say.
# The pass reads mailboxes, never panes, so every case runs with no lane window
# and one with no tmux at all. The real `lane-mail` writes and reads each
# mailbox, so a case fails when either side of the channel changes under it.
# The rest of the sandbox is lib/oversee-watch-harness.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
HEARTBEAT='EVENT heartbeat loops=1 interval=0s since=none'

echo "=== oversee-watch lane mail ==="

# The case's own mailbox lives under the sandbox repository the watch runs in,
# which is where lane-mail resolves a lane root with no --root of its own.
mail_reset() { # ITEM
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
  mkdir -p -- "$CASE_REPO_ROOT/tmp/lane-mail/$1"
}

say() { # ITEM VERB TEXT [OPTIONS] -> the id, for an ask
  printf '%s\n' "$3" > "$TMP_ROOT/msg.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" "$2" --item "$1" --file "$TMP_ROOT/msg.txt" \
    ${4:+--options "$4"})
}

answer() { # ITEM MSGID TEXT
  printf '%s\n' "$3" > "$TMP_ROOT/ans.txt"
  "$LANE_MAIL" send --item "$1" --root "$CASE_REPO_ROOT" --re "$2" --file "$TMP_ROOT/ans.txt"
}

# --- an ask is reported once --------------------------------------------
new_case mail_once
mail_reset KEN-7
ID="$(say KEN-7 ask 'Cut the scanner or keep it?' cut,keep)"
ID="${ID#id=}"
err="$TMP_ROOT/mail-a"
out="$(run_watch -- --max-loops 1 --item KEN-7 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-7 $ID" \
  "a new ask emits lane-question naming the item and the message id" "$err"
assert_contains "$out" "Cut the scanner or keep it?" "the ask's text follows its event line" "$err"
assert_contains "$out" "options: cut, keep" "the ask's choices follow its text" "$err"

err="$TMP_ROOT/mail-b"
out="$(run_watch -- --max-loops 1 --item KEN-7 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" "the same ask is not reported twice" "$err"
assert_not_contains "$out" "EVENT lane-question" "a re-run over a drained mailbox says nothing" "$err"

SECOND="$(say KEN-7 ask 'And the lexer?')"
SECOND="${SECOND#id=}"
err="$TMP_ROOT/mail-c"
out="$(run_watch -- --max-loops 1 --item KEN-7 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-7 $SECOND" \
  "a second ask is news again" "$err"
assert_not_contains "$out" "Cut the scanner or keep it?" \
  "the second pass carries only the message the first did not" "$err"

# --- a notice, and an ask the overseer already answered -----------------
new_case mail_notice
mail_reset KEN-8
say KEN-8 notice 'Rebased onto main; CI is green.' >/dev/null
err="$TMP_ROOT/notice-a"
out="$(run_watch -- --max-loops 1 --item KEN-8 2>"$err")"
assert_contains "$out" "EVENT lane-notice KEN-8 " "a notice emits lane-notice" "$err"
assert_contains "$out" "Rebased onto main; CI is green." "the notice's text follows its event line" "$err"

new_case mail_answered
mail_reset KEN-8
ID="$(say KEN-8 ask 'Merge now?')"
ID="${ID#id=}"
answer KEN-8 "$ID" 'Merge it.'
err="$TMP_ROOT/answered"
out="$(run_watch -- --max-loops 1 --item KEN-8 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" "an ask the overseer has answered is never reported" "$err"

# --- no tmux ------------------------------------------------------------
# The pass reads a file, so it runs where there is no pane to read at all.
new_case mail_no_tmux
mail_reset KEN-9
ID="$(say KEN-9 ask 'Who owns this rule?')"
ID="${ID#id=}"
err="$TMP_ROOT/no-tmux"
out="$(run_watch TMUX= -- --max-loops 1 --item KEN-9 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-9 $ID" \
  "the mail pass runs outside tmux, with no lane window" "$err"

# The drain cursor is durable read state, not a sighting: a lane dropped from
# --item for one run and named again in the next must not replay its mailbox.
new_case mail_item_readded
mail_reset KEN-20
say KEN-20 notice 'Read me once.' >/dev/null
err="$TMP_ROOT/readded-a"
out="$(run_watch -- --max-loops 1 --item KEN-20 2>"$err")"
assert_contains "$out" "EVENT lane-notice KEN-20 " "the notice is reported on the run that finds it" "$err"
err="$TMP_ROOT/readded-b"
out="$(run_watch -- --max-loops 1 --item KEN-21 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" "a run that does not name the item reports nothing for it" "$err"
err="$TMP_ROOT/readded-c"
out="$(run_watch -- --max-loops 1 --item KEN-20 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" \
  "the item named again drains from where it left off, not from zero" "$err"

# The remote root exists nowhere on this disk, so a pass that quietly fell
# back to the local root would read an empty mailbox instead.
new_case mail_hosted
mail_reset KEN-10
REMOTE_ROOT=/srv/lane/ken-10
REMOTE_DISK="$STUB_DIR/remote"
mkdir -p "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-10"
printf '{"id":"remote-1","kind":"ask","at":"t","text":"Hosted question"}\n' \
  > "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-10/to-overseer.jsonl"
err="$TMP_ROOT/hosted"
out="$(run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" \
  LANE_HOST_STUB_DIR="$REMOTE_DISK" -- --max-loops 1 --item KEN-10 \
  --hosted "KEN-10=$REMOTE_ROOT" 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-10 remote-1" \
  "--hosted reads the lane's mailbox on its own host" "$err"
assert_contains "$out" "Hosted question" "the hosted ask's text follows its event line" "$err"
assert_contains "$(cat "$STUB_DIR/host.log")" \
  "$REMOTE_ROOT/tmp/lane-mail/KEN-10/to-overseer.jsonl" \
  "the transport call log names the remote path the pass read" "$err"

new_case mail_hosted_invalid
err="$TMP_ROOT/hosted-bad"
out="$(run_watch -- --max-loops 1 --item KEN-10 --hosted 'KEN 10=/srv' 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "a --hosted value that names no item exits 2"
assert_eq "$(grep -c '^oversee-watch: hosted-invalid value=KEN 10=/srv$' "$err")" "1" \
  "the refusal names its reason and the value it rejected"

# --- a mailbox that cannot be read --------------------------------------
new_case mail_unreadable
mail_reset KEN-11
say KEN-11 notice 'x' >/dev/null
chmod 000 "$CASE_REPO_ROOT/tmp/lane-mail/KEN-11/to-overseer.jsonl"
err="$TMP_ROOT/unreadable"
out="$(run_watch -- --max-loops 1 --item KEN-11 2>"$err")" && rc=0 || rc=$?
chmod 644 "$CASE_REPO_ROOT/tmp/lane-mail/KEN-11/to-overseer.jsonl"
assert_eq "$rc" "2" "a mailbox that cannot be read exits 2 rather than reading the lane as silent"
assert_eq "$(grep -c '^oversee-watch: mail-read-failed item=KEN-11 exit=2$' "$err")" "1" \
  "the refusal names the item and the reader's exit status"
assert_contains "$(cat "$err")" "lane-mail: file-unreadable=" \
  "the reader's own keyed line is kept under the watch's"

# --- must-fail control --------------------------------------------------
# The baseline row never consulted: with it gone the same ask is reported on
# every pass. The copy keeps orch's place in a skills tree so its libraries
# resolve the github skill beside it.
MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$MUTANT_DIR/orch/scripts"
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
sed 's@lane_row_get lane-mail "\$state" "\$item"@printf ""@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(cmp -s "$MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the mutant really stops the pass consulting its baseline row"

new_case mail_row_mutant
mail_reset KEN-12
ID="$(say KEN-12 ask 'Report me once.')"
ID="${ID#id=}"
err="$TMP_ROOT/mutant-a"
out="$(WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run_watch -- --max-loops 1 --item KEN-12 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-12 $ID" \
  "control: the mutant still reports the ask on the pass that finds it" "$err"
err="$TMP_ROOT/mutant-b"
out="$(WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run_watch -- --max-loops 1 --item KEN-12 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-12 $ID" \
  "control: without the row a re-run reports the same ask again" "$err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
