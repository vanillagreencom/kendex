#!/usr/bin/env bash
# Tests for the hosted pi launch contract.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# Physical: on macOS the temp root sits under /var -> /private/var, and the
# scripts print the resolved path.
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-lane-hosted: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-lane-hosted: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-lane-hosted: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# shellcheck source=lib/open-terminal-hosted-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/open-terminal-hosted-world.sh"


HOSTED_LINE='Resume the orch workflow for KEN-48 from where this session stopped. Run .agents/skills/mailbox/scripts/lane-mail inbox --item KEN-48 first and act on every envelope it prints, answers and directives alike, as its text directs.'
PI_RELAUNCH="$HARNESS_UP;ORCH_LANE_ALIASES=eclaude=work;ORCH_LANE_COPILOT_POOL=$H/.eclaude=1/10;flags=--model github-copilot/opus --thinking high"
run_ot "$PI_RELAUNCH" --host "$HOST_STUB" --harness pi --lane "$H/.eclaude" --repo o/r --relaunch KEN-48
PI_REMOTE="$(ot_hosted_relaunch_text "$RUN/tmux.log")" || exit 1
PI_RESUME="0) exec pi '--exclude-tools' 'question' '--model' 'github-copilot/opus' '--thinking' 'high' --session \"\$session\" '$HOSTED_LINE $UNATTENDED_TEXT' ;; 1) exec pi"
assert_eq "$(observe "rc=0 creates=nolog launched=1 claim_lanes=eclaude") lookup=$(grep -cF 'session=$(bash .agents/skills/orch/scripts/lib/lane-relaunch.sh pi KEN-48 ' <<<"$PI_REMOTE" || true) resume=$(grep -cF "$PI_RESUME" <<<"$PI_REMOTE" || true) fresh=$(grep -cF "'/skill:orch start KEN-48 $UNATTENDED_TEXT'" <<<"$PI_REMOTE" || true)" \
  "rc=0 creates=nolog launched=1 claim_lanes=eclaude lookup=1 resume=1 fresh=1" \
  "a hosted pi relaunch selects its host session or the start brief, keeping its lane and continuation line"
PI_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-pi-native/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-pi-native/orch"
mutate_file "$OPEN_TERMINAL" '      codex | pi)' '      pi) printf '\''pi %s-c%s\n'\'' "$flags" "$line"; return ;;'$'\n''      pi | codex)'
run_ot "$PI_RELAUNCH" --host "$HOST_STUB" --harness pi --lane "$H/.eclaude" --repo o/r --relaunch KEN-48
PI_REMOTE="$(ot_hosted_relaunch_text "$RUN/tmux.log")" || exit 1
assert_eq "rc=$RC selection=$(grep -cF "$PI_RESUME" <<<"$PI_REMOTE" || true) native=$(grep -cF " -c '$HOSTED_LINE $UNATTENDED_TEXT'" <<<"$PI_REMOTE" || true)" \
  "rc=0 selection=0 native=1" "control: the old pi -c form fails the resume-or-fresh assertion"
OPEN_TERMINAL="$PI_OT_SHIPPED"
# A hosted Pi launch on a pi-claude model is refused before any pick, judge or
# host call, auto and named alike: the host protocol hands a Pi lane its
# account as its Pi root and carries no Claude seat. The control drops the
# refusal, and the auto launch goes on to the provider.
for pi_seat_lane in auto "$H/.eclaude"; do
  run_ot "ORCH_LANE_ALIASES=eclaude=work;flags=--model pi-claude/opus --thinking high" --host "$HOST_STUB" --harness pi --lane "$pi_seat_lane" --repo o/r KEN-1690
  assert_eq "$(observe "rc=1 launched=nolog hostseat=host=$HOST_STUB,model=pi-claude/opus") calls=$(host_call)" \
    "rc=1 launched=nolog hostseat=host=$HOST_STUB,model=pi-claude/opus calls=nolog" \
    "a hosted Pi launch on a pi-claude model under --lane $pi_seat_lane is refused before any host call"
done
PI_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-pi-seat/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-pi-seat/orch"
mutate_file "$OPEN_TERMINAL" '"$(lane_pick_harness pi "$LAUNCH_MODEL")" == claude ]]; then' '"$(lane_pick_harness pi "$LAUNCH_MODEL")" == claude-dropped ]]; then'
run_ot "ORCH_LANE_ALIASES=eclaude=work;flags=--model pi-claude/opus --thinking high" --host "$HOST_STUB" --harness pi --lane auto --repo o/r KEN-1690
assert_eq "$(observe "hostseat=none") called=$([[ "$(host_call)" == nolog ]] && echo no || echo yes)" "hostseat=none called=yes" \
  "control: without the refusal a hosted Pi launch on a pi-claude model goes on to the provider"
