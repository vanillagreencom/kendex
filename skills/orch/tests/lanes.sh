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
  OUT=$(env LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" \
    OVERSEE_WATCH_STATE_DIR="$RUN/store" TMUX_PANES_FILE="$RUN/panes" \
    PATH="$CLAIM_BIN:$PATH" ${env_args[@]+"${env_args[@]}"} "$LANES" "$@" 2>"$ERR")
  RC=$?
}

json() { jq -r "$1" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE; }

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order. Names:
#   rc                    exit status
#   out                   stdout, whole
#   <alias>.<field>       that field of the listed lane with that alias
#   first.<field>         that field of the only listed lane
#   bs.<field>            that field of the backslash-named lane
#   aliases               every listed alias, sorted
#   files                 the claim files left in the store, sorted, or none
observe() {
  local got="" token name value alias field
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      out) value="$OUT" ;;
      length) value="$(json length)" ;;
      aliases) value="$(json '[.[].alias] | sort | join(",")')" ;;
      files) value="$(ls -1 "$STORE/claims" 2>/dev/null | sed 's/\.claim$//' | paste -sd, - || true)"; [[ -n "$value" ]] || value=none ;;
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
  "every candidate config dir is listed||$LIST|length=4" \
  "a dir with no credentials is reported, not silently dropped||$LIST|openclaude.status=no_credentials" \
  "the plan is read from the credentials file without a network call||$LIST|claude.plan=max" \
  "a low session but high weekly yields low headroom||$LIST|nclaude.headroom_pct=5" \
  "a high session bucket binds when it is the largest||$LIST|eclaude.headroom_pct=20" \
  "headroom is 100 minus the largest bucket||$LIST|claude.headroom_pct=80" \
  "the model-scoped label comes from the API, not a hard-coded name||$LIST|claude.model_label=Opus" \
  "a lane with no live claim counts 0||$LIST|claude.claims=0"

echo "=== aliases are an overlay on the discovered inventory ==="
# Discovery keeps finding every account with no configuration at all; an
# alias relabels one it found and can neither add nor drop a lane, nor change
# what was measured.
table \
  "with no aliases every discovered lane keeps its directory name||$LIST|aliases=claude,eclaude,nclaude,openclaude" \
  "an alias renames the lane it names, whitespace around the pairs tolerated|ORCH_LANE_ALIASES=eclaude=work, nclaude = overflow|$LIST|aliases=claude,openclaude,overflow,work" \
  "the renamed lane is the directory the alias named|ORCH_LANE_ALIASES=eclaude=work|$LIST|work.config_dir=$H/.eclaude" \
  "an alias naming no discovered directory is inert|ORCH_LANE_ALIASES=notthere=phantom|$LIST|aliases=claude,eclaude,nclaude,openclaude" \
  "an alias does not change the lane's measured headroom|ORCH_LANE_ALIASES=eclaude=work|$LIST|work.headroom_pct=20"

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
  "a 7-day primary window fills the weekly slot and the missing session window stays null|CODEX_HOME=$H/.codex|list --harness codex --json|first.weekly_pct=44 first.session_5h_pct=null first.headroom_pct=56"
jq -n '{rate_limit: {primary_window: {used_percent: 30, reset_at: 1785000000, limit_window_seconds: 18000},
                     secondary_window: {used_percent: 70, reset_at: 1785600000, limit_window_seconds: 604800}}}' \
  > "$FIXTURE_DIR/.codex.json"
table \
  "a 5h and a 7d window fill their slots and the larger binds|CODEX_HOME=$H/.codex|list --harness codex --json|first.session_5h_pct=30 first.weekly_pct=70 first.headroom_pct=30"

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
  for part in "${parts[@]}"; do
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
      pid="$LIVE_PID"; [[ "${entry%%:*}" == live ]] || pid="$DEAD_PID"
      pane="${entry#*:}"
      printf '%s %s\n' "$pid" "$pane" >> "$target"
    done
  done
}

# stage_claims SPEC — the claim files for one run, `name:server:pane:dir` items
# separated by `;`: server is live or dead, dir a lane name under the home,
# `claude/` for a trailing slash, `link` for a symlink to claude, `bs` for the
# backslash-named lane; `junk` writes a malformed record.
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
    pid="$LIVE_PID"; [[ "$server" == live ]] || pid="$DEAD_PID"
    case "$dir" in
      claude/) dir="$H/.claude/" ;;
      link) dir="$TMP_ROOT/claude-link" ;;
      bs)
        dir="$BSDIR"
        mkdir -p "$BSDIR"
        cp "$H/.claude/.credentials.json" "$BSDIR/.credentials.json"
        claude_usage 10 20 5 Opus > "$FIXTURE_DIR/$(basename "$BSDIR").json"
        ;;
      *) dir="$H/.$dir" ;;
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

echo "=== argument handling ==="
table \
  'an unknown harness is rejected||pick --harness bogus|rc=1' \
  'an unknown subcommand is rejected||bogus|rc=1' \
  'a malformed --max-pct is rejected||list --max-pct 999x|rc=1'

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
