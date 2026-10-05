# shellcheck shell=bash
#
# The world the open-terminal --lane suites share: the lane settings kept out
# of every fixture, the claim and usage fixtures from lanes-fixture.sh, the
# stubs from open-terminal-stubs.sh and the run_ot, observe and table
# helpers each row reads a launch through. A suite sources it after its
# `set -uo pipefail`, its git-env preamble and the TMP_ROOT its own trap
# removes; the suites are open-terminal-lane-pick.sh (how a lane is picked,
# judged and claimed, and the tree a launch binds), open-terminal-lane-hosted.sh
# (a hosted launch and its ssh pane) and open-terminal-lane.sh (the launcher
# and the pane read back, which race a real process tree and so run alone).
#
# Sourced, never run: the runners glob tests/*.sh, so the `lib/` prefix keeps
# this file out of the run.

# Empty child values keep inherited and checkout lane settings out of fixtures.
# Unsetting them would let the project loader restore the checkout values.
# Each row's explicit settings follow these defaults and override them.
LANE_ENV_DEFAULTS=(
  LINEAR_TEAM=
  ORCH_LANE_PREFERENCE= ORCH_LANE_DIRS= ORCH_LANE_ALIASES=
  ORCH_LANE_EXCLUDE= ORCH_LANE_RETIRE= ORCH_LANE_COPILOT_POOL=
  ORCH_LANE_BURN_PCT_PER_HOUR= ORCH_LANE_MAX_PCT= ORCH_LANE_HOST=local
)
unset ORCH_LANES_USAGE_TTL CODEX_HOME
# The renewal's own settings, for the same reason: with one of these exported a
# developer runs a different suite from CI, where the expired-lane rows below
# stay expired, and a row could reach a live helper or the real token endpoint.
unset ORCH_LANES_CLAUDE_CLIENT_ID ORCH_LANES_TOKEN_CMD ORCH_LANES_CLAUDE_TOKEN_URL
# shellcheck source=shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/shared-skill-libs.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
OPEN_TERMINAL="$SCRIPTS_DIR/open-terminal"
CODEX_COMPACTION='{"harness":"codex","settings":{"model_auto_compact_token_limit":"9223372036854775807","model_auto_compact_token_limit_scope":"body_after_prefix","model_post_turn_compact_threshold_percent":"0"}}'

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$TEST_DIR/lib/lanes-fixture.sh"
# shellcheck source=lib/open-terminal-stubs.sh
source "$TEST_DIR/lib/open-terminal-stubs.sh"
# shellcheck source=lib/question-off.sh
source "$TEST_DIR/lib/question-off.sh"
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
# The command observations use the launcher's model reader. Its claims sibling
# enables errexit; this suite collects refusal statuses instead of exiting.
# shellcheck source=../scripts/lib/lane-launch.sh
source "$SCRIPTS_DIR/lib/lane-launch.sh"
set +e
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"

# --- stubs -----------------------------------------------------------------
OT_STUB_BIN="$TMP_ROOT/ot-bin"
ot_stub_bin "$OT_STUB_BIN"
# Only the scoring rows use a fixed epoch. Keep real sleeps for the launch
# waits, and the real clock for token expiry and renewal rows.
source "$TEST_DIR/lib/virtual-clock.sh"
mkdir -p "$TMP_ROOT/clock-bin"
virtual_clock_install "$TMP_ROOT/clock-bin" "$TMP_ROOT/pick-clock"
printf '%s\n' 1790812800 > "$TMP_ROOT/pick-clock"
ln -s "$TMP_ROOT/clock-bin/date" "$OT_STUB_BIN/date"
STUB_CLOCK=""

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
d="$(mktemp -d "$OWNED_ROOT/wt.XXXXXX")"; git init -q "$d"; git -C "$d" config gc.auto 0; git -C "$d" config maintenance.auto false; printf '%s\n' "$d"
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
printf '200 \n'
cat "$f"
STUB
chmod +x "$TMP_ROOT/fetch-flaky"

