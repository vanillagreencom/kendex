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
# Every lane this suite measures lives under LANES_HOME; an inherited lane
# setting would point discovery at the operator's real accounts.
unset ORCH_LANE_DIRS ORCH_LANE_ALIASES ORCH_LANE_EXCLUDE ORCH_LANE_RETIRE ORCH_LANES_USAGE_TTL CODEX_HOME
# The caller's environment outranks project settings, so a pinned local host
# keeps an inherited or configured provider out of the local rows; hosted rows
# pass the stub themselves.
export ORCH_LANE_HOST=local
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
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
[[ "${1:-}" == "create" ]] && { d="$(mktemp -d "$(dirname "$OT_WT_LOG")/wt.XXXXXX")"; git init -q "$d"; printf '%s\n' "$d"; exit 0; }
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
  display-message)
    if [[ "$*" == *pane_current_command* ]]; then echo ssh
    elif [[ "$*" == *pane_pid* ]]; then
      # The moment the account check starts: a row that holds its leaf back
      # until then puts the first read inside the window it is pinning.
      [[ -z "${OT_PANE_PID_TRIGGER:-}" ]] || : > "$OT_PANE_PID_TRIGGER"
      printf '%s\n' "${OT_PANE_PID:-0}"
    else echo 0; fi ;;
  capture-pane) printf '%s\n' "${OT_PANE_TEXT:-dev@lane:~\$}" ;;
  load-buffer) cat "${!#}" >> "$OT_TMUX_LOG" ;;
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
d="$(mktemp -d "$OWNED_ROOT/wt.XXXXXX")"; git init -q "$d"; printf '%s\n' "$d"
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
    OT_WT_LOG="$RUN/worktree.log" OVERSEE_WATCH_STATE_DIR="$RUN/state" LANE_HOST_STUB_LOG="$RUN/host.log" \
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
#   refused       the first field of the lane-refused line, or none
#   failed        the first field of the lane-resolution-failed line, or none
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
        local summary_line lane_count
        summary_line="$(grep '^open-terminal: summary ' <<<"$OUT" || true)"
        lane_count="$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^lanes=/) print substr($i,7)}' <<<"$summary_line")"
        if [[ "${lane_count:-0}" -gt 1 ]]; then
          value="spread=$lane_count"
        elif [[ "$summary_line" == *' lane=CLAUDE_CONFIG_DIR='* ]]; then
          value="lane=$(lane_names "$summary_line")"
        else
          value=none
        fi
        ;;
      refused)
        value="$(awk '$1 == "open-terminal:" && $2 == "lane-refused" { print $3; exit }' <<<"$OUT")"
        value="${value:-none}"
        ;;
      failed)
        value="$(awk '$1 == "open-terminal:" && $2 == "lane-resolution-failed" { print $3; exit }' <<<"$OUT")"
        value="${value:-none}"
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
# A named lane ORCH_LANE_EXCLUDE or ORCH_LANE_RETIRE covers is refused, by
# alias or by path alike, and an excluded lane's alias before a same-named cwd
# directory can stand in for it. A lanes check that fails for another reason
# (a malformed setting) is reported as that failure, never as a covered lane.
table \
  "--help exits 0 outside a git repository|cwd=$NOREPO|--help|rc=0 stdout=line" \
  'no lane under the threshold: nothing launched, no worktree created||--harness claude --lane auto --lane-max-pct 15 --cmd true CC-1|rc=1 launched=nolog creates=nolog' \
  'an explicit --lane that is not a directory is refused||--harness claude --lane /nonexistent/lane CC-1|rc=1 launched=nolog' \
  'an unknown --lane alias is refused|ORCH_LANE_ALIASES=eclaude=work|--harness claude --lane nosuchlane --cmd true CC-1|rc=1 launched=nolog' \
  'a retired lane named by its alias is refused before anything launches|ORCH_LANE_ALIASES=eclaude=work;ORCH_LANE_RETIRE=eclaude=2000-01-01|--harness claude --lane work --cmd true CC-1|rc=1 launched=nolog refused=lane=work' \
  "an excluded lane named by its config dir is refused before anything launches|ORCH_LANE_EXCLUDE=eclaude|--harness claude --lane $H/.eclaude --cmd true CC-1|rc=1 launched=nolog refused=lane=$H/.eclaude" \
  "an excluded lane's alias is refused even beside a same-named cwd directory|ORCH_LANE_ALIASES=eclaude=work;ORCH_LANE_EXCLUDE=eclaude;cwd=$COLLIDE|--harness claude --lane work --cmd true CC-1|rc=1 launched=nolog refused=lane=work" \
  "an excluded lane's alias with no same-named directory is refused, not unknown|ORCH_LANE_ALIASES=eclaude=work;ORCH_LANE_EXCLUDE=eclaude;cwd=$BARE|--harness claude --lane work --cmd true CC-1|rc=1 launched=nolog refused=lane=work" \
  "a named lane whose check fails on a malformed setting is a resolution failure, not a refusal|ORCH_LANES_USAGE_TTL=soon|--harness claude --lane $H/.eclaude --cmd true CC-1|rc=1 launched=nolog refused=none failed=exit=1"

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
  "a re-pick that cannot place its item stops the batch after the first launch|ORCH_LANES_FETCH_CMD=$TMP_ROOT/fetch-flaky;FLAKY_COUNT=$TMP_ROOT/flaky-count;FLAKY_OK=3;ORCH_LANES_USAGE_TTL=0|--harness claude --lane auto --cmd true CC-6 CC-7|rc=1 launched=1 claims=1" \
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

