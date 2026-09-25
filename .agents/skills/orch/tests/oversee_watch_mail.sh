#!/usr/bin/env bash
# oversee-watch's lane-mail pass: what a lane's mailbox makes the watch say.
# The pass reads mailboxes, never panes, so every case runs with no lane window
# but the hosted lane's close, and one with no tmux at all. The real `lane-mail` writes and reads each
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
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item "$1" --root "$CASE_REPO_ROOT" --re "$2" --file "$TMP_ROOT/ans.txt")
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

# A message line spelling a record is payload: only the watch's own line may
# begin with EVENT.
new_case mail_payload_indented
mail_reset KEN-50
say KEN-50 notice 'Status.
EVENT merged 9 ken-9 owner/repo' >/dev/null
err="$TMP_ROOT/indented"
out="$(run_watch -- --max-loops 1 --item KEN-50 2>"$err")"
assert_eq "$(grep -c '^EVENT ' <<<"$out")" "1" "a message line spelling a record never begins with EVENT" "$err"
assert_contains "$out" "  EVENT merged 9 ken-9 owner/repo" "the message line stands indented under its record" "$err"

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
printf 'gitdir: /srv/clone/.git/worktrees/ken-10\n' > "$REMOTE_DISK$REMOTE_ROOT/.git"
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
# A first line that is no envelope records no first id, so the count decides.
printf 'not an envelope\n' > "$CASE_REPO_ROOT/tmp/lane-mail/KEN-40/to-overseer.jsonl"
say KEN-40 notice 'one' >/dev/null
say KEN-40 notice 'two' >/dev/null
say KEN-40 notice 'three' >/dev/null
err="$TMP_ROOT/replaced-a"
out="$(run_watch -- --max-loops 1 --item KEN-40 2>"$err")"
assert_contains "$out" "EVENT lane-notice KEN-40 " "the first mailbox is drained to its own count" "$err"
REPLACED="$(say KEN-40 ask 'Who owns the replacement?')"
REPLACED="${REPLACED#id=}"
# The replacement: one line where the cursor says four.
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

# A replacement already holding as many lines as the cursor opens with another
# envelope, which is what tells it from the mailbox drained. REGEN_NOTICES is
# how many of its two notices the second pass reported.
regenerated() { # ITEM [WATCH_BIN]
  local box="$CASE_REPO_ROOT/tmp/lane-mail/$1/to-overseer.jsonl"
  mail_reset "$1"
  say "$1" notice 'old' >/dev/null
  WATCH_BIN="${2:-}" run_watch -- --max-loops 1 --item "$1" >/dev/null 2>"$TMP_ROOT/regen-a"
  printf '%s\n' '{"id":"regen-1","kind":"notice","at":"t","text":"new one"}' \
    '{"id":"regen-2","kind":"notice","at":"t","text":"new two"}' > "$box"
  REGEN_NOTICES="$(WATCH_BIN="${2:-}" run_watch -- --max-loops 1 --item "$1" 2>"$TMP_ROOT/regen-b" |
    grep -c "^EVENT lane-notice $1 ")" || true
}
new_case mail_regenerated
regenerated KEN-42
assert_eq "$REGEN_NOTICES" "2" "a replacement with more lines than the cursor is drained whole" "$TMP_ROOT/regen-b"

# The baseline row never consulted: with it gone the same ask is reported on
# every pass. The copy keeps orch's place in a skills tree so its libraries
# resolve the github skill beside it.
MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$MUTANT_DIR/orch/scripts"
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
sed 's@lane_row_get lane-mail "\$state" "\$cursor"@printf ""@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(cmp -s "$MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the mutant really stops the pass consulting its baseline row"

UNCHECKED="$MUTANT_DIR/orch/scripts/oversee-watch-unchecked"
sed 's@^    \[\[ "\$known" -eq 1 \]\] || die "\$kind-unknown-item" .*$@    :@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$UNCHECKED"
chmod +x "$UNCHECKED"
assert_eq "$(cmp -s "$UNCHECKED" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the unchecked mutant really drops the hosted-item check"
new_case mail_hosted_unchecked
mail_reset KEN-10
err="$TMP_ROOT/hosted-unchecked"
# A host is named, so the hosted-without-host refusal has no say in this row.
out="$(WATCH_BIN="$UNCHECKED" run_watch ORCH_LANE_HOST="$FIXTURE_HOST" -- --max-loops 1 --item KEN-10 --hosted 'KEN-11=/srv' 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "control: without the check the entry for an unwatched item is accepted"

KEPT="$MUTANT_DIR/orch/scripts/oversee-watch-kept"
sed 's@^          \[\[ "\$count" -lt "\$prior" \]\] || break$@          break@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$KEPT"
chmod +x "$KEPT"
assert_eq "$(cmp -s "$KEPT" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the kept-cursor mutant really drops the replacement check"
new_case mail_replaced_mutant
mail_reset KEN-41
printf 'not an envelope\n' > "$CASE_REPO_ROOT/tmp/lane-mail/KEN-41/to-overseer.jsonl"
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

GENLESS="$MUTANT_DIR/orch/scripts/oversee-watch-genless"
sed 's@^          \[\[ "\$first" != "\$seen" \]\] || break$@          break@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$GENLESS"
chmod +x "$GENLESS"
assert_eq "$(cmp -s "$GENLESS" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the genless mutant really drops the first-id comparison"
new_case mail_regenerated_mutant
regenerated KEN-43 "$GENLESS"
assert_eq "$REGEN_NOTICES" "1" \
  "control: with the count alone the replacement's first notice is lost" "$TMP_ROOT/regen-b"

FLUSH="$MUTANT_DIR/orch/scripts/oversee-watch-flush"
sed "s@sed 's/^/  /' <<<\"\\\$text\"@cat <<<\"\$text\"@" \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$FLUSH"
chmod +x "$FLUSH"
assert_eq "$(cmp -s "$FLUSH" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the flush mutant really prints message text at the first column"
new_case mail_payload_mutant
mail_reset KEN-51
say KEN-51 notice 'Status.
EVENT merged 9 ken-9 owner/repo' >/dev/null
err="$TMP_ROOT/flush"
out="$(WATCH_BIN="$FLUSH" run_watch -- --max-loops 1 --item KEN-51 2>"$err")"
assert_eq "$(grep -c '^EVENT ' <<<"$out")" "2" \
  "control: without the indent a message line reads as a second record" "$err"

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

