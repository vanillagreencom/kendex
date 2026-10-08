#!/usr/bin/env bash
# Surface: read_usage_cache. Inputs: lanes, lib/lane-usage.sh,
# lib/lane-model.sh and host_account_rows' provider protocol.
# Endpoint bodies and hosted rows are the shipped cache writer's inputs.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/lanes-fixture.sh"
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo "lanes-cache-reset: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lanes-cache-reset: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lanes-cache-reset: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
LANES="$TEST_DIR/../scripts/lanes"
REAL_DATE="$(command -v date)"
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/repo"
git -C "$TMP_ROOT/repo" init -q -b main
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
cat > "$TMP_ROOT/bin/date" <<'CLOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == +%s ]]; then printf '%s\n' "$FAKE_NOW"; else exec "$REAL_DATE" "$@"; fi
CLOCK
chmod +x "$TMP_ROOT/bin/date"
make_fetcher "$TMP_ROOT/fetch"
CONTROL="$(mutant_scripts reset-control lanes)"
mutate_file "$CONTROL/lanes" '$reset != null and $reset <= $now' 'false and $reset != null and $reset <= $now'
BASE=1790812800

cache_run() { # SCRIPT NOW COMMAND...
  local script="$1" instant="$2"
  shift 2
  (cd "$TMP_ROOT/repo" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$H" REAL_DATE="$REAL_DATE" FAKE_NOW="$instant" \
    LANES_HOME="$H" ORCH_LANE_DIRS="$DIRS" \
    FIXTURE_DIR="$FIXTURE_DIR" ORCH_LANES_FETCH_CMD="$TMP_ROOT/fetch" FETCH_LOG="$H/fetch.log" \
    OVERSEE_WATCH_STATE_DIR="$H/store" ORCH_STATE_DIR="$H/state" \
    ORCH_LANE_HOST="$HOST" LANE_HOST_STUB_ACCOUNTS="$H/accounts" LANE_HOST_STUB_LOG="$H/host.log" \
    "$script" "$@" 2>"$H/err")
}

stage_usage() { # FAMILY BUCKET PCT RESET
  local family="$1" bucket="$2" pct="$3" reset="$4"
  case "$family" in
    claude)
      jq -n --arg b "$bucket" --argjson p "$pct" --arg r "$reset" '
        if $b == "session" then {five_hour: {utilization: $p, resets_at: $r}}
        elif $b == "weekly" then {seven_day: {utilization: $p, resets_at: $r}}
        elif $b == "legacy" then {seven_day_opus: {utilization: $p, resets_at: $r}}
        else {limits: [{kind: "weekly_scoped", percent: 100, resets_at: "2099-01-01T00:00:00Z",
                         scope: {model: {display_name: "Opus"}}},
                       {kind: "weekly_scoped", percent: $p, resets_at: $r,
                         scope: {model: {display_name: "Sonnet"}}}]} end' > "$FIXTURE_DIR/.claude.json"
      ;;
    codex)
      jq -n --argjson p "$pct" --argjson r "$reset" --arg b "$bucket" '
        {rate_limit: {primary_window: {used_percent: $p, reset_at: $r,
          limit_window_seconds: (if $b == "session" then 18000 else 604800 end)}}}' > "$FIXTURE_DIR/.codex.json"
      ;;
    copilot)
      jq -n --argjson p "$pct" --arg r "$reset" '
        {quota_snapshots: {premium_interactions: {entitlement: 100, remaining: (100 - $p)}},
         quota_reset_date_utc: $r}' > "$FIXTURE_DIR/.copilot.json"
      ;;
    host)
      local field="$bucket" harness=claude
      [[ "$bucket" != session ]] || field=session-5h
      [[ "$bucket" != monthly ]] || harness=pi
      printf 'account=%s\tharness=%s\t%s-pct=%s\t%s-resets=%s\n' \
        "$H/.claude" "$harness" "$field" "$pct" "$bucket" "$reset" > "$H/accounts"
      ;;
  esac
}