echo "=== a hosted launch goes through lane-host create and an ssh pane ==="
# The host stub answers create with one fixed line. A hosted launch calls no
# worktree helper, types ssh, then the remote prefix, and renders no lane env
# prefix while its claim still names the lane. A relaunch hands the picked
# account and --relaunch to create and continues the harness natively. Create
# exit 75 skips the item; any other exit fails it before a window opens. A
# harness the host protocol does not name and a wake are refused before create,
# and a create line missing a field fails the item before a window opens.
HOST_STUB="$TEST_DIR/fixtures/lane-host"
host_call() { [[ -f "$RUN/host.log" ]] || { echo nolog; return; }; sed -E -e 's/ +$//' -e "s#$H/\\.##g" -e 's/ /,/g' "$RUN/host.log"; }
typed() { grep -cF -- "$1" "$RUN/tmux.log" 2>/dev/null || true; }
said() { grep -cxF -- "$1" <<<"$OUT" || true; }

run_ot "ORCH_LANE_HOST=$HOST_STUB;ORCH_LANE_ALIASES=eclaude=work" --harness claude --lane work --repo o/r --cmd true CC-40
assert_eq "$(observe "rc=0 creates=nolog launched=1 claim_lanes=eclaude") create=$(host_call) ssh=$(typed "clear; ssh 'lane.example'") remote=$(typed "exec bash -lc 'cd /srv/lane && exec true'") env=$(typed CLAUDE_CONFIG_DIR=) opened=$(said "open-terminal: tmux-opened item=CC-40 host=$HOST_STUB path=/srv/lane")" \
  "rc=0 creates=nolog launched=1 claim_lanes=eclaude create=create,--item,CC-40,--repo,o/r,--harness,claude,--account,eclaude ssh=1 remote=1 env=0 opened=1" \
  "a hosted launch creates through lane-host, types ssh then the remote line, and renders no lane env prefix"
# A hosted relaunch continues natively. Q is how single_quote renders one quote
# of the continuation line inside the remote command.
#
# One row per harness, because the three resume forms take a prompt
# differently and only two of them can be given one here. `claude [prompt]` and
# `pi [messages...]` take it as a trailing positional. `codex resume` declares
# [SESSION_ID] [PROMPT] and binds by position, so a lone positional beside
# --last would be read as a session id; a hosted lane has no local transcript
# to resolve a real id from, so its resume is rendered promptless and the line
# is sent separately. The codex row pins the absence, which is the behaviour
# oversee.md describes.
Q="'\\''"
hosted_line() { printf 'Resume the orch workflow for %s from where this session stopped. Run .agents/skills/orch/scripts/lane-mail inbox --item %s first and act on every directive it prints.' "$1" "$1"; }
HOSTED_LINE="$(hosted_line CC-41)"
run_ot "" --host "$HOST_STUB" --harness claude --lane auto --repo o/r --relaunch --launch-flags --model=opus CC-41
assert_eq "$(observe "rc=0 creates=nolog launched=1") create=$(host_call) remote=$(typed "exec bash -lc 'cd /srv/lane && exec claude $Q--model=opus$Q --continue $Q$HOSTED_LINE$Q'")" \
  "rc=0 creates=nolog launched=1 create=create,--item,CC-41,--repo,o/r,--harness,claude,--account,claude,--relaunch remote=1" \
  "a hosted claude relaunch passes the picked account and --relaunch, and continues natively with the continuation line"
HOSTED_LINE="$(hosted_line CC-48)"
run_ot "ORCH_LANE_ALIASES=eclaude=work" --host "$HOST_STUB" --harness pi --lane work --repo o/r --relaunch CC-48
assert_eq "$(observe "rc=0 creates=nolog launched=1") remote=$(typed "exec bash -lc 'cd /srv/lane && exec pi -c $Q$HOSTED_LINE$Q'")" \
  "rc=0 creates=nolog launched=1 remote=1" \
  "a hosted pi relaunch continues natively with the continuation line"
run_ot "ORCH_LANE_ALIASES=eclaude=work" --host "$HOST_STUB" --harness codex --lane work --repo o/r --relaunch CC-49
assert_eq "$(observe "rc=0 creates=nolog launched=1") remote=$(typed "exec bash -lc 'cd /srv/lane && exec codex resume --last'") line=$(typed "Resume the orch workflow for CC-49")" \
  "rc=0 creates=nolog launched=1 remote=1 line=0" \
  "a hosted codex relaunch resumes promptless, so no sentence lands in the session-id slot"
