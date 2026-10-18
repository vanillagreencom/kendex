#!/usr/bin/env bash
# Count complete mail passes and idle ticks with the reader's shared fixture.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/git-env.sh"
source "${BASH_SOURCE[0]%/*}/oversee-watch-harness.sh"
source "${BASH_SOURCE[0]%/*}/growth-state.sh"
source "${BASH_SOURCE[0]%/*}/process-count.sh"

echo '=== oversee-watch process budgets ==='
if [[ -z "${BASHPID:-}" ]]; then
  printf 'rowless: process counting requires BASHPID; behavior runs in the mail suite\n'
  exit 0
fi

HOSTED_NOW="$(date -u +%s)" || exit 1

hosted_cost() { # NAME LANES WATCH READER
  local name="$1" lanes="$2" watch="$3" reader="$4" i root box counter rc=0
  new_case "$name"
  printf '%s\n' "$HOSTED_NOW" >"$STUB_DIR/now.epoch"
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
  mkdir -p "$STATE_DIR"
  : >"$STATE_DIR/owner_repo__none.mail"
  box="$CASE_REPO_ROOT/tmp/lane-mail/overseer"
  mkdir -p "$box"
  : >"$box/to-lane.jsonl"; : >"$box/to-lane.cursor.lock"
  printf '0\n' >"$box/to-lane.cursor"
  : >"$STUB_DIR/windows.txt"
  for ((i=1; i<=lanes; i++)); do
    root="/srv/lane/KEN-$i"
    box="$STUB_DIR/remote$root/tmp/lane-mail/KEN-$i"
    mkdir -p "$box"
    printf 'gitdir: /srv/clone/KEN-%s/.git/worktrees/lane\n' "$i" >"$STUB_DIR/remote$root/.git"
    printf '{"id":"n%s","kind":"notice","text":"Unread"}\n' "$i" >"$box/to-overseer.jsonl"
    printf '{"id":"d%s","kind":"directive","at":"2000-01-01T00:00:00Z"}\n' "$i" >"$box/to-lane.jsonl"
    if [[ "$i" -eq 1 ]]; then
      printf '0\n' >"$box/to-lane.cursor"
    else
      printf '1\n' >"$box/to-lane.cursor"
      printf 'lane-mail\tKEN-%s\t1 n%s\n' "$i" "$i" >>"$STATE_DIR/owner_repo__none.mail"
    fi
  done
  jq -n --argjson lanes "$lanes" --arg host "$REPO_ROOT/skills/orch/tests/fixtures/lane-host" \
    '{lanes:[range(1;$lanes+1) | {item:("KEN-"+tostring),window:("KEN-"+tostring),
      status:"running",harness:"claude",host:$host,mail_root:("/srv/lane/KEN-"+tostring)}]}' >"$STUB_DIR/fleet.json"
  counter="$STUB_DIR/count"
  python3 "$REPO_ROOT/skills/orch/tests/lib/process-count.py" install "$counter" "$TMP_ROOT/bin:$PATH" "$BASH" '' complete \
    "$TMP_ROOT/bin" "$REPO_ROOT/skills/orch/tests/fixtures"
  printf 'case "$0" in */oversee-watch) printf "%%s\\n" "$$" >"%s/existing" ;; esac\n' "$counter" >>"$counter/bash-env"
  WATCH_BIN="$watch" run_watch OVERSEE_WATCH_LANE_MAIL="$reader" BASH_ENV="$counter/bash-env" \
    PATH="$counter/bin:$TMP_ROOT/bin:$PATH" LANE_HOST_STUB_DIR="$STUB_DIR/remote" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LINEAR_TEAM= ORCH_SECURITY_ALERTS=off ORCH_EXTERNAL_TRIAGE=off -- \
    --max-loops 1 --state "$STUB_DIR/fleet.json" >"$STUB_DIR/out" 2>"$STUB_DIR/err" || rc=$?
  assert_eq "$rc" 0 "$name completes both hosted passes" "$STUB_DIR/err"
  assert_eq "$(grep -c '^EVENT lane-notice ' "$STUB_DIR/out" || :)" 1 "$name reports its fresh hosted notice"
  assert_eq "$(grep -c '^EVENT directive-unread ' "$STUB_DIR/out" || :)" 1 "$name reports its unread hosted directive"
  assert_contains "$(<"$STATE_DIR/owner_repo__none.mail")" "$(printf 'clone-root\tKEN-%s\t/srv/clone/KEN-%s' "$lanes" "$lanes")" \
    "$name retains the clone returned through the variable path"
  python3 "$REPO_ROOT/skills/orch/tests/lib/process-count.py" complete-steps "$counter" >"$STUB_DIR/counts"
  cat "$STUB_DIR/counts"
  awk '/: lane_gitfile_common_dir / { common++ } /: lane_gitfile_git_dir / { gitdir++ }
    END { printf "clone parsing evidence: common=%d gitdir=%d\n", common, gitdir }' "$counter/trace"
  HOSTED_OUTPUT="$STUB_DIR/out"
  HOSTED_MAIL="$(sed -n 's/^mail_turn=//p' "$STUB_DIR/counts")"
  HOSTED_LONG="$(sed -n 's/^long_pass=//p' "$STUB_DIR/counts")"
  printf 'hosted evidence: name=%s lanes=%s mail=%s long=%s\n' "$name" "$lanes" "$HOSTED_MAIL" "$HOSTED_LONG"
}

