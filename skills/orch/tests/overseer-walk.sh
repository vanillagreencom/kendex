#!/usr/bin/env bash
# Surface: ol_walk over the runtime's account
# judge, its replies planted from fixtures/accounts-pick; the rows that ask
# the retained `lanes pick` directly run it over the usage fixture.
# Inputs: skills/agent-runtime/, skills/agent-runtime/scripts/, skills/change-scope/references/,
# skills/change-scope/scripts/, skills/communication/references/reports.md,
# skills/mailbox/scripts/, skills/orch/runtime/, skills/orch/scripts/, skills/orch/tests/.
# Only the usage endpoint is a fixture.
set -euo pipefail
export MSYS=winsymlinks:nativestrict
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
SKILLS="${OVERSEER_WALK_SKILLS:-$(cd -- "$TEST_DIR/../.." && pwd -P)}"
MODE="${1:-all}"
TMP_ROOT="$(mktemp -d)" || { echo 'overseer-walk: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'overseer-walk: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'overseer-walk: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/lanes-fixture.sh"
source "$TEST_DIR/lib/growth-state.sh"
new_home succession
mkdir -p "$H/work/tmp"
export HOME="$H" LANES_HOME="$H" XDG_STATE_HOME="$H/state" ORCH_STATE_DIR="$H/work/tmp"
export OVERSEE_WATCH_STATE_DIR="$H/claims" ORCH_LANES_USAGE_TTL=0 ORCH_LANE_HOST=local
export ORCH_LANE_EXCLUDE= ORCH_LANE_RETIRE= ORCH_LANE_ALIASES= ORCH_LANE_COPILOT_POOL=
export ORCH_LANE_BURN_PCT_PER_HOUR=0 ORCH_OVERSEER_HEADROOM_PCT=50
unset CODEX_HOME CLAUDE_CONFIG_DIR TMUX TMUX_PANE
cd -- "$H/work"
make_lane "$H" claude
make_lane "$H" unreadclaude
jq -n --arg account "$H/.claude" '{controller:{account:$account}}' > "$ORCH_STATE_DIR/workflow-state-oversee.json"
claude_usage 57 30 5 Opus > "$FIXTURE_DIR/.claude.json"
for row in 'codex:22' '1codex:20' '2codex:18'; do
  name="${row%:*}" used="${row#*:}"
  make_codex_lane "$H/.$name"
  jq -n --argjson used "$used" '{rate_limit:{primary_window:{used_percent:$used,
    reset_at:4070908800,limit_window_seconds:18000},secondary_window:null}}' > "$FIXTURE_DIR/.$name.json"
