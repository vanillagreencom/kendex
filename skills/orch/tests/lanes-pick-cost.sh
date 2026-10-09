#!/usr/bin/env bash
# Surface: lanes pick account policy and provider rows.
# Inputs: scripts/lanes, scripts/lib/*.sh, scripts/lane-host, scripts/workflow-state.
# Count executable calls, not elapsed time or shell subshells. The live VM's
# total process and time bounds are checked after consumer refresh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANES="${LANES_UNDER_TEST:-$TEST_DIR/../scripts/lanes}"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
mkdir -p "$TEST_DIR/../../../tmp"
TMP_ROOT="$(mktemp -d "$TEST_DIR/../../../tmp/lanes-cost.XXXXXX")" || { echo 'lanes-pick-cost: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'lanes-pick-cost: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'lanes-pick-cost: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home"
for tool in jq awk basename cksum date tr; do
  real="$(command -v "$tool")"
  printf '#!%s\nset -euo pipefail\nprintf "%%s\\n" %q >> "$COST_COUNTER"\n' "$BASH" "$tool" > "$TMP_ROOT/bin/$tool"
  if [[ "$tool" == date ]]; then
    cat >> "$TMP_ROOT/bin/$tool" <<'STUB'
case "${*: -1}" in
  +%s) printf '1791540000\n' ;;
  +%Y-%m-%d) printf '2026-10-09\n' ;;
  *) exec "$COST_REAL_DATE" "$@" ;;
esac
STUB
  else
    printf 'exec %q "$@"\n' "$real" >> "$TMP_ROOT/bin/$tool"
  fi
  chmod +x "$TMP_ROOT/bin/$tool"
done
REAL_DATE="$(command -v date)"
cat > "$TMP_ROOT/provider" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  capabilities) printf 'kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\n' ;;
  accounts)
    for name in a b c d; do
      printf 'account=%s/.%sclaude\tharness=claude\tsession-5h-pct=10\tweekly-pct=20\n' "$LANES_HOME" "$name"
    done ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$TMP_ROOT/provider"
RETIRE_ONE='absent1=2099-01-01'
RETIRE_TEN="$RETIRE_ONE"
for n in 2 3 4 5 6 7 8 9 10; do RETIRE_TEN+=",absent$n=2099-01-01"; done
run_pick() { # HOMES RETIRE [PROVIDER]
  local n="$1" retire="$2" host="${3:-local}" i
  rm -rf -- "$TMP_ROOT/home" "$TMP_ROOT/state"
  mkdir -p "$TMP_ROOT/home"
  # A scratch home under worktree tmp must not read the enclosing project's
  # settings. No pick in this fixture consumes the operator's configuration.
  git -C "$TMP_ROOT/home" init -q
  git -C "$TMP_ROOT/home" config gc.auto 0
  git -C "$TMP_ROOT/home" config maintenance.auto false
  for ((i=1; i<=n; i++)); do
    mkdir -p "$TMP_ROOT/home/.${i}claude"
    printf '{}\n' > "$TMP_ROOT/home/.${i}claude/.claude.json"
  done
  : > "$TMP_ROOT/counter"
  RC=0
  OUT="$(cd "$TMP_ROOT/home" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    COST_COUNTER="$TMP_ROOT/counter" COST_REAL_DATE="$REAL_DATE" LANES_HOME="$TMP_ROOT/home" \
    ORCH_LANE_RETIRE="$retire" ORCH_LANE_EXCLUDE='blocked' ORCH_LANE_ALIASES=' aclaude = work , bclaude = blocked ' \
    ORCH_LANE_CLOUD_REPOS=' work = Owner/Repo , dclaude = Other/Repo ' \
    ORCH_LANE_HOST="$host" ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S=0 ORCH_LANES_FETCH_CMD=false \
    OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state" "$LANES" pick --harness claude --min-headroom-pct 5 --json \
    2>"$TMP_ROOT/err")" || RC=$?
  COUNT="$(wc -l < "$TMP_ROOT/counter")"; COUNT="${COUNT//[[:space:]]/}"
  BASES="$(awk '$0 == "basename" {n++} END {print n+0}' "$TMP_ROOT/counter")"
  printf 'cost: homes=%s retire=%s calls=%s basename=%s exit=%s\n' "$n" "$retire" "$COUNT" "$BASES" "$RC"
}
counts=()
for homes in 4 8 12; do
  run_pick "$homes" "$RETIRE_ONE"; one="$COUNT"
  assert_eq "$RC" 3 "$homes homes: one retirement entry reaches the chooser"
  run_pick "$homes" "$RETIRE_TEN"
  assert_eq "$RC" 3 "$homes homes: ten retirement entries reach the chooser"
  assert_eq "$COUNT" "$one" "$homes homes: retirement entries add no executable calls"
  assert_eq "$BASES" 0 "$homes homes: pick starts no basename"
  counts+=("$COUNT")