hosted_cases() { # [BASE_WATCH BASE_READER]
  local lanes previous=0 candidate_mail candidate_long candidate_output
  local reader_control output_rc
  reader_control="$(mutant_scripts hosted-reader-control/orch lane-mail)/lane-mail"
  mutate_file "$reader_control" '  CACHED_READ=1' '  CACHED_READ=0'
  for lanes in 15 16; do
    hosted_cost "hosted-$lanes" "$lanes" "$REPO_ROOT/skills/orch/scripts/oversee-watch" "$REPO_ROOT/skills/mailbox/scripts/lane-mail"
    candidate_mail="$HOSTED_MAIL"; candidate_long="$HOSTED_LONG"; candidate_output="$HOSTED_OUTPUT"
    assert_le "$candidate_mail" 100 "$lanes hosted lanes meet the complete mail-pass bound"
    assert_le "$candidate_long" 1020 "$lanes hosted lanes meet the complete long-pass bound"
    [[ "$previous" -eq 0 ]] || assert_le "$((candidate_mail - previous))" 12 'one added hosted lane adds at most twelve mail processes'
    previous="$candidate_mail"
    if [[ "$lanes" -eq 16 ]]; then
      hosted_cost hosted-control "$lanes" "$REPO_ROOT/skills/orch/scripts/oversee-watch" "$reader_control"
      assert_eq "$((HOSTED_MAIL > 100))" 1 'control: per-lane snapshot copies exceed the mail bound'
      output_rc=0; cmp -s "$candidate_output" "$HOSTED_OUTPUT" || output_rc=$?
      [[ "$output_rc" -eq 0 ]] || diff -u "$candidate_output" "$HOSTED_OUTPUT" || :
      assert_eq "$output_rc" 0 'control keeps every event byte-identical'
      if [[ -n "${1:-}" ]]; then
        hosted_cost hosted-main "$lanes" "$1" "${2:?base watch requires base reader}"
        assert_eq "$((HOSTED_MAIL > 100 || HOSTED_LONG > 1020))" 1 'control: main exceeds a required complete-pass bound'
        output_rc=0; cmp -s "$candidate_output" "$HOSTED_OUTPUT" || output_rc=$?
        [[ "$output_rc" -eq 0 ]] || diff -u "$candidate_output" "$HOSTED_OUTPUT" || :
        assert_eq "$output_rc" 0 'main and candidate print byte-identical events'
      fi
    fi
  done
  source "$REPO_ROOT/skills/orch/scripts/lib/lane-gitfile.sh"
  lane_gitfile_git_dir 'gitdir: /srv/clone/.git/worktrees/lane' >"$STUB_DIR/git-dir"
  assert_eq "$(<"$STUB_DIR/git-dir")" /srv/clone/.git/worktrees/lane 'git-dir stdout keeps its existing contract'
  assert_eq "$LANE_GITFILE_DIR" /srv/clone/.git/worktrees/lane 'git-dir variable matches its output'
  lane_gitfile_common_dir 'gitdir: /srv/clone/.git/worktrees/lane' >"$STUB_DIR/common-dir"
  assert_eq "$(<"$STUB_DIR/common-dir")" /srv/clone/.git 'common-dir stdout keeps its existing contract'
  assert_eq "$LANE_GITFILE_COMMON" /srv/clone/.git 'common-dir variable matches its output'
}

if [[ "${1:-}" == --hosted ]]; then
  shift
  hosted_cases "$@"
  printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
  exit
fi

