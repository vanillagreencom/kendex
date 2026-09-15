#!/usr/bin/env bash
# Tests for the `lanes` helper: discovery, measurement, aliases, pick, and the
# in-flight claim store. The network layer is the only impure part of `lanes`
# and is injected through ORCH_LANES_FETCH_CMD, so every row here runs offline
# against fixed responses; a chooser tested against live accounts would assert
# whatever today's usage happens to be. open-terminal's --lane wiring is
# open-terminal-lane.sh.
#
# One case per behaviour surface; shaped input is one table per case, one
# asserted row per shape. Every run gets its own empty claim store unless the
# row stages one, so no row reads another's claims or the checkout's.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# Every lane this suite measures lives under LANES_HOME; an inherited lane
# setting would point discovery at the operator's real accounts.
unset ORCH_LANE_DIRS ORCH_LANE_ALIASES ORCH_LANE_EXCLUDE ORCH_LANE_RETIRE ORCH_LANES_USAGE_TTL CODEX_HOME
# The renewal's own settings, for the same reason: with one of these exported a
# developer runs a different suite from CI, where a baseline expired-token row
# renews, or a row reaches a live helper or the real token endpoint.
unset ORCH_LANES_CLAUDE_CLIENT_ID ORCH_LANES_TOKEN_CMD ORCH_LANES_CLAUDE_TOKEN_URL
# Resolve siblings from the TEST directory, never from a repo root: the CLI
# integration check runs this same suite from an INSTALLED layout
# (.agents/skills/orch/tests/...), where a `<root>/skills/orch/...` path does not
# exist.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
LANES="$SCRIPTS_DIR/lanes"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$TEST_DIR/lib/lanes-fixture.sh"

FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"

# tmux stub for the claim store: `list-panes` prints the lines of
# $TMUX_PANES_FILE, or of $TMUX_PANES_FILE.<N> on the Nth call when that file
# exists, so a case can change what the server reports between two
# enumerations. cat's status is the stub's: an unreadable file is a failed
# enumeration, the way a dead tmux server is, not an empty one.
CLAIM_BIN="$TMP_ROOT/claim-bin"; mkdir -p "$CLAIM_BIN"
cat > "$CLAIM_BIN/tmux" <<'STUBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "list-panes" ]] || exit 0
n=0; [[ -f "${TMUX_PANES_FILE:-}.calls" ]] && n="$(cat "$TMUX_PANES_FILE.calls")"
n=$((n + 1)); [[ -z "${TMUX_PANES_FILE:-}" ]] || printf '%s' "$n" > "$TMUX_PANES_FILE.calls"
src="$TMUX_PANES_FILE.$n"; [[ -f "$src" ]] || src="$TMUX_PANES_FILE"
[[ -f "$src" ]] || exit 0
cat "$src"
STUBEOF
chmod +x "$CLAIM_BIN/tmux"
FAIL_BIN="$TMP_ROOT/fail-bin"; mkdir -p "$FAIL_BIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAIL_BIN/tmux"; chmod +x "$FAIL_BIN/tmux"

LIVE_PID="$$"
STORE=""
PANES=""
# Above pid_max on every platform this runs on (2^22 on Linux, 99999 on
# macOS), so `kill -0` can never find it: a tmux server provably gone.
DEAD_PID=2147483647