done
make_fetcher "$TMP_ROOT/fetch"
export ORCH_LANES_FETCH_CMD="$TMP_ROOT/fetch"
export ORCH_LANE_DIRS="$H/.claude:$H/.unreadclaude:$H/.codex:$H/.1codex:$H/.2codex"
SCRIPT_DIR="$SKILLS/orch/scripts" DEP_ERR="$TMP_ROOT/dependency.err"
source "$SCRIPT_DIR/lib/lane-launch.sh"
source "$SCRIPT_DIR/lib/lane-context.sh"
source "$SCRIPT_DIR/lib/overseer-launch.sh"
# The walk asks the runtime's account judge; this world has no built
# runtime, so the stand-in (lib/runtime-stub.sh), named by AGENT_RUNTIME_CLI,
# answers each `accounts pick` the walk asks with the reply the real verb
# printed over this world: one file per question (harness, trigger, excluded
# account) under fixtures/accounts-pick, its home spelled as this one's,
# each held to the verb by tests/rust/walk.rs. A question no file answers
# is refused, never answered by the retained shell judge.
source "$TEST_DIR/lib/runtime-stub.sh"
mkdir -p "$TMP_ROOT/runtime/runtime.picks"
fixture_runtime_stub "$TMP_ROOT/runtime" "$TMP_ROOT/runtime" || exit 1
for reply in "$TEST_DIR"/fixtures/accounts-pick/*.json; do
  sed "s|@H@|$H|g" "$reply" > "$TMP_ROOT/runtime/runtime.picks/$(basename "$reply" .json)"
done
: > "$TMP_ROOT/runtime/runtime.picks-only"
export AGENT_RUNTIME_CLI="$TMP_ROOT/runtime/orch-runtime"

selection() {
  local rc=0 result row role flag expected_rc expected_account
  for row in "ordinary||3|none" "successor|--for-overseer|0|$H/.claude"; do
    IFS='|' read -r role flag expected_rc expected_account <<<"$row"
    rc=0
    result="$("$SCRIPT_DIR/lanes" pick --harness claude --min-headroom-pct 5 ${flag:+"$flag"} --json 2>"$TMP_ROOT/seat.err")" || rc=$?
    result="$(jq -r '.config_dir // "none"' <<<"$result")"
    assert_eq "$rc|$result" "$expected_rc|$expected_account" "own seated account eligibility for $role" "$TMP_ROOT/seat.err"
  done
  rc=0
  # Source 43% is below trigger 50; the first entry has unreadable usage.
  # Codex accounts have 78%, 80% and 82%; the real picker selects 82%.
  ol_walk 50 "$H/.claude" claude::high codex::high || rc=$?
  assert_eq "$rc|$OL_CHOSEN|$OL_LANE_DIR" "0|codex::high|$H/.2codex" 'mixed walk selects readable above-trigger account' "$DEP_ERR"
}

exclusions() {
  local rc=0 got result line
  ol_walk 90 "$H/.claude" claude::high codex::high || rc=$?
  got="$(printf '%s\n' ${OL_WALK_SKIPS[@]+"${OL_WALK_SKIPS[@]}"} | LC_ALL=C sort)"
  result="$(printf 'successor-lane-excluded\tentry=%s\tlane=%s\treason=%s\n' \
    claude::high "$H/.unreadclaude" unmeasured \
    codex::high "$H/.codex" walled \
    codex::high "$H/.1codex" walled \
    codex::high "$H/.2codex" walled | LC_ALL=C sort)"
  # OL_WALK_SKIPS is the machine-read contract of Jarvis select; test its
  # typed fields rather than explanatory prose.
  assert_eq "$rc|$got" "3|$result" 'walk preserves every refused entry and account verdict' "$DEP_ERR"
  rc=0
  result="$("$SCRIPT_DIR/lanes" pick --harness claude --for-overseer --min-headroom-pct 90 --json 2>"$TMP_ROOT/pick.err")" || rc=$?
  got="$(jq -c '(.exclusions // []) | sort_by(.config_dir)' <<<"$result")"
  result="$(jq -nc --arg source "$H/.claude" --arg unread "$H/.unreadclaude" \
    '[{config_dir:$source,reason:"walled"},{config_dir:$unread,reason:"unmeasured"}] | sort_by(.config_dir)')"
  assert_eq "$rc|$got" "3|$result" 'overseer picker returns each exclusion in its refusal record' "$TMP_ROOT/pick.err"
  got="$(sed -n 's/^lanes: pick-account-excluded //p' "$TMP_ROOT/pick.err" | LC_ALL=C sort)"
  result="$(printf 'lane=%s reason=%s\n' "$H/.claude" walled "$H/.unreadclaude" unmeasured | LC_ALL=C sort)"
  assert_eq "$got" "$result" 'picker emits keyed account exclusion fields' "$TMP_ROOT/pick.err"
  rc=0
  result="$("$SCRIPT_DIR/lanes" pick --harness claude --min-headroom-pct 5 --json 2>"$TMP_ROOT/seat.err")" || rc=$?
  got="$(jq -r --arg account "$H/.claude" '[.walled,.unmeasured,.seats,(.exclusions[]? | select(.config_dir == $account) | .reason)] | map(tostring) | join("|")' <<<"$result")"
  line="$(awk '$1 == "lanes:" {print $2; exit}' "$TMP_ROOT/seat.err")"
  assert_eq "$rc|$line|$got" '3|no-candidate|0|1|1|seat-reserve' 'ordinary picker preserves its summary and names the reserved exclusion' "$TMP_ROOT/seat.err"
}

skip_details() {
  local row source target rows deprecated entry expected rc got tab=$'\t'
  for row in \
    'bootstrap||pi|0|false|pi:openai/gpt-5:high|entry-permission-unwritable' \
    'transfer|claude|codex|0|false|codex::high|entry-permission-untransferable' \
    'unmeasured-posture|pi|codex|1|false|codex::high|entry-permission-untransferable' \
    'numeric|copilot|claude|0|true|claude:1:high|entry-permission-untransferable'; do
    IFS='|' read -r row source target rows deprecated entry expected <<<"$row"
    OL_WALK_SOURCE_HARNESS="$source" OL_WALK_SOURCE_FLAGS='' OL_WALK_SOURCE_ROWS="$rows"
    OL_HARNESS="$target" OL_ENTRY_DEPRECATED="$deprecated" OL_MODEL=caller-model OL_WALK_SKIPS=()
    rc=0
    ol_entry_permitted "$entry" || rc=$?
    got="${OL_WALK_SKIPS[*]-}"
    assert_eq "$rc|${got%%$'\t'*}" "1|$expected" "permission $row retains its exclusion category"
    assert_contains "$got" "${tab}entry=$entry${tab}" "permission $row identifies its entry"
    assert_contains "$got" "${tab}lane=none" "permission $row names the unpicked account"
  done
  OL_WALK_SOURCE_HARNESS='' OL_WALK_SOURCE_ROWS=0 OL_WALK_SUCCESSOR_BOUND=3
  rc=0
  ol_walk 50 "$H/.claude" codex::high || rc=$?
  expected="successor-count-bound${tab}entry=codex::high${tab}lane=$H/.2codex${tab}qualifying=3${tab}bound=3"
  assert_eq "$rc|${OL_WALK_SKIPS[*]-}" "3|$expected" 'successor-bound exclusion names its account and count' "$DEP_ERR"
  OL_WALK_SOURCE_HARNESS=pi
  rc=0
  ol_walk 50 '' pi:openai/gpt-5:high || rc=$?
  expected="successor-count-unmeasured${tab}entry=pi:openai/gpt-5:high${tab}lane=none"
  assert_eq "$rc|${OL_WALK_SKIPS[*]-}" "3|$expected" 'accountless successor names its unmeasured count'
  OL_WALK_SOURCE_HARNESS='' OL_WALK_SOURCE_ROWS=0 OL_WALK_SUCCESSOR_BOUND=0
}

case "$MODE" in
  selection) selection ;;
  exclusions) exclusions; skip_details ;;
  all)
    selection
    exclusions
    skip_details
    # A disposable source mutation restores main's dropped walk evidence.
    CONTROL="$(mutant_scripts skip-control/orch lib/overseer-launch.sh)"
    mutate_file "$CONTROL/lib/overseer-launch.sh" \
      '    OL_WALK_SKIPS+=("successor-lane-excluded${tab}entry=$1${tab}lane=$lane${tab}reason=$reason")' \
      '    if false; then OL_WALK_SKIPS+=("successor-lane-excluded${tab}entry=$1${tab}lane=$lane${tab}reason=$reason"); fi'
    if (source "$CONTROL/lib/overseer-launch.sh"; FAIL=0; exclusions; (( FAIL == 0 ))) >"$TMP_ROOT/control.out" 2>&1; then
      fail 'exclusion contract accepted dropped walk evidence'
    else
      pass 'exclusion contract rejects dropped walk evidence'
    fi
    ;;
  *) echo "overseer-walk: mode-invalid value=$MODE" >&2; exit 2 ;;
esac
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
