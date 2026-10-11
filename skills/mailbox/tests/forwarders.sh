#!/usr/bin/env bash
# Surface: old orch mailbox paths. Inputs: mailbox/scripts/**, orch forwarding scripts, orch/tests/lane-mail-watch.sh.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
REPO_ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
# shellcheck source=../../orch/tests/lib/assertions.sh
. "$REPO_ROOT/skills/orch/tests/lib/assertions.sh"
# shellcheck source=../../orch/tests/lib/growth-state.sh
. "$REPO_ROOT/skills/orch/tests/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'mailbox-forwarders: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'mailbox-forwarders: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'mailbox-forwarders: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
PROJECT="$TMP_ROOT/project"
SKILLS_ROOT="${FORWARDERS_UNDER_TEST:-$REPO_ROOT/skills}"
mkdir -p "$PROJECT/.agents/skills/orch" "$PROJECT/.agents/skills/mailbox"
cp -R "$SKILLS_ROOT/orch/scripts" "$PROJECT/.agents/skills/orch/scripts"
cp -R "$SKILLS_ROOT/mailbox/scripts" "$PROJECT/.agents/skills/mailbox/scripts"
git -C "$PROJECT" init -q
git -C "$PROJECT" config gc.auto 0
git -C "$PROJECT" config maintenance.auto false
OLD="$PROJECT/.agents/skills/orch/scripts/lane-mail"
NEW="$PROJECT/.agents/skills/mailbox/scripts/lane-mail"
"$OLD" --help > "$TMP_ROOT/old.help" 2>"$TMP_ROOT/err"
"$NEW" --help > "$TMP_ROOT/new.help"
assert_eq "$(cmp "$TMP_ROOT/old.help" "$TMP_ROOT/new.help"; echo "$?")" 0 'forwarder keeps help bytes'
assert_eq "$(cat "$TMP_ROOT/err")" '' 'nonterminal help writes no warning'
printf 'Same receipt.\n' > "$TMP_ROOT/message"
receipt=""
for script in "$OLD" "$NEW"; do
  out="$(cd -- "$PROJECT" && env -u ORCH_STATE_DIR "$script" send --item TEST-1 --directive --file "$TMP_ROOT/message" 2>"$TMP_ROOT/err")"
  envelope="$(tail -n 1 "$PROJECT/tmp/lane-mail/TEST-1/to-lane.jsonl" | jq -r .id)"
  assert_eq "$(sed -n 's/.* id=\([^ ]*\).*/\1/p' <<<"$out")" "$envelope" 'receipt names the appended envelope'
  fields="${out/ id=$envelope/ id=ID}"
  if [ -n "$receipt" ]; then assert_eq "$fields" "$receipt" 'forwarder keeps receipt fields'; fi
  receipt="$fields"
  assert_eq "$(cat "$TMP_ROOT/err")" '' 'nonterminal send writes no warning'
  rm -rf -- "${PROJECT:?}/tmp/lane-mail/TEST-1"
done
for script in "$OLD" "$NEW"; do
  rc=0
  (cd -- "$PROJECT" && env -u ORCH_STATE_DIR "$script" send --item overseer --directive --file "$TMP_ROOT/message") \
    >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || rc=$?
  assert_eq "$rc" 2 'overseer refusal keeps its exit'
  first="$(sed -n '1p' "$TMP_ROOT/err")"
  if [ "$script" = "$OLD" ]; then refused="$first"; else assert_eq "$first" "$refused" 'forwarder keeps first refusal line'; fi
done
for library in file-lock mailbox-append; do
  case "$library" in file-lock) function=orch_take_lock ;; *) function=mailbox_append_locked ;; esac
  out="$("$BASH" -c '. "$1"; declare -F "$2"' _ "$PROJECT/.agents/skills/orch/scripts/lib/$library.sh" "$function" 2>"$TMP_ROOT/err")"
  assert_eq "$out" "$function" "$library forwarder defines its function"
  assert_eq "$(cat "$TMP_ROOT/err")" '' "$library forwarder writes no nonterminal warning"
done
rc=0
"$BASH" "$REPO_ROOT/skills/orch/tests/lane-mail-watch.sh" --term-row "$OLD" \
  >"$TMP_ROOT/term.log" 2>&1 || rc=$?
assert_eq "$rc" 0 'TERM through the forwarder stops the watch and withdraws its record' "$TMP_ROOT/term.log"
if [ -z "${FORWARDERS_UNDER_TEST:-}" ]; then
  # Fleet reads the first keyed stderr line. An unconditional warning breaks it.
  for control in lane-mail file-lock mailbox-append no-exec; do
    mkdir -p "$TMP_ROOT/$control/skills"
    cp -R "$PROJECT/.agents/skills/." "$TMP_ROOT/$control/skills/"
    if [ "$control" = lane-mail ]; then
      mutate_file "$TMP_ROOT/$control/skills/orch/scripts/lane-mail" 'if [ -t 2 ]; then' 'if :; then'
    elif [ "$control" = no-exec ]; then
      mutate_file "$TMP_ROOT/$control/skills/orch/scripts/lane-mail" \
        'exec "${BASH_SOURCE[0]%/*}/../../mailbox/scripts/lane-mail" "$@"' \
        '"${BASH_SOURCE[0]%/*}/../../mailbox/scripts/lane-mail" "$@"'
    else
      mutate_file "$TMP_ROOT/$control/skills/orch/scripts/lib/$control.sh" \
        '. "${BASH_SOURCE[0]%/*}/../../../mailbox/scripts/lib/'"$control"'.sh"' ':'
    fi
    rc=0
    env FORWARDERS_UNDER_TEST="$TMP_ROOT/$control/skills" "$BASH" "$REPO_ROOT/skills/mailbox/tests/forwarders.sh" \
      >"$TMP_ROOT/$control.log" 2>&1 || rc=$?
    assert_eq "$rc" 1 "$control mutant fails the same assertions"
    if [ "$control" = no-exec ]; then
      if grep -Eq 'term=(running|exited):record-kept' "$TMP_ROOT/$control.log"; then
        pass 'the no-exec control reaches the retained watch record'
      else
        fail 'the no-exec control reaches the retained watch record'
        dump_stderr "$TMP_ROOT/$control.log"
      fi
    fi
  done
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
