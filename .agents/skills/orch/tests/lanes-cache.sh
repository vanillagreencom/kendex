#!/usr/bin/env bash
# Cache retention and reads use the same account policy as lane discovery.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/lanes-fixture.sh"
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
LANES="$TEST_DIR/../scripts/lanes"
PROVIDER="$TEST_DIR/fixtures/lane-host"
new_home cache
make_lane "$H" claude
make_lane "$H" eclaude
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 30 40 5 Opus > "$FIXTURE_DIR/.eclaude.json"
make_fetcher "$TMP_ROOT/fetch"
mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/bin"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
printf 'account=%s\tharness=claude\tweekly-pct=20\naccount=%s\tharness=claude\tweekly-pct=40\n' \
  "$H/.claude" "$H/.eclaude" > "$TMP_ROOT/accounts"

# jq is the credential reader in measure_lane. Record attempts independently
# of fetches, so a cached answer cannot conceal an excluded credential read.
REAL_JQ="$(command -v jq)"
cat > "$TMP_ROOT/bin/jq" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  case "$arg" in */.credentials.json|*/auth.json) printf '%s\n' "$arg" >> "$CREDENTIAL_LOG" ;; esac
done
exec "$REAL_JQ" "$@"
STUB
chmod +x "$TMP_ROOT/bin/jq"
REAL_RM="$(command -v rm)"
cat > "$TMP_ROOT/bin/rm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$CACHE_RM_FAIL" == 1 ]]; then
  for arg in "$@"; do
    case "$arg" in */usage/*.json) exit 1 ;; esac
  done
fi
exec "$REAL_RM" "$@"
STUB
chmod +x "$TMP_ROOT/bin/rm"

# Run the shipped command in an empty environment and a settings-free repo.
cache_run() { # STATE POLICY COMMAND...
  local state="$1" policy="$2"
  shift 2
  (cd "$TMP_ROOT/repo" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$H" \
    REAL_JQ="$REAL_JQ" CREDENTIAL_LOG="$TMP_ROOT/credentials" \
    REAL_RM="$REAL_RM" CACHE_RM_FAIL="${CACHE_RM_FAIL:-0}" \
    LANES_HOME="$H" ORCH_LANE_DIRS="$H/.claude,$H/.eclaude" \
    ORCH_LANES_FETCH_CMD="$TMP_ROOT/fetch" FIXTURE_DIR="$FIXTURE_DIR" \
    OVERSEE_WATCH_STATE_DIR="$state" ORCH_LANE_HOST="$PROVIDER" \
    LANE_HOST_STUB_ACCOUNTS="$TMP_ROOT/accounts" LANE_HOST_STUB_LOG="$TMP_ROOT/provider-log" \
    "$policy" "$LANES" "$@")
}

for row in 'exclude|ORCH_LANE_EXCLUDE=claude|0' 'retire|ORCH_LANE_RETIRE=claude=2000-01-01|1'; do
  IFS='|' read -r name policy retired <<<"$row"
  state="$TMP_ROOT/$name"
  # Two actual writes exercise both current and prior hosted and local samples.
  cache_run "$state" ORCH_LANE_EXCLUDE= list --json --no-cache > "$TMP_ROOT/out"
  cache_run "$state" ORCH_LANE_EXCLUDE= list --json --no-cache > "$TMP_ROOT/out"
  assert_eq "$(jq -s '[.[] | select(.prior.usage != null)] | length' "$state"/usage/*.json)" \
    3 "$name seeds current and prior samples through real writes"
  : > "$TMP_ROOT/credentials"
  cache_run "$state" "$policy" list --json --local > "$TMP_ROOT/out"
  assert_eq "$(jq -s '[.[] | select(.config_dir | endswith("/.claude"))] | length' "$state"/usage/*.json)" \
    0 "$name removes local records even before any hosted read"
  assert_eq "$(find "$state/usage" -name 'host-accounts-*.json' | wc -l | tr -d ' ')" \
    0 "$name removes the old provider record even on a local listing"
  cache_run "$state" "$policy" host-accounts --json > "$TMP_ROOT/out"
  assert_eq "$(jq '[.[] | select(.alias == "claude" and .status == "retired")] | length' "$TMP_ROOT/out")" \
    "$retired" "$name preserves hosted retirement reporting"
  assert_eq "$(jq -r '.usage.rows' "$state"/usage/host-accounts-*.json | grep -c 'weekly-pct=20' || true)" \
    0 "$name never writes removed hosted usage back"
  cache_run "$state" "$policy" pick --harness claude --json > "$TMP_ROOT/out"
  assert_eq "$(jq -r '.config_dir' "$TMP_ROOT/out")" "$H/.eclaude" "$name cannot select cached removed capacity"
  assert_eq "$(grep -c -F "$H/.claude/.credentials.json" "$TMP_ROOT/credentials" || true)" \
    0 "$name never reads the removed account's credentials"
done

# Reach the cache reader directly in a disposable script, before discovery or
# startup pruning can mask a missing read guard. The production reader remains
# unchanged; only dispatch is replaced in this copy.
state="$TMP_ROOT/reader"
cache_run "$state" ORCH_LANE_EXCLUDE= list --json --no-cache > "$TMP_ROOT/out"
reader_dir="$(mutant_scripts reader lanes)"
mutate_file "$reader_dir/lanes" 'parse_argv "$@"' \
  'read_usage_cache "$1" "$2" "$(date +%s)" ""; exit $?'
ORIGINAL_LANES="$LANES"
LANES="$reader_dir/lanes"
for row in "claude|$H/.claude" "host-accounts|$PROVIDER"; do
  IFS='|' read -r harness account <<<"$row"
  for policy in ORCH_LANE_EXCLUDE=claude ORCH_LANE_RETIRE=claude=2000-01-01; do
    rc=0
    cache_run "$state" "$policy" "$harness" "$account" > "$TMP_ROOT/out" || rc=$?
    assert_eq "$rc:$(cat "$TMP_ROOT/out")" '1:' "$harness reader refuses $policy before discovery"
  done
done
LANES="$ORIGINAL_LANES"

# Each policy has its own control. The parser still runs, but the existing
# matcher no longer reports that policy, so the very same cached body is served.
for row in 'exclude|lane_excluded() {|ORCH_LANE_EXCLUDE=claude' 'retire|lane_retired() {|ORCH_LANE_RETIRE=claude=2000-01-01'; do
  IFS='|' read -r name match policy <<<"$row"
  control_dir="$(mutant_scripts "control-$name" lanes)"
  mutate_file "$control_dir/lanes" "$match" "$match return 1;"
  mutate_file "$control_dir/lanes" 'parse_argv "$@"' \
    'read_usage_cache "$1" "$2" "$(date +%s)" ""; exit $?'
  LANES="$control_dir/lanes"
  for row in "claude|$H/.claude" "host-accounts|$PROVIDER"; do
    IFS='|' read -r harness account <<<"$row"
    rc=0
    cache_run "$state" "$policy" "$harness" "$account" > "$TMP_ROOT/out" || rc=$?
    assert_eq "$rc:$(jq -r 'has("usage")' "$TMP_ROOT/out")" '0:true' \
      "control: disabling $name makes the $harness refusal assertion fail"
  done
done
LANES="$ORIGINAL_LANES"

# The cleanup assertion must fail if startup still judges every file but
# leaves rejected records on disk. A local read cannot replace the host record.
control_dir="$(mutant_scripts control-prune lanes)"
mutate_file "$control_dir/lanes" 'rm -f -- "$file" || die usage-cache-prune-failed "$file"' \
  ': "$file" || die usage-cache-prune-failed "$file"'
LANES="$control_dir/lanes"
cache_run "$state" ORCH_LANE_EXCLUDE=claude list --local --json > "$TMP_ROOT/out"
assert_eq "$(jq -s '[.[] | select(.config_dir | endswith("/.claude"))] | length' "$state"/usage/*.json)" \
  1 'control: disabling deletion leaves removed local usage on disk'
assert_eq "$(find "$state/usage" -name 'host-accounts-*.json' | wc -l | tr -d ' ')" \
  1 'control: disabling deletion leaves removed hosted usage on disk'

# Removing only read-time rows must not conceal bodies retained by the writer.
control_dir="$(mutant_scripts control-write lanes)"
mutate_file "$control_dir/lanes" 'rows="$(host_account_rows "$rows" all cache)" || return 1' \
  ': "$rows" || return 1'
LANES="$control_dir/lanes"
cache_run "$TMP_ROOT/writer" ORCH_LANE_EXCLUDE=claude host-accounts --json --no-cache > "$TMP_ROOT/out"
assert_eq "$(jq -r '.usage.rows' "$TMP_ROOT/writer"/usage/host-accounts-*.json | grep -c 'weekly-pct=20' || true)" \
  1 'control: disabling write filtering retains excluded hosted usage'

LANES="$ORIGINAL_LANES"
CACHE_RM_FAIL=1
rc=0
cache_run "$state" ORCH_LANE_EXCLUDE=claude list --local --json > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || rc=$?
assert_eq "$rc" 1 'a cache deletion failure refuses the command'
assert_contains "$(cat "$TMP_ROOT/err")" 'lanes: usage-cache-prune-failed path=' 'a deletion failure names the cache path'
control_dir="$(mutant_scripts control-prune-failure lanes)"
mutate_file "$control_dir/lanes" 'rm -f -- "$file" || die usage-cache-prune-failed "$file"' \
  'rm -f -- "$file" || : usage-cache-prune-failed "$file"'
LANES="$control_dir/lanes"
rc=0
cache_run "$state" ORCH_LANE_EXCLUDE=claude list --local --json > "$TMP_ROOT/out" || rc=$?
assert_eq "$rc" 0 'control: swallowing deletion failure makes the refusal assertion fail'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