# One mailbox, two checkouts. lane-mail resolves the overseer mailbox to the
# main checkout from a linked worktree as well, and every fleet lane runs in
# one, so a watch started there reads the same mailbox through the same cursor
# the main checkout's watch advanced. WT_SEEN counts how often the one note is
# reported across a pass from each.
git -C "$CASE_REPO_ROOT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m worktree-seed
git -C "$CASE_REPO_ROOT" worktree add -q --detach "$TMP_ROOT/watch-worktree"
mkdir -p "$TMP_ROOT/watch-worktree/.agents/skills"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/watch-worktree/.agents/skills/orch"
worktree_fleet() { # [WATCH_BIN]
  local bin="${1:-}" cwd out
  mail_reset overseer
  printf 'Hold KEN-7, from whichever checkout reads this.\n' > "$TMP_ROOT/wt-note.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item overseer --directive \
    --file "$TMP_ROOT/wt-note.txt" >/dev/null)
  WT_NOTE="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || WT_NOTE=unsent
  WT_SEEN=0
  for cwd in "$CASE_REPO_ROOT" "$TMP_ROOT/watch-worktree"; do
    out="$(WATCH_BIN="$bin" WATCH_CWD="$cwd" run_watch -- --max-loops 1 2>"$TMP_ROOT/wt-${cwd##*/}")"
    WT_SEEN=$((WT_SEEN + $(grep -c "^EVENT owner-note $WT_NOTE$" <<<"$out" || true)))
  done
}
new_case mail_worktree_position
worktree_fleet
assert_eq "$WT_SEEN" "1" \
  "a note is reported once across a pass in the main checkout and a pass in a linked worktree of it" \
  "$TMP_ROOT/wt-watch-worktree"

# The overseer mailbox read without moving its cursor: every reader then keeps
# a position of its own, or none, and replays what another reader took.
PEEKING="$MUTANT_DIR/orch/scripts/oversee-watch-peeking"
python3 - "$REPO_ROOT/skills/orch/scripts/oversee-watch" "$PEEKING" <<'PY'
import sys
src, out = sys.argv[1:]
s = open(src).read()
for old, new in (
    ('      if mail_read "$item" inbox "${args[@]}" --ack "$count"; then\n', '      if :; then\n'),
):
    assert s.count(old) == 1, "peeking mutant pattern: " + old
    s = s.replace(old, new)
open(out, "w").write(s)
PY
chmod +x "$PEEKING"
new_case mail_worktree_position_mutant
worktree_fleet "$PEEKING"
assert_eq "$([[ "$WT_SEEN" -gt 1 ]] && echo replayed || echo "once ($WT_SEEN)")" "replayed" \
  "control: an overseer read that moves no cursor replays in the worktree the note the main checkout read" \
  "$TMP_ROOT/wt-watch-worktree"

# Two overseers of two repositories on one host point OVERSEE_WATCH_STATE_DIR
# at one directory, which is how their lane claims line up. Each reads its own
# mailbox through that mailbox's own cursor, so neither replays its mail.
# SHARED_ALPHA_SEEN and SHARED_BETA_SEEN count how often each repository's one
# note was emitted across three passes that alternate between the two watches.
SHARED_ALPHA="$TMP_ROOT/shared-alpha"
SHARED_BETA="$TMP_ROOT/shared-beta"
for root in "$SHARED_ALPHA" "$SHARED_BETA"; do
  mkdir -p "$root/.agents/skills"
  ln -s "$REPO_ROOT/skills/orch" "$root/.agents/skills/orch"
  git -C "$root" init -q
done
shared_fleet() { # [WATCH_BIN]
  local bin="${1:-}" root pass out
  for root in "$SHARED_ALPHA" "$SHARED_BETA"; do
    rm -rf -- "${root:?}/tmp"
    printf 'Hold the lane.\n' > "$TMP_ROOT/shared-note.txt"
    (cd "$root" && "$LANE_MAIL" send --item overseer --directive \
      --file "$TMP_ROOT/shared-note.txt" >/dev/null)
  done
  SHARED_ALPHA_ID="$(jq -r .id "$SHARED_ALPHA/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || SHARED_ALPHA_ID=unsent
  SHARED_BETA_ID="$(jq -r .id "$SHARED_BETA/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || SHARED_BETA_ID=unsent
  SHARED_ALPHA_SEEN=0
  SHARED_BETA_SEEN=0
  for pass in 1 2 3; do
    out="$(WATCH_BIN="$bin" WATCH_CWD="$SHARED_ALPHA" run_watch -- \
      --max-loops 1 --repo owner/alpha 2>"$TMP_ROOT/shared-alpha-$pass")"
    SHARED_ALPHA_SEEN=$((SHARED_ALPHA_SEEN + $(grep -c "^EVENT owner-note $SHARED_ALPHA_ID$" <<<"$out" || true)))
    out="$(WATCH_BIN="$bin" WATCH_CWD="$SHARED_BETA" run_watch -- \
      --max-loops 1 --repo owner/beta 2>"$TMP_ROOT/shared-beta-$pass")"
    SHARED_BETA_SEEN=$((SHARED_BETA_SEEN + $(grep -c "^EVENT owner-note $SHARED_BETA_ID$" <<<"$out" || true)))
  done
}
new_case mail_shared_state_dir
shared_fleet
assert_eq "$SHARED_ALPHA_SEEN" "1" \
  "one watch's note is emitted once across three passes over a shared state directory" \
  "$TMP_ROOT/shared-alpha-3"
assert_eq "$SHARED_BETA_SEEN" "1" \
  "the other watch's note is emitted once across the same three passes" \
  "$TMP_ROOT/shared-beta-3"

# A peer overseer writes this one's mailbox from its own checkout, so the watch
# reports the repository the note came from rather than the owner.
new_case mail_peer_note
mail_reset overseer
PEER_REPO="$TMP_ROOT/peer-repo"
rm -rf -- "${PEER_REPO:?}"
mkdir -p -- "$PEER_REPO"
git -C "$PEER_REPO" init -q
printf 'VSY-47 is ours; hold KEN-7.\n' > "$TMP_ROOT/peer-note.txt"
(cd "$PEER_REPO" && "$LANE_MAIL" peer send --repo "$CASE_REPO_ROOT" --file "$TMP_ROOT/peer-note.txt")
PEER_NOTE="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || PEER_NOTE=unsent
err="$TMP_ROOT/peer-a"
out="$(run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT peer-note peer-repo $PEER_NOTE kind=directive" \
  "a peer overseer's note emits peer-note naming its repository, the message id and its kind" "$err"
assert_contains "$out" "  VSY-47 is ours; hold KEN-7." "the peer note's text follows its event line" "$err"
# The third kind the peer-note entry names. An overseer runs this watch rather
# than blocking in `wait`, so a peer's answer reaches it here or nowhere.
printf 'Ours after all.\n' > "$TMP_ROOT/peer-answer.txt"
(cd "$PEER_REPO" && "$LANE_MAIL" peer send --repo "$CASE_REPO_ROOT" --re some-ask --file "$TMP_ROOT/peer-answer.txt")
PEER_ANSWER="$(jq -rs 'map(select(.kind == "answer")) | .[0] | .id' "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || PEER_ANSWER=unsent
err="$TMP_ROOT/peer-b"
out="$(run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT peer-note peer-repo $PEER_ANSWER kind=answer re=some-ask" \
  "a peer's answer emits peer-note naming the ask of this overseer's it replies to" "$err"

# Only an ask is owed a reply, and a directive answered would name an id in no
# outbox, so the two must not arrive in one shape.
new_case mail_peer_ask
mail_reset overseer
printf 'Do you own VSY-47?\n' > "$TMP_ROOT/peer-ask.txt"
(cd "$PEER_REPO" && "$LANE_MAIL" peer ask --repo "$CASE_REPO_ROOT" --file "$TMP_ROOT/peer-ask.txt" >/dev/null)
PEER_INBOUND="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || PEER_INBOUND=unsent
err="$TMP_ROOT/peer-ask"
out="$(run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT peer-note peer-repo $PEER_INBOUND kind=ask" \
  "a peer's ask is told from a note by the kind on its line" "$err"

# Each lane-local read surface can fail on the first item without starving the
# next item. The second pass keeps the same failure in place: the later lane's
# successful mail and handoff rows must stop both of its events replaying.
continuation_pair() { # mail|state-fetch|handoff-output [WATCH_BIN]
  local kind="$1" bin="${2:-}" first=KEN-62 later=KEN-63 remote wrapper sealed item
  local -a CONTINUE_ENV CONTINUE_ARGS
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
  rm -f -- "$CASE_REPO_ROOT/tmp/workflow-state-$first.json" \
    "$CASE_REPO_ROOT/tmp/workflow-state-$later.json"
  mkdir -p "$CASE_REPO_ROOT/tmp/lane-mail/$first" "$CASE_REPO_ROOT/tmp/lane-mail/$later"
  printf '{"id":"first-%s","kind":"notice","at":"t","text":"First lane."}\n' "$kind" \
    > "$CASE_REPO_ROOT/tmp/lane-mail/$first/to-overseer.jsonl"
  printf '{"id":"later-%s","kind":"notice","at":"t","text":"Later lane."}\n' "$kind" \
    > "$CASE_REPO_ROOT/tmp/lane-mail/$later/to-overseer.jsonl"
  CONTINUE_ENV=()
  CONTINUE_ARGS=(--max-loops 1 --item "$first" --item "$later")
  CONTINUE_CAUSE=""
  CONTINUE_HANDOFF=""
  sealed=""
  case "$kind" in
    mail)
      sealed="$CASE_REPO_ROOT/tmp/lane-mail/$first/to-overseer.jsonl"
      chmod 000 "$sealed"
      CONTINUE_CAUSE="oversee-watch: mail-read-failed item=$first exit=2"
      ;;
    state-fetch)
      remote="$STUB_DIR/continuation-remote"
      rm -rf -- "${remote:?}"
      for item in "$first" "$later"; do
        mkdir -p "$remote/srv/lane/$item/tmp/lane-mail/$item" "$remote/srv/clone/tmp/lane-mail/$item"
        printf 'gitdir: /srv/clone/.git/worktrees/%s\n' "$item" > "$remote/srv/lane/$item/.git"
        cp "$CASE_REPO_ROOT/tmp/lane-mail/$item/to-overseer.jsonl" \
          "$remote/srv/lane/$item/tmp/lane-mail/$item/to-overseer.jsonl"
        printf '{"handoff":{"written_at":"t"}}\n' \
          > "$remote/srv/clone/tmp/workflow-state-$item.json"
      done
      rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
      CONTINUE_ENV=(ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log"
        LANE_HOST_STUB_DIR="$remote" LANE_HOST_STUB_CAT_STATUS=1
        LANE_HOST_STUB_CAT_ITEM="$first"
        LANE_HOST_STUB_CAT_PATH="/srv/clone/tmp/workflow-state-$first.json")
      CONTINUE_ARGS+=(--hosted "$first=/srv/lane/$first" --hosted "$later=/srv/lane/$later")
      CONTINUE_CAUSE="oversee-watch: handoff-read-failed item=$first path=/srv/clone/tmp"
      CONTINUE_HANDOFF="EVENT handoff $later"
      ;;
    handoff-output)
      printf '{"handoff":{"written_at":"t"}}\n' \
        > "$CASE_REPO_ROOT/tmp/workflow-state-$first.json"
      printf '{"handoff":{"written_at":"t"}}\n' \
        > "$CASE_REPO_ROOT/tmp/workflow-state-$later.json"
      wrapper="$STUB_DIR/workflow-state-invalid.sh"
      cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if [[ " $* " == *" handoff-standing KEN-62 "* ]]; then
  printf 'workflow-state: handoff-standing=invalid\n'
  exit 0