# A second home whose discovery hands back a lane carrying the claim record's
# field separator. At the fixed epoch, aclaude's 70 room resetting in one
# hour scores 105; the tab lane's 80 resetting in nine hours scores 88.
# A claim charged 20 session points drops aclaude to 75, so the tab lane wins.
new_home tabhome
TABHOME="$H"; TABFIX="$FIXTURE_DIR"
TABDIR="$TABHOME/.tab	claude"
make_lane "$TABHOME" aclaude 3600
mkdir -p "$TABDIR"
cp "$TABHOME/.aclaude/.credentials.json" "$TABDIR/.credentials.json"
claude_usage 30 10 5 Opus | jq '.five_hour.resets_at = "2026-10-01T01:00:00Z"' > "$TABFIX/.aclaude.json"
claude_usage 20 10 5 Opus | jq '.five_hour.resets_at = "2026-10-01T09:00:00Z"' > "$TABFIX/.tab	claude.json"
TABBED="$TMP_ROOT/tab	lane"; mkdir -p "$TABBED"

# A private batch world uses the same score crossing without the separator.
# After both accounts have a claim, claude scores 75 and eclaude scores 66,
# so the third item returns to claude. Claims-first picks eclaude first.
new_home spreadhome
SPREADHOME="$H"; SPREADFIX="$FIXTURE_DIR"
make_lane "$H" claude 3600
make_lane "$H" eclaude 3600
claude_usage 30 10 5 Opus | jq '.five_hour.resets_at = "2026-10-01T01:00:00Z"' > "$FIXTURE_DIR/.claude.json"
claude_usage 20 10 5 Opus | jq '.five_hour.resets_at = "2026-10-01T09:00:00Z"' > "$FIXTURE_DIR/.eclaude.json"
SPREAD_ENV="LANES_HOME=$SPREADHOME;FIXTURE_DIR=$SPREADFIX;ORCH_LANE_BURN_PCT_PER_HOUR=20;STUB_CLOCK=$TMP_ROOT/pick-clock"

