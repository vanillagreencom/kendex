#!/usr/bin/env bash
# oversee-watch's lane-mail pass: what a lane's mailbox makes the watch say.
# The pass reads mailboxes, never panes, so every case runs with no lane window
# and one with no tmux at all. The real `lane-mail` writes and reads each
# mailbox. The rest of the sandbox is lib/oversee-watch-harness.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
HEARTBEAT='EVENT heartbeat loops=1 interval=0s since=none'

echo "=== oversee-watch lane mail ==="

# Under the sandbox repository the watch runs in, where lane-mail resolves a
# lane root with no --root of its own.
mail_reset() { # ITEM
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
  mkdir -p -- "$CASE_REPO_ROOT/tmp/lane-mail/$1"
}

say() { # ITEM VERB TEXT [OPTIONS] -> the id, for an ask
  printf '%s\n' "$3" > "$TMP_ROOT/msg.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" "$2" --item "$1" --file "$TMP_ROOT/msg.txt" ${4:+--options "$4"})
}

answer() { # ITEM MSGID TEXT
  printf '%s\n' "$3" > "$TMP_ROOT/ans.txt"
  "$LANE_MAIL" send --item "$1" --root "$CASE_REPO_ROOT" --re "$2" --file "$TMP_ROOT/ans.txt"
}

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
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-7 $SECOND" "a second ask is news again" "$err"
assert_not_contains "$out" "Cut the scanner or keep it?" \
  "the second pass carries only the message the first did not" "$err"

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

# The pass reads a file, so it runs where there is no pane to read at all.
new_case mail_no_tmux
mail_reset KEN-9
ID="$(say KEN-9 ask 'Who owns this rule?')"
ID="${ID#id=}"
err="$TMP_ROOT/no-tmux"
out="$(run_watch TMUX= -- --max-loops 1 --item KEN-9 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-9 $ID" \
  "the mail pass runs outside tmux, with no lane window" "$err"

# The drain cursor is durable read state: an item out and back must not replay.
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
  LANE_HOST_STUB_DIR="$REMOTE_DISK" -- --max-loops 1 --item KEN-10 --hosted "KEN-10=$REMOTE_ROOT" 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-10 remote-1" \
  "--hosted reads the lane's mailbox on its own host" "$err"
assert_contains "$out" "Hosted question" "the hosted ask's text follows its event line" "$err"
assert_contains "$(cat "$STUB_DIR/host.log")" "$REMOTE_ROOT/tmp/lane-mail/KEN-10/to-overseer.jsonl" \
  "the transport call log names the remote path the pass read" "$err"

new_case mail_hosted_invalid
err="$TMP_ROOT/hosted-bad"
out="$(run_watch -- --max-loops 1 --item KEN-10 --hosted 'KEN 10=/srv' 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "a --hosted value that names no item exits 2"
assert_eq "$(grep -c '^oversee-watch: hosted-invalid value=KEN 10=/srv$' "$err")" "1" \
  "the refusal names its reason and the value it rejected"
# An entry for an item the run does not watch reads no mailbox, and the item it
# was meant for quietly reads its local root.
err="$TMP_ROOT/hosted-unknown"
out="$(run_watch -- --max-loops 1 --item KEN-10 --hosted 'KEN-11=/srv' 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "a --hosted item this run does not watch exits 2"
assert_eq "$(grep -c '^oversee-watch: hosted-unknown-item item=KEN-11$' "$err")" "1" \
  "the refusal names the item nothing watches"

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
assert_contains "$(cat "$err")" "lane-mail: file-unreadable=" "the reader's own keyed line is kept under the watch's"

# Two items, the second unreadable: one pass over both, then the repair and a
# second pass. BLOCKED_FIRST is what the second pass said about the first item,
# which is where an uncommitted cursor shows up as a message reported twice.
blocked_pair() { # FIRST SECOND [WATCH_BIN]
  local sealed="$CASE_REPO_ROOT/tmp/lane-mail/$2/to-overseer.jsonl"
  mail_reset "$1"
  mkdir -p -- "${sealed%/*}"
  say "$1" notice 'Read me once.' >/dev/null
  say "$2" notice 'And me.' >/dev/null
  chmod 000 "$sealed"
  BLOCKED_RC=0
  BLOCKED_FIRST="$(WATCH_BIN="${3:-}" run_watch -- --max-loops 1 --item "$1" --item "$2" \
    2>"$TMP_ROOT/blocked-a")" || BLOCKED_RC=$?
  chmod 644 "$sealed"
  BLOCKED_AGAIN="$(WATCH_BIN="${3:-}" run_watch -- --max-loops 1 --item "$1" --item "$2" \
    2>"$TMP_ROOT/blocked-b")"
}

new_case mail_commit_per_item
blocked_pair KEN-30 KEN-31
assert_eq "$BLOCKED_RC" "2" "the pass exits 2 on the mailbox it could not read"
assert_contains "$BLOCKED_FIRST" "EVENT lane-notice KEN-30 " \
  "the item read before it still reported its notice" "$TMP_ROOT/blocked-a"
assert_not_contains "$BLOCKED_AGAIN" "EVENT lane-notice KEN-30 " \
  "the re-run after the repair does not report that notice again" "$TMP_ROOT/blocked-b"