fi
exec "$WORKFLOW_STATE_STUB" "$@"
EOF
      chmod +x "$wrapper"
      CONTINUE_ENV=(OVERSEE_WATCH_WORKFLOW_STATE="$wrapper"
        WORKFLOW_STATE_STUB="$TMP_ROOT/bin/workflow-state-stub.sh")
      CONTINUE_CAUSE="oversee-watch: handoff-read-failed item=$first path=$CASE_REPO_ROOT/tmp"
      CONTINUE_HANDOFF="EVENT handoff $later"
      ;;
    *) echo "continuation_pair: unknown kind: $kind" >&2; exit 2 ;;
  esac
  CONTINUE_RC=0
  CONTINUE_OUT="$(WATCH_BIN="$bin" run_watch ${CONTINUE_ENV[@]+"${CONTINUE_ENV[@]}"} -- \
    "${CONTINUE_ARGS[@]}" 2>"$STUB_DIR/continue-a.err")" || CONTINUE_RC=$?
  CONTINUE_AGAIN_RC=0
  CONTINUE_AGAIN="$(WATCH_BIN="$bin" run_watch ${CONTINUE_ENV[@]+"${CONTINUE_ENV[@]}"} -- \
    "${CONTINUE_ARGS[@]}" 2>"$STUB_DIR/continue-b.err")" || CONTINUE_AGAIN_RC=$?
  [[ -z "$sealed" ]] || chmod 644 "$sealed"
}

for kind in mail state-fetch handoff-output; do
  new_case "mail_continue_$kind"
  continuation_pair "$kind"
  assert_eq "$CONTINUE_RC" "2" "$kind failure exits 2 after the completed pass"
  assert_eq "$(grep -cxF -- "$CONTINUE_CAUSE" "$STUB_DIR/continue-a.err" || :)" "1" \
    "$kind failure prints its keyed cause once" "$STUB_DIR/continue-a.err"
  assert_eq "$(grep -cx "EVENT lane-notice KEN-63 later-$kind" <<<"$CONTINUE_OUT" || :)" "1" \
    "$kind failure does not hide the later lane's mail" "$STUB_DIR/continue-a.err"
  [[ -z "$CONTINUE_HANDOFF" ]] || assert_eq \
    "$(grep -cxF -- "$CONTINUE_HANDOFF" <<<"$CONTINUE_OUT" || :)" "1" \
    "$kind failure does not hide the later lane's handoff" "$STUB_DIR/continue-a.err"
  assert_eq "$CONTINUE_AGAIN_RC" "0" "$kind failure, standing unchanged, fails no later pass"
  assert_eq "$(grep -cxF -- "EVENT lane-notice KEN-63 later-$kind" <<<"$CONTINUE_AGAIN" || :)" "0" \
    "$kind failure preserves the later lane's successful cursors" "$STUB_DIR/continue-b.err"
  [[ -z "$CONTINUE_HANDOFF" ]] || assert_eq \
    "$(grep -cxF -- "$CONTINUE_HANDOFF" <<<"$CONTINUE_AGAIN" || :)" "0" \
    "$kind failure preserves the later lane's successful handoff row" "$STUB_DIR/continue-b.err"
done

# One stopped hosted lane is a failed read, not the end of the pass. The later
# lane and both kinds of overseer note each advance their own cursor. The
# stopped row advances only when the provider reports another state.
stopped_fleet() { # [WATCH_BIN]
  local bin="${1:-}" remote_disk="$STUB_DIR/stopped-remote" n
  STOPPED_REMOTE="$remote_disk"
  mail_reset overseer
  rm -rf -- "${remote_disk:?}"
  for n in 60 61; do
    mkdir -p "$remote_disk/srv/lane/KEN-$n/tmp/lane-mail/KEN-$n"
    printf 'gitdir: /srv/clone/.git/worktrees/KEN-%s\n' "$n" \
      > "$remote_disk/srv/lane/KEN-$n/.git"
  done
  printf '{"id":"later-1","kind":"notice","at":"t","text":"Later lane."}\n' \
    > "$remote_disk/srv/lane/KEN-61/tmp/lane-mail/KEN-61/to-overseer.jsonl"
  printf 'Owner note.\n' > "$TMP_ROOT/stopped-owner.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item overseer --directive \
    --file "$TMP_ROOT/stopped-owner.txt" >/dev/null)
  STOPPED_OWNER="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl")"
  printf 'Peer note.\n' > "$TMP_ROOT/stopped-peer.txt"
  (cd "$PEER_REPO" && "$LANE_MAIL" peer send --repo "$CASE_REPO_ROOT" \
    --file "$TMP_ROOT/stopped-peer.txt")
  STOPPED_PEER="$(jq -rs '.[1].id' "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl")"
  STOPPED_RC=0
  STOPPED_OUT="$(WATCH_BIN="$bin" run_watch ORCH_LANE_HOST="$FIXTURE_HOST" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$remote_disk" \
    LANE_HOST_STUB_CAT_STATUS=1 LANE_HOST_STUB_CAT_ITEM=KEN-60 \
    LANE_HOST_STUB_CAT_STATE=stopped -- --max-loops 1 \
    --item KEN-60 --hosted KEN-60=/srv/lane/KEN-60 \
    --item KEN-61 --hosted KEN-61=/srv/lane/KEN-61 2>"$TMP_ROOT/stopped-a")" \
    || STOPPED_RC=$?
  STOPPED_AGAIN_RC=0
  STOPPED_AGAIN="$(WATCH_BIN="$bin" run_watch ORCH_LANE_HOST="$FIXTURE_HOST" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$remote_disk" \
    LANE_HOST_STUB_CAT_STATUS=1 LANE_HOST_STUB_CAT_ITEM=KEN-60 \
    LANE_HOST_STUB_CAT_STATE=stopped -- --max-loops 1 \
    --item KEN-60 --hosted KEN-60=/srv/lane/KEN-60 \
    --item KEN-61 --hosted KEN-61=/srv/lane/KEN-61 2>"$TMP_ROOT/stopped-b")" \
    || STOPPED_AGAIN_RC=$?
}

new_case mail_stopped_lane_continues
stopped_fleet
assert_eq "$STOPPED_RC" "2" "a stopped hosted lane makes the completed pass fail"
assert_eq "$(grep -c '^oversee-watch: handoff-read-failed item=KEN-60 ' "$TMP_ROOT/stopped-a" || :)" "1" \
  "the stopped lane's keyed failure is emitted once" "$TMP_ROOT/stopped-a"
assert_eq "$(grep -c '^lane-stopped item=KEN-60 state=stopped verb=cat$' "$TMP_ROOT/stopped-a" || :)" "1" \
  "the provider's stopped state follows the keyed failure once" "$TMP_ROOT/stopped-a"
assert_eq "$(grep -c '^EVENT lane-notice KEN-61 later-1$' <<<"$STOPPED_OUT" || :)" "1" \
  "the pass reports the later lane's notice" "$TMP_ROOT/stopped-a"
assert_eq "$(grep -c "^EVENT owner-note $STOPPED_OWNER$" <<<"$STOPPED_OUT" || :)" "1" \
  "the pass reports the owner's note" "$TMP_ROOT/stopped-a"
assert_eq "$(grep -c "^EVENT peer-note peer-repo $STOPPED_PEER kind=directive$" <<<"$STOPPED_OUT" || :)" "1" \
  "the pass reports the peer note" "$TMP_ROOT/stopped-a"
assert_eq "$STOPPED_AGAIN_RC" "0" "the standing stopped lane, reported once, fails no later pass"
assert_eq "$(grep -c 'lane-stopped item=KEN-60 state=stopped' "$TMP_ROOT/stopped-b" || :)" "0" \
  "the same stopped state is not reported on every pass" "$TMP_ROOT/stopped-b"
assert_eq "$(grep -v '^EVENT heartbeat ' <<<"$STOPPED_AGAIN" | grep -c '^EVENT ' || :)" "0" \
  "the successful lane and overseer cursors suppress their events on the next pass" "$TMP_ROOT/stopped-b"
run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" \
  LANE_HOST_STUB_DIR="$STOPPED_REMOTE" -- --max-loops 1 \
  --item KEN-60 --hosted KEN-60=/srv/lane/KEN-60 \
  --item KEN-61 --hosted KEN-61=/srv/lane/KEN-61 >/dev/null 2>"$TMP_ROOT/stopped-recovered"
rc=0
out="$(run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" \
  LANE_HOST_STUB_DIR="$STOPPED_REMOTE" LANE_HOST_STUB_CAT_STATUS=1 \
  LANE_HOST_STUB_CAT_ITEM=KEN-60 LANE_HOST_STUB_CAT_STATE=stopped -- --max-loops 1 \
  --item KEN-60 --hosted KEN-60=/srv/lane/KEN-60 \
  --item KEN-61 --hosted KEN-61=/srv/lane/KEN-61 2>"$TMP_ROOT/stopped-c")" || rc=$?
assert_eq "$rc" "2" "the lane's next stopped state makes the completed pass fail again"
assert_eq "$(grep -c '^lane-stopped item=KEN-60 state=stopped verb=cat$' "$TMP_ROOT/stopped-c" || :)" "1" \
  "a successful read clears the stopped sighting, so the next stop is reported" "$TMP_ROOT/stopped-c"

