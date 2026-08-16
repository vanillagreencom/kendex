#!/usr/bin/env bash
# Tests for the `lanes` helper and open-terminal's --lane wiring (vstack#894).
#
# The network layer is the ONLY impure part of `lanes`, and it is injected via
# ORCH_LANES_FETCH_CMD, so every assertion here runs offline against fixed
# responses. That is deliberate: a lane chooser tested against live accounts
# would assert whatever today's usage happens to be, which is the "measurement
# quoted for something it was not taken relative to" failure.
set -uo pipefail

# Resolve siblings from the TEST directory, never from a repo root: the CLI
# integration check runs this same suite from an INSTALLED layout
# (.agents/skills/orch/tests/...), where a `<root>/skills/orch/...` path does not
# exist. Same reason the sibling open-terminal test does it this way.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
LANES="$SCRIPTS_DIR/lanes"
OPEN_TERMINAL="$SCRIPTS_DIR/open-terminal"

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

echo "=== the inventory is discovered; aliases are only an overlay ==="

# Discovery must keep finding every account with no configuration at all — a
# hand-maintained lane list is the thing this deliberately does not have.
NO_ALIAS="$(run_lanes list --harness claude --json)"
assert_eq "$(jq -r '[.[].alias] | sort | join(",")' <<<"$NO_ALIAS")" "claude,eclaude,nclaude,openclaude" \
  "with no aliases configured, every discovered lane keeps its directory name"

run_lanes_aliased() { LANES_HOME="$H" ORCH_LANE_ALIASES="$1" ORCH_LANES_FETCH_CMD="$FETCHER" "$LANES" "${@:2}"; }

ALIASED="$(run_lanes_aliased "eclaude=work, nclaude = overflow" list --harness claude --json)"
assert_eq "$(jq -r '.[] | select(.config_dir | endswith("/.eclaude")) | .alias' <<<"$ALIASED")" "work" \
  "an alias renames the lane it names"
assert_eq "$(jq -r '.[] | select(.config_dir | endswith("/.nclaude")) | .alias' <<<"$ALIASED")" "overflow" \
  "surrounding whitespace in the pair list is tolerated"
assert_eq "$(jq -r '.[] | select(.config_dir | endswith("/.claude")) | .alias' <<<"$ALIASED")" "claude" \
  "a lane with no mapping keeps its discovered name"
assert_eq "$(jq 'length' <<<"$ALIASED")" "4" "aliasing changes labels only — no lane is added or dropped"

# An alias for a directory that does not exist must be inert, never conjure a
# lane: the inventory is what discovery found, and nothing else.
GHOST="$(run_lanes_aliased "notthere=phantom" list --harness claude --json)"
assert_eq "$(jq 'length' <<<"$GHOST")" "4" "an alias naming no discovered directory adds no lane"
assert_eq "$(jq -r '[.[].alias] | index("phantom") // "absent"' <<<"$GHOST")" "absent" \
  "an alias naming no discovered directory is inert"

# Measurement must be untouched by relabeling — headroom comes from the API
# response, not from what the lane is called.
assert_eq "$(jq -r '.[] | select(.alias=="work") | .headroom_pct' <<<"$ALIASED")" \
  "$(jq -r '.[] | select(.alias=="eclaude") | .headroom_pct' <<<"$NO_ALIAS")" \
  "an alias does not change the lane's measured headroom"

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

echo "=== in-flight lane claims ==="

# `open-terminal` records one claim per lane window it launches under a
# resolved lane; a claim is live while its pane is. Usage numbers lag a launch
# by minutes, so without this a second `pick` re-reads the same numbers and
# hands one account the whole fleet.
CLAIM_BIN="$TMP_ROOT/claim-bin"; mkdir -p "$CLAIM_BIN"
cat > "$CLAIM_BIN/tmux" <<'STUBEOF'
#!/usr/bin/env bash
# list-panes -a -F '<server pid> <pane id>' → the lines of $TMUX_PANES_FILE
[[ "${1:-}" == "list-panes" && -f "${TMUX_PANES_FILE:-}" ]] && cat "$TMUX_PANES_FILE"
exit 0
STUBEOF
chmod +x "$CLAIM_BIN/tmux"

