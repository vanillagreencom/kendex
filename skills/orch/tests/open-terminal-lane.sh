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
# The renewal's own settings, for the same reason: with one of these exported a
# developer runs a different suite from CI, where the expired-lane rows below
# stay expired, and a row could reach a live helper or the real token endpoint.
unset ORCH_LANES_CLAUDE_CLIENT_ID ORCH_LANES_TOKEN_CMD ORCH_LANES_CLAUDE_TOKEN_URL
# The caller's environment outranks project settings, so a pinned local host
# keeps an inherited or configured provider out of the local rows; hosted rows
# pass the stub themselves.
export ORCH_LANE_HOST=local
# The usage threshold is pinned per run (run_ot) rather than read from the
# checkout kendex.settings.toml, so the rows below assert what a launch
# actually does rather than the repository configuration.
unset ORCH_LANE_MAX_PCT
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
# The trust rows below read the config a codex launch would open. That reading
# is the launcher's own, so the suite sources it rather than scanning the file
# a second way and pinning what its own scanner happens to find.
# shellcheck source=../scripts/lib/toml.sh
source "$SCRIPTS_DIR/lib/toml.sh"
# lane_launch_home_account, for the rows that ask which ACCOUNT a launch
# landed on: a private home's path is a checksum a row cannot spell, and the
# launcher's own rule is what turns it back into the account.
# shellcheck source=../scripts/lib/lane-home.sh
source "$SCRIPTS_DIR/lib/lane-home.sh"
# mutate_file, the substitution half of the must-fail controls below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

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
if [[ "${1:-}" == "create" ]]; then
  # $OT_WT_FIXED pins the path for a row whose account config has to name the
  # launch directory before the launch reads it.
  if [[ -n "${OT_WT_FIXED:-}" ]]; then d="$OT_WT_FIXED"; mkdir -p "$d"
  else d="$(mktemp -d "$(dirname "$OT_WT_LOG")/wt.XXXXXX")"; fi
  git init -q "$d"
  printf '%s\n' "$d" >> "${OT_WT_PATH:-/dev/null}"
  printf '%s\n' "$d"
  exit 0
fi
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
  show-environment)
    # The tmux environment a new pane inherits, which is not the launcher's own.
    # tmux keeps TWO of them and the read names which: the SESSION scope without
    # -g, the GLOBAL scope with it, the latter being where the environment the
    # server was started with lands. A pane takes the session entry wherever it
    # has one. So this arm answers per scope, from a variable of that scope's
    # own, and a scope holding nothing fails the read the way the real tmux
    # reports an unknown variable. The value `-` is that scope's removal marker,
    # which tmux prints as a leading dash on the name and which hides the
    # variable from the pane.
    var="${!#}"
    if [[ "${2:-}" == -g ]]; then value="${OT_TMUX_ENV_GLOBAL_CODEX_HOME:-}"
    else value="${OT_TMUX_ENV_SESSION_CODEX_HOME:-}"; fi
    { [[ "$var" == CODEX_HOME ]] && [[ -n "$value" ]]; } || exit 1
    if [[ "$value" == - ]]; then printf -- '-%s\n' "$var"; else printf '%s=%s\n' "$var" "$value"; fi ;;
  display-message)
    if [[ "$*" == *pane_current_command* ]]; then echo ssh
    elif [[ "$*" == *pane_pid* ]]; then
      # The moment the account check starts: a row that holds its leaf back
      # until then puts the first read inside the window it is pinning.
      [[ -z "${OT_PANE_PID_TRIGGER:-}" ]] || : > "$OT_PANE_PID_TRIGGER"
      printf '%s\n' "${OT_PANE_PID:-0}"
    else echo 0; fi ;;
  capture-pane)
    # With a gate named, the pane shows nothing a launch check accepts until
    # that file exists: a row can then hold "launched" back until the wrapper
    # has handed the account over, which is the order the real thing has.
    if [[ -n "${OT_LAUNCHED_GATE:-}" && ! -e "$OT_LAUNCHED_GATE" ]]; then printf 'dev@lane:~$\n'
    else printf '%s\n' "${OT_PANE_TEXT:-dev@lane:~\$}"; fi ;;
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
# A git repository with no kendex settings of its own. A script copied outside
# every checkout resolves no PROJECT_ROOT, and `lane-host resolve` then runs
# from the working directory, which has to be a repository; this one carries no
# settings for that script to pick up on the way.
NOSETTINGS="$TMP_ROOT/nosettings"; mkdir -p "$NOSETTINGS"; git -C "$NOSETTINGS" init -q -b main

standard_home home

# A lane launch on a harness the flag table names names a model, and a reasoning
# effort where that harness has an effort flag, or open-terminal refuses it
# before any lane is judged; so every row below names both. CHOICE is
# the pair a row about something else passes: Opus, which every fixture in this
# suite measures with room, and an effort no gate here reads, so the row's
# outcome still turns on the one thing it is about. The rows that ARE about the
# pair spell their own, or pass none.
#
# Two spellings of the one pair, because the words go in the text the launch
# RUNS: CHOICE for a row that lets the launcher build the harness command, and
# CHOICE_CMD for a row whose launch carries its own `true` command, where
# --launch-flags would reach nothing and be refused.
CHOICE='flags=--model opus --effort high'
CHOICE_CMD='cmd=true --model opus --effort high'

# --- harness ---------------------------------------------------------------

# run_ot ENV ARGS... — runs open-terminal with the stubs, the standard home
# and a fresh claim store, tmux log, pane counter and worktree log under
# $RUN. ENV is a semicolon-separated list of `env` arguments that may override
# the defaults; an item `cwd=DIR` runs from DIR instead of the checkout,
# `max_pct=unset` drops the pinned launch threshold so `lanes` decides, and
# `prep=store_ro` or `prep=claims_file` stages this run's claim store as a
# read-only directory or as a plain file before the launch, `flags=S` passes S
# as one --launch-flags string and `cmd=S` passes S as one --cmd template. Those
# last two exist because a lane launch names both a model and an effort, which
# is two words, while a table row's args field is word-split; the env list is
# not. They are alternatives, never both: --launch-flags beside --cmd reach
# nothing and open-terminal refuses them, so a row whose launch runs its own
# command spells the pair inside that command. OUT is stdout and stderr
# together, the way a caller sees a launch.
RUN_SEQ=0
run_ot() {
  local env_list="$1" env_args=() flag_args=() items item cwd="$PWD" prep=""
  # The threshold is pinned per run so a row asserts what a launch does rather
  # than the checkout configuration. `max_pct=unset` drops the pin for the rows
  # that ask which number decides when the launcher forwards none.
  local pct_pin=(ORCH_LANE_MAX_PCT=95)
  shift
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$RUN"
  if [[ -n "$env_list" ]]; then
    IFS=';' read -ra items <<<"$env_list"
    for item in "${items[@]}"; do
      case "$item" in
        cwd=*) cwd="${item#cwd=}" ;;
        max_pct=*)
          [[ "${item#max_pct=}" == unset ]] \
            || { printf 'run_ot: max_pct takes only unset: %s\n' "$item" >&2; exit 1; }
          pct_pin=()
          ;;
        prep=*) prep="${item#prep=}" ;;
        flags=*) flag_args=(--launch-flags "${item#flags=}") ;;
        cmd=*) flag_args=(--cmd "${item#cmd=}") ;;
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
  # The provider's disk for this run: a hosted launch reads the lane's `.git`
  # there for the clone its marker belongs under, and writes the marker back.
  mkdir -p "$RUN/remote/srv/lane"
  printf 'gitdir: /srv/clone/.git/worktrees/lane\n' > "$RUN/remote/srv/lane/.git"
  # Every tmux wait is bounded by this, the premise wait ahead of the account
  # read included. These rows stub a pane that draws no harness screen, so each
  # such wait runs to its bound; one second keeps the suite honest and quick.
  OUT=$(cd "$cwd" && env LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
    LANE_HOST_STUB_DIR="$RUN/remote" \
    ORCH_TMUX_VERIFY_SECS=1 ${pct_pin[@]+"${pct_pin[@]}"} \
    TMUX=stub,1,0 OT_TMUX_LOG="$RUN/tmux.log" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$RUN/panes" \
    OT_WT_LOG="$RUN/worktree.log" OT_WT_PATH="$RUN/worktree.path" OVERSEE_WATCH_STATE_DIR="$RUN/state" ORCH_STATE_DIR="$RUN/state" LANE_HOST_STUB_LOG="$RUN/host.log" \
    PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
    ${env_args[@]+"${env_args[@]}"} "$OPEN_TERMINAL" ${flag_args[@]+"${flag_args[@]}"} "$@" 2>&1)
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

