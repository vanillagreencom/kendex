#!/usr/bin/env bash
# Surface: lane-mail-check item discovery, through halt and deliver wrappers.
# Inputs: hooks/lane-mail-{check,halt,deliver}.sh, skills/orch/scripts/**,
# lib/lane-mail-world.sh, lib/process-count.sh. No-lane costs include cleanup.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/lane-mail-world.sh"
. "$TEST_DIR/lib/process-count.sh"
process_count_setup "$TMP_ROOT"

if process_count_supported; then
new_lane mailbox_cost main
unmark_lanes
install_arms
CALL_ENV=("PATH=$COUNT_BIN" "BASH_ENV=$COUNT_TRACE" "PROCESS_COUNT_LOG=$COUNT_LOG")
for arm in halt deliver; do
  rm -rf -- "$LANE/tmp/lane-mail"
  first_count=
  previous_size=0
  for size in 1 10 40; do
    i=$previous_size
    while [ "$i" -lt "$size" ]; do
      mkdir -p "$LANE/tmp/lane-mail/KEN-$i"
      i=$((i + 1))
    done
    previous_size=$size
    CASE_HOOK="$LANE/.claude/hooks/lane-mail-$arm.sh"
    process_count_reset
    run_payload '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
    count=$(process_count_total)
    printf 'cost arm=%s mailboxes=%s processes=%s tr=%s\n' "$arm" "$size" "$count" "$(process_count_command tr)"
    assert_eq "$RC" 0 "$arm passes a checkout with no lane"
    if [ -z "$first_count" ]; then first_count=$count; fi
    assert_eq "$count" "$first_count" "$arm process count stays fixed at $size mailboxes"
  done
done
CALL_ENV=()
if [ "${1:-}" = --cost-row ]; then
  [ "$FAIL" -eq 0 ]
  exit
fi
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  wake_mutant directory-forks '      [[ "$name" == "$BRANCH" ]] || continue' \
    '      [ "$(printf "%s" "$name" | tr A-Z a-z)" = "$(printf "%s" "$BRANCH" | tr A-Z a-z)" ] || continue'
  control_rc=0
  env "HOOK_UNDER_TEST=$MUTANT_PATH" "$BASH" "$TEST_DIR/lane-mail-check-cost.test.sh" --cost-row \
    > "$TMP_ROOT/directory-cost.control.log" 2>&1 || control_rc=$?
  assert_eq "$control_rc" 1 'control: external comparisons make the mailbox-cost assertions red'
  growth=$(awk '/^cost arm=halt mailboxes=1 / { start=$4; sub("processes=", "", start) }
    /^cost arm=halt mailboxes=40 / { finish=$4; sub("processes=", "", finish) }
    END { print ((finish-start)/39 >= 2) }' "$TMP_ROOT/directory-cost.control.log")
  assert_eq "$growth" 1 'control: external comparisons add at least two processes for each directory'
fi
else
  printf 'process-count: unavailable=BASHPID\n'
fi

# LANE_MAIL_ITEM has priority. Otherwise only a single case-insensitive
# match can select a launch-bound lane. Delivery acknowledges its unread line.
while IFS='|' read -r name override duplicate expected; do
  new_lane "$name" ken-1
  install_arms
  mkdir -p "$LANE/tmp/lane-mail/KEN-1"
  i=2
  while [ "$i" -le 11 ]; do mkdir -p "$LANE/tmp/lane-mail/KEN-$i"; i=$((i + 1)); done
  item=KEN-1
  if [ -n "$override" ]; then item=$override; mark_lane "$item"; fi
  if [ "$duplicate" = yes ]; then
    if [ "$CASE_SENSITIVE" -eq 0 ]; then continue; fi
    mkdir -p "$LANE/tmp/lane-mail/ken-1"
  fi
  send "$item" 'Discovery note.' >/dev/null
  CASE_HOOK="$LANE/.claude/hooks/lane-mail-deliver.sh"
  run_payload '{}' ${override:+"LANE_MAIL_ITEM=$override"}
  actual="RC=$RC first=$(first_line) context=$(context_line)"
  assert_eq "$actual" "$expected" "$name selects or stalls its mailbox"
  if [ "$RC" -eq 0 ]; then
    run_payload '{}' ${override:+"LANE_MAIL_ITEM=$override"}
    assert_eq "RC=$RC context=$(context_line)" 'RC=0 context=-' "$name acknowledges the delivered line"
  fi
done <<'ROWS'
case_match||no|RC=0 first=- context=PostToolUse lane-mail-check: unread=1
case_ambiguous||yes|RC=2 first=lane-mail-check: item=ambiguous context=-
explicit_item|KEN-9|yes|RC=0 first=- context=PostToolUse lane-mail-check: unread=1
ROWS
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