CLAIM_STATE="$TMP_ROOT/claim-state"
PANES="$TMP_ROOT/panes.txt"
LIVE_PID="$$"
# Above pid_max on every platform this runs on (2^22 on Linux, 99999 on
# macOS), so `kill -0` can never find it: a tmux server provably gone.
DEAD_PID=2147483647
printf '%s %%1\n%s %%2\n' "$LIVE_PID" "$LIVE_PID" > "$PANES"
export FIXTURE_DIR="$TMP_ROOT/fix1"

write_claim() { # <name> <server pid> <pane id> <config dir> <window>
  mkdir -p "$CLAIM_STATE/claims"
  printf '%s\t%s\t%s\t%s\t2026-08-16T00:00:00Z\n' "$2" "$3" "$4" "$5" > "$CLAIM_STATE/claims/$1.claim"
}
run_lanes_claims() {
  LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" OVERSEE_WATCH_STATE_DIR="$CLAIM_STATE" \
    TMUX_PANES_FILE="$PANES" PATH="$CLAIM_BIN:$PATH" "$LANES" "$@"
}

rm -rf "$CLAIM_STATE"
NOCLAIMS="$(run_lanes_claims list --harness claude --json)"
assert_eq "$(jq -r '.[] | select(.alias=="claude") | .claims' <<<"$NOCLAIMS")" "0" \
  "a lane with no live claim counts 0"
assert_eq "$(run_lanes_claims pick --harness claude)" "CLAUDE_CONFIG_DIR=$H/.claude" \
  "with nothing in flight, pick still takes the most headroom"

write_claim one "$LIVE_PID" "%1" "$H/.claude" "vst-1"
CLAIMED="$(run_lanes_claims list --harness claude --json)"
assert_eq "$(jq -r '.[] | select(.alias=="claude") | .claims' <<<"$CLAIMED")" "1" \
  "a live claim is counted against its lane"
assert_eq "$(jq -r '.[] | select(.alias=="eclaude") | .claims' <<<"$CLAIMED")" "0" \
  "a claim counts against one lane only"
assert_contains "$(run_lanes_claims list --harness claude)" "CLAIMS" \
  "the table reports the claim count"

# The behaviour this exists for: a launch already in flight moves pick off the
# account with the most headroom, whose numbers have not caught up with it.
assert_eq "$(run_lanes_claims pick --harness claude)" "CLAUDE_CONFIG_DIR=$H/.eclaude" \
  "pick prefers the lane with nothing in flight over the one with more headroom"

# Claims only order the lanes that already qualify; they never buy one past
# the usage threshold.
run_lanes_claims pick --harness claude --max-pct 15 >/dev/null 2>&1
assert_eq "$?" "3" "a claimed lane does not lower the threshold for the rest"

write_claim two "$LIVE_PID" "%2" "$H/.eclaude" "vst-2"
assert_eq "$(run_lanes_claims pick --harness claude)" "CLAUDE_CONFIG_DIR=$H/.claude" \
  "with claims tied, headroom breaks the tie"

# A claim whose pane is gone is pruned on read: a finished lane must not hold
# its account out of the fleet forever.
printf '%s %%2\n' "$LIVE_PID" > "$PANES"
PRUNED="$(run_lanes_claims list --harness claude --json)"
assert_eq "$(jq -r '.[] | select(.alias=="claude") | .claims' <<<"$PRUNED")" "0" \
  "a claim whose pane is gone stops counting"
assert_eq "$([[ -f "$CLAIM_STATE/claims/one.claim" ]] && echo yes || echo no)" "no" \
  "the dead claim file is removed, not merely ignored"
assert_eq "$([[ -f "$CLAIM_STATE/claims/two.claim" ]] && echo yes || echo no)" "yes" \
  "a live claim survives the prune"

