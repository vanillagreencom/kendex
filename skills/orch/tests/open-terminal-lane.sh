#!/usr/bin/env bash
# Tests for open-terminal's --lane wiring: how a lane is resolved (auto, an
# alias, a directory), applied to the launched command, and claimed in the
# in-flight store so the next pick of a batch moves off it. The `lanes` helper
# itself is lanes.sh; the two share lib/lanes-fixture.sh.
#
# One case per behaviour surface; shaped input is one table per case, one
# asserted row per shape. Every run gets its own claim store, tmux log and
# pane counter, so no row reads another's launches. tmux, worktree and gh are
# stubs: run under a live session (TMUX set) open-terminal's default is tmux
# mode, and an unstubbed launch would open a real window per row.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
OPEN_TERMINAL="$SCRIPTS_DIR/open-terminal"

# Physical: on macOS the temp root sits under /var -> /private/var, and the
# scripts print the resolved path.
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$TEST_DIR/lib/lanes-fixture.sh"

FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"

# --- stubs -----------------------------------------------------------------
OT_STUB_BIN="$TMP_ROOT/ot-bin"; mkdir -p "$OT_STUB_BIN"
# `worktree create` hands back a fresh directory beside its log, under the
# run the suite's trap removes, and logs the call, so a row can assert that
# no worktree was created when the lane refused.
cat > "$OT_STUB_BIN/worktree" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OT_WT_LOG"
[[ "${1:-}" == "create" ]] && { d="$(mktemp -d "$(dirname "$OT_WT_LOG")/wt.XXXXXX")"; printf '%s\n' "$d"; exit 0; }
exit 0
STUBEOF
cat > "$OT_STUB_BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
# tmux logs every call; $OT_TMUX_FAIL names one subcommand that fails after
# logging, so a window can be created and claimed while its launch fails. The
# server pid is this test process, so claims recorded against it are live;
# $OT_TMUX_PANES counts the windows created and list-panes reports each.
cat > "$OT_STUB_BIN/tmux" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OT_TMUX_LOG"
if [[ -n "${OT_TMUX_FAIL:-}" && "${1:-}" == "$OT_TMUX_FAIL" ]]; then
  exit 1
fi
n=0; [[ -f "${OT_TMUX_PANES:-}" ]] && n="$(cat "$OT_TMUX_PANES")"
case "${1:-}" in
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
cat > "$OT_STUB_BIN/ghostty" <<'STUBEOF'
#!/usr/bin/env bash
exit 0
STUBEOF
chmod +x "$OT_STUB_BIN/worktree" "$OT_STUB_BIN/gh" "$OT_STUB_BIN/tmux" "$OT_STUB_BIN/ghostty"

# A worktree whose `create` owns every item after the first, the way the real
# one exits 75 for work another session holds.
OWNED_STUB="$TMP_ROOT/worktree-owned"
cat > "$OWNED_STUB" <<'STUBEOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$OT_WT_LOG"
[[ "${1:-}" == "create" ]] || exit 0
n=0; [[ -f "$OWNED_COUNT" ]] && n="$(cat "$OWNED_COUNT")"
n=$((n + 1)); printf '%s' "$n" > "$OWNED_COUNT"
[[ "$n" -eq 1 ]] || exit 75
d="$(mktemp -d "$OWNED_ROOT/wt.XXXXXX")"; printf '%s\n' "$d"
STUBEOF
chmod +x "$OWNED_STUB"

# A fetch that serves $FLAKY_OK usage queries and fails every one after, so
# the lanes go unmeasurable between a batch's first pick and its re-pick.
cat > "$TMP_ROOT/fetch-flaky" <<'STUB'
#!/usr/bin/env bash
n=0; [[ -f "$FLAKY_COUNT" ]] && n="$(cat "$FLAKY_COUNT")"
n=$((n + 1)); printf '%s' "$n" > "$FLAKY_COUNT"
[[ "$n" -le "${FLAKY_OK:-3}" ]] || exit 1
f="$FIXTURE_DIR/$(basename "$2").json"
[[ -f "$f" ]] || exit 1
cat "$f"
STUB
chmod +x "$TMP_ROOT/fetch-flaky"

# A second home whose discovery hands back a lane carrying the claim record's
# field separator: aclaude has the most headroom, the tab lane is the re-pick.
new_home tabhome
TABHOME="$H"; TABFIX="$FIXTURE_DIR"
TABDIR="$TABHOME/.tab	claude"
make_lane "$TABHOME" aclaude 3600
mkdir -p "$TABDIR"
cp "$TABHOME/.aclaude/.credentials.json" "$TABDIR/.credentials.json"
claude_usage 10 20 5  Opus > "$TABFIX/.aclaude.json"
claude_usage 30 30 30 Opus > "$TABFIX/.tab	claude.json"
TABBED="$TMP_ROOT/tab	lane"; mkdir -p "$TABBED"