# A recent long pass isolates mail. Each recorded local root still goes through
# local_clone. The empty overseer mailbox has the same files in every row.
mail_cost() { # NAME LANES WATCH READER
  local name="$1" lanes="$2" watch="$3" reader="$4" i box counter args=() rc=0
  new_case "$name"
  mkdir -p "$STATE_DIR"
  printf 'long-pass\tfleet\t%s\n' "$(date -u +%s)" >"$STATE_DIR/owner_repo__none.mail"
  box="$CASE_REPO_ROOT/tmp/lane-mail/overseer"
  mkdir -p "$box"
  : >"$box/to-lane.jsonl"; : >"$box/to-lane.cursor.lock"
  printf '0\n' >"$box/to-lane.cursor"
  for ((i=1; i<=lanes; i++)); do
    box="$CASE_REPO_ROOT/tmp/lane-mail/KEN-$i"
    mkdir -p "$box"
    printf '{"id":"n%s","kind":"notice","text":"Unread"}\n' "$i" >"$box/to-overseer.jsonl"
    printf '{"id":"d%s","kind":"directive","at":"2000-01-01T00:00:00Z"}\n' "$i" >"$box/to-lane.jsonl"
    args+=(--item "KEN-$i" --root "KEN-$i=$CASE_REPO_ROOT")
  done
  counter="$STUB_DIR/count"
  process_count_install "$counter"
  process_count_watch "$counter" mail
  WATCH_BIN="$watch" run_watch OVERSEE_WATCH_LANE_MAIL="$reader" TMUX= \
    BASH_ENV="$counter/bash-env" PATH="$counter/bin:$TMP_ROOT/bin:$PATH" -- \
    --interval 240 --max-loops 1 "${args[@]}" >"$STUB_DIR/out" 2>"$STUB_DIR/err" || rc=$?
  assert_eq "$rc" 0 "$name completes its mail pass" "$STUB_DIR/err"
  assert_eq "$(grep -c '^EVENT lane-notice ' "$STUB_DIR/out" || :)" "$lanes" "$name reports every unread notice"
  assert_eq "$(grep -c '^EVENT directive-unread ' "$STUB_DIR/out" || :)" "$lanes" "$name reports every unread directive"
  MAIL_COST="$(process_count_total "$counter")"
  printf 'mail evidence: name=%s lanes=%s processes=%s\n' "$name" "$lanes" "$MAIL_COST"
}

WATCH="$REPO_ROOT/skills/orch/scripts/oversee-watch"
READER="$REPO_ROOT/skills/mailbox/scripts/lane-mail"
previous=0; previous_lanes=0
for lanes in 2 4 8; do
  mail_cost "mail-$lanes" "$lanes" "$WATCH" "$READER"
  if [[ "$previous_lanes" -gt 0 ]]; then
    assert_le "$((MAIL_COST - previous))" "$(((lanes - previous_lanes) * 12))" \
      "$lanes lanes add at most twelve processes each"
  fi
  previous="$MAIL_COST"; previous_lanes="$lanes"
done

# An implementation run can supply the full pre-edit watch and reader.
# These are captured before editing, rather than duplicated in the package.
if [[ -n "${1:-}" ]]; then
  BASE_WATCH="$1"; BASE_READER="${2:?a base watch requires its base reader}"
  previous=0; previous_lanes=0
  for lanes in 2 4 8; do
    mail_cost "base-$lanes" "$lanes" "$BASE_WATCH" "$BASE_READER"
    if [[ "$previous_lanes" -gt 0 ]]; then
      added=$((MAIL_COST - previous))
      printf 'base mail evidence: added-lanes=%s added-processes=%s\n' "$((lanes - previous_lanes))" "$added"
      control_rc=0
      (FAIL=0; assert_le "$added" "$(((lanes - previous_lanes) * 12))" 'the full base satisfies the lane ceiling'; [[ "$FAIL" -eq 0 ]]) \
        >"$STUB_DIR/control.out" || control_rc=$?
      assert_eq "$control_rc" 1 'control: the lane ceiling rejects the full base watch and reader'
    fi
    previous="$MAIL_COST"; previous_lanes="$lanes"
  done
fi

# Restore the former capture and nested descriptor-lock scopes. The same
# output assertions must pass while the cost assertion must fail.
CONTROL_DIR="$(mutant_scripts mail-cost-control/orch oversee-watch)"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/mail-cost-control/github"
mutate_file "$CONTROL_DIR/oversee-watch" \
  '  if [[ "$host_read" -eq 0 ]]; then
    "$LANE_MAIL" "$@" >"$WORK_DIR/mail.out" 2>"$WORK_DIR/mail.err" || rc=$?' \
  '  if [[ "$host_read" -eq 0 ]]; then
    MAIL_OUT="$("$LANE_MAIL" "$@" 2>"$WORK_DIR/mail.err")" || rc=$?; printf "%s" "$MAIL_OUT" >"$WORK_DIR/mail.out"'