# run_lanes ENV ARGS... — runs `lanes` against the current home with a fresh
# claim store and pane file under $RUN; ENV is a semicolon-separated list of
# `env` arguments that may override the defaults (an alias list carries
# commas). Sets OUT, RC and ERR.
RUN_SEQ=0
run_lanes() {
  local env_list="$1" env_args=()
  shift
  [[ -z "$env_list" ]] || IFS=';' read -ra env_args <<<"$env_list"
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$RUN/store"
  ERR="$RUN/stderr"
  OUT=$(env LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" FETCH_LOG="$RUN/fetch.log" \
    TOKEN_LOG="$RUN/token.log" \
    OVERSEE_WATCH_STATE_DIR="$RUN/store" TMUX_PANES_FILE="$RUN/panes" \
    PATH="$CLAIM_BIN:$PATH" ${env_args[@]+"${env_args[@]}"} "$LANES" "$@" 2>"$ERR")
  RC=$?
}

# fetched_lanes FILE — the lane names the fetch stub logged (directory names
# without the leading dot), sorted and comma-joined, or none.
fetched_lanes() {
  local v
  v="$(sed 's/^\.//' "$1" 2>/dev/null | sort | paste -sd, - || true)"
  printf '%s' "${v:-none}"
}

json() { jq -r "$1" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE; }

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order. Names:
#   rc                    exit status
#   out                   stdout, whole; lines its line count
#   <alias>.<field>       that field of the listed lane with that alias
#   first.<field>         that field of the only listed lane
#   bs.<field>            that field of the backslash-named lane
#   aliases               every listed alias, sorted
#   files                 the claim files left in the store, sorted, or none
#   fetched               the lanes the fetch stub served, sorted, or none
#   cachefiles            the lanes whose usage records the run left, sorted, or none
#   <alias>.aged          that lane's usage_age_s, or 30+ from 30 seconds on
observe() {
  local got="" token name value alias field
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      out) value="$OUT" ;;
      lines) value="$(grep -c . <<<"$OUT" || true)" ;;
      length) value="$(json length)" ;;
      aliases) value="$(json '[.[].alias] | sort | join(",")')" ;;
      files) value="$(ls -1 "$STORE/claims" 2>/dev/null | sed 's/\.claim$//' | paste -sd, - || true)"; [[ -n "$value" ]] || value=none ;;
      fetched) value="$(fetched_lanes "$RUN/fetch.log")" ;;
      tokencalls) value="$(grep -c . "$RUN/token.log" 2>/dev/null || true)"; value="${value:-0}" ;;
      # Every jq argument vector of the run, searched for the fixture's own
      # refresh token and for both tokens the endpoint stub hands back.
      jqsecrets) value="$(grep -c -e refresh-claude -e renewed-token -e rotated-refresh "$JQ_ARGV_LOG" 2>/dev/null || true)"; value="${value:-0}" ;;
      newtoken) value="$(jq -r '.claudeAiOauth.accessToken' "$H/.claude/.credentials.json" 2>/dev/null || echo UNREADABLE)" ;;
      newrefresh) value="$(jq -r '.claudeAiOauth.refreshToken' "$H/.claude/.credentials.json" 2>/dev/null || echo UNREADABLE)" ;;
      cachefiles) value="$(cat "$RUN/store/usage"/*.json 2>/dev/null | jq -r '.config_dir' | sed "s#^$H/\\.##" | sort | paste -sd, - || true)"; [[ -n "$value" ]] || value=none ;;
      *.cause)
        # A detail is a sentence, and `expect` splits on whitespace: the
        # underscores let a row pin the whole text rather than a fragment.
        value="$(json ".[] | select(.alias==\"${name%%.*}\") | .detail")"
        value="${value// /_}"
        ;;
      *.aged)
        # A reused figure's age grows with the clock; the row pins its floor.
        value="$(json ".[] | select(.alias==\"${name%%.*}\") | .usage_age_s")"
        [[ "$value" =~ ^[0-9]+$ && "$value" -ge 30 ]] && value="30+"
        ;;
      first.*) value="$(json ".[0].${name#first.}")" ;;
      bs.*) value="$(jq -r --arg d "$BSDIR" ".[] | select(.config_dir==\$d) | .${name#bs.}" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE)" ;;
      *.*)
        alias="${name%%.*}"; field="${name#*.}"
        value="$(json ".[] | select(.alias==\"$alias\") | .$field")"
        ;;
      *) value="$(json ".$name")" ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# table ROW... — one run and one assertion per row: `label|env|args|expect`.
