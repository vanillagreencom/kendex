#!/usr/bin/env bash
# Quiet report delivery and the owner-sent baseline, at fixed Pacific hours.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-report-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/oversee-report-fixture.sh"

echo "=== quiet hours: owner-local reports and the morning brief ==="
# UTC runners must see the same owner's hours. The last sent report is at
# 11 pm Pacific. Both night merges remain in the 7 am brief, even after a
# 6 am file resets the ordinary two-hour cadence.
SAVED_NOW="$NOW"
NOW="$(jq -rn '"2026-09-26T09:00:00Z" | fromdateiso8601')"
for mode in quiet off morning; do
  new_case "quiet_$mode"
  printf '%s\n' "$NOW" > "$CASE/now"
  report -10800
  fleet '' "$(lane KEN-1 done)" "$(lane KEN-2 done)"
  for n in 1 2; do issue "KEN-$n" "Title $n" "Outcome $n"; done
  echo "[$(merged_pr 11 ken-1 -3600 abcdef1234)]" > "$CASE/merged.json"
  printf 'Work landed overnight.\n%s\n' "$OWNER_ROWS" > "$CASE/summary.txt"
  run ORCH_OWNER_TIME_ZONE=America/Los_Angeles -- due --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC|$OUT" "0|report-due reason=minutes since=$(at -10800)" "02:00 Pacific is still due during quiet hours"
  envs=(ORCH_OWNER_TIME_ZONE=America/Los_Angeles)
  [[ "$mode" != off ]] || envs+=(ORCH_REPORT_QUIET_HOURS=)
  run "${envs[@]}" -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
  FILE="${CASE}/progress-reports/09-26-09-00.md"
  notices=0; [[ ! -f "$CASE/mail.calls" ]] || notices="$(wc -l < "$CASE/mail.calls" | tr -d ' ')"
  want=0; [[ "$mode" != off ]] || want=1
  assert_eq "$RC|$OUT|$notices" "0|$(cat "$FILE")|$want" \
    "02:00 writes and prints its report; empty quiet hours sends the notice as the suppression control"
  if [[ "$mode" == morning ]]; then
    printf '%s\n' "$((NOW + 14400))" > "$CASE/now"
    echo "[$(merged_pr 11 ken-1 -3600 abcdef1234),$(merged_pr 12 ken-2 10800 1212121aaa)]" > "$CASE/merged.json"
    run ORCH_OWNER_TIME_ZONE=America/Los_Angeles -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
    assert_eq "$RC|$([[ -f "$CASE/mail.calls" ]] && echo sent || echo quiet)" "0|quiet" "06:00 still writes without an owner notice"
    printf '%s\n' "$((NOW + 18000))" > "$CASE/now"
    run ORCH_OWNER_TIME_ZONE=America/Los_Angeles -- due --state "$CASE/state.json" --repo owner/repo
    assert_eq "$RC|$OUT" "0|report-due reason=minutes since=$(at -10800)" \
      "07:00 makes the morning brief due even with a 06:00 file"
    run ORCH_OWNER_TIME_ZONE=America/Los_Angeles -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
    assert_eq "$RC|$(wc -l < "$CASE/mail.calls" | tr -d ' ')|$(awk '/^\| KEN-/' <<<"$OUT")" \
      "0|1|| KEN-1 (#11, abcdef1) | Title 1 | Outcome 1 |