STOP_EARLY="$MUTANT_DIR/orch/scripts/oversee-watch-stop-early"
python3 -c 'import sys
src, out = sys.argv[1:]
s = open(src).read()
old = "    PASS_FAILED=1\n    ow_message"
new = "    exit 2\n    ow_message"
assert s.count(old) == 1, "deferred-exit mutant pattern"
open(out, "w").write(s.replace(old, new))' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" "$STOP_EARLY"
chmod +x "$STOP_EARLY"
assert_eq "$(cmp -s "$STOP_EARLY" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the stop-early mutant really restores a lane failure's immediate exit"
new_case mail_stopped_lane_control
stopped_fleet "$STOP_EARLY"
assert_eq "$(grep -c '^EVENT ' <<<"$STOPPED_OUT" || :)" "0" \
  "control: ending at the failed lane drops the later lane and both overseer notes" "$TMP_ROOT/stopped-a"

NO_SUCCESS_CURSOR="$MUTANT_DIR/orch/scripts/oversee-watch-no-success-cursor"
sed 's@state="$(lane_row_set lane-mail "$state" "$cursor" "$count $first")"@:@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$NO_SUCCESS_CURSOR"
chmod +x "$NO_SUCCESS_CURSOR"
assert_eq "$(cmp -s "$NO_SUCCESS_CURSOR" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the cursor mutant really drops the successful lane's cursor"
new_case mail_stopped_lane_cursor_control
stopped_fleet "$NO_SUCCESS_CURSOR"
assert_eq "$(grep -c '^EVENT lane-notice KEN-61 later-1$' <<<"$STOPPED_AGAIN" || :)" "1" \
  "control: without its cursor the successful later lane is reported again" "$TMP_ROOT/stopped-b"

KINDLESS="$MUTANT_DIR/orch/scripts/oversee-watch-kindless"
sed 's@\$id kind=\$kind\${re:+ re=\$re}@$id${re:+ re=$re}@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$KINDLESS"
chmod +x "$KINDLESS"
assert_eq "$(cmp -s "$KINDLESS" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the kindless mutant really drops the kind"
new_case mail_peer_kindless
mail_reset overseer
(cd "$PEER_REPO" && "$LANE_MAIL" peer ask --repo "$CASE_REPO_ROOT" --file "$TMP_ROOT/peer-ask.txt" >/dev/null)
KINDLESS_ASK="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || KINDLESS_ASK=unsent
err="$TMP_ROOT/kindless"
out="$(WATCH_BIN="$KINDLESS" run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT peer-note peer-repo $KINDLESS_ASK" \
  "control: without the kind an ask arrives in the same shape as a note" "$err"

# The thread pointer is the answer's alone. A lane's own records reach the
# watch through drain, and a `re=` on one would read as a reply to an ask the
# overseer never sent.
new_case mail_lane_no_thread
mail_reset KEN-52
say KEN-52 notice 'Rebased onto main.' >/dev/null
err="$TMP_ROOT/lane-thread"
out="$(run_watch -- --max-loops 1 --item KEN-52 2>"$err")"
assert_eq "$(grep -c 're=' <<<"$(head -1 <<<"$out")")" "0" \
  "a lane's event line carries no thread pointer" "$err"

THREADLESS="$MUTANT_DIR/orch/scripts/oversee-watch-threadless"
sed 's@ kind=\$kind\${re:+ re=\$re}@ kind=$kind@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$THREADLESS"
chmod +x "$THREADLESS"
assert_eq "$(cmp -s "$THREADLESS" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the threadless mutant really drops the thread pointer"
new_case mail_peer_threadless
mail_reset overseer
(cd "$PEER_REPO" && "$LANE_MAIL" peer send --repo "$CASE_REPO_ROOT" --re some-ask --file "$TMP_ROOT/peer-answer.txt")
THREADLESS_ID="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || THREADLESS_ID=unsent
err="$TMP_ROOT/threadless"
out="$(WATCH_BIN="$THREADLESS" run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT peer-note peer-repo $THREADLESS_ID kind=answer" \
  "control: without the pointer two replies from one peer are told apart by their wording alone" "$err"

THREADED_LANE="$MUTANT_DIR/orch/scripts/oversee-watch-threaded-lane"
sed 's@echo "EVENT lane-notice \$item \$id"@echo "EVENT lane-notice $item $id${re:+ re=$re}"@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$THREADED_LANE"
chmod +x "$THREADED_LANE"
assert_eq "$(cmp -s "$THREADED_LANE" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the threaded-lane mutant really puts the pointer on a lane line"
new_case mail_lane_threaded
mail_reset KEN-53
printf '{"id":"lane-1","kind":"notice","at":"t","from":"KEN-53","re":"never-asked","text":"Rebased."}\n' \
  > "$CASE_REPO_ROOT/tmp/lane-mail/KEN-53/to-overseer.jsonl"
err="$TMP_ROOT/lane-threaded"
out="$(WATCH_BIN="$THREADED_LANE" run_watch -- --max-loops 1 --item KEN-53 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-notice KEN-53 lane-1 re=never-asked" \
  "control: a pointer on a lane line reads as a reply to an ask the overseer never sent" "$err"