table() {
  local row label env args expect
  for row in "$@"; do
    IFS='|' read -r label env args expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    # shellcheck disable=SC2086
    run_lanes "$env" $args
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

standard_home home
LIST='list --harness claude --json'

echo "=== list: every candidate config dir is measured; headroom is the binding bucket ==="
# Averaging nclaude's 5% session and 95% weekly would call it half free and
# send a fleet into the wall; the largest bucket binds.
table \
  "every candidate dir is listed, a dir with no credentials reported, the plan read from the file, headroom 100 minus the largest bucket, the model label from the API, no live claim as 0||$LIST|length=4 openclaude.status=no_credentials claude.plan=max nclaude.headroom_pct=5 eclaude.headroom_pct=20 claude.headroom_pct=80 claude.model_label=Opus claude.claims=0" \
  "the human table renders every discovered lane under its header||list --harness claude|rc=0 lines=5"

echo "=== aliases are an overlay on the discovered inventory ==="
# Discovery keeps finding every account with no configuration at all; an
# alias relabels one it found and can neither add nor drop a lane, nor change
# what was measured.
table \
  "with no aliases every discovered lane keeps its directory name||$LIST|aliases=claude,eclaude,nclaude,openclaude" \
  "an alias renames the lane it names, whitespace around the pairs tolerated|ORCH_LANE_ALIASES=eclaude=work, nclaude = overflow|$LIST|aliases=claude,openclaude,overflow,work" \
  "the renamed lane is the directory the alias named, its measured headroom unchanged|ORCH_LANE_ALIASES=eclaude=work|$LIST|work.config_dir=$H/.eclaude work.headroom_pct=20" \
  "an alias naming no discovered directory is inert|ORCH_LANE_ALIASES=notthere=phantom|$LIST|aliases=claude,eclaude,nclaude,openclaude"

echo "=== pick: the most headroom, or a refusal ==="
# Every lane over the threshold is an error, never a best-effort pick, or the
# fleet launches into a wall anyway.
table \
  "pick returns the lane with the most headroom as a launch env prefix||pick --harness claude|rc=0 out=CLAUDE_CONFIG_DIR=$H/.claude" \
  "pick --json returns the whole lane record||pick --harness claude --json|alias=claude" \
  "pick exits 3 when no lane is under the threshold||pick --harness claude --max-pct 15|rc=3"

echo "=== unmeasurable lanes are never idle ==="
# An expired token, an authenticated lane whose usage body carries none of the
# consumer windows (a real enterprise plan), and an unreachable API each report
# their status with null headroom, and pick never chooses them.
new_home expired
make_lane "$H" claude -60
make_lane "$H" eclaude 3600
claude_usage 90 90 90 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 40 40 40 Opus > "$FIXTURE_DIR/.eclaude.json"
table \
  "an expired token is reported as expired with null headroom||$LIST|claude.status=expired claude.headroom_pct=null" \
  "pick skips an expired lane||pick --harness claude|rc=0 out=CLAUDE_CONFIG_DIR=$H/.eclaude"
new_home enterprise
make_lane "$H" claude 3600 enterprise
jq -n '{spend: {}}' > "$FIXTURE_DIR/.claude.json"
table \
  "a usage body with no usable window is no_usage_data with null headroom||$LIST|first.status=no_usage_data first.headroom_pct=null" \
  "pick refuses rather than choosing an unmeasurable lane||pick --harness claude|rc=3"
new_home unreachable
make_lane "$H" claude 3600
table \
  "a failed usage query is unreachable with null headroom||$LIST|first.status=unreachable first.headroom_pct=null"

echo "=== an expired access token is renewed in place, or the lane stays expired ==="
# The lane `pick` prints must carry a live token: a session launched on a stale
# one stalls at its first call. The token POST is the stub; the lock, the
# re-read under it and the credentials write-back are the real ones.
TOKEN_OK="$TMP_ROOT/token-ok"
# Answers without jq of its own: the argv row below reads every jq argument
# vector of the run, and a stub that passed its own fixture tokens to jq would
# be the leak it is looking for.
cat > "$TOKEN_OK" <<'STUB'
#!/usr/bin/env bash
# The token request body arrives on stdin; the endpoint's JSON goes to stdout.
cat >/dev/null
[[ -z "${TOKEN_LOG:-}" ]] || printf 'refresh\n' >> "$TOKEN_LOG"
printf '{"access_token":"renewed-token","refresh_token":"rotated-refresh","expires_in":3600}\n'
STUB
chmod +x "$TOKEN_OK"
TOKEN_BAD="$TMP_ROOT/token-bad"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "{}"\n' > "$TOKEN_BAD"
chmod +x "$TOKEN_BAD"
# An access token with no expires_in. The empty object above never reaches the
# expiry refusal, because the missing access token refuses first.
TOKEN_NOEXP="$TMP_ROOT/token-noexp"
cat > "$TOKEN_NOEXP" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '{"access_token":"renewed-token","refresh_token":"rotated-refresh"}\n'
STUB
chmod +x "$TOKEN_NOEXP"
# Zero is a number and not a lifetime: it dates the new expiry to this instant,
# so the lane would return renewed and the next run would renew it again.
TOKEN_ZEROEXP="$TMP_ROOT/token-zeroexp"
cat > "$TOKEN_ZEROEXP" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '{"access_token":"renewed-token","refresh_token":"rotated-refresh","expires_in":0}\n'
STUB
chmod +x "$TOKEN_ZEROEXP"
REFRESH_ENV="ORCH_LANES_CLAUDE_CLIENT_ID=client-1;ORCH_LANES_TOKEN_CMD=$TOKEN_OK"

new_home refreshable
make_lane "$H" claude -60
make_lane "$H" eclaude 3600
claude_usage 10 20 5  Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 40 40 40 Opus > "$FIXTURE_DIR/.eclaude.json"
table \
  "a renewed lane is measured like any other, its record marked refreshable, both the new token and the rotated refresh token written back to its credentials|$REFRESH_ENV|$LIST|claude.status=ok claude.refreshable=true claude.headroom_pct=80 newtoken=renewed-token newrefresh=rotated-refresh" \
  "a lane whose token had not expired is not refreshable|$REFRESH_ENV|$LIST|eclaude.status=ok eclaude.refreshable=false"

# Its own home: the rows above renewed theirs, and a renewal writes an expiry
# in the future, so that home has no expired lane left for `pick` to renew.
new_home pick-renews
make_lane "$H" claude -60
make_lane "$H" eclaude 3600
claude_usage 10 20 5  Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 40 40 40 Opus > "$FIXTURE_DIR/.eclaude.json"
table \
  "pick renews the lane it returns, once|$REFRESH_ENV|pick --harness claude|rc=0 out=CLAUDE_CONFIG_DIR=$H/.claude tokencalls=1"

# The renewal writes the new expiry with the new token. Without it every later
# run reads the lane as expired and rotates the shared refresh token again,
# which is a worse version of the failure this renewal exists to remove. The
# first list renews; the asserted row is the second.
new_home renew-once
make_lane "$H" claude -60
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
run_lanes "$REFRESH_ENV" $LIST
table \
  "a second run reads the renewed lane as live and makes no second token call|$REFRESH_ENV|$LIST|claude.status=ok claude.refreshable=false claude.headroom_pct=80 tokencalls=0"

# Every secret reaches jq through the environment. On Linux /proc/<pid>/cmdline
# is world-readable, so a token on an argument vector is readable by any local
# user for as long as the process lives.
JQ_ARGV_BIN="$TMP_ROOT/jq-argv-bin"; mkdir -p "$JQ_ARGV_BIN"
JQ_ARGV_LOG="$TMP_ROOT/jq-argv.log"
REAL_JQ="$(command -v jq)"
cat > "$JQ_ARGV_BIN/jq" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$JQ_ARGV_LOG"
exec "$REAL_JQ" "\$@"
STUBEOF
chmod +x "$JQ_ARGV_BIN/jq"
new_home jq-argv
make_lane "$H" claude -60
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
: > "$JQ_ARGV_LOG"
table \
  "a renewal puts no token on a jq argument vector|$REFRESH_ENV;PATH=$JQ_ARGV_BIN:$CLAIM_BIN:$PATH|$LIST|claude.status=ok claude.refreshable=true jqsecrets=0"

new_home refresh-fails
make_lane "$H" claude -60
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
table \
  "a renewal the endpoint refuses fails closed as expired, naming the cause|ORCH_LANES_CLAUDE_CLIENT_ID=client-1;ORCH_LANES_TOKEN_CMD=$TOKEN_BAD|$LIST|claude.status=expired claude.refreshable=false claude.headroom_pct=null claude.cause=access_token_expired_and_could_not_be_renewed:_the_token_endpoint_returned_no_access_token" \
  "pick refuses a lane whose renewal failed|ORCH_LANES_CLAUDE_CLIENT_ID=client-1;ORCH_LANES_TOKEN_CMD=$TOKEN_BAD|pick --harness claude|rc=3"

# RFC 6749 makes expires_in recommended, not required: a response without one
# refuses rather than writing a live token under the past expiry, which would
# renew again on every later run.
new_home no-expires-in
make_lane "$H" claude -60
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
table \
  "a response with no expires_in refuses, naming it, and leaves the credentials alone|ORCH_LANES_CLAUDE_CLIENT_ID=client-1;ORCH_LANES_TOKEN_CMD=$TOKEN_NOEXP|$LIST|claude.status=expired claude.refreshable=false claude.headroom_pct=null claude.cause=access_token_expired_and_could_not_be_renewed:_the_token_endpoint_returned_no_usable_expires_in newtoken=token-claude newrefresh=refresh-claude"

new_home zero-expires-in
make_lane "$H" claude -60
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
table \
  "an expires_in of zero refuses on the same cause and leaves the credentials alone|ORCH_LANES_CLAUDE_CLIENT_ID=client-1;ORCH_LANES_TOKEN_CMD=$TOKEN_ZEROEXP|$LIST|claude.status=expired claude.refreshable=false claude.headroom_pct=null claude.cause=access_token_expired_and_could_not_be_renewed:_the_token_endpoint_returned_no_usable_expires_in newtoken=token-claude newrefresh=refresh-claude"

# A real interleaving, not a simulated one: the peer takes the SAME lock through
# the same lib the renewal uses, writes a live token and a rotated refresh token
# while the measured run waits on it, and releases. Posting after that would
# rotate the peer's fresh refresh token away and strand its account.
PEER="$TMP_ROOT/peer-renew"
cat > "$PEER" <<'STUB'
#!/usr/bin/env bash
# argv: <credentials path> <held marker path>
set -uo pipefail
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/lib/file-lock.sh"
creds="$1"; held="$2"; lock="$(dirname "$creds")/.lanes-refresh.lock"
exec 9>"$lock" || exit 1
orch_take_lock 9 "$lock" 30 || exit 1
# Only now is the interleaving staged: the caller waits for this before it runs.
: > "$held"
sleep 2
exp=$(( ($(date +%s) + 3600) * 1000 ))
jq --argjson exp "$exp" \
  '.claudeAiOauth.accessToken = "peer-token"
   | .claudeAiOauth.refreshToken = "peer-refresh"
   | .claudeAiOauth.expiresAt = $exp' "$creds" > "$creds.peer" || exit 1
mv "$creds.peer" "$creds" || exit 1
exec 9>&-
orch_release_lock
STUB
chmod +x "$PEER"
export SCRIPTS_DIR
new_home peer-renews
make_lane "$H" claude -60
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
PEER_HELD="$TMP_ROOT/peer-held"; rm -f -- "${PEER_HELD:?}"
"$PEER" "$H/.claude/.credentials.json" "$PEER_HELD" &
PEER_PID=$!
peer_wait=0
until [[ -f "$PEER_HELD" ]] || (( peer_wait >= 100 )); do sleep 0.1; peer_wait=$((peer_wait + 1)); done
[[ -f "$PEER_HELD" ]] || { printf 'peer-renew never took the lock; the interleaving was not staged\n' >&2; exit 1; }
table \
  "a renewal a peer wrote under the lock is taken as it stands, with no second POST|$REFRESH_ENV|$LIST|claude.status=ok claude.refreshable=true claude.headroom_pct=80 tokencalls=0 newtoken=peer-token newrefresh=peer-refresh"
wait "$PEER_PID"

new_home no-refresh-token
mkdir -p "$H/.claude"
jq -n --argjson exp "$(( ($(date +%s) - 60) * 1000 ))" \
  '{claudeAiOauth: {accessToken: "stale", expiresAt: $exp, subscriptionType: "max"}}' \
  > "$H/.claude/.credentials.json"
table \
  "an expired lane with no refresh token beside it names that, and never reaches the endpoint|ORCH_LANES_CLAUDE_CLIENT_ID=client-1;ORCH_LANES_TOKEN_CMD=$TOKEN_OK|$LIST|claude.status=expired claude.refreshable=false claude.cause=access_token_expired_and_could_not_be_renewed:_there_is_no_refresh_token_in_$H/.claude/.credentials.json_to_renew_with tokencalls=0"

echo "=== codex windows route by duration, not by position ==="
# OpenAI's primary/secondary windows do not map to session/weekly by position:
# a weekly-only account reports its 7-day limit as the PRIMARY window with a
# null secondary, and routing by position would label it 5h and invent a
# phantom 0% weekly.
new_home codex
make_codex_lane "$H/.codex"
jq -n '{rate_limit: {primary_window: {used_percent: 44, reset_at: 1785000000, limit_window_seconds: 604800},
                     secondary_window: null}}' > "$FIXTURE_DIR/.codex.json"
