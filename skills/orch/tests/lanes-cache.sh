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

# jq is the credential reader in measure_lane and the cache reader in
# usage_cache_permitted. Record both independently of fetches, so a cached
# answer cannot conceal an excluded credential read, and a startup scan that
# was skipped is told from one that ran.
REAL_JQ="$(command -v jq)"
cat > "$TMP_ROOT/bin/jq" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  case "$arg" in
    */.credentials.json|*/auth.json) printf '%s\n' "$arg" >> "$CREDENTIAL_LOG" ;;
    */usage/*.json) printf '%s\n' "$arg" >> "$CACHE_READ_LOG" ;;
  esac
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
# The UTC day is the one clock the retirement policy reads; FAKE_TODAY moves it
# for one run so a case can have a retirement date arrive.
REAL_DATE="$(command -v date)"
cat > "$TMP_ROOT/bin/date" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "$FAKE_TODAY" && "$*" == "-u +%Y-%m-%d" ]]; then printf '%s\n' "$FAKE_TODAY"; exit 0; fi
exec "$REAL_DATE" "$@"
STUB
chmod +x "$TMP_ROOT/bin/date"

# Run the shipped command in an empty environment and a settings-free repo.
# POLICY is one or more blank-separated `NAME=value` settings.
cache_run() { # STATE POLICY COMMAND...
  local state="$1"
  local -a policy
  read -ra policy <<<"$2"
  shift 2
  (cd "$TMP_ROOT/repo" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$H" \
    REAL_JQ="$REAL_JQ" CREDENTIAL_LOG="$TMP_ROOT/credentials" CACHE_READ_LOG="$TMP_ROOT/cache-reads" \
    REAL_RM="$REAL_RM" CACHE_RM_FAIL="${CACHE_RM_FAIL:-0}" \
    REAL_DATE="$REAL_DATE" FAKE_TODAY="${FAKE_TODAY:-}" \
    LANES_HOME="$H" ORCH_LANE_DIRS="$H/.claude:$H/.eclaude" \
    ORCH_LANES_FETCH_CMD="$TMP_ROOT/fetch" FIXTURE_DIR="$FIXTURE_DIR" \
    OVERSEE_WATCH_STATE_DIR="$state" ORCH_LANE_HOST="$PROVIDER" \
    LANE_HOST_STUB_ACCOUNTS="$TMP_ROOT/accounts" LANE_HOST_STUB_LOG="$TMP_ROOT/provider-log" \
    "${policy[@]}" "$LANES" "$@")
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

# A provider record is stamped with the policy that shaped it, so a lifted
# exclusion, a lifted or postponed retirement, an alias moved to another
# account under a key naming it, and a retirement date that arrives each ask
# the provider again inside the TTL. The provider log counts the calls; the
# cached answer would leave it unchanged. A row's sixth field is the alias
# the written record lists the account under, where the policy renames it.
provider_calls() { grep -c 'accounts' "$TMP_ROOT/provider-log"; }
claude_hosted() { # [ALIAS] — the hosted row listed under ALIAS (default claude) as STATUS:WEEKLY, or absent
  jq -r --arg alias "${1:-claude}" '[.[] | select(.alias == $alias)] | if length == 0 then "absent" else "\(.[0].status):\(.[0].weekly_pct)" end' "$TMP_ROOT/out"
}
state="$TMP_ROOT/lifted"
: > "$TMP_ROOT/provider-log"
for row in 'ORCH_LANE_EXCLUDE=claude|ORCH_LANE_EXCLUDE=|absent|ok:20|a lifted exclusion' \
  'ORCH_LANE_RETIRE=claude=2000-01-01|ORCH_LANE_RETIRE=|retired:null|ok:20|a lifted retirement' \
  'ORCH_LANE_RETIRE=claude=2000-01-01|ORCH_LANE_RETIRE=claude=2099-01-01|retired:null|ok:20|a postponed retirement' \
  'ORCH_LANE_EXCLUDE=work ORCH_LANE_ALIASES=claude=work|ORCH_LANE_EXCLUDE=work ORCH_LANE_ALIASES=eclaude=work|absent|ok:20|an alias moved under an exclusion|work' \
  'ORCH_LANE_RETIRE=work=2000-01-01 ORCH_LANE_ALIASES=claude=work|ORCH_LANE_RETIRE=work=2000-01-01 ORCH_LANE_ALIASES=eclaude=work|retired:null|ok:20|an alias moved under a retirement|work'; do
  IFS='|' read -r written read_under before after name written_alias <<<"$row"
  cache_run "$state" "$written" host-accounts --json > "$TMP_ROOT/out"
  assert_eq "$(claude_hosted "${written_alias:-claude}")" "$before" "$name: the record is written under the policy"
  calls="$(provider_calls)"
  cache_run "$state" "$read_under" host-accounts --json > "$TMP_ROOT/out"
  assert_eq "$(claude_hosted)" "$after" "$name is visible on the next read"
  assert_eq "$(provider_calls)" "$((calls + 1))" "$name asks the provider again"
done
cache_run "$state" ORCH_LANE_EXCLUDE= pick --harness claude --json > "$TMP_ROOT/out"
assert_eq "$(jq -r '.config_dir' "$TMP_ROOT/out")" "$H/.claude" 'a lifted exclusion makes the account pickable again'
cache_run "$state" ORCH_LANE_RETIRE=claude=2099-01-01 host-accounts --json > "$TMP_ROOT/out"
calls="$(provider_calls)"
FAKE_TODAY=2099-01-01 cache_run "$state" ORCH_LANE_RETIRE=claude=2099-01-01 host-accounts --json > "$TMP_ROOT/out"
assert_eq "$(claude_hosted)" 'retired:null' 'a retirement date that arrives is visible on the next read'
assert_eq "$(provider_calls)" "$((calls + 1))" 'a retirement date that arrives asks the provider again'

# Reach the cache reader directly in a disposable script, before discovery or
# startup pruning can mask a missing read guard. The production reader remains
# unchanged; only the `check` verb's first step is replaced in this copy, which
# is the one dispatch site that runs after the cache directory and the clock
# are initialized and before validate_lane_settings prunes. The parser owns the
# argv: `check` takes one directory, and --harness names the record's harness.
# The state dir is named apart from every mutant, which mutant_scripts clears.
READER_DISPATCH='[[ -n "$LANE_ARG" ]] || die missing-value check'
READER_BODY='read_usage_cache "$HARNESS" "$LANE_ARG" "$(date +%s)" ""; exit $?'
state="$TMP_ROOT/reader-state"
cache_run "$state" ORCH_LANE_EXCLUDE= list --json --no-cache > "$TMP_ROOT/out"
reader_dir="$(mutant_scripts reader lanes)"
mutate_file "$reader_dir/lanes" "$READER_DISPATCH" "$READER_BODY"
ORIGINAL_LANES="$LANES"
LANES="$reader_dir/lanes"
for row in "claude|$H/.claude" "host-accounts|$PROVIDER"; do
  IFS='|' read -r harness account <<<"$row"
  for policy in ORCH_LANE_EXCLUDE=claude ORCH_LANE_RETIRE=claude=2000-01-01; do
    rc=0
    cache_run "$state" "$policy" check --harness "$harness" "$account" > "$TMP_ROOT/out" || rc=$?
    assert_eq "$rc:$(cat "$TMP_ROOT/out")" '1:' "$harness reader refuses $policy before discovery"
  done
done
LANES="$ORIGINAL_LANES"

# Each rule has its own control. A lane record is refused by the policy
# matchers: each control keeps the parser and the matcher running and flips
# the matcher's verdict to "no match", so the very same cached body is served.
# A provider record is refused by its policy stamp: that control keeps the
# compare and makes it always agree.
policy_control() { # NAME MATCH REPLACEMENT POLICY HARNESS ACCOUNT
  local name="$1" match="$2" replacement="$3" policy="$4" harness="$5" account="$6" control_dir rc
  control_dir="$(mutant_scripts "control-$name" lanes)"
  mutate_file "$control_dir/lanes" "$match" "$replacement"
  mutate_file "$control_dir/lanes" "$READER_DISPATCH" "$READER_BODY"
  LANES="$control_dir/lanes"
  rc=0
  cache_run "$state" "$policy" check --harness "$harness" "$account" > "$TMP_ROOT/out" || rc=$?
  assert_eq "$rc:$(jq -r 'has("usage")' "$TMP_ROOT/out")" '0:true' \
    "control: disabling $name makes the $harness refusal assertion fail"
  LANES="$ORIGINAL_LANES"
}
policy_control exclude 'lane_matches "$name" "$1" && return 0' \
  'lane_matches "$name" "$1" && return 1' ORCH_LANE_EXCLUDE=claude claude "$H/.claude"
policy_control retire '[[ -n "$date" && ! "$TODAY" < "$date" ]] || return 1' \
  '[[ -n "$date" && ! "$TODAY" < "$date" ]]; return 1' ORCH_LANE_RETIRE=claude=2000-01-01 claude "$H/.claude"
STAMP_MATCH='.policy == $policy'
STAMP_REPLACEMENT='.policy == .policy'
for policy in ORCH_LANE_EXCLUDE=claude ORCH_LANE_RETIRE=claude=2000-01-01; do
  policy_control stamp "$STAMP_MATCH" "$STAMP_REPLACEMENT" "$policy" host-accounts "$PROVIDER"
done
# The same stamp control against the lifted-exclusion listing: without the
# stamp the record written under the exclusion is served as the answer.
control_dir="$(mutant_scripts control-stamp lanes)"
mutate_file "$control_dir/lanes" "$STAMP_MATCH" "$STAMP_REPLACEMENT"
LANES="$control_dir/lanes"
cache_run "$TMP_ROOT/lifted-control" ORCH_LANE_EXCLUDE=claude host-accounts --json > "$TMP_ROOT/out"
calls="$(provider_calls)"
cache_run "$TMP_ROOT/lifted-control" ORCH_LANE_EXCLUDE= host-accounts --json > "$TMP_ROOT/out"
assert_eq "$(claude_hosted):$(provider_calls)" "absent:$calls" \
  'control: disabling the stamp makes the lifted-exclusion assertions fail'
LANES="$ORIGINAL_LANES"

# The cleanup assertion must fail if startup still judges every file but
# leaves rejected records on disk. A local read cannot replace the host record.
control_dir="$(mutant_scripts control-prune lanes)"
mutate_file "$control_dir/lanes" 'rm -f -- "$file" && continue' ': "$file" && continue'
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

# The startup scan is skipped only while the `.pruned` marker holds this
# policy and the cache directory is unchanged since it was written; a policy
# change, a day change, a write under any policy and the scan's own deletion
# each send the next process through the scan. The cache-read log counts the
# files the scan judged: `check` reads no record of its own. The records are
# seeded under the first policy, so the first scan deletes nothing. A scan
# that failed leaves no valid marker, so the deletion failure below is
# refused on every run, not the first.
#
# Bash 3.2 compares whole-second mtimes, so a change in the second the
# marker was written is not newer than it. Each row whose claim is a change
# after the marker makes that order explicit: `age-dir` backdates the
# directory before the change, and `age-marker` then dates the marker between
# the two, so the change alone makes the directory newer. A write row takes
# both before its write; a deleting row takes `age-dir` before its run, and
# the row after it `age-marker`, since the scan writes the marker before it
# deletes. Every other row reads real mtimes: a scan row's policy or day
# decides it, and a skip row follows a scan that wrote its marker after the
# directory last changed.
AGED_DIR=200001010000
AGED_MARKER=200101010000
scan_ran() { [[ "$(grep -c '' "$TMP_ROOT/cache-reads" || true)" -gt 0 ]] && printf scanned || printf skipped; }
LANES="$ORIGINAL_LANES"
state="$TMP_ROOT/marker"
cache_run "$state" ORCH_LANE_EXCLUDE=sclaude list --json --no-cache > "$TMP_ROOT/out"
for row in '|ORCH_LANE_EXCLUDE=sclaude||scanned|the first run under a policy scans' \
  '|ORCH_LANE_EXCLUDE=sclaude||skipped|an unchanged directory under the same policy is not scanned again' \
  'age-dir age-marker write|ORCH_LANE_EXCLUDE=sclaude||scanned|a write under another policy sends the next run through the scan' \
  '|ORCH_LANE_EXCLUDE=sclaude||skipped|the scan after that write marks the directory again' \
  'age-dir|ORCH_LANE_EXCLUDE=sclaude,zclaude||scanned|a policy change scans and deletes the provider record' \
  'age-marker|ORCH_LANE_EXCLUDE=sclaude,zclaude||scanned|that deletion sends the next run through the scan once more' \
  '|ORCH_LANE_EXCLUDE=sclaude,zclaude||skipped|the scan after a policy change marks the directory again' \
  '|ORCH_LANE_EXCLUDE=sclaude,zclaude|2099-01-01|scanned|a day change scans' \
  'age-dir|ORCH_LANE_EXCLUDE=claude||scanned|a tightened policy scans and deletes' \
  'age-marker|ORCH_LANE_EXCLUDE=claude||scanned|a deletion sends the next run through the scan once more' \
  '|ORCH_LANE_EXCLUDE=claude||skipped|the scan after a deletion marks the directory again'; do
  IFS='|' read -r prep policy today expected name <<<"$row"
  for step in $prep; do
    case "$step" in
      age-dir) touch -t "$AGED_DIR" "$state/usage" || fail "marker row: cannot backdate $state/usage" ;;
      age-marker) touch -t "$AGED_MARKER" "$state/usage/.pruned" || fail "marker row: cannot backdate $state/usage/.pruned" ;;
      write) cache_run "$state" ORCH_LANE_EXCLUDE= list --local --json --no-cache > "$TMP_ROOT/out" ;;
      *) fail "marker row: unknown prep step $step" ;;
    esac
  done
  : > "$TMP_ROOT/cache-reads"
  FAKE_TODAY="$today" cache_run "$state" "$policy" check "$H/.eclaude" > "$TMP_ROOT/out"
  assert_eq "$(scan_ran)" "$expected" "$name"
done
assert_eq "$(jq -s '[.[] | select(.config_dir | endswith("/.claude"))] | length' "$state"/usage/*.json)" \
  0 'the marked directory holds no record the policy refuses'
# One control per rule the skip reads: the stamp compare made to always agree,
# and the directory compare made to never find it newer. The directory is
# marked under SEED-POLICY, each WRITE-POLICY then writes local records, and
# the exclusion of claude must scan: a mutant that skips leaves the removed
# record on disk, which the cleanup assertion catches.
marker_control() { # NAME MATCH REPLACEMENT SEED-POLICY [WRITE-POLICY...]
  local name="$1" match="$2" replacement="$3" seed="$4" control_dir write state="$TMP_ROOT/marker-$1"
  shift 4
  control_dir="$(mutant_scripts "control-marker-$name" lanes)"
  mutate_file "$control_dir/lanes" "$match" "$replacement"
  LANES="$control_dir/lanes"
  cache_run "$state" "$seed" list --json --no-cache > "$TMP_ROOT/out"
  cache_run "$state" "$seed" check "$H/.eclaude" > "$TMP_ROOT/out"
  for write in "$@"; do
    cache_run "$state" "$write" list --local --json --no-cache > "$TMP_ROOT/out"
  done
  cache_run "$state" ORCH_LANE_EXCLUDE=claude list --local --json > "$TMP_ROOT/out"
  assert_eq "$(jq -s '[.[] | select(.config_dir | endswith("/.claude"))] | length' "$state"/usage/*.json)" \
    1 "control: disabling the marker's $name compare leaves removed local usage on disk"
  LANES="$ORIGINAL_LANES"
}
marker_control stamp '"$stamp" != "$USAGE_POLICY" ||' '"$stamp" != "$stamp" ||' ORCH_LANE_EXCLUDE=sclaude
marker_control directory '"$USAGE_CACHE_DIR" -nt "$marker"' '"$USAGE_CACHE_DIR" -nt "$USAGE_CACHE_DIR"' \
  ORCH_LANE_EXCLUDE=claude ORCH_LANE_EXCLUDE=

state="$TMP_ROOT/deletion"
cache_run "$state" ORCH_LANE_EXCLUDE= list --json --no-cache > "$TMP_ROOT/out"
CACHE_RM_FAIL=1
for attempt in first second; do
  rc=0
  cache_run "$state" ORCH_LANE_EXCLUDE=claude list --local --json > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || rc=$?
  assert_eq "$rc" 1 "a cache deletion failure refuses the command on the $attempt run"
  assert_contains "$(cat "$TMP_ROOT/err")" 'lanes: usage-cache-prune-failed path=' "the $attempt deletion failure names the cache path"
done
control_dir="$(mutant_scripts control-prune-failure lanes)"
mutate_file "$control_dir/lanes" 'die usage-cache-prune-failed "$file"' ': usage-cache-prune-failed "$file"'
LANES="$control_dir/lanes"
rc=0
cache_run "$state" ORCH_LANE_EXCLUDE=claude list --local --json > "$TMP_ROOT/out" || rc=$?
assert_eq "$rc" 0 'control: swallowing deletion failure makes the refusal assertion fail'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