READER_DIR="$(mutant_scripts mail-reader-control/orch lane-mail)"
mutate_file "$READER_DIR/lane-mail" 'READ_OUT="$(lm_read_pair "$READ_OVER_LOCK" "$TO_LANE"' \
  'READ_OUT="$(lm_existing_lock 8 "$READ_OVER_LOCK" lm_existing_lock 9 "$TO_LANE"'
mail_cost control-2 2 "$CONTROL_DIR/oversee-watch" "$READER_DIR/lane-mail"
previous="$MAIL_COST"
mail_cost control-4 4 "$CONTROL_DIR/oversee-watch" "$READER_DIR/lane-mail"
control_rc=0
(FAIL=0; assert_le "$((MAIL_COST - previous))" 24 'restored shell scopes satisfy the lane ceiling'; [[ "$FAIL" -eq 0 ]]) \
  >"$STUB_DIR/control.out" || control_rc=$?
assert_eq "$control_rc" 1 'control: the lane ceiling rejects the former shell scopes'

idle_cost() { # NAME WATCH
  local name="$1" watch="$2" box counter rc=0
  new_case "$name"
  mkdir -p "$STATE_DIR"
  printf 'long-pass\tfleet\t%s\n' "$(date -u +%s)" >"$STATE_DIR/owner_repo__none.mail"
  box="$CASE_REPO_ROOT/tmp/lane-mail/overseer"
  mkdir -p "$box"
  : >"$box/to-lane.jsonl"; : >"$box/to-lane.cursor.lock"
  printf '0\n' >"$box/to-lane.cursor"
  mkdir -p "$STUB_DIR/idle-bin"
  cat >"$STUB_DIR/idle-bin/sleep" <<'EOF'
#!/bin/sh
ticks=0
if [ -f "$STUB_DIR/ticks" ]; then read -r ticks <"$STUB_DIR/ticks"; fi
ticks=$((ticks + 1)); printf '%s\n' "$ticks" >"$STUB_DIR/ticks"
if [ "$ticks" -eq 10 ]; then
  printf '{"id":"wake","kind":"directive","text":"Wake"}\n' >"$IDLE_BOX"
fi
EOF
  chmod +x "$STUB_DIR/idle-bin/sleep"
  PATH="$STUB_DIR/idle-bin:$PATH" process_count_install "$STUB_DIR/count"
  counter="$STUB_DIR/count"
  process_count_watch "$counter" idle
  WATCH_BIN="$watch" run_watch TMUX= BASH_ENV="$counter/bash-env" IDLE_BOX="$box/to-lane.jsonl" \
    PATH="$counter/bin:$TMP_ROOT/bin:$PATH" ORCH_WATCH_MAIL_INTERVAL=600 -- \
    --interval 3600 --max-loops 1 >"$STUB_DIR/out" 2>"$STUB_DIR/err" || rc=$?
  assert_eq "$rc" 0 "$name wakes on the notice" "$STUB_DIR/err"
  assert_eq "$(<"$STUB_DIR/ticks")" 10 "$name records ten idle ticks"
  assert_eq "$(grep -c '^EVENT owner-note wake$' "$STUB_DIR/out" || :)" 1 "$name reports its wake notice"
  IDLE_COST="$(process_count_total "$counter")"
  printf 'idle evidence: name=%s ticks=10 processes=%s\n' "$name" "$IDLE_COST"
}
idle_cost idle "$WATCH"
assert_le "$IDLE_COST" 20 'ten idle ticks start at most twenty processes'

# Restore the base watch's per-tick date and size helper calls.
IDLE_DIR="$(mutant_scripts idle-base/orch oversee-watch)"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/idle-base/github"
mutate_file "$IDLE_DIR/oversee-watch" '    now=$((WATCH_EPOCH + SECONDS - WATCH_SECONDS))' \
  '    now="$(date -u +%s)" || die time-failed "" "clock=UTC"'
mutate_file "$IDLE_DIR/oversee-watch" 'size="$(exec wc -c 2>/dev/null < "$OVERSEER_BOX")"' 'size="$(overseer_box_size)"'
idle_cost idle-base "$IDLE_DIR/oversee-watch"
control_rc=0
(FAIL=0; assert_le "$IDLE_COST" 20 'the base idle path satisfies the ceiling'; [[ "$FAIL" -eq 0 ]]) \
  >"$STUB_DIR/control.out" || control_rc=$?
assert_eq "$control_rc" 1 'control: the idle ceiling rejects the base watch'

hosted_cases

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