table \
  "a 7-day primary window fills the weekly slot and the missing session window stays null||list --harness codex --json|first.weekly_pct=44 first.session_5h_pct=null first.headroom_pct=56"
jq -n '{rate_limit: {primary_window: {used_percent: 30, reset_at: 1785000000, limit_window_seconds: 18000},
                     secondary_window: {used_percent: 70, reset_at: 1785600000, limit_window_seconds: 604800}}}' \
  > "$FIXTURE_DIR/.codex.json"
table \
  "a 5h and a 7d window fill their slots and the larger binds||list --harness codex --json|first.session_5h_pct=30 first.weekly_pct=70 first.headroom_pct=30"

echo "=== in-flight lane claims ==="
# open-terminal records one claim per lane window it launches; a claim is live
# while its pane is, judged by server pid and pane id together (pane ids
# restart at %0 on every server). Usage numbers lag a launch by minutes, so
# without the store a second pick re-reads the same numbers and hands one
# account the whole fleet. A claim this enumeration cannot see, or one behind
# a failed enumeration, is judged by its server alone and never deleted
# blind; a malformed record is dropped; an unreadable store or file is
# unknown, never zero, and pick refuses on it.
standard_home home
# A config dir carrying a backslash is a real path the count must see (`awk
# -v` would expand the escape and match nothing); it exists only for the row
# that claims it, or it would tie claude for the pick.
BSDIR="$H/.back\\tclaude"
ln -sfn "$H/.claude" "$TMP_ROOT/claude-link"