# Hosted lanes over the provider stub, three runs each. Each lane is the pair
# open-terminal launches for a GitHub item: item issue-N in window gh-N. The
# clone is learned from the worktree's .git file and the handoff read from the
# clone's state. KEEP gone removes the worktrees after the first run, lands a
# closing notice in each clone's mailbox and a new handoff record in each
# clone's state before the merged item's exited window closes its sandbox;
# keep leaves them standing; absent never has one.
hosted_runs() { # CASE LANES KEEP [ENV...]
  local lanes="$2" keep="$3" n run args=()
  new_case "$1"
  shift 3
  HOSTED_DISK="$STUB_DIR/remote"
  HOSTED_OUT=()
  HOSTED_RC=()
  for n in $lanes; do
    mkdir -p "$HOSTED_DISK/srv/clone/tmp/lane-mail/issue-$n"
    if [[ "$keep" != absent ]]; then
      mkdir -p "$HOSTED_DISK/srv/lane/issue-$n"
      printf 'gitdir: /srv/clone/.git/worktrees/issue-%s\n' "$n" > "$HOSTED_DISK/srv/lane/issue-$n/.git"
    fi
    printf '{"handoff":{"written_at":"t"}}\n' > "$HOSTED_DISK/srv/clone/tmp/workflow-state-issue-$n.json"
    printf 'bash\n' > "$STUB_DIR/cmd-gh-$n.txt"
    args+=(--item "issue-$n" --hosted "issue-$n=/srv/lane/issue-$n" "gh-$n")
  done
  jq -nc '[$ARGS.positional[] | {number: tonumber, headRefName: "issue-\(.)", mergedAt: "2026-09-14T10:00:00Z"}]' \
    --args $lanes > "$STUB_DIR/merged.json"
  for run in 1 2 3; do
    HOSTED_RC[run]=0
    HOSTED_OUT[run]="$(run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" \
      LANE_HOST_STUB_DIR="$HOSTED_DISK" ${1+"$@"} -- --max-loops 1 "${args[@]}" 2>"$STUB_DIR/run$run.err")" \
      || HOSTED_RC[run]=$?
    # A jammed state directory is the stub's doing; the next run starts writable.
    [[ ! -d "$STATE_DIR" ]] || chmod u+w "$STATE_DIR"
    [[ "$run" -eq 1 && "$keep" == gone ]] || continue
    for n in $lanes; do
      rm -rf -- "${HOSTED_DISK:?}/srv/lane/issue-$n"
      printf '{"id":"closing-%s","kind":"notice","at":"t","text":"Merged."}\n' "$n" \
        > "$HOSTED_DISK/srv/clone/tmp/lane-mail/issue-$n/to-overseer.jsonl"
      printf '{"handoff":{"written_at":"t2"}}\n' > "$HOSTED_DISK/srv/clone/tmp/workflow-state-issue-$n.json"
    done
  done
}
hosted_facts() { # LANES
  local n later out=""
  later="$(printf '%s\n%s\n' "${HOSTED_OUT[2]}" "${HOSTED_OUT[3]}")"
  for n in $1; do
    out+="issue-$n: handoff=$(grep -cx "EVENT handoff issue-$n" <<<"${HOSTED_OUT[1]}" || :)"
    out+=" notice=$(grep -cx "EVENT lane-notice issue-$n closing-$n" <<<"${HOSTED_OUT[2]}" || :)"
    out+=" closed=$(grep -A1 -x "EVENT lane-closed issue-$n" <<<"$later" | grep -c '^kept=' || :)"
    out+=" refused=$(grep -A1 -x "EVENT lane-close-refused issue-$n" <<<"$later" | grep -cx 'path=/srv/clone' || :)"
    out+=" closes=$(grep -c "^close --item issue-$n \$" "$STUB_DIR/host.log" || :)"
    out+=" none=$(grep -A1 -x "EVENT lane-closed issue-$n" <<<"$later" | grep -cx 'kept=none' || :); "
  done
  printf '%s' "${out%; }"
}
# One run's exit status, how many times its stderr carries KEYED_LINE, and
# with EVENT_LINE how many times its stdout carries that.
hosted_exit() { # RUN KEYED_LINE [EVENT_LINE]
  printf 'rc=%s note=%s' "${HOSTED_RC[$1]}" "$(grep -cxF -- "$2" "$STUB_DIR/run$1.err" || :)"
  [[ -z "${3:-}" ]] || printf ' out=%s' "$(grep -cxF -- "$3" <<<"${HOSTED_OUT[$1]}" || :)"
}
hosted_mutant() { # NAME OLD NEW
  python3 -c 'import sys
src, out, old, new = sys.argv[1:]
s = open(src).read()
assert s.count(old) == 1, "hosted mutant pattern: " + old
open(out, "w").write(s.replace(old, new))' "$REPO_ROOT/skills/orch/scripts/oversee-watch" "$MUTANT_DIR/orch/scripts/oversee-watch-$1" "$2" "$3"
  chmod +x "$MUTANT_DIR/orch/scripts/oversee-watch-$1"
}
hosted_mutant local-state '  [[ -n "$HOSTED_ROOT" ]] || return 0' '  return 0'
hosted_mutant unclosed '        if ! close_hosted_lane "$LANE_ITEM"; then' '        if false; then'
hosted_mutant worktree-mail '        root="$HOSTED_CLONE"; cursor="$item@clone"' '        :'
hosted_mutant retried '      echo "EVENT lane-close-refused $1"' '      return 1'
hosted_mutant standing '         && grep -qxF -- "$LANE_ITEM" <<<"$HOSTED_GONE_ITEMS"; then' '; then'
hosted_mutant fail-fast '      ow_message lane-close-failed "item=$1" "exit=$rc" >&2' '      exit 2'
hosted_mutant window '  LANE_ITEM="issue-${LANE_ITEM#gh-}"' '  :'
hosted_mutant nothing-kept '        echo "kept=none"' '        :'
hosted_mutant exit-zero '  [[ "$close_failed" -eq 0 ]] || exit 2' '  :'
hosted_mutant unkeyed '      ow_message lane-close-failed "item=$1" "exit=$rc" >&2' '      :'
hosted_mutant commit-after '        lane_row_commit "$asking_state"' '        :'
hosted_mutant misread-cat '  [[ "$rc" -eq 2 ]] || return 2' '  :'
hosted_mutant misread-touch '  "$SCRIPT_DIR/lane-host" touch --item "$1" >/dev/null 2>>"$WORK_DIR/host.err" || return 2' '  :'
hosted_mutant early-exit $'  check_handoff\n  # check_handoff commits' $'  [[ "$close_failed" -eq 0 ]] || exit 2\n  check_handoff\n  # check_handoff commits'
hosted_mutant path-unparsed '        path="${line#*close-refused path=}"' '        :'
ONE='issue-2: handoff=1 notice=1'
QUIET='issue-2: handoff=0 notice=0 closed=0 refused=0 closes=0 none=0'
FAIL2='LANE_HOST_STUB_CLOSE_STATUS=1 LANE_HOST_STUB_CLOSE_ITEM=issue-2'
CLOSE_NOTE='oversee-watch: lane-close-failed item=issue-2 exit=1'
READ_NOTE='oversee-watch: handoff-read-failed item=issue-2 path=/srv/lane/issue-2/.git'
RETRIED="issue-1: handoff=1 notice=1 closed=1 refused=0 closes=1 none=0; $ONE closed=0 refused=0 closes=2 none=0"
HOSTED_SEQ=0
# label|mutant|lanes|keep|env|facts[|exit|run|keyed line[|event line]]
for row in \
  "a hosted GitHub lane reads its handoff and closing notice from the clone and closes once||2|gone||$ONE closed=1 refused=0 closes=1 none=0" \
  "a refused close names the refused checkout's path and is never closed again||2|gone|LANE_HOST_STUB_CLOSE_STATUS=3|$ONE closed=0 refused=1 closes=1 none=0" \
  "a lane exiting while its worktree stands is not closed||2|keep||issue-2: handoff=1 notice=0 closed=0 refused=0 closes=0 none=0" \
  "a failed close is retried alone, the lane closed beside it not closed again||1 2|gone|$FAIL2|$RETRIED|rc=2 note=1|2|$CLOSE_NOTE" \
  "a close that archived nothing is reported as kept=none||2|gone|LANE_HOST_STUB_CLOSE_EMPTY=1|$ONE closed=1 refused=0 closes=1 none=1" \
  "a close whose run then fails to commit is not closed again||2|gone|LANE_HOST_STUB_CLOSE_JAM=1|$ONE closed=1 refused=0 closes=1 none=0" \
  "a failing close still lets its pass report another lane's handoff before exiting 2||1 2|gone|$FAIL2|$RETRIED|rc=2 note=1 out=1|2|$CLOSE_NOTE|EVENT handoff issue-1" \
  "a hosted read the provider fails is handoff-read-failed, never a missing file||2|gone|LANE_HOST_STUB_CAT_STATUS=1|$QUIET|rc=2 note=1|1|$READ_NOTE" \
  "a missing file on a host that does not answer is handoff-read-failed||2|absent|LANE_HOST_STUB_TOUCH_STATUS=1|$QUIET|rc=2 note=1|1|$READ_NOTE" \
  "control: read from this checkout's state, the hosted handoff is never reported|local-state|2|gone||issue-2: handoff=0 notice=1 closed=1 refused=0 closes=1 none=0" \
  "control: without the close call the sandbox stays|unclosed|2|gone||$ONE closed=0 refused=0 closes=0 none=0" \
  "control: reading the removed worktree's mailbox loses the closing notice|worktree-mail|2|gone||issue-2: handoff=1 notice=0 closed=1 refused=0 closes=1 none=0" \
  "control: a refusal read as a failure is closed again on the next run|retried|2|gone|LANE_HOST_STUB_CLOSE_STATUS=3|$ONE closed=0 refused=0 closes=2 none=0" \
  "control: without the worktree check a lane stopped inside merge-pr is closed|standing|2|keep||issue-2: handoff=1 notice=0 closed=1 refused=0 closes=1 none=0" \
  "control: a failed close that ends the pass before its row is reset is never retried|fail-fast|1 2|gone|$FAIL2|issue-1: handoff=1 notice=1 closed=1 refused=0 closes=1 none=0; $ONE closed=0 refused=0 closes=1 none=0" \
  "control: a gh-N window not mapped to issue-N never closes its lane|window|2|gone||$ONE closed=0 refused=0 closes=0 none=0" \
  "control: an empty close with no line of the watch's own leaves nothing to record|nothing-kept|2|gone|LANE_HOST_STUB_CLOSE_EMPTY=1|$ONE closed=0 refused=0 closes=1 none=0" \
  "control: a failed close whose pass exits 0 hides the failure from the caller|exit-zero|1 2|gone|$FAIL2|$RETRIED|rc=0 note=1|2|$CLOSE_NOTE" \
  "control: a failed close with no keyed line leaves the caller no item to act on|unkeyed|1 2|gone|$FAIL2|$RETRIED|rc=2 note=0|2|$CLOSE_NOTE" \
  "control: a row committed after the close is closed again when that commit fails|commit-after|2|gone|LANE_HOST_STUB_CLOSE_JAM=1|$ONE closed=2 refused=0 closes=2 none=0" \
  "control: a failed close that ends the pass early drops another lane's handoff|early-exit|1 2|gone|$FAIL2|$RETRIED|rc=2 note=1 out=0|2|$CLOSE_NOTE|EVENT handoff issue-1" \
  "control: a failed read taken as a missing file loses the path the refusal names|misread-cat|2|gone|LANE_HOST_STUB_CAT_STATUS=1|$QUIET|rc=2 note=0|1|$READ_NOTE" \
  "control: an unanswered probe taken as a missing file loses the path the refusal names|misread-touch|2|absent|LANE_HOST_STUB_TOUCH_STATUS=1|$QUIET|rc=2 note=0|1|$READ_NOTE" \
  "control: a refusal whose path is not read names no checkout|path-unparsed|2|gone|LANE_HOST_STUB_CLOSE_STATUS=3|$ONE closed=0 refused=0 closes=1 none=0"; do
  IFS='|' read -r label bin lanes keep env expect exit run needle event <<<"$row"
  read -ra envs <<<"$env"
  WATCH_BIN="${bin:+$MUTANT_DIR/orch/scripts/oversee-watch-$bin}" \
    hosted_runs "hosted_$((HOSTED_SEQ += 1))" "$lanes" "$keep" ${envs[@]+"${envs[@]}"}
  assert_eq "$(hosted_facts "$lanes")" "$expect" "$label" "$STUB_DIR/run${run:-2}.err"
  [[ -z "$exit" ]] || assert_eq "$(hosted_exit "$run" "$needle" "$event")" "$exit" "$label: exit status and keyed line" "$STUB_DIR/run$run.err"
done

# --- the mail pass on its own cadence --------------------------------------
# A lane-mail that logs each verb it is run with, stamped with the pr-watch
# calls made so far, and on the drain NOTE_AT lands a notice in KEN-70's
# mailbox before reading it: a note written between two mail passes.
cat > "$TMP_ROOT/bin/lane-mail-logging.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
calls=0; [[ -f "$STUB_DIR/prwatch.calls.owner_repo" ]] && calls="$(cat "$STUB_DIR/prwatch.calls.owner_repo")"
printf 'mail %s long=%s\n' "$1" "$calls" >> "$STUB_DIR/cadence.log"
if [[ "$1" == drain && -n "${NOTE_AT:-}" ]]; then
  n="$(grep -c '^mail drain ' "$STUB_DIR/cadence.log")"
  if [[ "$n" -eq "$NOTE_AT" ]]; then
    printf 'Rebased; CI is green.\n' > "$STUB_DIR/note.txt"
    "$REAL_LANE_MAIL" notice --item KEN-70 --file "$STUB_DIR/note.txt" >/dev/null
  fi