OPEN_TERMINAL="$PI_OT_SHIPPED"
echo "=== a hosted Anthropic Pi launch spends the selected account grant ==="
API_ROWS="$TMP_ROOT/hosted-api-credit.tsv"
api_hosted_rows() { # REMAINING [STATUS [DETAIL]]
  if [[ "${2:-ok}" == unreachable ]]; then
    printf 'account=%s\tharness=pi\tstatus=unreachable\tdetail=%s\n' "$H/.eclaude" "$3" > "$API_ROWS"
  else
    printf 'account=%s\tharness=pi\tstatus=%s\tcredit-limit=200.00\tcredit-spent=0.00\tcredit-remaining=%s\tcredit-expires=2099-10-06T00:00:00Z\n' \
      "$H/.eclaude" "${2:-ok}" "$1" > "$API_ROWS"
  fi
}
API_FLAGS='flags=--model anthropic/claude-opus-5-5 --thinking high'
API_ENV="$HARNESS_UP;LANE_HOST_STUB_ACCOUNTS=$API_ROWS;ORCH_LANE_CLOUD_CREDIT_FLOOR=5;$API_FLAGS"
api_launch_result() { # no host create is accepted on a refused credit
  printf 'rc=%s creates=%s launched=%s cause=%s' "$RC" \
    "$(grep -c '^create ' "$RUN/host.log" 2>/dev/null || true)" "$(typed "clear; ssh 'lane.example'")" \
    "$(awk '$2 == "lane-credit-refused" {for(i=3;i<=NF;i++) if($i ~ /^cause=/ || $i ~ /^retry-at=/) printf "%s,", $i}' <<<"$OUT")"
}
api_launch_room() {
  run_ot "$API_ENV" --host "$HOST_STUB" --harness pi --lane auto --repo o/r KEN-3747
  assert_eq "rc=$RC account=$(awk '/^create / { for(i=1;i<=NF;i++) if($i == "--account") print $(i+1) }' "$RUN/host.log") launched=$(typed "clear; ssh 'lane.example'") pool=$(awk -F'\t' '{print $9}' "$RUN"/state/claims/*.claim 2>/dev/null)" \
    "rc=0 account=$H/.eclaude launched=1 pool=api-credit" 'the API-credit pick passes its Claude home and spending pool to create and the claim'
}
api_hosted_rows 150
api_launch_room

# The preference walk spends the hosted API grant before the local Claude
# account. A restricted source posture must reach the fallback before flags
# are built, since the shared builder refuses that cross-harness transfer.
API_PREFERENCE="pi@$HOST_STUB:anthropic/claude-opus-5-5:high,claude:fable:high"
printf '/orch start KEN-3801\nWorking (esc to interrupt)\nuser@lane:~$\n' > "$TMP_ROOT/api-preference-screen"
API_PREFERENCE_ENV="$HARNESS_UP;OT_SCREEN_FILE=$TMP_ROOT/api-preference-screen;OT_SCREEN_ON=0;LANE_HOST_STUB_ACCOUNTS=$API_ROWS;ORCH_LANE_DIRS=$H/.eclaude;ORCH_LANE_CLOUD_CREDIT_FLOOR=5;ORCH_LANE_PREFERENCE=$API_PREFERENCE;LANE_HOST_STUB_CREATE_LINE=ssh-target=lane.example"$'\t'"path=/srv/lane"$'\t'"remote-prefix=env PI_CODING_AGENT_DIR=/pi bash -lc"$'\t'"pi-root=/pi"
api_preference_case() { # REMAINING FLAGS EXPECTED [PREFERENCE]
  api_hosted_rows "$1"
  run_ot "$API_PREFERENCE_ENV${2:+;flags=$2}${4:+;ORCH_LANE_PREFERENCE=$4}" --host local --harness claude --lane auto --repo o/r KEN-3801
  printf '%s\n' "$OUT" > "$RUN/preference.out"
  assert_eq "$(observe 'rc=0 cmd_lane=none claim_lanes=eclaude') hosted=$(typed 'env PI_CODING_AGENT_DIR=/pi bash -lc') pool=$(awk -F'\t' '{print $9}' "$RUN"/state/claims/*.claim 2>/dev/null) prompt=$(awk '$2 == "permission-prompt" {n++} END {print n+0}' <<<"$OUT")" \
    "$3" 'the preference launches the eligible account with its spending pool' "$RUN/preference.out"
}
printf '%s\n' \
  '150|--dangerously-skip-permissions|rc=0 cmd_lane=none claim_lanes=eclaude hosted=1 pool=api-credit prompt=0' \
  '4|--dangerously-skip-permissions|rc=0 cmd_lane=eclaude claim_lanes=eclaude hosted=0 pool=plan prompt=0' \
  '150|--permission-mode dontAsk|rc=0 cmd_lane=eclaude claim_lanes=eclaude hosted=0 pool=plan prompt=0' \
  '150||rc=0 cmd_lane=eclaude claim_lanes=eclaude hosted=0 pool=plan prompt=1' \
  '150|--dangerously-skip-permissions --permission-mode dontAsk|rc=0 cmd_lane=eclaude claim_lanes=eclaude hosted=0 pool=plan prompt=0' \
  '150|--dangerously-skip-permissions|rc=0 cmd_lane=eclaude claim_lanes=eclaude hosted=0 pool=plan prompt=0|pi:1:high,claude:fable:high' \
  > "$TMP_ROOT/api-preference-rows"