# launched_codex_home — the CODEX_HOME the launched command names, empty when
# the run launched none. The value is single-quoted inside the launch line the
# pane's shell reads, which is where the tmux stub logs it.
launched_codex_home() {
  sed -nE "s/.*env CODEX_HOME='([^']*)'.*/\\1/p" "$RUN/tmux.log" 2>/dev/null | sed -n 1p || true
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
#   walled        lane, model, pct and bucket of the lane-model-walled line, or none
#   unreadable    lane, model and step of the lane-model-unreadable line, or none
#   judgefailed   lane, model and exit of the lane-judge-failed line, or none
#   modelmissing  harness, lane and spellings of the launch-model-missing line,
#                 or none
#   effortmissing the same of the launch-effort-missing line, or none
#   flagsunreachable  every field of the launch-flags-unreachable line, commas
#                 for spaces, or none
#   credentialdead  lane and host of the host-credential-dead line, or none
#   relaunchgate  the host-relaunch-credential lines, which say the launch was
#                 not judged on this machine's copy of the account
#   unanswered    the host-accounts-unanswered lines, which say the provider
#                 failed the accounts verb and the launch kept the local gate
#   claimsnotice  the keyed lanes: pick-lane-claims notice lines, which say the
#                 claim store could not be read and the wall verdict stands
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
      walled)
        value="$(awk '$1 == "open-terminal:" && $2 == "lane-model-walled" { print $3, $4, $5, $6; exit }' <<<"$OUT" | tr ' ' ',')"
        value="${value:-none}"
        ;;
      unreadable)
        value="$(awk '$1 == "open-terminal:" && $2 == "lane-model-unreadable" { print $3, $4, $5; exit }' <<<"$OUT" | tr ' ' ',')"
        value="${value:-none}"
        ;;
      judgefailed)
        value="$(awk '$1 == "open-terminal:" && $2 == "lane-judge-failed" { print $3, $4, $5; exit }' <<<"$OUT" | tr ' ' ',')"
        value="${value:-none}"
        ;;
      modelmissing)
        value="$(awk '$1 == "open-terminal:" && $2 == "launch-model-missing" { print $3, $4, $5; exit }' <<<"$OUT" | tr ' ' ',')"
        value="${value:-none}"
        ;;
      effortmissing)
        value="$(awk '$1 == "open-terminal:" && $2 == "launch-effort-missing" { print $3, $4, $5; exit }' <<<"$OUT" | tr ' ' ',')"
        value="${value:-none}"
        ;;
      flagsunreachable)
        # Every field of the line, commas for spaces: the flags it names carry
        # spaces of their own and an expect string is word-split.
        value="$(sed -n 's/^open-terminal: launch-flags-unreachable //p' <<<"$OUT" | sed -n 1p | tr ' ' ',')"
        value="${value:-none}"
        ;;
      credentialdead)
        value="$(awk '$1 == "open-terminal:" && $2 == "host-credential-dead" { print $3, $4; exit }' <<<"$OUT" | tr ' ' ',')"
        value="${value:-none}"
        ;;
      relaunchgate) value="$(grep -c '^open-terminal: host-relaunch-credential ' <<<"$OUT" || true)" ;;
      unanswered) value="$(grep -c '^open-terminal: host-accounts-unanswered ' <<<"$OUT" || true)" ;;
      claimsnotice) value="$(grep -c '^lanes: pick-lane-claims claims=null$' <<<"$OUT" || true)" ;;
      # Which CODEX_HOME the launched command runs under, as a shape rather
      # than a path: `private` is a home of this launch's own under the
      # account, sitting under a directory named for the worktree path and its
      # checksum, so it is not a value a row can spell; its own leaf is the
      # fixed word `home`. Anything else is named relative to the home.
      cmd_home)
        local home
        home="$(launched_codex_home)"
        if [[ -z "$home" ]]; then value=none
        elif [[ "$home" == */lane-launch/*/home ]]; then value=private
        else value="${home#"$H/"}"; fi
        ;;
      # Which ACCOUNT that CODEX_HOME belongs to, named relative to the
      # fixture home. A private home sits under a directory named for the
      # worktree path and its checksum, so the account is taken back out of it
      # through the launcher's own rule rather than spelled here.
      cmd_account)
        local account
        account="$(launched_codex_home)"
        if [[ -z "$account" ]]; then value=none
        else value="$(lane_launch_home_account "$account")"; value="${value#"$H/"}"; fi
        ;;
      # The refusal the launcher reports when it could not make the entry. The
      # count is the assertion, not the catalog line in the source: a catalog
      # line survives a guard that stopped refusing.
      trustfail) value="$(grep -c '^open-terminal: launch-trust-missing ' <<<"$OUT" || true)" ;;
      # Which route made the directory trusted, as the launcher reports it
      # beside the launch. That line is the only place a reader learns which
      # config the session is running under: an account that already answered
      # for the directory, or a home this launch built for it.
      trust_route)
        local route
        route="$(sed -nE 's/^open-terminal: launch-trusted .*route=([^ ]*).*/\1/p' <<<"$OUT" | sed -n 1p)"
        value="${route:-none}"
        ;;
      # Does that home's config trust the directory the window opened in? That
      # is the question the harness answers before it reads its arguments, read
      # here through the launcher's own reader.
      home_trusts)
        local trust_home trust_wt
        trust_home="$(launched_codex_home)"
        trust_wt="$(sed -n '$p' "$RUN/worktree.path" 2>/dev/null || true)"
        if [[ -z "$trust_home" || -z "$trust_wt" ]]; then value=none
        elif [[ "$(toml_value "$trust_home/config.toml" "projects.\"$trust_wt\"" trust_level || true)" == trusted ]]; then value=yes
        else value=no; fi
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
  "no lane under the threshold: nothing launched, no worktree created|$CHOICE_CMD|--harness claude --lane auto --lane-max-pct 15 CC-1|rc=1 launched=nolog creates=nolog" \
  "an explicit --lane that is not a directory is refused|$CHOICE|--harness claude --lane /nonexistent/lane CC-1|rc=1 launched=nolog" \
  "an unknown --lane alias is refused|ORCH_LANE_ALIASES=eclaude=work;$CHOICE_CMD|--harness claude --lane nosuchlane CC-1|rc=1 launched=nolog" \
  "a retired lane named by its alias is refused before anything launches|ORCH_LANE_ALIASES=eclaude=work;ORCH_LANE_RETIRE=eclaude=2000-01-01;$CHOICE_CMD|--harness claude --lane work CC-1|rc=1 launched=nolog refused=lane=work" \
  "an excluded lane named by its config dir is refused before anything launches|ORCH_LANE_EXCLUDE=eclaude;$CHOICE_CMD|--harness claude --lane $H/.eclaude CC-1|rc=1 launched=nolog refused=lane=$H/.eclaude" \
  "an excluded lane's alias is refused even beside a same-named cwd directory|ORCH_LANE_ALIASES=eclaude=work;ORCH_LANE_EXCLUDE=eclaude;cwd=$COLLIDE;$CHOICE_CMD|--harness claude --lane work CC-1|rc=1 launched=nolog refused=lane=work" \
  "an excluded lane's alias with no same-named directory is refused, not unknown|ORCH_LANE_ALIASES=eclaude=work;ORCH_LANE_EXCLUDE=eclaude;cwd=$BARE;$CHOICE_CMD|--harness claude --lane work CC-1|rc=1 launched=nolog refused=lane=work" \
  "a named lane whose check fails on a malformed setting is a resolution failure, not a refusal|ORCH_LANES_USAGE_TTL=soon;$CHOICE_CMD|--harness claude --lane $H/.eclaude CC-1|rc=1 launched=nolog refused=none failed=exit=1" \
  "an ALIAS-spelled lane whose lookup fails on the same setting is that failure too, never an unknown alias|ORCH_LANE_ALIASES=eclaude=work;ORCH_LANES_USAGE_TTL=soon;$CHOICE_CMD|--harness claude --lane work CC-1|rc=1 launched=nolog refused=none failed=exit=1"

# The separator-bearing path cannot ride through a table row's word split.
run_ot "$CHOICE_CMD" --harness claude --lane "$TABBED" CC-21
assert_eq "$(observe "rc=1 launched=nolog")" "rc=1 launched=nolog" "a tab-bearing lane config dir is refused"

echo "=== a lane launch names a model and an effort, or nothing launches ==="
# A harness default is whatever that harness happens to ship this week, and the
# account the launch opens on is spent either way, so a lane, a model and an
# effort are one purposeful choice: a launch making only part of it is refused
# before any lane is judged, and is never judged on the account's binding bucket
# instead. One keyed refusal per missing half, so the key says which. Every
# harness the flag table names, a relaunch as much as a fresh launch.
#
# The spellings each row pins are the table's own, which is why a harness whose
# CLI spells the pair differently is one row there: codex takes `-m` and a
# `model_reasoning_effort=` config token, pi `--model` and `--thinking`, and
# opencode's launch form has no effort flag at all, so it asks the model alone.
table \
  "a launch naming a model and no effort is refused, naming the flag that harness takes|cmd=true --model opus|--harness claude --lane $H/.claude CC-81|rc=1 launched=nolog creates=nolog modelmissing=none effortmissing=harness=claude,lane=$H/.claude,spellings=--effort" \
  "a launch naming neither is refused for both, one keyed line each||--harness claude --lane $H/.claude --cmd true CC-82|rc=1 launched=nolog creates=nolog modelmissing=harness=claude,lane=$H/.claude,spellings=--model effortmissing=harness=claude,lane=$H/.claude,spellings=--effort" \
  "a pi launch naming neither is refused the same way, on pi's own spellings||--harness pi --lane $H/.claude --cmd true CC-83|rc=1 launched=nolog creates=nolog modelmissing=harness=pi,lane=$H/.claude,spellings=--model effortmissing=harness=pi,lane=$H/.claude,spellings=--thinking" \
  "a codex launch naming neither is refused on codex's config-token spelling of the effort||--harness codex --lane $H/.claude --cmd true CC-84|rc=1 launched=nolog creates=nolog modelmissing=harness=codex,lane=$H/.claude,spellings=-m,--model effortmissing=harness=codex,lane=$H/.claude,spellings=model_reasoning_effort=" \
  "a relaunch naming neither is refused too, the choice being the launch's and not the session's||--harness claude --relaunch --lane $H/.claude --cmd true CC-85|rc=1 launched=nolog modelmissing=harness=claude,lane=$H/.claude,spellings=--model" \
  "a launch naming both launches, which is what the usage gate below then judges|$CHOICE_CMD|--harness claude --lane $H/.claude CC-86|rc=0 launched=1 modelmissing=none effortmissing=none" \
  "opencode has no effort flag to name, so its launch asks the model alone|cmd=true --model anthropic/claude-opus-5|--harness opencode --lane $H/.claude CC-87|rc=0 launched=1 modelmissing=none effortmissing=none"

# The --cmd template carries the same two words for the same reason: a launch
# writing its own harness argv still made the choice, and a template a row
# cannot spell inside a word-split args field is passed through run_ot's argv.
run_ot "" --harness claude --lane "$H/.claude" --cmd "claude --model opus --effort high" CC-88
assert_eq "$(observe "rc=0 launched=1 modelmissing=none effortmissing=none")" \
  "rc=0 launched=1 modelmissing=none effortmissing=none" \
  "a model and an effort named only in the --cmd template are named"
run_ot "" --harness claude --lane "$H/.claude" --cmd "claude --model opus" CC-89
assert_eq "$(observe "rc=1 launched=nolog effortmissing=harness=claude,lane=$H/.claude,spellings=--effort")" \
  "rc=1 launched=nolog effortmissing=harness=claude,lane=$H/.claude,spellings=--effort" \
  "a --cmd template naming a model and no effort is refused for the effort"

# THE LANE SPEC NAMES THE HARNESS TOO. `--lane auto:<h>` resolves a real <h>
# account through `lanes pick --harness <h>`, so a launch that passed no
# --harness has still named the harness whose row judges its choice words, and
# that row judges it. Keyed on --harness alone the gate skipped exactly this
# shape: the launch was accepted with no model named and the lane started on
# whatever default the harness ships. Its control is ctl-lane-harness below.
#
# Only a launch naming a harness NOWHERE stays exempt — a named config dir or
# alias with no --harness — because nothing in that argv says which harness
# reads the words in the caller's own command.
table \
  "a launch naming its harness only in the lane spec is judged by that harness's row|cmd=true|--lane auto:claude CC-114|rc=1 launched=nolog creates=nolog modelmissing=harness=claude,lane=auto:claude,spellings=--model effortmissing=harness=claude,lane=auto:claude,spellings=--effort" \
  "the same launch naming both words inside its command launches|$CHOICE_CMD|--lane auto:claude CC-115|rc=0 launched=1 modelmissing=none effortmissing=none" \
  "a named lane with no --harness names no harness anywhere, and is the one shape left exempt|cmd=true|--lane $H/.claude CC-116|rc=0 launched=1 modelmissing=none effortmissing=none"

# --launch-flags beside a --cmd template reach NOTHING: start_cmd renders the
# template verbatim and appends no flag to it. Left ungated, the choice words
# there would be read, judged and recorded while the harness ran its own
# default. The refusal is the launch's, not the lane's, so it lands on a launch
# with no --lane too, and the model or effort the flags name is never read.
run_ot "flags=--model opus --effort high" --harness claude --lane "$H/.claude" --cmd true CC-99
assert_eq "$(observe "rc=1 launched=nolog creates=nolog flagsunreachable=option=--launch-flags,flags=--model,opus,--effort,high modelmissing=none effortmissing=none")" \
  "rc=1 launched=nolog creates=nolog flagsunreachable=option=--launch-flags,flags=--model,opus,--effort,high modelmissing=none effortmissing=none" \
  "launch flags beside a --cmd template refuse the launch, naming the flags that reach nothing"
run_ot "flags=--model opus --effort high" --cmd true CC-112
assert_eq "$(observe "rc=1 launched=nolog flagsunreachable=option=--launch-flags,flags=--model,opus,--effort,high")" \
  "rc=1 launched=nolog flagsunreachable=option=--launch-flags,flags=--model,opus,--effort,high" \
  "a wholly custom launch with no harness and no lane is refused for the same unreachable flags"

# pi spells the thinking level on the model value too, `--model sonnet:high`,
# which its own --help documents. A launch passing that has made both choices, so
# asking it for a --thinking it already named would refuse a launch that named
# everything. The table row's fourth field carries the separator, `-` for the
# harness that has none, so this is one row rule and not a branch per harness:
# the claude rows above pass `opus` with no level and are still asked for
# --effort. A separator with nothing after it names no level.
#
# The last row is the inverse: an arbitrary value carrying the same character on
# a harness whose row names no separator is a model value and nothing more.
table \
  "pi's level on the model value names the effort, so the launch is not asked for it again|cmd=true --model sonnet:high|--harness pi --lane $H/.claude CC-95|rc=0 launched=1 modelmissing=none effortmissing=none" \
  "a separator with no level after it names no effort, so that launch is still refused|cmd=true --model sonnet:|--harness pi --lane $H/.claude CC-97|rc=1 launched=nolog modelmissing=none effortmissing=harness=pi,lane=$H/.claude,spellings=--thinking" \
  "a claude launch whose model value carries a colon is still asked for its effort, its row naming no separator|cmd=true --model opus:1m|--harness claude --lane $H/.claude CC-98|rc=1 launched=nolog modelmissing=none effortmissing=harness=claude,lane=$H/.claude,spellings=--effort"
# The same value inside a --cmd template, which a word-split args field cannot
# spell.
run_ot "" --harness pi --lane "$H/.claude" --cmd "pi --model sonnet:high" CC-96
assert_eq "$(observe "rc=0 launched=1 modelmissing=none effortmissing=none")" \
  "rc=0 launched=1 modelmissing=none effortmissing=none" \
  "pi's level named on the model value inside the --cmd template names the effort too"

echo "=== a launch is refused when the model it passes has no window left ==="
# An account with plan-wide weekly room can still have none left for ONE model.
# The binding bucket never shows it, so a --wake or --relaunch onto a named
# account opens its first turn on a usage banner instead of the session it
# resumed. The model comes from the text the launch RUNS: the --cmd command
# where there is one, --launch-flags where there is not, so the wall judged is
# always the wall of the model the harness will really be started on.
# The refusal sits in lane resolution, ahead of the branch that tells a wake
# from a relaunch from a plain launch, so every launch mode meets the same
# clause and the relaunch row below is the shaped input for all of them.
claude_usage 10 20 95 'Fable 5.1' > "$FIXTURE_DIR/.claude.json"
table \
  "a named lane whose window for this model is walled is refused before anything launches|cmd=true --model=fable --effort=high|--harness claude --lane $H/.claude CC-60|rc=1 launched=nolog creates=nolog walled=lane=$H/.claude,model=fable,pct=95,bucket=model" \
  "a relaunch onto that same lane is refused the same way|cmd=true --model=fable --effort=high|--harness claude --relaunch --lane $H/.claude CC-61|rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=95,bucket=model" \
  "the same lane launches for a model whose own window has room|$CHOICE_CMD|--harness claude --lane $H/.claude CC-62|rc=0 launched=1 walled=none" \
  "--lane auto takes the account with the most room for the model being passed|$CHOICE_CMD|--harness claude --lane auto CC-64|rc=0 cmd_lane=claude walled=none" \
  "--lane auto moves off the account whose window for that model is walled|cmd=true --model=fable --effort=high|--harness claude --lane auto CC-65|rc=0 cmd_lane=eclaude walled=none"

# A model can be spelled three ways and the gate reads all three. The rows above
# spell `--model=X`; these spell `--model X` and codex's `-m X`, so deleting the
# arm that takes the value from the NEXT token reddens a row instead of silently
# unguarding every space-form and codex launch.
run_ot "cmd=true --model fable --effort high" --harness claude --lane "$H/.claude" CC-67
assert_eq "$(observe "rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=95,bucket=model")" \
  "rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=95,bucket=model" \
  "the space-spelled --model in the launch command gates the lane too"

# A launch that carries its own harness argv is gated on the model INSIDE that
# argv, which is the model it will really run: the template is read rather than
# waved through, and the same wall is judged as for a launch whose command this
# launcher builds. The second row is the inverse, a model with room in the same
# template still launching.
run_ot "" --harness claude --lane "$H/.claude" --cmd "claude --model fable --effort high" CC-75
assert_eq "$(observe "rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=95,bucket=model")" \
  "rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=95,bucket=model" \
  "a model named inside the --cmd command gates the lane on that model's wall"
# cmd_home beside the launch: a claude lane names no CODEX_HOME and builds no
# home of its own, since the folder-trust record that harness reads is not this
# file at all.
run_ot "" --harness claude --lane "$H/.claude" --cmd "claude --model opus --effort high" CC-76
assert_eq "$(observe "rc=0 launched=1 walled=none cmd_home=none trust_route=none")" \
  "rc=0 launched=1 walled=none cmd_home=none trust_route=none" \
  "a --cmd naming a model with room still launches, under no CODEX_HOME and no trust route"

make_codex_lane "$H/.codex"
jq -n '{rate_limit: {primary_window: {used_percent: 95, reset_at: 1785000000,
                                      limit_window_seconds: 18000}}}' > "$FIXTURE_DIR/.codex.json"
run_ot "cmd=true -m fable -c model_reasoning_effort=high" --harness codex --lane "$H/.codex" CC-68
assert_eq "$(observe "rc=1 launched=nolog walled=lane=$H/.codex,model=fable,pct=95,bucket=session")" \
  "rc=1 launched=nolog walled=lane=$H/.codex,model=fable,pct=95,bucket=session" \
  "codex spells the model -m, and that launch is gated on the same wall"

# A Codex session started into a directory its config does not trust stops on
# the folder-trust question and waits there, and a lane launch has nobody at
# the pane to answer it. The entry is made before the window opens, in a
# CODEX_HOME of the launch's own under the account, because the account's own
# config.toml is a link its shim repoints at every launch. The preparation
# itself is lane-launch-trust.sh; these rows are the wiring, and what the
# launched command ends up running under.
make_codex_lane "$H/.tcodex"
jq -n '{rate_limit: {primary_window: {used_percent: 5, reset_at: 1785000000,
                                      limit_window_seconds: 18000}}}' > "$FIXTURE_DIR/.tcodex.json"