fi
exec "$REAL_LANE_MAIL" "$@"
EOF
# A pr-watch that marks its start and end in the same log, holding its first
# call open, with LONG_HOLD set, until three mail passes have logged under it or
# twenty seconds pass: the long pass that overruns its interval, staged on
# what the mail pass does rather than on how fast the machine is.
cat > "$TMP_ROOT/bin/pr-watch-slow.sh" <<'EOF'
#!/usr/bin/env bash
n=0; [[ -f "$STUB_DIR/prwatch.calls.owner_repo" ]] && n="$(cat "$STUB_DIR/prwatch.calls.owner_repo")"
n=$((n + 1)); printf '%s' "$n" > "$STUB_DIR/prwatch.calls.owner_repo"
printf 'long start %s\n' "$n" >> "$STUB_DIR/cadence.log"
if [[ "$n" -eq 1 && -n "${LONG_HOLD:-}" ]]; then
  waited=0
  until [[ "$(awk '$0 == "long start 1" { on = 1; next } on && /^mail drain / { k++ } END { print k + 0 }' "$STUB_DIR/cadence.log")" -ge 3 \
    || "$waited" -ge 200 ]]; do
    waited=$((waited + 1)); sleep 0.1
  done
fi
printf 'long end %s\n' "$n" >> "$STUB_DIR/cadence.log"
EOF
chmod +x "$TMP_ROOT/bin/lane-mail-logging.sh" "$TMP_ROOT/bin/pr-watch-slow.sh"
cadence_run() { # [WATCH_BIN] [ENV...] -- ARGS...
  local bin="$1" began="$SECONDS"
  shift
  mail_reset KEN-70
  CADENCE_OUT="$(WATCH_BIN="$bin" run_watch ORCH_WATCH_MAIL_INTERVAL=1 \
    OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/lane-mail-logging.sh" REAL_LANE_MAIL="$LANE_MAIL" \
    OVERSEE_WATCH_PR_WATCH="$TMP_ROOT/bin/pr-watch-slow.sh" "$@" 2>"$STUB_DIR/cadence.err")" || true
  CADENCE_LOG="$(cat "$STUB_DIR/cadence.log" 2>/dev/null)" || CADENCE_LOG=""
  CADENCE_SECS=$((SECONDS - began))
}
# How the note was reported: its event count, the drain it landed on, and the
# long passes started by the time the run ended.
cadence_facts() {
  printf 'notices=%s drains=%s long=%s' \
    "$(grep -c '^EVENT lane-notice KEN-70 ' <<<"$CADENCE_OUT" || :)" \
    "$(grep -c '^mail drain ' <<<"$CADENCE_LOG" || :)" \
    "$(grep -c '^long start ' <<<"$CADENCE_LOG" || :)"
}
# Mail passes between the first long pass's start and its end, and any long
# pass started inside that window.
overrun_facts() {
  awk '
    $0 == "long start 1" { open = 1; next }
    $0 == "long end 1" { open = 0; next }
    open && /^mail drain / { mail++ }
    open && /^long start / { overlap++ }
    END { printf "mail-during=%s overlap=%d", (mail >= 2 ? "several" : mail + 0), overlap }' <<<"$CADENCE_LOG"
}

# The note lands on the second mail pass, one second into a run whose next
# long pass is an hour away: reported on that pass, by the mail cadence alone.
new_case mail_cadence
cadence_run "" NOTE_AT=2 -- --interval 3600 --max-loops 2 --item KEN-70
assert_eq "$(cadence_facts)" "notices=1 drains=2 long=1" \
  "a lane's note is reported on the mail pass after it lands, between two long passes" "$STUB_DIR/cadence.err"

# The long pass held open past its interval: mail passes go on under it, and
# the next long pass waits for it to end.
new_case mail_cadence_overrun
cadence_run "" LONG_HOLD=1 -- --interval 1 --max-loops 2 --item KEN-70
assert_eq "$(overrun_facts)" "mail-during=several overlap=0" \
  "a long pass overrunning its interval holds up no mail pass and overlaps no long pass" "$STUB_DIR/cadence.err"

# Must-fail inverses. Mail on the long cadence reports the note only once the
# long interval is out: run at a four-second interval, since at the hour the
# row above runs at that mutant would not end. Whether the next long pass has
# started by then depends on the second its start was stamped in, so the row
# counts no long pass. A long pass run in line holds every
# mail pass up behind it; one started without waiting for the last overlaps it.
cadence_mutant() { # NAME OLD NEW
  python3 - "$REPO_ROOT/skills/orch/scripts/oversee-watch" "$MUTANT_DIR/orch/scripts/oversee-watch-$1" "$2" "$3" <<'PY'
import sys
src, out, old, new = sys.argv[1:]
s = open(src).read()
assert s.count(old) == 1, "cadence mutant pattern: " + old
open(out, "w").write(s.replace(old, new))
PY
  chmod +x "$MUTANT_DIR/orch/scripts/oversee-watch-$1"
}
cadence_mutant long-cadence 'MAIL_DUE=$((PASS_NOW + MAIL_INTERVAL))' 'MAIL_DUE=$((PASS_NOW + INTERVAL))'
cadence_mutant in-line '>"$LONG_OUT" 2>"$LONG_ERR" &' '>"$LONG_OUT" 2>"$LONG_ERR" & wait "$!"'
cadence_mutant overlapping '[[ -z "$LONG_PID" && "$LONG_PASSES" -lt "$MAX_LOOPS" ]]' '[[ "$LONG_PASSES" -lt "$MAX_LOOPS" ]]'
new_case mail_cadence_mutant
cadence_run "$MUTANT_DIR/orch/scripts/oversee-watch-long-cadence" NOTE_AT=2 -- --interval 4 --max-loops 2 --item KEN-70
assert_eq "$(cadence_facts | sed 's/ long=.*//') waited=$([[ "$CADENCE_SECS" -ge 3 ]] && echo interval || echo "${CADENCE_SECS}s")" \
  "notices=1 drains=2 waited=interval" \
  "control: mail read on the long cadence reports the note only once the long interval is out" "$STUB_DIR/cadence.err"
new_case mail_cadence_overrun_inline
cadence_run "$MUTANT_DIR/orch/scripts/oversee-watch-in-line" LONG_HOLD=1 -- --interval 1 --max-loops 2 --item KEN-70
assert_eq "$(overrun_facts)" "mail-during=0 overlap=0" \
  "control: a long pass run in line holds every mail pass up until it ends" "$STUB_DIR/cadence.err"
new_case mail_cadence_overrun_overlapping
cadence_run "$MUTANT_DIR/orch/scripts/oversee-watch-overlapping" LONG_HOLD=1 -- --interval 1 --max-loops 3 --item KEN-70
assert_eq "$([[ "$(overrun_facts)" == *' overlap=0' ]] && echo none || echo some)" "some" \
  "control: a long pass started while the last is in flight overlaps it" "$STUB_DIR/cadence.err"

# --- the overseer mailbox, read through its own cursor ----------------------
# One note across three runs, each with a state directory of its own: a
# successor started from another checkout, or with another --since, holds no
# position of the one it follows. The cursor is the mailbox's own, so the note
# is reported once whatever the watch keeps.
fresh_state_fleet() { # [WATCH_BIN]
  local bin="${1:-}" run out
  mail_reset overseer
  printf 'Hold KEN-7 for the owner.\n' > "$TMP_ROOT/fresh-note.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item overseer --directive --file "$TMP_ROOT/fresh-note.txt" >/dev/null)
  FRESH_SEEN=0
  for run in 1 2 3; do
    out="$(WATCH_BIN="$bin" run_watch OVERSEE_WATCH_STATE_DIR="$STUB_DIR/state-$run" -- --max-loops 1 \
      2>"$STUB_DIR/fresh-$run.err")"
    FRESH_SEEN=$((FRESH_SEEN + $(grep -c '^EVENT owner-note ' <<<"$out" || true)))
  done
}
new_case mail_owner_note_fresh_state
fresh_state_fleet
assert_eq "$FRESH_SEEN" "1" "an owner note is reported once across three runs that share no state directory" \
  "$STUB_DIR/fresh-3.err"
new_case mail_owner_note_fresh_state_mutant
fresh_state_fleet "$PEEKING"
assert_eq "$FRESH_SEEN" "3" "control: an overseer read that moves no cursor replays the note in every fresh state" \
  "$STUB_DIR/fresh-3.err"

# A session start reads its own mailbox before anything else; the watch it
# then starts finds that read already taken.
session_start() { # [WATCH_BIN]
  mail_reset overseer
  printf 'Merge KEN-7 once CI is green.\n' > "$TMP_ROOT/start-note.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item overseer --directive --file "$TMP_ROOT/start-note.txt" >/dev/null)
  START_READ="$(cd "$CASE_REPO_ROOT" && "$LANE_MAIL" inbox --item overseer | jq -r .text)"
  START_OUT="$(WATCH_BIN="${1:-}" run_watch -- --max-loops 1 2>"$STUB_DIR/start.err")"
}
new_case mail_session_start
session_start
assert_eq "read=$START_READ first=$(head -1 <<<"$START_OUT")" "read=Merge KEN-7 once CI is green. first=$HEARTBEAT" \
  "the session start's inbox read lists the note, and the watch after it does not report it again" "$STUB_DIR/start.err"