| KEN-2 (#12, 1212121) | Title 2 | Outcome 2 |" "07:00 sends one notice and lists both overnight merges"
    printf '%s\n' "$((NOW + 18060))" > "$CASE/now"
    run ORCH_OWNER_TIME_ZONE=America/Los_Angeles -- render --state "$CASE/state.json" --repo owner/repo
    assert_eq "$RC|$(awk '/^Landed/' <<<"$OUT")" "0|Landed: none" "the sent morning brief advances the owner baseline"
  fi
done

# Each changed command surface has a planted defect in a disposable copy.
# due loses its morning catch-up; render counts from the latest quiet file;
# write sends the notice despite the quiet judgement.
for surface in due render write; do
  mutant="$(mutant_scripts "quiet-control-$surface/orch" oversee-report)/oversee-report" || exit 1
  ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/quiet-control-$surface/github"
  case "$surface" in
    due) mutate_file "$mutant" '"$NOTICE_MODE" == send && -n "$OWNER_MARKER"' '"$NOTICE_MODE" == disabled && -n "$OWNER_MARKER"' ;;
    render) mutate_file "$mutant" 'WINDOW_MARKER="$OWNER_MARKER"' 'WINDOW_MARKER="$MARKER"' ;;
    write) mutate_file "$mutant" 'if [[ "$NOTICE_MODE" == quiet ]]; then' 'if [[ "$NOTICE_MODE" == disabled ]]; then' ;;
  esac
  new_case "quiet_mutant_$surface"
  printf '%s\n' "$NOW" > "$CASE/now"
  report -10800
  fleet '' "$(lane KEN-1 done)"
  issue KEN-1 "Title 1" "Outcome 1"
  echo "[$(merged_pr 11 ken-1 -3600 abcdef1234)]" > "$CASE/merged.json"
  printf 'Work landed overnight.\n%s\n' "$OWNER_ROWS" > "$CASE/summary.txt"
  if [[ "$surface" != write ]]; then
    run ORCH_OWNER_TIME_ZONE=America/Los_Angeles -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
    printf '%s\n' "$((NOW + 14400))" > "$CASE/now"
    run ORCH_OWNER_TIME_ZONE=America/Los_Angeles -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
    printf '%s\n' "$((NOW + 18000))" > "$CASE/now"
  fi
  args=(); [[ "$surface" != write ]] || args=(--summary-file "$CASE/summary.txt")
  REPORT_UNDER_TEST="$mutant" run ORCH_OWNER_TIME_ZONE=America/Los_Angeles -- "$surface" --state "$CASE/state.json" --repo owner/repo "${args[@]+"${args[@]}"}"
  case "$surface" in
    due) assert_eq "$RC|$OUT" "0|" "control: without morning catch-up due misses the 07:00 brief" ;;
    render) assert_eq "$RC|$(awk '/^Landed/' <<<"$OUT")" "0|Landed: none" "control: counting from the quiet file loses the night merge" ;;
    write) assert_eq "$RC|$(wc -l < "$CASE/mail.calls" | tr -d ' ')" "0|1" "control: without suppression write sends a 02:00 notice" ;;
  esac
done

# Project owners can set a quiet window that crosses midnight. Excluding
# its start in a disposable copy must send the otherwise suppressed notice.
NOW="$(jq -rn '"2026-09-26T06:00:00Z" | fromdateiso8601')" || exit 1
mutant="$(mutant_scripts "quiet-wrapping-control/orch" oversee-report)/oversee-report" || exit 1
github_dir="$(cd "$TEST_DIR/../../github" && pwd)" || exit 1
ln -s "$github_dir" "$TMP_ROOT/quiet-wrapping-control/github"
mutate_file "$mutant" '[[ "$hour" -ge "$QUIET_START" || "$hour" -lt "$QUIET_END" ]]' \
  '[[ "$hour" -gt "$QUIET_START" || "$hour" -lt "$QUIET_END" ]]'