# stage_panes SPEC — the pane file(s) for one run: `live:%1,dead:%2` lists
# panes by server (live is this process, dead a pid no server has); `N=...;`
# prefixes name the file the stub serves on the Nth call, `*=` the default
# for every other call; `FAIL` makes that file unreadable; `broken` swaps in
# a tmux whose enumeration fails outright.
stage_panes() {
  local spec="$1" parts part target n entries ents entry pid pane
  PANES="$RUN/panes"; : > "$PANES"
  PANES_PATH="$CLAIM_BIN"
  [[ "$spec" != broken ]] || { PANES_PATH="$FAIL_BIN"; return; }
  IFS=';' read -ra parts <<<"$spec"
  # An empty spec leaves the array empty, which Bash 3.2 reads as unbound.
  for part in ${parts[@]+"${parts[@]}"}; do
    target="$PANES"
    entries="$part"
    if [[ "$part" == *=* ]]; then
      n="${part%%=*}"; entries="${part#*=}"
      [[ "$n" == '*' ]] || target="$PANES.$n"
    fi
    : > "$target"
    [[ "$entries" != FAIL ]] || { chmod 000 "$target"; continue; }
    [[ -n "$entries" ]] || continue
    IFS=',' read -ra ents <<<"$entries"
    for entry in "${ents[@]}"; do
      case "${entry%%:*}" in
        live) pid="$LIVE_PID" ;;
        dead) pid="$DEAD_PID" ;;
        *) echo "stage_panes: unknown server token in $entry" >&2; exit 1 ;;
      esac
      pane="${entry#*:}"
      printf '%s %s\n' "$pid" "$pane" >> "$target"
    done
  done
}