# The session start's own read taken past: a watch reading the mailbox file
# whole, through no cursor.
WHOLE="$MUTANT_DIR/orch/scripts/oversee-watch-whole"
python3 - "$REPO_ROOT/skills/orch/scripts/oversee-watch" "$WHOLE" <<'PY'
import sys
src, out = sys.argv[1:]
s = open(src).read()
old = 'if ! mail_read "$item" inbox "${args[@]}" --peek; then'
assert s.count(old) == 1, "whole mutant pattern"
open(out, "w").write(s.replace(old, 'if ! MAIL_OUT="$(printf \'count=0 first=\\n\'; cat -- "$PROJECT_ROOT/tmp/lane-mail/overseer/to-lane.jsonl")"; then'))
PY
chmod +x "$WHOLE"
new_case mail_session_start_mutant
session_start "$WHOLE"
assert_contains "$START_OUT" "EVENT owner-note " \
  "control: a watch reading the mailbox through no cursor reports the note the session start already read" "$STUB_DIR/start.err"

# --- a hosted mailbox read that misses lines --------------------------------
# The first notice is drained; the next read of the mailbox comes back empty,
# as a provider does whose file read failed while its probe answered; a second
# notice lands; the third read is whole again. Only the second notice is news.
missed_read_fleet() { # [WATCH_BIN]
  local bin="${1:-}" box="$STUB_DIR/remote/srv/lane/KEN-90/tmp/lane-mail/KEN-90/to-overseer.jsonl" run
  local -a host_env
  mkdir -p "${box%/*}"
  printf 'gitdir: /srv/clone/.git/worktrees/ken-90\n' > "$STUB_DIR/remote/srv/lane/KEN-90/.git"
  printf '{"id":"hosted-1","kind":"notice","at":"t","text":"First."}\n' > "$box"
  host_env=(ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$STUB_DIR/remote")
  MISSED_OUT=""
  for run in 1 2 3; do
    local -a extra=()
    [[ "$run" -ne 2 ]] || extra=(LANE_HOST_STUB_CAT_STATUS=2 LANE_HOST_STUB_CAT_PATH=/srv/lane/KEN-90/tmp/lane-mail/KEN-90/to-overseer.jsonl)
    MISSED_OUT+="$(WATCH_BIN="$bin" run_watch "${host_env[@]}" ${extra[@]+"${extra[@]}"} -- --max-loops 1 \
      --item KEN-90 --hosted KEN-90=/srv/lane/KEN-90 2>"$STUB_DIR/missed-$run.err")"$'\n'
    [[ "$run" -ne 2 ]] || printf '{"id":"hosted-2","kind":"notice","at":"t","text":"Second."}\n' >> "$box"
  done
}
new_case mail_hosted_missed_read
missed_read_fleet
assert_eq "first=$(grep -c '^EVENT lane-notice KEN-90 hosted-1$' <<<"$MISSED_OUT" || :) second=$(grep -c '^EVENT lane-notice KEN-90 hosted-2$' <<<"$MISSED_OUT" || :)" \
  "first=1 second=1" "a hosted read that misses lines moves no position, so each notice is reported once" "$STUB_DIR/missed-3.err"
cadence_mutant lowered '[[ "$replaced" -eq 0 && "$count" -lt "$prior" ]] \' '[[ "$replaced" -eq 1 ]] \'
new_case mail_hosted_missed_read_mutant
missed_read_fleet "$MUTANT_DIR/orch/scripts/oversee-watch-lowered"
assert_eq "first=$(grep -c '^EVENT lane-notice KEN-90 hosted-1$' <<<"$MISSED_OUT" || :)" "first=2" \
  "control: a position lowered to the missed read reports the first notice again" "$STUB_DIR/missed-3.err"

# --- a hosted root that is a clone ------------------------------------------
# The record's root is the repository clone itself, whose .git is a directory:
# the mailbox is read at the root, and nothing is appended to it.
clone_root_fleet() { # [WATCH_BIN]
  local root="$STUB_DIR/remote/srv/clone"
  mkdir -p "$root/.git" "$root/tmp/lane-mail/KEN-91"
  printf 'ref: refs/heads/main\n' > "$root/.git/HEAD"
  printf '{"id":"clone-1","kind":"ask","at":"t","text":"Which base?"}\n' > "$root/tmp/lane-mail/KEN-91/to-overseer.jsonl"
  CLONE_RC=0
  CLONE_OUT="$(WATCH_BIN="${1:-}" run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" \
    LANE_HOST_STUB_DIR="$STUB_DIR/remote" -- --max-loops 1 --item KEN-91 --hosted KEN-91=/srv/clone \
    2>"$STUB_DIR/clone.err")" || CLONE_RC=$?
}
new_case mail_hosted_clone_root
clone_root_fleet
assert_eq "rc=$CLONE_RC asks=$(grep -c '^EVENT lane-question KEN-91 clone-1$' <<<"$CLONE_OUT" || :) failed=$(grep -c '^oversee-watch: handoff-read-failed ' "$STUB_DIR/clone.err" || :)" \
  "rc=0 asks=1 failed=0" "a hosted root that is a clone has its ask read there, with no read failure" "$STUB_DIR/clone.err"
cadence_mutant gitfile-only '    if host_fetch "$1" "$HOSTED_ROOT/.git/HEAD" "$WORK_DIR/githead"; then' '    if false; then'
new_case mail_hosted_clone_root_mutant
clone_root_fleet "$MUTANT_DIR/orch/scripts/oversee-watch-gitfile-only"
assert_eq "rc=$CLONE_RC asks=$(grep -c '^EVENT lane-question KEN-91 clone-1$' <<<"$CLONE_OUT" || :)" "rc=2 asks=0" \
  "control: read only as a worktree's .git file, a clone root's ask is never reported" "$STUB_DIR/clone.err"

# A read failure that stands is reported on the run that meets it and not on
# every run after, and a successful read makes the next one news again: four
# runs, failing, failing, whole, failing.
standing_failure() { # [WATCH_BIN]
  local run box="$CASE_REPO_ROOT/tmp/lane-mail/KEN-92/to-overseer.jsonl"
  mail_reset KEN-92
  say KEN-92 notice 'Standing by.' >/dev/null
  STANDING=""
  for run in 1 2 3 4; do
    [[ "$run" -eq 3 ]] || chmod 000 "$box"
    WATCH_BIN="${1:-}" run_watch -- --max-loops 1 --item KEN-92 >/dev/null 2>"$STUB_DIR/standing-$run.err" || true
    chmod 644 "$box"
    STANDING+="$(grep -c '^oversee-watch: mail-read-failed item=KEN-92 ' "$STUB_DIR/standing-$run.err" || :)"
  done
}
new_case mail_standing_failure
standing_failure
assert_eq "reports=$STANDING" "reports=1001" \
  "an unchanged lane read failure is reported once, and again after a read that succeeded" "$STUB_DIR/standing-4.err"
cadence_mutant loud '  if [[ "$prior" != "$key" ]]; then' '  if true; then'
# The standing failure is quiet but not forgotten: a later quiet run's
# heartbeat names the channel still broken.
new_case mail_standing_failure_heartbeat
mail_reset KEN-94
say KEN-94 notice 'Standing by.' >/dev/null
chmod 000 "$CASE_REPO_ROOT/tmp/lane-mail/KEN-94/to-overseer.jsonl"
run_watch -- --max-loops 1 --item KEN-94 >/dev/null 2>"$STUB_DIR/beat-a.err" || true
BEAT="$(run_watch -- --max-loops 1 --item KEN-94 2>"$STUB_DIR/beat-b.err")" || true
chmod 644 "$CASE_REPO_ROOT/tmp/lane-mail/KEN-94/to-overseer.jsonl"
assert_eq "$(sed -n 2p <<<"$BEAT" | cut -d' ' -f1-6)" "  failing KEN-94 mail-read-failed item=KEN-94" \
  "a later quiet run's heartbeat names the lane whose failure still stands" "$STUB_DIR/beat-b.err"
# The item leaves the fleet with its failure standing: a later heartbeat
# names only the current fleet's channels.
BEAT="$(run_watch -- --max-loops 1 --item KEN-95 2>"$STUB_DIR/beat-c.err")" || true
assert_eq "$(grep -c '^  failing KEN-94 ' <<<"$BEAT" || :)" "0" \
  "a lane that left the fleet with its failure standing is not named in a later heartbeat" "$STUB_DIR/beat-c.err"
cadence_mutant fleetless '      NF == 3 && $1 == "lane-failed" && ($2 in watched) { print "  failing " $2 " " $3 }'"'"' \' \
  '      NF == 3 && $1 == "lane-failed" { print "  failing " $2 " " $3 }'"'"' \'
BEAT="$(WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch-fleetless" run_watch -- --max-loops 1 --item KEN-95 2>/dev/null)" || true
assert_eq "$(grep -c '^  failing KEN-94 ' <<<"$BEAT" || :)" "1" \
  "control: rows read whatever the fleet is name a departed lane in every heartbeat"
