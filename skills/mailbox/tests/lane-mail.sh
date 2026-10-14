#!/usr/bin/env bash
# Surface: lane-mail message input. Inputs: skills/mailbox/scripts/**, skills/orch/scripts/**.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
# shellcheck source=../../orch/tests/lib/assertions.sh
. "$ROOT/skills/orch/tests/lib/assertions.sh"
# shellcheck source=../../orch/tests/lib/growth-state.sh
. "$ROOT/skills/orch/tests/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'mailbox-input: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'mailbox-input: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'mailbox-input: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/.agents/skills/mailbox" "$REPO/.agents/skills/orch" "$REPO/tmp" "$TMP_ROOT/open directory" "$TMP_ROOT/home"
cp -R "${MAILBOX_UNDER_TEST:-$ROOT/skills/mailbox}/scripts" "$REPO/.agents/skills/mailbox/scripts"
cp -R "$ROOT/skills/orch/scripts" "$REPO/.agents/skills/orch/scripts"
git -C "$REPO" init -q
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
MAIL="$REPO/.agents/skills/mailbox/scripts/lane-mail"
printf 'The caller file.\n' > "$REPO/tmp/message with spaces"
# A Pi-style shell launch starts in the caller directory. A DEBUG trap changes
# only the child script's directory at its message-file check, after parsing.
cat > "$TMP_ROOT/move.sh" <<'MOVE'
trap 'if [[ $BASH_COMMAND == lm_read_file ]]; then
  cd -- "$OPEN_CWD"
  printf "open-cwd=%s file=%s\n" "$(pwd -P)" "$FILE" >&2
  trap - DEBUG
fi' DEBUG
MOVE
for given in 'tmp/message with spaces' "$REPO/tmp/message with spaces" 'tmp/missing file'; do
  rc=0
  env -i PATH="$PATH" HOME="$TMP_ROOT/home" BASH_ENV="$TMP_ROOT/move.sh" OPEN_CWD="$TMP_ROOT/open directory" \
    "$BASH" -c 'cd -- "$1" && printf "caller-cwd=%s\n" "$(pwd -P)" >&2 && "$2" ask --item TEST-1 --file "$3"' \
    _ "$REPO" "$MAIL" "$given" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || rc=$?
  assert_file_contains "$TMP_ROOT/err" "caller-cwd=$REPO" 'shell starts at the file owner'
  assert_file_contains "$TMP_ROOT/err" "open-cwd=$TMP_ROOT/open directory" 'directory moves inside lane-mail'
  case "$given" in /*) resolved="$given" ;; *) resolved="$REPO/$given" ;; esac
  if [[ $given == 'tmp/missing file' ]]; then
    assert_eq "$rc" 2 'missing message refuses'
    assert_file_contains "$TMP_ROOT/err" "lane-mail: file-unreadable=$given resolved=$resolved" 'refusal preserves given and resolved paths for the overseer'
  else
    assert_eq "$rc" 0 'message sends after the directory moves' "$TMP_ROOT/err"
    if [[ $rc -eq 0 ]]; then
      assert_eq "$(jq -r .text "$REPO/tmp/lane-mail/TEST-1/to-overseer.jsonl")" 'The caller file.' 'ask reads the caller file'
      rm -rf -- "$REPO/tmp/lane-mail/TEST-1"
    fi
  fi
done
if [[ -z ${MAILBOX_UNDER_TEST:-} ]]; then
  mkdir -p "$TMP_ROOT/control"
  cp -R "$ROOT/skills/mailbox/scripts" "$TMP_ROOT/control/scripts"
  mutate_file "$TMP_ROOT/control/scripts/lane-mail" '*) FILE="$(pwd -P)/$FILE" || refuse root-unresolved . ;;' '*) : ;;'
  rc=0
  env MAILBOX_UNDER_TEST="$TMP_ROOT/control" "$BASH" "$ROOT/skills/mailbox/tests/lane-mail.sh" > "$TMP_ROOT/control.log" 2>&1 || rc=$?
  assert_eq "$rc" 1 'relative-open control fails the same assertions'
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
