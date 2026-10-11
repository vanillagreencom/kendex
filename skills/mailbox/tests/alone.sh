#!/usr/bin/env bash
# Surface: mailbox without orch. Inputs: skills/mailbox/scripts/**.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
# shellcheck source=../../orch/tests/lib/assertions.sh
. "$ROOT/skills/orch/tests/lib/assertions.sh"
# shellcheck source=../../orch/tests/lib/growth-state.sh
. "$ROOT/skills/orch/tests/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'mailbox-alone: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'mailbox-alone: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'mailbox-alone: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
REPO="$TMP_ROOT/repo"
PEER="$TMP_ROOT/peer"
mkdir -p "$REPO/.agents/skills/mailbox" "$PEER" "$TMP_ROOT/home"
cp -R "${MAILBOX_UNDER_TEST:-$ROOT/skills/mailbox}/scripts" "$REPO/.agents/skills/mailbox/scripts"
for project in "$REPO" "$PEER"; do
  git -C "$project" init -q
  git -C "$project" config gc.auto 0
  git -C "$project" config maintenance.auto false
done
MAIL="$REPO/.agents/skills/mailbox/scripts/lane-mail"
printf 'Mailbox message.\n' > "$TMP_ROOT/message"
lm() {
  RC=0
  OUT="$(cd -- "$REPO" && env -i PATH="$PATH" HOME="$TMP_ROOT/home" \
    "$MAIL" "$@" 2>"$TMP_ROOT/err")" || RC=$?
  ERR="$(sed -n '1p' "$TMP_ROOT/err")"
}
unchanged() { # VERB ARGS...
  local before after
  before="$(git -C "$REPO" status --porcelain --untracked-files=all)"
  lm "$@"
  after="$(git -C "$REPO" status --porcelain --untracked-files=all)"
  assert_eq "$after" "$before" "$1 writes no file"
}
reader_refusal() { # SEND|PEER
  if [ "$1" = send ]; then
    unchanged send --item overseer --directive --file "$TMP_ROOT/message"
  else
    unchanged peer send --repo "$PEER" --file "$TMP_ROOT/message"
    assert_eq "$(git -C "$PEER" status --porcelain --untracked-files=all)" '' 'peer target stays unchanged'
  fi
  assert_eq "$RC" 2 "$1 refuses without a reader"
  assert_eq "${ERR%%=*}" 'lane-mail: overseer-absent' "$1 keeps the reader refusal key"
}
if [ "${1:-}" = --reader-row ]; then
  reader_refusal send
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
  exit
fi

lm ask --item overseer --to owner --wait 0 --options proceed,hold --recommend hold --file "$TMP_ROOT/message"
assert_eq "$RC" 0 'owner ask works alone'
ASK="${OUT#id=}"
lm notice --item overseer --to owner --file "$TMP_ROOT/message"
assert_eq "$RC" 0 'notice works alone'
for verb in events pending inbox drain; do
  args=("$verb" --item overseer --root "$REPO")
  [ "$verb" != drain ] || args+=(--after 0)
  lm "${args[@]}"
  assert_eq "$RC" 0 "$verb works alone"
done
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC" 0 'resolve works alone'
lm wait --item overseer --id "$ASK" --timeout 0
assert_eq "$RC" 0 'wait reads the resolved ask alone'
# A watch wakes only for unread inbound mail. This fixture is the answer
# producer's existing envelope format, with no registered session needed.
printf '{"id":"watch-answer","kind":"answer","re":"%s","text":"Watch wake."}\n' "$ASK" >> "$REPO/tmp/lane-mail/overseer/to-lane.jsonl"
lm watch --item overseer --once
assert_eq "$RC" 0 'watch works alone'
reader_refusal send
reader_refusal peer
while IFS='|' read -r verb item flag value; do
  args=("$verb" --item "$item" --root "$REPO")
  [ -z "$flag" ] || args+=("$flag")
  [ -z "$value" ] || args+=("$value")
  case "$verb" in send) args+=(--directive --file "$TMP_ROOT/message") ;; notice) args+=(--to owner --file "$TMP_ROOT/message") ;; esac
  unchanged "${args[@]}"
  assert_eq "$RC" 2 "$verb $flag refuses without orch"
  assert_eq "${ERR%%=*}" 'lane-mail: orch-missing' "$verb $flag names the missing package"
done <<ROWS
send|TEST-1||
events|overseer|--host|
send|overseer|--state-dir|$TMP_ROOT/state
compact|overseer||
notice|overseer|--attach|$TMP_ROOT/message
ROWS

if [ -z "${MAILBOX_UNDER_TEST:-}" ]; then
  for control in startup reader require; do
    mkdir -p "$TMP_ROOT/$control"
    cp -R "$ROOT/skills/mailbox/scripts" "$TMP_ROOT/$control/scripts"
    if [ "$control" = startup ]; then
      mutate_file "$TMP_ROOT/$control/scripts/lane-mail" '. "$SCRIPT_DIR/lib/common-root.sh"' \
        '. "$SCRIPT_DIR/lib/common-root.sh"; . "$ORCH_SCRIPTS/lib/lane-host-read.sh"'
      row=()
    elif [ "$control" = reader ]; then
      mutate_file "$TMP_ROOT/$control/scripts/lane-mail" 'if [ ! -f "$ORCH_SCRIPTS/workflow-state" ]; then' \
        'if [ ! -f "$ORCH_SCRIPTS/workflow-state" ]; then return 0;'
      row=(--reader-row)
    else
      mutate_file "$TMP_ROOT/$control/scripts/lane-mail" 'lm_require_orch() { # FILE...' \
        'lm_require_orch() { return 0; # FILE...'
      row=()
    fi
    rc=0
    env MAILBOX_UNDER_TEST="$TMP_ROOT/$control" "$BASH" "$ROOT/skills/mailbox/tests/alone.sh" \
      ${row[@]+"${row[@]}"} >"$TMP_ROOT/$control.log" 2>&1 || rc=$?
    assert_eq "$rc" 1 "$control mutant fails the same assertions"
  done
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