# A relaunched lane brings a fresh mailbox, shorter than the cursor that read
# the old one. The saved cursor would suppress everything the replacement
# holds and then lower itself, losing those messages for good.
new_case mail_replaced
mail_reset KEN-40
say KEN-40 notice 'one' >/dev/null
say KEN-40 notice 'two' >/dev/null
say KEN-40 notice 'three' >/dev/null
err="$TMP_ROOT/replaced-a"
out="$(run_watch -- --max-loops 1 --item KEN-40 2>"$err")"
assert_contains "$out" "EVENT lane-notice KEN-40 " "the first mailbox is drained to its own count" "$err"
REPLACED="$(say KEN-40 ask 'Who owns the replacement?')"
REPLACED="${REPLACED#id=}"
# The replacement: one line where the cursor says three.
printf '%s\n' "$(tail -n 1 "$CASE_REPO_ROOT/tmp/lane-mail/KEN-40/to-overseer.jsonl")" \
  > "$CASE_REPO_ROOT/tmp/lane-mail/KEN-40/to-overseer.jsonl.new"
mv "$CASE_REPO_ROOT/tmp/lane-mail/KEN-40/to-overseer.jsonl.new" \
  "$CASE_REPO_ROOT/tmp/lane-mail/KEN-40/to-overseer.jsonl"
err="$TMP_ROOT/replaced-b"
out="$(run_watch -- --max-loops 1 --item KEN-40 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-40 $REPLACED" \
  "a mailbox shorter than its cursor is read whole" "$err"
err="$TMP_ROOT/replaced-c"
out="$(run_watch -- --max-loops 1 --item KEN-40 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" "and once read, not again" "$err"

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

UNCHECKED="$MUTANT_DIR/orch/scripts/oversee-watch-unchecked"
sed 's@^    \[\[ "\$hosted_item" -eq 1 \]\] || die hosted-unknown-item .*$@    :@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$UNCHECKED"
chmod +x "$UNCHECKED"
assert_eq "$(cmp -s "$UNCHECKED" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the unchecked mutant really drops the hosted-item check"
new_case mail_hosted_unchecked
mail_reset KEN-10
err="$TMP_ROOT/hosted-unchecked"
out="$(WATCH_BIN="$UNCHECKED" run_watch -- --max-loops 1 --item KEN-10 --hosted 'KEN-11=/srv' 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "control: without the check the entry for an unwatched item is accepted"

KEPT="$MUTANT_DIR/orch/scripts/oversee-watch-kept"
sed 's@^      \[\[ "\$count" -lt "\$prior" && "\$reread" -eq 0 \]\] || break$@      break@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$KEPT"
chmod +x "$KEPT"
assert_eq "$(cmp -s "$KEPT" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the kept-cursor mutant really drops the replacement check"
new_case mail_replaced_mutant
mail_reset KEN-41
say KEN-41 notice 'one' >/dev/null
say KEN-41 notice 'two' >/dev/null
say KEN-41 notice 'three' >/dev/null
WATCH_BIN="$KEPT" run_watch -- --max-loops 1 --item KEN-41 >/dev/null 2>"$TMP_ROOT/kept-a"
say KEN-41 ask 'Who owns the replacement?' >/dev/null
printf '%s\n' "$(tail -n 1 "$CASE_REPO_ROOT/tmp/lane-mail/KEN-41/to-overseer.jsonl")" \
  > "$CASE_REPO_ROOT/tmp/lane-mail/KEN-41/to-overseer.jsonl.new"
mv "$CASE_REPO_ROOT/tmp/lane-mail/KEN-41/to-overseer.jsonl.new" \
  "$CASE_REPO_ROOT/tmp/lane-mail/KEN-41/to-overseer.jsonl"
err="$TMP_ROOT/kept-b"
out="$(WATCH_BIN="$KEPT" run_watch -- --max-loops 1 --item KEN-41 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" \
  "control: keeping the cursor swallows the replacement's first ask" "$err"

LATE="$MUTANT_DIR/orch/scripts/oversee-watch-late"
python3 -c 'import sys
p, out = sys.argv[1], sys.argv[2]
s = open(p).read()
old = "    lane_row_commit \"$state\"\n  done\n}"
assert old in s, "late-commit mutant"
open(out, "w").write(s.replace(old, "  done\n  lane_row_commit \"$state\"\n}", 1))' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" "$LATE"
chmod +x "$LATE"
assert_eq "$(cmp -s "$LATE" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the late-commit mutant really moves the commit below the loop"
new_case mail_commit_mutant
blocked_pair KEN-32 KEN-33 "$LATE"
assert_contains "$BLOCKED_AGAIN" "EVENT lane-notice KEN-32 " \
  "control: with the commit below the loop the earlier notice is reported again" "$TMP_ROOT/blocked-b"

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

# Sent from a linked worktree with no --root, the note lands in the main
# checkout's overseer mailbox, which the watch reads with no --item at all.
new_case mail_owner_note
git -C "$CASE_REPO_ROOT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
git -C "$CASE_REPO_ROOT" worktree add -q --detach "$TMP_ROOT/linked"
printf 'Hold KEN-7 for the owner.\n' > "$TMP_ROOT/note.txt"
(cd "$TMP_ROOT/linked" && "$LANE_MAIL" send --item overseer --directive --file "$TMP_ROOT/note.txt")
NOTE="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || NOTE=unsent
err="$TMP_ROOT/owner-a"
out="$(run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT owner-note $NOTE" \
  "a note to the overseer emits owner-note naming its id" "$err"
assert_contains "$out" "Hold KEN-7 for the owner." "the note's text follows its event line" "$err"
err="$TMP_ROOT/owner-b"
out="$(run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" "the same note is not reported twice" "$err"
err="$TMP_ROOT/owner-c"
out="$(run_watch LINEAR_TEAM -- --max-loops 1 --since 2026-01-01T00:00:00Z 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=2026-01-01T00:00:00Z" \
  "a watch for another fleet's --since does not report the note again" "$err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
