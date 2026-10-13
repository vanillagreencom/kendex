#!/usr/bin/env bash
# Surface: owner ask tracker writer and outcome projection.
# Inputs: skills/mailbox/scripts/**, skills/slack/scripts/**, skills/orch/references/secret-value.ere,
# skills/mailbox/tests/lib/owner-tracker.py,
# skills/orch/tests/lib/assertions.sh, skills/orch/tests/lib/growth-state.sh.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
# shellcheck source=../../orch/tests/lib/assertions.sh
. "$ROOT/skills/orch/tests/lib/assertions.sh"
# shellcheck source=../../orch/tests/lib/growth-state.sh
. "$ROOT/skills/orch/tests/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'owner-tracker: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'owner-tracker: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'owner-tracker: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
run_rows() { # SOURCE
  python3 - "$ROOT/skills/mailbox/tests/lib/owner-tracker.py" "$1" "$TMP_ROOT" "$BASH" <<'PY'
import subprocess
import sys
import os
import signal
child = subprocess.Popen([sys.executable, *sys.argv[1:]], start_new_session=True)
try:
    child.wait(timeout=60)
except subprocess.TimeoutExpired:
    os.killpg(child.pid, signal.SIGKILL)
    child.wait()
    raise
sys.exit(child.returncode)
PY
}
FACTS="$(run_rows "${MAILBOX_UNDER_TEST:-$ROOT/skills/mailbox}")"
assert_eq "$(jq '.pending' <<<"$FACTS")" true 'tracker calls start after a marked immutable ask'
assert_eq "$(jq '.terminal' <<<"$FACTS")" true 'each tracker result appends its terminal outcome'
assert_eq "$(jq '.projection' <<<"$FACTS")" true 'readers fold terminal outcomes without replay or private events'
assert_eq "$(jq '.delivery' <<<"$FACTS")" true 'the real relay holds pending asks then posts the selected form once'
assert_eq "$(jq '.bound' <<<"$FACTS")" true 'a missing outcome releases at the fixed bound and preserves later delivery'
if [[ -z "${MAILBOX_UNDER_TEST:-}" ]]; then
  for rule in pending failed bound; do
    mkdir -p "$TMP_ROOT/control-$rule"
    cp -R "$ROOT/skills/mailbox/scripts" "$TMP_ROOT/control-$rule/scripts"
    if [[ "$rule" == pending ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lane-mail" '.tracker_pending = true' '.tracker_pending = false'
      assertion='the real relay holds pending asks then posts the selected form once'
    elif [[ "$rule" == failed ]]; then
      mutate_file "$TMP_ROOT/control-$rule/scripts/lane-mail" 'lm_append_local "$TO_OVERSEER" "$POSTED_LINE"' \
        'if [ "$OWNER_TRACKER_POSTED" -eq 1 ]; then lm_append_local "$TO_OVERSEER" "$POSTED_LINE"; fi'
      assertion='the real relay holds pending asks then posts the selected form once'
    else
      mutate_file "$TMP_ROOT/control-$rule/scripts/lib/lane-mail-store.py" \
        'and (release_at is None or time.time() < release_at)' \
        'and (release_at is None or True or time.time() < release_at)'
      assertion='a missing outcome releases at the fixed bound and preserves later delivery'
    fi
    control_rc=0
    MAILBOX_UNDER_TEST="$TMP_ROOT/control-$rule" "$BASH" "$ROOT/skills/mailbox/tests/owner-tracker.sh" \
      >"$TMP_ROOT/control-$rule.log" 2>&1 || control_rc=$?
    assert_eq "$control_rc" 1 "control: removing $rule makes the writer suite fail"
    assert_file_contains "$TMP_ROOT/control-$rule.log" "FAIL  $assertion" "control: $rule reaches its contract assertion"
  done
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