done
assert_eq "$((counts[2]-counts[1]))" "$((counts[1]-counts[0]))" 'equal home increments add equal executable calls'
run_pick 4 ' work = 2099-01-01 , cclaude = 2000-01-01 ' "$TMP_ROOT/provider"
printf 'parity: exit=%s record=%s\n' "$RC" "${OUT//$TMP_ROOT/ROOT}"
assert_eq "$RC" 0 'provider policy fixture picks with the baseline exit'
# This record is captured from the unpatched script, with only its scratch
# root replaced. Keep every public field in the comparison.
EXPECTED='{"alias":"work","harness":"claude","config_dir":"ROOT/home/.aclaude","measured_through":"host","status":"ok","refreshable":false,"plan":null,"session_5h_pct":10,"weekly_pct":20,"model_pct":null,"model_label":null,"model_buckets":[],"monthly_pct":null,"credits":null,"unlimited":false,"claims":0,"headroom_pct":80,"binding_bucket":"weekly","binding_resets_at":null,"usage_age_s":null,"resets":{"session":null,"weekly":null,"model":null,"monthly":null},"detail":null,"usage_rate_state":"one-sample","usage_rate_pct_per_min":null,"projected_wall_minutes":null,"burn_pct_per_lane_hour":0.1488095238095238,"binding_projected_headroom_pct":80,"session_projected_headroom_pct":90,"session_burn_pct_per_lane_hour":5,"session_charge_hours":1,"projected_headroom_pct":80,"projected_window":{"bucket":"weekly","pct":20,"resets_at":null},"selection_score":80,"effective_headroom_pct":80,"qualifying_count":2}'
assert_eq "${OUT//$TMP_ROOT/ROOT}" "$EXPECTED" 'provider policy fixture keeps the baseline JSON' "$TMP_ROOT/err"
rc=0
err="$(cd "$TMP_ROOT/home" && env -i PATH="$PATH" HOME="$TMP_ROOT/home" ORCH_LANE_RETIRE='cclaude=2000-01-01' \
  OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/check-state" "$LANES" check "$TMP_ROOT/home/.cclaude" 2>&1)" || rc=$?
assert_eq "$rc" 4 'fleet named-lane gate keeps retirement exit'
assert_eq "${err%%$'\n'*}" "lanes: lane-retired dir=$TMP_ROOT/home/.cclaude date=2000-01-01" 'fleet named-lane gate keeps machine-readable retirement line'
# Controls use the same assertions on private source copies. The added
# basename recreates the entry-dependent process cost. Ignoring exclusions
# changes the pinned public record's qualifying_count.
ORIGINAL_LANES="$LANES"
CONTROL="$(mutant_scripts policy-cost lanes)"
mutate_file "$CONTROL/lanes" 'lane_base "$2"; base="$LANE_BASE"' 'lane_base "$2"; base="$(basename -- "$2")"'
LANES="$CONTROL/lanes"
run_pick 4 "$RETIRE_ONE"; one="$COUNT"
run_pick 4 "$RETIRE_TEN"
rc=0
( FAIL=0; assert_eq "$COUNT" "$one" 'retirement-entry cost'; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/control-cost.log" || rc=$?
assert_eq "$rc" 1 'cost assertion rejects entry-dependent command starts'
CONTROL="$(mutant_scripts policy-parity lanes)"
mutate_file "$CONTROL/lanes" 'lane_matches "$name" "$1" && return 0' 'lane_matches "$name" "$1" && :'
LANES="$CONTROL/lanes"
run_pick 4 ' work = 2099-01-01 , cclaude = 2000-01-01 ' "$TMP_ROOT/provider"
assert_eq "$RC" 0 'parity control reaches a successful pick'
rc=0
( FAIL=0; assert_eq "${OUT//$TMP_ROOT/ROOT}" "$EXPECTED" 'public JSON'; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/control-parity.log" || rc=$?
assert_eq "$rc" 1 'parity assertion rejects an account policy that ignores exclusions'
LANES="$ORIGINAL_LANES"
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
