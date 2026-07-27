#!/usr/bin/env bash
# Tests for the `lanes` helper and open-terminal's --lane wiring (vstack#894).
#
# The network layer is the ONLY impure part of `lanes`, and it is injected via
# ORCH_LANES_FETCH_CMD, so every assertion here runs offline against fixed
# responses. That is deliberate: a lane chooser tested against live accounts
# would assert whatever today's usage happens to be, which is the "measurement
# quoted for something it was not taken relative to" failure.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
LANES="$REPO_ROOT/skills/orch/scripts/lanes"
OPEN_TERMINAL="$REPO_ROOT/skills/orch/scripts/open-terminal"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then pass "$name"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"; fi
}

assert_contains() {
  local hay="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$hay"; then pass "$name"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        wanted: %s\n        in: %s\n' "$name" "$needle" "$hay"; fi
}

# A fake home with N claude lanes plus a codex lane. `expires_in_s` lets a lane
# be given an already-expired token.
make_lane() {
  local home="$1" name="$2" expires_in_s="${3:-3600}" plan="${4:-max}"
  local dir="$home/.$name"
  mkdir -p "$dir"
  local exp=$(( ($(date +%s) + expires_in_s) * 1000 ))
  jq -n --arg at "token-$name" --arg rt "refresh-$name" --argjson exp "$exp" --arg plan "$plan" \
    '{claudeAiOauth: {accessToken: $at, refreshToken: $rt, expiresAt: $exp, subscriptionType: $plan}}' \
    > "$dir/.credentials.json"
}

make_codex_lane() {
  local dir="$1"
  mkdir -p "$dir"
  jq -n '{tokens: {access_token: "codex-token", account_id: "acct-1"}}' > "$dir/auth.json"
}

# Fetch stub: prints the fixture registered for the config dir it is handed.
make_fetcher() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
# argv: <harness> <config_dir>
f="$FIXTURE_DIR/$(basename "$2").json"
[[ -f "$f" ]] || exit 1
cat "$f"
STUB
  chmod +x "$path"
}

FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"

claude_usage() { # session_pct weekly_pct model_pct model_label
  jq -n --argjson s "$1" --argjson w "$2" --argjson m "$3" --arg lbl "$4" '{
    five_hour: {utilization: $s, resets_at: "2026-07-27T06:00:00Z"},
    seven_day: {utilization: $w, resets_at: "2026-08-01T06:00:00Z"},
    limits: [{kind: "weekly_scoped", percent: $m, resets_at: "2026-08-01T06:00:00Z",
              scope: {model: {display_name: $lbl}}}]
  }'
}

echo "=== enumeration and measurement ==="

H="$TMP_ROOT/home1"; mkdir -p "$H"
export FIXTURE_DIR="$TMP_ROOT/fix1"; mkdir -p "$FIXTURE_DIR"
make_lane "$H" "claude" 3600
make_lane "$H" "eclaude" 3600
make_lane "$H" "nclaude" 3600
mkdir -p "$H/.openclaude"          # a config dir with no credentials at all
claude_usage 10 20 5  "Opus"  > "$FIXTURE_DIR/.claude.json"
claude_usage 80 30 10 "Opus"  > "$FIXTURE_DIR/.eclaude.json"
claude_usage 5  95 12 "Opus"  > "$FIXTURE_DIR/.nclaude.json"