# Checkouts a row can run from: one holding a directory named like a lane
# alias, one holding a bare directory no alias claims, one with no git at all.
COLLIDE="$TMP_ROOT/collide"; mkdir -p "$COLLIDE/work"; git -C "$COLLIDE" init -q -b main
BARE="$TMP_ROOT/bare"; mkdir -p "$BARE/somelane"; git -C "$BARE" init -q -b main
NOREPO="$TMP_ROOT/norepo"; mkdir -p "$NOREPO"

standard_home home

# --- harness ---------------------------------------------------------------

# run_ot ENV ARGS... — runs open-terminal with the stubs, the standard home
# and a fresh claim store, tmux log, pane counter and worktree log under
# $RUN. ENV is a semicolon-separated list of `env` arguments that may override
# the defaults; an item `cwd=DIR` runs from DIR instead of the checkout, and
# `prep=store_ro` or `prep=claims_file` stages this run's claim store as a
# read-only directory or as a plain file before the launch. OUT is stdout and
# stderr together, the way a caller sees a launch.
RUN_SEQ=0
run_ot() {
  local env_list="$1" env_args=() items item cwd="$PWD" prep=""
  shift
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$RUN"
  if [[ -n "$env_list" ]]; then
    IFS=';' read -ra items <<<"$env_list"
    for item in "${items[@]}"; do
      case "$item" in
        cwd=*) cwd="${item#cwd=}" ;;
        prep=*) prep="${item#prep=}" ;;
        *) env_args+=("$item") ;;
      esac
    done
  fi
  case "$prep" in
    "") ;;
    store_ro) mkdir -p "$RUN/state/claims"; chmod 555 "$RUN/state/claims" ;;
    claims_file) mkdir -p "$RUN/state"; : > "$RUN/state/claims" ;;
    *) echo "run_ot: unknown prep $prep" >&2; exit 1 ;;
  esac
  OUT=$(cd "$cwd" && env LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
    TMUX=stub,1,0 OT_TMUX_LOG="$RUN/tmux.log" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$RUN/panes" \
    OT_WT_LOG="$RUN/worktree.log" OVERSEE_WATCH_STATE_DIR="$RUN/state" \
    PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
    ${env_args[@]+"${env_args[@]}"} "$OPEN_TERMINAL" "$@" 2>&1)
  RC=$?
  [[ "$prep" != store_ro ]] || chmod 755 "$RUN/state/claims"
}

# lane_names TEXT — every distinct CLAUDE_CONFIG_DIR value in TEXT, in first
# appearance order, as the lane's directory name (the home prefix stripped),
# joined by commas. The value appears bare in the launch report and
# single-quoted inside the launched command, and a report sentence may end
# on it; both spellings count once, without the full stop.
lane_names() {
  local names
  names="$(grep -oE "CLAUDE_CONFIG_DIR='?[^ '\"]+" <<<"$1" | sed -E -e "s/^CLAUDE_CONFIG_DIR='?//" -e 's/\.$//' -e "s#^$H/\\.##" | awk '!seen[$0]++' | paste -sd, - || true)"
  printf '%s' "${names:-none}"
}

