#!/usr/bin/env bash
# Surface: lanes pick and list account policy and provider rows.
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
run_lanes() { # HOMES RETIRE PROVIDER VERB FORMAT
  local n="$1" retire="$2" host="$3" verb="$4" format="$5" i
  local mode_args=(--harness claude)
  [[ "$verb" != pick ]] || mode_args+=(--min-headroom-pct 5)
  [[ "$format" != json ]] || mode_args+=(--json)
  rm -rf -- "$TMP_ROOT/home" "$TMP_ROOT/state"
  mkdir -p "$TMP_ROOT/home"
  # A scratch home under worktree tmp must not read the enclosing project's
  # settings. No command in this fixture consumes the operator's configuration.
  git -C "$TMP_ROOT/home" init -q
  git -C "$TMP_ROOT/home" config gc.auto 0
  git -C "$TMP_ROOT/home" config maintenance.auto false
  for ((i=1; i<=n; i++)); do
    mkdir -p "$TMP_ROOT/home/.${i}claude"
    printf '{}\n' > "$TMP_ROOT/home/.${i}claude/.claude.json"
  done
  : > "$TMP_ROOT/counter"
  RC=0
  (cd "$TMP_ROOT/home" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    COST_COUNTER="$TMP_ROOT/counter" COST_REAL_DATE="$REAL_DATE" LANES_HOME="$TMP_ROOT/home" \
    ORCH_LANE_RETIRE="$retire" ORCH_LANE_EXCLUDE='blocked' ORCH_LANE_ALIASES=' aclaude = work , bclaude = blocked ' \
    ORCH_LANE_CLOUD_REPOS=' work = Owner/Repo , dclaude = Other/Repo ' \
    ORCH_LANE_HOST="$host" ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S=0 ORCH_LANES_FETCH_CMD=false \
    OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state" "$LANES" "$verb" "${mode_args[@]}" \
    >"$TMP_ROOT/out" 2>"$TMP_ROOT/err") || RC=$?
  OUT="$(cat "$TMP_ROOT/out")"
  COUNT="$(wc -l < "$TMP_ROOT/counter")"; COUNT="${COUNT//[[:space:]]/}"
  BASES="$(awk '$0 == "basename" {n++} END {print n+0}' "$TMP_ROOT/counter")"
  printf 'cost: verb=%s format=%s homes=%s retire=%s calls=%s basename=%s exit=%s\n' "$verb" "$format" "$n" "$retire" "$COUNT" "$BASES" "$RC"
}
counts=()
for homes in 4 8 12; do
  run_lanes "$homes" "$RETIRE_ONE" local pick json; one="$COUNT"
  assert_eq "$RC" 3 "$homes homes: one retirement entry reaches the chooser"
  run_lanes "$homes" "$RETIRE_TEN" local pick json
  assert_eq "$RC" 3 "$homes homes: ten retirement entries reach the chooser"
  assert_eq "$COUNT" "$one" "$homes homes: retirement entries add no executable calls"
  assert_eq "$BASES" 0 "$homes homes: pick starts no basename"
  counts+=("$COUNT")
done
assert_eq "$((counts[2]-counts[1]))" "$((counts[1]-counts[0]))" 'equal home increments add equal executable calls'
# The fixture directory and account number vary; captured fields and the
# retirement field stay pinned, with ordering, spaces and final newlines.
# The comparison reads the raw stdout files.
EXPECTED_LIST_ROW='{"alias":"NAMEclaude","harness":"claude","config_dir":"CONFIG_DIR","retire_date":null,"measured_through":"local","status":"no_credentials","refreshable":false,"plan":null,"session_5h_pct":null,"weekly_pct":null,"model_pct":null,"model_label":null,"model_buckets":[],"monthly_pct":null,"credits":null,"unlimited":false,"claims":0,"headroom_pct":null,"binding_bucket":null,"binding_resets_at":null,"usage_age_s":null,"resets":{"session":null,"weekly":null,"model":null,"monthly":null},"detail":"no credential file at CONFIG_DIR/.credentials.json","wall":null,"usage_rate_state":"one-sample","usage_rate_pct_per_min":null,"projected_wall_minutes":null,"burn_pct_per_lane_hour":null,"binding_projected_headroom_pct":null,"session_projected_headroom_pct":null,"session_burn_pct_per_lane_hour":null,"session_charge_hours":null,"projected_headroom_pct":null,"projected_window":null,"verdict":"unmeasured"}'
write_expected_list() { # HOMES FORMAT
  local names width=9 name dir row comma="" header='LANE     '
  case "$1" in
    4) names='1 2 3 4' ;;
    8) names='1 2 3 4 5 6 7 8' ;;
    12) names='10 11 12 1 2 3 4 5 6 7 8 9'; width=10; header='LANE      ' ;;
  esac
  if [[ "$2" == json ]]; then
    printf '['
    for name in $names; do
      dir="$TMP_ROOT/home/.${name}claude"
      row="${EXPECTED_LIST_ROW//NAME/$name}"
      row="${row//CONFIG_DIR/$dir}"
      printf '%s%s' "$comma" "$row"; comma=','
    done
    printf ']\n'
  else
    printf '%s%s\n' "$header" 'HARNESS  THROUGH  STATUS          PLAN  5H  WEEK  MODEL  MONTH  HEADROOM  CLAIMS  AGE  DETAIL'
    for name in $names; do
      printf '%-*s%s%s\n' "$width" "${name}claude" \
        'claude   local    no_credentials  -     -   -     -      -      -         0       -    no credential file at ' \
        "$TMP_ROOT/home/.${name}claude/.credentials.json"
    done
  fi
}
for format in table json; do
  counts=()
  for homes in 4 8 12; do
    write_expected_list "$homes" "$format" > "$TMP_ROOT/expected"
    for entries in 1 10; do
      retire="$RETIRE_ONE"
      [[ "$entries" != 10 ]] || retire="$RETIRE_TEN"
      run_lanes "$homes" "$retire" local list "$format"
      assert_eq "$RC" 0 "$homes homes, $entries retirement entries: list $format exits successfully"
      cmp_rc=0; cmp -s -- "$TMP_ROOT/out" "$TMP_ROOT/expected" || cmp_rc=$?
      assert_eq "$cmp_rc" 0 "$homes homes, $entries retirement entries: list $format matches baseline bytes"
      assert_eq "$BASES" 0 "$homes homes, $entries retirement entries: list $format starts no basename"
      if [[ "$entries" == 1 ]]; then one="$COUNT"; else
        assert_eq "$COUNT" "$one" "$homes homes: list $format retirement entries add no executable calls"
      fi
    done
    counts+=("$COUNT")
  done
  assert_eq "$((counts[2]-counts[1]))" "$((counts[1]-counts[0]))" "list $format equal home increments add equal executable calls"