while IFS='|' read -r credit flags expected preference; do
  api_preference_case "$credit" "$flags" "$expected" "$preference"
done < "$TMP_ROOT/api-preference-rows"
API_PREFERENCE_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-api-preference/orch lib/lane-launch.sh)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-api-preference/orch"
mutate_file "${OPEN_TERMINAL%/*}/lib/lane-launch.sh" \
  'pi|--model|--thinking|:|-|no-word|-|-|--exclude-tools question|-' \
  'pi|--model|--thinking|:|-|-|-|-|--exclude-tools question|-'
API_PREFERENCE_SAVED_FAIL="$FAIL"; FAIL=0
api_preference_case 150 --dangerously-skip-permissions 'rc=0 cmd_lane=none claim_lanes=eclaude hosted=1 pool=api-credit prompt=0' > "$TMP_ROOT/api-preference-control.out"
API_PREFERENCE_CONTROL="$FAIL"; FAIL="$API_PREFERENCE_SAVED_FAIL"
assert_eq "$API_PREFERENCE_CONTROL" 1 'control: the former Pi posture fails the hosted launch assertion'
assert_eq "$(awk '$2 == "entry-permission-untransferable" {for(i=3;i<=NF;i++) if($i ~ /^(entry|source|target)=/) printf "%s,", $i}' <<<"$OUT")" \
  "entry=pi@$HOST_STUB:anthropic/claude-opus-5-5:high,source=claude,target=pi," 'control: the former posture records the typed permission skip'
OPEN_TERMINAL="$API_PREFERENCE_SHIPPED"
OPEN_TERMINAL="$(mutant_scripts ctl-api-preference-prompt/orch lib/lane-launch.sh)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-api-preference-prompt/orch"
mutate_file "${OPEN_TERMINAL%/*}/lib/lane-launch.sh" \
  '  [[ "$spellings" != - && "$spellings" != no-word ]] || return 0' \
  '  [[ "$spellings" != - ]] || return 0'
API_PREFERENCE_SAVED_FAIL="$FAIL"; FAIL=0
api_preference_case 150 --dangerously-skip-permissions 'rc=0 cmd_lane=none claim_lanes=eclaude hosted=1 pool=api-credit prompt=0' > "$TMP_ROOT/api-preference-prompt-control.out"
API_PREFERENCE_CONTROL="$FAIL"; FAIL="$API_PREFERENCE_SAVED_FAIL"
assert_eq "$API_PREFERENCE_CONTROL" 1 'control: treating no-word as a flag fails the prompt absence assertion'
OPEN_TERMINAL="$API_PREFERENCE_SHIPPED"
OPEN_TERMINAL="$(mutant_scripts ctl-api-preference-source/orch lib/overseer-launch.sh)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-api-preference-source/orch"
mutate_file "${OPEN_TERMINAL%/*}/lib/overseer-launch.sh" \
  '    && launch_choice_permission_transferable "$OL_WALK_SOURCE_HARNESS" "$OL_WALK_SOURCE_FLAGS"; then' \
  '    && true; then'