# counted PATTERN FILE — matching lines, or `nolog` when the stub never wrote
# the file: a stub that never landed on PATH must not read as zero.
counted() {
  [[ -f "$2" ]] || { echo nolog; return; }
  grep -c -- "$1" "$2" || true
}

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order:
#   rc            exit status
#   stdout        `line` when anything was printed, `empty` otherwise
#   launched      windows the tmux stub created (`nolog`: tmux never ran)
#   creates       worktrees the stub was asked to create (`nolog` likewise)
#   claims        claim files recorded (`nolog`: no store directory)
#   cmd_lane      the lane the launched command's env prefix names, read from
#                 the tmux log, single-quoted as the launch shell needs it
#   claim_lanes   the distinct lanes those claims name, sorted
#   claim_window  the window the single claim names; claim_pane its pane id
#   out_lanes     the lanes the launch output names, in order
#   summary       the batch summary's lane attribution, the one fact only the
#                 summary carries: `spread=N` distinct lanes, or `lane=NAME`
observe() {
  local got="" token name value
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      stdout) value="$([[ -n "$OUT" ]] && echo line || echo empty)" ;;
      launched) value="$(counted '^new-window' "$RUN/tmux.log")" ;;
      creates) value="$(counted '^create ' "$RUN/worktree.log")" ;;
      claims) value="$([[ -d "$RUN/state/claims" ]] && ls -1 "$RUN/state/claims" | wc -l | tr -d '[:space:]' || echo nolog)" ;;
      cmd_lane) value="$(grep -oE "env CLAUDE_CONFIG_DIR='[^']*'" "$RUN/tmux.log" 2>/dev/null | sed -E -e "s/^env CLAUDE_CONFIG_DIR='//" -e "s/'\$//" -e "s#^$H/\\.##" | sort -u | paste -sd, - || true)"; value="${value:-none}" ;;
      claim_lanes) value="$(cat "$RUN"/state/claims/*.claim 2>/dev/null | cut -f3 | sed "s#^$H/\\.##" | sort -u | paste -sd, - || true)"; value="${value:-none}" ;;
      claim_window) value="$(cat "$RUN"/state/claims/*.claim 2>/dev/null | cut -f4 || true)" ;;
      claim_pane) value="$(cat "$RUN"/state/claims/*.claim 2>/dev/null | cut -f2 || true)" ;;
      out_lanes) value="$(lane_names "$OUT")" ;;
      summary)
        if grep -qE 'across [0-9]+ lanes' <<<"$OUT"; then
          value="spread=$(grep -oE 'across [0-9]+ lanes' <<<"$OUT" | head -1 | grep -oE '[0-9]+')"
        elif grep -q 'on lane CLAUDE_CONFIG_DIR=' <<<"$OUT"; then
          value="lane=$(lane_names "$(grep -o 'on lane CLAUDE_CONFIG_DIR=[^ ]*' <<<"$OUT" | head -1)")"
        else
          value=none
        fi
        ;;
      *) value=UNKNOWN_FIELD ;;
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
    run_ot "$env" $args
    assert_eq "$(observe "$expect")" "$expect" "$label"
  done
}

echo "=== a lane is resolved before anything launches ==="
# --help needs no git repository: a PROJECT_ROOT substitution under `set -e`
# before argument parsing would die with git's 128 and no output. A refusal
# from `lanes` stops the launch before a worktree exists: discovering "every
# account is full" after spawning worktrees has already done the expensive
# half. An explicit --lane that is not a directory is a typo, not a config
# dir; one carrying the claim record's field separator can never be counted.
table \
  "--help exits 0 outside a git repository|cwd=$NOREPO|--help|rc=0 stdout=line" \
  'no lane under the threshold: nothing launched, no worktree created||--harness claude --lane auto --lane-max-pct 15 --cmd true CC-1|rc=1 launched=nolog creates=nolog' \
  'an explicit --lane that is not a directory is refused||--harness claude --lane /nonexistent/lane CC-1|rc=1 launched=nolog' \
  'an unknown --lane alias is refused|ORCH_LANE_ALIASES=eclaude=work|--harness claude --lane nosuchlane --cmd true CC-1|rc=1 launched=nolog'

# The separator-bearing path cannot ride through a table row's word split.
run_ot "" --harness claude --lane "$TABBED" --cmd true CC-21
assert_eq "$(observe "rc=1 launched=nolog")" "rc=1 launched=nolog" "a tab-bearing lane config dir is refused"

echo "=== a bare --lane word is an alias first, then a directory ==="
# The alias owns the bare word: a cwd directory with the same name would
# otherwise win and launch under a config dir nobody configured, silently. A
# word no alias claims still resolves as a directory.
table \
  "a cwd directory does not shadow the alias it collides with|ORCH_LANE_ALIASES=eclaude=work;cwd=$COLLIDE|--harness claude --lane work --cmd true CC-1|rc=0 out_lanes=eclaude" \
  "a bare word no alias claims falls back to the directory|ORCH_LANE_ALIASES=eclaude=work;cwd=$BARE|--harness claude --lane somelane --cmd true CC-1|rc=0 out_lanes=somelane"

echo "=== a tmux launch under a lane runs under it and records its claim ==="
# The launched command carries the lane as a single-quoted env prefix; the
# claim names the lane's config dir, the window, and the pane id that keeps
# it prunable; a launch with no lane has no account to claim; a GUI
# launch has no pane to keep a claim alive, so a GUI batch records nothing
# and stays on the lane resolved up front.
table \
  "--lane <alias> launches under that lane's env prefix and records one claim naming lane, window and pane|ORCH_LANE_ALIASES=eclaude=work|--harness claude --lane work --cmd true CC-2|rc=0 cmd_lane=eclaude claims=1 claim_lanes=eclaude claim_window=CC-2 claim_pane=%1" \
  'a launch with no --lane still opens its window and records no claim||--harness claude --cmd true CC-3|launched=1 claims=nolog' \
  'a GUI batch launches, records no claim, and reports the one lane it resolved|TERMINAL=ghostty|--ghostty --harness claude --lane auto --cmd true CC-10 CC-11|rc=0 claims=nolog summary=lane=claude'