run_ot "cmd=true -m gpt-5 -c model_reasoning_effort=high" --harness codex --lane "$H/.tcodex" CC-1632
assert_eq "$(observe "rc=0 launched=1 cmd_home=private home_trusts=yes trust_route=launch-home")" \
  "rc=0 launched=1 cmd_home=private home_trusts=yes trust_route=launch-home" \
  "a codex launch runs under a home whose config trusts the worktree it opens in, and names that route"
# A codex launch with NO --lane opens into the same untrusted worktree and is
# prepared the same way: folder trust belongs to the directory, not to the
# account a launch was aimed at, and the command shape handoff.md section 2
# documents passes no --lane at all.
#
# WHICH account such a launch lands on is the one the pane would have opened on
# by itself. Under tmux that is the tmux SERVER's environment, and CODEX_HOME is
# not on tmux's default update-environment list, so a value set in the
# launcher's own environment never reaches the pane. An orch agent running
# inside a codex lane launches handoff items this way, and reading its own
# variable would move every one of them onto its own account, with no claim
# taken on it and the account check skipped.
#
# ENV|ITEM|ACCOUNT|WHAT, one row per place the value can sit. No HOME is
# pinned: the default account is derived from LANES_HOME like every other
# reader's, so a row that had to set HOME would be saying the derivation is
# somewhere else.
#
# WHICH tmux scope holds it is the second half of that question. tmux keeps a
# session environment beside a global one and a pane takes the session entry
# wherever it has one; the environment the SERVER was started with lands in the
# GLOBAL scope alone, and nothing here writes a session entry, so on a fleet
# host the account a pane inherits is the global one. A read without -g answers
# `unknown variable` there and sends the launch to the harness default instead.
for row in \
  "|CC-1634|.codex|the default account under LANES_HOME" \
  "CODEX_HOME=$H/.tcodex;|CC-1636|.codex|the launcher's own CODEX_HOME, which no pane inherits" \
  "OT_TMUX_ENV_GLOBAL_CODEX_HOME=$H/.tcodex;|CC-1637|.tcodex|the tmux GLOBAL scope, where a server's own environment lands" \
  "OT_TMUX_ENV_SESSION_CODEX_HOME=$H/.tcodex;|CC-1638|.tcodex|the tmux SESSION scope, which a set-environment writes" \
  "OT_TMUX_ENV_SESSION_CODEX_HOME=$H/.tcodex;OT_TMUX_ENV_GLOBAL_CODEX_HOME=$H/.codex;|CC-1639|.tcodex|a session entry, which the pane takes over the global one" \
  "OT_TMUX_ENV_SESSION_CODEX_HOME=-;OT_TMUX_ENV_GLOBAL_CODEX_HOME=$H/.tcodex;|CC-1640|.codex|a session removal marker, which hides the global value from the pane" \
  ; do
  extra="${row%%|*}"; rest="${row#*|}"
  item="${rest%%|*}"; rest="${rest#*|}"
  account="${rest%%|*}"; what="${rest#*|}"
  want="rc=0 launched=1 cmd_home=private cmd_account=$account home_trusts=yes trust_route=launch-home"
  run_ot "${extra}cmd=true -m gpt-5 -c model_reasoning_effort=high" --harness codex "$item"
  assert_eq "$(observe "$want")" "$want" \
    "a codex launch with no --lane is prepared under $what"
done

# Control: the walk asks the session scope alone, which is what reading without
# -g amounted to. The global entry is then unreachable and the launch falls to
# the harness default — the account every no-lane launch on a fleet host was
# landing on while the operator's numbered account sat in the scope nobody read.
GLOBAL_ROOT="$TMP_ROOT/mutant-global-scope/orch"
mkdir -p "$GLOBAL_ROOT/scripts"
cp -R "$SCRIPTS_DIR/." "$GLOBAL_ROOT/scripts/"
orch_fixture_shared_libs "$GLOBAL_ROOT"
mutate_file "$GLOBAL_ROOT/scripts/open-terminal" \
  'for scope in session global; do' 'for scope in session; do'
OPEN_TERMINAL_REAL="$OPEN_TERMINAL"
OPEN_TERMINAL="$GLOBAL_ROOT/scripts/open-terminal"
run_ot "OT_TMUX_ENV_GLOBAL_CODEX_HOME=$H/.tcodex;cmd=true -m gpt-5 -c model_reasoning_effort=high" \
  --harness codex CC-1641
assert_eq "$(observe "rc=0 launched=1 cmd_account=.codex")" "rc=0 launched=1 cmd_account=.codex" \
  "control: a walk that never asks the global scope spends the default account, not the server's"
OPEN_TERMINAL="$OPEN_TERMINAL_REAL"

# An account whose config exists and cannot be read refuses the item: the
# launch would otherwise start with every table the account was approved for
# gone. Nothing opens, and the batch exits on the failed count. The config is
# replaced with a dangling link, which is the shape a numbered account's shim
# leaves behind when the render it points at is not there.
DANGLING_LANE="$H/.dcodex"
make_codex_lane "$DANGLING_LANE"
jq -n '{rate_limit: {primary_window: {used_percent: 5, reset_at: 1785000000,
                                      limit_window_seconds: 18000}}}' > "$FIXTURE_DIR/.dcodex.json"
ln -sfn "$H/no-such-render.toml" "${DANGLING_LANE:?}/config.toml"
run_ot "cmd=true -m gpt-5 -c model_reasoning_effort=high" --harness codex --lane "$DANGLING_LANE" CC-1635
assert_eq "$(observe "rc=1 launched=nolog trustfail=1")" "rc=1 launched=nolog trustfail=1" \
  "an account config that cannot be read refuses the item and opens no window"

# The account answering for the worktree already is the other route: nothing is
# built and the launch runs under the account directory itself. The worktree is
# pinned for this row, since a config can only name a directory that exists
# before the launch reads it.
TRUSTED_WT="$TMP_ROOT/trusted-wt"
printf '[projects."%s"]\ntrust_level = "trusted"\n' "$TRUSTED_WT" > "$H/.tcodex/config.toml"
run_ot "OT_WT_FIXED=$TRUSTED_WT;cmd=true -m gpt-5 -c model_reasoning_effort=high" \
  --harness codex --lane "$H/.tcodex" CC-1633
assert_eq "$(observe "rc=0 launched=1 cmd_home=.tcodex home_trusts=yes trust_route=preapproved")" \
  "rc=0 launched=1 cmd_home=.tcodex home_trusts=yes trust_route=preapproved" \
  "an account config that already trusts the worktree launches on the account itself, under the other route"

# The model-scoped window has room, but the shared 5-hour window walls every
# model on the account. The launcher reports that shared bucket as the cause.
claude_usage 85 20 10 'Fable 5.1' > "$FIXTURE_DIR/.claude.json"
run_ot "ORCH_LANE_MAX_PCT=80;cmd=true --model fable --effort high" --harness claude --lane "$H/.claude" CC-118
assert_eq "$(observe "rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=85,bucket=session")" \
  "rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=85,bucket=session" \
  "a shared 5-hour wall refuses a launch whose model-scoped bucket has room"

# Control: keep the refusal and its diagnostic, but make the launcher replace
# the deciding bucket with the model spelling. The assertion above distinguishes
# that result from the shared session bucket the judge returned.
BUCKET_ROOT="$TMP_ROOT/mutant-launch-bucket/orch"
mkdir -p "$BUCKET_ROOT/scripts"
cp -R "$SCRIPTS_DIR/." "$BUCKET_ROOT/scripts/"
orch_fixture_shared_libs "$BUCKET_ROOT"
mutate_file "$BUCKET_ROOT/scripts/open-terminal" \
  '"bucket=$lane_bucket"' '"bucket=model"'
OPEN_TERMINAL_REAL="$OPEN_TERMINAL"
OPEN_TERMINAL="$BUCKET_ROOT/scripts/open-terminal"
run_ot "ORCH_LANE_MAX_PCT=80;cmd=true --model fable --effort high" --harness claude --lane "$H/.claude" CC-119
assert_eq "$(observe "rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=85,bucket=model")" \
  "rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=85,bucket=model" \
  "control: a launcher that replaces the deciding bucket reports the wrong model bucket"
OPEN_TERMINAL="$OPEN_TERMINAL_REAL"
claude_usage 10 20 95 'Fable 5.1' > "$FIXTURE_DIR/.claude.json"

# A lane the inventory HAS but whose windows answer nothing for this model is
# a lane nobody measured, not a lane that is full: the key says so. Telling an
# operator the allowance is gone would send them to wait for a reset that is
# not coming.
make_lane "$H" uclaude 3600
jq -n '{limits: [{kind: "weekly_scoped", percent: 10, resets_at: "2026-08-01T06:00:00Z",
                  scope: {model: {display_name: "Opus"}}}]}' > "$FIXTURE_DIR/.uclaude.json"
run_ot "cmd=true --model sonnet --effort high" --harness claude --lane "$H/.uclaude" CC-69
assert_eq "$(observe "rc=1 launched=nolog unreadable=lane=$H/.uclaude,model=sonnet,step=windows walled=none")" \
  "rc=1 launched=nolog unreadable=lane=$H/.uclaude,model=sonnet,step=windows walled=none" \
  "a lane whose windows name no such model is unreadable, never reported as full"

# A lane whose usage could not be fetched at all is the same answer for the same
# reason: nobody read a window, so nobody may say the allowance is gone. The
# openclaude dir is discovered as a lane and has no credentials to measure.
run_ot "cmd=true --model fable --effort high" --harness claude --lane "$H/.openclaude" CC-73
assert_eq "$(observe "rc=1 launched=nolog unreadable=lane=$H/.openclaude,model=fable,step=windows walled=none")" \
  "rc=1 launched=nolog unreadable=lane=$H/.openclaude,model=fable,step=windows walled=none" \
  "a lane whose usage could not be read is unreadable, never reported as full"

# A config dir no lane record covers is judged by nothing, because there is
# nothing to judge it by and there never was. --help says such a dir is used as
# given, and this gate does not take that away.
OUTSIDE_LANE="$TMP_ROOT/outside-any-lane"
mkdir -p "$OUTSIDE_LANE"
run_ot "cmd=true --model fable --effort high" --harness claude --lane "$OUTSIDE_LANE" CC-70
assert_eq "$(observe "rc=0 launched=1 walled=none unreadable=none")" \
  "rc=0 launched=1 walled=none unreadable=none" \
  "a config dir outside every lane record launches, the gate holding no record to judge it by"

# The threshold is forwarded, never evaluated here: a value this script once
# fed to bash arithmetic is now refused by the one parser that owns it, and the
# launch stops rather than proceeding on a comparison that errored.
run_ot "cmd=true --model fable --effort high" --harness claude --lane "$H/.claude" --lane-max-pct '90%' CC-71
assert_eq "$(observe "rc=1 launched=nolog judgefailed=lane=$H/.claude,model=fable,exit=1 unreadable=none")" \
  "rc=1 launched=nolog judgefailed=lane=$H/.claude,model=fable,exit=1 unreadable=none" \
  "a malformed --lane-max-pct on a named lane refuses the launch, named as the judge failing and not as an unread window"

# A claims path that is not a directory does NOT refuse the named lane: this
# gate asks for a wall, which no claim count enters, so the store is reported as
# a notice on stderr and the window opens. The claim write fails too and is not
# fatal either, which is the policy this gate now matches.
run_ot "prep=claims_file;$CHOICE_CMD" --harness claude --lane "$H/.claude" CC-74
assert_eq "$(observe "rc=0 launched=1 claimsnotice=1 walled=none judgefailed=none")" \
  "rc=0 launched=1 claimsnotice=1 walled=none judgefailed=none" \
  "an unreadable claim store notices and launches the named lane rather than refusing it"

rm -rf -- "${H:?}/.uclaude" "${FIXTURE_DIR:?}/.uclaude.json"

# The shared home is neutral again for the rows below; the control row further
# down stages this fixture once more for itself.
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"

echo "=== a bare --lane word is an alias first, then a directory ==="
# The alias owns the bare word: a cwd directory with the same name would
# otherwise win and launch under a config dir nobody configured, silently. A
# word no alias claims still resolves as a directory.
table \
  "a cwd directory does not shadow the alias it collides with|ORCH_LANE_ALIASES=eclaude=work;cwd=$COLLIDE;$CHOICE_CMD|--harness claude --lane work CC-1|rc=0 out_lanes=eclaude" \
  "a bare word no alias claims falls back to the directory|ORCH_LANE_ALIASES=eclaude=work;cwd=$BARE;$CHOICE_CMD|--harness claude --lane somelane CC-1|rc=0 out_lanes=somelane"

echo "=== a tmux launch under a lane runs under it and records its claim ==="
# The launched command carries the lane as a single-quoted env prefix; the
# claim names the lane's config dir, the window, and the pane id that keeps
# it prunable; a launch with no lane has no account to claim; a GUI
# launch has no pane to keep a claim alive, so a GUI batch records nothing
# and stays on the lane resolved up front.
table \
  "--lane <alias> launches under that lane's env prefix and records one claim naming lane, window and pane|ORCH_LANE_ALIASES=eclaude=work;$CHOICE_CMD|--harness claude --lane work CC-2|rc=0 cmd_lane=eclaude claims=1 claim_lanes=eclaude claim_window=CC-2 claim_pane=%1" \
  'a launch with no --lane still opens its window and records no claim||--harness claude --cmd true CC-3|launched=1 claims=nolog' \
  "a GUI batch launches, records no claim, and reports the one lane it resolved|TERMINAL=ghostty;$CHOICE_CMD|--ghostty --harness claude --lane auto CC-10 CC-11|rc=0 claims=nolog summary=lane=claude"