# Checkouts a row can run from: one holding a directory named like a lane
# alias, one holding a bare directory no alias claims, one with no git at all.
COLLIDE="$TMP_ROOT/collide"; mkdir -p "$COLLIDE/work"; git -C "$COLLIDE" init -q -b main; git -C "$COLLIDE" config gc.auto 0; git -C "$COLLIDE" config maintenance.auto false
BARE="$TMP_ROOT/bare"; mkdir -p "$BARE/somelane"; git -C "$BARE" init -q -b main; git -C "$BARE" config gc.auto 0; git -C "$BARE" config maintenance.auto false
NOREPO="$TMP_ROOT/norepo"; mkdir -p "$NOREPO"
# A git repository with no kendex settings of its own. A script copied outside
# every checkout resolves no PROJECT_ROOT, and `lane-host resolve` then runs
# from the working directory, which has to be a repository; this one carries no
# settings for that script to pick up on the way.
NOSETTINGS="$TMP_ROOT/nosettings"; mkdir -p "$NOSETTINGS"; git -C "$NOSETTINGS" init -q -b main; git -C "$NOSETTINGS" config gc.auto 0; git -C "$NOSETTINGS" config maintenance.auto false

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
# read-only directory or as a plain file before the launch, `prep=claude_claim`
# one live launch claim on the claude lane in pane %1, `flags=S` passes S
# as one --launch-flags string and `cmd=S` passes S as one --cmd template, with
# every harness's question-tool words after it (lib/question-off.sh). Those
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
        cmd=*) flag_args=(--cmd "${item#cmd=} $QUESTION_OFF_ALL") ;;
        *) env_args+=("$item") ;;
      esac
    done
  fi
  case "$prep" in
    "") ;;
    store_ro) mkdir -p "$RUN/state/claims"; chmod 555 "$RUN/state/claims" ;;
    claims_file) mkdir -p "$RUN/state"; : > "$RUN/state/claims" ;;
    claude_claim)
      mkdir -p "$RUN/state/claims"; printf '1' > "$RUN/panes"
      printf '%s\t%%1\t%s\tcc-live\t2026-09-28T00:00:00Z\t\n' "$$" "$H/.claude" > "$RUN/state/claims/cc-live.claim"
      ;;
    *) echo "run_ot: unknown prep $prep" >&2; exit 1 ;;
  esac
  # The provider's disk for this run: a hosted launch reads the lane's `.git`
  # there for the clone its marker belongs under, and writes the marker back.
  mkdir -p "$RUN/remote/srv/lane"
  printf 'gitdir: /srv/clone/.git/worktrees/lane\n' > "$RUN/remote/srv/lane/.git"
  # Every tmux wait is bounded by one of these two, the premise wait ahead of
  # the account read included. These rows stub a pane that draws no harness
  # screen, so each such wait runs to its bound; one second keeps the suite
  # honest. Which waits read the ssh bound, and how many of them a hosted
  # launch makes, is named at open-terminal's validation gate. The pane is
  # replayed from the tmux log and no process here changes under a wait, so
  # OT_SLEEP_INSTANT spends each bound's looks in no wall time; lane_launch,
  # whose rows race a real process tree, keeps the real sleep.
  OUT=$(cd "$cwd" && env "${LANE_ENV_DEFAULTS[@]}" LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
    LANE_HOST_STUB_DIR="$RUN/remote" OT_SLEEP_INSTANT=1 \
    ORCH_TMUX_VERIFY_SECS=1 ORCH_LANE_SSH_PROMPT_SECS=1 ${pct_pin[@]+"${pct_pin[@]}"} \
    TMUX=stub,1,0 ORCH_TMUX_SESSION=stub OT_TMUX_LOG="$RUN/tmux.log" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$RUN/panes" \
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
#   cmd_model     the model in a preference-built Claude command
#   cmd_lane      the lane the launched command's env prefix names, read from
#                 the tmux log, single-quoted as the launch shell needs it
#   pi_root       the same for a PI_CODING_AGENT_DIR prefix, or none
#   copilot_home  the same for the COPILOT_HOME the launch line sets, or none
#   pickrefusal   every field of the first refusal of an `auto` pick, a
#                 copilot-pool-*, lane-provider-unmeasured or lane-unavailable
#                 line, key first, or none
#   hostseat      every field of the host-pi-claude-seat line, or none
#   compactionon  the file field of the first compaction-on line, or none
#   statusline    the cause and file fields of the first status-line refusal,
#                 or none
#   claim_lanes   the distinct lanes those claims name, sorted
#   claim_window  the window the single claim names; claim_pane its pane id
#   out_lanes     the lanes the launch output names, in order
#   summary       the batch summary's lane attribution, the one fact only the
#                 summary carries: `spread=N` distinct lanes, or `lane=NAME`
#   walled        lane, model, pct, bucket and projected-headroom of the
#                 lane-model-walled line, or none
#   unreadable    lane, model and step of the lane-model-unreadable line, or none
#   unread_status  its status field after step; unread_reason its login reason
#   poolfix       every Copilot pool fix= line as READ:ROOT, READ `local`,
#                 `absent`, `host` or `row` by the read it names and ROOT the
#                 root it names with `_` for a space, comma-joined, or none
#   judgefailed   lane, model and exit of the lane-judge-failed line, or none
#   modelmissing  harness, lane and spellings of the launch-model-missing line,
#                 or none
#   effortmissing the same of the launch-effort-missing line, or none
#   flagsunreachable  every field of the launch-flags-unreachable line, commas
#                 for spaces, or none
#   questionmissing  every field of the launch-question-tool-missing line,
#                 commas for spaces, or none
#   credentialdead  lane and host of the host-credential-dead line, or none
#   promptmissing every field of the remote-prompt-missing line, commas for
#                 spaces, or none
#   seconds_invalid  setting and value of the verify-seconds-invalid line, or none
#   seconds_clamped  setting, value and limit of the verify-seconds-clamped
#                 line, or none
#   tmuxfailed    operation and item of the tmux-failed line, or none
#   relaunchgate  the host-relaunch-credential lines, which say the launch was
#                 not judged on this machine's copy of the account
#   unanswered    the host-accounts-unanswered lines, which say the provider
#                 failed the accounts verb and the launch kept the local gate
#   localreading  the keyed lanes: pick-local-reading lines, which say the
#                 provider could not read the account and the judge took this
#                 machine's fresh reading of it
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
      cmd_model)
        # The tmux stub logs events before the command; the model reader takes
        # one command line, not the complete event log.
        value="$(sed -n '/^clear; env CLAUDE_CONFIG_DIR=/{p;q;}' "$RUN/tmux.log")" || return 1
        value="$(launch_choice_launch_model claude "$value")" || return 1
        value="${value:-none}"
        ;;
      cmd_lane) value="$(grep -oE "env CLAUDE_CONFIG_DIR='[^']*'" "$RUN/tmux.log" 2>/dev/null | sed -E -e "s/^env CLAUDE_CONFIG_DIR='//" -e "s/'\$//" -e "s#^$H/\\.##" | sort -u | paste -sd, - || true)"; value="${value:-none}" ;;
      pi_root) value="$(grep -oE "env PI_CODING_AGENT_DIR='[^']*'" "$RUN/tmux.log" 2>/dev/null | sed -E -e "s/^env PI_CODING_AGENT_DIR='//" -e "s/'\$//" -e "s#^$H/\\.##" | sort -u | paste -sd, - || true)"; value="${value:-none}" ;;
      copilot_home) value="$(grep -oE "COPILOT_HOME='[^']*'" "$RUN/tmux.log" 2>/dev/null | sed -E -e "s/^COPILOT_HOME='//" -e "s/'\$//" -e "s#^$H/\\.##" | sort -u | paste -sd, - || true)"; value="${value:-none}" ;;
      compactionon)
        value="$(awk '$1 == "open-terminal:" && $2 == "compaction-on" { print $4; exit }' <<<"$OUT")"
        value="${value:-none}"
        ;;
      statusline)
        value="$(awk '$1 == "open-terminal:" && $2 == "unsupported-for-oversee" && $4 == "reason=no-context-reader" { print $5 "," $6 "," $7; exit }' <<<"$OUT")"
        value="${value:-none}"
        ;;
      pickrefusal)
        value="$(awk '$1 == "open-terminal:" && $2 ~ /^(copilot-pool-|lane-provider-unmeasured$|lane-unavailable$)/ { $1 = ""; sub(/^ +/, ""); gsub(/ +/, ","); print; exit }' <<<"$OUT")"
        value="${value:-none}"
        ;;
      hostseat)
        value="$(awk '$1 == "open-terminal:" && $2 == "host-pi-claude-seat" { $1 = ""; $2 = ""; sub(/^ +/, ""); gsub(/ +/, ","); print; exit }' <<<"$OUT")"
        value="${value:-none}"
        ;;
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
        value="$(awk '$1 == "open-terminal:" && $2 == "lane-model-walled" { print $3, $4, $5, $6, $7; exit }' <<<"$OUT" | tr ' ' ',')"
        value="${value:-none}"
        ;;
      unreadable)
        value="$(awk '$1 == "open-terminal:" && $2 == "lane-model-unreadable" { print $3, $4, $5; exit }' <<<"$OUT" | tr ' ' ',')"
        value="${value:-none}"
        ;;
      unread_status)
        value="$(awk '$1 == "open-terminal:" && $2 == "lane-model-unreadable" { print $6; exit }' <<<"$OUT")"
        value="${value:-none}"
        ;;
      unread_reason)
        value="$(sed -nE 's/^open-terminal: lane-model-unreadable .* detail=copilot login unread: ([a-z-]*).*/\1/p' <<<"$OUT")"
        value="${value:-none}"
        ;;
      poolfix)
        value="$(sed -nE -e 's/^fix=no Copilot pool reading for ([^:]*): ORCH_LANE_HOST=local .*/local:\1/p' \
          -e 's/^fix=no Copilot pool reading for ([^:]*): lane host .* implements no accounts verb.*/absent:\1/p' \
          -e 's/^fix=no Copilot pool reading for ([^:]*): the accounts verb .*/host:\1/p' \
          -e 's/^fix=no Copilot pool reading for ([^:]*): the accounts row .*/row:\1/p' <<<"$OUT" | tr ' ' _ | paste -sd, -)"
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
      questionmissing)
        value="$(sed -n 's/^open-terminal: launch-question-tool-missing //p' <<<"$OUT" | sed -n 1p | tr ' ' ',')"
        value="${value:-none}"
        ;;
      credentialdead)
        value="$(awk '$1 == "open-terminal:" && $2 == "host-credential-dead" { print $3, $4; exit }' <<<"$OUT" | tr ' ' ',')"
        value="${value:-none}"
        ;;
      promptmissing)
        # Every field of the line, commas for spaces: the bound it spent and
        # the attempts it made are the two only this line carries.
        value="$(sed -n 's/^open-terminal: remote-prompt-missing //p' <<<"$OUT" | sed -n 1p | tr ' ' ',')"
        value="${value:-none}"
        ;;
      seconds_invalid)
        value="$(awk '$1 == "open-terminal:" && $2 == "verify-seconds-invalid" { print $3, $4; exit }' <<<"$OUT" | tr ' ' ',')"
        value="${value:-none}"
        ;;
      seconds_clamped)
        value="$(awk '$1 == "open-terminal:" && $2 == "verify-seconds-clamped" { print $3, $4, $5; exit }' <<<"$OUT" | tr ' ' ',')"
        value="${value:-none}"
        ;;
      tmuxfailed)
        value="$(awk '$1 == "open-terminal:" && $2 == "tmux-failed" { print $3, $4; exit }' <<<"$OUT" | tr ' ' ',')"
        value="${value:-none}"
        ;;
      relaunchgate) value="$(grep -c '^open-terminal: host-relaunch-credential ' <<<"$OUT" || true)" ;;
      unanswered) value="$(grep -c '^open-terminal: host-accounts-unanswered ' <<<"$OUT" || true)" ;;
      localreading) value="$(grep -c '^lanes: pick-local-reading ' <<<"$OUT" || true)" ;;
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
      # The writer's own words under that refusal, jq's for a claude config
      # that does not parse: the count of lines carrying its prefix.
      trustdetail) value="$(grep -c '^jq: ' <<<"$OUT" || true)" ;;
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