envs=(TZ=UTC ORCH_OWNER_TIME_ZONE=America/Los_Angeles ORCH_REPORT_QUIET_HOURS=23-7)
for version in live control; do
  new_case "quiet_wrapping_$version"
  printf '%s\n' "$NOW" > "$CASE/now"
  report -10800
  since="$(at -10800)" || exit 1
  fleet ''
  printf 'Work continues overnight.\n%s\n' "$OWNER_ROWS" > "$CASE/summary.txt"
  target="$REPORT_BIN"; want=0
  if [[ "$version" == control ]]; then target="$mutant"; want=1; fi
  REPORT_UNDER_TEST="$target" run "${envs[@]}" -- due --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC|$OUT" "0|report-due reason=minutes since=$since" "23:00 Pacific is due with a 23-7 window ($version)"
  REPORT_UNDER_TEST="$target" run "${envs[@]}" -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
  written="$(cat "$CASE/progress-reports/09-26-06-00.md")" || exit 1
  notices=0; [[ ! -f "$CASE/mail.calls" ]] || notices="$(wc -l < "$CASE/mail.calls" | tr -d ' ')" || exit 1
  assert_eq "$RC|$OUT|$notices" "0|$written|$want" \
    "23:00 writes and prints; start-inclusive suppression sends no notice, its control sends one ($version)"
  [[ "$version" == live ]] || continue
  printf '%s\n' "$((NOW + 28800))" > "$CASE/now"
  run "${envs[@]}" -- due --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC|$OUT" "0|report-due reason=minutes since=$since" "07:00 Pacific is due at the exclusive end of a 23-7 window"
  run "${envs[@]}" -- write --state "$CASE/state.json" --repo owner/repo --summary-file "$CASE/summary.txt"
  written="$(cat "$CASE/progress-reports/09-26-14-00.md")" || exit 1
  notices="$(wc -l < "$CASE/mail.calls" | tr -d ' ')" || exit 1
  assert_eq "$RC|$OUT|$notices" "0|$written|1" "07:00 writes and prints its report and sends one notice after the wrapping window"
done
NOW="$SAVED_NOW"

new_case report_history_unread
printf '%s\n' "$NOW" > "$CASE/now"
fleet '' "$(lane KEN-1 done)"
touch "$CASE/events-fail"
run -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: owner-reports=overseer" "an unread mailbox refuses rather than lose the owner baseline"

echo "=== quiet settings: refusals and must-fail controls ==="
# These are settings a project author can supply, not upstream data.
while IFS='~' read -r name setting old new; do
  new_case "quiet_setting_$name"
  printf '%s\n' "$NOW" > "$CASE/now"
  fleet ''
  run "$setting" -- render --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC|$(first_err)" "2|oversee-report: setting=${setting/=/:}" "$setting refuses before a report is rendered"
  mutant="$(mutant_scripts "quiet-setting-$name/orch" oversee-report)/oversee-report" || exit 1
  ln -s "$(cd "$TEST_DIR/../../github" && pwd)" "$TMP_ROOT/quiet-setting-$name/github"
  mutate_file "$mutant" "$old" "$new"
  REPORT_UNDER_TEST="$mutant" run "$setting" -- render --state "$CASE/state.json" --repo owner/repo
  assert_eq "$RC" "0" "control: without the $name check the invalid setting renders"
done <<'ROWS'
hours~ORCH_REPORT_QUIET_HOURS=25-7~^([0-9]|1[0-9]|2[0-3])-([0-9]|1[0-9]|2[0-3])$~^([0-9]+)-([0-9]+)$
equal~ORCH_REPORT_QUIET_HOURS=7-7~[[ "$QUIET_START" -ne "$QUIET_END" ]]~[[ "$QUIET_START" -ge 0 ]]
zone~ORCH_OWNER_TIME_ZONE=Mars/Olympus~[[ -n "$OWNER_ZONE" && -f "${TZDIR:-/usr/share/zoneinfo}/$OWNER_ZONE" && -r "${TZDIR:-/usr/share/zoneinfo}/$OWNER_ZONE" ]]~[[ -n "$OWNER_ZONE" ]]
ROWS
new_case quiet_setting_directory
printf '%s\n' "$NOW" > "$CASE/now"
fleet ''
run ORCH_OWNER_TIME_ZONE=America -- render --state "$CASE/state.json" --repo owner/repo
assert_eq "$RC|$(first_err)" "2|oversee-report: setting=ORCH_OWNER_TIME_ZONE:America" "a zoneinfo directory is not a time zone"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
