#!/usr/bin/env bash
# Surface: lane-mail drain-many, the batched read. Inputs: skills/mailbox/scripts/**, skills/orch/scripts/orch-runtime.
# The batch's contract is the single verb's: each lane's section is what
# `drain --receipts` prints for it, under an `item=` line, in request order,
# with mailbox alone installed. A lane that cannot be read stops the call
# with that lane's refusal and retracts nothing printed before it.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
export MSYS=winsymlinks:nativestrict
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
# shellcheck source=../../orch/tests/lib/assertions.sh
. "$ROOT/skills/orch/tests/lib/assertions.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'mailbox-drain-many: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'mailbox-drain-many: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'mailbox-drain-many: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/.agents/skills/mailbox" "$TMP_ROOT/home"
cp -R "${MAILBOX_UNDER_TEST:-$ROOT/skills/mailbox}/scripts" "$REPO/.agents/skills/mailbox/scripts"
git -C "$REPO" init -q
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
MAIL="$REPO/.agents/skills/mailbox/scripts/lane-mail"
lm() { # ARGS... -> RC, OUT, ERR (the first stderr line)
  RC=0
  OUT="$(cd -- "$REPO" && env -i PATH="$PATH" HOME="$TMP_ROOT/home" \
    ${LANE_HOST_READ_DIR:+"LANE_HOST_READ_DIR=$LANE_HOST_READ_DIR"} "$MAIL" "$@" 2>"$TMP_ROOT/err")" || RC=$?
  ERR="$(sed -n '1p' "$TMP_ROOT/err")"
}
printf 'Cut the scanner?\n' > "$TMP_ROOT/ask"
printf 'Rebased.\n' > "$TMP_ROOT/notice"
# KEN-1 holds an ask and a notice, KEN-2 a notice, KEN-3 nothing.
lm ask --item KEN-1 --file "$TMP_ROOT/ask" --options cut,keep
assert_eq "$RC" 0 'the ask lands' "$ERR"
lm notice --item KEN-1 --file "$TMP_ROOT/notice"
assert_eq "$RC" 0 'the notice lands' "$ERR"
lm notice --item KEN-2 --file "$TMP_ROOT/notice"
assert_eq "$RC" 0 "the second lane's notice lands" "$ERR"
# A directive the lane has read: its receipt names the cursor.
printf 'Rebase onto main.\n' > "$TMP_ROOT/directive"
printf '{"id":"d-1","kind":"directive","at":"2026-01-29T15:20:00Z","from":"overseer:repo","text":"Rebase."}\n' >> "$REPO/tmp/lane-mail/KEN-2/to-lane.jsonl"
lm inbox --item KEN-2 --root "$REPO"
assert_eq "$RC" 0 'the lane reads its directive' "$ERR"

echo "=== each section is the single verb's answer, in request order ==="
EXPECTED=""
for pair in 'KEN-2 0' 'KEN-1 1' 'KEN-3 0'; do
  read -r item after <<<"$pair"
  lm drain --item "$item" --root "$REPO" --after "$after" --receipts
  assert_eq "$RC" 0 "drain $item answers" "$ERR"
  EXPECTED+="item=$item"$'\n'"$OUT"$'\n'
done
EXPECTED="${EXPECTED%$'\n'}"
printf 'KEN-2 0 %s\nKEN-1 1 %s\nKEN-3 0 %s\n' "$REPO" "$REPO" "$REPO" > "$TMP_ROOT/request"
lm drain-many --file "$TMP_ROOT/request"
assert_eq "rc=$RC" "rc=0" 'the batch answers' "$ERR"
assert_eq "$OUT" "$EXPECTED" "three lanes, one process, the single verb's sections in order"
assert_contains "$OUT" 'receipts cursor=1 count=1 first=d-1' "the read lane's receipt carries its cursor"
assert_eq "$(grep -c '^item=' <<<"$OUT")" 3 'one item line per lane'
# An empty request answers nothing.
: > "$TMP_ROOT/empty"
lm drain-many --file "$TMP_ROOT/empty"
assert_eq "rc=$RC out=$OUT" "rc=0 out=" 'an empty request is an empty answer' "$ERR"

echo "=== a lane that cannot be read stops the call, naming it ==="
printf 'KEN-2 0 %s\nKEN-1 x %s\nKEN-3 0 %s\n' "$REPO" "$REPO" "$REPO" > "$TMP_ROOT/bad-after"
lm drain-many --file "$TMP_ROOT/bad-after"
assert_eq "rc=$RC err=$ERR" 'rc=2 err=lane-mail: after-invalid=x item=KEN-1' 'a cursor that is no count refuses, naming the lane'
assert_eq "$(grep -c '^item=' <<<"$OUT")" 1 'the lane before it was printed, the lanes after it not'
assert_contains "$OUT" 'item=KEN-2' 'the first lane stands'
printf 'KEN-2 0 %s\nKEN-1\n' "$REPO" > "$TMP_ROOT/short-line"
lm drain-many --file "$TMP_ROOT/short-line"
assert_eq "rc=$RC err=$ERR" 'rc=2 err=lane-mail: root-unresolved=KEN-1' 'a line short of its root refuses, naming the lane'
printf 'KEN-2 0 %s\n../x 0 %s\n' "$REPO" "$REPO" > "$TMP_ROOT/bad-item"
lm drain-many --file "$TMP_ROOT/bad-item"
assert_eq "rc=$RC err=$ERR" 'rc=2 err=lane-mail: item-invalid=../x' 'an item outside the alphabet refuses'
printf 'x\n' > "$REPO/tmp/lane-mail/KEN-1/to-lane.cursor"
printf 'KEN-2 0 %s\nKEN-1 0 %s\n' "$REPO" "$REPO" > "$TMP_ROOT/bad-cursor"
lm drain-many --file "$TMP_ROOT/bad-cursor"
assert_eq "rc=$RC err=$ERR" "rc=2 err=lane-mail: cursor-invalid=$REPO/tmp/lane-mail/KEN-1/to-lane.cursor" "a lane's cursor that holds no count refuses the call with the single verb's key"
assert_eq "$(grep -c '^item=' <<<"$OUT")" 1 'the lane before it stands'
rm -- "$REPO/tmp/lane-mail/KEN-1/to-lane.cursor"