# A config dir no lane record covers: a launch on it meets no usage verdict.
OUTSIDE_LANE="$TMP_ROOT/outside-any-lane"
mkdir -p "$OUTSIDE_LANE"

# pi_control NAME FILE OLD NEW ENV ARGS... — one run_ot against a copy of the
# scripts with FILE edited from OLD to NEW, the shipped launcher restored after.
pi_control() { # NAME FILE OLD NEW ENV ARGS... — sets OPEN_TERMINAL back after one run
  local shipped="$OPEN_TERMINAL" dir
  dir="$(mutant_scripts "$1/orch" "$2")" || exit 1
  orch_fixture_shared_libs "$TMP_ROOT/$1/orch"
  mutate_file "$dir/$2" "$3" "$4"
  OPEN_TERMINAL="$dir/open-terminal"
  shift 4
  run_ot "$@"
  OPEN_TERMINAL="$shipped"
}

# lane_suite_end — the hermeticity proof over every run the suite made, then
# its summary; its status is the suite's.
lane_suite_end() {
  # Hermeticity proof: every window the launch rows created went through the
  # stub. No new-window line anywhere means a real tmux server took the calls.
  if grep -q '^new-window' "$TMP_ROOT"/runs/*/tmux.log 2>/dev/null; then
    pass "launch rows drove the tmux stub, not a real server"
  else
    fail "launch rows bypassed the tmux stub (real windows were created)"
  fi

  echo
  printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
