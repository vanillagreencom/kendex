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
    FETCH_LOG="$TMP_ROOT/fetch-log" FETCH_STATUS="${FETCH_STATUS:-200}" FETCH_RETRY_AFTER=300 \
    ORCH_LANES_TOKEN_CMD="$TMP_ROOT/token" ORCH_LANES_CLAUDE_CLIENT_ID=fixture-client TOKEN_LOG="$TMP_ROOT/token-log" TOKEN_STATUS="${TOKEN_STATUS:-400}" \
    OVERSEE_WATCH_STATE_DIR="$state" ORCH_LANE_HOST="$PROVIDER" \
    LANE_HOST_STUB_ACCOUNTS="$TMP_ROOT/accounts" LANE_HOST_STUB_LOG="$TMP_ROOT/provider-log" \
    ${policy[@]+"${policy[@]}"} "$LANES" "$@")
}

# Credit values are from the cached usage body, independently of credentials.
for body in "$FIXTURE_DIR/.claude.json" "$FIXTURE_DIR/.eclaude.json"; do
  jq '.iguana_necktie = {limit_dollars: 50, used_dollars: 20, remaining_dollars: 30, resets_at: "2099-08-01T06:00:00Z", locked_reason: null}' "$body" > "$body.tmp"
  mv "$body.tmp" "$body"
done
cat > "$TMP_ROOT/token" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >> "$TOKEN_LOG"
printf '%s\n{}\n' "$TOKEN_STATUS"
STUB
chmod +x "$TMP_ROOT/token"

cache_only_observed() {
  local fetched tokens providers
  fetched="$(sed 's/^\.//' "$TMP_ROOT/fetch-log" | sort | paste -sd, -)"
  tokens="$(grep -c . "$TMP_ROOT/token-log" || true)"
  providers="$(grep -c accounts "$TMP_ROOT/provider-log" || true)"
  printf '%s fetched=%s tokens=%s providers=%s' "$(jq -r '.[] | select(.alias == "claude") | [.status, (.credits.remaining_dollars | tostring), (.usage_age_s | if . == null then "null" else "number" end), (.session_5h_pct | tostring)] | join(":")' "$TMP_ROOT/out")" "${fetched:-none}" "$tokens" "$providers"
}

# oversee-watch calls this writer after a claimed lane shows the harness's
# weekly-limit banner. Every cache-only row reads beside that same live wall.
stage_cache_wall() { # STATE
  (source "$TEST_DIR/../scripts/lib/lane-claims.sh" && source "$TEST_DIR/../scripts/lib/account-wall.sh" \
    && OVERSEE_WATCH_STATE_DIR="$1" account_wall_record "" "$H/.claude" "$WALL_UNTIL" "$WALL_NOW" \
      "$ACCOUNT_WALL_DRAWN""You've hit your weekly limit") \
    && compgen -G "$1/walls/*.json" >/dev/null \
    || { echo "stage_cache_wall: no wall record under $1" >&2; exit 1; }
}
WALL_NOW="$(date +%s)"
WALL_UNTIL=$((WALL_NOW + 86400))
WALL_RESET="$(jq -nr --argjson at "$WALL_UNTIL" '$at | todate')"

cache_only_windows() { # empty|figure
  jq -r --arg kind "$1" --arg s "$CLAUDE_USAGE_SESSION_RESET" --arg w "$WALL_RESET" '
    .[] | select(.alias == "claude")
    | if $kind == "empty" then
        ([.session_5h_pct, .weekly_pct, .model_pct, .monthly_pct, .headroom_pct,
          .binding_bucket, .binding_resets_at, .model_label] | all(. == null))
        and .model_buckets == [] and .credits == null
        and .resets == {session: null, weekly: null, model: null, monthly: null}
      else
        .session_5h_pct == 10 and .weekly_pct == 100 and .model_pct == 5
        and .monthly_pct == null and .headroom_pct == 0
        and .model_label == "Opus"
        and .model_buckets == [{label: "Opus", pct: 5, resets_at: "2099-08-01T06:00:00Z"}]
        and (.credits | del(.measured_at)) == {unit: "usd", limit_dollars: 50, used_dollars: 20,
          remaining_dollars: 30, resets_at: "2099-08-01T06:00:00Z", locked_reason: null}
        and .binding_bucket == "weekly" and .binding_resets_at == $w
        and .resets == {session: $s, weekly: $w, model: "2099-08-01T06:00:00Z", monthly: null}
      end' "$TMP_ROOT/out"
}