# stage_claims SPEC — the claim files for one run, `name:server:pane:dir` items
# separated by `;`: server is live or dead, dir one of the home's lane names,
# `claude/` for a trailing slash, `link` for a symlink to claude, `bs` for the
# backslash-named lane; `junk` writes a malformed record. Any other token is
# a typo and aborts the suite rather than staging the opposite world.
stage_claims() {
  local spec="$1" items item name server pane dir pid
  STORE="$RUN/store"
  mkdir -p "$STORE/claims"
  [[ -n "$spec" ]] || return 0
  IFS=';' read -ra items <<<"$spec"
  for item in "${items[@]}"; do
    if [[ "$item" == junk ]]; then
      printf 'not-a-pid\t\tstuff\n' > "$STORE/claims/junk.claim"
      continue
    fi
    IFS=':' read -r name server pane dir <<<"$item"
    case "$server" in
      live) pid="$LIVE_PID" ;;
      dead) pid="$DEAD_PID" ;;
      *) echo "stage_claims: unknown server token in $item" >&2; exit 1 ;;
    esac
    case "$dir" in
      claude | eclaude | nclaude) dir="$H/.$dir" ;;
      claude/) dir="$H/.claude/" ;;
      link) dir="$TMP_ROOT/claude-link" ;;
      bs)
        dir="$BSDIR"
        mkdir -p "$BSDIR"
        cp "$H/.claude/.credentials.json" "$BSDIR/.credentials.json"
        claude_usage 10 20 5 Opus > "$FIXTURE_DIR/$(basename "$BSDIR").json"
        ;;
      *) echo "stage_claims: unknown dir token in $item" >&2; exit 1 ;;
    esac
    printf '%s\t%s\t%s\t%s\t2026-08-16T00:00:00Z\n' "$pid" "$pane" "$dir" "$name" > "$STORE/claims/$name.claim"
  done
}

# claims_table ROW... — `label|panes|claims|perm|args|expect`; perm is empty,
# `store` (the claims directory unreadable for the run) or `file:<name>`.
claims_table() {
  local row label panes claims perm args expect
  for row in "$@"; do
    IFS='|' read -r label panes claims perm args expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'claims_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"; mkdir -p "$RUN"
    stage_panes "$panes"
    stage_claims "$claims"
    case "$perm" in
      store) chmod 000 "$STORE/claims" ;;
      file:*) chmod 000 "$STORE/claims/${perm#file:}.claim" ;;
    esac
    # shellcheck disable=SC2086
    OUT=$(env LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" OVERSEE_WATCH_STATE_DIR="$STORE" \
      TMUX_PANES_FILE="$PANES" PATH="$PANES_PATH:$PATH" "$LANES" $args 2>"$RUN/stderr")
    RC=$?
    case "$perm" in
      store) chmod 755 "$STORE/claims" ;;
      file:*) chmod 644 "$STORE/claims/${perm#file:}.claim" ;;
    esac
    chmod -R u+rw "$RUN" 2>/dev/null || true
    assert_eq "$(observe "$expect")" "$expect" "$label" "$RUN/stderr"
    rm -rf -- "${BSDIR:?}" "${FIXTURE_DIR:?}/$(basename "$BSDIR").json"
  done
}

PICK='pick --harness claude'
claims_table \
  "with nothing in flight, pick still takes the most headroom|live:%1,live:%2|||$PICK|out=CLAUDE_CONFIG_DIR=$H/.claude" \
  "a live claim is counted against its lane only|live:%1,live:%2|one:live:%1:claude||$LIST|claude.claims=1 eclaude.claims=0" \
  "pick prefers the lane with nothing in flight over the one with more headroom|live:%1,live:%2|one:live:%1:claude||$PICK|out=CLAUDE_CONFIG_DIR=$H/.eclaude" \
  "a claimed lane does not lower the threshold for the rest|live:%1,live:%2|one:live:%1:claude||$PICK --max-pct 15|rc=3" \
  "with claims tied, headroom breaks the tie|live:%1,live:%2|one:live:%1:claude;two:live:%2:eclaude||$PICK|out=CLAUDE_CONFIG_DIR=$H/.claude" \
  "a claim whose pane is gone stops counting and its file is removed|live:%2|one:live:%1:claude;two:live:%2:eclaude||$LIST|claude.claims=0 files=two" \
  "a claim from a dead tmux server never matches a reused pane id|live:%2|stale:dead:%2:eclaude||$LIST|eclaude.claims=0 files=none" \
  "a claim this enumeration cannot see still counts while its server runs, and is kept||foreign:live:%5:claude||$LIST|claude.claims=1 files=foreign" \
  "a failed pane enumeration deletes nothing|broken|foreign:live:%5:claude||$LIST|claude.claims=1 files=foreign" \
  "a claim whose server is gone is pruned even with nothing to enumerate||foreign:live:%5:claude;gone:dead:%6:eclaude||$LIST|eclaude.claims=0 files=foreign" \
  "a claim written with a trailing slash counts against the discovered lane|live:%7|slashed:live:%7:claude/||$LIST|claude.claims=1" \
  "a claim written through a symlink counts against the lane it points at|live:%7|linked:live:%7:link||$LIST|claude.claims=1" \
  "a claim written after the pane snapshot is not pruned by it|1=live:%1;2=live:%1,live:%4;*=live:%4|racer:live:%4:claude||$LIST|claude.claims=1 files=racer" \
  "a backslash-bearing config dir still counts its live claim|live:%5|backslash:live:%5:bs||$LIST|bs.claims=1" \
  "a malformed claim record is dropped on read|live:%1|junk||$LIST|files=none"

# Root reads a mode-000 path, so these rows cannot fail a read there.
if [[ "$(id -u)" -eq 0 ]]; then
  printf '  skip  unreadable store, file and pane rows (running as root)\n'