# name|producer|bucket|share|reset offset from fetch|refetch|caller max-age|script
# The default row fetches 60 seconds before reset and reads 30 seconds after it.
for row in \
  "weekly-default|claude|weekly|100|60|yes||$LANES" \
  "session|claude|session|100|60|yes||$LANES" \
  "non-binding-model|claude|model|20|60|yes||$LANES" \
  "legacy-model|claude|legacy|100|60|yes||$LANES" \
  "fractional-use|claude|weekly|0.1|60|yes||$LANES" \
  "at-reset|claude|weekly|100|90|yes||$LANES" \
  "wider-age|claude|weekly|100|60|yes|1000|$LANES" \
  "future-reset|claude|weekly|100|91|no||$LANES" \
  "zero-use|claude|weekly|0|60|no||$LANES" \
  "unknown-reset|claude|weekly|100|unknown|no||$LANES" \
  "codex-session|codex|session|100|60|yes||$LANES" \
  "codex-weekly|codex|weekly|100|60|yes||$LANES" \
  "codex-fraction|codex|weekly|0.1|60|yes||$LANES" \
  "copilot-monthly|copilot|monthly|100|60|yes||$LANES" \
  "host-session|host|session|100|60|yes||$LANES" \
  "host-weekly|host|weekly|100|60|yes||$LANES" \
  "host-model|host|model|100|60|yes||$LANES" \
  "host-pi-monthly|host|monthly|100|60|yes||$LANES" \
  "host-zero|host|weekly|0|60|no||$LANES" \
  "control-local|claude|weekly|100|60|yes||$CONTROL/lanes" \
  "control-host|host|weekly|100|60|yes||$CONTROL/lanes"; do
  IFS='|' read -r name family bucket pct offset refresh max_age script <<<"$row"
  new_home "$name"
  make_lane "$H" claude
  make_codex_lane "$H/.codex"
  mkdir -p "$H/.copilot"
  printf '{"copilotTokens":"test-token"}\n' > "$H/.copilot/config.json"
  HOST=local
  DIRS="$H/.$family"
  args=(list --json --local --harness "$family")
  if [[ "$family" == host ]]; then
    HOST="$TEST_DIR/fixtures/lane-host"
    args=(host-accounts --json)
    [[ "$bucket" != monthly ]] || args+=(--harness pi)
  fi
  reset=unknown
  if [[ "$offset" != unknown ]]; then
    reset="$(jq -nr --argjson r "$((BASE + offset))" '$r | todate')"
    [[ "$family" != codex ]] || reset="$((BASE + offset))"
    # Claude's endpoint also carries fractional seconds with a UTC offset.
    [[ "$name" != session ]] || reset="${reset%Z}.123456+00:00"
  fi
  stage_usage "$family" "$bucket" "$pct" "$reset"
  cache_run "$script" "$BASE" "${args[@]}" --no-cache > "$H/out"
  assert_eq "$(jq 'length' "$H/out")" 1 "$name seeds a measured account"
  if [[ "$family" == host ]]; then
    calls="$(grep -c accounts "$H/host.log")"
  else
    calls="$(wc -l < "$H/fetch.log" | tr -d ' ')"
  fi
  next_reset="$(jq -nr --argjson r "$((BASE + 1000))" '$r | todate')"
  [[ "$family" != codex ]] || next_reset="$((BASE + 1000))"
  stage_usage "$family" "$bucket" 0 "$next_reset"
  [[ -z "$max_age" ]] || args+=(--max-age "$max_age")
  cache_run "$script" "$((BASE + 90))" "${args[@]}" > "$H/out"
  if [[ "$family" == host ]]; then
    after="$(grep -c accounts "$H/host.log")"
  else
    after="$(wc -l < "$H/fetch.log" | tr -d ' ')"
  fi
  reported=no
  grep '^lanes: usage-cache-reset ' "$H/err" >/dev/null && reported=yes
  got="$after:$reported"
  want="$calls:no"
  [[ "$refresh" != yes ]] || want="$((calls + 1)):yes"
  if [[ "$name" == control-* ]]; then
    assert_eq "$got" "$calls:no" "$name serves the old figure when the reset check is disabled"
    [[ "$got" != "$want" ]] && pass "$name turns the refetch assertion red" || fail "$name did not reach the reset check"
  else
    assert_eq "$got" "$want" "$name refreshes only a consumed bucket whose reset arrived" "$H/err"
    field=weekly_pct
    case "$bucket" in session) field=session_5h_pct ;; model|legacy) field=model_pct ;; monthly) field=monthly_pct ;; esac
    expected="$pct"
    [[ "$refresh" != yes ]] || expected=0
    [[ "$family:$bucket" != claude:model ]] || expected=100
    assert_eq "$(jq -r --arg field "$field" '.[0][$field]' "$H/out")" "$expected" "$name reports the figure selected by the cache read"
  fi
done

# A succession uses the same pick verb. A reset account must regain priority
# over an account that remains busy while both old figures are within the TTL.
new_home pick
make_lane "$H" claude
make_lane "$H" eclaude
HOST=local
DIRS="$H/.claude:$H/.eclaude"
claude_usage 0 100 0 Opus | jq '.seven_day.resets_at = "2026-10-01T00:01:00Z"' > "$FIXTURE_DIR/.claude.json"
claude_usage 0 20 0 Opus | jq '.seven_day.resets_at = "2099-01-01T00:00:00Z"' > "$FIXTURE_DIR/.eclaude.json"
cache_run "$LANES" "$BASE" list --local --harness claude --json --no-cache > "$H/out"
claude_usage 0 0 0 Opus > "$FIXTURE_DIR/.claude.json"
cache_run "$LANES" "$((BASE + 90))" pick --harness claude --json > "$H/out"
assert_eq "$(jq -r '.config_dir' "$H/out")" "$H/.claude" 'pick selects the account whose consumed bucket reset'

# store_usage_refusal retains the figure under usage_fetched_at beside a live
# 429. That fallback must also stop serving it when a consumed bucket resets.
new_home refusal
make_lane "$H" claude
DIRS="$H/.claude"
claude_usage 0 100 0 Opus | jq '.seven_day.resets_at = "2026-10-01T00:01:00Z"' > "$FIXTURE_DIR/.claude.json"
cache_run "$LANES" "$BASE" list --local --harness claude --json --no-cache > "$H/out"
for record in "$H/store/usage"/*.json; do
  jq --argjson at "$((BASE + 90))" '
    .usage_fetched_at = .fetched_at | .fetched_at = $at
    | .refusal = {endpoint: "usage", status: "rate_limited", code: "429",
                  detail: "HTTP 429", expires_at: ($at + 300)}' "$record" > "$record.tmp"
  mv -- "$record.tmp" "$record"
done
cache_run "$LANES" "$((BASE + 90))" list --local --harness claude --json > "$H/out"
assert_eq "$(jq -r '.[0] | "\(.status):\(.weekly_pct):\(.headroom_pct)"' "$H/out")" \
  'rate_limited:null:null' 'a live refusal cannot restore a consumed bucket that reset'
assert_eq "$(wc -l < "$H/fetch.log" | tr -d ' ')" 1 'a bucket reset preserves the live endpoint refusal'
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
