#!/usr/bin/env bash
# Surface: oversee-watch mail and long pass process starts at fifteen lanes.
# Inputs: scripts/oversee-watch, scripts/lib/*.sh, tests/lib/oversee-watch-harness.sh,
# tests/lib/process-count.py, and the mailbox and GitHub required sibling skills.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/lib/git-env.sh"
source "${BASH_SOURCE[0]%/*}/lib/oversee-watch-harness.sh"
source "${BASH_SOURCE[0]%/*}/lib/process-count.sh"

if [[ -z "${BASHPID:-}" ]]; then
  printf 'process attribution requires BASHPID\npass: 0   fail: 0\n'
  exit 0
fi

measure_passes() { # CASE WATCH
  new_case "$1"
  args=()
  : >"$STUB_DIR/windows.txt"
  for ((i=1; i<=15; i++)); do
    lane="gh-$i"
    printf '%s\n' "$lane" >>"$STUB_DIR/windows.txt"
    printf '⏺ working on it\n' >"$STUB_DIR/pane-$lane.txt"
    printf 'claude\n' >"$STUB_DIR/cmd-$lane.txt"
    printf '%s\n' "$((9000 + i))" >"$STUB_DIR/panepid-$lane.txt"
    box="$CASE_REPO_ROOT/tmp/lane-mail/KEN-$i"
    mkdir -p "$box"
    printf '{"id":"n%s","kind":"notice","text":"Unread"}\n' "$i" >"$box/to-overseer.jsonl"
    args+=(--item "KEN-$i" --root "KEN-$i=$CASE_REPO_ROOT" "$lane")
  done
  counter="$STUB_DIR/count"
  python3 "$REPO_ROOT/skills/orch/tests/lib/process-count.py" install "$counter" "$TMP_ROOT/bin:$PATH" "$BASH" oversee-watch passes
  rc=0
  WATCH_BIN="$2" run_watch \
    BASH_ENV="$counter/bash-env" PATH="$counter/bin:$TMP_ROOT/bin:$PATH" -- \
    --max-loops 1 "${args[@]}" >"$STUB_DIR/out" 2>"$STUB_DIR/err" || rc=$?
  assert_eq "$rc" 0 'fixed fifteen-lane pass completes' "$STUB_DIR/err"
  assert_eq "$(grep -c '^EVENT lane-notice ' "$STUB_DIR/out" || :)" 15 'mail pass reads every lane notice'
  for ((i=1; i<=15; i++)); do
    assert_eq "$(cat "$STUB_DIR/pane-gh-$i.calls")" 1 "long pass captures lane $i once"
  done
  counts="$(python3 "$REPO_ROOT/skills/orch/tests/lib/process-count.py" steps "$counter")"
  printf '%s\n' "$counts"
  for step in mail_turn.check_mail long_pass.observe_lanes long_pass.check_lanes; do
    starts="$(sed -n "s/^$step=//p" <<<"$counts")"
    assert_le 15 "$starts" "$step records at least one start for each lane"
  done
  MAIL_COST="$(sed -n 's/^mail_turn=//p' <<<"$counts")"
  LONG_COST="$(sed -n 's/^long_pass=//p' <<<"$counts")"
}

measure_passes fixed_fifteen "${PASS_COST_WATCH:-$REPO_ROOT/skills/orch/scripts/oversee-watch}"
[[ -z "${PASS_COST_EVIDENCE:-}" ]] || printf '%s\n' "$counts" >"$PASS_COST_EVIDENCE"
assert_le "$MAIL_COST" 100 'fifteen-lane mail pass starts at most one hundred processes'
assert_le "$LONG_COST" 1020 'fifteen-lane long pass starts at most 1020 processes'

# Restoring the per-lane window reads preserves the workload and exceeds the bound.
CONTROL_SCRIPTS="$(mutant_scripts pass-cost-control/orch oversee-watch)"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/pass-cost-control/github"
mutate_file "$CONTROL_SCRIPTS/oversee-watch" 'local LANE_WINDOW_CACHE=1' 'local LANE_WINDOW_CACHE=0'
measure_passes per_lane_control "$CONTROL_SCRIPTS/oversee-watch"
control_rc=0
(FAIL=0; assert_le "$LONG_COST" 1020 'per-lane reads satisfy the long-pass bound'; [[ "$FAIL" -eq 0 ]]) \
  >"$STUB_DIR/control.out" || control_rc=$?
assert_eq "$control_rc" 1 'control: the long-pass bound rejects per-lane window reads'
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
