#!/usr/bin/env bash
# Tests for the `lanes` helper: discovery, measurement, aliases, pick, and the
# in-flight claim store. The network layer is the only impure part of `lanes`
# and is injected through ORCH_LANES_FETCH_CMD and ORCH_LANES_TOKEN_CMD, or, for
# the rows that exercise the real curl calls, through a `curl` shim first on
# PATH, so every row here runs offline against fixed responses; a chooser tested
# against live accounts would assert whatever today's usage happens to be. open-terminal's --lane wiring is
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
# The two thresholds the checkout configures. Every run that asserts a threshold
# goes through run_lanes or claims_table, which run from outside the checkout as
# well, so neither the environment nor kendex.settings.toml supplies one: those
# rows assert the script's default, and a row that wants a setting passes it.
# The two direct $LANES calls below, in stage_cache and in the renewal ceiling,
# run from the checkout and assert no threshold.
unset ORCH_LANE_MAX_PCT ORCH_HANDOFF_HEADROOM_PCT
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

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$TEST_DIR/lib/lanes-fixture.sh"
# mutant_scripts and mutate_file, the two halves of the must-fail controls below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"

# Every run is made from here, with the ceiling stopping git one level above
# it: `lanes` resolves its project root from the working directory, so a run
# made in the checkout reads the checkout kendex.settings.toml and this suite
# would assert the repository configuration rather than the script defaults.
# It is a git repository carrying no settings, not a bare directory: `lane-host`
# takes its own root from `git rev-parse` on the working directory, so outside
# every repository the provider verb dies and the hosted rows below lose the
# answer they are asserting.
NOSETTINGS="$TMP_ROOT/nosettings"; mkdir -p "$NOSETTINGS"
git -C "$NOSETTINGS" init -q -b main

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
  OUT=$(cd "$NOSETTINGS" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" \
    LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" FETCH_LOG="$RUN/fetch.log" \
    FETCH_SEQ_DIR="$RUN/fetchseq" TOKEN_LOG="$RUN/token.log" \
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
#   key                   the first keyed stderr line, `key,field=value,...`
#   keyed.<key>           the first keyed stderr line carrying that key, in the
#                         same form, or none
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
      # Every listed lane's status, sorted, so a row can assert that a word
      # reaches NO lane of a listing rather than only what one lane reads.
      statuses) value="$(json '[.[].status] | sort | join(",")')" ;;
      # The User-Agent the renewal handed the token stub, with the version it
      # read replaced by `V`: the endpoint matches the `claude-cli/` prefix and
      # does not parse the version, so the shape is the contract and this host's
      # installed version is not. Underscored, since `expect` splits on
      # whitespace. `UNSET` is the stub's own word for a renewal that named none.
      ua)
        value="$(sed -n '1p' "$UA_LOG" 2>/dev/null | sed 's#^claude-cli/[^ ][^ ]*#claude-cli/V#' || true)"
        value="${value// /_}"; value="${value:-none}"
        ;;
      # The stub's argument vector. On Linux /proc/<pid>/cmdline is
      # world-readable, and the header the endpoint gates on is what tells a
      # reader which account is being renewed from where.
      uaargv) value="$(sed -n '2p' "$UA_LOG" 2>/dev/null || true)"; value="${value:-none}" ;;
      # How long the refusal this run recorded parks the lane for, read out of
      # the record the run itself wrote, so a row pins whether the endpoint's
      # own Retry-After or the script's default set the window.
      refusalwindow)
        value="$(jq -r '.refusal.expires_at - .fetched_at' "$RUN"/store/usage/*.json 2>/dev/null || true)"
        value="${value:-none}"
        ;;
      files) value="$(ls -1 "$STORE/claims" 2>/dev/null | sed 's/\.claim$//' | paste -sd, - || true)"; [[ -n "$value" ]] || value=none ;;
      fetched) value="$(fetched_lanes "$RUN/fetch.log")" ;;
      tokencalls) value="$(grep -c . "$RUN/token.log" 2>/dev/null || true)"; value="${value:-0}" ;;
      # Every jq argument vector of the run, searched for the fixture's own
      # refresh token and for both tokens the endpoint stub hands back.
      jqsecrets) value="$(grep -c -e refresh-claude -e renewed-token -e rotated-refresh "$JQ_ARGV_LOG" 2>/dev/null || true)"; value="${value:-0}" ;;
      newtoken) value="$(jq -r '.claudeAiOauth.accessToken' "$H/.claude/.credentials.json" 2>/dev/null || echo UNREADABLE)" ;;
      newrefresh) value="$(jq -r '.claudeAiOauth.refreshToken' "$H/.claude/.credentials.json" 2>/dev/null || echo UNREADABLE)" ;;
      cachefiles) value="$(cat "$RUN/store/usage"/*.json 2>/dev/null | jq -r 'select(.usage) | .config_dir' | sed "s#^$H/\\.##" | sort | paste -sd, - || true)"; [[ -n "$value" ]] || value=none ;;
      # The chooser adds a working field to rank candidates on. A record that
      # carried it out would put the chooser's own scratch in every consumer's
      # lane record.
      haswall) value="$(json 'has("wall")')" ;;
      # Every listed row as `<alias>:<credential it was measured through>`, in
      # listing order, so a row pins which reading each figure came from and
      # not merely that two rows exist.
      through) value="$(json '[.[] | .alias + ":" + (.measured_through // "absent")] | join(",")')" ;;
      # The first keyed line on stderr as `key,field=value,...`, so a row pins
      # the refusal it is about rather than the English under it. `expect`
      # splits on whitespace, hence the commas.
      key)
        value="$(awk '$1 == "lanes:" { $1 = ""; sub(/^ +/, ""); gsub(/ +/, ","); print; exit }' "$ERR" 2>/dev/null || true)"
        value="${value:-none}"
        ;;
      # A notice another keyed line can precede: a state directory that cannot
      # hold a refusal cannot hold the refresh lock either, and that notice is
      # printed first.
      keyed.*)
        value="$(awk -v k="${name#keyed.}" '$1 == "lanes:" && $2 == k { $1 = ""; sub(/^ +/, ""); gsub(/ +/, ","); print; exit }' "$ERR" 2>/dev/null || true)"
        value="${value:-none}"
        ;;
      first.model_label)
        value="$(json '.[0].model_label')"
        value="${value// /_}"
        ;;
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
      # Every scoped window of the only listed lane, `label:pct` in order.
      # Underscored, since `expect` splits on whitespace.
      first.buckets) value="$(json '[.[0].model_buckets[] | "\(.label):\(.pct)"] | join(",")')"; value="${value// /_}" ;;
      first.*) value="$(json ".[0].${name#first.}")" ;;
      last.*) value="$(json ".[-1].${name#last.}")" ;;
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

# lanes_mutant NAME FILE PATTERN [REPLACEMENT] — mutant_scripts NAME FILE with
# one line of FILE, a path relative to scripts/, mutated; its caller then runs
# $TMP_ROOT/NAME/scripts/lanes. PATTERN is a basic regular expression; its
# occurrence count is asserted as 1 before and 0 after, so a pattern that
# stopped matching reddens a row instead of leaving a mutant that mutates
# nothing. With no REPLACEMENT the line is deleted. It prints nothing but those
# assertions — a caller capturing its output would capture them too.
#
# The after-count is 0, so a mutation whose REPLACEMENT keeps the matched text
# cannot use this helper and asserts its own post-condition instead.
lanes_mutant() {
  local dir file="$2"
  dir="$(mutant_scripts "$1" "$file")" || exit 1
  assert_eq "$(grep -c -e "$3" "$dir/$file")" "1" "control $1 finds exactly one line to mutate"
  if [[ $# -ge 4 ]]; then sed -i.bak "s/$3/$4/" "$dir/$file"
  else sed -i.bak "/$3/d" "$dir/$file"; fi
  assert_eq "$(grep -c -e "$3" "$dir/$file")" "0" "control $1 applied its mutation"
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

echo "=== list: each record's verdict is pick's own wall judgement ==="
# nclaude's weekly 95 meets the default bound, eclaude's session 80 meets it
# only once the setting lowers the bound to 80, and a lane nothing measured is
# neither room nor a wall.
table \
  "under the default bound a lane at 95 is walled, one at 80 has room and one with no credentials is unmeasured||$LIST|claude.verdict=room eclaude.verdict=room nclaude.verdict=walled openclaude.verdict=unmeasured" \
  "the verdict follows ORCH_LANE_MAX_PCT, so a lane at 80 is walled under a bound of 80|ORCH_LANE_MAX_PCT=80|$LIST|claude.verdict=room eclaude.verdict=walled"

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
  "pick --json returns the whole lane record and the qualifying set size||pick --harness claude --json|alias=claude qualifying_count=2" \
  "excluding the caller leaves the one other qualifying account|ORCH_LANE_DIRS=$H/.claude:$H/.eclaude:$H/.nclaude|pick --harness claude --exclude-lane $H/.claude --json|alias=eclaude qualifying_count=1" \
  "pick exits 3 when no lane is under the threshold||pick --harness claude --max-pct 15|rc=3"

echo "=== unmeasurable lanes are never idle ==="
# An expired login, an authenticated lane whose usage body carries none of the
# consumer windows (a real enterprise plan), and an unreachable API each report
# their status with null headroom, and pick never chooses them.
new_home expired
make_dead_lane "$H" claude
make_lane "$H" eclaude 3600
claude_usage 90 90 90 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 40 40 40 Opus > "$FIXTURE_DIR/.eclaude.json"
table \
  "an expired login is reported as expired with null headroom|ORCH_LANES_CLAUDE_CLIENT_ID=client-1|$LIST|claude.status=expired claude.headroom_pct=null" \
  "pick skips an expired lane|ORCH_LANES_CLAUDE_CLIENT_ID=client-1|pick --harness claude|rc=0 out=CLAUDE_CONFIG_DIR=$H/.eclaude"
# With no client id the renewal fails on this machine's own setting before it
# reads the credentials, so the login is untested: `error`, never `expired`,
# which would send the operator to a re-login that fixes nothing.
NO_CLIENT_CAUSE="access_token_expired_and_could_not_be_renewed:_no_OAuth_client_id_is_configured_(ORCH_LANES_CLAUDE_CLIENT_ID)"
table \
  "an expired lane with no client id configured reads error, naming the setting|ORCH_LANES_CLAUDE_CLIENT_ID=|$LIST|claude.status=error claude.cause=$NO_CLIENT_CAUSE"
# The suite's one must-fail control on `list`: the missing client id read as
# expired again.
lanes_mutant mutant-no-client lanes "token_refusal error '' '' 'no OAuth client id" "token_refusal expired '' '' 'no OAuth client id"
LANES="$TMP_ROOT/mutant-no-client/scripts/lanes"
table \
  "control: with the missing client id read as expired, the lane sends its operator to a re-login|ORCH_LANES_CLAUDE_CLIENT_ID=|$LIST|claude.status=expired"
LANES="$SCRIPTS_DIR/lanes"
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
# The token request body arrives on stdin; the endpoint's answer goes to stdout
# in the shape `lanes` reads: the HTTP status and any Retry-After on the first
# line, the JSON body under it. LANES_USER_AGENT carries the header the real
# POST would have sent, logged here so a row can assert it.
cat >/dev/null
[[ -z "${TOKEN_LOG:-}" ]] || printf 'refresh\n' >> "$TOKEN_LOG"
[[ -z "${TOKEN_UA_LOG:-}" ]] || printf '%s\nargv=%s\n' "${LANES_USER_AGENT-UNSET}" "$*" >> "$TOKEN_UA_LOG"
printf '200 \n{"access_token":"renewed-token","refresh_token":"rotated-refresh","expires_in":3600}\n'
STUB
chmod +x "$TOKEN_OK"
TOKEN_BAD="$TMP_ROOT/token-bad"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "200 \\n{}"\n' > "$TOKEN_BAD"
chmod +x "$TOKEN_BAD"
# An access token with no expires_in. The empty object above never reaches the
# expiry refusal, because the missing access token refuses first.
TOKEN_NOEXP="$TMP_ROOT/token-noexp"
cat > "$TOKEN_NOEXP" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '200 \n{"access_token":"renewed-token","refresh_token":"rotated-refresh"}\n'
STUB
chmod +x "$TOKEN_NOEXP"
# Zero is a number and not a lifetime: it dates the new expiry to this instant,
# so the lane would return renewed and the next run would renew it again.
TOKEN_ZEROEXP="$TMP_ROOT/token-zeroexp"
cat > "$TOKEN_ZEROEXP" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '200 \n{"access_token":"renewed-token","refresh_token":"rotated-refresh","expires_in":0}\n'
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
make_dead_lane "$H" claude
table \
  "an expired lane with no refresh token beside it names that, and never reaches the endpoint|ORCH_LANES_CLAUDE_CLIENT_ID=client-1;ORCH_LANES_TOKEN_CMD=$TOKEN_OK|$LIST|claude.status=expired claude.refreshable=false claude.cause=access_token_expired_and_could_not_be_renewed:_there_is_no_refresh_token_in_$H/.claude/.credentials.json_to_renew_with tokencalls=0"

echo "=== the renewal names itself to the token endpoint ==="
# platform.claude.com answers HTTP 429 `rate_limit_error` to a token POST
# carrying no User-Agent, whatever the rate: it matches the `claude-cli/` prefix
# and does not parse the version. That is why an interactive launch renews an
# account this script could not, and it is the root cause under every row below.
# The header reaches the injected command through its ENVIRONMENT, the way it
# reaches curl, so the stub reads what a real POST would have sent and no local
# user reads it off /proc/<pid>/cmdline.
UA_LOG="$TMP_ROOT/token-ua.log"
new_home token-ua
make_lane "$H" claude -60
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
: > "$UA_LOG"
table \
  "the renewal posts a claude-cli User-Agent, and puts it on no argument vector|$REFRESH_ENV;TOKEN_UA_LOG=$UA_LOG|$LIST|claude.status=ok claude.refreshable=true ua=claude-cli/V_(external,_cli) uaargv=argv="

echo "=== a refused endpoint is reported by its HTTP code, never as an expired login ==="
# `expired` means a proven-dead login downstream: open-terminal turns it into a
# remedy line telling the operator to log in again on this machine. A rate limit
# and a server fault are refusals the account survives, so neither may take it,
# and a 400 or 401 still must.
#
# One stub for every code a row stages: TOKEN_STATUS is the status it answers,
# TOKEN_RETRY the Retry-After beside it, and the error object is what the real
# endpoint carries.
TOKEN_STATUS_STUB="$TMP_ROOT/token-status"
cat > "$TOKEN_STATUS_STUB" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
[[ -z "${TOKEN_LOG:-}" ]] || printf 'refresh\n' >> "$TOKEN_LOG"
printf '%s %s\n' "${TOKEN_STATUS:-429}" "${TOKEN_RETRY:-}"
printf '{"error":{"type":"%s","message":"%s"}}\n' \
  "${TOKEN_ERR_TYPE:-rate_limit_error}" "${TOKEN_ERR_MSG:-Rate limited. Please try again later.}"
STUB
chmod +x "$TOKEN_STATUS_STUB"
RL_ENV="ORCH_LANES_CLAUDE_CLIENT_ID=client-1;ORCH_LANES_TOKEN_CMD=$TOKEN_STATUS_STUB"
RL_429_CAUSE="access_token_expired_and_could_not_be_renewed:_the_token_endpoint_refused_the_renewal_with_HTTP_429_(rate_limit_error:_Rate_limited._Please_try_again_later.)"

new_home token-refused
make_lane "$H" claude -60
make_lane "$H" eclaude 3600
claude_usage 10 20 5  Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 40 40 40 Opus > "$FIXTURE_DIR/.eclaude.json"
table \
  "a token endpoint answering 429 reads rate_limited, its detail naming the code and the endpoint's own error|$RL_ENV|$LIST|claude.status=rate_limited claude.refreshable=false claude.headroom_pct=null claude.cause=$RL_429_CAUSE" \
  "and no account on that host reads expired, which is the reading that sends an operator to log in again|$RL_ENV|$LIST|statuses=ok,rate_limited" \
  "a token endpoint answering 503 reads unreachable, the login left untested|$RL_ENV;TOKEN_STATUS=503;TOKEN_ERR_TYPE=api_error;TOKEN_ERR_MSG=Overloaded|$LIST|claude.status=unreachable claude.headroom_pct=null claude.cause=access_token_expired_and_could_not_be_renewed:_the_token_endpoint_refused_the_renewal_with_HTTP_503_(api_error:_Overloaded)" \
  "a token endpoint answering 400 is still the proven-dead login expired exists for, with its code in the detail|$RL_ENV;TOKEN_STATUS=400;TOKEN_ERR_TYPE=invalid_grant;TOKEN_ERR_MSG=Refresh token not found|$LIST|claude.status=expired claude.headroom_pct=null claude.cause=access_token_expired_and_could_not_be_renewed:_the_token_endpoint_refused_the_renewal_with_HTTP_400_(invalid_grant:_Refresh_token_not_found)" \
  "a token endpoint answering 401 reads expired too|$RL_ENV;TOKEN_STATUS=401;TOKEN_ERR_TYPE=invalid_grant;TOKEN_ERR_MSG=Refresh token not found|$LIST|claude.status=expired claude.cause=access_token_expired_and_could_not_be_renewed:_the_token_endpoint_refused_the_renewal_with_HTTP_401_(invalid_grant:_Refresh_token_not_found)" \
  "a 200 answer carrying an error object but no token names that error beside the missing token|$RL_ENV;TOKEN_STATUS=200;TOKEN_ERR_TYPE=invalid_request;TOKEN_ERR_MSG=bad body|$LIST|claude.status=expired claude.cause=access_token_expired_and_could_not_be_renewed:_the_token_endpoint_returned_no_access_token_(invalid_request:_bad_body)"

# A token POST that never reached the endpoint (DNS, a refused connection, the
# timeout) proves nothing about the login, and carries no code, so no window is
# recorded for it and the next run posts again. The pair shares one state
# directory, which is what the second row reads.
UNREACHED_STATE="$TMP_ROOT/token-unreached-state"
UNREACHED_ENV="ORCH_LANES_CLAUDE_CLIENT_ID=client-1;ORCH_LANES_TOKEN_CMD=false;OVERSEE_WATCH_STATE_DIR=$UNREACHED_STATE"
UNREACHED_CAUSE="access_token_expired_and_could_not_be_renewed:_the_token_endpoint_could_not_be_reached"
# unreached_home — a fresh expired lane and an empty state directory, since the
# second row of the pair renews the lane it measured.
unreached_home() {
  new_home token-unreached
  make_lane "$H" claude -60
  claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  rm -rf -- "${UNREACHED_STATE:?}"
}
unreached_home
table \
  "a token POST that never reached the endpoint reads unreachable, and no account reads expired|$UNREACHED_ENV|$LIST|claude.status=unreachable statuses=unreachable claude.cause=$UNREACHED_CAUSE"
assert_eq "$(find "$UNREACHED_STATE" -path '*/usage/*.json' 2>/dev/null | grep -c . || true)" "0" \
  "and it records no refusal window, since no endpoint answered"
table \
  "so the next run on that state directory posts again and renews the lane|$REFRESH_ENV;OVERSEE_WATCH_STATE_DIR=$UNREACHED_STATE|$LIST|claude.status=ok claude.refreshable=true tokencalls=1"

new_home usage-refused
make_lane "$H" claude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
table \
  "a usage endpoint answering 503 reads unreachable with that code in its detail, not the fixed offline sentence|FETCH_STATUS=503|$LIST|first.status=unreachable first.headroom_pct=null claude.cause=usage_query_refused_with_HTTP_503" \
  "a usage endpoint answering 429 reads rate_limited on the same judgement the token endpoint takes|FETCH_STATUS=429|$LIST|first.status=rate_limited claude.cause=usage_query_refused_with_HTTP_429" \
  "a usage query that could not be run at all still reads unreachable, with no code to name|ORCH_LANES_FETCH_CMD=false|$LIST|first.status=unreachable claude.cause=usage_query_could_not_be_run" \
  "a usage endpoint answering 2xx with no body reads unreachable, naming the code it answered|FETCH_STATUS=204|$LIST|first.status=unreachable claude.cause=usage_query_answered_HTTP_204_with_no_body"

echo "=== a recorded refusal parks the lane for its window, and nothing re-posts inside it ==="
# The fleet measures every thirty seconds and several overseers share one state
# directory, so a refusal one of them met is one they all must read: re-posting
# is what sustains a rate limit.
new_home refusal-window
make_lane "$H" claude -60
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
REFUSAL_STATE="$TMP_ROOT/refusal-state"
# stage_refusal AGE_S WINDOW_S — the refusal the first run recorded, re-dated
# AGE_S seconds into the past and its window re-set to WINDOW_S from now, so a
# row asserting the record's own age or a window that has passed asserts a
# fixed number rather than whatever the clock did between two runs.
stage_refusal() {
  local f now
  now="$(date +%s)"
  for f in "$REFUSAL_STATE"/usage/*.json; do
    [[ -f "$f" ]] || continue
    jq --argjson at "$(( now - $1 ))" --argjson until "$(( now + $2 ))" \
      '.fetched_at = $at | .refusal.expires_at = $until' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    return 0
  done
  echo "stage_refusal: the first run recorded no refusal to stage" >&2
  exit 1
}
rm -rf -- "${REFUSAL_STATE:?}"
run_lanes "$RL_ENV;OVERSEE_WATCH_STATE_DIR=$REFUSAL_STATE" $LIST
stage_refusal 45 120
table \
  "a second run inside the window reports the recorded refusal with its code and its own age, and posts nothing|$RL_ENV;OVERSEE_WATCH_STATE_DIR=$REFUSAL_STATE|$LIST|claude.status=rate_limited claude.cause=$RL_429_CAUSE claude.aged=30+ tokencalls=0"
stage_refusal 45 120
table \
  "--no-cache declines a cached figure, never a live refusal window: the one caller asking for a fresh reading is not the one that re-posts|$RL_ENV;OVERSEE_WATCH_STATE_DIR=$REFUSAL_STATE|$LIST --no-cache|claude.status=rate_limited tokencalls=0"
# The window's far side: a refusal that parked a lane for good would be the
# worse failure, so the run after it passes posts again.
stage_refusal 45 -1
table \
  "once the window has passed the next run posts to the endpoint again|$RL_ENV;OVERSEE_WATCH_STATE_DIR=$REFUSAL_STATE|$LIST|claude.status=rate_limited tokencalls=1"

# The window itself: the endpoint knows when it will answer again, and says so.
new_home refusal-retry-after
make_lane "$H" claude -60
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
table \
  "the window is the answer's own Retry-After where it named one|$RL_ENV;TOKEN_RETRY=900|$LIST|claude.status=rate_limited refusalwindow=900" \
  "and the script's own five minutes where the answer named none|$RL_ENV|$LIST|claude.status=rate_limited refusalwindow=300" \
  "a Retry-After written as an HTTP date names no seconds to wait, so the default window stands|$RL_ENV;TOKEN_RETRY=Wed, 21 Oct 2026 07:28:00 GMT|$LIST|claude.status=rate_limited refusalwindow=300"

new_home usage-refusal-window
make_lane "$H" claude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
USAGE_REFUSAL_STATE="$TMP_ROOT/usage-refusal-state"
rm -rf -- "${USAGE_REFUSAL_STATE:?}"
run_lanes "FETCH_STATUS=503;OVERSEE_WATCH_STATE_DIR=$USAGE_REFUSAL_STATE" $LIST
table \
  "a recorded usage refusal is read the same way, and the second run fetches nothing even though the endpoint would now answer|OVERSEE_WATCH_STATE_DIR=$USAGE_REFUSAL_STATE|$LIST|first.status=unreachable claude.cause=usage_query_refused_with_HTTP_503 fetched=none"

# The usage endpoint's own Retry-After sets its window as the token endpoint's
# does.
new_home usage-refusal-retry-after
make_lane "$H" claude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
table \
  "a usage refusal is waited out for the endpoint's own Retry-After|FETCH_STATUS=429;FETCH_RETRY_AFTER=900|$LIST|first.status=rate_limited refusalwindow=900"

# A refusal the state directory cannot hold leaves every caller re-posting each
# pass, so the failure is a keyed notice naming the directory; the lane is still
# reported. The usage path is a regular file here, so only that write fails.
new_home refusal-unrecorded
make_lane "$H" claude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
UNRECORDED_STATE="$TMP_ROOT/refusal-unrecorded-state"
rm -rf -- "${UNRECORDED_STATE:?}"
mkdir -p "$UNRECORDED_STATE"
: > "$UNRECORDED_STATE/usage"
table \
  "a refusal that cannot be recorded is a notice naming the state directory, and the lane is still reported|FETCH_STATUS=429;OVERSEE_WATCH_STATE_DIR=$UNRECORDED_STATE|$LIST|rc=0 first.status=rate_limited keyed.refusal-unrecorded=refusal-unrecorded,dir=$UNRECORDED_STATE/usage"

echo "=== the real POST and GET, read through a curl shim ==="
# Every other row injects ORCH_LANES_TOKEN_CMD or ORCH_LANES_FETCH_CMD, so none
# runs the curl branches or http_answer, the only parser of a real answer. These
# rows leave both unset and put a `curl` first on PATH that logs the User-Agent
# it was handed and prints a canned `-D - -w '\n%{http_code}'` capture. Both URLs
# are under the reserved .invalid domain, so a real curl reached by mistake
# fails to resolve rather than reaching an endpoint.
CURL_BIN="$TMP_ROOT/curl-bin"; mkdir -p "$CURL_BIN"
cat > "$CURL_BIN/curl" <<'STUB'
#!/usr/bin/env bash
# The token POST carries its body on stdin and the usage GET its bearer header
# (-K -); both are read and dropped. The URL argument names the endpoint, and
# CURL_TOKEN_ANSWER or CURL_USAGE_ANSWER names the capture it answers with.
cat >/dev/null
ua=UNSET endpoint=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -A) ua="$2"; shift ;;
    "$ORCH_LANES_CLAUDE_TOKEN_URL") endpoint=token ;;
    "$ORCH_LANES_CLAUDE_USAGE_URL") endpoint=usage ;;
  esac
  shift
done
case "$endpoint" in
  token)
    [[ -z "${TOKEN_LOG:-}" ]] || printf 'refresh\n' >> "$TOKEN_LOG"
    [[ -z "${TOKEN_UA_LOG:-}" ]] || printf '%s\n' "$ua" >> "$TOKEN_UA_LOG"
    answer="${CURL_TOKEN_ANSWER:-}"
    ;;
  usage) answer="${CURL_USAGE_ANSWER:-}" ;;
  *) printf 'curl shim: no endpoint this suite answers\n' >&2; exit 6 ;;
esac
[[ -f "$answer" ]] || { printf 'curl shim: no capture for %s\n' "$endpoint" >&2; exit 6; }
cat "$answer"
STUB
chmod +x "$CURL_BIN/curl"
CURL_ENV="ORCH_LANES_FETCH_CMD=;ORCH_LANES_CLAUDE_TOKEN_URL=https://token.lanes-test.invalid/v1/oauth/token;ORCH_LANES_CLAUDE_USAGE_URL=https://usage.lanes-test.invalid/api/oauth/usage;PATH=$CURL_BIN:$CLAIM_BIN:$PATH"
CAPTURES="$TMP_ROOT/curl-captures"; mkdir -p "$CAPTURES"
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"access_token":"renewed-token","refresh_token":"rotated-refresh","expires_in":3600}\n200' \
  > "$CAPTURES/token-200"
{ printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n'; claude_usage 10 20 5 Opus; printf '\n200'; } \
  > "$CAPTURES/usage-200"
# An interim 100 block ahead of the real headers, CRLF line ends, and the
# Retry-After among them: every rule of the parser at once.
printf 'HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nRetry-After: 900\r\n\r\n{"error":{"type":"rate_limit_error","message":"Rate limited. Please try again later."}}\n429' \
  > "$CAPTURES/token-429"
printf 'HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\n\r\nupstream connect error\n503' \
  > "$CAPTURES/usage-503"
# A Retry-After on the interim block and none on the refusal: the interim
# block's header is not the refusal's own.
printf 'HTTP/1.1 100 Continue\r\nRetry-After: 900\r\n\r\nHTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\n\r\n{"error":{"type":"rate_limit_error"}}\n429' \
  > "$CAPTURES/usage-429-interim-retry"
CURL_RENEW_ENV="$CURL_ENV;ORCH_LANES_CLAUDE_CLIENT_ID=client-1;TOKEN_UA_LOG=$UA_LOG;CURL_TOKEN_ANSWER=$CAPTURES/token-200;CURL_USAGE_ANSWER=$CAPTURES/usage-200"
CURL_429_ENV="$CURL_ENV;ORCH_LANES_CLAUDE_CLIENT_ID=client-1;CURL_TOKEN_ANSWER=$CAPTURES/token-429"
# curl_home NAME EXPIRES_IN_S — a fresh home with one lane and its usage fixture.
curl_home() {
  new_home "$1"
  make_lane "$H" claude "$2"
  claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  : > "$UA_LOG"
}
curl_home curl-renew -60
table \
  "the real renewal POST carries the claude-cli User-Agent, and its 200 answer renews the lane|$CURL_RENEW_ENV|$LIST|claude.status=ok claude.refreshable=true claude.headroom_pct=80 ua=claude-cli/V_(external,_cli) tokencalls=1"
curl_home curl-429 -60
table \
  "a real 429 behind a 100 Continue block, with CRLF headers, reads rate_limited and is parked for its Retry-After|$CURL_429_ENV|$LIST|claude.status=rate_limited claude.cause=$RL_429_CAUSE refusalwindow=900"
curl_home curl-usage-503 3600
table \
  "a real usage answer of 503 reads unreachable with that code in its detail|$CURL_ENV;CURL_USAGE_ANSWER=$CAPTURES/usage-503|$LIST|first.status=unreachable claude.cause=usage_query_refused_with_HTTP_503"
curl_home curl-usage-interim 3600
table \
  "a Retry-After on an interim block is not the refusal's, so a 429 naming none takes the default window|$CURL_ENV;CURL_USAGE_ANSWER=$CAPTURES/usage-429-interim-retry|$LIST|first.status=rate_limited refusalwindow=300"

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
    # The same name run_lanes uses, so `observe` reads one stderr path whichever
    # helper drove the run.
    ERR="$RUN/stderr"
    stage_panes "$panes"
    stage_claims "$claims"
    case "$perm" in
      store) chmod 000 "$STORE/claims" ;;
      file:*) chmod 000 "$STORE/claims/${perm#file:}.claim" ;;
    esac
    # shellcheck disable=SC2086
    OUT=$(cd "$NOSETTINGS" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" \
      LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" OVERSEE_WATCH_STATE_DIR="$STORE" \
      TMUX_PANES_FILE="$PANES" PATH="$PANES_PATH:$PATH" "$LANES" $args 2>"$ERR")
    RC=$?
    case "$perm" in
      store) chmod 755 "$STORE/claims" ;;
      file:*) chmod 644 "$STORE/claims/${perm#file:}.claim" ;;
    esac
    chmod -R u+rw "$RUN" 2>/dev/null || true
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
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
  "the one-lane form counts the same claims the fleet pick and the listing do|live:%1,live:%2|one:live:%1:claude||pick --lane $H/.claude --harness claude --json|rc=0 claims=1" \
  "a malformed claim record is dropped on read|live:%1|junk||$LIST|files=none"

# Root reads a mode-000 path, so these rows cannot fail a read there.
if [[ "$(id -u)" -eq 0 ]]; then
  printf '  skip  unreadable store, file and pane rows (running as root)\n'
else
  claims_table \
    "a failed re-enumeration prunes nothing the first snapshot proved live, nor the record that provoked it|1=live:%1,live:%4;2=FAIL;*=live:%1|live4:live:%4:claude;gone5:live:%5:eclaude||$LIST|claude.claims=1 eclaude.claims=1 files=gone5,live4" \
    "an unreadable claim store reports claims as unknown, never zero, and is never emptied|live:%7|keepme:live:%7:claude|store|$LIST|rc=0 claude.claims=null files=keepme" \
    "pick refuses when in-flight claims cannot be read|live:%7|keepme:live:%7:claude|store|$PICK|rc=1" \
    "the one-lane form notices an unreadable store and still answers the wall, which no claim count enters|live:%7|keepme:live:%7:claude|store|pick --lane $H/.claude --harness claude --json|rc=0 claims=null wall=20 key=pick-lane-claims,claims=null" \
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
    [[ -f "$f" && "$(jq -r 'select(.usage) | .config_dir' "$f")" == "$H/.claude" ]] || continue
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

# The displaced cache record is the prior sample. The lane record reports a
# rate only when the samples are at least a minute apart and usage increased.
stage_rate() { # CURRENT PRIOR GAP
  local f now
  stage_cache 0
  now="$(date +%s)"
  for f in "$CACHE_STATE"/usage/*.json; do
    [[ -f "$f" && "$(jq -r '.config_dir' "$f")" == "$H/.claude" ]] || continue
    jq --argjson now "$now" --argjson gap "$3" \
      --argjson current "$(claude_usage "$1" 20 5 Opus)" \
      --argjson prior "$(claude_usage "$2" 20 5 Opus)" \
      '.fetched_at = $now | .usage = $current
       | .prior = {fetched_at: ($now - $gap), usage: $prior}' "$f" > "$f.tmp" \
      && mv "$f.tmp" "$f"
    return 0
  done
  return 1
}
RATE_LIST='list --harness claude --json'
stage_rate 40 20 600
table "two spaced samples expose a two-point rate and a thirty-minute wall|ORCH_LANE_DIRS=$H/.claude;OVERSEE_WATCH_STATE_DIR=$CACHE_STATE|$RATE_LIST|claude.usage_rate_pct_per_min=2 claude.projected_wall_minutes=30 claude.usage_rate_state=measured"
stage_rate 22 20 600
table "a slower positive rate exposes its later projected wall|ORCH_LANE_DIRS=$H/.claude;OVERSEE_WATCH_STATE_DIR=$CACHE_STATE|$RATE_LIST|claude.projected_wall_minutes=390 claude.usage_rate_state=measured"
stage_rate 40 20 30
table "samples less than a minute apart report an unmeasured rate|ORCH_LANE_DIRS=$H/.claude;OVERSEE_WATCH_STATE_DIR=$CACHE_STATE|$RATE_LIST|claude.projected_wall_minutes=null claude.usage_rate_state=samples-too-close"
stage_rate 20 20 600
table "a flat rate reports unmeasured rather than healthy|ORCH_LANE_DIRS=$H/.claude;OVERSEE_WATCH_STATE_DIR=$CACHE_STATE|$RATE_LIST|claude.projected_wall_minutes=null claude.usage_rate_state=not-increasing"
# The Claude endpoint writes fractional seconds and +00:00. The prior sample
# and the current one are compared on their reset, so both take the one
# spelling or the rate is never measured.
stage_rate 40 20 600
for f in "$CACHE_STATE"/usage/*.json; do
  [[ -f "$f" && "$(jq -r '.config_dir' "$f")" == "$H/.claude" ]] || continue
  jq 'walk(if type == "object" and (.resets_at | type) == "string"
           then .resets_at |= sub("Z$"; ".123456+00:00") else . end)' "$f" > "$f.tmp" \
    && mv "$f.tmp" "$f"
done
assert_eq "$(jq -r 'select(.config_dir == "'"$H/.claude"'") | .usage.five_hour.resets_at + " " + .prior.usage.five_hour.resets_at' "$CACHE_STATE"/usage/*.json)" \
  "2026-07-27T06:00:00.123456+00:00 2026-07-27T06:00:00.123456+00:00" \
  "the staged samples carry the endpoint's fractional spelling"
table "fractional +00:00 resets on both samples still expose the rate|ORCH_LANE_DIRS=$H/.claude;OVERSEE_WATCH_STATE_DIR=$CACHE_STATE|$RATE_LIST|claude.usage_rate_state=measured claude.binding_resets_at=2026-07-27T06:00:00Z"
stage_cache 0
table "one sample reports an unmeasured rate|ORCH_LANE_DIRS=$H/.claude;OVERSEE_WATCH_STATE_DIR=$CACHE_STATE|$RATE_LIST|claude.projected_wall_minutes=null claude.usage_rate_state=one-sample"

retain_rate_samples() { # STATE
  local state="$1" f
  rm -rf -- "${state:?}"
  claude_usage 20 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  env LANES_HOME="$H" ORCH_LANE_DIRS="$H/.claude" ORCH_LANES_FETCH_CMD="$FETCHER" \
    OVERSEE_WATCH_STATE_DIR="$state" PATH="$CLAIM_BIN:$PATH" \
    "$LANES" list --harness claude --json --no-cache >/dev/null
  f="$(find "$state/usage" -type f -name '*.json' -print -quit)"
  jq --argjson at "$(( $(date +%s) - 600 ))" '.fetched_at = $at' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  claude_usage 40 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  env LANES_HOME="$H" ORCH_LANE_DIRS="$H/.claude" ORCH_LANES_FETCH_CMD="$FETCHER" \
    OVERSEE_WATCH_STATE_DIR="$state" PATH="$CLAIM_BIN:$PATH" \
    "$LANES" list --harness claude --json --no-cache >/dev/null
  OUT="$(env LANES_HOME="$H" ORCH_LANE_DIRS="$H/.claude" ORCH_LANES_FETCH_CMD="$FETCHER" \
    OVERSEE_WATCH_STATE_DIR="$state" PATH="$CLAIM_BIN:$PATH" \
    "$LANES" list --harness claude --json)"
}

retain_rate_samples "$TMP_ROOT/retained-rate"
assert_eq "$(jq -r '.[0].usage_rate_state' <<<"$OUT")" "measured" \
  "two real fetches retain the displaced first sample for the next cache read"

# A refresh answered after a usage 429 takes the figure kept beside that
# refusal as its prior, under the figure's own stamp: the refusal's stamp
# would read two samples ten minutes apart as seconds apart.
refused_prior_rate() { # STATE
  local state="$1" f
  rm -rf -- "${state:?}"
  claude_usage 20 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  env LANES_HOME="$H" ORCH_LANE_DIRS="$H/.claude" ORCH_LANES_FETCH_CMD="$FETCHER" \
    OVERSEE_WATCH_STATE_DIR="$state" PATH="$CLAIM_BIN:$PATH" \
    "$LANES" list --harness claude --json --no-cache >/dev/null
  age_usage_record "$state" "$H/.claude" 600
  env LANES_HOME="$H" ORCH_LANE_DIRS="$H/.claude" ORCH_LANES_FETCH_CMD="$FETCHER" \
    OVERSEE_WATCH_STATE_DIR="$state" PATH="$CLAIM_BIN:$PATH" \
    FETCH_STATUS=429 FETCH_RETRY_AFTER=600 \
    "$LANES" list --harness claude --json >/dev/null
  f="$(find "$state/usage" -type f -name '*.json' -print -quit)"
  jq '.refusal.expires_at = 0' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  claude_usage 40 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  OUT="$(env LANES_HOME="$H" ORCH_LANE_DIRS="$H/.claude" ORCH_LANES_FETCH_CMD="$FETCHER" \
    OVERSEE_WATCH_STATE_DIR="$state" PATH="$CLAIM_BIN:$PATH" \
    "$LANES" list --harness claude --json)"
}

refused_prior_rate "$TMP_ROOT/refused-prior"
assert_eq "$(jq -r '.[0] | "\(.status) \(.usage_rate_state)"' <<<"$OUT")" "ok measured" \
  "an answer after a 429 rates against the kept figure's own stamp"

echo "=== a refused usage refresh serves the last figures rather than walling the host ==="
# The control VM's failure: eleven accounts answered HTTP 429 with valid
# bearers while the shared cache held good reads seconds old, and every lane
# reported no windows at all. No rate limit is a credential problem, and a
# figure seconds old is not no figure.
#
# ORCH_LANES_USAGE_TTL=0 on these rows is what puts a request on the wire at
# all: it expires the cached figure for the FRESHNESS read while leaving the
# record itself for the refusal to fall back to, which is the state the control
# host was in and needs no clock to reach.
new_home ratelimit
make_lane "$H" claude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
RL_STATE="$TMP_ROOT/ratelimit-state"
RL_ENV="OVERSEE_WATCH_STATE_DIR=$RL_STATE;ORCH_LANE_DIRS=$H/.claude"
table \
  "a first run measures the account and leaves the figures it read|$RL_ENV|$LIST|first.status=ok first.headroom_pct=80 fetched=claude"
age_usage_record "$RL_STATE" "$H/.claude" 45
# The endpoint's body moves while it is refusing, so which figures a row
# reports says which record it served: 80 headroom is the cached one and 40 is
# the body that came back with the refusal. The stub answers both, as the
# control host's endpoint did, and with the `Retry-After: 0` the control VM
# received from every account.
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
printf '429 0\n' > "$FIXTURE_DIR/.claude.status"
table \
  "a 429 with a cached figure serves that figure as rate_limited, never as no reading|$RL_ENV;ORCH_LANES_USAGE_TTL=0|$LIST|first.status=rate_limited first.headroom_pct=80 claude.aged=30+ fetched=claude"
RL_RECORD="$(cat "$RL_STATE"/usage/*.json 2>/dev/null | jq -r 'select(.refusal) | [.config_dir, .refusal.code, (.refusal.expires_at - .fetched_at), (.usage | type)] | @tsv')"
assert_eq "$(cut -f1,2,4 <<<"$RL_RECORD")" "$H/.claude"$'\t'"429"$'\t'"object" \
  "the refusal is recorded in the lane's own record, under the code that gave it, with the figure it served kept beside it"
# A zero names no seconds to wait out, and honouring it is a retry loop at the
# rate being refused, so it takes the default window like an answer naming
# none. That window is wide enough for the rows below to sit inside on any
# runner.
assert_eq "window=$(cut -f3 <<<"$RL_RECORD")" "window=300" \
  "a Retry-After of 0 takes the default window, so the refusal is not re-posted in the second it arrived"
table \
  "a later caller inside that window posts nothing and still reports the figures|$RL_ENV;ORCH_LANES_USAGE_TTL=0|$LIST|first.status=rate_limited first.headroom_pct=80 fetched=none" \
  "--no-cache inside it posts nothing either: it asks for a fresh figure, not to re-post a refused request|$RL_ENV;ORCH_LANES_USAGE_TTL=0|$LIST --no-cache|first.status=rate_limited first.headroom_pct=80 fetched=none" \
  "and pick judges those served figures instead of walling every launch on the host|$RL_ENV;ORCH_LANES_USAGE_TTL=0|pick --harness claude|rc=0 out=CLAUDE_CONFIG_DIR=$H/.claude"

# A refusal the endpoint keeps giving never replaces the figure, so the figure
# it serves only grows older. Past the 5-hour session window it cannot say what
# that window holds now, and `pick` must not launch on it. Still inside the
# 300-second window recorded above, so no row here posts.
age_usage_record "$RL_STATE" "$H/.claude" 86400
table \
  "a figure a day old is not served under a refusal: the lane reports the refusal with no windows|$RL_ENV;ORCH_LANES_USAGE_TTL=0|$LIST|first.status=rate_limited first.headroom_pct=null claude.cause=usage_query_refused_with_HTTP_429 fetched=none" \
  "and pick refuses the host rather than launching on that figure|$RL_ENV;ORCH_LANES_USAGE_TTL=0|pick --harness claude|rc=3"
rm -f -- "${FIXTURE_DIR:?}/.claude.status"

echo "=== a refusal's window is counted from when the refusal arrived ==="
# A request slower than the window it is refused with would otherwise record a
# deadline already past, and the next caller would post to the same account at
# once. FETCH_DELAY holds the answer 3 seconds; the 2-second window then ends
# at least 5 seconds after this run started.
new_home ratelimit-slow
make_lane "$H" claude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
SLOW_STATE="$TMP_ROOT/ratelimit-slow-state"
SLOW_ENV="OVERSEE_WATCH_STATE_DIR=$SLOW_STATE;ORCH_LANE_DIRS=$H/.claude"
table "a first run leaves a figure to serve|$SLOW_ENV|$LIST|first.status=ok fetched=claude"
printf '429 2\n' > "$FIXTURE_DIR/.claude.status"
SLOW_BEFORE="$(date +%s)"
table "the slow refusal serves the cached figure|$SLOW_ENV;ORCH_LANES_USAGE_TTL=0;FETCH_DELAY=3|$LIST|first.status=rate_limited fetched=claude"
SLOW_UNTIL="$(cat "$SLOW_STATE"/usage/*.json 2>/dev/null | jq -r 'select(.refusal) | .refusal.expires_at')"
assert_eq "$([[ "$SLOW_UNTIL" =~ ^[0-9]+$ && "$SLOW_UNTIL" -ge "$((SLOW_BEFORE + 5))" ]] && echo from-answer || echo "from-request:$SLOW_UNTIL")" \
  "from-answer" \
  "the recorded deadline is the refusal's arrival plus its window, not the request's start"
rm -f -- "${FIXTURE_DIR:?}/.claude.status"

echo "=== an answer other than 2xx or 429 is unreachable and its body never cached ==="
# The endpoint's error bodies are JSON objects too, so only the status keeps
# one from being parsed as usage and written to the cache for the next caller.
# Each row takes a state directory of its own, so neither reads the refusal the
# other recorded.
new_home badstatus
make_lane "$H" claude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
for row in \
  "a 500 with a JSON body is unreachable, and the body is not cached|500|$TMP_ROOT/badstatus-500-state" \
  "a 401 with a JSON body is unreachable, and the body is not cached|401|$TMP_ROOT/badstatus-401-state"; do
  IFS='|' read -r label code state <<<"$row"
  printf '%s \n' "$code" > "$FIXTURE_DIR/.claude.status"
  run_lanes "OVERSEE_WATCH_STATE_DIR=$state;ORCH_LANE_DIRS=$H/.claude" $LIST
  assert_eq "$(observe 'first.status= first.headroom_pct= fetched=') body=$(jq -r 'select(.usage) | "cached"' "$state"/usage/*.json 2>/dev/null)" \
    "first.status=unreachable first.headroom_pct=null fetched=claude body=" "$label" "$ERR"
done
rm -f -- "${FIXTURE_DIR:?}/.claude.status"

echo "=== a 429 with nothing cached retries once before reporting the refusal ==="
# Nothing on this host has ever read this account, so there is no figure to
# stand in for the refused one and the lane reports the refusal with no
# windows. Both rows fetch TWICE, and the log is what proves the retry is a
# second request rather than a sleep before the same verdict.
new_home ratelimit-cold
make_lane "$H" claude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
COLD_STATE="$TMP_ROOT/ratelimit-cold-state"
COLD_ENV="OVERSEE_WATCH_STATE_DIR=$COLD_STATE;ORCH_LANE_DIRS=$H/.claude"
# The retry is refused with a window of its own. The first refusal's 1-second
# window has passed by the time the retry answers, so only a record of the
# RETRY's refusal keeps the next caller off the endpoint.
printf '429 1\n' > "$FIXTURE_DIR/.claude.status.1"
printf '429 600\n' > "$FIXTURE_DIR/.claude.status.2"
table \
  "refused twice with a cold cache, the lane reports the refusal with no windows|$COLD_ENV|$LIST|first.status=rate_limited first.headroom_pct=null fetched=claude,claude" \
  "the caller after it posts nothing and reports the refusal, the retry's being on record|$COLD_ENV|$LIST|first.status=rate_limited fetched=none"
# The inverse row: the SECOND request answers, so a retry that never
# happened would leave this row on the first refusal. A state directory of its
# own, so the window recorded above does not gate it. The answer also replaces
# the refusal the first request recorded: a refusal left standing would keep
# the next caller off an endpoint that answers again for its whole window.
rm -f -- "${FIXTURE_DIR:?}/.claude.status.2"
COLD_OK_STATE="$TMP_ROOT/ratelimit-cold-ok-state"
table \
  "with the second request answering, that same lane reads ok on what the retry brought back|OVERSEE_WATCH_STATE_DIR=$COLD_OK_STATE;ORCH_LANE_DIRS=$H/.claude|$LIST|first.status=ok first.headroom_pct=80 fetched=claude,claude"
COLD_OK_REFUSALS="$(cat "$COLD_OK_STATE"/usage/*.json 2>/dev/null | jq -r 'select(.refusal) | "refusal"' | grep -c . || true)"
assert_eq "refusals=${COLD_OK_REFUSALS:-0}" "refusals=0" \
  "the answer drops the refusal the first request recorded"
rm -f -- "${FIXTURE_DIR:?}/.claude.status.1"
# Lanes are measured one after another, so the retry is bounded per run: the
# first cold lane spends it and a later one reports its refusal at once.
make_lane "$H" eclaude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
printf '429 1\n' > "$FIXTURE_DIR/.claude.status"
printf '429 1\n' > "$FIXTURE_DIR/.eclaude.status"
COLD_PAIR_DIRS="ORCH_LANE_DIRS=$H/.claude:$H/.eclaude"
table \
  "two cold lanes refused in one run spend one retry between them|$COLD_PAIR_DIRS;OVERSEE_WATCH_STATE_DIR=$TMP_ROOT/cold-pair-state|$LIST|claude.status=rate_limited eclaude.status=rate_limited fetched=claude,claude,eclaude"
rm -f -- "${FIXTURE_DIR:?}/.claude.status" "${FIXTURE_DIR:?}/.eclaude.status"

echo "=== a caller naming its own pass interval is served its last figure ==="
# A watch whose pass is longer than the TTL finds the figure expired on every
# pass and fetches on every pass, which is the burst with no caller doing
# anything wrong. --max-age is that caller's own interval, and it only ever
# widens the TTL: a caller passing nothing, or less than the TTL, keeps the
# TTL it configured.
new_home maxage
make_lane "$H" claude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
MA_STATE="$TMP_ROOT/maxage-state"
MA_ENV="OVERSEE_WATCH_STATE_DIR=$MA_STATE;ORCH_LANE_DIRS=$H/.claude;ORCH_LANES_USAGE_TTL=60"
table "a first run leaves a figure to reuse|$MA_ENV|$LIST|fetched=claude"
age_usage_record "$MA_STATE" "$H/.claude" 120
table \
  "past the TTL with no interval named, the figure is fetched again|$MA_ENV|$LIST|fetched=claude"
age_usage_record "$MA_STATE" "$H/.claude" 120
table \
  "a caller naming a longer pass is served that same figure, with its age, and posts nothing|$MA_ENV|$LIST --max-age 300|first.status=ok claude.aged=30+ fetched=none" \
  "an interval that is not a whole number of seconds is refused before any lane is measured|$MA_ENV|$LIST --max-age 4m|rc=1 key=invalid-usage-max-age,value=4m"
# A pass SHORTER than the TTL leaves the TTL deciding: this figure is inside
# the configured 60 seconds and outside the named 10, and it is still served.
age_usage_record "$MA_STATE" "$H/.claude" 30
table \
  "an interval shorter than the TTL never narrows it|$MA_ENV|$LIST --max-age 10|claude.aged=30+ fetched=none"
table \
  "a TTL of 0 is never widened, so every run still fetches|$MA_ENV;ORCH_LANES_USAGE_TTL=0|$LIST --max-age 300|fetched=claude"
# The setting is the only road oversee-watch has to this reader: it hands the
# window to its judgement through the environment, never through argv.
age_usage_record "$MA_STATE" "$H/.claude" 120
table \
  "the setting widens the TTL the way --max-age does|$MA_ENV;ORCH_LANES_USAGE_MAX_AGE=300|$LIST|first.status=ok claude.aged=30+ fetched=none" \
  "a setting that is not a whole number of seconds is refused before any lane is measured|$MA_ENV;ORCH_LANES_USAGE_MAX_AGE=4m|$LIST|rc=1 key=invalid-usage-max-age,value=4m"
# A TTL written with a leading zero is decimal: 0300 is 300 seconds, so a
# shorter named pass leaves it deciding and a figure 250 seconds old is served.
age_usage_record "$MA_STATE" "$H/.claude" 250
table \
  "a zero-padded TTL is read in base 10 and a shorter pass never narrows it|$MA_ENV;ORCH_LANES_USAGE_TTL=0300|$LIST --max-age 200|claude.aged=30+ fetched=none"

echo "=== one host-wide refresh per window, whatever the number of callers ==="
# The TTL alone cannot do this: at expiry every caller's fetch lands in the
# same second, which is what put eleven accounts over the endpoint's rate at
# once. The lock is what turns N callers times M lanes into one refresh, and
# the second caller through re-reads the cache INSIDE it rather than fetching
# what the first has already brought back.
new_home lockshare
make_lane "$H" claude 3600
make_lane "$H" eclaude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 80 30 10 Opus > "$FIXTURE_DIR/.eclaude.json"
LOCK_LOG="$TMP_ROOT/lockshare-fetch.log"
# concurrent_fetches STATE_DIR ARGS... -- two `lanes ARGS` runs started
# together against one state directory and one log; prints the lanes fetched
# across both, each repeated once per request it served. Each call takes its OWN empty
# state directory rather than clearing a shared one, so no run can read a
# record the previous one left. FETCH_DELAY holds every request open long
# enough that two unsynchronized callers provably overlap, so a single count is
# the lock and not the scheduler.
concurrent_fetches() {
  local i state="$1"
  shift
  : > "$LOCK_LOG"
  for i in 1 2; do
    ( cd "$NOSETTINGS" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" LANES_HOME="$H" \
      FIXTURE_DIR="$FIXTURE_DIR" ORCH_LANES_FETCH_CMD="$FETCHER" FETCH_LOG="$LOCK_LOG" \
      FETCH_DELAY=1 ORCH_LANE_DIRS="$H/.claude:$H/.eclaude" \
      OVERSEE_WATCH_STATE_DIR="$state" PATH="$CLAIM_BIN:$PATH" \
      "$LANES" "$@" >/dev/null 2>&1 ) &
  done
  wait
  fetched_lanes "$LOCK_LOG"
}
assert_eq "$(concurrent_fetches "$TMP_ROOT/lockshare-locked" list --harness claude --json)" "claude,eclaude" \
  "two callers arriving together are one refresh of each account, not two"
# The single-account read open-terminal and lane-mail-check make before every
# launch and every turn end goes through the same lock on a miss.
assert_eq "$(concurrent_fetches "$TMP_ROOT/lockshare-pick" pick --lane "$H/.claude" --harness claude --json)" "claude" \
  "two pick --lane callers arriving together are one refresh of that account"

# NOFLOCK is this PATH with flock taken out, so a run takes the mkdir mutex
# file-lock.sh falls back to where flock is absent.
NOFLOCK="$TMP_ROOT/path-without-flock"
mkdir -p "$NOFLOCK"
(
  IFS=:
  for d in $PATH; do
    [[ -d "$d" ]] || continue
    ln -s "$d"/* "$NOFLOCK"/ 2>/dev/null || true
  done
)
rm -f -- "$NOFLOCK/flock"
assert_eq "$(PATH="$NOFLOCK" command -v flock > /dev/null 2>&1 && echo found || echo none)" "none" \
  "the probe PATH resolves no flock, so the mkdir mutex is the one taken"
# One run takes the lock once per lane it refreshes. With flock, closing the
# descriptor frees it; without, only the release removes the mutex, and a
# second cold lane would otherwise wait out its own run's first take, name a
# contention that is not there, and hold every other caller on the host until
# the run exits. The notice is the pin, so the row needs no clock.
NF_ENV="ORCH_LANE_DIRS=$H/.claude:$H/.eclaude;PATH=$CLAIM_BIN:$NOFLOCK"
table \
  "without flock, one run refreshing two cold lanes frees the mutex between them|$NF_ENV|$LIST|key=none fetched=claude,eclaude"

echo "=== a lane the cache can answer never waits for the refresh lock ==="
# `pick --lane` runs under lane-mail-check's 20-second ceiling. A lane whose
# figure is fresh has nothing to refresh, so another caller holding the lock
# over a slow fleet refresh must not hold this read too. The holder below takes
# the lock the way `lanes` does on this host: flock where it is installed, the
# mkdir mutex where it is not.
new_home lockwarm
make_lane "$H" claude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
LW_STATE="$TMP_ROOT/lockwarm-state"
LW_ENV="OVERSEE_WATCH_STATE_DIR=$LW_STATE;ORCH_LANE_DIRS=$H/.claude"
LW_LOCK="$LW_STATE/usage/.usage-refresh.lock"
table "a first run leaves a fresh figure|$LW_ENV|$LIST|fetched=claude"
# hold_usage_lock LOCK_FILE / release_usage_lock LOCK_FILE: the holder is a
# background process for flock, whose lock the kernel drops when it is killed.
LOCK_HOLDER=""
hold_usage_lock() {
  local tries=0
  if command -v flock > /dev/null 2>&1; then
    ( exec 7> "$1"; flock 7; exec sleep 120 ) &
    LOCK_HOLDER=$!
    while flock -n "$1" true 2> /dev/null; do
      tries=$((tries + 1))
      [[ "$tries" -lt 100 ]] || { echo "hold_usage_lock: the holder never took $1" >&2; exit 1; }
      sleep 0.1
    done
  else
    mkdir -- "$1.d"
  fi
}
release_usage_lock() {
  [[ -z "$LOCK_HOLDER" ]] || { kill "$LOCK_HOLDER" 2> /dev/null; wait "$LOCK_HOLDER" 2> /dev/null; }
  LOCK_HOLDER=""
  rmdir -- "$1.d" 2> /dev/null || true
}
hold_usage_lock "$LW_LOCK"
# No clock bounds this row: a read that queued behind the holder names the lock
# it waited on, so the absence of that notice is the pin, on any runner.
run_lanes "$LW_ENV" pick --lane "$H/.claude" --harness claude --json
assert_eq "$(observe 'rc= key= fetched=')" \
  "rc=0 key=none fetched=none" \
  "with the lock held elsewhere, pick --lane answers a warm lane off the cache at once" "$ERR"
# A lock that never comes free is a keyed notice, and the lane is still
# refreshed and answered. The figure is expired first, so this read needs the
# lock it cannot have.
age_usage_record "$LW_STATE" "$H/.claude" 600
run_lanes "$LW_ENV" pick --lane "$H/.claude" --harness claude --json
assert_eq "rc=$RC $(observe 'key= fetched=')" \
  "rc=0 key=usage-lock-timeout,lock-file=$LW_LOCK,wait-s=10 fetched=claude" \
  "past the lock wait the read names the lock it could not take and still refreshes the lane" "$ERR"
release_usage_lock "$LW_LOCK"
# The same fallback where flock is absent: the mutex a holder left behind is
# waited out, named, and the lane is still refreshed.
age_usage_record "$LW_STATE" "$H/.claude" 600
mkdir -- "$LW_LOCK.d"
run_lanes "$LW_ENV;PATH=$CLAIM_BIN:$NOFLOCK" pick --lane "$H/.claude" --harness claude --json
assert_eq "rc=$RC $(observe 'key= fetched=')" \
  "rc=0 key=usage-lock-timeout,lock-file=$LW_LOCK,wait-s=10 fetched=claude" \
  "without flock, a held mutex past the wait is named and the lane is still refreshed" "$ERR"
rmdir -- "$LW_LOCK.d"
# A lock file that cannot be opened at all is the other fallback: named, and
# the lane measured without it. A directory at the lock's path is one such.
LU_STATE="$TMP_ROOT/lock-unopenable-state"
mkdir -p "$LU_STATE/usage/.usage-refresh.lock"
table \
  "a lock file that cannot be opened is named and the lane is still measured|OVERSEE_WATCH_STATE_DIR=$LU_STATE;ORCH_LANE_DIRS=$H/.claude|$LIST|key=usage-lock-unopenable,lock-file=$LU_STATE/usage/.usage-refresh.lock first.status=ok fetched=claude"

echo "=== a renewal that waited finds the figure its peer wrote meanwhile ==="
# Two callers renewing one expired token: the second waits on the credentials
# lock while the first renews, measures and writes this lane's figure. The
# second's cache read must judge that figure against the clock as it reads it,
# not the one it started with, or a record seconds old reads as stamped in the
# future and the read queues behind the usage lock for a figure already there.
# The token stub stands in for the peer: it waits, then stamps the lane's
# record with the time it answers, which is what the peer's write leaves.
TOKEN_PEER="$TMP_ROOT/token-peer"
cat > "$TOKEN_PEER" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
sleep 2
now="$(date +%s)"
sed -E "s/\"fetched_at\": *[0-9]+/\"fetched_at\": $now/" "$PEER_RECORD" > "$PEER_RECORD.peer" \
  && mv "$PEER_RECORD.peer" "$PEER_RECORD"
printf '200 \n{"access_token":"renewed-token","refresh_token":"rotated-refresh","expires_in":3600}\n'
STUB
chmod +x "$TOKEN_PEER"
new_home lockrenew
make_lane "$H" claude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
LR_STATE="$TMP_ROOT/lockrenew-state"
LR_LOCK="$LR_STATE/usage/.usage-refresh.lock"
table "a first run leaves a figure|OVERSEE_WATCH_STATE_DIR=$LR_STATE;ORCH_LANE_DIRS=$H/.claude|$LIST|fetched=claude"
LR_RECORD="$(for f in "$LR_STATE"/usage/*.json; do
  [[ "$(jq -r 'select(.usage) | .config_dir' "$f" 2>/dev/null)" == "$H/.claude" ]] && printf '%s' "$f"
done)"
assert_eq "$([[ -f "$LR_RECORD" ]] && echo found || echo none)" "found" \
  "the lane's usage record is found for the peer to rewrite"
LR_ENV="OVERSEE_WATCH_STATE_DIR=$LR_STATE;ORCH_LANE_DIRS=$H/.claude;ORCH_LANES_CLAUDE_CLIENT_ID=client-1;ORCH_LANES_TOKEN_CMD=$TOKEN_PEER;PEER_RECORD=$LR_RECORD"
# lr_expire_and_hold: the token expired again and the figure past the TTL, so
# only the peer's write can answer, and the usage lock held elsewhere, so a
# read that misses it waits.
lr_expire_and_hold() {
  make_lane "$H" claude -60
  age_usage_record "$LR_STATE" "$H/.claude" 600
  hold_usage_lock "$LR_LOCK"
}
lr_expire_and_hold
run_lanes "$LR_ENV" pick --lane "$H/.claude" --harness claude --json
release_usage_lock "$LR_LOCK"
assert_eq "$(observe 'rc= key= fetched=')" \
  "rc=0 key=none fetched=none" \
  "after a renewal that waited, pick --lane answers off the peer's figure without the usage lock" "$ERR"

echo "=== the usage TTL default outlasts the longest watch interval on the host ==="
# A TTL under `oversee-watch --interval` has every pass find the figure expired
# and fetch again. Both numbers are read out of the shipped scripts, so a red
# here names a document that drifted from them and never the reverse, and a
# watch default raised past the TTL reddens here too; the floors name a sed as
# broken rather than a script as unset.
TTL_DEFAULT="$(sed -n 's/^USAGE_TTL="${ORCH_LANES_USAGE_TTL:-\([0-9][0-9]*\)}"$/\1/p' "$LANES")"
assert_eq "$([[ -n "$TTL_DEFAULT" ]] && echo found || echo none)" "found" \
  "the extractor reads the TTL fallback out of the shipped script"
WATCH_INTERVAL_DEFAULT="$(sed -n 's/^  INTERVAL=\([0-9][0-9]*\)$/\1/p' "$SCRIPTS_DIR/oversee-watch")"
assert_eq "$([[ "$WATCH_INTERVAL_DEFAULT" =~ ^[0-9]+$ ]] && echo found || echo "none:$WATCH_INTERVAL_DEFAULT")" "found" \
  "the extractor reads exactly one interval default out of oversee-watch"
assert_eq "$([[ "$TTL_DEFAULT" -gt "$WATCH_INTERVAL_DEFAULT" ]] && echo outlasts || echo "under-interval:$TTL_DEFAULT<=$WATCH_INTERVAL_DEFAULT")" \
  "outlasts" "the default TTL outlasts the default watch interval"
# The two documents that STATE the default name the setting on one line each,
# so every line naming it has to carry the script's own number: the two counts
# are equal or a document has drifted. The left count floors the comparison, so
# a document that stopped naming the setting reddens rather than passing as
# agreeing. README.md names the setting without stating its value and is left
# out for that reason.
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
for doc in DEVELOPMENT.md kendex.settings.toml.example; do
  assert_eq "names=$(grep -c -F -e "ORCH_LANES_USAGE_TTL" "$SKILL_DIR/$doc" || true) agrees=$(grep -F -e "ORCH_LANES_USAGE_TTL" "$SKILL_DIR/$doc" | grep -c -F -e "$TTL_DEFAULT" || true)" \
    "names=1 agrees=1" \
    "$doc states the script's own TTL default on the line that names the setting"
done
# The script's own help text is the third place the number is written out, and
# it is a different line from the assignment the extractor above read.
assert_eq "$(grep -c -F -e "reused (default $TTL_DEFAULT;" "$LANES" || true)" "1" \
  "the script header states the same TTL default its own fallback assigns"
new_home ttl-default
make_lane "$H" claude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
TTLD_STATE="$TMP_ROOT/ttl-default-state"
TTLD_ENV="OVERSEE_WATCH_STATE_DIR=$TTLD_STATE;ORCH_LANE_DIRS=$H/.claude"
table "a first run leaves a figure to reuse|$TTLD_ENV|$LIST|fetched=claude"
age_usage_record "$TTLD_STATE" "$H/.claude" 240
table \
  "with the setting unset, a figure one whole watch interval old is still served|$TTLD_ENV|$LIST|claude.aged=30+ fetched=none"

echo "=== pick --json names the binding bucket and its reset ==="
# claude's largest bucket is weekly, eclaude's the 5-hour session.
standard_home home
table \
  "pick --json carries the chosen lane's headroom, binding bucket and that bucket's reset||pick --harness claude --json|headroom_pct=80 binding_bucket=weekly binding_resets_at=2026-08-01T06:00:00Z" \
  "a lane bound by its session window names the session bucket and reset||$LIST|eclaude.binding_bucket=session eclaude.binding_resets_at=2026-07-27T06:00:00Z nclaude.binding_bucket=weekly openclaude.binding_bucket=null"

# The Claude endpoint writes fractional seconds and +00:00; every reset a
# record carries is whole-second UTC with a Z, the spelling Codex resets
# already take, so a reader parses and compares one form.
new_home fractional-resets
make_lane "$H" claude 3600
claude_usage 10 20 5 Opus \
  | jq 'walk(if type == "object" and (.resets_at | type) == "string"
             then .resets_at |= sub("Z$"; ".123456+00:00") else . end)' > "$FIXTURE_DIR/.claude.json"
table \
  "a fractional +00:00 reset from the endpoint is listed as whole-second UTC||$LIST|claude.binding_resets_at=2026-08-01T06:00:00Z claude.resets.session=2026-07-27T06:00:00Z claude.model_buckets[0].resets_at=2026-08-01T06:00:00Z"

echo "=== pick --model judges the window that walls THAT model ==="
# An account with plan-wide weekly room can still have none left for ONE model,
# and the binding bucket never shows it: the launch opens on a usage banner
# instead of a session. The account here has two model-scoped windows, so the
# row also pins that the window consulted is the one scoped to the model being
# passed rather than the most-consumed one the MODEL column reports.
new_home model-wall
make_lane "$H" claude 3600
jq -n '{
  five_hour: {utilization: 5, resets_at: "2026-07-27T06:00:00Z"},
  seven_day: {utilization: 20, resets_at: "2026-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: 95, resets_at: "2026-08-01T06:00:00Z",
            scope: {model: {display_name: "Fable 5.1"}}},
           {kind: "weekly_scoped", percent: 10, resets_at: "2026-08-01T06:00:00Z",
            scope: {model: {display_name: "Opus"}}}]
}' > "$FIXTURE_DIR/.claude.json"
MODELPICK='pick --harness claude --max-pct 90'
table \
  "every scoped window is kept, and the MODEL column still reports the most-consumed one||$LIST|first.model_pct=95 first.model_label=Fable_5.1 first.buckets=Fable_5.1:95,Opus:10" \
  "the window scoped to the model being passed walls the lane, and nothing qualifies||$MODELPICK --model fable|rc=3" \
  "the same lane is picked for a model whose own window has room||$MODELPICK --model claude-opus-5|rc=0 out=CLAUDE_CONFIG_DIR=$H/.claude" \
  "and under the binding floor that same lane is refused, its own bucket spent on a model this launch never passes||$MODELPICK --model claude-opus-5 --binding-floor|rc=3" \
  "the floor holds the binding bucket to the same number, so a lane clearing both is still picked||pick --harness claude --max-pct 96 --model claude-opus-5 --binding-floor|rc=0 out=CLAUDE_CONFIG_DIR=$H/.claude" \
  "the full model id reaches the window its API label names, separators and all||$MODELPICK --model claude-fable-5-1|rc=3" \
  "a model no scoped window names is judged on the session and weekly windows alone||$MODELPICK --model sonnet|rc=0 out=CLAUDE_CONFIG_DIR=$H/.claude" \
  "without --model the binding bucket decides, as it always did||$MODELPICK|rc=3" \
  "--json names the shared bucket that decided and drops the chooser's working field||$MODELPICK --model claude-opus-5 --json|binding_bucket=weekly binding_resets_at=2026-08-01T06:00:00Z haswall=false"

model_usage() { # FABLE OPUS
  jq -nc --argjson f "$1" --argjson o "$2" '{
    five_hour: {utilization: 5, resets_at: "2026-07-27T06:00:00Z"},
    seven_day: {utilization: 20, resets_at: "2026-08-01T06:00:00Z"},
    limits: [{kind: "weekly_scoped", percent: $f, resets_at: "2026-08-01T06:00:00Z",
              scope: {model: {display_name: "Fable 5.1"}}},
             {kind: "weekly_scoped", percent: $o, resets_at: "2026-08-01T06:00:00Z",
              scope: {model: {display_name: "Opus"}}}]}'
}
stage_model_rate() { # CURRENT_FABLE CURRENT_OPUS PRIOR_FABLE PRIOR_OPUS
  local f now
  CACHE_STATE="$TMP_ROOT/model-rate-$1-$2-$3-$4"
  model_usage "$1" "$2" > "$FIXTURE_DIR/.claude.json"
  stage_cache 0
  now="$(date +%s)"
  f="$(find "$CACHE_STATE/usage" -type f -name '*.json' -print -quit)"
  jq --argjson now "$now" --argjson current "$(model_usage "$1" "$2")" \
    --argjson prior "$(model_usage "$3" "$4")" \
    '.fetched_at = $now | .usage = $current
     | .prior = {fetched_at: ($now - 600), usage: $prior}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

stage_model_rate 95 10 75 10
table \
  "a named Opus pick ignores the rising Fable bucket when it calculates rate|ORCH_LANE_DIRS=$H/.claude;OVERSEE_WATCH_STATE_DIR=$CACHE_STATE|pick --lane $H/.claude --harness claude --model opus --json|usage_rate_state=not-increasing projected_wall_minutes=null" \
  "a fleet Opus pick ignores the rising Fable bucket too|ORCH_LANE_DIRS=$H/.claude;OVERSEE_WATCH_STATE_DIR=$CACHE_STATE|pick --harness claude --model opus --json|usage_rate_state=not-increasing projected_wall_minutes=null"
stage_model_rate 95 80 95 60
table \
  "a named Opus pick reports its approaching wall when the larger Fable bucket is flat|ORCH_LANE_DIRS=$H/.claude;OVERSEE_WATCH_STATE_DIR=$CACHE_STATE|pick --lane $H/.claude --harness claude --model opus --json|usage_rate_state=measured projected_wall_minutes=10" \
  "a fleet Opus pick reports the same approaching wall|ORCH_LANE_DIRS=$H/.claude;OVERSEE_WATCH_STATE_DIR=$CACHE_STATE|pick --harness claude --model opus --json|usage_rate_state=measured projected_wall_minutes=10"

stage_raw_rate() { # NAME CURRENT PRIOR
  local name="$1" current="$2" prior="$3" f now
  CACHE_STATE="$TMP_ROOT/model-identity-$name"
  printf '%s\n' "$current" > "$FIXTURE_DIR/.claude.json"
  stage_cache 0
  now="$(date +%s)"
  f="$(find "$CACHE_STATE/usage" -type f -name '*.json' -print -quit)"
  jq --argjson now "$now" --argjson current "$current" --argjson prior "$prior" \
    '.fetched_at = $now | .usage = $current
     | .prior = {fetched_at: ($now - 600), usage: $prior}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
unlabeled_usage() { # PERCENT RESET
  jq -nc --argjson pct "$1" --arg reset "$2" '{
    five_hour: {utilization: 5, resets_at: "2026-07-27T06:00:00Z"},
    seven_day: {utilization: 20, resets_at: "2026-08-01T06:00:00Z"},
    limits: [{kind: "weekly_scoped", percent: $pct, resets_at: $reset,
              scope: {model: {}}}]}'
}
stage_raw_rate reset-crossing \
  "$(unlabeled_usage 80 2026-08-02T06:00:00Z)" \
  "$(unlabeled_usage 60 2026-07-26T06:00:00Z)"
table "samples from different quota windows never form a rate|ORCH_LANE_DIRS=$H/.claude;OVERSEE_WATCH_STATE_DIR=$CACHE_STATE|$RATE_LIST|claude.usage_rate_state=one-sample claude.projected_wall_minutes=null"
stage_raw_rate unlabeled-model \
  "$(unlabeled_usage 80 2026-08-02T06:00:00Z)" \
  "$(unlabeled_usage 60 2026-08-02T06:00:00Z)"
table "an unlabeled model bucket matches its prior raw null identity|ORCH_LANE_DIRS=$H/.claude;OVERSEE_WATCH_STATE_DIR=$CACHE_STATE|$RATE_LIST|claude.usage_rate_state=measured claude.projected_wall_minutes=10"

echo "=== pick --model judges shared and scoped buckets together ==="
# The account-wide 5-hour and weekly windows wall every model. A model launch
# therefore uses the largest matching bucket, and the returned binding fields
# identify that bucket rather than the account's unrelated overall maximum.
new_home shared-model-wall
make_lane "$H" claude 3600
SHARED_PICK="pick --lane $H/.claude --harness claude --max-pct 80 --model fable --json"
jq -n '{
  five_hour: {utilization: 85, resets_at: "2026-07-27T06:00:00Z"},
  seven_day: {utilization: 20, resets_at: "2026-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: 10, resets_at: "2026-08-02T06:00:00Z",
            scope: {model: {display_name: "Fable"}}},
           {kind: "weekly_scoped", percent: 95, resets_at: "2026-08-03T06:00:00Z",
            scope: {model: {display_name: "Opus"}}}]
}' > "$FIXTURE_DIR/.claude.json"
table \
  "a shared 5-hour wall outranks the named model bucket and names itself||$SHARED_PICK|rc=3 binding_bucket=session binding_resets_at=2026-07-27T06:00:00Z wall=85 key=pick-lane-walled,lane=$H/.claude,wall=85,bucket=session,max-pct=80"

jq -n '{
  five_hour: {utilization: 10, resets_at: "2026-07-27T06:00:00Z"},
  seven_day: {utilization: 20, resets_at: "2026-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: 85, resets_at: "2026-08-02T06:00:00Z",
            scope: {model: {display_name: "Fable"}}},
           {kind: "weekly_scoped", percent: 95, resets_at: "2026-08-03T06:00:00Z",
            scope: {model: {display_name: "Opus"}}}]
}' > "$FIXTURE_DIR/.claude.json"
table \
  "the named model wall outranks both shared buckets and names itself||$SHARED_PICK|rc=3 binding_bucket=model binding_resets_at=2026-08-02T06:00:00Z wall=85 key=pick-lane-walled,lane=$H/.claude,wall=85,bucket=model,max-pct=80"

jq -n '{
  five_hour: {utilization: 10, resets_at: "2026-07-27T06:00:00Z"},
  seven_day: {utilization: 20, resets_at: "2026-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: 70, resets_at: "2026-08-02T06:00:00Z",
            scope: {model: {display_name: "Fable"}}}]
}' > "$FIXTURE_DIR/.claude.json"
table \
  "a lane is picked when its shared and named model buckets are below the bound||$SHARED_PICK|rc=0 binding_bucket=model binding_resets_at=2026-08-02T06:00:00Z wall=70 key=none"

# A lane measured on its scoped window alone answers nothing about a model that
# window does not name, and an unanswered question is never read as "it is free".
new_home model-only
make_lane "$H" claude 3600
jq -n '{limits: [{kind: "weekly_scoped", percent: 10, resets_at: "2026-08-01T06:00:00Z",
                  scope: {model: {display_name: "Opus"}}}]}' > "$FIXTURE_DIR/.claude.json"
table \
  "a lane whose windows answer nothing for the model is refused, and the refusal names the unmeasured cause rather than the usage limit||$MODELPICK --model sonnet|rc=3 key=no-candidate-unmeasured,harness=claude,model=sonnet,unmeasured=1" \
  "the refusal holds at the highest threshold the parser allows, so no number stands in for the unmeasured answer||pick --harness claude --max-pct 100 --model sonnet|rc=3 key=no-candidate-unmeasured,harness=claude,model=sonnet,unmeasured=1" \
  "the same lane is picked for the model its one window does name||$MODELPICK --model opus|rc=0 out=CLAUDE_CONFIG_DIR=$H/.claude"

# A scoped window the API did not name walls EVERY model. Nothing says which
# model it belongs to, so it might be this one, and a window that might wall the
# launch is not evidence the launch is free. Without this, naming a model would
# be more permissive than naming none: the same account is refused by the plain
# pick through its MODEL column.
new_home model-unnamed
make_lane "$H" claude 3600
jq -n '{
  five_hour: {utilization: 10, resets_at: "2026-07-27T06:00:00Z"},
  seven_day: {utilization: 20, resets_at: "2026-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: 99, resets_at: "2026-08-01T06:00:00Z",
            scope: {model: {}}}]
}' > "$FIXTURE_DIR/.claude.json"
table \
  "an unnamed scoped window is carried with a null label, not the MODEL column's filler||$LIST|first.buckets=null:99 first.model_pct=99" \
  "a scoped window nobody named walls the model being passed||$MODELPICK --model opus|rc=3" \
  "and the same account is refused without --model too, so naming one is never the freer answer||$MODELPICK|rc=3"

# The scoped windows an older response carries in seven_day_sonnet and
# seven_day_opus instead of limits[]. A response carrying BOTH keeps both: each
# is a real window walling the model it names, and dropping the second judges a
# launch on that model by the session and weekly windows alone.
new_home legacy-model
make_lane "$H" claude 3600
jq -n '{
  five_hour: {utilization: 5, resets_at: "2026-07-27T06:00:00Z"},
  seven_day: {utilization: 20, resets_at: "2026-08-01T06:00:00Z"},
  seven_day_sonnet: {utilization: 10, resets_at: "2026-08-01T06:00:00Z"},
  seven_day_opus: {utilization: 97, resets_at: "2026-08-01T06:00:00Z"}
}' > "$FIXTURE_DIR/.claude.json"
table \
  "both legacy model fields are kept, and the MODEL column reports the most-consumed of the two||$LIST|first.buckets=Sonnet:10,Opus:97 first.model_pct=97 first.model_label=Opus" \
  "the legacy window scoped to the model being passed walls the lane||$MODELPICK --model opus|rc=3" \
  "a model neither legacy field names is judged on the session and weekly windows alone||$MODELPICK --model fable|rc=0 out=CLAUDE_CONFIG_DIR=$H/.claude"

echo "=== pick --lane judges one named account, and says which outcome it reached ==="
# The form open-terminal calls. Every exit it can reach is driven here directly,
# because a launcher asserting its OWN keys proves nothing about the ones this
# script emits, and an outcome no row names is an outcome a rename can drop.
new_home one-lane
make_lane "$H" claude 3600
make_lane "$H" eclaude 3600
make_codex_lane "$H/.codex"
claude_usage 10 20 95 'Fable 5.1' > "$FIXTURE_DIR/.claude.json"
claude_usage 10 20 10 Opus      > "$FIXTURE_DIR/.eclaude.json"
# A lane whose only window names one model, so another model measures nothing.
make_lane "$H" uclaude 3600
jq -n '{limits: [{kind: "weekly_scoped", percent: 10, resets_at: "2026-08-01T06:00:00Z",
                  scope: {model: {display_name: "Opus"}}}]}' > "$FIXTURE_DIR/.uclaude.json"
jq -n '{rate_limit: {primary_window: {used_percent: 20, reset_at: 1785000000,
                                      limit_window_seconds: 18000}}}' > "$FIXTURE_DIR/.codex.json"
ONE="pick --lane $H/.eclaude --harness claude"
table \
  "room prints the env prefix and nothing else||$ONE --model opus|rc=0 out=CLAUDE_CONFIG_DIR=$H/.eclaude key=none" \
  "room under --json prints the lane record instead||$ONE --model opus --json|rc=0 alias=eclaude key=none" \
  "the record carries the wall it was judged on, so a caller names the percentage it refused||pick --lane $H/.claude --harness claude --model fable --json|rc=3 wall=95" \
  "a walled lane refuses 3 and names the wall on the keyed line||pick --lane $H/.claude --harness claude --model fable|rc=3 out= key=pick-lane-walled,lane=$H/.claude,wall=95,bucket=model,max-pct=95" \
  "a lane no window measures for this model refuses 5, never 3||pick --lane $H/.uclaude --harness claude --model sonnet|rc=5 key=pick-lane-unmeasured,lane=$H/.uclaude,model=sonnet" \
  "the record comes back on 5 too, whose status says the account read fine and its one window names another model||pick --lane $H/.uclaude --harness claude --model sonnet --json|rc=5 status=ok model_label=Opus wall=null" \
  "a directory no lane record covers refuses 4, which a launcher reads as nothing to judge||pick --lane $TMP_ROOT/not-a-lane --harness claude --model opus|rc=4 key=pick-lane-unlisted,lane=$TMP_ROOT/not-a-lane,harness=claude" \
  "a threshold the parser refuses never reaches a lane at all||$ONE --model opus --max-pct 90%|rc=1 key=invalid-percent,option=--max-pct" \
  "a codex lane prints the codex spelling of the prefix||pick --lane $H/.codex --harness codex --model fable|rc=0 out=CODEX_HOME=$H/.codex key=none"

echo "=== the bound is one number, in either spelling ==="
# Strictly MORE headroom than the bound qualifies, so a lane sitting exactly on
# it is refused. Its own world: the sections above each leave the fixture they
# were measuring, and this row is read against one lane holding 80 percent
# headroom, which is what both spellings of the bound are compared to.
new_home headroom-bound
make_lane "$H" claude 3600
claude_usage 20 10 5 Opus > "$FIXTURE_DIR/.claude.json"
table \
  'a lane above the headroom bound is picked||pick --harness claude --min-headroom-pct 79 --json|headroom_pct=80' \
  'a lane exactly at the headroom bound is refused||pick --harness claude --min-headroom-pct 80|rc=3' \
  'the same bound written as percent used refuses it too||pick --harness claude --max-pct 20|rc=3'

echo "=== a hosted fleet lists the provider's own credentials beside this machine's ==="
# A hosted lane runs on the copy the provider put on the host, so `accounts` and
# this machine's config dir are two readings of one account and the listing
# carries both rather than choosing between them. Its own world: one local
# lane, and a provider that reports the same account with different windows.
# `expired` here is the defect's shape — the local copy is dead while the
# provider's still measures — and the row pins that BOTH readings are listed,
# each named by the credential it came through.
#
# The last two rows are the fail-closed pair: a provider that cannot answer
# leaves the listing the local reading it always was, and a percentage nobody
# can parse drops that row rather than listing it as an account with room.
new_home hosted-accounts
make_dead_lane "$H" claude
HOST_FIXTURE="$TEST_DIR/fixtures/lane-host"
HOST_ENV="ORCH_LANE_HOST=$HOST_FIXTURE;LANE_HOST_STUB_LOG=$TMP_ROOT/accounts.log"
printf 'account=%s\tharness=claude\tsession-5h-pct=3\tweekly-pct=8\tmodel-pct=11\tmodel-label=Fable\tmodel-resets=2026-08-02T06:00:00Z\n' \
  "$H/.claude" > "$TMP_ROOT/accounts-ok.tsv"
printf 'account=%s\tharness=claude\tweekly-pct=abc\n' "$H/.claude" > "$TMP_ROOT/accounts-junk.tsv"
# The provider's own status for the account. No other fixture sets the field, so
# without this one the ok row below pins the parser's default rather than
# anything the provider said, and a provider reporting its copy dead would list
# as an account with full headroom.
printf 'account=%s\tharness=claude\tstatus=expired\tsession-5h-pct=3\tweekly-pct=8\n' \
  "$H/.claude" > "$TMP_ROOT/accounts-dead.tsv"
# A required field each: one row naming no harness, one naming no account. Each
# fixture plants exactly one defect, so each verdict below belongs to one rule.
printf 'account=%s\tweekly-pct=8\n' "$H/.claude" > "$TMP_ROOT/accounts-noharness.tsv"
printf 'harness=claude\tweekly-pct=8\n' > "$TMP_ROOT/accounts-noaccount.tsv"
# Two accounts, only one of which this machine has a config dir for, so a
# setting that drops the second is visibly dropping the HOST row while the
# first account's pair stands.
printf 'account=%s\tharness=claude\tsession-5h-pct=3\tweekly-pct=8\naccount=%s\tharness=claude\tsession-5h-pct=4\tweekly-pct=9\n' \
  "$H/.claude" "$H/.eclaude" > "$TMP_ROOT/accounts-two.tsv"
# A provider holding an account for the OTHER harness, which this machine has
# no config dir for. Every other hosted fixture is claude and every hosted row
# asks for claude, so the harness match is answered in one direction only; this
# fixture is what the rows below read it from both.
printf 'account=%s\tharness=codex\tsession-5h-pct=5\tweekly-pct=6\n' \
  "$H/.codex" > "$TMP_ROOT/accounts-mixed.tsv"
table \
  "with no provider the local config dirs are the whole listing|ORCH_LANE_HOST=local|list --harness claude --json|through=claude:local length=1 key=none" \
  "the provider's own reading of the same account is listed beside this machine's|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv|list --harness claude --json|through=claude:local,claude:host length=2" \
  "the local copy stays expired while the provider's reading carries its own windows|$HOST_ENV;ORCH_LANES_CLAUDE_CLIENT_ID=client-1;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv|list --harness claude --json|first.status=expired last.session_5h_pct=3 last.weekly_pct=8 last.headroom_pct=89" \
  "the hosted reading carries its deciding model bucket and reset|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv|list --harness claude --json --no-cache|last.measured_through=host last.binding_bucket=model last.binding_resets_at=2026-08-02T06:00:00Z" \
  "a status the provider reports is the host row's status, not this parser's default|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-dead.tsv|list --harness claude --json|through=claude:local,claude:host last.status=expired last.headroom_pct=null" \
  "a provider that fails the verb it implements says so, and the listing stays this machine's reading|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS_STATUS=7|list --harness claude --json|through=claude:local length=1 key=host-accounts-unreadable,host=$HOST_FIXTURE,exit=7" \
  "a percentage this script cannot read drops that row rather than listing it as room|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-junk.tsv|list --harness claude --json|through=claude:local length=1 key=host-account-invalid,account=$H/.claude,field=weekly-pct" \
  "a row naming no harness is dropped on that rule, which no other fixture reaches|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-noharness.tsv|list --harness claude --json|through=claude:local length=1 key=host-account-invalid,account=$H/.claude,field=harness" \
  "a row naming no account is dropped on that rule, named as unnamed|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-noaccount.tsv|list --harness claude --json|through=claude:local length=1 key=host-account-invalid,account=<unnamed>,field=account" \
  "an excluded account is not listed through the host either, while the rest of the answer stands|$HOST_ENV;ORCH_LANE_EXCLUDE=eclaude;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-two.tsv|list --harness claude --json|through=claude:local,claude:host length=2" \
  "a retired account the provider reports is listed retired, with no headroom to place an item on|$HOST_ENV;ORCH_LANE_RETIRE=eclaude=2000-01-01;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-two.tsv|list --harness claude --json|length=3 eclaude.status=retired eclaude.headroom_pct=null eclaude.measured_through=host" \
  "a codex account the provider holds is not listed in a claude listing|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-mixed.tsv|list --harness claude --json|rc=0 through=claude:local length=1 key=none" \
  "the default listing carries the host row, so the harness a caller did not name is every harness|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv|list --json|rc=0 through=claude:local,claude:host length=2 key=none"

# The verb is OPTIONAL: a provider without it gives no answer, which is not a
# failure. Both listings are captured whole and compared, because the claim is
# that the verb-absent listing is EXACTLY the no-provider one rather than merely
# one row long, and that nothing at all reaches stderr — the shipped reference
# provider answers an unknown verb with its parser's whole usage message, and an
# overseer runs this listing constantly.
run_lanes "ORCH_LANE_HOST=local" list --harness claude --json
NO_PROVIDER_OUT="$OUT"
NO_PROVIDER_ERR="$(cat "$ERR")"
run_lanes "$HOST_ENV;LANE_HOST_STUB_NO_ACCOUNTS=1" list --harness claude --json
assert_eq "rc=$RC json=$([[ "$OUT" == "$NO_PROVIDER_OUT" ]] && echo same || echo differs) stderr=$([[ "$(cat "$ERR")" == "$NO_PROVIDER_ERR" ]] && echo same || echo "$(cat "$ERR")")" \
  "rc=0 json=same stderr=same" \
  "a provider without the verb lists exactly what the no-provider reading lists, and says nothing"

# --local is what the launcher's own lookups pass: resolving a config dir by
# alias must cost no provider round trip. Each half writes its own call log, so
# neither can be answered by the other's calls.
ASKED_LOG="$TMP_ROOT/accounts-asked.log"; : > "$ASKED_LOG"
SKIPPED_LOG="$TMP_ROOT/accounts-skipped.log"; : > "$SKIPPED_LOG"
run_lanes "ORCH_LANE_HOST=$HOST_FIXTURE;LANE_HOST_STUB_LOG=$ASKED_LOG;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv" \
  list --harness claude --json
ASKED="$(grep -c '^accounts' "$ASKED_LOG" || true)"
run_lanes "ORCH_LANE_HOST=$HOST_FIXTURE;LANE_HOST_STUB_LOG=$SKIPPED_LOG;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv" \
  list --harness claude --local --json
assert_eq "asked=$ASKED skipped=$(grep -c '^accounts' "$SKIPPED_LOG" || true) $(observe 'through=claude:local length=1')" \
  "asked=1 skipped=0 through=claude:local length=1" \
  "--local lists this machine's config dirs alone and asks the provider nothing"

# The provider's answer is read through the usage cache, so the inventory an
# overseer runs every cycle forks one provider call per window instead of one per
# invocation. Each run writes its own call log and the pair shares one state dir,
# which is where the cache lives; run_lanes gives every other row a fresh one, so
# no other row can be answered from a neighbour's cache.
TTL_STORE="$TMP_ROOT/accounts-ttl-store"
TTL_ENV="ORCH_LANE_HOST=$HOST_FIXTURE;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv;OVERSEE_WATCH_STATE_DIR=$TTL_STORE"
TTL_FIRST="$TMP_ROOT/accounts-ttl-1.log"; : > "$TTL_FIRST"
TTL_SECOND="$TMP_ROOT/accounts-ttl-2.log"; : > "$TTL_SECOND"
TTL_THIRD="$TMP_ROOT/accounts-ttl-3.log"; : > "$TTL_THIRD"
run_lanes "$TTL_ENV;LANE_HOST_STUB_LOG=$TTL_FIRST" list --harness claude --json
TTL_CALLS="$(grep -c '^accounts' "$TTL_FIRST" || true)"
run_lanes "$TTL_ENV;LANE_HOST_STUB_LOG=$TTL_SECOND" list --harness claude --json
assert_eq "first=$TTL_CALLS second=$(grep -c '^accounts' "$TTL_SECOND" || true) $(observe 'through=claude:local,claude:host length=2')" \
  "first=1 second=0 through=claude:local,claude:host length=2" \
  "a second listing inside the TTL forks no provider call and still carries the host row from the cached answer"
# A cached record this script cannot read is a MISS, not an answer. The shared
# reader validates that the body is an object and no more, so a record carrying a
# status and no rows would otherwise hand the row parser the string `null` to read
# as a provider row. One record exists by construction: the pair above wrote it.
ACCOUNTS_RECORDS=("$TTL_STORE/usage"/host-accounts-*.json)
assert_eq "${#ACCOUNTS_RECORDS[@]}" "1" "the cached pair above left exactly one provider record to corrupt"
jq -c '.usage = {status: 0}' "${ACCOUNTS_RECORDS[0]}" > "$TMP_ROOT/accounts-malformed.json"
cp "$TMP_ROOT/accounts-malformed.json" "${ACCOUNTS_RECORDS[0]}"
MALFORMED_LOG="$TMP_ROOT/accounts-malformed.log"; : > "$MALFORMED_LOG"
run_lanes "$TTL_ENV;LANE_HOST_STUB_LOG=$MALFORMED_LOG" list --harness claude --json
assert_eq "calls=$(grep -c '^accounts' "$MALFORMED_LOG" || true) $(observe 'through=claude:local,claude:host key=none')" \
  "calls=1 through=claude:local,claude:host key=none" \
  "a cached record this script cannot read is a miss: the provider is asked again and no row is invented from it"
run_lanes "$TTL_ENV;LANE_HOST_STUB_LOG=$TTL_THIRD" list --harness claude --json --no-cache
assert_eq "calls=$(grep -c '^accounts' "$TTL_THIRD" || true) $(observe 'through=claude:local,claude:host')" \
  "calls=1 through=claude:local,claude:host" \
  "--no-cache asks the provider again inside the same window, which is what a launch gate passes"
# The absent verb is cached too: a provider that will never implement it would
# otherwise pay a fork on every invocation to be told so again.
ABSENT_STORE="$TMP_ROOT/accounts-absent-store"
ABSENT_ENV="ORCH_LANE_HOST=$HOST_FIXTURE;LANE_HOST_STUB_NO_ACCOUNTS=1;OVERSEE_WATCH_STATE_DIR=$ABSENT_STORE"
ABSENT_FIRST="$TMP_ROOT/accounts-absent-1.log"; : > "$ABSENT_FIRST"
ABSENT_SECOND="$TMP_ROOT/accounts-absent-2.log"; : > "$ABSENT_SECOND"
run_lanes "$ABSENT_ENV;LANE_HOST_STUB_LOG=$ABSENT_FIRST" list --harness claude --json
ABSENT_CALLS="$(grep -c '^accounts' "$ABSENT_FIRST" || true)"
run_lanes "$ABSENT_ENV;LANE_HOST_STUB_LOG=$ABSENT_SECOND" list --harness claude --json
assert_eq "first=$ABSENT_CALLS second=$(grep -c '^accounts' "$ABSENT_SECOND" || true) $(observe 'rc=0 through=claude:local')" \
  "first=1 second=0 rc=0 through=claude:local" \
  "the absent-verb answer is cached as well, and the second listing is the local reading with no call"
# A FAILED verb is never cached: it is the transient one of the two answers, and
# replaying it for the rest of the window would hide the host coming back.
FAILED_STORE="$TMP_ROOT/accounts-failed-store"
FAILED_ENV="ORCH_LANE_HOST=$HOST_FIXTURE;LANE_HOST_STUB_ACCOUNTS_STATUS=7;OVERSEE_WATCH_STATE_DIR=$FAILED_STORE"
FAILED_FIRST="$TMP_ROOT/accounts-failed-1.log"; : > "$FAILED_FIRST"
FAILED_SECOND="$TMP_ROOT/accounts-failed-2.log"; : > "$FAILED_SECOND"
run_lanes "$FAILED_ENV;LANE_HOST_STUB_LOG=$FAILED_FIRST" list --harness claude --json
FAILED_CALLS="$(grep -c '^accounts' "$FAILED_FIRST" || true)"
run_lanes "$FAILED_ENV;LANE_HOST_STUB_LOG=$FAILED_SECOND" list --harness claude --json
assert_eq "first=$FAILED_CALLS second=$(grep -c '^accounts' "$FAILED_SECOND" || true) $(observe "key=host-accounts-unreadable,host=$HOST_FIXTURE,exit=7")" \
  "first=1 second=1 key=host-accounts-unreadable,host=$HOST_FIXTURE,exit=7" \
  "a failed verb is asked again on the next listing rather than replayed from the cache"
# The bound. A provider that never returns would otherwise hold the inventory an
# overseer runs every cycle; the bound reached is the verb failing, timeout's own
# 124, and the listing stays this machine's reading. Skipped where neither
# timeout spelling is installed, since there is nothing to bound the call with.
SLOW_HOST="$TMP_ROOT/accounts-slow-host"
cat > "$SLOW_HOST" <<'SLOWEOF'
#!/usr/bin/env bash
[[ "${1:-}" != accounts ]] || { sleep "${ACCOUNTS_SLEEP_S:-3}"; exit 0; }
exit 2
SLOWEOF
chmod +x "$SLOW_HOST"
SLOW_ENV="ORCH_LANE_HOST=$SLOW_HOST;ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S=1"
# The same provider under a bound written with a leading zero, which the
# validator accepts as the whole number of seconds it documents. It sleeps past
# that bound, so the row below says whether the bound was applied at all.
OCTAL_ENV="ORCH_LANE_HOST=$SLOW_HOST;ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S=08;ACCOUNTS_SLEEP_S=9"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  table \
    "a provider that does not return inside the bound is the verb failing, and the listing stays local|$SLOW_ENV|list --harness claude --json|rc=0 through=claude:local length=1 key=host-accounts-unreadable,host=$SLOW_HOST,exit=124"
  # Bash arithmetic reads a leading zero as an octal literal, and 08 is not one:
  # every `-ne 0` test on the raw setting errors, which skips the bound and the
  # unbounded-read refusal alike and leaves the overseer waiting on the provider.
  # The setting is normalized to its decimal reading once, at validation.
  table \
    "a bound written with a leading zero is read in base 10 and still bounds the provider|$OCTAL_ENV|list --harness claude --json|rc=0 through=claude:local length=1 key=host-accounts-unreadable,host=$SLOW_HOST,exit=124"
  # A full per-home cap on provider calls, through the real dispatcher at the
  # shipped slot wait and bound: a slot naming this suite's own shell, alive
  # throughout, fills a cap of 1 in a home of its own. lane-host's 30-second
  # slot wait outlasts the 10-second bound, so the read waits for less than
  # the bound and lane-host refuses as busy before the bound can end it.
  BUSY_HOME="$TMP_ROOT/busy-home"
  mkdir -p "$BUSY_HOME/.cache/orch/lane-host-slots"
  : > "$BUSY_HOME/.cache/orch/lane-host-slots/slot.$$"
  BUSY_ENV="$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv;HOME=$BUSY_HOME;ORCH_LANE_HOST_MAX_CALLS=1;ORCH_LANE_HOST_BUSY_WAIT_SECS=30;ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S=10"
  table \
    "a read lane-host refuses at its per-home cap answers 1 under lane-host-busy before the bound ends it|$BUSY_ENV|host-accounts --no-cache|rc=1 lines=0 key=lane-host-busy,step=accounts,item=-"
  # Control: with the slot wait left longer than the bound, the bound cuts the
  # wait off and the refusal reads as the verb failing.
  lanes_mutant mutant-accounts-busy-wait lanes 'busy_wait=\$((ACCOUNTS_TIMEOUT_S - 1))' ':'
  LANES_PATCHED="$LANES"
  LANES="$TMP_ROOT/mutant-accounts-busy-wait/scripts/lanes"
  table \
    "control: a slot wait past the bound is cut off as host-accounts-unreadable exit 124|$BUSY_ENV|host-accounts --no-cache|rc=1 lines=0 key=host-accounts-unreadable,host=$HOST_FIXTURE,exit=124"
  LANES="$LANES_PATCHED"
else
  echo "  skip  neither timeout nor gtimeout is installed; the accounts bound rows did not run"
fi
table \
  "a bound the parser cannot read refuses before any provider runs, named as the setting|ORCH_LANE_HOST=$SLOW_HOST;ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S=soon|list --harness claude --json|rc=1 key=invalid-accounts-timeout,value=soon"

# A machine carrying neither timeout spelling, which is a stock macOS install:
# the copy below finds no bound command, the way that machine does. A CACHED
# read still runs the provider unbounded, since its cost is one call per window
# and no launch waits on a listing; a read that asked for NO cache asked to wait
# for the provider now, and with nothing to end that wait it is refused rather
# than left hanging with nothing on stderr. `open-terminal` passes --no-cache on
# the gate path, so this is the launcher's probe.
lanes_mutant mutant-accounts-nobound lanes 'for _accounts_timeout in timeout gtimeout; do' 'for _accounts_timeout in; do'
LANES_PATCHED="$LANES"
LANES="$TMP_ROOT/mutant-accounts-nobound/scripts/lanes"
table \
  "with no timeout command a cached listing still asks the provider and answers|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv|list --harness claude --json|rc=0 through=claude:local,claude:host length=2 key=none" \
  "with no timeout command the uncached probe is refused, naming the bound it could not apply|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv|host-accounts --harness claude --no-cache|rc=1 lines=0 key=host-accounts-unbounded,host=$HOST_FIXTURE,bound-s=10" \
  "a bound of 0 asks for no bound at all, so the same uncached probe answers|$HOST_ENV;ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S=0;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv|host-accounts --harness claude --no-cache|rc=0 lines=1 key=none"
LANES="$LANES_PATCHED"

# `host-accounts` is the one reader of the verb: it prints what it validated and
# hands the provider's answer back as its own exit status, so a caller deciding
# what the host holds inherits the field rules and the harness match instead of
# matching provider bytes itself. 0 answered, 2 verb absent, 1 verb failed, and
# `local` refused rather than answered as an absent verb, since the dispatcher
# refuses a provider verb under `local` with that same 2.
table \
  "the answer is one line per validated row|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv|host-accounts --harness claude|rc=0 lines=1 key=none" \
  "a row this script cannot read is dropped here too, so the answer holds no account|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-junk.tsv|host-accounts --harness claude|rc=0 lines=0 key=host-account-invalid,account=$H/.claude,field=weekly-pct" \
  "the harness is part of the match, so a claude row holds nothing for codex|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv|host-accounts --harness codex|rc=0 lines=0 key=none" \
  "and a codex row is listed for a codex listing, which is that same match from the other side|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-mixed.tsv|host-accounts --harness codex --json|rc=0 length=1 first.config_dir=$H/.codex first.harness=codex first.measured_through=host" \
  "a provider without the optional verb answers 2 and says nothing|$HOST_ENV;LANE_HOST_STUB_NO_ACCOUNTS=1|host-accounts|rc=2 lines=0 key=none" \
  "a provider that fails the verb answers 1 under its keyed line|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS_STATUS=7|host-accounts|rc=1 lines=0 key=host-accounts-unreadable,host=$HOST_FIXTURE,exit=7" \
  "no configured provider is refused, never answered as an absent verb|ORCH_LANE_HOST=local|host-accounts|rc=1 lines=0 key=host-accounts-local,host=local" \
  "--json carries the config dir the provider was given, unescaped, which is the form a caller compares|$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv|host-accounts --harness claude --json|rc=0 length=1 first.config_dir=$H/.claude first.measured_through=host"
run_lanes "$HOST_ENV;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/accounts-ok.tsv" host-accounts --harness claude
assert_eq "$OUT" "$H/.claude"$'\t'"claude" \
  "the printed row names the config dir the provider was given and that row's harness"
echo "=== a renewal a ceiling lands on finishes, keeps the rotated token and releases the mutex ==="
# `refresh_claude_token` takes that mutex inside a command substitution, which
# a ceiling signals along with the shell that called it: `timeout` signals the
# whole process group. Once the POST is out the endpoint may already have
# rotated the refresh token, so the renewal ignores the ceiling's TERM until
# the rename and a credentials file never keeps a retired token. Left behind, the mutex
# makes every later renewal on that account wait out its whole timeout and
# fail with "another tool holds the credentials lock". Only the mkdir mutex
# can outlive its holder — under flock the kernel releases it — so the probe
# PATH below is the platform this row exists for, built the way
# workflow-state-flockless.sh builds its own: the real PATH minus flock, so it
# stays true as `lanes` changes.
#
# The mutex assertion reads the SETTLED state rather than the instant the
# ceiling returns, through lib/lanes-fixture.sh's `settled_mutex`, the one
# reading of a reaped lock these suites share. The credentials check reads the
# file only once the mutex assertion before it has waited for the release,
# which comes after the rename.
#
# The run gets its own OVERSEE_WATCH_STATE_DIR, because `lanes` also takes the
# host-wide usage mutex under that directory, and the fallback under the
# checkout is shared with every other run on this host.
#
# The library rule has its own rows in file-lock-messages.sh; what those cannot
# reach is whether the SHIPPED caller takes it. The ceiling row below lands
# while the token POST is in flight and the renewal then runs to its end, so
# it executes the line that restores the handlers but no signal reaches that
# line. The change under test is the word itself, so it is pinned as source:
# `trap -` on those signals is what the revert would put back.
#
# The invariant is the renewal's alone — no clearing to the default disposition
# while it holds the mkdir mutex — so the pin reads that function's body and no
# other line of the script. Sites outside it hold no mutex and arm and clear
# handlers of their own, the host-accounts read being one, and a pin over the
# whole file reds on a neighbour that never touched this rule. The body is read
# out of the shipped script rather than named by line number.
RENEWAL_BODY="$(awk '
  $0 == "refresh_claude_token() {" { inside = 1; next }
  inside && $0 == "}" { exit }
  inside
' "$SCRIPTS_DIR/lanes")"
# The floor under both counts below: an extractor that matched nothing would
# report no clears for a renewal it never read. A red here names this awk as
# broken, never the script as clean.
assert_eq "$([[ -n "$RENEWAL_BODY" ]] && echo found || echo none)" "found" \
  "the extractor reads the renewal's own body out of the shipped script"
assert_eq "$(grep -c -F 'orch_arm_lock_signals' <<<"$RENEWAL_BODY")" "1" \
  "the renewal restores the lock's own signal handlers after the rename"
assert_eq "$(grep -c -E '^[[:space:]]*trap - INT TERM' <<<"$RENEWAL_BODY")" "0" \
  "and clears them nowhere inside that renewal, which is what would leave a held mutex at the default disposition"

if command -v timeout > /dev/null 2>&1; then
  # A token endpoint that answers after the ceiling, as a slow one does: the
  # ceiling lands while the mutex is held and the POST is in flight, which is
  # after the endpoint has rotated the refresh token.
  TOKEN_SLOW="$TMP_ROOT/token-slow"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nsleep 3\nprintf %s\n' \
    "'200 \\n{\"access_token\":\"renewed-token\",\"refresh_token\":\"rotated-refresh\",\"expires_in\":3600}\\n'" \
    > "$TOKEN_SLOW"
  chmod +x "$TOKEN_SLOW"
  new_home ceiling
  make_lane "$H" claude -60
  claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  CEILING_RC=0
  PATH="$NOFLOCK" LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" ORCH_LANES_FETCH_CMD="$FETCHER" \
    OVERSEE_WATCH_STATE_DIR="$H/state" \
    ORCH_LANES_CLAUDE_CLIENT_ID=client-1 ORCH_LANES_TOKEN_CMD="$TOKEN_SLOW" \
    timeout 2 "$LANES" pick --lane "$H/.claude" --harness claude --json > /dev/null 2>&1 ||
    CEILING_RC=$?
  assert_eq "rc=$CEILING_RC mutex=$(settled_mutex "$H/.claude/.lanes-refresh.lock.d")" \
    "rc=124 mutex=released" \
    "a renewal the ceiling lands on leaves no mutex for the next one to wait on"
  assert_eq "$(jq -r '.claudeAiOauth.refreshToken + " " + .claudeAiOauth.accessToken' "$H/.claude/.credentials.json" 2>/dev/null || echo UNREADABLE)" \
    "rotated-refresh renewed-token" \
    "and the credentials file holds the rotated refresh token the endpoint answered with"
else
  printf '  skip  a renewal a ceiling lands on: this host has no timeout to bound one with\n'
fi

echo "=== the default bound is the owner rule: more than five percent headroom ==="
# On a pick that names no model, which is every row below, a lane never launches
# on an account with five percent headroom or less. The number lives in this
# script and nowhere else, so a launcher that forwards no threshold gets the
# same one a pick typed by hand does; ORCH_LANE_MAX_PCT moves both together, and
# a setting nobody can read refuses rather than falling back.
new_home default-bound
make_lane "$H" claude 3600
claude_usage 94 10 5 Opus > "$FIXTURE_DIR/.claude.json"
table \
  "an account at 94 percent used is picked||pick --harness claude|rc=0 out=CLAUDE_CONFIG_DIR=$H/.claude" \
  "the setting is the default of --max-pct, and lowering it refuses that account|ORCH_LANE_MAX_PCT=94|pick --harness claude|rc=3 key=no-candidate,harness=claude,max-pct=94,model=none,walled=1,unmeasured=0" \
  "the flag still outranks the setting|ORCH_LANE_MAX_PCT=94|pick --harness claude --max-pct 95|rc=0 out=CLAUDE_CONFIG_DIR=$H/.claude" \
  "a setting outside 0-100 is refused before any lane is measured|ORCH_LANE_MAX_PCT=94%|pick --harness claude|rc=1 key=invalid-lane-max-pct,value=94%"

# The suite's one must-fail control on `pick`: the default moved back to 90, so
# the account at 94 percent is refused and the launchable headroom between 90
# and 95 that the owner rule opens is unused again.
MUTANT_DIR="$(mutant_scripts mutant-default lanes)" || exit 1
mutate_file "$MUTANT_DIR/lanes" 'ORCH_LANE_MAX_PCT:-95' 'ORCH_LANE_MAX_PCT:-90'
LANES_REAL="$LANES"; LANES="$MUTANT_DIR/lanes"
table \
  "control: with the default back at 90 the account at 94 percent is refused||pick --harness claude|rc=3 key=no-candidate,harness=claude,max-pct=90,model=none,walled=1,unmeasured=0"
LANES="$LANES_REAL"

new_home default-bound-spent
make_lane "$H" claude 3600
claude_usage 95 10 5 Opus > "$FIXTURE_DIR/.claude.json"
table \
  "an account at 95 percent used is refused, five percent headroom being the wall||pick --harness claude|rc=3 key=no-candidate,harness=claude,max-pct=95,model=none,walled=1,unmeasured=0" \
  "the setting raises the same bound, and that account is picked|ORCH_LANE_MAX_PCT=96|pick --harness claude|rc=0 out=CLAUDE_CONFIG_DIR=$H/.claude"

echo "=== argument handling ==="
table \
  'an unknown harness is rejected||pick --harness bogus|rc=1' \
  'an unknown subcommand is rejected||bogus|rc=1' \
  'a malformed --max-pct is rejected||list --max-pct 999x|rc=1' \
  'a --max-pct above 100 is rejected, so no threshold passes a spent wall||list --max-pct 150|rc=1 key=invalid-percent,option=--max-pct' \
  'a malformed --min-headroom-pct is rejected, and the refusal names the spelling that was passed||list --min-headroom-pct 999x|rc=1 key=invalid-percent,option=--min-headroom-pct'

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