run_lanes() { LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" "$LANES" "$@"; }

OUT="$(run_lanes list --harness claude --json)"
assert_eq "$(jq 'length' <<<"$OUT")" "4" "every candidate config dir is listed"
assert_eq "$(jq -r '.[] | select(.alias=="openclaude") | .status' <<<"$OUT")" "no_credentials" \
  "a config dir with no credentials is reported, not silently dropped"
assert_eq "$(jq -r '.[] | select(.alias=="claude") | .plan' <<<"$OUT")" "max" \
  "the plan is read from the credentials file without a network call"

echo "=== headroom is the binding bucket, not an average ==="

# nclaude: 5% session but 95% weekly. Averaging would call that ~50% free and
# send a fleet straight into the wall the issue describes.
assert_eq "$(jq -r '.[] | select(.alias=="nclaude") | .headroom_pct' <<<"$OUT")" "5" \
  "a low session but high weekly yields low headroom"
assert_eq "$(jq -r '.[] | select(.alias=="eclaude") | .headroom_pct' <<<"$OUT")" "20" \
  "a high session bucket binds when it is the largest"
assert_eq "$(jq -r '.[] | select(.alias=="claude") | .headroom_pct' <<<"$OUT")" "80" \
  "headroom is 100 minus the largest bucket"
assert_eq "$(jq -r '.[] | select(.alias=="claude") | .model_label' <<<"$OUT")" "Opus" \
  "the model-scoped label comes from the API, not a hard-coded name"

echo "=== pick ==="

assert_eq "$(run_lanes pick --harness claude)" "CLAUDE_CONFIG_DIR=$H/.claude" \
  "pick returns the lane with the most headroom as a launch env prefix"
assert_eq "$(run_lanes pick --harness claude --json | jq -r '.alias')" "claude" \
  "pick --json returns the whole lane record"

# Fail closed: every lane over the threshold must be an error, not a best-effort
# pick, or the fleet launches into a wall anyway.
run_lanes pick --harness claude --max-pct 15 >/dev/null 2>&1
assert_eq "$?" "3" "pick exits 3 when no lane is under the threshold"
ERR="$(run_lanes pick --harness claude --max-pct 15 2>&1 >/dev/null)"
assert_contains "$ERR" "no claude lane is below 15%" "the refusal says what the threshold was"
assert_contains "$ERR" "nclaude" "the refusal shows the lanes it considered"

# A lane whose token expired is not measurable, and must never be picked.
H2="$TMP_ROOT/home2"; mkdir -p "$H2"
export FIXTURE_DIR="$TMP_ROOT/fix2"; mkdir -p "$FIXTURE_DIR"
make_lane "$H2" "claude" -60
make_lane "$H2" "eclaude" 3600
claude_usage 90 90 90 "Opus" > "$FIXTURE_DIR/.claude.json"
claude_usage 40 40 40 "Opus" > "$FIXTURE_DIR/.eclaude.json"
OUT2="$(LANES_HOME="$H2" ORCH_LANES_FETCH_CMD="$FETCHER" "$LANES" list --harness claude --json)"
assert_eq "$(jq -r '.[] | select(.alias=="claude") | .status' <<<"$OUT2")" "expired" \
  "an expired token is reported as expired"
assert_eq "$(jq -r '.[] | select(.alias=="claude") | .headroom_pct' <<<"$OUT2")" "null" \
  "an unmeasured lane has null headroom, never 100"
assert_eq "$(LANES_HOME="$H2" ORCH_LANES_FETCH_CMD="$FETCHER" "$LANES" pick --harness claude)" \
  "CLAUDE_CONFIG_DIR=$H2/.eclaude" "pick skips an expired lane"

# Refresh is opt-in precisely because it rotates a token other tools share.
assert_contains "$(jq -r '.[] | select(.alias=="claude") | .detail' <<<"$OUT2")" "--refresh" \
  "the expired lane names the opt-in that would fix it"

echo "=== unmeasurable lanes are not treated as idle ==="

H3="$TMP_ROOT/home3"; mkdir -p "$H3"
export FIXTURE_DIR="$TMP_ROOT/fix3"; mkdir -p "$FIXTURE_DIR"
make_lane "$H3" "claude" 3600 "enterprise"
# Authenticates fine, returns a usage object with none of the consumer windows —
# observed on a real enterprise plan.
jq -n '{spend: {}}' > "$FIXTURE_DIR/.claude.json"
OUT3="$(LANES_HOME="$H3" ORCH_LANES_FETCH_CMD="$FETCHER" "$LANES" list --harness claude --json)"
assert_eq "$(jq -r '.[0].status' <<<"$OUT3")" "no_usage_data" \
  "an authenticated lane with no usable window is not reported as ok"
assert_eq "$(jq -r '.[0].headroom_pct' <<<"$OUT3")" "null" \
  "no usable window means null headroom, not 100"
LANES_HOME="$H3" ORCH_LANES_FETCH_CMD="$FETCHER" "$LANES" pick --harness claude >/dev/null 2>&1
assert_eq "$?" "3" "pick refuses rather than choosing an unmeasurable lane"

# An unreachable API is likewise not idle.
H4="$TMP_ROOT/home4"; mkdir -p "$H4"
export FIXTURE_DIR="$TMP_ROOT/fix4"; mkdir -p "$FIXTURE_DIR"   # no fixtures → fetch fails
make_lane "$H4" "claude" 3600
OUT4="$(LANES_HOME="$H4" ORCH_LANES_FETCH_CMD="$FETCHER" "$LANES" list --harness claude --json)"
assert_eq "$(jq -r '.[0].status' <<<"$OUT4")" "unreachable" "a failed usage query is reported as unreachable"
assert_eq "$(jq -r '.[0].headroom_pct' <<<"$OUT4")" "null" "an unreachable lane has null headroom"

echo "=== codex windows route by duration, not by position ==="

# The gotcha this pins: OpenAI's primary/secondary windows do NOT map to
# session/weekly by position. A weekly-only account reports its 7-day limit as
# the PRIMARY window with a null secondary; routing by position labels it "5h"
# and invents a phantom 0% weekly.
H5="$TMP_ROOT/home5"; mkdir -p "$H5"
export FIXTURE_DIR="$TMP_ROOT/fix5"; mkdir -p "$FIXTURE_DIR"
make_codex_lane "$H5/.codex"
jq -n '{rate_limit: {primary_window: {used_percent: 44, reset_at: 1785000000,
                                      limit_window_seconds: 604800},
                     secondary_window: null}}' > "$FIXTURE_DIR/.codex.json"