cadence_mutant beatless '  [[ -z "$failing" ]] || printf '"'"'%s\n'"'"' "$failing"' '  :'
new_case mail_standing_failure_heartbeat_mutant
mail_reset KEN-94
say KEN-94 notice 'Standing by.' >/dev/null
chmod 000 "$CASE_REPO_ROOT/tmp/lane-mail/KEN-94/to-overseer.jsonl"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch-beatless" run_watch -- --max-loops 1 --item KEN-94 >/dev/null 2>&1 || true
BEAT="$(WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch-beatless" run_watch -- --max-loops 1 --item KEN-94 2>/dev/null)" || true
chmod 644 "$CASE_REPO_ROOT/tmp/lane-mail/KEN-94/to-overseer.jsonl"
assert_eq "$(grep -c '^  failing ' <<<"$BEAT" || :)" "0" \
  "control: a heartbeat listing only PRs says nothing of the broken mailbox"

new_case mail_standing_failure_mutant
standing_failure "$MUTANT_DIR/orch/scripts/oversee-watch-loud"
assert_eq "reports=$STANDING" "reports=1101" "control: with no failure row every run reports the same failure again" \
  "$STUB_DIR/standing-2.err"

# Two refusals from lane-mail under one exit status are two failures: the key
# carries the tool's own keyed line, so the second cause is reported too.
cat > "$TMP_ROOT/bin/lane-mail-refusing.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == drain ]]; then
  printf 'lane-mail: %s=/srv/box\nThe refusal.\n' "$(cat "$STUB_DIR/refusal")" >&2
  exit 2
fi
exec "$REAL_LANE_MAIL" "$@"
EOF
chmod +x "$TMP_ROOT/bin/lane-mail-refusing.sh"
two_causes() { # [WATCH_BIN]
  local key
  mail_reset KEN-93
  CAUSES=""
  for key in lock-failed file-unreadable; do
    printf '%s' "$key" > "$STUB_DIR/refusal"
    WATCH_BIN="${1:-}" run_watch OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/lane-mail-refusing.sh" \
      REAL_LANE_MAIL="$LANE_MAIL" -- --max-loops 1 --item KEN-93 >/dev/null 2>"$STUB_DIR/causes-$key.err" || true
    CAUSES+="$(grep -c '^oversee-watch: mail-read-failed item=KEN-93 ' "$STUB_DIR/causes-$key.err" || :)"
  done
}
new_case mail_two_causes
two_causes
assert_eq "reports=$CAUSES" "reports=11" "a second refusal under the same exit status is reported as the new failure it is" \
  "$STUB_DIR/causes-file-unreadable.err"
cadence_mutant causeless '      awk '"'"'/^[A-Za-z0-9._-]+: [A-Za-z0-9._-]+([= ]|$)/ { print; exit }'"'"' <<<"$LANE_FAILURE_DETAIL")"' '      :)"'
new_case mail_two_causes_mutant
two_causes "$MUTANT_DIR/orch/scripts/oversee-watch-causeless"
assert_eq "reports=$CAUSES" "reports=10" "control: keyed on the reason alone, the second cause passes in silence" \
  "$STUB_DIR/causes-file-unreadable.err"

# The overseer mailbox acknowledged after its notes print: an --ack lane-mail
# refuses, here lock-failed as a cursor lock held past its wait gives, is the
# mailbox's failure. The note is printed, the refusal is said once, the run
# fails, and the cursor stays for the next reader.
cat > "$TMP_ROOT/bin/lane-mail-ack-refusing.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == inbox && " $* " == *" --item overseer "* && " $* " == *" --ack "* ]]; then
  printf 'lane-mail: lock-failed=/srv/box/to-lane.cursor.lock\nThe refusal.\n' >&2
  exit 2
fi
exec "$REAL_LANE_MAIL" "$@"
EOF
chmod +x "$TMP_ROOT/bin/lane-mail-ack-refusing.sh"
ack_refused() { # [WATCH_BIN]
  local rc=0 out cursor
  mail_reset overseer
  printf 'Hold the release.\n' > "$TMP_ROOT/ack-note.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item overseer --directive --file "$TMP_ROOT/ack-note.txt" >/dev/null)
  out="$(WATCH_BIN="${1:-}" run_watch OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/lane-mail-ack-refusing.sh" \
    REAL_LANE_MAIL="$LANE_MAIL" -- --max-loops 1 2>"$STUB_DIR/ack.err")" || rc=$?
  cursor="$(cat "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.cursor" 2>/dev/null || :)"
  ACK_REFUSED="rc=$rc printed=$(grep -c '^EVENT owner-note ' <<<"$out" || :)"
  ACK_REFUSED+=" refused=$(grep -c '^oversee-watch: mail-read-failed item=overseer exit=2$' "$STUB_DIR/ack.err" || :)"
  ACK_REFUSED+=" cursor=${cursor:-0}"
}
new_case mail_ack_refused
ack_refused
assert_eq "$ACK_REFUSED" "rc=2 printed=1 refused=1 cursor=0" \
  "a refused overseer --ack prints the note, reports the failure once and fails the run, moving no cursor" \
  "$STUB_DIR/ack.err"
cadence_mutant ack-unreported '      else
        lane_failure_report "$item" "$state"
        state="$LANE_FAILURE_STATE"
      fi
      mail_row_commit "$state"
      continue' '      fi
      mail_row_commit "$state"
      continue'
new_case mail_ack_refused_mutant
ack_refused "$MUTANT_DIR/orch/scripts/oversee-watch-ack-unreported"
assert_eq "$ACK_REFUSED" "rc=0 printed=1 refused=0 cursor=0" \
  "control: without the failure arm a refused ack passes in silence" "$STUB_DIR/ack.err"

# An answered ask read while to-lane.jsonl reads as not there beside a cursor
# past its answer, as a hosted read that misses once returns it: the drain has
# no answer to drop the ask by and the receipts read the cursor as missed. The
# pass reports nothing of the item and moves no row, and once the file reads
# whole the ask stays answered. A read failure standing before it is cleared,
# and stays cleared through the overseer mailbox read after it.
answered_missed() { # [WATCH_BIN]
  local box="$CASE_REPO_ROOT/tmp/lane-mail/KEN-60" out
  mail_reset KEN-60
  ANSWERED_ASK="$(say KEN-60 ask 'Squash or merge?')"
  ANSWERED_ASK="${ANSWERED_ASK#id=}"
  answer KEN-60 "$ANSWERED_ASK" 'Squash.' >/dev/null
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" inbox --item KEN-60 >/dev/null)
  chmod 000 "$box/to-overseer.jsonl"
  WATCH_BIN="${1:-}" run_watch -- --max-loops 1 --item KEN-60 >/dev/null 2>"$STUB_DIR/answered-f" || true
  chmod 644 "$box/to-overseer.jsonl"
  mv -- "$box/to-lane.jsonl" "$box/to-lane.jsonl.away"
  out="$(WATCH_BIN="${1:-}" run_watch -- --max-loops 1 --item KEN-60 2>"$STUB_DIR/answered-a")"
  ANSWERED_MISSED="first=$(head -1 <<<"$out") row=$(awk -F'\t' '$1 == "lane-mail" && $2 == "KEN-60" { print $3 }' \
    "$STATE_DIR"/*.mail 2>/dev/null || true)"
  ANSWERED_MISSED+=" failed=$(awk -F'\t' '$1 == "lane-failed" && $2 == "KEN-60"' "$STATE_DIR"/*.mail | wc -l)"
  mv -- "$box/to-lane.jsonl.away" "$box/to-lane.jsonl"
  out="$(WATCH_BIN="${1:-}" run_watch -- --max-loops 1 --item KEN-60 2>"$STUB_DIR/answered-b")"
  ANSWERED_MISSED+=" after=$(grep -c '^EVENT lane-question ' <<<"$out" || true)"
}
new_case mail_answered_missed
answered_missed
assert_eq "$ANSWERED_MISSED" "first=$HEARTBEAT row= failed=0 after=0" \
  "a to-lane read that missed reports no answered ask as a question, moves no row and clears a failure" \
  "$STUB_DIR/answered-a"
cadence_mutant deliver-first '    if [[ "$hold" == item ]]; then' '    if false; then'
new_case mail_answered_missed_mutant
answered_missed "$MUTANT_DIR/orch/scripts/oversee-watch-deliver-first"
assert_eq "$ANSWERED_MISSED" "first=EVENT lane-question KEN-60 $ANSWERED_ASK row=1 $ANSWERED_ASK failed=0 after=0" \
  "control: delivered before the missed read is judged, the answered ask is a question and its row moves past it" \
  "$STUB_DIR/answered-a"
cadence_mutant hold-stale '      state="$(lane_row_clear lane-failed "$state" "$item")"
      mail_row_commit "$state"
      continue' '      mail_row_commit "$(lane_row_clear lane-failed "$state" "$item")"
      continue'
new_case mail_answered_missed_stale_mutant
answered_missed "$MUTANT_DIR/orch/scripts/oversee-watch-hold-stale"
assert_eq "${ANSWERED_MISSED#* row= }" "failed=1 after=0" \
  "control: a hold that commits the cleared row but keeps its stale state restores the failure" "$STUB_DIR/answered-a"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