# A GitHub-tracker item is the issue number while its worktree id is issue-<n>,
# and the lane's mailbox is bound under the worktree id: write_lane_marker
# writes it there and the overseer's `lane-mail send --item` writes the same
# id. A line built from the bare number would send the lane to an empty mailbox
# and lose every queued answer, directive and halt. The hosted arm renders the
# line with no transcript lookup, so it is where the two ids are visibly
# distinct.
HOSTED_LINE="$(hosted_line issue-2708)"
run_ot "ORCH_LANE_ALIASES=eclaude=work" --host "$HOST_STUB" --tracker github --harness claude --lane work --repo o/r --relaunch 2708
assert_eq "$(observe "rc=0 creates=nolog launched=1") create=$(host_call) remote=$(typed "exec bash -lc 'cd /srv/lane && exec claude --continue $Q$HOSTED_LINE$Q'")" \
  "rc=0 creates=nolog launched=1 create=create,--item,issue-2708,--repo,o/r,--harness,claude,--account,eclaude,--relaunch remote=1" \
  "a GitHub relaunch names the worktree id its mailbox is bound under, never the bare issue number"
run_ot "LANE_HOST_STUB_STATUS=75" --host "$HOST_STUB" --harness claude --lane auto --repo o/r --cmd true CC-42
assert_eq "$(observe "rc= launched=") owned=$(awk '$2 == "item-owned" { print $3 }' <<<"$OUT")" "rc=75 launched=nolog owned=item=CC-42" \
  "a hosted create exit 75 skips the item as owned by another session"
run_ot "LANE_HOST_STUB_STATUS=1" --host "$HOST_STUB" --harness claude --lane auto --repo o/r --cmd true CC-43
assert_eq "$(observe "rc= launched= creates=") failed=$(said "open-terminal: host-create-failed item=CC-43 exit=1")" "rc=1 launched=nolog creates=nolog failed=1" \
  "a hosted create failure is host-create-failed and opens no window"
run_ot "" --host "$HOST_STUB" --lane "$H/.eclaude" --repo o/r --cmd true CC-44
assert_eq "$(observe "rc= launched= creates=") create=$(host_call) invalid=$(awk '$2 == "host-invalid" { print $NF }' <<<"$OUT")" "rc=1 launched=nolog creates=nolog create=nolog invalid=harness=" \
  "a hosted launch without a host-protocol harness is host-invalid before any create"
run_ot "" --host "$HOST_STUB" --harness claude --wake CC-45
assert_eq "$(observe "rc=") create=$(host_call) wake=$(awk '$2 == "wake-invalid"' <<<"$OUT" | wc -l | tr -d '[:space:]')" "rc=1 create=nolog wake=1" \
  "a hosted wake is wake-invalid before any create"
run_ot "LANE_HOST_STUB_CREATE_LINE=ssh-target=lane.example"$'\t'"path=/srv/lane" --host "$HOST_STUB" --harness claude --lane auto --repo o/r --cmd true CC-46
assert_eq "$(observe "rc= launched=") invalid=$(said "open-terminal: host-line-invalid item=CC-46")" "rc=1 launched=nolog invalid=1" \
  "a create line missing its remote prefix is host-line-invalid and opens no window"
# lane-host create writes the hosted lane's marker on its host. A local one
# would bind the caller's own checkout, which would then pose as a lane.
HOSTCALLER="$TMP_ROOT/hostcaller"; mkdir -p "$HOSTCALLER"; git -C "$HOSTCALLER" init -q
run_ot "cwd=$HOSTCALLER" --host "$HOST_STUB" --harness claude --lane auto --repo o/r --cmd true CC-47
assert_eq "$(observe "rc= launched=") local_marker=$([[ -e "$HOSTCALLER/.git/lane-mail" ]] && echo present || echo absent)" "rc=0 launched=1 local_marker=absent" \
  "a hosted launch writes no lane marker into the caller's own checkout"