else
  claims_table \
    "a failed re-enumeration prunes nothing the first snapshot proved live, nor the record that provoked it|1=live:%1,live:%4;2=FAIL;*=live:%1|live4:live:%4:claude;gone5:live:%5:eclaude||$LIST|claude.claims=1 eclaude.claims=1 files=gone5,live4" \
    "an unreadable claim store reports claims as unknown, never zero, and is never emptied|live:%7|keepme:live:%7:claude|store|$LIST|rc=0 claude.claims=null files=keepme" \
    "pick refuses when in-flight claims cannot be read|live:%7|keepme:live:%7:claude|store|$PICK|rc=1" \
    "one unreadable claim file is enough for pick to refuse|live:%7|keepme:live:%7:claude|file:keepme|$PICK|rc=1" \
    "an unreadable claim file is left in place|live:%7|keepme:live:%7:claude|file:keepme|$LIST|files=keepme"
fi

echo "=== exclusion and retirement overlay discovery ==="
# An excluded lane is never listed, fetched or picked; a lane past its
# retirement date is listed as retired and never fetched or picked, one before
# it is picked as usual. The retired lane's credentials file is not JSON, so a
# read before the retirement check reports `error` instead of `retired`; the
# fetch log proves no usage query. `fetched` lists the lanes the stub served.
standard_home home
table \
  "an excluded lane is not listed and its usage is never fetched|ORCH_LANE_EXCLUDE=claude|$LIST|aliases=eclaude,nclaude,openclaude fetched=eclaude,nclaude" \
  "pick never returns an excluded lane, even the one with the most headroom|ORCH_LANE_EXCLUDE=sclaude, claude|pick --harness claude|rc=0 out=CLAUDE_CONFIG_DIR=$H/.eclaude fetched=eclaude,nclaude" \
  "an excluded ORCH_LANE_DIRS entry is neither listed nor fetched|ORCH_LANE_DIRS=$H/.claude:$H/.eclaude;ORCH_LANE_EXCLUDE=.claude|list --json|aliases=eclaude fetched=eclaude" \
  "an alias names an excluded lane as its directory name does|ORCH_LANE_ALIASES=claude=personal;ORCH_LANE_EXCLUDE=personal|$LIST|aliases=eclaude,nclaude,openclaude fetched=eclaude,nclaude" \
  "an ORCH_LANE_DIRS whose every entry is excluded still keeps discovery off|ORCH_LANE_DIRS=$H/.eclaude;ORCH_LANE_EXCLUDE=eclaude|$LIST|length=0 fetched=none" \
  "pick never returns a retired lane, even the one with the most headroom|ORCH_LANE_RETIRE=claude=2000-01-01|pick --harness claude|rc=0 out=CLAUDE_CONFIG_DIR=$H/.eclaude" \
  "a lane before its retirement date is picked as usual|ORCH_LANE_RETIRE=claude=2999-12-31|pick --harness claude|rc=0 out=CLAUDE_CONFIG_DIR=$H/.claude"
printf 'not json' > "$H/.claude/.credentials.json"
table \
  "a lane past its retirement date is listed as retired, unread and unfetched|ORCH_LANE_RETIRE=claude=2000-01-01|$LIST|claude.status=retired claude.headroom_pct=null fetched=eclaude,nclaude"

echo "=== codex lanes are discovered like claude lanes ==="
# A harness-named directory holding no config marker (a shared session store,
# a backup) matches the discovery glob but is no lane.
new_home stores
make_lane "$H" claude 3600
mkdir -p "$H/.claude-shared" "$H/.codex-backup" "$H/.codex-cfg"
: > "$H/.codex-cfg/config.toml"
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
table \
  "a discovered dir with no config marker is not listed; a codex config.toml is one||list --json|aliases=claude,codex-cfg codex-cfg.status=no_credentials"

# ~/.codex plus every ~/.*codex* directory; an ORCH_LANE_DIRS entry holding
# auth.json and no .credentials.json is a codex lane.
new_home codexes
make_codex_lane "$H/.codex"
make_codex_lane "$H/.1codex"
make_codex_lane "$H/.2codex"
make_lane "$H" claude 3600
for c in codex:80 1codex:50 2codex:10; do
  jq -n --argjson p "${c#*:}" '{rate_limit: {primary_window: {used_percent: $p, reset_at: 1785000000, limit_window_seconds: 18000}}}' \
    > "$FIXTURE_DIR/.${c%%:*}.json"
done
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
table \
  "every numbered codex dir is listed as a codex lane||list --harness codex --json|aliases=1codex,2codex,codex" \
  "pick --harness codex takes the numbered lane with the most headroom||pick --harness codex|rc=0 out=CODEX_HOME=$H/.2codex" \
  "an ORCH_LANE_DIRS entry is a codex or claude lane by the credentials file it holds|ORCH_LANE_DIRS=$H/.1codex:$H/.claude|list --json|1codex.harness=codex claude.harness=claude length=2"
# A CODEX_HOME the codex CLI reads outside the discovery glob is still a lane,
# listed once when discovery found it too; a retired ORCH_LANE_DIRS entry
# holding auth.json under a name without `codex` lists as claude, because its
# harness comes from its name, never a probe.
XCODEX="$TMP_ROOT/elsewhere-codex"
make_codex_lane "$XCODEX"
RETIRED_ACCT="$TMP_ROOT/retired-acct"
make_codex_lane "$RETIRED_ACCT"
jq -n '{rate_limit: {primary_window: {used_percent: 40, reset_at: 1785000000, limit_window_seconds: 18000}}}' \
  > "$FIXTURE_DIR/elsewhere-codex.json"