done
run_lanes 4 ' work = 2099-01-01 , cclaude = 2000-01-01 ' "$TMP_ROOT/provider" pick json
printf 'parity: exit=%s record=%s\n' "$RC" "${OUT//$TMP_ROOT/ROOT}"
assert_eq "$RC" 0 'provider policy fixture picks with the baseline exit'
# Keep every captured public field and the retirement field in the
# comparison, with only the scratch root replaced.
EXPECTED='{"alias":"work","harness":"claude","config_dir":"ROOT/home/.aclaude","retire_date":"2099-01-01","measured_through":"host","status":"ok","refreshable":false,"plan":null,"session_5h_pct":10,"weekly_pct":20,"model_pct":null,"model_label":null,"model_buckets":[],"monthly_pct":null,"credits":null,"unlimited":false,"claims":0,"headroom_pct":80,"binding_bucket":"weekly","binding_resets_at":null,"usage_age_s":null,"resets":{"session":null,"weekly":null,"model":null,"monthly":null},"detail":null,"usage_rate_state":"one-sample","usage_rate_pct_per_min":null,"projected_wall_minutes":null,"burn_pct_per_lane_hour":0.1488095238095238,"binding_projected_headroom_pct":80,"session_projected_headroom_pct":90,"session_burn_pct_per_lane_hour":5,"session_charge_hours":1,"projected_headroom_pct":80,"projected_window":{"bucket":"weekly","pct":20,"resets_at":null},"selection_score":80,"effective_headroom_pct":80,"qualifying_count":2}'
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
run_lanes 4 "$RETIRE_ONE" local pick json; one="$COUNT"
run_lanes 4 "$RETIRE_TEN" local pick json
rc=0
( FAIL=0; assert_eq "$COUNT" "$one" 'retirement-entry cost'; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/control-cost.log" || rc=$?
assert_eq "$rc" 1 'cost assertion rejects entry-dependent command starts'
for format in table json; do
  run_lanes 4 "$RETIRE_ONE" local list "$format"; one="$COUNT"
  assert_eq "$RC" 0 "cost control list $format reaches the listing"
  run_lanes 4 "$RETIRE_TEN" local list "$format"
  rc=0
  ( FAIL=0; assert_eq "$COUNT" "$one" 'retirement-entry cost'; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/control-list-cost-$format.log" || rc=$?
  assert_eq "$rc" 1 "cost assertion rejects list $format entry-dependent command starts"
done
CONTROL="$(mutant_scripts policy-parity lanes)"
mutate_file "$CONTROL/lanes" 'lane_matches "$name" "$1" && return 0' 'lane_matches "$name" "$1" && :'
LANES="$CONTROL/lanes"
run_lanes 4 ' work = 2099-01-01 , cclaude = 2000-01-01 ' "$TMP_ROOT/provider" pick json
assert_eq "$RC" 0 'parity control reaches a successful pick'
rc=0
( FAIL=0; assert_eq "${OUT//$TMP_ROOT/ROOT}" "$EXPECTED" 'public JSON'; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/control-parity.log" || rc=$?
assert_eq "$rc" 1 'parity assertion rejects an account policy that ignores exclusions'
CONTROL="$(mutant_scripts list-parity lanes)"
mutate_file "$CONTROL/lanes" \
  'map(with_lane_projection($burn; $now) | with_lane_verdict(.wall; $max; $credit_floor) | lane_public)' \
  'map(with_lane_projection($burn; $now) | with_lane_verdict(.wall; $max; $credit_floor) | .claims = 7 | lane_public)'
LANES="$CONTROL/lanes"
for format in table json; do
  run_lanes 4 "$RETIRE_ONE" local list "$format"
  assert_eq "$RC" 0 "parity control list $format reaches the listing"
  write_expected_list 4 "$format" > "$TMP_ROOT/expected"
  cmp_rc=0; cmp -s -- "$TMP_ROOT/out" "$TMP_ROOT/expected" || cmp_rc=$?
  rc=0
  ( FAIL=0; assert_eq "$cmp_rc" 0 'baseline bytes'; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/control-list-parity-$format.log" || rc=$?
  assert_eq "$rc" 1 "parity assertion rejects changed list $format bytes"
done
LANES="$ORIGINAL_LANES"
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