OUT5="$(CODEX_HOME="$H5/.codex" ORCH_LANES_FETCH_CMD="$FETCHER" "$LANES" list --harness codex --json)"
assert_eq "$(jq -r '.[0].weekly_pct' <<<"$OUT5")" "44" \
  "a 7-day primary window fills the weekly slot"
assert_eq "$(jq -r '.[0].session_5h_pct' <<<"$OUT5")" "null" \
  "a missing session window stays null rather than a phantom 0%"
assert_eq "$(jq -r '.[0].headroom_pct' <<<"$OUT5")" "56" "codex headroom uses the window it actually has"

# And the ordinary two-window case still routes correctly.
jq -n '{rate_limit: {primary_window: {used_percent: 30, reset_at: 1785000000, limit_window_seconds: 18000},
                     secondary_window: {used_percent: 70, reset_at: 1785600000, limit_window_seconds: 604800}}}' \
  > "$FIXTURE_DIR/.codex.json"
OUT6="$(CODEX_HOME="$H5/.codex" ORCH_LANES_FETCH_CMD="$FETCHER" "$LANES" list --harness codex --json)"
assert_eq "$(jq -r '.[0].session_5h_pct' <<<"$OUT6")" "30" "a 5h window fills the session slot"
assert_eq "$(jq -r '.[0].weekly_pct' <<<"$OUT6")" "70" "a 7d window fills the weekly slot"
assert_eq "$(jq -r '.[0].headroom_pct' <<<"$OUT6")" "30" "the larger bucket binds"

echo "=== argument handling ==="

"$LANES" pick --harness bogus >/dev/null 2>&1
assert_eq "$?" "1" "an unknown harness is rejected"
"$LANES" bogus >/dev/null 2>&1
assert_eq "$?" "1" "an unknown subcommand is rejected"
"$LANES" list --max-pct 999x >/dev/null 2>&1
assert_eq "$?" "1" "a malformed --max-pct is rejected"

echo "=== open-terminal --lane wiring ==="

# Assert against what a user actually sees, not against a parse of the source.
HELP_OUT="$("$OPEN_TERMINAL" --help 2>&1)"
assert_contains "$HELP_OUT" "--lane <spec>" "open-terminal --help documents --lane"
assert_contains "$HELP_OUT" "--lane-max-pct" "open-terminal --help documents the threshold flag"

# The lane must resolve BEFORE any worktree is created: discovering "every
# account is full" after spawning worktrees has already done the expensive half.
lane_line=$(grep -n 'LANES_CLI" pick' "$OPEN_TERMINAL" | head -1 | cut -d: -f1)
loop_line=$(grep -n 'for raw in "\${ITEMS\[@\]}"' "$OPEN_TERMINAL" | head -1 | cut -d: -f1)
if [[ -n "$lane_line" && -n "$loop_line" ]] && (( lane_line < loop_line )); then
  pass "the lane is resolved before the launch loop creates worktrees"
else
  fail "the lane is resolved before the launch loop creates worktrees (lane=$lane_line loop=$loop_line)"
fi

# A refusal from `lanes` must stop the launch entirely.
assert_contains "$(cat "$OPEN_TERMINAL")" "nothing was launched" \
  "open-terminal says nothing was launched when no lane qualifies"
assert_contains "$(cat "$OPEN_TERMINAL")" 'cmd="env $LANE_ENV $cmd"' \
  "the chosen lane is applied to the launched command as an env prefix"

# An explicit lane that is not a directory is a typo, not a config dir.
set +e
bogus_out=$("$OPEN_TERMINAL" --harness claude --lane /nonexistent/lane CC-1 2>&1)
bogus_rc=$?
set -e
assert_eq "$bogus_rc" "1" "an explicit --lane that is not a directory is refused"
assert_contains "$bogus_out" "not a directory" "the refusal explains what --lane accepts"
if grep -qF "Opened" <<<"$bogus_out"; then
  fail "a refused --lane launches nothing"
else
  pass "a refused --lane launches nothing"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