echo "=== --lane auto over a batch re-picks off every claimed lane ==="
# Each recorded claim moves the next item off that lane; a window created and
# then failed still holds its account (the trigger is an attempted item); the
# summary counts distinct lanes. A claim that could not be written, a claims
# path that is not a directory, a re-picked lane carrying the separator, or a
# re-pick that cannot place its item stops the batch instead of launching the
# next item blind; an item another session owns never carried a session and
# is not a lane the batch ran on.
table \
  'a two-item batch spreads across two accounts, most headroom first|| --harness claude --lane auto --cmd true CC-4 CC-5|rc=0 launched=2 claim_lanes=claude,eclaude out_lanes=claude,eclaude summary=spread=2' \
  'a claimed window whose launch failed still moves the next item off that lane|OT_TMUX_FAIL=send-keys|--harness claude --lane auto --cmd true CC-8 CC-9|launched=2 claim_lanes=claude,eclaude out_lanes=claude,eclaude' \
  'a third item returning to a used lane still reports two distinct lanes||--harness claude --lane auto --cmd true CC-12 CC-13 CC-14|launched=3 summary=spread=2' \
  "a re-picked lane carrying a separator stops the batch after the first launch|LANES_HOME=$TABHOME;FIXTURE_DIR=$TABFIX|--harness claude --lane auto --cmd true CC-22 CC-23|rc=1 launched=1 claims=1" \
  "a re-pick that cannot place its item stops the batch after the first launch|ORCH_LANES_FETCH_CMD=$TMP_ROOT/fetch-flaky;FLAKY_COUNT=$TMP_ROOT/flaky-count;FLAKY_OK=3|--harness claude --lane auto --cmd true CC-6 CC-7|rc=1 launched=1 claims=1" \
  "a lane picked for an item another session owns is not one the batch ran on|WORKTREE_CLI=$OWNED_STUB;OWNED_COUNT=$TMP_ROOT/owned-count;OWNED_ROOT=$TMP_ROOT|--harness claude --lane auto --cmd true CC-17 CC-18|launched=1 summary=lane=claude"

# A claims path that is not a directory is a misconfiguration, not an empty
# store: the pick refuses before anything launches.
table \
  'a non-directory claims path refuses the launch|prep=claims_file|--harness claude --lane auto --cmd true CC-19|rc=1 launched=nolog'

# Root writes into a mode-555 directory, so the row cannot fail a write there.
if [[ "$(id -u)" -eq 0 ]]; then
  printf '  skip  unwritable claim store (running as root)\n'
else
  table \
    'a claim that could not be recorded stops the batch after the launch that stands|prep=store_ro|--harness claude --lane auto --cmd true CC-15 CC-16|rc=1 launched=1'
fi

echo "=== the claim store belongs to the caller's checkout ==="
# `.agents` in a worktree points back at the main checkout, so a root derived
# from the script's own path would write where `lanes` never looks.
SCRIPTREPO="$TMP_ROOT/scriptrepo"; CALLERREPO="$TMP_ROOT/callerrepo"
mkdir -p "$SCRIPTREPO/scripts/lib" "$CALLERREPO"
cp "$OPEN_TERMINAL" "$SCRIPTS_DIR/lanes" "$SCRIPTREPO/scripts/"
cp "$SCRIPTS_DIR/lib"/*.sh "$SCRIPTREPO/scripts/lib/"
chmod +x "$SCRIPTREPO/scripts/open-terminal" "$SCRIPTREPO/scripts/lanes"
git -C "$SCRIPTREPO" init -q; git -C "$CALLERREPO" init -q
( cd "$CALLERREPO" && LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
  TMUX=stub,1,0 OT_TMUX_LOG="$TMP_ROOT/caller.tmux.log" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$TMP_ROOT/caller.panes" \
  OT_WT_LOG="$TMP_ROOT/caller.worktree.log" PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
  "$SCRIPTREPO/scripts/open-terminal" --harness claude --lane auto --cmd true CC-20 ) >/dev/null 2>&1
assert_eq "caller=$(ls -1 "$CALLERREPO"/tmp/oversee-watch/claims 2>/dev/null | wc -l | tr -d '[:space:]') script=$(ls -1 "$SCRIPTREPO"/tmp/oversee-watch/claims 2>/dev/null | wc -l | tr -d '[:space:]')" \
  "caller=1 script=0" "the claim lands in the caller checkout, where lanes reads it, never under the script's"

# Hermeticity proof: every window the launch rows created went through the
# stub. No new-window line anywhere means a real tmux server took the calls.
if grep -q '^new-window' "$TMP_ROOT"/runs/*/tmux.log 2>/dev/null; then
  pass "launch rows drove the tmux stub, not a real server"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "launch rows bypassed the tmux stub (real windows were created)"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