for row in 'fresh||ok:30:number:10' 'stale||unreachable:null:null:null' \
  'widened|--max-age 900|ok:30:number:10' 'ttl-zero||unreachable:null:null:null' \
  'reset||unreachable:null:null:null' 'refused||refused:null:number:null' \
  'token-refused||expired:null:number:null' 'expired||ok:30:number:10' \
  'fresh-token-400||expired:null:number:null' 'fresh-token-403||expired:null:number:null' \
  'fresh-usage-403||refused:null:number:null' 'fresh-usage-429||rate_limited:30:number:10' \
  'ttl-zero-429||rate_limited:30:number:10' 'stale-429||rate_limited:30:number:10' \
  'reset-429||rate_limited:null:number:null' 'old-429||rate_limited:null:number:null' \
  'cold-429||rate_limited:null:number:null' \
  'missing-credentials||ok:30:number:10' 'absent||unreachable:null:null:null'; do
  IFS='|' read -r name args expected <<<"$row"
  state="$TMP_ROOT/cache-only-$name"
  make_lane "$H" claude
  cache_run "$state" '' list --local --json --no-cache > "$TMP_ROOT/out"
  policy=ORCH_LANES_USAGE_TTL=300
  case "$name" in
    stale|widened) age_usage_record "$state" "$H/.claude" 600 ;;
    ttl-zero) policy=ORCH_LANES_USAGE_TTL=0 ;;
    reset|reset-429)
      for record in "$state"/usage/*.json; do
        jq '.usage.five_hour.resets_at = "2000-01-01T00:00:00Z"' "$record" > "$record.tmp"
        mv "$record.tmp" "$record"
      done ;;
    refused|token-refused)
      age_usage_record "$state" "$H/.claude" 600
      ;;
    ttl-zero-429) policy=ORCH_LANES_USAGE_TTL=0 ;;
    stale-429) age_usage_record "$state" "$H/.claude" 600 ;;
    old-429) age_usage_record "$state" "$H/.claude" 18001 ;;
    cold-429) rm -- "${state:?}"/usage/*.json ;;
    expired) make_lane "$H" claude -3600 ;;
    missing-credentials) rm -- "${H:?}/.claude/.credentials.json" ;;
    absent) rm -- "${state:?}"/usage/*.json ;;
  esac
  # Normal measurement is the producer of both refusal kinds. Its shipped
  # writers keep the last figure beside token renewal or usage HTTP failures.
  code=""
  case "$name" in
    token-refused|fresh-token-400|fresh-token-403)
      code=400; [[ "$name" != fresh-token-403 ]] || code=403
      make_lane "$H" claude -3600
      TOKEN_STATUS="$code" cache_run "$state" '' list --local --json --no-cache > "$TMP_ROOT/out" ;;
    refused|fresh-usage-403|*-429)
      code=403; [[ "$name" != *-429 ]] || code=429
      FETCH_STATUS="$code" cache_run "$state" '' list --local --json --no-cache > "$TMP_ROOT/out" ;;
  esac
  stage_cache_wall "$state"
  : > "$TMP_ROOT/fetch-log"; : > "$TMP_ROOT/token-log"; : > "$TMP_ROOT/provider-log"
  # args contains only the literal --max-age row above.
  cache_run "$state" "$policy" list --cache-only --json $args > "$TMP_ROOT/out"
  assert_eq "$(cache_only_observed)" "$expected fetched=none tokens=0 providers=0" "cache-only $name uses only its record"
  windows=empty; [[ "$expected" != *:10 ]] || windows=figure
  assert_eq "$(cache_only_windows "$windows")" true "cache-only $name reports every window, reset and headroom"
  [[ -z "$code" ]] || assert_contains "$(jq -r '.[] | select(.alias == "claude") | .detail' "$TMP_ROOT/out")" "HTTP $code" "cache-only $name preserves the refusal cause"
done
make_lane "$H" claude

# Each endpoint prevention rule has a control that reaches its own stub.
original_lanes="$LANES"
for rule in fetch token provider; do
  state="$TMP_ROOT/cache-only-control-$rule-state"
  cache_run "$state" '' list --local --json --no-cache > "$TMP_ROOT/out"
  control_dir="$(mutant_scripts "cache-only-control-$rule" lanes)"
  expected='ok:30:number:10 fetched=none tokens=0 providers=0'
  case "$rule" in
    fetch)
      age_usage_record "$state" "$H/.claude" 600
      mutate_file "$control_dir/lanes" $'if [[ "$CACHE_ONLY" == true ]]; then\n\t\t\tstatus=unreachable' $'if [[ "$CACHE_ONLY" == false ]]; then\n\t\t\tstatus=unreachable'
      expected='unreachable:null:null:null fetched=none tokens=0 providers=0' ;;
    token)
      make_lane "$H" claude -3600
      mutate_file "$control_dir/lanes" $'if [[ "$CACHE_ONLY" != true ]]; then\n\t\tif [[ "$harness" == pi ]]' $'if [[ "$CACHE_ONLY" == true ]]; then\n\t\tif [[ "$harness" == pi ]]' ;;
    provider)
      mutate_file "$control_dir/lanes" 'CACHE_ONLY=true; LOCAL_ONLY=true; shift' 'CACHE_ONLY=true; LOCAL_ONLY=false; shift' ;;
  esac
  LANES="$control_dir/lanes"
  : > "$TMP_ROOT/fetch-log"; : > "$TMP_ROOT/token-log"; : > "$TMP_ROOT/provider-log"
  cache_run "$state" ORCH_LANES_USAGE_TTL=300 list --cache-only --json > "$TMP_ROOT/out"
  rc=0
  ( FAIL=0; assert_eq "$(cache_only_observed)" "$expected" 'cache-only endpoints'; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/cache-only-control-$rule.log" || rc=$?
  assert_eq "$rc" 1 "cache-only row rejects the $rule endpoint control"
  case "$rule" in
    fetch) assert_eq "$(grep -c . "$TMP_ROOT/fetch-log" || true)" 1 'fetch control reaches the stale account usage endpoint' ;;
    token) assert_eq "$(grep -c . "$TMP_ROOT/token-log" || true)" 1 'token control reaches the expired account token endpoint' ;;
    provider) assert_eq "$(grep -c accounts "$TMP_ROOT/provider-log" || true)" 1 'provider control reaches the accounts endpoint' ;;
  esac
  LANES="$original_lanes"
  make_lane "$H" claude
done

# Each new refusal priority and the empty-window rule is independently
# disabled. The same shipped writers and row observers must reject it.
for rule in wall token-priority usage-priority; do
  state="$TMP_ROOT/cache-only-control-$rule-state"
  cache_run "$state" '' list --local --json --no-cache > "$TMP_ROOT/out"
  control_dir="$(mutant_scripts "cache-only-control-$rule" lanes)"
  case "$rule" in
    wall)
      rm -- "${state:?}"/usage/*.json
      mutate_file "$control_dir/lanes" 'if [[ "$CACHE_ONLY" != true || "$buckets" != '\''{}'\'' ]]; then' 'if true; then'
      expected='unreachable:null:null:null fetched=none tokens=0 providers=0' ;;
    token-priority)
      make_lane "$H" claude -3600
      TOKEN_STATUS=400 cache_run "$state" '' list --local --json --no-cache > "$TMP_ROOT/out"
      mutate_file "$control_dir/lanes" 'if [[ "$CACHE_ONLY" == true ]] && refusal=' 'if [[ "$CACHE_ONLY" == false ]] && refusal='
      expected='expired:null:number:null fetched=none tokens=0 providers=0' ;;
    usage-priority)
      FETCH_STATUS=403 cache_run "$state" '' list --local --json --no-cache > "$TMP_ROOT/out"
      mutate_file "$control_dir/lanes" '"$USE_CACHE" == "true" && -z "$refusal"' '"$USE_CACHE" == "true"'
      expected='refused:null:number:null fetched=none tokens=0 providers=0' ;;
  esac
  stage_cache_wall "$state"
  LANES="$control_dir/lanes"
  : > "$TMP_ROOT/fetch-log"; : > "$TMP_ROOT/token-log"; : > "$TMP_ROOT/provider-log"
  cache_run "$state" '' list --cache-only --json > "$TMP_ROOT/out"
  rc=0
  ( FAIL=0
    assert_eq "$(cache_only_observed)" "$expected" 'cache-only recorded answer'
    assert_eq "$(cache_only_windows empty)" true 'cache-only empty windows'
    [[ "$FAIL" == 0 ]]
  ) > "$TMP_ROOT/cache-only-control-$rule.log" || rc=$?
  assert_eq "$rc" 1 "cache-only row rejects the $rule control"
  LANES="$original_lanes"
  make_lane "$H" claude
done

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
# unchanged; the `check` verb's first step runs settings validation with startup
# pruning disabled, so the reader alone decides whether to serve the record.
# The settings parser must populate the policy arrays before this read. It owns the
# argv: `check` takes one directory, and --harness names the record's harness.
# The state dir is named apart from every mutant, which mutant_scripts clears.
READER_DISPATCH='[[ -n "$LANE_ARG" ]] || die missing-value check'
READER_BODY='prune_usage_cache() { :; }; validate_lane_settings; read_usage_cache "$HARNESS" "$LANE_ARG" "$(date +%s)" ""; exit $?'
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
policy_control retire '[[ -n "$LANE_RETIRE_DATE" && ! "$TODAY" < "$LANE_RETIRE_DATE" ]] || return 1' \
  '[[ -n "$LANE_RETIRE_DATE" && ! "$TODAY" < "$LANE_RETIRE_DATE" ]]; return 1' ORCH_LANE_RETIRE=claude=2000-01-01 claude "$H/.claude"
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
# deletes. `fresh` gives the directory the marker's mtime, so policy and day
# rows prove their own trigger and skip rows judge an unchanged directory.
AGED_DIR=200001010000
AGED_MARKER=200101010000
scan_ran() { [[ "$(grep -c '' "$TMP_ROOT/cache-reads" || true)" -gt 0 ]] && printf scanned || printf skipped; }
LANES="$ORIGINAL_LANES"
state="$TMP_ROOT/marker"
cache_run "$state" ORCH_LANE_EXCLUDE=sclaude list --json --no-cache > "$TMP_ROOT/out"
for row in 'age-marker|ORCH_LANE_EXCLUDE=sclaude||scanned|the first run under a policy scans' \
  'fresh|ORCH_LANE_EXCLUDE=sclaude||skipped|an unchanged directory under the same policy is not scanned again' \
  'age-dir age-marker write|ORCH_LANE_EXCLUDE=sclaude||scanned|a write under another policy sends the next run through the scan' \
  'fresh|ORCH_LANE_EXCLUDE=sclaude||skipped|the scan after that write marks the directory again' \
  'age-dir|ORCH_LANE_EXCLUDE=sclaude,zclaude||scanned|a policy change scans and deletes the provider record' \
  'age-marker|ORCH_LANE_EXCLUDE=sclaude,zclaude||scanned|that deletion sends the next run through the scan once more' \
  'fresh|ORCH_LANE_EXCLUDE=sclaude,zclaude||skipped|the scan after a policy change marks the directory again' \
  'fresh|ORCH_LANE_EXCLUDE=sclaude,zclaude|2099-01-01|scanned|a day change scans' \
  'age-dir|ORCH_LANE_EXCLUDE=claude||scanned|a tightened policy scans and deletes' \
  'age-marker|ORCH_LANE_EXCLUDE=claude||scanned|a deletion sends the next run through the scan once more' \
  'fresh|ORCH_LANE_EXCLUDE=claude||skipped|the scan after a deletion marks the directory again'; do
  IFS='|' read -r prep policy today expected name <<<"$row"
  for step in $prep; do
    case "$step" in
      age-dir) touch -t "$AGED_DIR" "$state/usage" || fail "marker row: cannot backdate $state/usage" ;;
      age-marker) touch -t "$AGED_MARKER" "$state/usage/.pruned" || fail "marker row: cannot backdate $state/usage/.pruned" ;;
      fresh) touch -r "$state/usage/.pruned" "$state/usage" || fail "marker row: cannot date $state/usage" ;;
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
  touch -t "$AGED_DIR" "$state/usage"
  touch -t "$AGED_MARKER" "$state/usage/.pruned"
  for write in "$@"; do
    cache_run "$state" "$write" list --local --json --no-cache > "$TMP_ROOT/out"
  done
  : > "$TMP_ROOT/cache-reads"
  cache_run "$state" ORCH_LANE_EXCLUDE=claude check "$H/.eclaude" > "$TMP_ROOT/out"
  assert_eq "$(scan_ran)" skipped "control: disabling the marker's $name compare defeats the scan assertion"
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