# Pane ids restart at %0 on a new tmux server, so the server pid is half the
# liveness key: without it a claim outliving its server matches a stranger.
rm -f "$CLAIM_STATE"/claims/*.claim
write_claim stale "$DEAD_PID" "%2" "$H/.eclaude" "vst-2"
assert_eq "$(jq -r '.[] | select(.alias=="eclaude") | .claims' <<<"$(run_lanes_claims list --harness claude --json)")" "0" \
  "a claim from a dead tmux server never matches a reused pane id"

# `tmux list-panes` sees one server. A claim on another socket — or one this
# process could not enumerate at all — is judged by whether its server still
# runs: deleting what could not be measured would report a busy account free.
rm -f "$CLAIM_STATE"/claims/*.claim
: > "$PANES"
write_claim foreign "$LIVE_PID" "%5" "$H/.claude" "vst-3"
UNSEEN="$(run_lanes_claims list --harness claude --json)"
assert_eq "$(jq -r '.[] | select(.alias=="claude") | .claims' <<<"$UNSEEN")" "1" \
  "a claim this enumeration cannot see still counts while its server runs"
assert_eq "$([[ -f "$CLAIM_STATE/claims/foreign.claim" ]] && echo yes || echo no)" "yes" \
  "an unmeasurable claim is kept, not deleted"

# The same read with the enumeration itself failing, not merely empty.
FAIL_BIN="$TMP_ROOT/fail-bin"; mkdir -p "$FAIL_BIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAIL_BIN/tmux"; chmod +x "$FAIL_BIN/tmux"
BROKEN="$(LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" OVERSEE_WATCH_STATE_DIR="$CLAIM_STATE" \
  PATH="$FAIL_BIN:$PATH" "$LANES" list --harness claude --json)"
assert_eq "$(jq -r '.[] | select(.alias=="claude") | .claims' <<<"$BROKEN")" "1" \
  "a failed pane enumeration does not empty the claim store"
assert_eq "$([[ -f "$CLAIM_STATE/claims/foreign.claim" ]] && echo yes || echo no)" "yes" \
  "a failed enumeration deletes nothing"

# ...and a claim whose server is gone is still pruned when nothing enumerates.
write_claim gone "$DEAD_PID" "%6" "$H/.eclaude" "vst-4"
GONE="$(run_lanes_claims list --harness claude --json)"
assert_eq "$(jq -r '.[] | select(.alias=="eclaude") | .claims' <<<"$GONE")" "0" \
  "a claim whose server is gone is pruned even with nothing to enumerate"
assert_eq "$([[ -f "$CLAIM_STATE/claims/gone.claim" ]] && echo yes || echo no)" "no" \
  "the gone-server claim file is removed"

# One spelling per account: a lane given with a trailing slash, or through a
# symlink, is the same account the inventory discovered — an exact string
# compare would count zero claims for it and stack a second session there.
rm -f "$CLAIM_STATE"/claims/*.claim
printf '%s %%7\n' "$LIVE_PID" > "$PANES"
write_claim slashed "$LIVE_PID" "%7" "$H/.claude/" "vst-5"
assert_eq "$(jq -r '.[] | select(.alias=="claude") | .claims' <<<"$(run_lanes_claims list --harness claude --json)")" "1" \
  "a claim written with a trailing slash counts against the discovered lane"
rm -f "$CLAIM_STATE"/claims/*.claim
ln -sfn "$H/.claude" "$TMP_ROOT/claude-link"
write_claim linked "$LIVE_PID" "%7" "$TMP_ROOT/claude-link" "vst-6"
assert_eq "$(jq -r '.[] | select(.alias=="claude") | .claims' <<<"$(run_lanes_claims list --harness claude --json)")" "1" \
  "a claim written through a symlink counts against the lane it points at"

# An unreadable claim store is not an empty one. Root reads anything, so the
# case cannot run there.
rm -f "$CLAIM_STATE"/claims/*.claim
write_claim keepme "$LIVE_PID" "%7" "$H/.claude" "vst-7"
if [[ "$(id -u)" -eq 0 ]]; then
  printf '  skip  unreadable claim store (running as root)\n'
else
  chmod 000 "$CLAIM_STATE/claims"
  UNREADABLE_ERR="$(run_lanes_claims list --harness claude --json 2>&1 >/dev/null)"
  chmod 755 "$CLAIM_STATE/claims"
  assert_contains "$UNREADABLE_ERR" "is not readable" \
    "an unreadable claim store says so rather than reporting every account free"
  assert_eq "$([[ -f "$CLAIM_STATE/claims/keepme.claim" ]] && echo yes || echo no)" "yes" \
    "an unreadable claim store is never emptied"

  # `list` reports what it measured; `pick` DECIDES, so it refuses rather
  # than reading an unreadable store as "nothing in flight".
  chmod 000 "$CLAIM_STATE/claims"
  UNKNOWN_JSON="$(run_lanes_claims list --harness claude --json 2>/dev/null)"
  UNKNOWN_TABLE="$(run_lanes_claims list --harness claude 2>/dev/null)"
  run_lanes_claims list --harness claude --json >/dev/null 2>&1
  list_rc=$?
  PICK_ERR="$(run_lanes_claims pick --harness claude 2>&1 >/dev/null)"
  pick_rc=$?
  chmod 755 "$CLAIM_STATE/claims"
  assert_eq "$list_rc" "0" "list still reports the lanes it could measure"
  assert_eq "$(jq -r '.[0].claims' <<<"$UNKNOWN_JSON")" "null" \
    "an unreadable store reports claims as unknown, never as zero"
  assert_contains "$UNKNOWN_TABLE" "?" "the table shows the unknown claim count as ?"

  # A single unreadable claim FILE is the same unknown, not an absent claim.
  chmod 755 "$CLAIM_STATE/claims"; chmod 000 "$CLAIM_STATE/claims/keepme.claim"
  ONEBAD_PICK="$(run_lanes_claims pick --harness claude 2>&1 >/dev/null)"
  onebad_rc=$?
  chmod 644 "$CLAIM_STATE/claims/keepme.claim"
  assert_eq "$onebad_rc" "1" "one unreadable claim file is enough for pick to refuse"
  assert_contains "$ONEBAD_PICK" "refusing to pick" "the single-file refusal says what it refused"
  assert_eq "$pick_rc" "1" "pick refuses when in-flight claims cannot be read"
  assert_contains "$PICK_ERR" "refusing to pick" "the refusal says what it refused to do"

  # An unreadable claim FILE is left in place too, and never leaves the
  # previous record's fields standing in for it.
  chmod 000 "$CLAIM_STATE/claims/keepme.claim"
  FILE_ERR="$(run_lanes_claims list --harness claude --json 2>&1 >/dev/null)"
  chmod 644 "$CLAIM_STATE/claims/keepme.claim"
  assert_contains "$FILE_ERR" "cannot read claim" "an unreadable claim file is named on stderr"
  assert_eq "$([[ -f "$CLAIM_STATE/claims/keepme.claim" ]] && echo yes || echo no)" "yes" \
    "an unreadable claim file is left in place"
fi

# A malformed record is not a lane: it is dropped rather than counted forever.
printf 'not-a-pid\t\tstuff\n' > "$CLAIM_STATE/claims/junk.claim"
run_lanes_claims list --harness claude --json >/dev/null
assert_eq "$([[ -f "$CLAIM_STATE/claims/junk.claim" ]] && echo yes || echo no)" "no" \
  "a malformed claim record is dropped on read"

echo "=== argument handling ==="

"$LANES" pick --harness bogus >/dev/null 2>&1
assert_eq "$?" "1" "an unknown harness is rejected"
"$LANES" bogus >/dev/null 2>&1
assert_eq "$?" "1" "an unknown subcommand is rejected"
"$LANES" list --max-pct 999x >/dev/null 2>&1
assert_eq "$?" "1" "a malformed --max-pct is rejected"

echo "=== open-terminal --lane wiring ==="

# open-terminal validates $WORKTREE_CLI before it reaches any lane logic, and a
# fresh checkout has no `.agents` install mirror for it to find. Stub it, so
# these assertions test the lane path instead of the absence of a mirror.
OT_STUB_BIN="$TMP_ROOT/ot-bin"; mkdir -p "$OT_STUB_BIN"
cat > "$OT_STUB_BIN/worktree" <<'STUBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "create" ]] && { d="$(mktemp -d)"; printf '%s\n' "$d"; exit 0; }
exit 0
STUBEOF
cat > "$OT_STUB_BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
# tmux is stubbed so launch-success cases never touch a real tmux server: run
# under a live session (TMUX set), open-terminal's flagless default is tmux
# mode, and an unstubbed launch creates a real window per case. The log is the
# hermeticity proof — every window these cases "create" must appear here.
OT_TMUX_LOG="$TMP_ROOT/lanes.tmux-log"
cat > "$OT_STUB_BIN/tmux" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OT_TMUX_LOG"
# $OT_TMUX_FAIL names one tmux subcommand that fails after logging, so a case
# can leave a window created and claimed while the launch itself fails.
if [[ -n "${OT_TMUX_FAIL:-}" && "${1:-}" == "$OT_TMUX_FAIL" ]]; then
  exit 1
fi
# A server whose pid is this test process: claims recorded against it are
# genuinely live, so `lanes pick` sees them the way it would on a real server.
# $OT_TMUX_PANES counts the windows created; every one is reported by
# list-panes, giving each launch its own pane id.
n=0; [[ -f "${OT_TMUX_PANES:-}" ]] && n="$(cat "$OT_TMUX_PANES")"
case "${1:-}" in
  # `-P -F '#{pid} #{pane_id}'`: the server pid and pane id of the new window,
  # the two halves of a lane claim's liveness key.
  new-window)
    n=$((n + 1)); [[ -z "${OT_TMUX_PANES:-}" ]] || printf '%s' "$n" > "$OT_TMUX_PANES"
    echo "$OT_TMUX_SERVER_PID %$n" ;;
  list-panes)
    i=1; while [[ "$i" -le "$n" ]]; do echo "$OT_TMUX_SERVER_PID %$i"; i=$((i + 1)); done ;;
  list-windows) echo "1" ;;
  display-message) echo "stub" ;;
esac
exit 0
STUBEOF
chmod +x "$OT_STUB_BIN/worktree" "$OT_STUB_BIN/gh" "$OT_STUB_BIN/tmux"
# Every open-terminal launch below runs with the claim store redirected out of
# the repository: a test must never write into the checkout it is testing.
OT_STATE="$TMP_ROOT/ot-state"
OT_TMUX_PANES="$TMP_ROOT/ot-panes"
run_ot() { TMUX=stub,1,0 OT_TMUX_LOG="$OT_TMUX_LOG" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$OT_TMUX_PANES" OVERSEE_WATCH_STATE_DIR="$OT_STATE" PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" "$OPEN_TERMINAL" "$@"; }

# Assert against what a user actually sees, not against a parse of the source.
# --help must work with no git repository in sight. It used to die with git's
# exit 128 and no output at all, because the PROJECT_ROOT command substitution
# failed under `set -e` before argument parsing ever ran.
NOREPO="$TMP_ROOT/norepo"; mkdir -p "$NOREPO"
help_rc=0
HELP_OUT="$( (cd "$NOREPO" && PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
  "$OPEN_TERMINAL" --help) 2>&1 )" || help_rc=$?
assert_eq "$help_rc" "0" "open-terminal --help exits 0 outside a git repository"
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
assert_contains "$(cat "$OPEN_TERMINAL")" 'cmd="env ${LANE_ENV%%=*}=' \
  "the chosen lane is applied to the launched command as an env prefix (value single-quoted)"

# An explicit lane that is not a directory is a typo, not a config dir.
set +e
bogus_out=$(run_ot --harness claude --lane /nonexistent/lane CC-1 2>&1)
bogus_rc=$?
set -e
assert_eq "$bogus_rc" "1" "an explicit --lane that is not a directory is refused"
assert_contains "$bogus_out" "not a directory" "the refusal explains what --lane accepts"
if grep -qF "Opened" <<<"$bogus_out"; then
  fail "a refused --lane launches nothing"
else
  pass "a refused --lane launches nothing"
fi

# A bare word is resolved as a lane alias against the same discovered inventory
# `pick` measures, so a named lane needs no second source of truth.
# GH_ISSUE_PATTERN is pinned here so the assertion tests lane resolution rather
# than whatever issue convention the surrounding checkout happens to configure.
run_ot_aliased() { LANES_HOME="$H" ORCH_LANE_ALIASES="$1" ORCH_LANES_FETCH_CMD="$FETCHER" \
  GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' TMUX=stub,1,0 OT_TMUX_LOG="$OT_TMUX_LOG" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$OT_TMUX_PANES" OVERSEE_WATCH_STATE_DIR="$OT_STATE" \
  PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" "$OPEN_TERMINAL" "${@:2}"; }

set +e
alias_out=$(run_ot_aliased "eclaude=work" --harness claude --lane work --cmd "true" CC-1 2>&1)
alias_rc=$?
set -e
assert_eq "$alias_rc" "0" "--lane <alias> resolves to a discovered lane"
assert_contains "$alias_out" "CLAUDE_CONFIG_DIR=$H/.eclaude" \
  "--lane <alias> launches under the aliased lane's config dir"

set +e
unknown_out=$(run_ot_aliased "eclaude=work" --harness claude --lane nosuchlane --cmd "true" CC-1 2>&1)
unknown_rc=$?
set -e
assert_eq "$unknown_rc" "1" "an unknown --lane alias is refused"
assert_contains "$unknown_out" "known lane alias" "the alias refusal names what it looked for"

# Collision: the caller's cwd holds a directory with the same name as a lane
# alias. Resolving the filesystem first made that directory win, so the fleet
# launched under a config dir nobody configured — silently, since a directory
# that exists raises no error. The alias owns the bare word.
COLLIDE="$TMP_ROOT/collide"; mkdir -p "$COLLIDE/work"
git -C "$COLLIDE" init -q -b main
set +e
collide_out=$( (cd "$COLLIDE" && LANES_HOME="$H" ORCH_LANE_ALIASES="eclaude=work" \
  ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
  TMUX=stub,1,0 OT_TMUX_LOG="$OT_TMUX_LOG" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$OT_TMUX_PANES" OVERSEE_WATCH_STATE_DIR="$OT_STATE" \
  PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
  "$OPEN_TERMINAL" --harness claude --lane work --cmd "true" CC-1) 2>&1 )
collide_rc=$?
set -e
assert_eq "$collide_rc" "0" "--lane <alias> still resolves when a cwd directory shares its name"
assert_contains "$collide_out" "CLAUDE_CONFIG_DIR=$H/.eclaude" \
  "a cwd directory does not shadow the lane alias it collides with"
if grep -qF "CLAUDE_CONFIG_DIR=work" <<<"$collide_out"; then
  fail "the cwd-relative directory is never used as the lane config dir"
else
  pass "the cwd-relative directory is never used as the lane config dir"
fi

# A bare word that no alias claims still resolves as a directory, so the
# alias-first order narrows nothing.
BARE="$TMP_ROOT/bare"; mkdir -p "$BARE/somelane"
git -C "$BARE" init -q -b main
set +e
bare_out=$( (cd "$BARE" && LANES_HOME="$H" ORCH_LANE_ALIASES="eclaude=work" \
  ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
  TMUX=stub,1,0 OT_TMUX_LOG="$OT_TMUX_LOG" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$OT_TMUX_PANES" OVERSEE_WATCH_STATE_DIR="$OT_STATE" \
  PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
  "$OPEN_TERMINAL" --harness claude --lane somelane --cmd "true" CC-1) 2>&1 )
bare_rc=$?
set -e
assert_eq "$bare_rc" "0" "a bare directory name with no matching alias still resolves"
assert_contains "$bare_out" "CLAUDE_CONFIG_DIR=somelane" \
  "the unclaimed bare word falls back to the directory"

# A tmux lane launched under a resolved lane records its claim, so the next
# pick counts the launch before the account's usage numbers move.
rm -rf "$OT_STATE"; rm -f "$OT_TMUX_PANES"
run_ot_aliased "eclaude=work" --harness claude --lane work --cmd "true" CC-2 >/dev/null 2>&1
assert_eq "$(cat "$OT_STATE"/claims/*.claim 2>/dev/null | cut -f3)" "$H/.eclaude" \
  "a tmux launch under a lane records a claim naming that lane's config dir"
assert_eq "$(cat "$OT_STATE"/claims/*.claim 2>/dev/null | cut -f4)" "CC-2" \
  "the claim names the tmux window it belongs to"
assert_eq "$(cat "$OT_STATE"/claims/*.claim 2>/dev/null | cut -f2)" "%1" \
  "the claim carries the pane id that keeps it prunable"

# A launch with no lane resolved records nothing: there is no account to claim.
rm -rf "$OT_STATE"
noclaim_out=$(OVERSEE_WATCH_STATE_DIR="$OT_STATE" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
  TMUX=stub,1,0 OT_TMUX_LOG="$OT_TMUX_LOG" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$OT_TMUX_PANES" \
  PATH="$OT_STUB_BIN:$PATH" \
  WORKTREE_CLI="$OT_STUB_BIN/worktree" "$OPEN_TERMINAL" --harness claude --cmd "true" CC-3 2>&1)
assert_contains "$noclaim_out" "Opened tmux window" "the laneless launch still opened its window"
assert_eq "$(ls -1 "$OT_STATE/claims" 2>/dev/null | wc -l | tr -d '[:space:]')" "0" \
  "a launch with no --lane records no claim"

# `--lane auto` over a batch: the claim each launch records must move the next
# item off that account, or one invocation puts the whole fleet on one lane —
# the failure the claims exist to prevent.
rm -rf "$OT_STATE"; rm -f "$OT_TMUX_PANES"
run_ot_auto() { LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" \
  GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' TMUX=stub,1,0 OT_TMUX_LOG="$OT_TMUX_LOG" \
  OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$OT_TMUX_PANES" OVERSEE_WATCH_STATE_DIR="$OT_STATE" \
  PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" "$OPEN_TERMINAL" "$@"; }
set +e
auto_out=$(run_ot_auto --harness claude --lane auto --cmd "true" CC-4 CC-5 2>&1)
auto_rc=$?
set -e
assert_eq "$auto_rc" "0" "a two-item --lane auto batch launches both items"
assert_eq "$(cat "$OT_STATE"/claims/*.claim 2>/dev/null | cut -f3 | sort -u | wc -l | tr -d '[:space:]')" "2" \
  "a two-item --lane auto batch spreads across two accounts"
assert_contains "$auto_out" "CLAUDE_CONFIG_DIR=$H/.claude" "the first item takes the lane with the most headroom"
assert_contains "$auto_out" "CLAUDE_CONFIG_DIR=$H/.eclaude" "the second item is re-picked onto the unclaimed lane"
assert_contains "$auto_out" "across 2 lanes" \
  "the summary reports the spread rather than attributing every session to the last lane"

# A window that was created and then failed its launch still holds that
# account: the re-pick trigger is an attempted item, never a successful one.
rm -rf "$OT_STATE"; rm -f "$OT_TMUX_PANES"
set +e
partial_out=$(OT_TMUX_FAIL=send-keys run_ot_auto --harness claude --lane auto --cmd "true" CC-8 CC-9 2>&1)
set -e
assert_contains "$partial_out" "CLAUDE_CONFIG_DIR=$H/.eclaude" \
  "a claimed window whose launch failed still moves the next item off that lane"
assert_eq "$(cat "$OT_STATE"/claims/*.claim 2>/dev/null | cut -f3 | sort -u | wc -l | tr -d '[:space:]')" "2" \
  "the failed launch's claim is one of two distinct accounts, not a repeat"

# The summary counts DISTINCT lanes: a batch that returns to a lane it already
# used must not inflate the spread it reports.
rm -rf "$OT_STATE"; rm -f "$OT_TMUX_PANES"
set +e
three_out=$(run_ot_auto --harness claude --lane auto --cmd "true" CC-12 CC-13 CC-14 2>&1)
set -e
assert_contains "$three_out" "across 2 lanes" \
  "a third item returning to a used lane still reports two distinct lanes"

# A claim that could not be written is a batch that can no longer be spread:
# the launch stands, the next item does not go out blind.
rm -rf "$OT_STATE"; rm -f "$OT_TMUX_PANES"
mkdir -p "$OT_STATE/claims"
if [[ "$(id -u)" -eq 0 ]]; then
  printf '  skip  unwritable claim store (running as root)\n'
else
  chmod 555 "$OT_STATE/claims"   # readable (so the pick works), not writable
  set +e
  blind_out=$(run_ot_auto --harness claude --lane auto --cmd "true" CC-15 CC-16 2>&1)
  blind_rc=$?
  set -e
  chmod 755 "$OT_STATE/claims"
  assert_eq "$blind_rc" "1" "a batch whose claim could not be recorded exits nonzero"
  assert_contains "$blind_out" "could not record the lane claim" "the failed write is reported"
  assert_contains "$blind_out" "stopping after 1 launch(es)" \
    "the batch stops instead of stacking the next item blind"
fi

# A claims path that is not a directory at all is a misconfiguration, not an
# empty store: the pick refuses before anything launches.
rm -rf "$OT_STATE"; rm -f "$OT_TMUX_PANES"
mkdir -p "$OT_STATE"
: > "$OT_STATE/claims"
set +e
notdir_out=$(run_ot_auto --harness claude --lane auto --cmd "true" CC-19 2>&1)
notdir_rc=$?
set -e
rm -f "$OT_STATE/claims"
assert_eq "$notdir_rc" "1" "a non-directory claims path refuses the launch"
assert_contains "$notdir_out" "is not a directory" "the refusal names what is wrong"
assert_contains "$notdir_out" "nothing was launched" "nothing is launched on an unreadable store"

# A lane picked for an item that turns out to be owned by another session
# never carried a session, and must not appear in the spread the summary
# reports. The worktree stub refuses the second item the way `create` does.
OWNED_STUB="$TMP_ROOT/worktree-owned"
cat > "$OWNED_STUB" <<'STUBEOF'
#!/usr/bin/env bash
# `create <item>`: the first item gets a tree, every later one is owned.
[[ "${1:-}" == "create" ]] || exit 0
n=0; [[ -f "$OWNED_COUNT" ]] && n="$(cat "$OWNED_COUNT")"
n=$((n + 1)); printf '%s' "$n" > "$OWNED_COUNT"
[[ "$n" -eq 1 ]] || exit 75
d="$(mktemp -d)"; printf '%s\n' "$d"
STUBEOF
chmod +x "$OWNED_STUB"
rm -rf "$OT_STATE"; rm -f "$OT_TMUX_PANES" "$TMP_ROOT/owned-count"
set +e
owned_out=$(LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" OWNED_COUNT="$TMP_ROOT/owned-count" \
  GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' TMUX=stub,1,0 OT_TMUX_LOG="$OT_TMUX_LOG" \
  OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$OT_TMUX_PANES" OVERSEE_WATCH_STATE_DIR="$OT_STATE" \
  PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OWNED_STUB" \
  "$OPEN_TERMINAL" --harness claude --lane auto --cmd "true" CC-17 CC-18 2>&1)
set -e
assert_contains "$owned_out" "on lane CLAUDE_CONFIG_DIR=$H/.claude" \
  "a lane picked for an owned item is not counted as one the batch ran on"
assert_contains "$owned_out" "skipped 1 (owned by another session)" "the owned item is still skipped"

# A GUI launch has no pane to keep a claim alive, so a GUI batch records
# nothing and stays on the lane resolved up front — as `--help` says.
cat > "$OT_STUB_BIN/ghostty" <<'STUBEOF'
#!/usr/bin/env bash
exit 0
STUBEOF
chmod +x "$OT_STUB_BIN/ghostty"
rm -rf "$OT_STATE"; rm -f "$OT_TMUX_PANES"
set +e
gui_out=$(run_ot_auto --ghostty --harness claude --lane auto --cmd "true" CC-10 CC-11 2>&1)
gui_rc=$?
set -e
assert_eq "$gui_rc" "0" "a GUI batch launches"
assert_eq "$(ls -1 "$OT_STATE/claims" 2>/dev/null | wc -l | tr -d '[:space:]')" "0" \
  "a GUI launch records no claim: nothing could ever prune it"
assert_contains "$gui_out" "on lane CLAUDE_CONFIG_DIR=$H/.claude" \
  "a GUI batch reports the single lane it resolved up front"

# The re-pick refuses on the same terms as the first: a batch whose remaining
# items cannot be placed stops instead of launching onto an unvouched account.
# The lanes go unmeasurable between the two picks (every usage query fails),
# which is exactly the state `pick` refuses on.
cat > "$TMP_ROOT/fetch-flaky" <<'STUB'
#!/usr/bin/env bash
# Serves $FLAKY_OK usage queries, then fails every one after that.
n=0; [[ -f "$FLAKY_COUNT" ]] && n="$(cat "$FLAKY_COUNT")"
n=$((n + 1)); printf '%s' "$n" > "$FLAKY_COUNT"
[[ "$n" -le "${FLAKY_OK:-3}" ]] || exit 1
f="$FIXTURE_DIR/$(basename "$2").json"
[[ -f "$f" ]] || exit 1
cat "$f"
STUB
chmod +x "$TMP_ROOT/fetch-flaky"
rm -rf "$OT_STATE"; rm -f "$OT_TMUX_PANES" "$TMP_ROOT/flaky-count"
set +e
stop_out=$(LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$TMP_ROOT/fetch-flaky" \
  FLAKY_COUNT="$TMP_ROOT/flaky-count" FLAKY_OK=3 \
  GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' TMUX=stub,1,0 OT_TMUX_LOG="$OT_TMUX_LOG" \
  OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$OT_TMUX_PANES" OVERSEE_WATCH_STATE_DIR="$OT_STATE" \
  PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
  "$OPEN_TERMINAL" --harness claude --lane auto --cmd "true" CC-6 CC-7 2>&1)
stop_rc=$?
set -e
assert_eq "$stop_rc" "1" "a batch that cannot place its next item exits nonzero"
assert_contains "$stop_out" "stopping after 1 launch(es)" "the refusal says how far the batch got"
assert_eq "$(ls -1 "$OT_STATE/claims" 2>/dev/null | wc -l | tr -d '[:space:]')" "1" \
  "the item that could not be placed was never launched"

# Hermeticity proof: every window the launch-success cases created must have
# gone through the stub. An empty log means a real tmux server took the call.
if [[ -s "$OT_TMUX_LOG" ]] && grep -q "new-window" "$OT_TMUX_LOG"; then
  pass "launch cases drove the tmux stub, not a real server"
else
  fail "launch cases bypassed the tmux stub (real windows were created)"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