API_PREFERENCE_SAVED_FAIL="$FAIL"; FAIL=0
api_preference_case 150 '--permission-mode dontAsk' 'rc=0 cmd_lane=eclaude claim_lanes=eclaude hosted=0 pool=plan prompt=0' > "$TMP_ROOT/api-preference-source-control.out"
API_PREFERENCE_CONTROL="$FAIL"; FAIL="$API_PREFERENCE_SAVED_FAIL"
assert_eq "$API_PREFERENCE_CONTROL" 1 'control: admitting a restricted source fails the fallback launch assertion'
OPEN_TERMINAL="$API_PREFERENCE_SHIPPED"
for lane in auto "$H/.eclaude"; do
  api_hosted_rows 5
  run_ot "$API_ENV" --host "$HOST_STUB" --harness pi --lane "$lane" --repo o/r KEN-3747
  assert_eq "$(api_launch_result)" 'rc=1 creates=0 launched= cause=cause=api-credit,retry-at=none,' 'credit at the floor creates no hosted lane'
done
api_pick_refusal_case() { # CREDIT EXCLUDE EXPECTED
  api_hosted_rows "$1"
  run_ot "$API_ENV;ORCH_LANE_EXCLUDE=$2" --host "$HOST_STUB" --harness pi --lane auto --repo o/r KEN-3844
  assert_eq "$(api_launch_result) $(observe 'pickrefusal=none')" "$3" \
    'an automatic API pick reports the cause from its grant refusals'
}
API_EXCLUDED_EXPECT='rc=1 creates=0 launched= cause= pickrefusal=lane-unavailable,harness=pi'
while IFS='|' read -r credit exclude expected; do
  api_pick_refusal_case "$credit" "$exclude" "$expected"
done <<ROWS
150|eclaude|$API_EXCLUDED_EXPECT
4||rc=1 creates=0 launched= cause=cause=api-credit,retry-at=none, pickrefusal=none
ROWS
API_NO_CANDIDATE_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-api-no-candidate/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-api-no-candidate/orch"
mutate_file "$OPEN_TERMINAL" 'if [[ "$grant_refused" == false ]]; then' 'if false && [[ "$grant_refused" == false ]]; then'
API_SAVED_FAIL="$FAIL"; FAIL=0
api_pick_refusal_case 150 eclaude "$API_EXCLUDED_EXPECT" > "$TMP_ROOT/api-no-candidate-control.out"
API_CONTROL="$FAIL"; FAIL="$API_SAVED_FAIL"
assert_eq "$API_CONTROL" 1 'control: the prior API mapping fails the excluded-account row'
assert_eq "$(api_launch_result)" 'rc=1 creates=0 launched= cause=cause=api-credit,retry-at=none,' \
  'control: the prior API mapping reports a credit refusal without a refused grant'
awk '$1 == "open-terminal:" && $2 == "lane-credit-refused"' <<<"$OUT"
OPEN_TERMINAL="$API_NO_CANDIDATE_SHIPPED"
api_hosted_rows 150 expired
run_ot "$API_ENV" --host "$HOST_STUB" --harness pi --lane auto --repo o/r KEN-3747
assert_eq "$(api_launch_result)" 'rc=1 creates=0 launched= cause=cause=api-credit,retry-at=none,' 'a provider-expired grant creates no lane'
for detail in api-credit-tokens-unreadable api-credit-tokens-undated api-credit-model-unpriced api-credit-reading-unavailable; do
  api_hosted_rows '' unreachable "$detail"
  run_ot "$API_ENV" --host "$HOST_STUB" --harness pi --lane "$H/.eclaude" --repo o/r KEN-3747
  assert_eq "rc=$RC calls=$(host_call) detail=$(awk '$2 == "lane-provider-unmeasured" {for(i=3;i<=NF;i++) if($i ~ /^detail=/) print $i}' <<<"$OUT")" \
    "rc=1 calls=accounts detail=detail=$detail" 'an unread provider API row names its detail and creates nothing'
done
api_hosted_rows 150
for lane in auto "$H/.eclaude"; do
  for failure in busy timeout; do
    failure_env=LANE_HOST_STUB_ACCOUNTS_STATUS=69
    [[ "$failure" != timeout ]] || failure_env='LANE_HOST_STUB_ACCOUNTS_DELAY=2;ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S=1;OT_SLEEP_INSTANT='
    run_ot "$API_ENV;$failure_env" --host "$HOST_STUB" --harness pi --lane "$lane" --repo o/r KEN-3747
    failure_key=lane-resolution-failed
    [[ "$lane" == auto ]] || failure_key=lane-judge-failed
    assert_eq "rc=$RC creates=$(grep -c '^create ' "$RUN/host.log" || true) failed=$(awk -v key="$failure_key" '$2 == key {n++} END {print n+0}' <<<"$OUT") repair=$(awk '$2 == "lane-provider-unmeasured" {n++} END {print n+0}' <<<"$OUT")" \
      'rc=1 creates=0 failed=1 repair=0' 'failed API accounts returns a command failure and opens no lane'
  done