echo "=== --lane auto over a batch re-picks off every claimed lane ==="
# Each recorded claim moves the next item off that lane; a window created and
# then failed still holds its account (the trigger is an attempted item); the
# summary counts distinct lanes. A claim that could not be written, a claims
# path that is not a directory, a re-picked lane carrying the separator, or a
# re-pick that cannot place its item stops the batch instead of launching the
# next item blind; an item another session owns never carried a session and
# is not a lane the batch ran on.
table \
  "a two-item batch spreads across two accounts, most headroom first|$CHOICE_CMD| --harness claude --lane auto CC-4 CC-5|rc=0 launched=2 claim_lanes=claude,eclaude out_lanes=claude,eclaude summary=spread=2" \
  "a claimed window whose launch failed still moves the next item off that lane|OT_TMUX_FAIL=send-keys;$CHOICE_CMD|--harness claude --lane auto CC-8 CC-9|launched=2 claim_lanes=claude,eclaude out_lanes=claude,eclaude" \
  "a third item returning to a used lane still reports two distinct lanes|$CHOICE_CMD|--harness claude --lane auto CC-12 CC-13 CC-14|launched=3 summary=spread=2" \
  "a re-picked lane carrying a separator stops the batch after the first launch|LANES_HOME=$TABHOME;FIXTURE_DIR=$TABFIX;$CHOICE_CMD|--harness claude --lane auto CC-22 CC-23|rc=1 launched=1 claims=1" \
  "a re-pick that cannot place its item stops the batch after the first launch|ORCH_LANES_FETCH_CMD=$TMP_ROOT/fetch-flaky;FLAKY_COUNT=$TMP_ROOT/flaky-count;FLAKY_OK=3;ORCH_LANES_USAGE_TTL=0;$CHOICE_CMD|--harness claude --lane auto CC-6 CC-7|rc=1 launched=1 claims=1" \
  "a lane picked for an item another session owns is not one the batch ran on|WORKTREE_CLI=$OWNED_STUB;OWNED_COUNT=$TMP_ROOT/owned-count;OWNED_ROOT=$TMP_ROOT;$CHOICE_CMD|--harness claude --lane auto CC-17 CC-18|launched=1 summary=lane=claude"

# A claims path that is not a directory is a misconfiguration, not an empty
# store: the pick refuses before anything launches.
table \
  "a non-directory claims path refuses the launch|prep=claims_file;$CHOICE_CMD|--harness claude --lane auto CC-19|rc=1 launched=nolog"

# Root writes into a mode-555 directory, so the row cannot fail a write there.
if [[ "$(id -u)" -eq 0 ]]; then
  printf '  skip  unwritable claim store (running as root)\n'
else
  table \
    "a claim that could not be recorded stops the batch after the launch that stands|prep=store_ro;$CHOICE_CMD|--harness claude --lane auto CC-15 CC-16|rc=1 launched=1"
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
# Every provider call the run made, in order: one `,`-joined verb and argument
# list per call, the calls themselves joined with `;`. A row that asserts this
# asserts the whole call sequence, so a call the launcher adds cannot pass
# unnoticed.
host_call() { [[ -f "$RUN/host.log" ]] || { echo nolog; return; }; sed -E -e 's/ +$//' -e "s#$H/\\.##g" -e 's/ /,/g' "$RUN/host.log" | paste -sd';' -; }
typed() { grep -cF -- "$1" "$RUN/tmux.log" 2>/dev/null || true; }
said() { grep -cxF -- "$1" <<<"$OUT" || true; }

run_ot "ORCH_LANE_HOST=$HOST_STUB;ORCH_LANE_ALIASES=eclaude=work;$CHOICE_CMD" --harness claude --lane work --repo o/r CC-40
assert_eq "$(observe "rc=0 creates=nolog launched=1 claim_lanes=eclaude") calls=$(host_call) ssh=$(typed "clear; ssh 'lane.example'") remote=$(typed "exec bash -lc 'cd /srv/lane && exec true --model opus --effort high'") env=$(typed CLAUDE_CONFIG_DIR=) opened=$(said "open-terminal: tmux-opened item=CC-40 host=$HOST_STUB path=/srv/lane")" \
  "rc=0 creates=nolog launched=1 claim_lanes=eclaude calls=create,--item,CC-40,--repo,o/r,--harness,claude,--account,eclaude;cat,--item,CC-40,/srv/lane/.git;put,--item,CC-40,/srv/clone/.git/lane-mail/cc-40;cat,--item,CC-40,/srv/clone/.git/lane-mail/cc-40 ssh=1 remote=1 env=0 opened=1" \
  "a hosted launch creates through lane-host, types ssh then the remote line, and renders no lane env prefix"
# A hosted relaunch continues natively. Q is how single_quote renders one quote
# of the continuation line inside the remote command.
#
# One row per harness, one asserted remote command each. The codex row pins an
# absence, because `codex resume` declares its prompt as conflicting with
# --last: a rendered `codex resume --last <line>` would hand codex a sentence
# as a session name. The assertion named "a hosted codex relaunch resumes
# promptless, so no sentence is rendered into the session-id slot" is what
# reddens if that line comes back.
# Write it as ${Q} wherever a letter, digit or underscore follows: `$Qopus` is
# the variable Qopus, which under `set -u` empties the whole substitution the
# expectation was built in and leaves the row comparing against nothing.
Q="'\\''"
hosted_line() { printf 'Resume the orch workflow for %s from where this session stopped. Run .agents/skills/orch/scripts/lane-mail inbox --item %s first and act on every directive it prints.' "$1" "$1"; }
HOSTED_LINE="$(hosted_line CC-41)"
run_ot "$CHOICE" --host "$HOST_STUB" --harness claude --lane auto --repo o/r --relaunch CC-41
assert_eq "$(observe "rc=0 creates=nolog launched=1") calls=$(host_call) remote=$(typed "exec bash -lc 'cd /srv/lane && exec claude $Q--model$Q ${Q}opus$Q $Q--effort$Q ${Q}high$Q --continue $Q$HOSTED_LINE$Q'")" \
  "rc=0 creates=nolog launched=1 calls=create,--item,CC-41,--repo,o/r,--harness,claude,--account,claude,--relaunch;cat,--item,CC-41,/srv/lane/.git;put,--item,CC-41,/srv/clone/.git/lane-mail/cc-41;cat,--item,CC-41,/srv/clone/.git/lane-mail/cc-41 remote=1" \
  "a hosted claude relaunch passes the picked account and --relaunch, and continues natively with the continuation line"
HOSTED_LINE="$(hosted_line CC-48)"
run_ot "ORCH_LANE_ALIASES=eclaude=work;flags=--model opus --thinking high" --host "$HOST_STUB" --harness pi --lane work --repo o/r --relaunch CC-48
assert_eq "$(observe "rc=0 creates=nolog launched=1") remote=$(typed "exec bash -lc 'cd /srv/lane && exec pi $Q--model$Q ${Q}opus$Q $Q--thinking$Q ${Q}high$Q -c $Q$HOSTED_LINE$Q'")" \
  "rc=0 creates=nolog launched=1 remote=1" \
  "a hosted pi relaunch continues natively with the continuation line"
run_ot "ORCH_LANE_ALIASES=eclaude=work;flags=-m gpt-6-astra -c model_reasoning_effort=high" --host "$HOST_STUB" --harness codex --lane work --repo o/r --relaunch CC-49
assert_eq "$(observe "rc=0 creates=nolog launched=1") remote=$(typed "exec bash -lc 'cd /srv/lane && exec codex $Q-m$Q ${Q}gpt-6-astra$Q $Q-c$Q ${Q}model_reasoning_effort=high$Q resume --last'") line=$(typed "Resume the orch workflow for CC-49")" \
  "rc=0 creates=nolog launched=1 remote=1 line=0" \
  "a hosted codex relaunch resumes promptless, so no sentence is rendered into the session-id slot"
# The lane comes up idle, so the launcher owes the operator a record saying the
# line is still to be pasted; without one the summary reports the item as
# launched and nothing distinguishes it from a lane that got its instruction.
# The assertion named "the promptless resume is recorded as owing its
# continuation line" is what reddens if the record goes away.
assert_eq "$(said "open-terminal: resume-lineless item=CC-49 harness=codex")" "1" \
  "the promptless resume is recorded as owing its continuation line"
# Parse-level control for the row above, run against the real codex parser.
# One positional is appended to whatever open-terminal rendered, and the
# assertion named "a positional appended to the rendering is still parsed as a
# session id" is what reddens: a promptless rendering leaves the session-id
# slot free, so the appended value fills it and codex parses (exit 1, stdin is
# not a terminal); a rendering that already carried the line makes the appended
# value a second positional, which is the PROMPT that --last is declared to
# conflict with, and clap exits 2 before anything runs. --help is deliberately
# NOT used here: it short-circuits clap ahead of conflict checking, so every
# form exits 0 and the probe would answer the same for the rendering and for
# the defect.
if command -v codex >/dev/null 2>&1; then
  # The pane log holds the command as it was TYPED, so every quote start_cmd put
  # round a flag token reads as the `bash -lc` escape; the second sed undoes that
  # escape, which is what the remote shell does before codex sees its argv.
  RENDERED="$(sed -n "s/.*exec bash -lc 'cd \/srv\/lane \&\& exec \(codex .*\)'.*/\1/p" "$RUN/tmux.log" \
    | tail -1 | sed "s/'\\\\''/'/g")"
  assert_eq "${RENDERED:-MISSING}" "codex '-m' 'gpt-6-astra' '-c' 'model_reasoning_effort=high' resume --last" \
    "the rendered remote command is recovered from the pane log"
  CODEX_PARSE_RC=0
  CODEX_HOME="$TMP_ROOT/codex-parse-home" timeout 20 bash -c "$RENDERED zz-appended-session" </dev/null >/dev/null 2>&1 || CODEX_PARSE_RC=$?
  assert_eq "$CODEX_PARSE_RC" "1" "a positional appended to the rendering is still parsed as a session id"
  CODEX_REFUSE_RC=0
  CODEX_HOME="$TMP_ROOT/codex-parse-home" timeout 20 codex resume --last 'a continuation line' zz-appended-session </dev/null >/dev/null 2>&1 || CODEX_REFUSE_RC=$?
  assert_eq "$CODEX_REFUSE_RC" "2" "control: the same append onto a rendering carrying the line is the parse error the assertion above would catch"
else
  echo "  skip  codex is not installed; the parse-level control did not run"
fi
# A GitHub-tracker item is the issue number while its worktree id is issue-<n>,
# and the lane's mailbox is bound under the worktree id: write_lane_marker
# writes it there and the overseer's `lane-mail send --item` writes the same
# id. A line built from the bare number would send the lane to an empty mailbox
# and lose every queued answer, directive and halt. The hosted arm renders the
# line with no transcript lookup, so it is where the two ids are visibly
# distinct, and the assertion below is what reddens if the bare number returns.
HOSTED_LINE="$(hosted_line issue-2708)"
run_ot "ORCH_LANE_ALIASES=eclaude=work;$CHOICE" --host "$HOST_STUB" --tracker github --harness claude --lane work --repo o/r --relaunch 2708
assert_eq "$(observe "rc=0 creates=nolog launched=1") calls=$(host_call) remote=$(typed "exec bash -lc 'cd /srv/lane && exec claude $Q--model$Q ${Q}opus$Q $Q--effort$Q ${Q}high$Q --continue $Q$HOSTED_LINE$Q'")" \
  "rc=0 creates=nolog launched=1 calls=create,--item,issue-2708,--repo,o/r,--harness,claude,--account,eclaude,--relaunch;cat,--item,issue-2708,/srv/lane/.git;put,--item,issue-2708,/srv/clone/.git/lane-mail/issue-2708;cat,--item,issue-2708,/srv/clone/.git/lane-mail/issue-2708 remote=1" \
  "a GitHub relaunch names the worktree id its mailbox is bound under, never the bare issue number, and asks the provider nothing on an account that measured"

# WHICH CREDENTIAL A HOSTED LAUNCH RUNS ON. The host runs the copy the provider
# put there, which is independent of this machine's copy only where the provider
# installs a secret of its own; a provider that re-seeds the host from the
# account's config dir at every create runs this machine's copy, on a relaunch as
# much as a fresh launch. So the PROVIDER'S ANSWER decides, never the --relaunch
# flag: the answer comes from `lanes host-accounts`, the one reader of that verb,
# and only `held` skips the usage gate.
#
# xclaude carries an expired access token and no OAuth client id is configured
# for it, so `lanes` reports it `expired` and measures no window. Each row below
# differs from its neighbour in one thing: what the provider answers, and whether
# the launch is a relaunch.
make_lane "$H" xclaude -3600
printf 'account=%s\tharness=claude\n' "$H/.xclaude" > "$TMP_ROOT/hosted-accounts.tsv"
HOSTED_ACCOUNT="LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts.tsv"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=;$HOSTED_ACCOUNT;$CHOICE_CMD" --host "$HOST_STUB" --harness claude \
  --lane "$H/.xclaude" --repo o/r CC-77
assert_eq "$(observe "rc=1 launched=nolog credentialdead=lane=$H/.xclaude,host=$HOST_STUB unreadable=none")" \
  "rc=1 launched=nolog credentialdead=lane=$H/.xclaude,host=$HOST_STUB unreadable=none" \
  "a fresh hosted launch on an account this machine cannot renew is refused as host-credential-dead"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=;$HOSTED_ACCOUNT;flags=--model fable --effort high" --host "$HOST_STUB" --harness claude \
  --lane "$H/.xclaude" --repo o/r --relaunch CC-78
assert_eq "$(observe "rc=0 launched=1 credentialdead=none unreadable=none relaunchgate=1")" \
  "rc=0 launched=1 credentialdead=none unreadable=none relaunchgate=1" \
  "a hosted relaunch on that same dead local copy proceeds, and says which credential runs it"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=;$CHOICE_CMD" --host "$HOST_STUB" --harness claude \
  --lane "$H/.xclaude" --repo o/r CC-79
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows" \
  "a provider holding no credential for the account leaves the refusal the unread window it was"
# The relaunch's skip is the provider's answer, not the flag. A provider with no
# accounts verb — the shipped reference lane-host-ssh, which copies this
# machine's account files to the host at every create — answers nothing, so the
# relaunch is judged on the local reading it runs on. Silent: the absent verb is
# no news.
RELAUNCH_FLAGS='flags=--model fable --effort high'
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=;LANE_HOST_STUB_NO_ACCOUNTS=1;$RELAUNCH_FLAGS" --host "$HOST_STUB" \
  --harness claude --lane "$H/.xclaude" --repo o/r --relaunch CC-100
assert_eq "$(observe "rc=1 launched=nolog relaunchgate=0 unanswered=0 credentialdead=none unreadable=lane=$H/.xclaude,model=fable,step=windows")" \
  "rc=1 launched=nolog relaunchgate=0 unanswered=0 credentialdead=none unreadable=lane=$H/.xclaude,model=fable,step=windows" \
  "a hosted relaunch whose provider implements no accounts verb keeps the usage gate, and says nothing about a verb that is absent"