echo "=== the claim store belongs to the caller's checkout ==="
# `.agents` in a worktree points back at the main checkout, so a root derived
# from the script's own path would write where `lanes` never looks.
SCRIPTREPO="$TMP_ROOT/scriptrepo"; CALLERREPO="$TMP_ROOT/callerrepo"
mkdir -p "$SCRIPTREPO/scripts/lib" "$CALLERREPO"
cp "$OPEN_TERMINAL" "$SCRIPTS_DIR/lanes" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/git-context" "$SCRIPTREPO/scripts/"
cp "$SCRIPTS_DIR/lib"/*.sh "$SCRIPTREPO/scripts/lib/"
orch_fixture_shared_libs "$SCRIPTREPO"
chmod +x "$SCRIPTREPO/scripts/open-terminal" "$SCRIPTREPO/scripts/lanes"
git -C "$SCRIPTREPO" init -q; git -C "$CALLERREPO" init -q
( cd "$CALLERREPO" && LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
  TMUX=stub,1,0 OT_TMUX_LOG="$TMP_ROOT/caller.tmux.log" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$TMP_ROOT/caller.panes" \
  OT_WT_LOG="$TMP_ROOT/caller.worktree.log" PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
  "$SCRIPTREPO/scripts/open-terminal" --harness claude --lane auto --cmd true CC-20 ) >/dev/null 2>&1
assert_eq "caller=$(ls -1 "$CALLERREPO"/tmp/oversee-watch/claims 2>/dev/null | wc -l | tr -d '[:space:]') script=$(ls -1 "$SCRIPTREPO"/tmp/oversee-watch/claims 2>/dev/null | wc -l | tr -d '[:space:]')" \
  "caller=1 script=0" "the claim lands in the caller checkout, where lanes reads it, never under the script's"

# The repository the launch line renders splits the same way. The resolver's
# first rung, `gh repo view`, answers for the caller's cwd, so its origin-remote
# fallback must read the caller's checkout too — reading the script's would
# brief the lane on whichever repository the kendex install happens to sit in.
# gh exits 1 here, which is the rung that answers nothing.
git -C "$SCRIPTREPO" remote add origin git@github.com:script-owner/script-repo.git
git -C "$CALLERREPO" remote add origin git@github.com:caller-owner/caller-repo.git
REPO_LOG="$TMP_ROOT/caller.repo.tmux.log"
( cd "$CALLERREPO" && LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
  TMUX=stub,1,0 OT_TMUX_LOG="$REPO_LOG" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$TMP_ROOT/caller.repo.panes" \
  OT_WT_LOG="$TMP_ROOT/caller.repo.worktree.log" PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
  "$SCRIPTREPO/scripts/open-terminal" --harness claude --lane auto --cmd 'true {repo}' CC-21 ) >/dev/null 2>&1
assert_eq "caller=$(grep -c 'caller-owner/caller-repo' "$REPO_LOG" || true) script=$(grep -c 'script-owner/script-repo' "$REPO_LOG" || true)" \
  "caller=1 script=0" "the launch line names the caller checkout's repository, never the script checkout's"

echo "=== a GH_REPO the resolver refuses never reaches the launch line ==="
# The resolver returns status 2 for a value that is not owner/name and PRINTS
# it anyway, so the value is on stdout whether it was accepted or rejected.
# resolve_repo is where that distinction is kept: a consumer reading the
# output without the status types a quote-bearing GH_REPO into the pane shell
# that runs the rendered line. gh-repo-resolve.test.sh pins the refusal; this
# pins what open-terminal does with it.
BAD_REPO="o/r';id;'"

# The mutant: a resolve_repo that reads the output and drops the status.
MUTREPO="$TMP_ROOT/mutrepo"
mkdir -p "$MUTREPO/scripts/lib"
cp "$OPEN_TERMINAL" "$SCRIPTS_DIR/lanes" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/git-context" "$MUTREPO/scripts/"
cp "$SCRIPTS_DIR/lib"/*.sh "$MUTREPO/scripts/lib/"
orch_fixture_shared_libs "$MUTREPO"
chmod +x "$MUTREPO/scripts/open-terminal" "$MUTREPO/scripts/lanes"
assert_eq "$(grep -Fc '[[ "$resolve_status" -eq 0 ]] || return 0' "$MUTREPO/scripts/open-terminal")" "1" \
  "control finds exactly one live status check"
# `#` as the delimiter: the line the control rewrites carries `||`.
sed -i.bak 's#\[\[ "$resolve_status" -eq 0 \]\] || return 0#[[ "$resolve_status" -eq 0 ]] || :#' \
  "$MUTREPO/scripts/open-terminal"
assert_eq "$(grep -Fc '[[ "$resolve_status" -eq 0 ]] || return 0' "$MUTREPO/scripts/open-terminal")" "0" \
  "control applied the mutation"

# run_bad_repo SCRIPT NAME — one launch under the refused GH_REPO, from a
# caller checkout of its own so the claim store starts empty. Prints
# `launched=<n> rejected=<n>`: the windows opened, and the tmux lines carrying
# the refused value. Both halves matter — a run that launched nothing would
# report rejected=0 for the wrong reason.
run_bad_repo() {
  local script="$1" name="$2"
  local caller="$TMP_ROOT/$name-caller" log="$TMP_ROOT/$name.tmux.log"
  mkdir -p "$caller"
  git -C "$caller" init -q
  ( cd "$caller" && LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
    GH_REPO="$BAD_REPO" TMUX=stub,1,0 OT_TMUX_LOG="$log" OT_TMUX_SERVER_PID="$$" \
    OT_TMUX_PANES="$TMP_ROOT/$name.panes" OT_WT_LOG="$TMP_ROOT/$name.worktree.log" \
    PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
    "$script" --harness claude --lane auto --cmd 'true {repo}' CC-30 ) >/dev/null 2>&1
  printf 'launched=%s rejected=%s' \
    "$(grep -c '^new-window' "$log" || true)" "$(grep -cF "$BAD_REPO" "$log" || true)"
}

assert_eq "$(run_bad_repo "$SCRIPTREPO/scripts/open-terminal" refused)" "launched=1 rejected=0" \
  "a GH_REPO the resolver refuses renders no repository into the launch line"
assert_eq "$(run_bad_repo "$MUTREPO/scripts/open-terminal" accepted)" "launched=1 rejected=1" \
  "must-fail control: a resolve_repo that drops the status types the refused value into the pane"

echo "=== a launch binds its item to the tree it made, or fails the item ==="
# lane-mail-check hands a lane its mail only where this marker names the tree's
# root. A tree git cannot mark fails the item rather than launching a lane the
# hook never reaches. The unmarkable tree sits outside every repository, and the
# ceiling keeps git from finding the one the suite's temp root may sit in.
NOGIT_STUB="$TMP_ROOT/worktree-nogit"
cat > "$NOGIT_STUB" <<'STUBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "create" ]] && { mktemp -d "$(dirname "$OT_WT_LOG")/wt.XXXXXX"; exit 0; }
exit 0
STUBEOF
chmod +x "$NOGIT_STUB"

# marked SCRIPT NAME WORKTREE_CLI — one launch of CC-40 from a caller checkout
# of its own. Prints `rc=<rc> marker=<root|none|other> refused=<marker-failed lines>`.
marked() {
  local script="$1" name="$2" runs="$TMP_ROOT/$2-runs" caller="$TMP_ROOT/$2-caller" out rc=0 wt marker=none
  mkdir -p "$runs" "$caller"
  git -C "$caller" init -q
  out="$( cd "$caller" && GIT_CEILING_DIRECTORIES="$TMP_ROOT" LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' TMUX=stub,1,0 OT_TMUX_LOG="$runs/tmux.log" OT_TMUX_SERVER_PID="$$" \
    OT_TMUX_PANES="$runs/panes" OT_WT_LOG="$runs/worktree.log" PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$3" \
    "$script" --harness claude --cmd true CC-40 2>&1 )" || rc=$?
  wt="$(find "$runs" -maxdepth 1 -type d -name 'wt.*')"
  if [[ -f "$wt/.git/lane-mail/cc-40" ]]; then
    marker=other
    [[ "$(cat "$wt/.git/lane-mail/cc-40")" != "$wt" ]] || marker=root
  fi
  printf 'rc=%s marker=%s refused=%s' "$rc" "$marker" "$(grep -c '^open-terminal: marker-failed item=CC-40 ' <<<"$out" || true)"
}

assert_eq "$(marked "$OPEN_TERMINAL" marked "$OT_STUB_BIN/worktree")" "rc=0 marker=root refused=0" \
  "a launch binds its lowercased item to the root of the tree it made"
assert_eq "$(marked "$OPEN_TERMINAL" unmarkable "$NOGIT_STUB")" "rc=1 marker=none refused=1" \
  "a tree git cannot mark fails the item instead of launching it"

# A symlink already at the marker path fails the item and writes through nothing.
LINKED_STUB="$TMP_ROOT/worktree-linked"
cat > "$LINKED_STUB" <<'STUBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "create" ]] || exit 0
d="$(mktemp -d "$(dirname "$OT_WT_LOG")/wt.XXXXXX")"
git init -q "$d"
mkdir -p "$d/.git/lane-mail"
ln -s "$(dirname "$OT_WT_LOG")/marker-target" "$d/.git/lane-mail/cc-40"
printf '%s\n' "$d"
STUBEOF
chmod +x "$LINKED_STUB"
LINKED="$(marked "$OPEN_TERMINAL" linked "$LINKED_STUB")"
assert_eq "$LINKED target=$([[ -e "$TMP_ROOT/linked-runs/marker-target" ]] && echo written || echo untouched)" \
  "rc=1 marker=none refused=1 target=untouched" "a symlink at the marker path fails the item and writes through nothing"

# The mutant: the marker line gone, so neither the write nor its refusal runs.
MARKREPO="$TMP_ROOT/markrepo"
mkdir -p "$MARKREPO/scripts/lib"
cp "$OPEN_TERMINAL" "$SCRIPTS_DIR/lanes" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/git-context" "$MARKREPO/scripts/"
cp "$SCRIPTS_DIR/lib"/*.sh "$MARKREPO/scripts/lib/"
orch_fixture_shared_libs "$MARKREPO"
chmod +x "$MARKREPO/scripts/open-terminal" "$MARKREPO/scripts/lanes"
sed -i.bak '/^  if \[\[ "\$WAKE" != true && "\$LANE_HOST" == local && -d "\$wt" \]\] && ! write_lane_marker /d' "$MARKREPO/scripts/open-terminal"
assert_eq "$(grep -c 'ot_message marker-failed' "$MARKREPO/scripts/open-terminal")" "0" "control applied the marker mutation"
assert_eq "$(marked "$MARKREPO/scripts/open-terminal" mutant-marked "$OT_STUB_BIN/worktree")" "rc=0 marker=none refused=0" \
  "control: without the marker line a launch leaves its lane unmarked"
assert_eq "$(marked "$MARKREPO/scripts/open-terminal" mutant-unmarkable "$NOGIT_STUB")" "rc=0 marker=none refused=0" \
  "control: without the marker line an unmarkable tree launches anyway"

echo "=== a lane launches through its own launcher ==="
# A command named for the lane's config directory selects the account itself,
# and the dotfiles-style bare `claude` on PATH exports CLAUDE_CONFIG_DIR for
# its own name — so an env prefix in front of THAT is overwritten and the lane
# runs on another account with nothing on screen saying so. Where the launcher
# exists it replaces the prefix; where it does not, and where the name is the
# harness word itself, the prefix stands.
#
# These rows read the rendered launch line only, so they run on every platform.
# That matters most where the pane check below CANNOT run: there the launcher
# rule is the whole defence, and it is the leg with no second line of it.
LNBIN="$TMP_ROOT/ln-bin"; mkdir -p "$LNBIN"
# The shims: a bare `claude` and a bare `codex` that rewrite the variable for
# their own name. Nothing executes them here — tmux is a stub — but they are
# what makes the launcher the only selector that survives, and on PATH ahead of
# everything they seal the machine's own wrappers out of these rows.
cat > "$LNBIN/claude" <<'STUBEOF'
#!/usr/bin/env bash
export CLAUDE_CONFIG_DIR="$HOME/.claude"
exec true "$@"
STUBEOF
cp "$LNBIN/claude" "$LNBIN/1claude"
cp "$LNBIN/claude" "$LNBIN/codex"
cp "$LNBIN/claude" "$LNBIN/1codex"
chmod +x "$LNBIN/claude" "$LNBIN/1claude" "$LNBIN/codex" "$LNBIN/1codex"
LNLANE="$TMP_ROOT/.1claude"; mkdir -p "$LNLANE"        # `1claude` is on PATH
LNBARE="$TMP_ROOT/.lnbareclaude"; mkdir -p "$LNBARE"   # no such command exists
LNSELF="$TMP_ROOT/.claude"; mkdir -p "$LNSELF"         # named for the harness
LNCODEX="$TMP_ROOT/.1codex"; mkdir -p "$LNCODEX"       # `1codex` is on PATH
LNCODEXSELF="$TMP_ROOT/.codex"; mkdir -p "$LNCODEXSELF"

# The pane's process tree: its own process carries whatever the operator's
# shell had, its child carries $2 under the lane variable $1 the way
# `env VAR=<picked>` does, and the leaf carries $3 the way a wrapper that
# rewrote the variable does. A read that stopped at the first descendant would
# report $2 for a tree running on $3.
#
# With a trigger file in $4 the leaf appears only after that file does, which is
# how a wrapper that does work before its exec behaves: the first read then
# lands inside the window where only the picked value is on the tree.
cat > "$TMP_ROOT/lane-tree" <<'STUBEOF'
#!/usr/bin/env bash
OT_VAR="$1" OT_LEAF="$3" OT_TRIGGER="${4:-}" env "$1=$2" bash -c '
  if [[ -n "$OT_TRIGGER" ]]; then
    while [[ ! -e "$OT_TRIGGER" ]]; do sleep 0.1; done
    sleep 0.3
  fi
  env "$OT_VAR=$OT_LEAF" sleep 30 & wait' &
wait
STUBEOF
chmod +x "$TMP_ROOT/lane-tree"
# Depth first, so a parent is never killed before the children it would orphan.
kill_tree() { local p; for p in $(pgrep -P "$1" 2>/dev/null || true); do kill_tree "$p"; done; kill "$1" 2>/dev/null || true; }

# lane_launch SCRIPT NAME HARNESS LANE LEAF LATE|- FIELDS — one real-harness
# lane launch through SCRIPT, from a caller checkout of its own, with the
# launcher directory ahead of PATH and the process tree above standing in for
# the launched harness. LATE=late holds the leaf back until the check reads the
# pane pid. FIELDS names the facts to print, in its own order, so a row asserts
# exactly what it is about:
#   rc         exit status
#   form       `launcher` when the line names the launcher by the absolute path
#              the judge resolved, `prefix` under the env prefix, else `none`
#   bare       lines naming the launcher by the bare word a differently-PATHed
#              pane shell would resolve again for itself
#   verified   lane-verified lines; mismatch, lane-mismatch lines naming the
#              picked and observed dirs; closed, tmux kill-window calls
lane_launch() {
  local script="$1" name="$2" harness="$3" lane="$4" leaf="$5" late="$6" fields="$7" item="CC-50"
  local runs="$TMP_ROOT/$name-runs" caller="$TMP_ROOT/$name-caller" out rc=0 tree form=none launcher trigger="" var f value got=""
  # The lane variable per harness, pinning open-terminal's own mapping.
  case "$harness" in codex) var=CODEX_HOME ;; *) var=CLAUDE_CONFIG_DIR ;; esac
  # `basename --`, the way the judge derives it: a trailing-slash row's expected
  # name has to come out of the same normalisation the row is pinning.
  launcher="$(basename -- "$lane")"; launcher="${launcher#.}"
  mkdir -p "$runs" "$caller"
  git -C "$caller" init -q
  [[ "$late" != late ]] || trigger="$runs/trigger"
  "$TMP_ROOT/lane-tree" "$var" "$lane" "$leaf" "$trigger" & tree=$!
  out="$( cd "$caller" && LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
    TMUX=stub,1,0 OT_TMUX_LOG="$runs/tmux.log" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$runs/panes" \
    OT_PANE_PID="$tree" OT_PANE_TEXT="/orch start $item" ORCH_TMUX_VERIFY_SECS=5 OT_PANE_PID_TRIGGER="$trigger" \
    OT_WT_LOG="$runs/worktree.log" OVERSEE_WATCH_STATE_DIR="$runs/state" \
    PATH="$LNBIN:$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
    "$script" --harness "$harness" --lane "$lane" "$item" 2>&1 )" || rc=$?
  kill_tree "$tree"
  grep -qF "clear; env $var='$lane' $harness " "$runs/tmux.log" && form=prefix
  grep -qF "clear; '$LNBIN/$launcher' " "$runs/tmux.log" && form=launcher
  for f in $fields; do
    case "$f" in
      rc) value="$rc" ;;
      form) value="$form" ;;
      bare) value="$(grep -cF "clear; '$launcher' " "$runs/tmux.log" || true)" ;;
      verified) value="$(grep -c "^open-terminal: lane-verified item=$item " <<<"$out" || true)" ;;
      mismatch) value="$(grep -c "^open-terminal: lane-mismatch item=$item picked=$lane observed=" <<<"$out" || true)" ;;
      closed) value="$(grep -c '^kill-window' "$runs/tmux.log" || true)" ;;
      *) value=UNKNOWN_FIELD ;;
    esac
    got="$got $f=$value"
  done
  printf '%s' "${got# }"
}

# mutant_repo NAME BRE [REPLACEMENT] — a copy of the scripts at $TMP_ROOT/NAME
# with the one text BRE matches replaced, or the line deleted where no
# REPLACEMENT is given. One defect per copy: a repo carrying several would pass
# its rows while any one of them was caught. A rule whose deletion changes more
# than the rule takes a replacement: dropping the account check's settle test
# entirely leaves a loop that never breaks, which is not the behaviour it
# replaced, and dropping the launcher print leaves the judge emitting nothing.
mutant_repo() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/scripts/lib"
  cp "$OPEN_TERMINAL" "$SCRIPTS_DIR/lanes" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/git-context" "$dir/scripts/"
  cp "$SCRIPTS_DIR/lib"/*.sh "$dir/scripts/lib/"
  orch_fixture_shared_libs "$dir"
  chmod +x "$dir/scripts/open-terminal" "$dir/scripts/lanes"
  assert_eq "$(grep -c -e "$2" "$dir/scripts/open-terminal")" "1" "control $1 finds exactly one line to mutate"
  if [[ $# -ge 3 ]]; then sed -i.bak "s/$2/$3/" "$dir/scripts/open-terminal"
  else sed -i.bak "/$2/d" "$dir/scripts/open-terminal"; fi
  assert_eq "$(grep -c -e "$2" "$dir/scripts/open-terminal")" "0" "control $1 applied its mutation"
}

mutant_repo ctl-slash 'name="\$(basename -- "\${LANE_ENV#\*=}")"' 'name="${LANE_ENV#*=}"; name="${name##*\/}"'
mutant_repo ctl-harness '"\$name" != \*"\$HARNESS"\*'
mutant_repo ctl-launcher 'launcher:\*) cmd='
mutant_repo ctl-abspath "printf 'launcher:%s\\\\n' \"\$path\"" "printf 'launcher:%s\\\\n' \"\$name\""
mutant_repo ctl-check '^  lane_account_ok "\$pane" "\$title" ||'
mutant_repo ctl-settle '\[\[ -z "\$observed" || "\$observed" != "\$settled" \]\] || break' '[[ -z "$observed" ]] || break'

assert_eq "$(lane_launch "$OPEN_TERMINAL" launcher claude "$LNLANE" "$LNLANE" - "rc form bare")" \
  "rc=0 form=launcher bare=0" \
  "a lane whose launcher is on PATH launches through it by the absolute path the judge resolved, with no env prefix"
assert_eq "$(lane_launch "$OPEN_TERMINAL" bare claude "$LNBARE" "$LNBARE" - "rc form bare")" \
  "rc=0 form=prefix bare=0" \
  "a lane with no launcher on PATH keeps the env prefix"
assert_eq "$(lane_launch "$OPEN_TERMINAL" self claude "$LNSELF" "$LNSELF" - "rc form bare")" \
  "rc=0 form=prefix bare=0" \
  "a lane named for the harness itself keeps the env prefix: the harness binary picks its own default account"
assert_eq "$(lane_launch "$OPEN_TERMINAL" codex-launcher codex "$LNCODEX" "$LNCODEX" - "rc form bare")" \
  "rc=0 form=launcher bare=0" \
  "a codex lane whose launcher is on PATH launches through its absolute path, with no CODEX_HOME prefix"
assert_eq "$(lane_launch "$OPEN_TERMINAL" codex-self codex "$LNCODEXSELF" "$LNCODEXSELF" - "rc form bare")" \
  "rc=0 form=prefix bare=0" \
  "a codex lane named for the harness itself keeps the CODEX_HOME prefix"
assert_eq "$(lane_launch "$OPEN_TERMINAL" trailing claude "$LNLANE/" "$LNLANE" - "rc form bare")" \
  "rc=0 form=launcher bare=0" \
  "a lane path written with a trailing slash reaches the same launcher, the spelling --lane and ORCH_LANE_DIRS both carry through"

assert_eq "$(lane_launch "$TMP_ROOT/ctl-slash/scripts/open-terminal" mutant-slash claude "$LNLANE/" "$LNLANE" - "rc form bare")" \
  "rc=0 form=prefix bare=0" \
  "control: splitting the path on the last slash leaves a trailing-slash lane no name to judge, and it falls back to the prefix"
assert_eq "$(lane_launch "$TMP_ROOT/ctl-harness/scripts/open-terminal" mutant-harness claude "$LNSELF" "$LNSELF" - "rc form bare")" \
  "rc=0 form=launcher bare=0" \
  "control: without the harness-word rule a lane named for the harness launches through the bare harness"
assert_eq "$(lane_launch "$TMP_ROOT/ctl-launcher/scripts/open-terminal" mutant-launcher claude "$LNLANE" "$LNLANE" - "rc form bare")" \
  "rc=0 form=prefix bare=0" \
  "control: without the launcher arm the lane launches through the bare harness the shim would redirect"
assert_eq "$(lane_launch "$TMP_ROOT/ctl-abspath/scripts/open-terminal" mutant-abspath claude "$LNLANE" "$LNLANE" - "rc form bare")" \
  "rc=0 form=none bare=1" \
  "control: rendering the launcher's bare name leaves the pane shell to resolve it again against its own PATH"

echo "=== the pane is read back, and a disagreement closes the window ==="
# The check needs a readable per-process environment. Where the platform has
# none, lane_account_ok reports that by name and the launch stands, which these
# rows cannot tell apart from the pass they are pinning — so only they skip.
# The rows above still run there, which is the point of the split.
if [[ ! -r "/proc/$$/environ" ]]; then
  printf '  skip  pane-check rows (no readable per-process environment)\n'
else
  assert_eq "$(lane_launch "$OPEN_TERMINAL" ok-launcher claude "$LNLANE" "$LNLANE" - "rc verified mismatch closed")" \
    "rc=0 verified=1 mismatch=0 closed=0" \
    "the pane confirms the account under the launcher form"
  assert_eq "$(lane_launch "$OPEN_TERMINAL" ok-prefix claude "$LNBARE" "$LNBARE" - "rc verified mismatch closed")" \
    "rc=0 verified=1 mismatch=0 closed=0" \
    "the pane confirms the account under the env-prefix form"
  assert_eq "$(lane_launch "$OPEN_TERMINAL" wrong claude "$LNBARE" "$LNLANE" - "rc verified mismatch closed")" \
    "rc=1 verified=0 mismatch=1 closed=1" \
    "a pane observed running another account than the one picked is closed and the item fails"
  assert_eq "$(lane_launch "$OPEN_TERMINAL" late claude "$LNBARE" "$LNLANE" late "rc verified mismatch closed")" \
    "rc=1 verified=0 mismatch=1 closed=1" \
    "a wrapper that rewrites the account after the first read is still caught: an observation counts only once it settles"

  assert_eq "$(lane_launch "$TMP_ROOT/ctl-check/scripts/open-terminal" mutant-check claude "$LNBARE" "$LNLANE" - "rc verified mismatch closed")" \
    "rc=0 verified=0 mismatch=0 closed=0" \
    "control: without the account check a pane on the wrong account is reported as launched"
  assert_eq "$(lane_launch "$TMP_ROOT/ctl-settle/scripts/open-terminal" mutant-settle claude "$LNBARE" "$LNLANE" late "rc verified mismatch closed")" \
    "rc=0 verified=1 mismatch=0 closed=0" \
    "control: trusting the first read confirms an account the pane is about to stop running"
fi

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