done
api_hosted_rows 150
API_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-api-unmeasured/orch lib/lane-launch.sh)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-api-unmeasured/orch"
mutate_file "${OPEN_TERMINAL%/*}/lib/lane-launch.sh" 'github-copilot/* | anthropic/*)' 'github-copilot/*)'
API_SAVED_FAIL="$FAIL"; FAIL=0
api_launch_room > "$TMP_ROOT/api-unmeasured-control.out"
API_CONTROL="$FAIL"; FAIL="$API_SAVED_FAIL"; OPEN_TERMINAL="$API_OT_SHIPPED"
assert_eq "$API_CONTROL" 1 'control: the prior unmeasured Anthropic mapping fails the unchanged hosted launch row'
OPEN_TERMINAL="$(mutant_scripts ctl-api-claim-pool/orch lib/lane-claims.sh)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-api-claim-pool/orch"
mutate_file "${OPEN_TERMINAL%/*}/lib/lane-claims.sh" \
  'lane_claim_put "$1" claim "$2" "$3" "$4" "$5" "${6:-}" "${7:-}" "${8:-plan}"' \
  'lane_claim_put "$1" claim "$2" "$3" "$4" "$5" "${6:-}" "${7:-}" "plan"'
API_SAVED_FAIL="$FAIL"; FAIL=0
api_launch_room > "$TMP_ROOT/api-claim-pool-control.out"
API_CONTROL="$FAIL"; FAIL="$API_SAVED_FAIL"; OPEN_TERMINAL="$API_OT_SHIPPED"
assert_eq "$API_CONTROL" 1 'control: dropping the picked pool makes the unchanged hosted claim assertion fail'
# The refusal cause must reach the launcher even when the chooser works.
OPEN_TERMINAL="$(mutant_scripts ctl-api-refusal/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-api-refusal/orch"
mutate_file "$OPEN_TERMINAL" '3) ot_message lane-credit-refused cause=api-credit retry-at=none' \
  '3) ot_message lane-credit-refused cause=cloud-credit retry-at=none'
api_hosted_rows 5
run_ot "$API_ENV" --host "$HOST_STUB" --harness pi --lane auto --repo o/r KEN-3747
assert_eq "$(api_launch_result)" 'rc=1 creates=0 launched= cause=cause=cloud-credit,retry-at=none,' 'control: the wrong pool cause reaches the launcher refusal'
OPEN_TERMINAL="$API_OT_SHIPPED"

# A hosted Pi relaunch on a Copilot model whose pool neither the provider's
# harness=pi row nor the override reads is refused as unmeasured, with the fix
# naming the provider's accounts read, and open-terminal does not ask whether
# the provider holds the account: the judge already read the provider's row.
run_ot "ORCH_LANE_ALIASES=eclaude=work;flags=--model github-copilot/claude-sonnet-5 --thinking high" --host "$HOST_STUB" --harness pi --lane "$H/.eclaude" --repo o/r --relaunch KEN-1665
assert_eq "$(observe "rc=1 launched=nolog unreadable=lane=$H/.eclaude,model=github-copilot/claude-sonnet-5,step=windows unanswered=0 relaunchgate=0 poolfix=host:$H/.eclaude")" \
  "rc=1 launched=nolog unreadable=lane=$H/.eclaude,model=github-copilot/claude-sonnet-5,step=windows unanswered=0 relaunchgate=0 poolfix=host:$H/.eclaude" \
  "a hosted Pi relaunch on an unread Copilot pool is refused as unmeasured, naming the accounts read, open-terminal never asking whether the provider holds the account"
# The provider's harness=pi row is the pool with no hand-set number: a row with
# room admits the relaunch, and a walled row refuses it on the monthly bucket
# even where the override states room.
PI_ROW_FILE="$TMP_ROOT/hosted-accounts-pi.tsv"
pi_hosted_row() { # PCT
  printf 'account=%s\tharness=pi\tmonthly-pct=%s\tmonthly-resets=2026-10-07T00:00:00Z\n' "$H/.eclaude" "$1" > "$PI_ROW_FILE"
}
pi_hosted_row 40
run_ot "$HARNESS_UP;ORCH_LANE_ALIASES=eclaude=work;LANE_HOST_STUB_ACCOUNTS=$PI_ROW_FILE;flags=--model github-copilot/claude-sonnet-5 --thinking high" --host "$HOST_STUB" --harness pi --lane "$H/.eclaude" --repo o/r --relaunch KEN-1669
assert_eq "$(observe "rc=0 launched=1 unreadable=none poolfix=none")" "rc=0 launched=1 unreadable=none poolfix=none" \
  "a hosted Pi relaunch is admitted on the provider's pool row with no stated reading"