flockless_unsafe_box() {
  local path="$TMP_ROOT/path-without-flock" name
  local box="$REPO/tmp/lane-mail/KEN-4"
  mkdir -p "$path" "$TMP_ROOT/elsewhere" "${box%/*}"
  for name in bash sh python3 cat tail mkdir mv rm rmdir date jq awk sed git \
    tr head sleep cp ln wc sort grep dirname basename touch chmod id uname env mktemp; do
    ln -s "$(type -P "$name")" "$path/$name"
  done
  ln -s "$TMP_ROOT/elsewhere" "$box"
  [[ -L "$box" ]] || { fail 'the unsafe mailbox fixture is a symlink'; return; }
  printf 'KEN-4 0 %s\n' "$REPO" > "$TMP_ROOT/unsafe-request"
  PATH="$path" lm drain-many --file "$TMP_ROOT/unsafe-request"
  assert_eq "$RC=$ERR=$OUT" "2=lane-mail: mailbox-unsafe=$box=" 'a batch without flock refuses an unsafe lane mailbox'
}
flockless_unsafe_box

echo "=== the request is the one input ==="
lm drain-many
assert_eq "rc=$RC err=$ERR" 'rc=2 err=lane-mail: option-required=--file' 'no request refuses'
lm drain-many --file "$TMP_ROOT/request" --item KEN-1
assert_eq "rc=$RC err=$ERR" 'rc=2 err=lane-mail: option-unknown=--item' 'a lane option on the batch refuses'
lm drain-many --file "$TMP_ROOT/request" --host
assert_eq "rc=$RC err=$ERR" 'rc=2 err=lane-mail: option-unknown=--host' 'a hosted batch refuses'
lm drain-many --file "$TMP_ROOT/missing"
assert_eq "rc=$RC err=$ERR" "rc=2 err=lane-mail: file-unreadable=$TMP_ROOT/missing resolved=$TMP_ROOT/missing" 'a request that is not there refuses'

hosted_numbering() {
  local snapshot="$TMP_ROOT/hosted" mailbox="$REPO/tmp/lane-mail"
  local item member path status file=0 previous
  ln -s -- "$ROOT/skills/orch" "$REPO/.agents/skills/orch"
  mkdir -p "$snapshot" "$mailbox/KEN-3"
  : > "$mailbox/KEN-3/to-overseer.jsonl"
  printf '%s\n' '{"dropped":0,"first":"Older.ID_2-","lines":[]}' > "$mailbox/KEN-2/to-lane.jsonl.numbering"
  printf '%s\n' '{"dropped":0,"first":"invalid id","lines":[]}' > "$mailbox/KEN-1/to-overseer.jsonl.numbering"
  printf '%s\n' '{"dropped":0,"first":"","lines":[]}' > "$mailbox/KEN-3/to-overseer.jsonl.numbering"
  # Cached reads receive one provider status and snapshot file per path.
  for item in KEN-1 KEN-2 KEN-3; do
    for member in to-overseer.jsonl to-overseer.jsonl.numbering to-lane.jsonl to-lane.jsonl.numbering to-lane.cursor to-lane.cursor.lock; do
      path="$mailbox/$item/$member"
      file=$((file + 1))
      status=2
      if [ -f "$path" ]; then
        cp -- "$path" "$snapshot/$file"
        status=0
      fi
      printf '%s\t%s\t%s\t%s\n' "$item" "$path" "$status" "$file"
    done
  done > "$snapshot/index"
  local LANE_HOST_READ_DIR="$snapshot"
  printf 'KEN-2 0 %s\n' "$REPO" > "$TMP_ROOT/neighbor"
  lm drain-many --file "$TMP_ROOT/neighbor" --host
  assert_eq "$RC" 0 'legacy ID characters remain readable' "$ERR"
  assert_contains "$OUT" 'receipts cursor=1 count=1 first=Older.ID_2-' 'the valid lane retains its own receipt'
  previous="$OUT"
  printf 'KEN-2 0 %s\nKEN-1 0 %s\nKEN-3 0 %s\n' "$REPO" "$REPO" "$REPO" > "$TMP_ROOT/bad-numbering"
  lm drain-many --file "$TMP_ROOT/bad-numbering" --host
  assert_eq "rc=$RC err=$ERR" "rc=2 err=lane-mail: file-unreadable=$mailbox/KEN-1/to-overseer.jsonl" \
    'malformed numbering is refused by the cached reader'
  assert_eq "$OUT" "$previous" 'the invalid lane emits no section and leaves its valid neighbor intact'
  printf 'KEN-3 0 %s\n' "$REPO" > "$TMP_ROOT/empty-numbering"
  lm drain-many --file "$TMP_ROOT/empty-numbering" --host
  assert_eq "rc=$RC out=$OUT" "rc=0 out=item=KEN-3"$'\n''count=0 first='$'\n''receipts cursor=0 count=0 first=' \
    'the next lane remains readable with an empty persisted first ID' "$ERR"
}
hosted_numbering

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