# The control for this row is ctl-relaunch-skip, in the controls section below,
# where mutant_repo is defined; it keeps this world's lane and fixtures.

# WHICH unmeasured account gets the login remedy. The remedy is for a credential
# this machine holds and cannot renew, which `lanes` reports as `expired` and
# nothing else; an account that reads fine and simply has no window for the model
# is the unread window it always was. Its own lane, whose one window names a
# model no other row launches, so a pick asking for another model drops it.
make_lane "$H" vclaude 3600
jq -n '{limits: [{kind: "weekly_scoped", percent: 10, resets_at: "2026-08-01T06:00:00Z",
                  scope: {model: {display_name: "Haiku"}}}]}' > "$FIXTURE_DIR/.vclaude.json"
printf 'account=%s\tharness=claude\n' "$H/.vclaude" > "$TMP_ROOT/hosted-accounts-vclaude.tsv"
run_ot "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-vclaude.tsv;cmd=true --model sonnet --effort high" \
  --host "$HOST_STUB" --harness claude --lane "$H/.vclaude" --repo o/r CC-110
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.vclaude,model=sonnet,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.vclaude,model=sonnet,step=windows" \
  "a hosted account the provider holds, unmeasured for this model but not expired, is the unread window and not a login to renew"
# WHICH account the provider's answer is about. An answer naming other accounts
# of this harness is an answer that does not name this one, so the exact
# comparison is what stands between a held account and a neighbour's.
printf 'account=%s\tharness=claude\n' "$H/.eclaude" > "$TMP_ROOT/hosted-accounts-other.tsv"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-other.tsv;$CHOICE_CMD" \
  --host "$HOST_STUB" --harness claude --lane "$H/.xclaude" --repo o/r CC-111
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows" \
  "a provider naming other accounts of this harness holds nothing for this one, so the refusal stays the unread window"

# THE WALL BINDS A HOSTED RELAUNCH TOO. A usage window belongs to the account,
# not to the copy of the credential that reads it, so a window measured at the
# threshold here is the window the sandbox meets; resuming would spend the
# sandbox start, the worktree step and the continuation line to open on a usage
# banner. The local twin is CC-61 above, refused on the same shape, and the
# provider holds this account — which changes the UNMEASURED answer and nothing
# about the wall. Its own lane, so no row that follows reads this window.
make_lane "$H" wclaude 3600
claude_usage 10 20 95 'Fable 5.1' > "$FIXTURE_DIR/.wclaude.json"
printf 'account=%s\tharness=claude\n' "$H/.wclaude" > "$TMP_ROOT/hosted-accounts-walled.tsv"
run_ot "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-walled.tsv;$RELAUNCH_FLAGS" --host "$HOST_STUB" \
  --harness claude --lane "$H/.wclaude" --repo o/r --relaunch CC-107
assert_eq "$(observe "rc=1 launched=nolog creates=nolog relaunchgate=0 walled=lane=$H/.wclaude,model=fable,pct=95,bucket=model")" \
  "rc=1 launched=nolog creates=nolog relaunchgate=0 walled=lane=$H/.wclaude,model=fable,pct=95,bucket=model" \
  "a hosted relaunch onto an account the provider holds meets the wall its local twin meets"

# A verb that exists and fails is the other case: the reader prints the
# provider's own bytes under its keyed line, this launcher adds one of its own,
# and the gate still holds, because no answer establishes nothing.
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=;LANE_HOST_STUB_ACCOUNTS_STATUS=7;$RELAUNCH_FLAGS" --host "$HOST_STUB" \
  --harness claude --lane "$H/.xclaude" --repo o/r --relaunch CC-101
assert_eq "$(observe "rc=1 launched=nolog relaunchgate=0 unanswered=1 unreadable=lane=$H/.xclaude,model=fable,step=windows") provider=$(said 'lane-host-fixture: accounts-failed') reader=$(grep -c "^lanes: host-accounts-unreadable host=$HOST_STUB exit=7\$" <<<"$OUT" || true)" \
  "rc=1 launched=nolog relaunchgate=0 unanswered=1 unreadable=lane=$H/.xclaude,model=fable,step=windows provider=1 reader=1" \
  "a hosted relaunch whose provider fails the accounts verb keeps the gate, and the provider's line, the reader's line and the launcher's line all appear"
# The reader's validation reaches this launcher, which does no matching of its
# own. A row `lanes` drops for a percentage nobody can parse holds no account
# here either, so the refusal is the unread window and not a login remedy the
# owner cannot act on.
printf 'account=%s\tharness=claude\tweekly-pct=999\n' "$H/.xclaude" > "$TMP_ROOT/hosted-accounts-bad.tsv"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-bad.tsv;$CHOICE_CMD" \
  --host "$HOST_STUB" --harness claude --lane "$H/.xclaude" --repo o/r CC-102
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows") dropped=$(grep -c "^lanes: host-account-invalid account=$H/.xclaude field=weekly-pct\$" <<<"$OUT" || true)" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows dropped=1" \
  "an accounts row the reader drops holds no account for the launcher either"
# The harness is part of the match, and the reader makes it: a row naming this
# account under the other harness is not this launch's account.
printf 'account=%s\tharness=codex\n' "$H/.xclaude" > "$TMP_ROOT/hosted-accounts-codex.tsv"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-codex.tsv;$CHOICE_CMD" \
  --host "$HOST_STUB" --harness claude --lane "$H/.xclaude" --repo o/r CC-103
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows" \
  "an accounts row naming this account under another harness holds nothing for this launch"
# host-credential-dead reaches claude lanes. `lanes` reads an unrenewable expiry
# from the claude token alone; a codex account whose own auth.json cannot be used
# reads `unreachable`, which an offline read also produces, so the refusal stays
# the unread window and --help says so.
make_codex_lane "$H/.xcodex"
printf 'account=%s\tharness=codex\n' "$H/.xcodex" > "$TMP_ROOT/hosted-accounts-xcodex.tsv"
run_ot "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-xcodex.tsv;cmd=true -m gpt-6-astra -c model_reasoning_effort=high" \
  --host "$HOST_STUB" --harness codex --lane "$H/.xcodex" --repo o/r CC-104
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xcodex,model=gpt-6-astra,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xcodex,model=gpt-6-astra,step=windows" \
  "a codex lane this machine cannot measure is the unread window, never the claude-only login remedy"
run_ot "LANE_HOST_STUB_STATUS=75;$CHOICE_CMD" --host "$HOST_STUB" --harness claude --lane auto --repo o/r CC-42
assert_eq "$(observe "rc= launched=") owned=$(awk '$2 == "item-owned" { print $3 }' <<<"$OUT")" "rc=75 launched=nolog owned=item=CC-42" \
  "a hosted create exit 75 skips the item as owned by another session"
run_ot "LANE_HOST_STUB_STATUS=1;$CHOICE_CMD" --host "$HOST_STUB" --harness claude --lane auto --repo o/r CC-43
assert_eq "$(observe "rc= launched= creates=") failed=$(said "open-terminal: host-create-failed item=CC-43 exit=1")" "rc=1 launched=nolog creates=nolog failed=1" \
  "a hosted create failure is host-create-failed and opens no window"
run_ot "" --host "$HOST_STUB" --lane "$H/.eclaude" --repo o/r --cmd true CC-44
assert_eq "$(observe "rc= launched= creates=") create=$(host_call) invalid=$(awk '$2 == "host-invalid" { print $NF }' <<<"$OUT")" "rc=1 launched=nolog creates=nolog create=nolog invalid=harness=" \
  "a hosted launch without a host-protocol harness is host-invalid before any create"
run_ot "" --host "$HOST_STUB" --harness claude --wake CC-45
assert_eq "$(observe "rc=") create=$(host_call) wake=$(awk '$2 == "wake-invalid"' <<<"$OUT" | wc -l | tr -d '[:space:]')" "rc=1 create=nolog wake=1" \
  "a hosted wake is wake-invalid before any create"
run_ot "LANE_HOST_STUB_CREATE_LINE=ssh-target=lane.example"$'\t'"path=/srv/lane;$CHOICE_CMD" --host "$HOST_STUB" --harness claude --lane auto --repo o/r CC-46
assert_eq "$(observe "rc= launched=") invalid=$(said "open-terminal: host-line-invalid item=CC-46")" "rc=1 launched=nolog invalid=1" \
  "a create line missing its remote prefix is host-line-invalid and opens no window"
# lane-host create writes the hosted lane's marker on its host. A local one
# would bind the caller's own checkout, which would then pose as a lane.
HOSTCALLER="$TMP_ROOT/hostcaller"; mkdir -p "$HOSTCALLER"; git -C "$HOSTCALLER" init -q
run_ot "cwd=$HOSTCALLER;$CHOICE_CMD" --host "$HOST_STUB" --harness claude --lane auto --repo o/r CC-47
assert_eq "$(observe "rc= launched=") local_marker=$([[ -e "$HOSTCALLER/.git/lane-mail" ]] && echo present || echo absent)" "rc=0 launched=1 local_marker=absent" \
  "a hosted launch writes no lane marker into the caller's own checkout"