pi_hosted_row 97
run_ot "ORCH_LANE_ALIASES=eclaude=work;ORCH_LANE_COPILOT_POOL=$H/.eclaude=1/10;LANE_HOST_STUB_ACCOUNTS=$PI_ROW_FILE;flags=--model github-copilot/claude-sonnet-5 --thinking high" --host "$HOST_STUB" --harness pi --lane "$H/.eclaude" --repo o/r --relaunch KEN-1669
assert_eq "$(observe "rc=1 launched=nolog walled=lane=$H/.eclaude,model=github-copilot/claude-sonnet-5,pct=97,bucket=monthly,projected-headroom=3")" \
  "rc=1 launched=nolog walled=lane=$H/.eclaude,model=github-copilot/claude-sonnet-5,pct=97,bucket=monthly,projected-headroom=3" \
  "a hosted Pi relaunch is refused on a walled provider row, the stated override replaced"
# A provider row that holds the Pi root and reads no pool leaves it unmeasured,
# and the relaunch is refused: asked whether the provider holds the account,
# open-terminal would take the row as held and relaunch on a pool nobody read.
printf 'account=%s\tharness=pi\tstatus=refused\tdetail=http-403-forbidden\n' "$H/.eclaude" > "$PI_ROW_FILE"
PI_HELD="ORCH_LANE_ALIASES=eclaude=work;LANE_HOST_STUB_ACCOUNTS=$PI_ROW_FILE;flags=--model github-copilot/claude-sonnet-5 --thinking high"
run_ot "$PI_HELD" --host "$HOST_STUB" --harness pi --lane "$H/.eclaude" --repo o/r --relaunch KEN-1669
assert_eq "$(observe "rc=1 launched=nolog relaunchgate=0 poolfix=row:$H/.eclaude")" "rc=1 launched=nolog relaunchgate=0 poolfix=row:$H/.eclaude" \
  "a hosted Pi relaunch on a provider row that reads no pool is refused, never relaunched as held"
# The same row under `auto` is the unstated refusal, its fix naming the row,
# never a walled pool: nobody read it. The control drops the unstated arm, and
# the refusal is reported as lanes failing.
run_ot "$PI_HELD" --host "$HOST_STUB" --harness pi --lane auto --repo o/r KEN-1669
assert_eq "$(observe "rc=1 launched=nolog pickrefusal=copilot-pool-unstated,setting=ORCH_LANE_COPILOT_POOL poolfix=row:$H/.eclaude")" \
  "rc=1 launched=nolog pickrefusal=copilot-pool-unstated,setting=ORCH_LANE_COPILOT_POOL poolfix=row:$H/.eclaude" \
  "a hosted auto Pi launch on a provider row that reads no pool is refused as unstated, naming the row"
pi_control ctl-pi-auto-row open-terminal '    5:pi) ot_message copilot-pool-unstated' '    5:pi-dropped) ot_message copilot-pool-unstated' \
  "$PI_HELD" --host "$HOST_STUB" --harness pi --lane auto --repo o/r KEN-1669
assert_eq "$(observe "rc=1 pickrefusal=none failed=exit=5")" "rc=1 pickrefusal=none failed=exit=5" \
  "control: without the unstated arm the auto refusal on an unread row is reported as lanes failing"
PI_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-pi-host/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-pi-host/orch"
mutate_file "$OPEN_TERMINAL" '[[ "$LANE_HOST" == local || "$LAUNCH_HARNESS" == pi ]]' '[[ "$LANE_HOST" == local ]]'
run_ot "$HARNESS_UP;$PI_HELD" --host "$HOST_STUB" --harness pi --lane "$H/.eclaude" --repo o/r --relaunch KEN-1669
assert_eq "$(observe "rc=0 relaunchgate=1")" "rc=0 relaunchgate=1" \
  "control: a Pi relaunch that asks the provider relaunches on a held row whose pool nobody read"
OPEN_TERMINAL="$PI_OT_SHIPPED"

lane_suite_end