table \
  "a Claude-only ORCH_LANE_DIRS leaves codex lanes discovered|ORCH_LANE_DIRS=$H/.claude|list --json|aliases=1codex,2codex,claude,codex" \
  "a CODEX_HOME outside the home is a codex lane beside the discovered ones|CODEX_HOME=$XCODEX|list --harness codex --json|aliases=1codex,2codex,codex,elsewhere-codex elsewhere-codex.harness=codex" \
  "a CODEX_HOME discovery already found is listed once|CODEX_HOME=$H/.codex|list --harness codex --json|length=3" \
  "a retired ORCH_LANE_DIRS entry takes its harness from its name, never a probe|ORCH_LANE_DIRS=$RETIRED_ACCT;ORCH_LANE_RETIRE=retired-acct=2000-01-01|list --harness claude --json|retired-acct.harness=claude retired-acct.status=retired fetched=none"
# Lanes sharing a directory name keep separate cache records: the first run
# fetches both, a second run within the TTL fetches neither.
SAMENAME="$TMP_ROOT/other/.codex"
make_codex_lane "$SAMENAME"
SAMENAME_STATE="$TMP_ROOT/samename-state"
table \
  "two same-named codex lanes are each fetched on the first run|CODEX_HOME=$SAMENAME;OVERSEE_WATCH_STATE_DIR=$SAMENAME_STATE|list --harness codex --json|fetched=1codex,2codex,codex,codex" \
  "a second run within the TTL reuses both same-named records|CODEX_HOME=$SAMENAME;OVERSEE_WATCH_STATE_DIR=$SAMENAME_STATE|list --harness codex --json|fetched=none"

echo "=== usage figures are cached per host ==="
# A run writes each fetched body under the state dir's usage/ and a run
# within the TTL reuses it without a fetch; --no-cache and an expired figure
# fetch afresh. The staged body differs from the fixture (claude at 50%), so
# which figure a run used is visible in its headroom.
standard_home home
CACHE_STATE="$TMP_ROOT/cache-state"
# stage_cache AGE_S — a cached claude figure fetched AGE_S seconds ago, written
# over the record a real run left, so the file is the one lanes itself names.
stage_cache() {
  local f
  rm -rf -- "${CACHE_STATE:?}"
  env LANES_HOME="$H" ORCH_LANE_DIRS="$H/.claude" ORCH_LANES_FETCH_CMD="$FETCHER" OVERSEE_WATCH_STATE_DIR="$CACHE_STATE" \
    PATH="$CLAIM_BIN:$PATH" "$LANES" list --harness claude --json >/dev/null 2>&1
  for f in "$CACHE_STATE"/usage/*.json; do
    [[ -f "$f" && "$(jq -r '.config_dir' "$f")" == "$H/.claude" ]] || continue
    jq --argjson at "$(( $(date +%s) - $1 ))" --argjson u "$(claude_usage 50 20 5 Opus)" \
      '.fetched_at = $at | .usage = $u' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    return 0
  done
  echo "stage_cache: no cached claude record to stage" >&2
  exit 1
}
table \
  "a fresh fetch reports age 0 and writes one cache file per fetched lane||$LIST|claude.usage_age_s=0 cachefiles=claude,eclaude,nclaude"
stage_cache 30
table \
  "a figure within the TTL is reused without a fetch, its age reported|OVERSEE_WATCH_STATE_DIR=$CACHE_STATE|$LIST|claude.headroom_pct=50 claude.aged=30+ fetched=eclaude,nclaude"
stage_cache 30
table \
  "--no-cache fetches afresh|OVERSEE_WATCH_STATE_DIR=$CACHE_STATE|$LIST --no-cache|claude.headroom_pct=80 fetched=claude,eclaude,nclaude"
stage_cache 30
table \
  "a figure at or past the TTL is fetched afresh|OVERSEE_WATCH_STATE_DIR=$CACHE_STATE;ORCH_LANES_USAGE_TTL=30|$LIST|claude.headroom_pct=80 fetched=claude,eclaude,nclaude"

echo "=== pick --json names the binding bucket and its reset ==="
# claude's largest bucket is weekly, eclaude's the 5-hour session.
standard_home home
table \
  "pick --json carries the chosen lane's headroom, binding bucket and that bucket's reset||pick --harness claude --json|headroom_pct=80 binding_bucket=weekly binding_resets_at=2026-08-01T06:00:00Z" \
  "a lane bound by its session window names the session bucket and reset||$LIST|eclaude.binding_bucket=session eclaude.binding_resets_at=2026-07-27T06:00:00Z nclaude.binding_bucket=weekly openclaude.binding_bucket=null"

echo "=== argument handling ==="
table \
  'an unknown harness is rejected||pick --harness bogus|rc=1' \
  'an unknown subcommand is rejected||bogus|rc=1' \
  'a malformed --max-pct is rejected||list --max-pct 999x|rc=1'

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