echo "=== the claim store belongs to the caller's checkout ==="
# `.agents` in a worktree points back at the main checkout, so a root derived
# from the script's own path would write where `lanes` never looks.
SCRIPTREPO="$TMP_ROOT/scriptrepo"; CALLERREPO="$TMP_ROOT/callerrepo"
mkdir -p "$SCRIPTREPO/scripts/lib" "$CALLERREPO"
cp "$OPEN_TERMINAL" "$SCRIPTS_DIR/lanes" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" "$SCRIPTS_DIR/lane-marker" "$SCRIPTREPO/scripts/"
cp "$SCRIPTS_DIR/lib"/*.sh "$SCRIPTREPO/scripts/lib/"
orch_fixture_shared_libs "$SCRIPTREPO"
chmod +x "$SCRIPTREPO/scripts/open-terminal" "$SCRIPTREPO/scripts/lanes" "$SCRIPTREPO/scripts/lane-marker"
git -C "$SCRIPTREPO" init -q; git -C "$CALLERREPO" init -q
( cd "$CALLERREPO" && LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
  TMUX=stub,1,0 OT_TMUX_LOG="$TMP_ROOT/caller.tmux.log" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$TMP_ROOT/caller.panes" \
  OT_WT_LOG="$TMP_ROOT/caller.worktree.log" PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
  "$SCRIPTREPO/scripts/open-terminal" --harness claude --lane auto \
  --cmd "true --model opus --effort high" CC-20 ) >/dev/null 2>&1
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
  "$SCRIPTREPO/scripts/open-terminal" --harness claude --lane auto \
  --cmd 'true {repo} --model opus --effort high' CC-21 ) >/dev/null 2>&1
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
cp "$OPEN_TERMINAL" "$SCRIPTS_DIR/lanes" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" "$SCRIPTS_DIR/lane-marker" "$MUTREPO/scripts/"
cp "$SCRIPTS_DIR/lib"/*.sh "$MUTREPO/scripts/lib/"
orch_fixture_shared_libs "$MUTREPO"
chmod +x "$MUTREPO/scripts/open-terminal" "$MUTREPO/scripts/lanes" "$MUTREPO/scripts/lane-marker"
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
    "$script" --harness claude --lane auto \
      --cmd 'true {repo} --model opus --effort high' CC-30 ) >/dev/null 2>&1
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
#
# `lane-marker` owns the record and the containment over it, and lane-marker.sh
# pins those; what these rows pin is that a launch calls it and fails the item
# on what it says.
NOGIT_STUB="$TMP_ROOT/worktree-nogit"
cat > "$NOGIT_STUB" <<'STUBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "create" ]] && { mktemp -d "$(dirname "$OT_WT_LOG")/wt.XXXXXX"; exit 0; }
exit 0
STUBEOF
chmod +x "$NOGIT_STUB"

# marked SCRIPT NAME WORKTREE_CLI — one launch of CC-40 from a caller checkout
# of its own. Prints `rc=<rc> marker=<root|none|other> box=<made|none>
# refused=<marker-failed lines>`. `box` is the lane's own mailbox directory,
# which the launch makes in the item's own spelling: lane-mail-check resolves
# the item by it, so a lane nobody has messaged is still judged on its handoff
# marks.
marked() {
  local script="$1" name="$2" runs="$TMP_ROOT/$2-runs" caller="$TMP_ROOT/$2-caller" out rc=0 wt marker=none box=none
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
  # A plain directory, never a link a row planted: -d alone follows one.
  { [[ -L "$wt/tmp/lane-mail/CC-40" ]] || [[ ! -d "$wt/tmp/lane-mail/CC-40" ]]; } || box=made
  printf 'rc=%s marker=%s box=%s refused=%s' "$rc" "$marker" "$box" "$(grep -c '^open-terminal: marker-failed item=CC-40 ' <<<"$out" || true)"
}

assert_eq "$(marked "$OPEN_TERMINAL" marked "$OT_STUB_BIN/worktree")" "rc=0 marker=root box=made refused=0" \
  "a launch binds its lowercased item to the root of the tree it made and opens the lane's mailbox there"
assert_eq "$(marked "$OPEN_TERMINAL" unmarkable "$NOGIT_STUB")" "rc=1 marker=none box=none refused=1" \
  "a tree git cannot mark fails the item instead of launching it"

# A worktree whose tmp is a symlink, which skills/worktree's WORKTREE_SYMLINKS
# makes: the launch marks it and opens its mailbox through the link, because
# containment starts at tmp/lane-mail, where lane-mail's own reader starts it.
TMPLINK_STUB="$TMP_ROOT/worktree-tmplink"
cat > "$TMPLINK_STUB" <<'STUBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "create" ]] || exit 0
d="$(mktemp -d "$(dirname "$OT_WT_LOG")/wt.XXXXXX")"
git init -q "$d"
scratch="$(mktemp -d "$(dirname "$OT_WT_LOG")/scratch.XXXXXX")"
ln -s "$scratch" "$d/tmp"
printf '%s\n' "$d"
STUBEOF
chmod +x "$TMPLINK_STUB"
assert_eq "$(marked "$OPEN_TERMINAL" tmplink "$TMPLINK_STUB")" "rc=0 marker=root box=made refused=0" \
  "a launch into a worktree whose tmp is a symlink writes the marker and the mailbox"

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
  "rc=1 marker=none box=none refused=1 target=untouched" "a symlink at the marker path fails the item and writes through nothing"

# The mutant: the marker line gone, so neither the write nor its refusal runs.
MARKREPO="$TMP_ROOT/markrepo"
mkdir -p "$MARKREPO/scripts/lib"
cp "$OPEN_TERMINAL" "$SCRIPTS_DIR/lanes" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" \
  "$SCRIPTS_DIR/lane-marker" "$MARKREPO/scripts/"
cp "$SCRIPTS_DIR/lib"/*.sh "$MARKREPO/scripts/lib/"
orch_fixture_shared_libs "$MARKREPO"
chmod +x "$MARKREPO/scripts/open-terminal" "$MARKREPO/scripts/lanes" "$MARKREPO/scripts/lane-marker"
sed -i.bak '/^  if \[\[ "\$WAKE" != true && -d "\$wt" \]\] && ! write_lane_marker /d' "$MARKREPO/scripts/open-terminal"
assert_eq "$(grep -c 'ot_message "\$LANE_MARKER_REASON"' "$MARKREPO/scripts/open-terminal")" "0" "control applied the marker mutation"
assert_eq "$(marked "$MARKREPO/scripts/open-terminal" mutant-marked "$OT_STUB_BIN/worktree")" "rc=0 marker=none box=none refused=0" \
  "control: without the marker line a launch leaves its lane unmarked"
assert_eq "$(marked "$MARKREPO/scripts/open-terminal" mutant-unmarkable "$NOGIT_STUB")" "rc=0 marker=none box=none refused=0" \
  "control: without the marker line an unmarkable tree launches anyway"

# The mailbox directory alone, with the marker still written: a launch that
# lost only the directory leaves the lane's turn-end hook no name to resolve
# its handoff marks by, and this is what tells that apart from a lost marker.
# The defect is planted in the owner the launcher calls, which is what these
# rows say the launcher does.
BOXREPO="$TMP_ROOT/boxrepo"
mkdir -p "$BOXREPO/scripts/lib"
cp "$OPEN_TERMINAL" "$SCRIPTS_DIR/lanes" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" \
  "$SCRIPTS_DIR/lane-marker" "$BOXREPO/scripts/"
cp "$SCRIPTS_DIR/lib"/*.sh "$BOXREPO/scripts/lib/"
orch_fixture_shared_libs "$BOXREPO"
chmod +x "$BOXREPO/scripts/open-terminal" "$BOXREPO/scripts/lanes" "$BOXREPO/scripts/lane-marker"
sed -i.bak 's@^MADE=\$(mkdir -p -- "\$COMMON/lane-mail" "\$BOX" 2>&1)@MADE=$(mkdir -p -- "$COMMON/lane-mail" 2>\&1)@' \
  "$BOXREPO/scripts/lane-marker"
assert_eq "$(grep -c 'mkdir -p -- "\$COMMON/lane-mail" "\$BOX"' "$BOXREPO/scripts/lane-marker")" "0" \
  "control applied the mailbox-directory mutation"
assert_eq "$(marked "$BOXREPO/scripts/open-terminal" mutant-boxless "$OT_STUB_BIN/worktree")" "rc=0 marker=root box=none refused=0" \
  "control: without its mkdir the launch marks the lane and opens no mailbox for it"

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
OT_VAR="$1" OT_LEAF="$3" OT_TRIGGER="${4:-}" OT_GATE="${5:-}" env "$1=$2" bash -c '
  if [[ -n "$OT_TRIGGER" ]]; then
    while [[ ! -e "$OT_TRIGGER" ]]; do sleep 0.1; done
    sleep 0.3
  fi
  # A gated tree stands on the picked account for long enough that a reading
  # taken before the launch is verified settles on it, then hands over and only
  # then lets the pane look launched.
  [[ -z "$OT_GATE" ]] || sleep 2
  env "$OT_VAR=$OT_LEAF" sleep 30 &
  [[ -z "$OT_GATE" ]] || : > "$OT_GATE"
  wait' &
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
# LATE=gated instead holds the handover, and the harness screen the pane draws
# with it, until after a reading taken the instant after the keystrokes would
# have settled.
#   verified   lane-verified lines; mismatch, lane-mismatch lines naming the
#              picked and observed dirs; closed, tmux kill-window calls
#   unobserved lane-unobserved lines
#   premise    lane-premise-unmet lines
#   unpremised lane-unobserved lines whose reason is the missing premise
#   resumed    launch lines carrying --resume, which is what a relaunch that
#              found a stored transcript renders in place of a fresh brief.
#              Read off the rendered command and not off the session-resumed
#              line, which the loop prints only after a launch that succeeded
#   probes     tmux capture-pane calls, which is how many times the premise
#              wait looked before it answered: 1 for a screen it knows, the
#              bound plus one for a screen it does not
#
# Trailing KEY=VALUE options, each optional:
#   cmd=       a --cmd template: the caller's own command, whose first word
#              open-terminal does not replace and whose pane it never reads back
#   flags=     further open-terminal flags, split on whitespace
#   text=      the pane screen the tmux stub draws, in place of the brief plus
#              the live-input marker the row's own harness draws
lane_launch() {
  local script="$1" name="$2" harness="$3" lane="$4" leaf="$5" late="$6" fields="$7" item="CC-50"
  shift 7
  local runs="$TMP_ROOT/$name-runs" caller="$TMP_ROOT/$name-caller" out rc=0 tree form=none launcher trigger="" var f value got=""
  # A row whose leaf names a path derived from the launch directory pins that
  # directory, since the stub otherwise makes a fresh one per run and no row
  # can spell it.
  local template="" flags="" text="" fixed_wt="" prefix_home="$lane" opt
  for opt in "$@"; do
    case "$opt" in
      cmd=*) template="${opt#cmd=}" ;;
      flags=*) flags="${opt#flags=}" ;;
      text=*) text="${opt#text=}" ;;
      wt=*) fixed_wt="${opt#wt=}" ;;
      home=*) prefix_home="${opt#home=}" ;;
      *) printf 'lane_launch: unknown option %s\n' "$opt" >&2; exit 1 ;;
    esac
  done
  # Every lane launch names a model and an effort or nothing launches. These
  # rows are about the launcher form and their lanes are outside every lane
  # record, so the pair is passed in the spelling the row's harness takes and
  # nothing here turns on its value. It goes in the text the launch RUNS: inside
  # a row's own --cmd command where it has one, since --launch-flags beside a
  # template reach nothing and are refused, and in --launch-flags where it does
  # not. Appended, so the template's FIRST word, which is what the launcher form
  # is judged on, stays the row's own.
  local choice extra=()
  case "$harness" in
    codex) choice="-m gpt-6-astra -c model_reasoning_effort=high" ;;
    *) choice="--model opus --effort high" ;;
  esac
  if [[ -n "$template" ]]; then extra=(--cmd "$template $choice")
  else extra=(--launch-flags "$choice"); fi
  # shellcheck disable=SC2206  # a row's flags are its own words, split on purpose.
  [[ -z "$flags" ]] || extra+=($flags)
  # The screen a launched TUI draws: the brief it was given, and the live-input
  # marker that says the harness itself is up. Per harness, because that marker
  # is what the premise ahead of the account read waits for: a codex row given
  # the Claude footer would be pinning the premise against a screen only Claude
  # draws. A gated row holds the marker back with the handover, and an
  # unlaunched row is given a screen carrying neither.
  if [[ -z "$text" ]]; then
    case "$harness" in
      codex) text="/orch start $item"$'\n''› ' ;;
      *) text="/orch start $item"$'\n''? for shortcuts' ;;
    esac
  fi
  # The lane variable per harness, pinning open-terminal's own mapping.
  case "$harness" in codex) var=CODEX_HOME ;; *) var=CLAUDE_CONFIG_DIR ;; esac
  # `basename --`, the way the judge derives it: a trailing-slash row's expected
  # name has to come out of the same normalisation the row is pinning.
  launcher="$(basename -- "$lane")"; launcher="${launcher#.}"
  mkdir -p "$runs" "$caller"
  git -C "$caller" init -q
  local gate=""
  [[ "$late" != late ]] || trigger="$runs/trigger"
  [[ "$late" != gated ]] || gate="$runs/gate"
  "$TMP_ROOT/lane-tree" "$var" "$lane" "$leaf" "$trigger" "$gate" & tree=$!
  out="$( cd "$caller" && LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
    TMUX=stub,1,0 OT_TMUX_LOG="$runs/tmux.log" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$runs/panes" \
    OT_PANE_PID="$tree" OT_PANE_TEXT="$text" ORCH_TMUX_VERIFY_SECS=5 OT_PANE_PID_TRIGGER="$trigger" \
    OT_LAUNCHED_GATE="$gate" \
    OT_WT_LOG="$runs/worktree.log" OT_WT_FIXED="$fixed_wt" OVERSEE_WATCH_STATE_DIR="$runs/state" \
    PATH="$LNBIN:$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
    "$script" --harness "$harness" --lane "$lane" ${extra[@]+"${extra[@]}"} "$item" 2>&1 )" || rc=$?
  kill_tree "$tree"
  # Under a template the first word after the prefix is the caller's own
  # command, not the harness word, so the prefix is all this row matches on.
  # The value the prefix must name: the lane itself, or the home `home=` gives
  # a row whose launch builds one.
  local want="clear; env $var='$prefix_home' "
  [[ -n "$template" ]] || want+="$harness "
  grep -qF "$want" "$runs/tmux.log" && form=prefix
  grep -qF "clear; '$LNBIN/$launcher' " "$runs/tmux.log" && form=launcher
  for f in $fields; do
    case "$f" in
      rc) value="$rc" ;;
      form) value="$form" ;;
      bare) value="$(grep -cF "clear; '$launcher' " "$runs/tmux.log" || true)" ;;
      verified) value="$(grep -c "^open-terminal: lane-verified item=$item " <<<"$out" || true)" ;;
      mismatch) value="$(grep -c "^open-terminal: lane-mismatch item=$item picked=$lane observed=" <<<"$out" || true)" ;;
      closed) value="$(grep -c '^kill-window' "$runs/tmux.log" || true)" ;;
      unobserved) value="$(grep -c "^open-terminal: lane-unobserved item=$item " <<<"$out" || true)" ;;
      premise) value="$(grep -c "^open-terminal: lane-premise-unmet item=$item reason=no-harness-screen$" <<<"$out" || true)" ;;
      unpremised) value="$(grep -c "^open-terminal: lane-unobserved item=$item reason=unpremised$" <<<"$out" || true)" ;;
      resumed) value="$(grep -c -- '--resume ' "$runs/tmux.log" || true)" ;;
      probes) value="$(grep -c '^capture-pane' "$runs/tmux.log" || true)" ;;
      *) value=UNKNOWN_FIELD ;;
    esac
    got="$got $f=$value"
  done
  printf '%s' "${got# }"
}

# mutant_repo NAME FILE BRE [REPLACEMENT] — a copy of the scripts at
# $TMP_ROOT/NAME with the one text BRE matches in FILE replaced, or the line
# deleted where no REPLACEMENT is given. FILE is the copy-relative path, since
# the launch form, the launch line and the account check live in the lib both
# launchers source and only their wiring is open-terminal's own. One defect per
# copy: a repo carrying several would pass its rows while any one of them was
# caught. A rule whose deletion changes more than the rule takes a replacement:
# dropping the account check's settle test entirely leaves a loop that never
# breaks, which is not the behaviour it replaced, and dropping the launcher
# print leaves the judge emitting nothing.
#
# Every control lives BELOW this definition, whatever section its green row sits
# in: a call above it is an undefined function, which run_ot reports as exit 127
# and a row reads as an ordinary assertion failure.
mutant_repo() {
  local dir="$TMP_ROOT/$1" file="$2"
  mkdir -p "$dir/scripts/lib"
  cp "$OPEN_TERMINAL" "$SCRIPTS_DIR/lanes" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" "$SCRIPTS_DIR/lane-marker" "$dir/scripts/"
  cp "$SCRIPTS_DIR/lib"/*.sh "$dir/scripts/lib/"
  orch_fixture_shared_libs "$dir"
  chmod +x "$dir/scripts/open-terminal" "$dir/scripts/lanes" "$dir/scripts/lane-marker"
  assert_eq "$(grep -c -e "$3" "$dir/$file")" "1" "control $1 finds exactly one line to mutate"
  if [[ $# -ge 4 ]]; then sed -i.bak "s/$3/$4/" "$dir/$file"
  else sed -i.bak "/$3/d" "$dir/$file"; fi
  assert_eq "$(grep -c -e "$3" "$dir/$file")" "0" "control $1 applied its mutation"
}

LAUNCH_LIB=scripts/lib/lane-launch.sh
mutant_repo ctl-slash "$LAUNCH_LIB" 'name="\$(basename -- "\$dir")"' 'name="${dir##*\/}"'
mutant_repo ctl-harness "$LAUNCH_LIB" '"\$name" != \*"\$harness"\*'
mutant_repo ctl-launcher "$LAUNCH_LIB" 'launcher:\*) printf'
mutant_repo ctl-abspath "$LAUNCH_LIB" "printf 'launcher:%s\\\\n' \"\$path\"" "printf 'launcher:%s\\\\n' \"\$name\""
mutant_repo ctl-check scripts/open-terminal '^  lane_account_ok "\$pane" "\$title" "\$premise" ||'
mutant_repo ctl-settle "$LAUNCH_LIB" '\[\[ -z "\$observed" || "\$observed" != "\$settled" \]\] || break' '[[ -z "$observed" ]] || break'
# The premise the read rests on: the pane is showing the harness's own screen,
# so the reading is about the harness and not about a wrapper still on its way
# to exec. Returning from that wait at once puts the reading back the instant
# after the keystrokes, which is where every shipped launch shape had it.
mutant_repo ctl-premise scripts/open-terminal 'tmux_wait_harness() { # PANE' 'tmux_wait_harness() { return 0; # PANE'
# The read happens on EVERY path past the keystrokes. Returning on a failed
# verification skips it, and a pane left open on an account nobody picked keeps
# its claim and its window.
mutant_repo ctl-failexit scripts/open-terminal '|| tmux_launch_verify "\$pane" "\$title" "\$brief" || launch_rc=\$?' '|| tmux_launch_verify "$pane" "$title" "$brief" || return 1'
# An unpremised read reports what it is. Without this the agreement a pane that
# never showed a harness happens to carry is announced as a verified account,
# byte for byte like one taken after the harness came up.
# A launch this check can never read back must not spend the whole verification
# timeout waiting for a screen first. Dropping the guard leaves the wait running
# its full bound ahead of a read that returns `skipped` either way.
mutant_repo ctl-readable scripts/open-terminal 'if lane_account_readable "\$LANE_FORM"; then' 'if true; then'
# A launch that built a private CODEX_HOME runs under it, so the account check
# reads that home back off the pane. Without the rule that maps a home to the
# account it sits under, every such launch reports a mismatch against the very
# account it is running on, and its window is closed.
mutant_repo ctl-homeaccount scripts/lib/lane-home.sh '\*\/lane-launch\/\*\/home) printf'
mutant_repo ctl-unpremised scripts/open-terminal 'if \[\[ "\$3" == unmet \]\]; then ot_message lane-unobserved "item=\$2" "reason=unpremised" >&2' 'if false; then ot_message lane-unobserved "item=$2" "reason=unpremised" >\&2'

assert_eq "$(lane_launch "$OPEN_TERMINAL" launcher claude "$LNLANE" "$LNLANE" - "rc form bare")" \
  "rc=0 form=launcher bare=0" \
  "a lane whose launcher is on PATH launches through it by the absolute path the judge resolved, with no env prefix"
assert_eq "$(lane_launch "$OPEN_TERMINAL" bare claude "$LNBARE" "$LNBARE" - "rc form bare")" \
  "rc=0 form=prefix bare=0" \
  "a lane with no launcher on PATH keeps the env prefix"
assert_eq "$(lane_launch "$OPEN_TERMINAL" self claude "$LNSELF" "$LNSELF" - "rc form bare")" \
  "rc=0 form=prefix bare=0" \
  "a lane named for the harness itself keeps the env prefix: the harness binary picks its own default account"
# A codex launch runs under the home it builds for its worktree, and that home
# is reached by the variable that names it whatever else is on PATH: an account
# launcher exports CODEX_HOME for its OWN name, which would put the launch back
# on the shared config with no trust entry in it. So the launcher form is what
# these two rows say a codex lane must NOT take, where the claude rows above
# say a lane with a launcher takes it. Each row pins its worktree, since the
# home it must name is derived from that path.
CODEXLAUNCHWT="$TMP_ROOT/codex-launcher-wt"
CODEXSELFWT="$TMP_ROOT/codex-self-wt"
codex_home_for() { ( source "$SCRIPTS_DIR/lib/lane-launch.sh" && lane_codex_home_path "$1" "$2" ); }
assert_eq "$(lane_launch "$OPEN_TERMINAL" codex-launcher codex "$LNCODEX" "$LNCODEX" - "rc form bare" \
  "wt=$CODEXLAUNCHWT" "home=$(codex_home_for "$LNCODEX" "$CODEXLAUNCHWT")")" \
  "rc=0 form=prefix bare=0" \
  "a codex lane keeps the prefix even where its launcher is on PATH: the launcher would overwrite the home carrying the launch's folder trust"
assert_eq "$(lane_launch "$OPEN_TERMINAL" codex-self codex "$LNCODEXSELF" "$LNCODEXSELF" - "rc form bare" \
  "wt=$CODEXSELFWT" "home=$(codex_home_for "$LNCODEXSELF" "$CODEXSELFWT")")" \
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

# A --cmd template is the caller's own command: its first word is not replaced
# even on a lane whose launcher IS on PATH, and its pane is read back by
# nothing, so neither account verdict appears. Without the template term in the
# judge this launch would be read back against a command nobody here built.
# The pane draws no harness screen, so a wait taken here would run to its whole
# bound: at zero probes this launch never looked, which is the guard. That bound
# is the hard-coded 15 here, not ORCH_TMUX_VERIFY_SECS: a --cmd template reads
# none of the waits the setting is validated for, so the setting is not read for
# it either — which is what the control below spends.
assert_eq "$(lane_launch "$OPEN_TERMINAL" template claude "$LNLANE" "$LNLANE" - "rc form verified unobserved probes" "cmd=true {item}" "text=dev@lane:~$")" \
  "rc=0 form=prefix verified=0 unobserved=0 probes=0" \
  "a --cmd template keeps the env prefix on a launcher-named lane and is read back by nothing"
assert_eq "$(lane_launch "$TMP_ROOT/ctl-readable/scripts/open-terminal" mutant-readable claude "$LNLANE" "$LNLANE" - "rc verified probes" "cmd=true {item}" "text=dev@lane:~$")" \
  "rc=0 verified=0 probes=16" \
  "control: without the readable guard a launch nothing reads back still spends the whole verification timeout looking for a harness"

# Controls for the model gate. run_ot reads $OPEN_TERMINAL, so each mutant takes
# that name for its own rows and the patched path is restored after.
OPEN_TERMINAL_PATCHED="$OPEN_TERMINAL"

# One control per rule of the model-and-effort refusal, each on the same
# arguments as the green row beside it. OUTSIDE_LANE is a config dir no lane
# record covers, so a launch that gets past the refusal meets no usage verdict
# and the row reads the refusal alone.
run_ot "" --harness claude --lane "$OUTSIDE_LANE" --cmd true CC-90
assert_eq "$(observe "rc=1 launched=nolog modelmissing=harness=claude,lane=$OUTSIDE_LANE,spellings=--model")" \
  "rc=1 launched=nolog modelmissing=harness=claude,lane=$OUTSIDE_LANE,spellings=--model" \
  "a lane launch naming no model is refused for it"
mutant_repo ctl-model-rule scripts/open-terminal 'if \[\[ -z "\$LAUNCH_MODEL" \]\]; then' 'if [[ -n "$LAUNCH_MODEL" ]]; then'
OPEN_TERMINAL="$TMP_ROOT/ctl-model-rule/scripts/open-terminal"
run_ot "" --harness claude --lane "$OUTSIDE_LANE" --cmd true CC-91
assert_eq "$(observe "modelmissing=none effortmissing=harness=claude,lane=$OUTSIDE_LANE,spellings=--effort")" \
  "modelmissing=none effortmissing=harness=claude,lane=$OUTSIDE_LANE,spellings=--effort" \
  "control: without the model rule a launch naming no model is not refused for it"
OPEN_TERMINAL="$OPEN_TERMINAL_PATCHED"

run_ot "cmd=true --model opus" --harness claude --lane "$OUTSIDE_LANE" CC-92
assert_eq "$(observe "rc=1 launched=nolog effortmissing=harness=claude,lane=$OUTSIDE_LANE,spellings=--effort")" \
  "rc=1 launched=nolog effortmissing=harness=claude,lane=$OUTSIDE_LANE,spellings=--effort" \
  "a lane launch naming no effort is refused for it"
mutant_repo ctl-effort-rule scripts/open-terminal '\-z "\$LAUNCH_EFFORT" \]\]' '-n "$LAUNCH_EFFORT" ]]'
OPEN_TERMINAL="$TMP_ROOT/ctl-effort-rule/scripts/open-terminal"
run_ot "cmd=true --model opus" --harness claude --lane "$OUTSIDE_LANE" CC-93
assert_eq "$(observe "rc=0 launched=1 effortmissing=none")" "rc=0 launched=1 effortmissing=none" \
  "control: without the effort rule a launch naming no effort launches"
OPEN_TERMINAL="$OPEN_TERMINAL_PATCHED"
# The bypass this refusal closes, planted whole: the refusal gone AND the model
# read out of the launch flags again, which is the code as it shipped. The
# launch then passes the gate on a word start_cmd renders nowhere, and its lane
# is judged and its record written under a model the harness never runs. Two
# edits on one copy, because either alone refuses the launch for the other's
# reason. OUTSIDE_LANE is covered by no lane record, so the row reads the gate
# alone. Its green rows are the CC-99 and CC-112 launches above.
mutant_repo ctl-flags-reach scripts/open-terminal 'if \[\[ -n "\$CMD_TEMPLATE" && -n "\$LAUNCH_FLAGS" \]\]; then' 'if false; then'
assert_eq "$(grep -cF 'LAUNCH_TEXT="$CMD_TEMPLATE"' "$TMP_ROOT/ctl-flags-reach/scripts/open-terminal")" "1" \
  "control ctl-flags-reach finds one text-the-launch-runs assignment to widen"
sed -i.bak 's/LAUNCH_TEXT="\$CMD_TEMPLATE"/LAUNCH_TEXT="$LAUNCH_FLAGS $CMD_TEMPLATE"/' \
  "$TMP_ROOT/ctl-flags-reach/scripts/open-terminal"
assert_eq "$(grep -cF 'LAUNCH_TEXT="$LAUNCH_FLAGS $CMD_TEMPLATE"' "$TMP_ROOT/ctl-flags-reach/scripts/open-terminal")" "1" \
  "control ctl-flags-reach applied its second mutation"
OPEN_TERMINAL="$TMP_ROOT/ctl-flags-reach/scripts/open-terminal"
run_ot "flags=--model opus --effort high" --harness claude --lane "$OUTSIDE_LANE" --cmd true CC-113
assert_eq "$(observe "rc=0 launched=1 flagsunreachable=none modelmissing=none")" \
  "rc=0 launched=1 flagsunreachable=none modelmissing=none" \
  "control: with the refusal gone and the flags read again, a launch whose command names no model passes the gate on a model the harness never runs"
OPEN_TERMINAL="$OPEN_TERMINAL_PATCHED"

# The harness a `--lane auto:<h>` spec names is the launch's harness, and the
# gate reads it. Keyed on --harness alone, the same launch reaches the lane with
# no model named at all, which is the state the refusal exists to prevent. Its
# green row is the CC-114 launch above.
mutant_repo ctl-lane-harness scripts/open-terminal 'LAUNCH_HARNESS="\$LANE_SPEC_HARNESS"' 'LAUNCH_HARNESS="$HARNESS"'
OPEN_TERMINAL="$TMP_ROOT/ctl-lane-harness/scripts/open-terminal"
run_ot "cmd=true" --lane auto:claude CC-117
assert_eq "$(observe "rc=0 launched=1 modelmissing=none effortmissing=none")" \
  "rc=0 launched=1 modelmissing=none effortmissing=none" \
  "control: keyed on --harness alone the gate skips a launch naming its harness only in the lane spec, and it starts on the harness default"
OPEN_TERMINAL="$OPEN_TERMINAL_PATCHED"

# pi's level on the model value is read from the row's separator field. Without
# that read, the launch that named both choices in one token is refused for the
# effort it already passed.
mutant_repo ctl-colon "$LAUNCH_LIB" '\[\[ "\$model" != \*"\$in_model"\* \]\] ||' '[[ "$model" == *"$in_model"* ]] ||'
OPEN_TERMINAL="$TMP_ROOT/ctl-colon/scripts/open-terminal"
run_ot "cmd=true --model sonnet:high" --harness pi --lane "$H/.claude" CC-105
assert_eq "$(observe "rc=1 launched=nolog effortmissing=harness=pi,lane=$H/.claude,spellings=--thinking")" \
  "rc=1 launched=nolog effortmissing=harness=pi,lane=$H/.claude,spellings=--thinking" \
  "control: without the separator read the level on the model value is not the effort, and the launch is refused for naming none"
OPEN_TERMINAL="$OPEN_TERMINAL_PATCHED"

# Which unmeasured account a relaunch proceeds on is the provider's answer and
# not the --relaunch flag. Keyed on the flag alone, the same launch over a
# provider that holds nothing proceeds and tells the operator the host runs a
# credential nothing here established. Its green row is the CC-100 launch above,
# on that world's expired xclaude lane and the same absent-verb provider.
mutant_repo ctl-relaunch-skip scripts/open-terminal '&& "\$HOST_ACCOUNT" == held \]\]' ']]'
OPEN_TERMINAL="$TMP_ROOT/ctl-relaunch-skip/scripts/open-terminal"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=;LANE_HOST_STUB_NO_ACCOUNTS=1;$RELAUNCH_FLAGS" --host "$HOST_STUB" \
  --harness claude --lane "$H/.xclaude" --repo o/r --relaunch CC-106
assert_eq "$(observe "rc=0 launched=1 relaunchgate=1 unreadable=none")" \
  "rc=0 launched=1 relaunchgate=1 unreadable=none" \
  "control: keyed on the flag alone, a relaunch whose provider holds nothing proceeds and claims the host copy runs it"
OPEN_TERMINAL="$OPEN_TERMINAL_PATCHED"

# The alias lookup's own status, taken and then acted on. Without the capture the
# failing lookup ends the run under errexit inside the substitution, and the
# launch dies with no keyed line of its own for the operator to act on. Its green
# row is the alias-spelled resolution-failure row in the first table.
#
# The CHECK that reads the captured status has no control of its own: with it
# gone the empty answer falls to the alias-not-found branch, whose `lane_check`
# meets the same malformed setting and refuses with the same key, so no input
# this suite can build tells the two apart. What the green row holds is the key
# an operator acts on, which is the same either way.
mutant_repo ctl-alias-status scripts/open-terminal ')" || alias_rc=\$?' ')"'
OPEN_TERMINAL="$TMP_ROOT/ctl-alias-status/scripts/open-terminal"
run_ot "ORCH_LANE_ALIASES=eclaude=work;ORCH_LANES_USAGE_TTL=soon;$CHOICE_CMD" --harness claude --lane work CC-109
assert_eq "$(observe "rc=1 launched=nolog failed=none") keyed=$(grep -c '^open-terminal: ' <<<"$OUT" || true)" \
  "rc=1 launched=nolog failed=none keyed=0" \
  "control: without the alias lookup's status the launch dies inside the substitution with no keyed line"
OPEN_TERMINAL="$OPEN_TERMINAL_PATCHED"

# The wall is judged for every named lane, with no launch shape exempt. Exempting
# the hosted relaunch — the shape that reads the provider at all — lets the
# walled account resume and open on its usage banner, which is the whole cost the
# gate exists to avoid. Its green row is CC-107 above, on that world's wclaude
# lane and a provider that holds it.
mutant_repo ctl-gate-every-shape scripts/open-terminal \
  'if \[\[ "\$lane_gate" == true \]\]; then' 'if [[ "$lane_gate" == true \&\& "$HOST_RELAUNCH" != true ]]; then'
OPEN_TERMINAL="$TMP_ROOT/ctl-gate-every-shape/scripts/open-terminal"
run_ot "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-walled.tsv;$RELAUNCH_FLAGS" --host "$HOST_STUB" \
  --harness claude --lane "$H/.wclaude" --repo o/r --relaunch CC-108
assert_eq "$(observe "rc=0 launched=1 walled=none")" "rc=0 launched=1 walled=none" \
  "control: with the hosted relaunch exempt from the gate the walled account resumes onto its own usage banner"
OPEN_TERMINAL="$OPEN_TERMINAL_PATCHED"

# Without the arm that takes a choice's value from the NEXT token, every
# space-spelled flag reads as absent: `--model sonnet` names no model, and the
# launch is refused for naming none instead of being judged against the window
# it did name. The uclaude fixture is where the two answers are visibly
# different — no window of it measures sonnet, so the unpatched script refuses
# as lane-model-unreadable and the patched one never reaches the lane at all.
claude_usage 10 20 95 'Fable 5.1' > "$FIXTURE_DIR/.claude.json"
# The lane its own gate row left the home is removed again after that row, so
# this pair builds it back: one scoped window for Opus and nothing else, which
# has binding-bucket room and measures nothing for sonnet.
make_lane "$H" uclaude 3600
jq -n '{limits: [{kind: "weekly_scoped", percent: 10, resets_at: "2026-08-01T06:00:00Z",
                  scope: {model: {display_name: "Opus"}}}]}' > "$FIXTURE_DIR/.uclaude.json"
run_ot "cmd=true --model sonnet --effort high" --harness claude --lane "$H/.uclaude" CC-80
assert_eq "$(observe "rc=1 launched=nolog modelmissing=none unreadable=lane=$H/.uclaude,model=sonnet,step=windows")" \
  "rc=1 launched=nolog modelmissing=none unreadable=lane=$H/.uclaude,model=sonnet,step=windows" \
  "the space-spelled model is judged against that lane's own window, which measures nothing for it"
mutant_repo ctl-take "$LAUNCH_LIB" 'tokens\[i+1\]'
OPEN_TERMINAL="$TMP_ROOT/ctl-take/scripts/open-terminal"
run_ot "cmd=true --model sonnet --effort high" --harness claude --lane "$H/.uclaude" CC-66
assert_eq "$(observe "rc=1 launched=nolog unreadable=none modelmissing=harness=claude,lane=$H/.uclaude,spellings=--model")" \
  "rc=1 launched=nolog unreadable=none modelmissing=harness=claude,lane=$H/.uclaude,spellings=--model" \
  "control: without the take arm the space-spelled model reads as none and the launch is refused for naming none"

# Without the null clause in the judge, an unmeasured wall compares as though it
# were the smallest number there is — jq orders null below every number — and a
# lane whose windows answer nothing for the model is handed back as having room.
# The clause is lib/lane-model.sh's `wall_verdict`, the one classifier both pick
# forms read, so this row reddens with the fleet chooser's own control.
#
# The unpatched script first: a copy taken while the row above still pointed at
# its own mutant would carry two planted defects under one verdict, and would
# pass while either was caught.
OPEN_TERMINAL="$OPEN_TERMINAL_PATCHED"
mutant_repo ctl-nullwall scripts/lib/lane-model.sh 'if \. == null then "unmeasured"' 'if false then "unmeasured"'
make_lane "$H" uclaude 3600
jq -n '{limits: [{kind: "weekly_scoped", percent: 10, resets_at: "2026-08-01T06:00:00Z",
                  scope: {model: {display_name: "Opus"}}}]}' > "$FIXTURE_DIR/.uclaude.json"
OPEN_TERMINAL="$TMP_ROOT/ctl-nullwall/scripts/open-terminal"
run_ot "cmd=true --model sonnet --effort high" --harness claude --lane "$H/.uclaude" CC-72
assert_eq "$(observe "rc=0 launched=1 unreadable=none")" "rc=0 launched=1 unreadable=none" \
  "control: without the null clause a lane nothing measures is treated as free and launches"
rm -rf -- "${H:?}/.uclaude" "${FIXTURE_DIR:?}/.uclaude.json"

OPEN_TERMINAL="$OPEN_TERMINAL_PATCHED"
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"

echo "=== the pane is read back, and a disagreement closes the window ==="
# The check needs a readable per-process environment. Where the platform has
# none, lane_account_ok reports that by name and the launch stands, which these
# rows cannot tell apart from the pass they are pinning — so only they skip.
# The rows above still run there, which is the point of the split.
# The condition is the reader's own predicate, asked in a subshell because the
# lib's claims sibling sets errexit as it loads and this suite runs without it.
if ! ( source "$SCRIPTS_DIR/lib/lane-launch.sh" && lane_process_env_readable ); then
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

  # A wrapper that holds the picked account while it comes up and hands over
  # only as the harness starts. Read the instant after the keystrokes, this
  # settles on the wrapper and the item is announced on an account the pane is
  # about to stop running.
  #
  # Three launch shapes, because the premise the read rests on must not be a
  # side effect of any one of them: a claude launch that carries a brief, a
  # codex launch that carries none, and a claude relaunch that resumes a
  # session and so carries none either. The last two reach the read with no
  # brief to verify, which is where they were being read too early.
  assert_eq "$(lane_launch "$OPEN_TERMINAL" gated claude "$LNBARE" "$LNLANE" gated "rc verified mismatch closed")" \
    "rc=1 verified=0 mismatch=1 closed=1" \
    "a wrapper that hands the account over as the harness starts is caught on a claude launch"
  assert_eq "$(lane_launch "$OPEN_TERMINAL" gated-codex codex "$LNCODEXSELF" "$LNLANE" gated "rc verified mismatch closed")" \
    "rc=1 verified=0 mismatch=1 closed=1" \
    "the same handover is caught on a codex launch, which carries no brief to verify"
  # The transcript a relaunch resumes. Staged here and removed after, so no
  # other row's launch finds a session it never asked for.
  RESUME_ROOT="$H/.claude-shared/projects/lane-resume"
  mkdir -p "$RESUME_ROOT"
  printf '%s\n' '{"type":"user","message":{"content":"kickoff CC-50"}}' > "$RESUME_ROOT/session.jsonl"
  # `resumed` is what makes this row the relaunch it claims to be: without it a
  # transcript that stopped matching would render a fresh claude carrying a
  # brief, which is the row above, and this assertion would not notice.
  assert_eq "$(lane_launch "$OPEN_TERMINAL" gated-resume claude "$LNBARE" "$LNLANE" gated "rc verified mismatch closed resumed" flags=--relaunch)" \
    "rc=1 verified=0 mismatch=1 closed=1 resumed=1" \
    "and on a claude relaunch that resumes a session, which carries none either"
  rm -rf -- "${RESUME_ROOT:?}"

  # On the codex shape, because that is where the premise is the ONLY thing
  # holding the read back: a claude launch also waits for its brief to appear,
  # which delays the read past the handover whatever this wait does.
  assert_eq "$(lane_launch "$TMP_ROOT/ctl-premise/scripts/open-terminal" mutant-premise codex "$LNCODEXSELF" "$LNLANE" gated "rc verified mismatch closed")" \
    "rc=0 verified=1 mismatch=0 closed=0" \
    "control: with the premise wait gone the briefless launch confirms the handover as the picked account"

  # The premise knows BOTH harnesses. A resumed codex pane draws its own
  # marker and no Claude one: the wait must answer on the first look, and the
  # read that follows is a premised one that reports the account it confirms.
  assert_eq "$(lane_launch "$OPEN_TERMINAL" codex-screen codex "$LNCODEXSELF" "$LNCODEXSELF" - "rc verified premise unpremised probes" "text=› ")" \
    "rc=0 verified=1 premise=0 unpremised=0 probes=1" \
    "a codex pane drawing only its own marker meets the premise on the first look"

  # A screen the predicate does not know: the wait cannot refuse it, so it
  # stalls for the whole bound — ORCH_TMUX_VERIFY_SECS=5 above, one look per
  # second plus the look that finds the budget spent. The read still happens,
  # and both the launch and the read say it was taken without the premise.
  assert_eq "$(lane_launch "$OPEN_TERMINAL" no-screen codex "$LNCODEXSELF" "$LNCODEXSELF" - "rc verified premise unpremised probes" "text=dev@lane:~$")" \
    "rc=0 verified=0 premise=1 unpremised=1 probes=6" \
    "a screen the premise does not know stalls for the whole bound, and the read that follows is reported unpremised"
  assert_eq "$(lane_launch "$TMP_ROOT/ctl-unpremised/scripts/open-terminal" mutant-unpremised codex "$LNCODEXSELF" "$LNCODEXSELF" - "rc verified premise unpremised" "text=dev@lane:~$")" \
    "rc=0 verified=1 premise=1 unpremised=0" \
    "control: without the unpremised arm a reading off a pane that never showed a harness is announced as a verified account"

  # A codex launch runs under the home it built for its worktree, so what the
  # pane carries is that home and not the account directory. The check's
  # question is which ACCOUNT the pane is spending, and a home built under one
  # is that account; a pane on some other account still disagrees, which the
  # `wrong` row above pins. The worktree is pinned because the leaf here is
  # derived from it, and the home path comes from the builder itself rather
  # than a second spelling of its shape.
  CODEXTRUSTWT="$TMP_ROOT/codex-trust-wt"
  CODEXTRUSTHOME="$( source "$SCRIPTS_DIR/lib/lane-launch.sh" && lane_codex_home_path "$LNCODEXSELF" "$CODEXTRUSTWT" )"
  assert_eq "$(lane_launch "$OPEN_TERMINAL" codex-trust codex "$LNCODEXSELF" "$CODEXTRUSTHOME" - "rc verified mismatch closed" "wt=$CODEXTRUSTWT")" \
    "rc=0 verified=1 mismatch=0 closed=0" \
    "a pane carrying the home this launch built confirms the account it was built under"
  assert_eq "$(lane_launch "$TMP_ROOT/ctl-homeaccount/scripts/open-terminal" mutant-homeaccount codex "$LNCODEXSELF" "$CODEXTRUSTHOME" - "rc verified mismatch closed" "wt=$CODEXTRUSTWT")" \
    "rc=1 verified=0 mismatch=1 closed=1" \
    "control: without the home-to-account rule a launch is closed over the home it was given"

  # A launch whose verification FAILS leaves this pane open with its claim
  # live, so the account it is really running on still has to be the picked
  # one. The pane draws neither the brief nor a ready composer, which is the
  # screen a stuck launch shows.
  # The premise is unmet here too, and a disagreement still refuses on it: the
  # guard fails closed on what it observed, whatever drew the screen.
  assert_eq "$(lane_launch "$OPEN_TERMINAL" stuck claude "$LNBARE" "$LNLANE" - "rc verified mismatch closed premise" "text=dev@lane:~$")" \
    "rc=1 verified=0 mismatch=1 closed=1 premise=1" \
    "a pane whose launch never verified is still read back, and a disagreement closes it"
  assert_eq "$(lane_launch "$TMP_ROOT/ctl-failexit/scripts/open-terminal" mutant-failexit claude "$LNBARE" "$LNLANE" - "rc verified mismatch closed" "text=dev@lane:~$")" \
    "rc=1 verified=0 mismatch=0 closed=0" \
    "control: returning on the failed verification leaves the pane open on an account nobody picked"
fi

echo "=== with no threshold flag the launcher forwards none and lanes decides ==="
# The bound lives in `lanes` alone. A launch passing no --lane-max-pct is judged
# on exactly the number the oversee directive's own `lanes pick` used; a second
# default here is what handed the overseer an account this gate then refused,
# so the item never launched and the same lane was picked again next cycle.
#
# The rows run against a copy of the scripts placed outside every checkout, and
# that is what isolates them: open-terminal takes its project root from `git -C`
# on its OWN directory, not from the working directory, so the shipped script
# loads this repository's kendex.settings.toml and exports its threshold to the
# `lanes` it spawns. The copy loads no settings file, run_ot's pin is dropped,
# and the suite unsets the variable, so the number that decides is the one
# `lanes` holds. The whole scripts directory is copied because open-terminal
# resolves its libraries and `lanes` beside itself, and the github libs are laid
# beside the copy because an orch lib reaches them by a fixed relative path.
new_home lanes-default
make_lane "$H" claude 3600
make_lane "$H" eclaude 3600
claude_usage 10 92 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 10 97 5 Opus > "$FIXTURE_DIR/.eclaude.json"
OUTSIDE_ROOT="$TMP_ROOT/outside-checkout/orch"; OUTSIDE_SCRIPTS="$OUTSIDE_ROOT/scripts"
mkdir -p "$OUTSIDE_SCRIPTS"
cp -R "$SCRIPTS_DIR/." "$OUTSIDE_SCRIPTS/" || { printf 'outside copy failed\n' >&2; exit 1; }
orch_fixture_shared_libs "$OUTSIDE_ROOT"
OT_REAL="$OPEN_TERMINAL"; OPEN_TERMINAL="$OUTSIDE_SCRIPTS/open-terminal"
table \
  "a named lane at 92 percent used launches, the launcher forwarding no threshold of its own|max_pct=unset;cwd=$NOSETTINGS;$CHOICE_CMD|--harness claude --lane $H/.claude CC-75|rc=0 launched=1 cmd_lane=claude walled=none" \
  "--lane auto is judged on the same bound, passing over the account above it|max_pct=unset;cwd=$NOSETTINGS;$CHOICE_CMD|--harness claude --lane auto CC-76|rc=0 launched=1 cmd_lane=claude"

# The control plants the private default this change removed INTO THAT SAME
# COPY, so it differs from the two rows above by the defect and nothing else:
# the launcher then forwards 90 whatever `lanes` holds, and the account at 92
# percent is refused although the directive's own pick handed it back.
mutate_file "$OUTSIDE_SCRIPTS/open-terminal" \
  '[[ -z "$LANE_MAX_PCT" ]] || LANE_PCT_ARGS=(--max-pct "$LANE_MAX_PCT")' \
  'LANE_PCT_ARGS=(--max-pct "${LANE_MAX_PCT:-90}")'
run_ot "max_pct=unset;cwd=$NOSETTINGS;$CHOICE_CMD" --harness claude --lane "$H/.claude" CC-77
assert_eq "$(observe "rc=1 launched=nolog walled=lane=$H/.claude,model=opus,pct=92,bucket=weekly")" \
  "rc=1 launched=nolog walled=lane=$H/.claude,model=opus,pct=92,bucket=weekly" \
  "control: a private default of 90 refuses the account the directive's own pick handed back"
OPEN_TERMINAL="$OT_REAL"

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
