#!/usr/bin/env bash
# Tests for scripts/oversee-succeed over a real tmux server on a private
# socket. The caller is a pane whose context reading the overseer's turn-end
# hook would have recorded in the overseer mailbox, written here per screen;
# claude and codex are stubs on PATH, and `lanes pick` answers from
# the lanes-fixture usage bodies. The harness stubs record their lane and argv
# and print the interrupt hint a running turn draws. The success row runs the
# script inside the caller's own pane, whose close HUPs it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/copilot-context-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/copilot-context-world.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/lanes-fixture.sh"
# mutant_scripts and mutate_file, the two halves of each mode's control.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
SUCCEED="${OVERSEE_SUCCEED_UNDER_TEST:-$TEST_DIR/../scripts/oversee-succeed}"
CODEX_COMPACTION='{"harness":"codex","settings":{"model_auto_compact_token_limit":"9223372036854775807","model_auto_compact_token_limit_scope":"body_after_prefix","model_post_turn_compact_threshold_percent":"0"}}'

TMP_ROOT="$(mktemp -d)" || { echo "oversee_succeed: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "oversee_succeed: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "oversee_succeed: scratch=resolve-failed" >&2; exit 1; }
SOCK="oversee-succeed-$$"
cleanup() {
  [[ ! -f "$TMP_ROOT/work/tmp/oversee-watch.pid" ]] || fixture_watch_stop "$TMP_ROOT/work/tmp/workflow-state-oversee.json" || true
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  [[ -z "${FOREIGN_PID:-}" ]] || kill "$FOREIGN_PID" 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
source "$TEST_DIR/lib/watch-fixture.sh"
QUIET_SCRIPTS="$(mutant_scripts fixture-watch oversee-succeed)" || exit 1
cp -p -- "$SUCCEED" "$QUIET_SCRIPTS/oversee-succeed"
SUCCEED="$QUIET_SCRIPTS/oversee-succeed"
fixture_watch_neighbor "$SUCCEED"
tm() { tmux -L "$SOCK" "$@"; }

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# A timing row asserts NAME and reads NAME:VALUE back when the figure missed the
# range, so the seconds it measured reach the failure text. An empty bound is
# open on that side; a non-numeric VALUE never matches.
in_range() { # NAME VALUE LO HI
  local name="$1" value="$2" lo="$3" hi="$4"
  if [[ "$value" =~ ^[0-9]+$ ]] &&
     { [[ -z "$lo" ]] || (( value >= lo )); } &&
     { [[ -z "$hi" ]] || (( value <= hi )); }; then
    printf '%s\n' "$name"
  else
    printf '%s:%s\n' "$name" "$value"
  fi
}

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN" "$TMP_ROOT/work"
# The work directory is the overseer's checkout, current with its origin, so a
# launch's fast-forward has nothing to move or refuse until a row says so.
# shellcheck source=lib/overseer-checkout.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/overseer-checkout.sh"
checkout_world "$TMP_ROOT/work" || { echo "fixture: the work checkout could not be made" >&2; exit 1; }
# The claude stub asks the folder-trust question the real harness asks: with
# no `hasTrustDialogAccepted` for its working directory in the .claude.json
# of the config dir it runs under, it draws the dialog line and waits, which
# is what a successor launched without the entry meets. The codex stub asks
# none, its trust being the launch-home rows' subject.
for harness in claude codex copilot; do
  case "$harness" in
    claude) lane_var=CLAUDE_CONFIG_DIR ;;
    codex) lane_var=CODEX_HOME ;;
    copilot) lane_var=COPILOT_HOME ;;
  esac
  trust_gate=""
  [[ "$harness" != claude ]] || trust_gate="jq -e --arg d \"\$(pwd -P)\" '.projects[\$d].hasTrustDialogAccepted == true' \"\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.claude.json\" >/dev/null 2>&1 || { echo 'Do you trust the files in this folder?'; exec sleep 100000; }"
  cat > "$BIN/$harness" <<STUB
#!/bin/sh
{ printf 'lane=%s\n' "\${$lane_var:-}"; printf 'argv0=%s\n' "\$0"; printf '%s\n' "\$@"; } > "$TMP_ROOT/argv.$harness"
$(checkout_stub_line)
$trust_gate
if [ -f "$TMP_ROOT/idle" ]; then echo 'FIXTURE successor startup waiting'; else echo 'esc to interrupt'; fi
[ ! -f "$TMP_ROOT/asking" ] || echo 'Do you want to proceed?'
exec sleep 100000
STUB
done
# A caller pane whose foreground process NAMES a harness, which is what
# lib/lane-context.sh needs before it will answer which account that session is
# spending from the account variable alone: a pane running anything else is
# offered both shapes and takes a variable only where exactly one is set. The
# `claude` stub above cannot hold the pane — it records its argv, and the
# successor's row would be the caller's.
#
# A COPY of sleep, never a shell or script named for the harness: both can reset
# the process name tmux reads, so the shape rule never sees the harness word.
cp "$(command -v sleep)" "$BIN/hclaude"
cp "$(command -v sleep)" "$BIN/node"
chmod +x "$BIN/claude" "$BIN/codex" "$BIN/copilot" "$BIN/hclaude" "$BIN/node"

# The trigger every headroom fixture below is derived from: a lane at exactly
# TRIGGER percent headroom has no room and one at TRIGGER+1 does, so the rows
# move with the setting instead of pinning 90 and 89 by hand. It follows the
# script's own default, which the rows below leave unset; the two rows that
# pin the SHIPPED default state their figures literally and say why.
TRIGGER=5
AT_TRIGGER=$((100 - TRIGGER))
ABOVE_TRIGGER=$((100 - TRIGGER - 1))

new_home fleet
make_lane "$H" claude
make_lane "$H" eclaude
make_codex_lane "$H/.codex"
FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"
# The caller's own account is .claude. The second claude lane stands walled by
# default so every row that does not speak about it picks .claude as before;
# a row exercising the headroom trigger gives it room of its own.
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
codex_usage() { # USED_PCT
  jq -n --argjson u "$1" '{rate_limit: {primary_window: {used_percent: $u, reset_at: 1785000000, limit_window_seconds: 18000}, secondary_window: null}}'
}
codex_usage 20 > "$FIXTURE_DIR/.codex.json"

env PATH="$BIN:$PATH" tmux -L "$SOCK" -f /dev/null new-session -d -s fleet -x 220 -y 50 'exec sleep 100000'
KEEP_WINDOW="$(tm display-message -p -t fleet:0 '#{window_id}')"
tm set-option -g default-shell /bin/sh
tm set-option -g renumber-windows off
# oversee-succeed opens the successor window with NO command, and tmux starts
# such a pane as a LOGIN shell. A login shell runs /etc/profile.d, which on a
# developer machine puts that host's own claude ahead of this fixture's stub on
# PATH, and every launching row then measures the real binary instead of the
# stub. default-command makes the successor pane a non-login shell under this
# fixture's PATH, so the stub is the claude it runs on any host.
tm set-option -g default-command "PATH=$BIN:\$PATH; export PATH; exec /bin/sh"
TMUX_ADDR="$(tm display-message -p '#{socket_path},#{pid},0')"
SERVER_PID="$(tm display-message -p '#{pid}')"
# The server's start, which every record a launch, a watch start or
# `oversee register` writes binds its server by; the hand-written records
# below carry it too.
SERVER_START="$(tm display-message -p '#{start_time}')"

MARK='  kendex (ken-1453) Fable 5.1 (1M context) 52% (fixture@example.com)     /rc'
UNDER_MARK='  kendex (ken-1453) Fable 5.1 (1M context) 10% (fixture@example.com)     /rc'
# A codex caller, whose account's reset is parsed from a Unix epoch.
CODEX_SCREEN='  Context 48% left'
# A codex caller at exactly 90 percent of the 258400 window its rollout names.
CODEX_AT_MARK='  Context 10% left'
# A claude tier the claude adapter's window table leaves out, so its reading
# carries a model and no window.
NO_TABLE_TIER='  kendex (ken-1453) Sonnet 4.5 47% (fixture@example.com)     /rc'

SRC_DIR="$(cd "$(dirname "$SUCCEED")" && pwd)"
# The account read's own condition, taken from the library the script under
# test sources, so every host decision below is the check's own answer and not
# a second copy of its test. See § The account the pane is really on.
# shellcheck source=../scripts/lib/lane-launch.sh
source "$SRC_DIR/lib/lane-launch.sh"
# The caller's full-bypass permission word, from the launch table, for the rows
# whose preference names a codex entry: only a transferable posture lets the
# walk reach an entry of another harness, and this file spells no switch.
BYPASS="$(launch_choice_permission_write claude)" || { echo "fixture: no claude permission word in the launch table" >&2; exit 1; }
# The owner of which reading a session takes of its own account, asked directly
# by the row that pins the pick's bound. See § the pick reading.
# shellcheck source=../scripts/lib/lane-context.sh
source "$SRC_DIR/lib/lane-context.sh"
# Fixture readings are <harness> <tokens> <window> <model>, empty before a turn.
# The record supplies identity; the wrapper passes --context unless NO_CONTEXT.
# CONTEXT_PCT defaults to 50. Production never reads these drawn screens.
screen_reading() { # SCREEN
  case "$1" in
    "$MARK") echo 'claude 520000 1000000 claude-fable-5-1' ;;
    "$UNDER_MARK") echo 'claude 100000 1000000 claude-fable-5-1' ;;
    "$CODEX_SCREEN") echo 'codex 100000 258400 gpt-6-astra' ;;
    "$CODEX_AT_MARK") echo 'codex 232560 258400 gpt-6-astra' ;;
    "$NO_TABLE_TIER") echo 'claude 399999 - claude-sonnet-4-5' ;;
    *'Sonnet 4.5 52%'*) echo 'claude 399999 - claude-sonnet-4-5' ;;
    *'Opus 5 (200k context) 41%'*) echo 'claude 82000 200000 claude-opus-5' ;;
    *) ;;
  esac
}

# The overseer mailbox every row's script reads, under the directory each run
# starts in.
OVERSEER_RECORD="$TMP_ROOT/work/tmp/lane-mail/overseer/context.json"

# record_caller SCREEN PANE — the reading screen_reading names for SCREEN,
# recorded for PANE through the library's own writer, and its figure left in
# CALLER_CONTEXT_FILE as the --context argument; neither where it names none.
# The argument is written before the record: the record naming its pane is the
# barrier in-pane starts the script on, so a record written first lets the run
# start with no --context and report context-unmeasured reason=context-unread.
CALLER_CONTEXT_FILE="$TMP_ROOT/caller.context"
record_caller() { # SCREEN PANE
  local reading harness tokens window model
  mkdir -p "${OVERSEER_RECORD%/*}"
  rm -f -- "$OVERSEER_RECORD" "$CALLER_CONTEXT_FILE"
  reading="$(screen_reading "$1")"
  [[ -n "$reading" ]] || return 0
  read -r harness tokens window model <<<"$reading"
  [[ "$window" != - ]] || window=""
  printf '%s:%s\n' "$tokens" "$window" > "$CALLER_CONTEXT_FILE"
  lane_context_record "${OVERSEER_RECORD%/*}" "$harness" "$tokens" "$window" "$model" s1 "$SERVER_PID $2"
}

# new_caller SCREEN [MARKER] [COMMAND] — every window past index 0 closed, then
# a caller pane at index 1 showing SCREEN; sets CALLER_PANE and CALLER_WINDOW.
# MARKER is the text that says the pane has drawn, defaulting to the claude
# screens' own. COMMAND is the pane's own command, defaulting to one whose
# foreground process names no harness.
new_caller() {
  fixture_watch_stop "$TMP_ROOT/work/tmp/workflow-state-oversee.json"
  local f="$TMP_ROOT/caller.screen" spec marker="${2:-(fixture@example.com)}"
  local cmd="${3:-cat '$f'; exec sleep 100000}"
  printf '%s\n' "$1" > "$f"
  tm kill-window -a -t "$KEEP_WINDOW"
  tm move-window -r -t fleet
  spec="$(tm new-window -d -t fleet:1 -c "$TMP_ROOT/work" -P -F '#{pane_id} #{window_id}' "$cmd")"
  read -r CALLER_PANE CALLER_WINDOW <<<"$spec"
  fixture_watch_predecessor "$SUCCEED" "$TMP_ROOT/work/tmp/workflow-state-oversee.json" "$TMP_ROOT/work" "$CALLER_PANE"
  record_caller "$1" "$CALLER_PANE"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ "$(tm capture-pane -p -t "$CALLER_PANE")" != *"$marker"* ]] || return 0
    sleep 0.2
  done
  echo "fixture: caller pane never drew its screen" >&2
  exit 1
}

# A pane whose command establishes its harness but whose screen has no context
# line. The account triggers can use that identity without guessing a model or
# context window.
new_known_claude_caller() {
  new_caller "$1" "$1" "cat '$TMP_ROOT/caller.screen'; exec '$BIN/hclaude' 100000"
  tm display-message -p -t "$CALLER_PANE" 'fixture: known caller command=#{pane_current_command}'
}

# A row whose successor never shows a running turn waits its whole --wait-secs
# bound and needs nothing real to happen inside it, so it runs with
# VIRTUAL_CLOCK set: the script reads time through the virtual clock, seeded at
# the real epoch, and spends the bound in no wall time. Every other row keeps
# the real clock, since its waits are the settle reads and running-turn looks
# of a real successor pane: two reads a second apart is what a settle claims,
# and a pane that draws in real time cannot be raced on a faster clock.
# shellcheck source=lib/virtual-clock.sh
source "$TEST_DIR/lib/virtual-clock.sh"
CLOCK_BIN="$TMP_ROOT/clock-bin"
mkdir -p "$CLOCK_BIN"
virtual_clock_install "$CLOCK_BIN" "$TMP_ROOT/clock"

# succeed-env ROW PREFERENCE ARGS... — the script under an explicit, whole
# environment, with TMUX and TMUX_PANE taken from the caller of this file: the
# test passes them, and a pane's own shell already carries them.
cat > "$TMP_ROOT/succeed-env" <<ENV
#!/usr/bin/env bash
row="\$1" pref="\$2"
shift 2
source "$TEST_DIR/lib/assertions.sh"
case " \$* " in
  *' --check-marks '*|*' --print-launch-line '*|*' --dead-pane '*|*' --walled-pane '*) ;;
  *)
    if [[ "\${HANDOFF_FIXTURE:-on}" == on ]]; then
      fixture_succession_handoff "$TMP_ROOT/work/tmp/workflow-state-oversee.json" "$TMP_ROOT/work/tmp/handoffs/OVERSEER-HANDOFF.md" || exit 1
    fi ;;
esac
# Only a row that speaks about the trigger sets it, so every other row runs on
# the script's own default and a drift in that default reddens them.
hp=""
[ -z "\${HEADROOM_PCT:-}" ] || hp="ORCH_OVERSEER_HEADROOM_PCT=\$HEADROOM_PCT"
# The account variable the caller pane carries. The word none carries NEITHER
# of them, which is what an overseer started by hand has: the harness picks its
# own default account and nothing in the environment says so. No backtick in
# this heredoc: it is unquoted, so one would run its contents as this file is
# written and the fixture would carry whatever that printed.
lane="\${CALLER_LANE:-CLAUDE_CONFIG_DIR=$H/.claude}"
[ "\$lane" != none ] || lane=""
cm="ORCH_HANDOFF_CONTEXT_PCT=\${CONTEXT_PCT:-50}"
# The pause between the two reads an account settles on. A harness stub here
# has execed its last process within milliseconds of its launch, so a tenth of
# a second still keeps the two reads apart, and no launch spends the production
# second on each read; lane-account-settle.sh holds the pause itself. A
# VIRTUAL_CLOCK row keeps the production second: the virtual sleep advances on
# whole seconds alone and sleeps a fraction in real time.
settle="ORCH_LANE_SETTLE_MS=100"
[ -z "\${VIRTUAL_CLOCK:-}" ] || settle=""
# A lanes setting the row can spoil, for the one row that needs the account
# judge itself to fail rather than answer.
ttl=""
[ -z "\${USAGE_TTL:-}" ] || ttl="ORCH_LANES_USAGE_TTL=\$USAGE_TTL"
wall="ORCH_OVERSEER_WALL_MINUTES=\${WALL_MINUTES:-0}"
[ "\$wall" != ORCH_OVERSEER_WALL_MINUTES=default ] || wall=""
successors="ORCH_OVERSEER_SUCCESSOR_ACCOUNTS=\${SUCCESSOR_ACCOUNTS:-0}"
# The setting's default is off, which puts the question-tool words on every
# successor line; the rows here pin the rest of a line under overseer, and
# the rows about the setting itself name their value, `unset` exporting none.
qt="ORCH_QUESTION_TOOL=\${QUESTION_TOOL:-overseer}"
[ "\${QUESTION_TOOL:-}" != unset ] || qt=""
host=""
[ -z "\${OVERSEER_HOST:-}" ] || host="ORCH_OVERSEER_HOST=\$OVERSEER_HOST"
# The reading a judging run is handed, as the turn-end hook hands it; the three
# modes that judge nothing refuse it, and NO_CONTEXT withholds it.
judging=1
for arg in "\$@"; do
  case "\$arg" in --print-launch-line|--walled-pane|--dead-pane) judging=0 ;; --) break ;; esac
done
if [ "\$judging" -eq 1 ] && [ -z "\${NO_CONTEXT:-}" ] && [ -s "$CALLER_CONTEXT_FILE" ]; then
  set -- --context "\$(cat "$CALLER_CONTEXT_FILE")" "\$@"
fi
# A fleet lane provider answering accounts from the file LANE_HOST_ACCOUNTS
# names. Such a row sets RUN_DIR to a repository too: lane-host takes its
# project from the working directory, and the work directory is none.
clock="STUB_CLOCK=" clock_path=""
if [ -n "\${VIRTUAL_CLOCK:-}" ]; then
  "$STUB_REAL_DATE" +%s > "$STUB_CLOCK"
  clock="STUB_CLOCK=$STUB_CLOCK"
  clock_path="$CLOCK_BIN:"
fi
lh=""
[ -z "\${LANE_HOST_ACCOUNTS:-}" ] || lh="ORCH_LANE_HOST=$TEST_DIR/fixtures/lane-host LANE_HOST_STUB_ACCOUNTS=\$LANE_HOST_ACCOUNTS LANE_HOST_STUB_LOG=$TMP_ROOT/host.log"
cd "\${RUN_DIR:-$TMP_ROOT/work}" && exec env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$H" PATH="\${PATH_PREFIX:+\$PATH_PREFIX:}\$clock_path$BIN:$PATH" TMUX="\$TMUX" TMUX_PANE="\$TMUX_PANE" \\
  STUB_REAL_DATE="$STUB_REAL_DATE" STUB_REAL_SLEEP="$STUB_REAL_SLEEP" \$clock \\
  LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state-\$row" \\
  \$lane \\
  ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="\${LANE_DIRS:-$H/.claude:$H/.eclaude:$H/.codex}" ORCH_OVERSEER_PREFERENCE="\$pref" \\
  ORCH_OVERSEER_SUCCESSION="\${SUCCESSION:-on}" \$settle \\
  \$hp \$cm \$ttl \$wall \$successors \$qt \$host \$lh "\${SUCCEED_BIN:-$SUCCEED}" "\$@"
ENV
# in-pane ARGS... — a caller pane's own command: draw the screen, wait until
# tmux shows it and its reading is recorded for this pane, then become the
# script.
cat > "$TMP_ROOT/in-pane" <<PANE
#!/bin/sh
cat "$TMP_ROOT/caller.screen"
until tmux capture-pane -p -t "\$TMUX_PANE" | grep -q 'fixture@example.com'; do sleep 0.1; done
until grep -qF "\"$SERVER_PID \$TMUX_PANE\"" "$OVERSEER_RECORD" 2>/dev/null; do sleep 0.1; done
exec "$TMP_ROOT/succeed-env" "\$@" > "$TMP_ROOT/in-pane.out" 2>&1
PANE
chmod +x "$TMP_ROOT/succeed-env" "$TMP_ROOT/in-pane"

# exec_succeed ROW PREFERENCE ARGS... — replaces the calling subshell with
# the script, so a background launch's pid is the script's own.
exec_succeed() {
  fixture_watch_neighbor "${SUCCEED_BIN:-$SUCCEED}"
  exec env TMUX="$TMUX_ADDR" TMUX_PANE="$CALLER_PANE" "$TMP_ROOT/succeed-env" "$@"
}

# run_succeed ROW PREFERENCE ARGS... — sets OUT (both streams) and RC.
run_succeed() {
  rm -f "${TMP_ROOT:?}"/argv.*
  RC=0
  OUT="$(exec_succeed "$@" 2>&1)" || RC=$?
}

# stage_usage_pair ROW CURRENT PRIOR GAP — write the cache record the row will
# read, then make its displaced sample explicit. PRIOR=none leaves one sample.
stage_usage_pair() {
  local row="$1" current="$2" prior="$3" gap="$4" state="$TMP_ROOT/state-$1" f now
  rm -rf -- "${state:?}"
  claude_usage "$current" 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  (cd "$TMP_ROOT/work" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$H" PATH="$BIN:$PATH" LANES_HOME="$H" \
    FIXTURE_DIR="$FIXTURE_DIR" OVERSEE_WATCH_STATE_DIR="$state" \
    ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="$H/.claude:$H/.eclaude" \
    "$SRC_DIR/lanes" list --harness claude --json --no-cache >/dev/null)
  [[ "$prior" != none ]] || return 0
  now="$(date +%s)"
  for f in "$state"/usage/*.json; do
    [[ "$(jq -r '.config_dir' "$f")" == "$H/.claude" ]] || continue
    jq --argjson at "$((now - gap))" --argjson usage "$(claude_usage "$prior" 20 5 Opus)" \
      '.prior = {fetched_at: $at, usage: $usage}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    return 0
  done
  return 1
}

# keyed KEY TEXT — the lines of TEXT from the one starting with KEY, so a row
# reads the refusal it is about past the `successor-launch` line printed before
# the window was opened.
keyed() { awk -v k="oversee-succeed: $1" 'index($0, k) == 1 { found = 1 } found' <<<"$2"; }

# Windows past index 0 as `index name;`, whether the caller's window is
# still open, and how many windows are named overseer.
layout() { tm list-windows -t fleet -F '#{window_id} #{window_index} #{window_name}' | awk -v keep="$KEEP_WINDOW" '$1 != keep { print $2, $3 }' | tr '\n' ';'; }
caller_open() { if [[ "$(tm list-windows -t fleet -F '#{window_id}')" == *"$CALLER_WINDOW"* ]]; then echo yes; else echo no; fi; }
overseers() { tm list-windows -t fleet -F '#{window_name}' | awk '$0 == "overseer"' | wc -l | tr -d ' '; }
# The lane and the arguments the harness stub was handed. `recorded_argv0`
# adds how it was INVOKED, which only the launcher rows ask about: under the
# environment prefix `env` hands the harness its bare name, and under the
# launcher form the pane runs the absolute path the judge resolved.
recorded() { if [[ -f "$TMP_ROOT/argv.$1" ]]; then grep -v '^argv0=' "$TMP_ROOT/argv.$1" | tr '\n' ';'; else printf 'none'; fi; }
recorded_argv0() { sed -n 's/^argv0=//p' "$TMP_ROOT/argv.$1" 2>/dev/null || true; }
# One brief on every harness: the plain sentence each of them reads as its
# opening prompt.
BRIEF='Read .agents/skills/orch/SKILL.md and execute the orch oversee workflow after reading the overseer handoff at tmp/handoffs/OVERSEER-HANDOFF.md'
# The launch words that turn each harness's own compaction off, which every
# successor command carries, as the harness stub records them and as the
# launch line spells the claude one for its shell.
# shellcheck disable=SC2016  # JSON, never expanded.
CLAUDE_COMPACT='--settings={"env":{"DISABLE_AUTO_COMPACT":"1"}}'
CODEX_COMPACT='-c;model_auto_compact_token_limit=9223372036854775807;-c;model_auto_compact_token_limit_scope=body_after_prefix;-c;model_post_turn_compact_threshold_percent=0'
CLAUDE_COMPACT_LINE="$(printf '%q' "$CLAUDE_COMPACT")"

# A live process that is NOT this suite's tmux server: lane_claims_read keeps a
# claim on a server it cannot enumerate while that server's process runs, so a
# foreign claim needs one to survive the prune and reach the collector.
sleep 300 &
FOREIGN_PID=$!

# A claim from that foreign server, on the pane id ROW's run will read as its
# own. lane_claims_read stores `<server pid> <pane id> <config dir> <window>`.
write_foreign_claim() { # ROW PANE CONFIG_DIR
  mkdir -p "$TMP_ROOT/state-$1/claims"
  printf '%s\t%s\t%s\t%s\t2026-09-18T00:00:00Z\n' \
    "$FOREIGN_PID" "$2" "$3" ken-foreign > "$TMP_ROOT/state-$1/claims/foreign.claim"
}

# A claim from THIS suite's tmux server on the pane ROW's run reads as its own.
# The caller's row is then the claim's own record, flagged where it already
# stands, which is the path an overseer launched as a lane takes; the appended
# row covers the other path, an overseer started by hand into an unclaimed
# window.
write_own_claim() { # ROW PANE CONFIG_DIR
  mkdir -p "$TMP_ROOT/state-$1/claims"
  printf '%s\t%s\t%s\t%s\t2026-09-18T00:00:00Z\n' \
    "$SERVER_PID" "$2" "$3" ken-own > "$TMP_ROOT/state-$1/claims/own.claim"
}

echo "=== oversee-succeed ==="

# The line every launch on a host with no readable per-process environment
# carries, between the launch and the successor-working line: the account was
# never observed there, so the deciding read names that and the launch stands.
# A row pinning the WHOLE keyed sequence of a launch carries it or not by host.
UNOBSERVED_LINE=""
lane_process_env_readable ||
  UNOBSERVED_LINE='oversee-succeed: successor-lane-unobserved reason=no-process-environment;'

# The fleet's workflow state, where a succession records the line it launched
# its successor with. `oversee-watch` reads that record back and hands it to a
# relaunch when the pane it names dies, so a run with no state to write to says
# so rather than leaving a later relaunch nothing. Every row below runs from
# $TMP_ROOT/work, which is where workflow-state resolves `tmp` to.
FLEET_STATE="$TMP_ROOT/work/tmp/workflow-state-oversee.json"
fleet_state() {
  mkdir -p "$(dirname "$FLEET_STATE")"
  printf '{"issue_id": "oversee", "overseer": {"generation": 1}}\n' > "$FLEET_STATE"
  fixture_succession_handoff "$FLEET_STATE" "$TMP_ROOT/work/tmp/handoffs/OVERSEER-HANDOFF.md"
}
recorded_line() { jq -r '.overseer.launch_line // "none"' "$FLEET_STATE" 2>/dev/null || echo unreadable; }
orec() { jq -r ".overseer.$1 // \"none\"" "$FLEET_STATE" 2>/dev/null || echo unreadable; }
fleet_state

# The owner relay consumes keyed refusal lines. Every refusal uses the same
# channel contract, including failures before a mark could be measured.
OWNER_NOTICES="$TMP_ROOT/work/tmp/lane-mail/overseer/to-overseer.jsonl"
refusal_evidence() { # KEY
  jq -nr --arg prefix "oversee-succeed: $1 " --slurpfile state "$FLEET_STATE" --slurpfile mail "$OWNER_NOTICES" '
    [$state[0].fleet_log[]? | select(.kind == "close" and .item == "overseer" and (.text | startswith($prefix)))] as $rows
    | [$mail[] | select(.kind == "notice" and .to == "owner" and (.text | startswith($prefix)))] as $notices
    | ($rows[0].text // "" | split(" ")) as $fields
    | [($rows | length),
       ([$fields[] | select(startswith("mark=")) | ltrimstr("mark=")] | first // "none"),
       ([$fields[] | select(startswith("account=")) | ltrimstr("account=")] | first // "none"),
       ([$fields[] | select(startswith("resets=")) | ltrimstr("resets=")] | first // "none"),
       ($notices | length), ($rows[0].text == $notices[0].text)] | map(tostring) | join("|")'
}
refusal_case() { # NAME SCRIPT SCENARIO
  local name="$1" script="$2" scenario="$3" screen="$MARK" ttl="" pref=claude:fable:high
  local -a args=()
  claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  case "$scenario" in
    headroom)
      screen="$UNDER_MARK"
      claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json" ;;
    lanes) ttl=forever ;;
    copilot) args=(--harness copilot) ;;
    window) pref=claude:claude-sonnet-4-5:high ;;
    check) args=(--check-marks --harness unknown) ;;
    print) args=(--print-launch-line --harness copilot) ;;
  esac
  new_caller "$screen"
  fleet_state
  : > "$OWNER_NOTICES"
  USAGE_TTL="$ttl" SUCCEED_BIN="$script" run_succeed "$name" "$pref" ${args[@]+"${args[@]}"}
}
while IFS='|' read -r scenario key status mark account resets; do
  refusal_case "refusal-$scenario" "$SUCCEED" "$scenario"
  assert_eq "$RC|$(caller_open)|$(overseers)|$(refusal_evidence "$key")" \
    "$status|yes|0|1|$mark|$account|$resets|1|true" \
    "pre-launch $key: one fleet row and one owner notice share the mark and only headroom names an account"
done <<ROWS
headroom|no-lane-qualifies|3|headroom|claude|$CLAUDE_USAGE_SESSION_RESET
copilot|copilot-account-unknown|1|unknown|none|none
lanes|lanes-failed|1|context|none|none
window|model-window-unknown|1|context|none|none
ROWS
# Dropping the pre-launch fleet row must turn the same evidence assertion red.
REFUSALCTL="$(mutant_scripts refusalctl oversee-succeed)" || exit 1
mutate_file "$REFUSALCTL/oversee-succeed" '    if ! ol_fleet_log "$dir/notice" "$dir/record" "$dir/err"; then' '    if ! :; then'
refusal_case refusal-row-control "$REFUSALCTL/oversee-succeed" headroom
assert_eq "$RC|$(refusal_evidence no-lane-qualifies)" "3|0|none|none|none|1|false" \
  "control: skipping the pre-launch row breaks the fleet and owner evidence contract"

# Refusing check and print commands still leave both channels untouched.
READONLYCTL="$(mutant_scripts refusal-readonlyctl oversee-succeed)" || exit 1
mutate_file "$READONLYCTL/oversee-succeed" '  [[ "${MODE:-}" != succeed ]] || fleet_log_refusal "$@"' '  fleet_log_refusal "$@"'
for scenario in check print; do
  key=invalid-harness
  [[ "$scenario" != print ]] || key=copilot-account-unknown
  refusal_case "readonly-$scenario" "$SUCCEED" "$scenario"
  assert_eq "$RC|$(refusal_evidence "$key")" "1|0|none|none|none|0|true" \
    "$scenario refuses without writing either channel"
  refusal_case "readonly-control-$scenario" "$READONLYCTL/oversee-succeed" "$scenario"
  assert_eq "$RC|$(refusal_evidence "$key")" "1|1|unknown|none|none|1|true" \
    "control: unconditional reporting breaks $scenario's read-only contract"
done

# The same refusal after the minute deduplication window takes lane-mail's
# owner-notice-repeated path. The owner keeps one notice and each run logs.
while IFS='|' read -r variant age; do
  script="$SUCCEED"
  if [[ "$variant" == control ]]; then
    REPEATCTL="$(mutant_scripts refusal-repeatctl oversee-succeed)" || exit 1
    mutate_file "$REPEATCTL/oversee-succeed" "        'lane-mail: duplicate id='* | 'lane-mail: owner-notice-repeated='*) ;;" "        'lane-mail: impossible='*) ;;"
    script="$REPEATCTL/oversee-succeed"
  fi
  refusal_case "refusal-repeat-$variant" "$script" headroom
  jq -c --argjson age "$age" '.at = ((.at | fromdateiso8601) - $age | todate)' "$OWNER_NOTICES" > "$OWNER_NOTICES.aged"
  mv -- "$OWNER_NOTICES.aged" "$OWNER_NOTICES"
  SUCCEED_BIN="$script" run_succeed "refusal-repeat-again-$variant" claude:fable:high
  failures="$(awk '/^oversee-succeed: owner-notice-unwritten / { n++ } END { print n+0 }' <<<"$OUT")"
  want_failures=0
  [[ "$variant" != control ]] || want_failures=1
  assert_eq "$RC|$failures|$(refusal_evidence no-lane-qualifies)" \
    "3|$want_failures|2|headroom|claude|$CLAUDE_USAGE_SESSION_RESET|1|true" \
    "repeat $variant: an owner notice already delivered leaves the refusal status and both fleet rows intact"
done <<'ROWS'
minute|0
live|210
control|210
ROWS
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
fleet_state

# record_order RECORDER — whether the --context argument was present at the
# instant RECORDER wrote the caller's record: the order in-pane relies on to
# hand the success row below its measured reading.
record_order() { # RECORDER
  (
    eval "real_$(declare -f lane_context_record)"
    lane_context_record() {
      if [[ -s "$CALLER_CONTEXT_FILE" ]]; then echo context-present; else echo context-absent; fi
      real_lane_context_record "$@"
    }
    "$1" "$MARK" %probe
  )
}
# The must-fail control: record_caller with the argument written after the
# record, the order that let the success row read context-unread.
record_first="$(declare -f record_caller | awk '
  /> "\$CALLER_CONTEXT_FILE"/ { held = $0; moved++; next }
  { print }
  /lane_context_record "/ { print held; placed++ }
  END { if (moved != 1 || placed != 1) exit 1 }' \
  | sed '1s/^record_caller /record_caller_record_first /')" \
  || { echo "fixture: record_caller has no argument write to move after its record" >&2; exit 1; }
eval "$record_first"
assert_eq "$(record_order record_caller)|$(record_order record_caller_record_first)" \
  "context-present|context-absent" \
  "the caller's --context argument exists before the record in-pane starts on, and the record-first order is seen"

# The caller at index 3 over a gap, renumber-windows off: the successor must
# start at the base index while its caller closes.
printf '%s\n' "$MARK" > "$TMP_ROOT/caller.screen"
tm kill-window -a -t "$KEEP_WINDOW"
tm move-window -r -t fleet
rm -f "${TMP_ROOT:?}"/argv.*
spec="$(tm new-window -d -t fleet:3 -P -F '#{pane_id} #{window_id} #{pane_pid}' \
  "exec '$TMP_ROOT/in-pane' success 'claude:fable:high' -- --dangerously-skip-permissions --verbose")"
read -r CALLER_PANE CALLER_WINDOW caller_pid <<<"$spec"
fixture_watch_predecessor "$SUCCEED" "$TMP_ROOT/work/tmp/workflow-state-oversee.json" "$TMP_ROOT/work" "$CALLER_PANE"
record_caller "$MARK" "$CALLER_PANE"
for _ in $(seq 1 100); do kill -0 "$caller_pid" 2>/dev/null || break; sleep 0.2; done
# Before the close that ends its own window, the run names the fleet watch it
# hands to the successor, here that none runs on the fleet state
# (oversee_succeed_watch.sh holds the handover itself).
assert_eq "$(layout)|$(caller_open)|$(grep '^oversee-succeed:' "$TMP_ROOT/in-pane.out" | sed 's/window=@[0-9]*/window=@N/; s/pane=%[0-9]*/pane=%N/; s|path=.*/tmp/workflow-state-oversee.json$|path=STATE|; s/watch-started .*/watch-started/' | tr '\n' ';')|$(recorded claude)" \
  "0 overseer;|no|oversee-succeed: successor-launch form=prefix lane=$H/.claude trust=account-config;${UNOBSERVED_LINE}oversee-succeed: watch-started;oversee-succeed: successor-working window=@N pane=%N;|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;$CLAUDE_COMPACT;--dangerously-skip-permissions;--verbose;$BRIEF;" \
  "success in the caller's own pane: successor at the base index, caller window gone"

# The record that succession wrote before the successor's first turn, over the
# registered predecessor above: runtime tmux, generation 2, the account picked, and the
# successor's own pane, which is the one the successor-working line names.
SUCC_REC_PANE="$(sed -n 's/.*successor-working window=@[0-9]* pane=\(%[0-9]*\).*/\1/p' "$TMP_ROOT/in-pane.out")"
assert_eq "runtime=$(orec runtime) generation=$(orec generation) account=$(orec account) pane=$(orec pane)" \
  "runtime=tmux generation=2 account=$H/.claude pane=$SUCC_REC_PANE" \
  "the successor record names the runtime, generation, account and successor pane"
# The same record's launch identity, read out of the command the successor was
# built with, and no pending successor: the one this launch wrote before its
# window opened is the session the record now names.
assert_eq "harness=$(orec harness) home=$(orec home) model=$(orec model) effort=$(orec effort) cwd=$(orec cwd) pending=$(orec pending)" \
  "harness=claude home=$H/.claude model=fable effort=high cwd=$(tm display-message -p -t "$SUCC_REC_PANE" '#{pane_current_path}') pending=none" \
  "the successor record carries its launch identity and drops the pending successor"

# The successor's own record carries the line it was launched with, which a
# later dead-overseer relaunch replays. The pending line written before the
# window opened is oversee_succeed_record.sh's row.
assert_eq "$(recorded_line)" \
  "env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer --model fable --effort high $CLAUDE_COMPACT_LINE --dangerously-skip-permissions --verbose '$BRIEF'" \
  "a succession records the line it launched, for a later dead-overseer relaunch"
# The succession's context arm, run from outside the caller's pane on the
# reading the turn-end hook hands it: a caller past the context mark on an
# account with room launches a successor on the context mark alone. Its
# control cuts that arm from a copy: the same caller is told it is below every
# mark and nothing launches.
new_caller "$MARK"
run_succeed walkcontext 'claude:fable:high' -- --dangerously-skip-permissions
assert_eq "$RC|$(caller_open)|$(overseers)|$(recorded claude)" \
  "0|no|1|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;$CLAUDE_COMPACT;--dangerously-skip-permissions;$BRIEF;" \
  "a caller past the context mark with account room hands over to a successor on that mark"
WALKCTL="$(mutant_scripts walkctl oversee-succeed)" || exit 1
mutate_file "$WALKCTL/oversee-succeed" '  elif [[ "$CONTEXT_STATE" == due ]]; then' '  elif false; then'
new_caller "$MARK"
SUCCEED_BIN="$WALKCTL/oversee-succeed" run_succeed walkctl 'claude:fable:high' -- --dangerously-skip-permissions
assert_eq "$RC|$(caller_open)|$(overseers)|$(sed -n 1p <<<"$OUT" | cut -d' ' -f1-2)" \
  "0|yes|0|oversee-succeed: context-below-mark" \
  "control: without the walk's context arm a caller past its context mark launches no successor"
# The successor opens on its checkout fast-forwarded to origin's head, the
# launcher's sync run for this script as for `oversee launch`
# (oversee_launch.sh holds its refusal table). Its control opens without it
# and leaves the checkout behind.
work_head() { git -C "$TMP_ROOT/work" rev-parse HEAD; }
unsynced() { grep -c "^oversee-succeed: checkout-unsynced cause=$1 path=$TMP_ROOT/work fix=[^ ]" <<<"$OUT" || true; }
WANT="$(checkout_advance)" || exit 1
new_caller "$MARK"
checkout_started_clear
run_succeed synced 'claude:fable:high'
assert_eq "$RC|$(caller_open)|$(work_head)|$(checkout_started)|$(unsynced '[^ ]*')" "0|no|$WANT|$WANT|0" \
  "a succession fast-forwards a clean checkout behind origin to origin's head before the successor opens"
SYNCCTL="$(mutant_scripts syncctl lib/overseer-launch.sh)" || exit 1
mutate_file "$SYNCCTL/lib/overseer-launch.sh" '  ol_checkout_sync "$1" || ol_checkout_notice' '  :'
BEHIND="$(work_head)"
checkout_advance >/dev/null || exit 1
new_caller "$MARK"
SUCCEED_BIN="$SYNCCTL/oversee-succeed" run_succeed syncctl 'claude:fable:high'
assert_eq "$RC|$(caller_open)|$(work_head)" "0|no|$BEHIND" \
  "control: a succession without the sync leaves the checkout behind"
# A dirty checkout: the succession goes on, on the tree as it stands, with
# this script's keyed line naming the fix, in the fleet log too.
printf 'local\n' >> "$TMP_ROOT/work/README"
fleet_state
new_caller "$MARK"
run_succeed unsynced 'claude:fable:high'
assert_eq "$RC|$(caller_open)|$(work_head)|$(unsynced dirty)|$(jq -r '[(.fleet_log // [])[] | select((.text | startswith("oversee-succeed: checkout-unsynced cause=dirty ")) and (.text | contains(" path=") | not))] | length' "$FLEET_STATE")" \
  "0|no|$BEHIND|1|1" \
  "a dirty checkout leaves the succession running and prints one keyed line naming the fix, also in the fleet log"
git -C "$TMP_ROOT/work" checkout -q -- README || exit 1
# The order's control: a launcher that syncs after the successor opens leaves
# the checkout synced once it returns, and the successor started on the tree
# behind it.
LATECTL="$(checkout_late_sync latesyncctl)" || exit 1
WANT="$(checkout_advance)" || exit 1
new_caller "$MARK"
checkout_started_clear
SUCCEED_BIN="$LATECTL/oversee-succeed" run_succeed latesyncctl 'claude:fable:high'
assert_eq "$RC|$(caller_open)|$(work_head)|$(checkout_started)" "0|no|$WANT|$BEHIND" \
  "control: a succession that syncs after the successor opens starts it on the tree behind origin"
new_caller "$MARK"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"
# A codex successor opens into the caller's own directory, which the account's
# config does not trust: the harness would stop on the folder-trust question in
# a pane nobody is at. The launch therefore runs under a CODEX_HOME of its own
# carrying that trust, so `lane=` here is that home rather than the account, and
# the route it took is on the launch line.
CALLER_CWD="$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')"
CODEX_LAUNCH_HOME="$(lane_codex_home_path "$H/.codex" "$CALLER_CWD")"
run_succeed walled 'claude:fable:high,codex:gpt-6-astra:high' -- --dangerously-skip-permissions
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)|$(recorded codex)|$(keyed successor-launch "$OUT" | sed -n 1p)|$(lane_codex_trusted "$CODEX_LAUNCH_HOME/config.toml" "$CALLER_CWD" && echo trusted || echo untrusted)" \
  "0|0 overseer;|no|none|lane=$CODEX_LAUNCH_HOME;-m;gpt-6-astra;-c;model_reasoning_effort=high;--dangerously-bypass-approvals-and-sandbox;-c;check_for_update_on_startup=false;-c;features.daemon_auto_start=false;--dangerously-bypass-hook-trust;$CODEX_COMPACT;$BRIEF;|oversee-succeed: successor-launch form=prefix lane=$H/.codex trust=launch-home|trusted" \
  "walled claude entry: codex entry picked, under a home that trusts the caller directory"
# The account and the private home that launch ran under are two fields: the
# account is what a judgement measures, the home what the account variable
# carries.
assert_eq "harness=$(orec harness) account=$(orec account) home=$(orec home) model=$(orec model) effort=$(orec effort)" \
  "harness=codex account=$H/.codex home=$CODEX_LAUNCH_HOME model=gpt-6-astra effort=high" \
  "a codex successor records its account and its private CODEX_HOME apart"
# The other side of that preparation: an account config that exists and cannot
# be read refuses the successor rather than launching it onto a config with
# every table the account was approved for gone. The caller keeps running and
# its window stands.
new_caller "$MARK"
TRUSTFAIL_CWD="$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')"
CODEX_CONFIG_SAVED="$(cat "$H/.codex/config.toml" 2>/dev/null || true)"
ln -sfn "$H/no-such-render.toml" "${H:?}/.codex/config.toml"
run_succeed trustfail 'claude:fable:high,codex:gpt-6-astra:high' -- --dangerously-skip-permissions
printf '%s\n' "$CODEX_CONFIG_SAVED" > "$H/.codex/config.toml"
assert_eq "$RC|$(caller_open)|$(overseers)|$(recorded codex)|$(keyed launch-trust-missing "$OUT" | sed -n 1p)" \
  "1|yes|0|none|oversee-succeed: launch-trust-missing lane=$H/.codex dir=$TRUSTFAIL_CWD reason=config-unreadable" \
  "an unreadable account config refuses the successor and keeps the caller"

# A NAMED entry of another harness takes the model and effort words its OWN
# row writes, its own full-bypass word, and none of the flags after --. Those
# flags are the claude caller's, each spelled for claude's CLI: codex has no
# effort flag at all, so a successor handed --effort high does not start,
# --model fable beside the -m gpt-6-astra this entry chose names a model the
# pick was never judged on, and an unrelated word such as --verbose is one
# codex need not take either.
#
# A claude caller's question-tool words are a flag codex refuses, so a codex
# entry never carries them either: it carries codex's own words exactly when
# ORCH_QUESTION_TOOL is off, which an unset setting is. One table, so the
# caller's permission switch is spelled on one line for every row.
# QUESTION_TOOL|CALLER WORDS AFTER THE PERMISSION SWITCH|LINE TAIL|WHAT
for row in \
  "overseer|--verbose||a named entry of another harness carries no caller word and replaces the caller's model, effort and permission posture" \
  "overseer|--disallowedTools=AskUserQuestion,EnterPlanMode --verbose||a claude caller's question-tool words never reach a codex successor: overseer, the codex line carries no question-tool word" \
  "unset|--disallowedTools=AskUserQuestion,EnterPlanMode --verbose|;-c;features.default_mode_request_user_input=false|a claude caller's question-tool words never reach a codex successor: unset, the codex line carries codex's own words and not claude's" \
  "off|--disallowedTools=AskUserQuestion,EnterPlanMode --verbose|;-c;features.default_mode_request_user_input=false|a claude caller's question-tool words never reach a codex successor: off, the codex line carries codex's own words and not claude's" \
  ; do
  IFS='|' read -r row_value row_words row_tail row_what <<<"$row"
  new_caller "$MARK"
  STRIP_CWD="$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')"
  STRIP_HOME="$(lane_codex_home_path "$H/.codex" "$STRIP_CWD")"
  # shellcheck disable=SC2086  # a row's words are its own, split on purpose.
  QUESTION_TOOL="$row_value" run_succeed "stripflags$row_value" 'codex:gpt-6-astra:high' -- --model fable --effort high --dangerously-skip-permissions $row_words
  assert_eq "$RC|$(overseers)|$(recorded claude)|$(recorded codex)" \
    "0|1|none|lane=$STRIP_HOME;-m;gpt-6-astra;-c;model_reasoning_effort=high;--dangerously-bypass-approvals-and-sandbox;-c;check_for_update_on_startup=false;-c;features.daemon_auto_start=false;--dangerously-bypass-hook-trust;$CODEX_COMPACT$row_tail;$BRIEF;" \
    "$row_what"
  if [[ "$row_value:$row_words" == overseer:--verbose ]]; then
    ENTRY_CODEX_LINE="$(recorded_line)"
  fi
done

new_caller "$MARK"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 20 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed same-harness-restricted 'claude:fable:high' -- \
  --model caller-model --effort low --permission-mode dontAsk --verbose
assert_eq "$RC|$(overseers)|$(recorded claude)" \
  "0|1|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$CLAUDE_COMPACT;--permission-mode;dontAsk;--verbose;$BRIEF;" \
  "a same-harness named entry preserves the restricted permission spelling"
ENTRY_SAME_LINE="$(recorded_line)"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"

# The reverse crossing reads the same table in the other direction. No codex
# caller word crosses, and the claude entry writes the permission word its own
# launch accepts.
new_caller "$CODEX_SCREEN" 'Context 48% left'
codex_usage 95 > "$FIXTURE_DIR/.codex.json"
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
CALLER_LANE="CODEX_HOME=$H/.codex" run_succeed codex-to-claude 'claude:fable:high' -- \
  -c check_for_update_on_startup=false -c features.daemon_auto_start=false --dangerously-bypass-hook-trust -m caller-model -c model_reasoning_effort=high \
  --dangerously-bypass-approvals-and-sandbox --verbose
codex_usage 20 > "$FIXTURE_DIR/.codex.json"
assert_eq "$RC|$(overseers)|$(recorded claude)|$(recorded codex)" \
  "0|1|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;--dangerously-skip-permissions;$CLAUDE_COMPACT;$BRIEF;|none" \
  "a codex caller picking claude carries claude's permission word and no codex word, its update setting included"
ENTRY_CLAUDE_LINE="$(recorded_line)"

# Supervisors request one entry instead of rebuilding the live launch line.
# The fleet record and harness argv stay unchanged: print prepares trust only.
ENTRYCTL="$(mutant_scripts entryctl oversee-succeed)" || exit 1
mutate_file "$ENTRYCTL/oversee-succeed" '    if (( ENTRY_GIVEN )); then' '    if false; then'
ENTRYCOUNTCTL="$(mutant_scripts entrycountctl oversee-succeed)" || exit 1
mutate_file "$ENTRYCOUNTCTL/oversee-succeed" '      (( OL_NAMED == 1 ))' '      (( OL_NAMED >= 1 ))'
ENTRYMODECTL="$(mutant_scripts entrymodectl oversee-succeed)" || exit 1
mutate_file "$ENTRYMODECTL/oversee-succeed" \
  '(( ! ENTRY_GIVEN )) || [[ "$MODE" == print ]] || die mode-conflict "mode=$MODE" "entry=$ENTRY_ARG"' ':'
# NAME|CALLER|ENTRY|FLAGS|MODE|CODEX USAGE|EXIT|KEYS|LINE|SCRIPT (a control)
for row in \
  "claude-codex|claude|codex:gpt-6-astra:high|--dangerously-skip-permissions --verbose|--print-launch-line|20|0||$ENTRY_CODEX_LINE|" \
  "codex-claude|codex|claude:fable:high|--dangerously-bypass-approvals-and-sandbox --verbose|--print-launch-line|20|0||$ENTRY_CLAUDE_LINE|" \
  "same-harness|claude|claude:fable:high|--permission-mode dontAsk --verbose|--print-launch-line|20|0||$ENTRY_SAME_LINE|" \
  "walled|claude|codex:gpt-6-astra:high|--dangerously-skip-permissions --verbose|--print-launch-line|95|3|no-lane-qualifies;||" \
  "restricted|claude|codex:gpt-6-astra:high|--permission-mode dontAsk|--print-launch-line|20|3|entry-permission-untransferable;no-lane-qualifies;||" \
  "malformed|claude|codex:bad model:high|--dangerously-skip-permissions|--print-launch-line|20|1|invalid-preference;||" \
  "two|claude|codex:gpt-6-astra:high,claude:fable:high|--dangerously-skip-permissions|--print-launch-line|20|1|invalid-preference;||" \
  "empty|claude||--dangerously-skip-permissions|--print-launch-line|20|1|invalid-preference;||" \
  "wall-mode|claude|codex:gpt-6-astra:high|--dangerously-skip-permissions|--walled-pane %9|20|1|mode-conflict;||" \
  "check-mode|claude|codex:gpt-6-astra:high||--check-marks|20|1|mode-conflict;||" \
  "caller-control|claude|codex:gpt-6-astra:high|--dangerously-skip-permissions --verbose|--print-launch-line|20|0||$ENTRY_CODEX_LINE|$ENTRYCTL/oversee-succeed" \
  "count-control|claude|codex:gpt-6-astra:high,claude:fable:high|--dangerously-skip-permissions|--print-launch-line|20|1|invalid-preference;||$ENTRYCOUNTCTL/oversee-succeed" \
  "mode-control|claude|codex:gpt-6-astra:high||--check-marks|20|1|mode-conflict;||$ENTRYMODECTL/oversee-succeed"; do
  IFS='|' read -r row_name row_caller row_entry row_flags row_mode row_usage row_rc row_keys row_line row_script <<<"$row"
  fleet_state
  row_lane="CLAUDE_CONFIG_DIR=$H/.claude"
  if [[ "$row_caller" == codex ]]; then
    new_caller "$CODEX_SCREEN" 'Context 48% left'
    row_lane="CODEX_HOME=$H/.codex"
  else
    new_caller "$MARK"
  fi
  claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  [[ "$row_name" != same-harness ]] || claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  claude_usage 20 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
  codex_usage "$row_usage" > "$FIXTURE_DIR/.codex.json"
  # Remove the earlier live launch's trust so this print must prepare it.
  if [[ "$row_name" == codex-claude ]]; then
    jq --arg d "$TMP_ROOT/work" 'del(.projects[$d])' "$H/.claude/.claude.json" > "$TMP_ROOT/trust.json"
    mv -- "$TMP_ROOT/trust.json" "$H/.claude/.claude.json"
  elif [[ "$row_name" == claude-codex ]]; then
    rm -rf -- "$STRIP_HOME"
  fi
  row_state="$(cat "$FLEET_STATE")"
  row_layout="$(tm list-windows -t fleet -F '#{window_id} #{window_index}')"
  rm -f "${TMP_ROOT:?}"/argv.*
  RC=0
  # shellcheck disable=SC2086  # table-owned mode and flag words are argv.
  (CALLER_LANE="$row_lane" SUCCEED_BIN="${row_script:-$SUCCEED}" exec_succeed "entry-$row_name" 'copilot:ignored:high' \
    $row_mode --entry "$row_entry" -- $row_flags) > "$TMP_ROOT/entry.out" 2> "$TMP_ROOT/entry.err" || RC=$?
  OUT="$(cat "$TMP_ROOT/entry.out")"
  row_got_keys="$(sed -n 's/^oversee-succeed: \([^ ]*\).*/\1/p' "$TMP_ROOT/entry.err" | tr '\n' ';')"
  row_got="$RC|$row_got_keys|$OUT|$(tm list-windows -t fleet -F '#{window_id} #{window_index}')|$(cat "$FLEET_STATE")|$(recorded claude)|$(recorded codex)"
  row_want="$row_rc|$row_keys|$row_line|$row_layout|$row_state|none|none"
  if [[ -n "$row_script" ]]; then
    if (FAIL=0; assert_eq "$row_got" "$row_want" "$row_name"; (( FAIL == 0 ))) > "$TMP_ROOT/entry-control.out"; then
      fail "$row_name: the entry contract accepts the mutant"
    else
      pass "$row_name: the entry contract rejects the mutant"
    fi
  else
    assert_eq "$row_got" "$row_want" "print entry $row_name" "$TMP_ROOT/entry.err"
  fi
  case "$row_name" in
    walled|restricted)
      row_walled=0
      [[ "$row_name" != walled ]] || row_walled=1
      assert_eq "$(sed -n 's/^oversee-succeed: no-lane-qualifies //p' "$TMP_ROOT/entry.err")" \
        "entries=1 fallback=none walled=$row_walled unmeasured=0 mark=none" "print entry $row_name refuses without a caller fallback" ;;
    claude-codex)
      assert_eq "$(lane_codex_trusted "$STRIP_HOME/config.toml" "$TMP_ROOT/work" && echo trusted || echo untrusted)" \
        trusted 'print entry prepares the picked codex home trust' ;;
    codex-claude)
      assert_eq "$(jq -r --arg d "$TMP_ROOT/work" '.projects[$d].hasTrustDialogAccepted' "$H/.claude/.claude.json")" \
        true 'print entry prepares the picked claude account trust' ;;
  esac
done
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
codex_usage 20 > "$FIXTURE_DIR/.codex.json"

# An alternate full-bypass spelling has the same meaning across harnesses.
new_caller "$MARK"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"
codex_usage 20 > "$FIXTURE_DIR/.codex.json"
ALT_CWD="$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')"
ALT_HOME="$(lane_codex_home_path "$H/.codex" "$ALT_CWD")"
CALLER_LANE="CLAUDE_CONFIG_DIR=$H/.claude" run_succeed alternate-bypass 'codex:gpt-6-astra:high' -- \
  --model fable --effort high --permission-mode bypassPermissions --verbose
assert_eq "$RC|$(overseers)|$(recorded codex)" \
  "0|1|lane=$ALT_HOME;-m;gpt-6-astra;-c;model_reasoning_effort=high;--dangerously-bypass-approvals-and-sandbox;-c;check_for_update_on_startup=false;-c;features.daemon_auto_start=false;--dangerously-bypass-hook-trust;$CODEX_COMPACT;$BRIEF;" \
  "an alternate claude full-bypass spelling transfers to codex, and no other caller word does"

# Permission modes without exact full-bypass equivalence skip the cross-harness
# entry before its pick: nothing of that harness is launched, and the walk goes
# on to the caller's own harness, whose one other account is walled here.
cross_permission_refuses() { # NAME FLAGS...
  local name="$1"
  shift
  new_caller "$MARK"
  fleet_state
  claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  codex_usage 20 > "$FIXTURE_DIR/.codex.json"
  run_succeed "$name" 'codex:gpt-6-astra:high' -- --model fable --effort high "$@"
  assert_eq "$RC|$(keyed entry-permission-untransferable "$OUT" | sed -n 1p)|$(overseers)|$(recorded codex)" \
    "3|oversee-succeed: entry-permission-untransferable entry=codex:gpt-6-astra:high source=claude target=codex|0|none" \
    "$name skips the cross-harness entry"
}
cross_permission_refuses restricted --permission-mode dontAsk
cross_permission_refuses absent
cross_permission_refuses unknown --permission-mode plan
# A full bypass beside a second permission word is a mix this reader cannot
# translate: which word the caller's harness honors is that harness's rule.
cross_permission_refuses mixed-restricted --dangerously-skip-permissions --permission-mode dontAsk
cross_permission_refuses mixed-unknown --dangerously-skip-permissions --permission-mode plan
cross_permission_refuses mixed-attached --dangerously-skip-permissions --permission-mode=plan
cross_permission_refuses mixed-double --dangerously-skip-permissions --permission-mode bypassPermissions

new_caller "$CODEX_SCREEN" 'Context 48% left'
fleet_state
codex_usage 95 > "$FIXTURE_DIR/.codex.json"
claude_usage 20 20 5 Opus > "$FIXTURE_DIR/.claude.json"
CALLER_LANE="CODEX_HOME=$H/.codex" run_succeed codex-restricted 'claude:fable:high' -- \
  -m caller-model -c model_reasoning_effort=high --approve-for-me
assert_eq "$RC|$(keyed entry-permission-untransferable "$OUT" | sed -n 1p)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: entry-permission-untransferable entry=claude:fable:high source=codex target=claude|0|none" \
  "codex approve-for-me skips the cross-harness entry"

new_caller "$CODEX_SCREEN" 'Context 48% left'
fleet_state
CALLER_LANE="CODEX_HOME=$H/.codex" run_succeed codex-never 'claude:fable:high' -- \
  -m caller-model -c model_reasoning_effort=high -a never
assert_eq "$RC|$(keyed entry-permission-untransferable "$OUT" | sed -n 1p)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: entry-permission-untransferable entry=claude:fable:high source=codex target=claude|0|none" \
  "codex ask-for-approval never skips the cross-harness entry"

new_caller "$CODEX_SCREEN" 'Context 48% left'
fleet_state
CALLER_LANE="CODEX_HOME=$H/.codex" run_succeed codex-mixed 'claude:fable:high' -- \
  -m caller-model -c model_reasoning_effort=high --dangerously-bypass-approvals-and-sandbox -a never
assert_eq "$RC|$(keyed entry-permission-untransferable "$OUT" | sed -n 1p)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: entry-permission-untransferable entry=claude:fable:high source=codex target=claude|0|none" \
  "codex full bypass beside ask-for-approval never skips the cross-harness entry"
codex_usage 20 > "$FIXTURE_DIR/.codex.json"

# The caller entry is the inverse contract. It names no choices of its own and
# carries this session's words whole, including an alternate accepted
# permission spelling.
new_caller "$MARK"
run_succeed callerflags '' -- --model fable --effort high --permission-mode bypassPermissions --verbose
assert_eq "$RC|$(overseers)|$(recorded claude)" \
  "0|1|lane=$H/.claude;-n;overseer;$CLAUDE_COMPACT;--model;fable;--effort;high;--permission-mode;bypassPermissions;--verbose;$BRIEF;" \
  "the caller entry carries the caller's model, effort and permission words whole"
new_caller "$MARK"
run_succeed attachedcaller '' -- --model=sonnet --effort high --permission-mode bypassPermissions --verbose
assert_eq "$RC|$(overseers)|$(recorded claude)" \
  "0|1|lane=$H/.claude;-n;overseer;$CLAUDE_COMPACT;--model=claude-sonnet-5-5;--effort;high;--permission-mode;bypassPermissions;--verbose;$BRIEF;" \
  "a caller's attached sonnet model word is carried as the model id"

claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"

# The table's two halves, pinned against each other rather than against the argv
# above: this script WRITES a successor's flags with launch_choice_write, and
# open-terminal READS a launch's choices back with launch_choice_value and
# launch_choice_effort. A word one half writes that the other cannot find is a
# successor whose model and effort the launch gate never sees, and every literal
# row in this suite would still pass. Each row is written and read back here,
# the harnesses this suite never launches included; a row with no effort flag
# writes the model alone and reads back no effort. Plain model ids only: the
# writer quotes its values for the shell it is building a command in, and the
# reader is handed argv a shell has already split.
roundtrip() { # HARNESS MODEL EFFORT — the model and effort read back, `;`-joined
  local words
  words="$(launch_choice_write "$1" "$2" "$3")"
  printf '%s;%s\n' \
    "$(launch_choice_value "$(launch_choice_model_spellings "$1")" "$words")" \
    "$(launch_choice_effort "$1" "$words" '')"
}
assert_eq "$(roundtrip claude fable high)|$(roundtrip codex gpt-6-astra high)|$(roundtrip opencode grok-5 high)|$(roundtrip pi sonnet high)|$(roundtrip copilot claude-fable-5.1 high)" \
  "fable;high|gpt-6-astra;high|grok-5;|sonnet;high|claude-fable-5.1;high" \
  "every row's written words read back as the model and effort they were written from"
# A claude successor on the sonnet or haiku alias is written with the model id,
# which no ANTHROPIC_DEFAULT_*_MODEL pin moves; another harness keeps its word.
assert_eq "$(roundtrip claude sonnet high)|$(roundtrip claude haiku high)|$(roundtrip pi sonnet high)" \
  "claude-sonnet-5-5;high|claude-haiku-4-5;high|sonnet;high" "a claude alias is written as its model id"
IDCTL="$(mutant_scripts idctl lib/lane-launch.sh)" || exit 1
mutate_file "$IDCTL/lib/lane-launch.sh" '$(printf %q "$(launch_choice_model_id "$1" "$2")")' '$(printf %q "$2")'
assert_eq "$(source "$IDCTL/lib/lane-launch.sh"; roundtrip claude sonnet high)" "sonnet;high" \
  "control: a writer that names the model as given writes the bare alias"

# Control: the reader answers from the row's own spellings. The same launches
# with a character in front of every word read back neither choice, so the row
# above passes because the reader found what the writer wrote rather than
# because it hands back whatever value sits beside any word.
misspelt() { # HARNESS MODEL EFFORT — the same, read back from words no row names
  local out="" word
  local -a tokens=()
  read -r -a tokens <<<"$(launch_choice_write "$1" "$2" "$3")"
  for word in ${tokens[@]+"${tokens[@]}"}; do out="$out x$word"; done
  printf '%s;%s\n' \
    "$(launch_choice_value "$(launch_choice_model_spellings "$1")" "$out")" \
    "$(launch_choice_effort "$1" "$out" '')"
}
assert_eq "$(misspelt claude fable high)|$(misspelt codex gpt-6-astra high)|$(misspelt opencode grok-5 high)|$(misspelt pi sonnet high)|$(misspelt copilot claude-fable-5.1 high)" \
  ";|;|;|;|;" \
  "control: those words spelt as ones no row names read back neither choice"

# The same table's effort spellings, which open-terminal prints in its
# launch-effort-missing refusal and whose EMPTINESS is that launcher's whole
# answer to "is this launch asked for an effort at all". An accessor that handed
# back the `-` sentinel would print it in that refusal and ask a harness with no
# effort flag for one; one that answered for a harness the table does not name
# would refuse every custom launch. Both are pinned here, beside the row list
# they are read from.
assert_eq "$(launch_choice_effort_spellings claude)|$(launch_choice_effort_spellings codex)|$(launch_choice_effort_spellings pi)|$(launch_choice_effort_spellings copilot)|$(launch_choice_effort_spellings opencode)|$(launch_choice_effort_spellings nosuch)|$(launch_choice_effort_spellings '')" \
  "--effort|model_reasoning_effort=|--thinking|--reasoning-effort|||" \
  "the effort spellings accessor answers each row's list, and nothing for a flagless or unnamed harness"

permission_write_status() {
  local rc=0
  launch_choice_permission_write "$1" >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}
assert_eq "$(launch_choice_permission_write claude)|$(launch_choice_permission_write codex)|$(launch_choice_permission_write copilot)|$(permission_write_status opencode)|$(permission_write_status nosuch)" \
  "--dangerously-skip-permissions|--dangerously-bypass-approvals-and-sandbox|--allow-all|1|1" \
  "the permission writer answers required rows and refuses sentinel and unknown rows"
assert_eq "$(launch_choice_transfer_permission_spellings claude)|$(launch_choice_transfer_permission_spellings codex)|$(launch_choice_transfer_permission_spellings copilot)" \
  "--dangerously-skip-permissions --permission-mode=bypassPermissions|--dangerously-bypass-approvals-and-sandbox|--allow-all --yolo" \
  "the transfer set excludes restricted unattended modes, and copilot's tools-only word among them"
transferable_status() { # HARNESS TEXT
  local rc=0
  launch_choice_permission_transferable "$1" "$2" || rc=$?
  printf '%s\n' "$rc"
}
assert_eq "$(transferable_status claude '--model fable --dangerously-skip-permissions --verbose')|$(transferable_status claude '--permission-mode bypassPermissions')|$(transferable_status claude '--dangerously-skip-permissions --permission-mode dontAsk')|$(transferable_status claude '--dangerously-skip-permissions --permission-mode plan')|$(transferable_status claude '--permission-mode dontAsk')|$(transferable_status claude '--model fable')|$(transferable_status codex '--dangerously-bypass-approvals-and-sandbox -a never')|$(transferable_status opencode '--model x')|$(transferable_status copilot '--allow-all --context long_context')|$(transferable_status copilot '--yolo')|$(transferable_status copilot '--allow-all-tools')|$(transferable_status copilot '--allow-all --yolo')" \
  "0|0|1|1|1|1|1|1|0|0|1|1" \
  "the transfer judge admits one full bypass alone and refuses a mix, a restricted word, and nothing; copilot's tools-only word is restricted"

# A caller below the lane reserve still has room at its overseer mark.
SEAT_RECORD="$("$SRC_DIR/workflow-state" --state-dir "$TMP_ROOT/work/tmp" get oversee '.overseer // {}')"
"$SRC_DIR/workflow-state" --state-dir "$TMP_ROOT/work/tmp" set oversee overseer "$(jq -nc --arg a "$H/.claude" '{account:$a}')" >/dev/null
new_known_claude_caller 'Seat reserve fixture'
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
run_succeed seatreserve '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: account-below-mark headroom=40" \
  "an overseer on its seat at 40 percent room keeps its own mark"
RESERVECTL="$(mutant_scripts seatreservectl oversee-succeed)" || exit 1
# shellcheck disable=SC2016
mutate_file "$RESERVECTL/oversee-succeed" '--harness "$CALLER_ACCOUNT_HARNESS" --for-overseer' '--harness "$CALLER_ACCOUNT_HARNESS"'
SUCCEED_BIN="$RESERVECTL/oversee-succeed" run_succeed seatreservectl '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-reached kind=headroom value=40 mark=$TRIGGER succession=on account=claude resets=$CLAUDE_USAGE_SESSION_RESET" \
  "control: omitting --for-overseer wrongly fires on the seat reserve"
"$SRC_DIR/workflow-state" --state-dir "$TMP_ROOT/work/tmp" set oversee overseer "$SEAT_RECORD" >/dev/null
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"

# The account mark, with the context well under the context mark: the caller's
# own account is at headroom 5 and the successor goes to the claude lane
# `lanes pick` names above the trigger, never back onto the walled one.
new_caller "$UNDER_MARK"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed headroom 'claude:fable:high'
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|0 overseer;|no|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$CLAUDE_COMPACT;$BRIEF;" \
  "account headroom under the trigger: succession fires under the context mark, on the picked lane"

# The empty preference keeps the caller's own harness and passes no model or
# effort flag; at the account mark it still leaves the account that ran out.
new_caller "$UNDER_MARK"
run_succeed headroom-caller '' -- --verbose
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|0 overseer;|no|lane=$H/.eclaude;-n;overseer;$CLAUDE_COMPACT;--verbose;$BRIEF;" \
  "empty preference at the account mark: the caller's own account is left behind"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"

# Every account at or below the trigger: the wall is a refusal naming the
# caller's own account and when its binding bucket frees up, not a silent park.
new_caller "$UNDER_MARK"
codex_usage 95 > "$FIXTURE_DIR/.codex.json"
run_succeed headroom-wall 'claude:fable:high,codex:gpt-6-astra:high' -- "$BYPASS"
codex_usage 20 > "$FIXTURE_DIR/.codex.json"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)|$(recorded codex)" \
  "3|oversee-succeed: no-lane-qualifies entries=2 fallback=claude walled=5 unmeasured=0 mark=headroom account=claude resets=$CLAUDE_USAGE_SESSION_RESET|yes|0|none|none" \
  "every account under the trigger: refusal names the account and its reset"
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"

# The builder turns a successor's compaction off only where an adapter names its
# model's window, so an entry whose claude model has none would open a successor
# that compacts rather than hands off: the same setting to fix, ending the run
# before any window opens. The caller's own entry is judged on the model its
# flags carry, so such an overseer with an empty preference is refused too.
new_caller "$MARK"
run_succeed nowindow 'claude:claude-sonnet-4-6:high,codex:gpt-6-astra:high'
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded codex)" \
  "1|oversee-succeed: model-window-unknown entry=claude:claude-sonnet-4-6:high model=claude-sonnet-4-6|yes|0|none" \
  "an entry whose claude model has no window refuses model-window-unknown and stops the walk"
new_caller "$MARK"
run_succeed sonnetcaller '' -- --model claude-sonnet-4-6 --effort high
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)" \
  "1|oversee-succeed: model-window-unknown entry=caller model=claude-sonnet-4-6|yes|0" \
  "an overseer on a model with no window and an empty preference is refused on its own entry"

# An overseer started by hand names no account in its environment, and the one
# it is spending is the harness's own default. The caller entry launches its
# successor THERE, read through the same lib/lane-context.sh owner that measured
# the room this succession turned on, rather than with no prefix at all — which
# left the successor to take whatever account the tmux server hands a new pane,
# never the one judged. The pane runs a harness-named process, which is what
# lets that owner name the account from the default alone.
new_caller "$MARK" '(fixture@example.com)' "cat '$TMP_ROOT/caller.screen'; exec '$BIN/hclaude' 100000"
CALLER_LANE=none run_succeed callerdefault ''
assert_eq "$RC|$(caller_open)|$(keyed successor-launch "$OUT" | sed -n 1p)|$(recorded claude)" \
  "0|no|oversee-succeed: successor-launch form=prefix lane=$H/.claude trust=preapproved|lane=$H/.claude;-n;overseer;$CLAUDE_COMPACT;$BRIEF;" \
  "a caller entry naming no account variable launches on the account its room was measured on"

# The same refusal from a CODEX overseer. Its account's reset arrives from the
# harness as a Unix epoch, and the field must name a time in the one spelling a
# claude overseer prints, not an integer the operator has to convert.
new_caller "$CODEX_SCREEN" 'Context 48% left'
codex_usage 95 > "$FIXTURE_DIR/.codex.json"
CALLER_LANE="CODEX_HOME=$H/.codex" run_succeed codexwall 'codex:gpt-6-astra:high'
codex_usage 20 > "$FIXTURE_DIR/.codex.json"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded codex)" \
  "3|oversee-succeed: no-lane-qualifies entries=1 fallback=codex walled=2 unmeasured=0 mark=headroom account=codex resets=2026-07-25T17:20:00Z|yes|0|none" \
  "a codex overseer's refusal names its reset as a time, not an epoch"

# The account judged is the one this session's own environment names, and a
# claim is not that answer: pane ids restart at %0 on every tmux server, so a
# claim from another server can carry this pane's number while naming an
# unrelated account. Here that foreign account holds 5 percent headroom and the
# caller's own holds 80; reading the claim would succeed an overseer with room.
new_caller "$UNDER_MARK"
write_foreign_claim foreign-pane "$CALLER_PANE" "$H/.eclaude"
run_succeed foreign-pane 'claude:fable:high'
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=80|0|none" \
  "a foreign server's claim on the caller's pane number does not name the judged account"

# An account judge that cannot answer says nothing about this account: the run
# reports no headroom, the context mark decides alone, and the cause rides the
# message rather than ending the run. A usage TTL that is not a whole number of
# seconds is what `lanes` refuses before it measures anything.
new_caller "$UNDER_MARK"
USAGE_TTL=forever run_succeed lanesfail 'claude:fable:high'
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=unreadable|0|none" \
  "an unanswerable account judge leaves the account mark unfired, not the run refused"

# A preference naming another harness, every account of it walled. The walk
# does not end there: it falls through to the fleet-wide sweep of the CALLER'S
# harness, whose account holds 80 percent headroom, and the successor opens on
# it. Before the fallback was unconditional this one-entry preference refused
# with nine claude accounts unexamined, which is the fleet this was measured on.
new_caller "$MARK"
codex_usage 95 > "$FIXTURE_DIR/.codex.json"
run_succeed crossharness 'codex:gpt-6-astra:high' -- "$BYPASS"
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)|$(recorded codex)" \
  "0|0 overseer;|no|lane=$H/.claude;-n;overseer;$CLAUDE_COMPACT;$BYPASS;$BRIEF;|none" \
  "a one-entry preference whose harness is walled falls through to the caller-harness sweep"

# The must-fail inverse of that row, on the same fixture: with the fallback
# entry never appended, the walk is the preference and nothing else, so the one
# walled codex entry refuses and every claude account stands unexamined. The
# default succession's one control.
NOFALLBACK="$(mutant_scripts nofallback oversee-succeed)" || exit 1
mutate_file "$NOFALLBACK/oversee-succeed" '  ENTRIES+=(caller)' ''
new_caller "$MARK"
SUCCEED_BIN="$NOFALLBACK/oversee-succeed" run_succeed nofallback 'codex:gpt-6-astra:high' -- "$BYPASS"
codex_usage 20 > "$FIXTURE_DIR/.codex.json"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: no-lane-qualifies entries=1 fallback=none walled=1 unmeasured=0 mark=context|yes|0|none" \
  "control: without the fallback the same preference refuses with the caller's harness unwalked"

# SCHED_SLACK — the seconds a loaded runner adds to a figure taken off the
# clock, over whatever the script under test decided. Every wait below is
# counted in whole seconds and ends on a `sleep 1`, so a runner late to
# schedule the last iteration moves the figure by one while the budgeting
# stands still, and the macOS runner is regularly that late. A row pinning the
# exact second therefore pins the runner's load, and reddens a gate every
# branch and every orch pull request must pass. Each row below pins the
# interval its claim is about instead. Lateness is the whole of what this pays
# for: a row measuring wall clock around a whole run carries work the script
# did besides waiting, and names its own term for that.
SCHED_SLACK=2

# The refusal reports how long the run waited, and the budget it spent is what
# that figure is about: never less than --wait-secs, since the loop abandons
# only once the budget is gone, and never more than a late schedule can add.
IDLE_WAIT=2
# idle_log — the fleet log rows the refusal left, `kind item text`, its window
# and wait normalized.
idle_log() { jq -r '(.fleet_log // [])[] | "\(.kind) \(.item) \(.text)"' "$FLEET_STATE" | sed 's/window=@[0-9]*/window=@N/; s/waited=[0-9]*/waited=N/'; }
new_caller "$MARK"
fleet_state
tm swap-window -d -s "$CALLER_WINDOW" -t "$KEEP_WINDOW"
IDLE_LAYOUT="$(tm list-windows -t fleet -F '#{window_id} #{window_index}')"
touch "$TMP_ROOT/idle"
VIRTUAL_CLOCK=1 run_succeed idle 'claude:fable:high' --wait-secs "$IDLE_WAIT"
rm -f "$TMP_ROOT/idle"
idle_waited="$(keyed successor-not-working "$OUT" | sed -n 1p | sed 's/.*waited=//')"
idle_budget="$(in_range spent "$idle_waited" "$IDLE_WAIT" "$((IDLE_WAIT + SCHED_SLACK))")"
assert_eq "$RC|$(keyed successor-not-working "$OUT" | sed -n 1p | sed 's/window=@[0-9]*/window=@N/; s/waited=[0-9]*/waited=N/')|$idle_budget|$(grep -cF 'FIXTURE successor startup waiting' <<<"$OUT")|$(caller_open)|$(overseers)|$(grep -c '^oversee-succeed: watch-' <<<"$OUT")|$(idle_log)" \
  "1|oversee-succeed: successor-not-working window=@N waited=N|spent|1|yes|0|0|close overseer oversee-succeed: successor-not-working window=@N waited=N mark=context" \
  "never working: refused after its whole budget, caller kept, successor closed, no watch handed over, the refusal in the fleet log"
assert_eq "$(tm list-windows -t fleet -F '#{window_id} #{window_index}')" "$IDLE_LAYOUT" \
  "an abandoned succession restores the base-index caller and unrelated windows"
# Its control: an abandon that writes no fleet log row leaves the session that
# reads the log next with no word that the succession failed.
IDLECTL="$(mutant_scripts idlectl oversee-succeed)" || exit 1
mutate_file "$IDLECTL/oversee-succeed" '    if ! ol_fleet_log "$dir/notice" "$dir/record" "$dir/err"; then' '    if ! :; then'
new_caller "$MARK"
fleet_state
touch "$TMP_ROOT/idle"
VIRTUAL_CLOCK=1 SUCCEED_BIN="$IDLECTL/oversee-succeed" run_succeed idlectl 'claude:fable:high' --wait-secs "$IDLE_WAIT"
rm -f "${TMP_ROOT:?}/idle"
assert_eq "$RC|$(keyed successor-not-working "$OUT" | sed -n 1p | cut -d' ' -f1-2)|$(idle_log)" \
  "1|oversee-succeed: successor-not-working|" \
  "control: an abandon that skips the fleet log row leaves no row"
# A fleet log that refuses the row: the refusal still closes the successor,
# keeps the caller and exits 1, and the notice names the refusal and the step
# after the refusal's own line. The stand-in refuses `append-file` alone, so
# every record write the succession makes still lands.
LOGFAIL="$(mutant_scripts logfail)" || exit 1
rm -f -- "${LOGFAIL:?}/workflow-state"
cat > "$LOGFAIL/workflow-state" <<STUB
#!/usr/bin/env bash
[[ "\$1" != append-file ]] || { echo 'fixture: append refused' >&2; exit 1; }
exec "$SRC_DIR/workflow-state" "\$@"
STUB
chmod +x "$LOGFAIL/workflow-state"
new_caller "$MARK"
fleet_state
touch "$TMP_ROOT/idle"
VIRTUAL_CLOCK=1 SUCCEED_BIN="$LOGFAIL/oversee-succeed" run_succeed logfail 'claude:fable:high' --wait-secs "$IDLE_WAIT"
rm -f "${TMP_ROOT:?}/idle"
assert_eq "$RC|$(grep -e '^oversee-succeed: fleet-log-unwritten ' -e '^oversee-succeed: successor-not-working ' -e '^fixture: ' <<<"$OUT" | sed 's/window=@[0-9]*/window=@N/; s/waited=[0-9]*/waited=N/' | tr '\n' ';')|$(caller_open)|$(overseers)|$(idle_log)" \
  "1|oversee-succeed: successor-not-working window=@N waited=N;oversee-succeed: fleet-log-unwritten key=successor-not-working step=append;fixture: append refused;|yes|0|" \
  "a fleet log that refuses the row leaves the refusal standing: successor closed, caller kept, the notice keyed"

# The wait asks the turn-in-flight predicate, not the lane_state judge beside
# it. A successor drawing a dialog line in its very first turn is a launched
# successor, and the judge would call that pane `asking` — not `working` — and
# abandon a succession that had in fact taken.
new_caller "$MARK"
touch "$TMP_ROOT/asking"
run_succeed asking 'claude:fable:high'
rm -f "$TMP_ROOT/asking"
assert_eq "$RC|$(layout)|$(caller_open)" \
  "0|0 overseer;|no" \
  "a first turn that also prints a dialog line is a launched successor, not an abandoned one"

# A shell tool that times out sends TERM mid-wait. The harness stub writes its
# argv only once the launch is typed, which is after the traps are set.
new_caller "$MARK"
touch "$TMP_ROOT/idle"
rm -f "${TMP_ROOT:?}"/argv.*
( exec_succeed interrupted 'claude:fable:high' --wait-secs 30 ) > "$TMP_ROOT/interrupted.out" 2>&1 &
succ_pid=$!
for _ in $(seq 1 50); do [[ ! -f "$TMP_ROOT/argv.claude" ]] || break; sleep 0.2; done
kill -TERM "$succ_pid"
RC=0
wait "$succ_pid" || RC=$?
rm -f "${TMP_ROOT:?}/idle"
assert_eq "$RC|$(keyed interrupted "$(cat "$TMP_ROOT/interrupted.out")" | sed -n 1p | sed 's/window=@[0-9]*/window=@N/')|$(caller_open)|$(overseers)" \
  "1|oversee-succeed: interrupted window=@N signal=TERM|yes|0" \
  "interrupted mid-wait: refused, caller kept, successor closed"

# A signal that lands while the runtime's create runs, the window the script
# header names: the successor window is open and its id lives only in the
# provider's answer, not yet in SUCC_PANE. The close-out must read the session
# off that answer and stop it, or two overseers run. A tmux shim on PATH
# holds load-buffer, the first write the provider's pane_write makes, until
# the test sends the group signal and releases it. The kill therefore lands
# between new-window and the provider's answer, regardless of runner load;
# the shim is on PATH for these rows alone.
REAL_TMUX="$(command -v tmux)"
# int_create_run BIN — the script launched in its own process group so the
# group kill reaches the provider too, run until load-buffer is held, then
# TERMed and released. Sets INT_OVERSEERS to the count after it exits.
int_create_run() { # SUCCEED_BIN
  new_caller "$MARK"
  local before after=""
  before="$(overseers)"
  rm -f -- "$TMP_ROOT/intcreate.ready" "$TMP_ROOT/intcreate.release"
  setsid env TMUX="$TMUX_ADDR" TMUX_PANE="$CALLER_PANE" SUCCEED_BIN="$1" \
    "$TMP_ROOT/succeed-env" intcreate 'claude:fable:high' --wait-secs 30 \
    > "$TMP_ROOT/intcreate.out" 2>&1 &
  local pgid=$!
  # Poll only for the barrier; a timeout refuses the fixture, never a row pass.
  for _ in $(seq 1 100); do [[ -f "$TMP_ROOT/intcreate.ready" ]] && break; sleep 0.2; done
  if [[ ! -f "$TMP_ROOT/intcreate.ready" ]]; then
    kill -TERM -"$pgid" 2>/dev/null || true
    touch "$TMP_ROOT/intcreate.release"
    wait "$pgid" 2>/dev/null || true
    echo 'oversee-succeed-test: intcreate=barrier-not-reached' >&2
    exit 1
  fi
  kill -TERM -"$pgid"
  touch "$TMP_ROOT/intcreate.release"
  wait "$pgid" 2>/dev/null || true
  for _ in $(seq 1 25); do after="$(overseers)"; [[ "$after" -le "$before" ]] && break; sleep 0.2; done
  INT_OVERSEERS="$after"
}
if command -v setsid >/dev/null 2>&1; then
  cat > "$BIN/tmux" <<SHIM
#!/bin/sh
if [ "\$1" = load-buffer ]; then
  : > "$TMP_ROOT/intcreate.ready"
  # Wait for the test's release after TERM, not for a fixed create duration.
  while [ ! -f "$TMP_ROOT/intcreate.release" ]; do sleep 0.2; done
fi
exec "$REAL_TMUX" "\$@"
SHIM
  chmod +x "$BIN/tmux"
  int_create_run "$SUCCEED"
  assert_eq "$INT_OVERSEERS" \
    "0" \
    "a signal during create closes the successor read off the provider's answer"
  # The provider's control: without its signal guard it dies between
  # new-window and its answer, and the window leaks.
  INTHOST="$(mutant_scripts int-create-host overseer-host-tmux)" || exit 1
  mutate_file "$INTHOST/overseer-host-tmux" "    trap '' HUP INT TERM" '    :'
  int_create_run "$INTHOST/oversee-succeed"
  assert_eq "$INT_OVERSEERS" \
    "1" \
    "control: a provider without its signal guard leaks the successor"
  # The library's control: ol_session_abandon recovers the session from the
  # provider's answer where the caller never assigned it. Drop that recovery
  # and the window leaks.
  INTCTL="$(mutant_scripts int-create-ctl lib/overseer-launch.sh)" || exit 1
  mutate_file "$INTCTL/lib/overseer-launch.sh" '  [[ -n "$OL_SESSION" ]] || ol_session_from_out' '  :'
  int_create_run "$INTCTL/oversee-succeed"
  assert_eq "$INT_OVERSEERS" \
    "1" \
    "control: without the recovery a signal during create leaks the successor"
  rm -f -- "${BIN:?}/tmux"
  tm kill-window -a -t "$KEEP_WINDOW" 2>/dev/null || true
  tm move-window -r -t fleet
else
  echo "  skip  a signal during create closes the successor (no setsid)"
fi

# The caller's own record is put back WHOLE when a launch is abandoned, its own
# launch line included: the read runs before the successor's line is written,
# so a later dead-overseer relaunch never replays the line this run refused.
# Seed a prior generation, run an abandon (never-working), and read the record.
SEED_LINE='env CLAUDE_CONFIG_DIR=/seed/.claude claude -n overseer --seeded'
seed_overseer() {
  fleet_state
  jq --arg line "$SEED_LINE" \
    '.overseer = {runtime: "tmux", generation: 5, server: "7000", pane: "%900", window: "@900", account: "/seed/.claude", launch_line: $line}' \
    "$FLEET_STATE" > "$FLEET_STATE.tmp" && mv -- "$FLEET_STATE.tmp" "$FLEET_STATE"
}
seed_overseer
new_caller "$MARK"
touch "$TMP_ROOT/idle"
VIRTUAL_CLOCK=1 run_succeed restore 'claude:fable:high' --wait-secs "$IDLE_WAIT"
rm -f "$TMP_ROOT/idle"
assert_eq "$RC|generation=$(orec generation) pane=$(orec pane) account=$(orec account) line=$(recorded_line)" \
  "1|generation=5 pane=%900 account=/seed/.claude line=$SEED_LINE" \
  "an abandoned succession puts the caller's whole record back, its own line included"

# A signal that lands while the session record's writer runs is taken only
# once the writer returns, and the writer may have committed: the abandon then
# has to put the caller's record back although ol_record_write never returned.
# A workflow-state stand-in commits the successor's record, TERMs the script
# and exits 0, once; every other call is the real writer's.
# record_commit_run SCRIPTS_DIR — the run over that tree; sets OUT and RC.
record_commit_run() { # SCRIPTS_DIR
  rm -f -- "$1/workflow-state" "$TMP_ROOT/record-commit.fired"
  cat > "$1/workflow-state" <<STUB
#!/usr/bin/env bash
"$SRC_DIR/workflow-state" "\$@" || exit
if [[ "\$1 \$2 \$3" == "set oversee overseer" && ! -e "$TMP_ROOT/record-commit.fired" ]]; then
  : > "$TMP_ROOT/record-commit.fired"
  kill -TERM "\$PPID"
fi
STUB
  chmod +x "$1/workflow-state"
  seed_overseer
  new_caller "$MARK"
  touch "$TMP_ROOT/idle"
  SUCCEED_BIN="$1/oversee-succeed" run_succeed recordcommit 'claude:fable:high' --wait-secs 30
  rm -f "$TMP_ROOT/idle"
}
seed_overseer
SEED_RECORD="$(jq -cS .overseer "$FLEET_STATE")"
RECCOMMIT="$(mutant_scripts record-commit)" || exit 1
record_commit_run "$RECCOMMIT"
assert_eq "$RC|$(keyed interrupted "$OUT" | sed -n 1p | sed 's/window=@[0-9]*/window=@N/')|$(caller_open)|$(overseers)|$(jq -cS .overseer "$FLEET_STATE")" \
  "1|oversee-succeed: interrupted window=@N signal=TERM|yes|0|$SEED_RECORD" \
  "a signal while the record's writer commits: refused, successor closed, the caller's record back"
# The control: the put-back gated on a flag ol_record_write sets once its
# writer returns, which a signal during the writer never lets it reach, so the
# record keeps the closed successor's generation, one past the seeded 5.
RECCTL="$(mutant_scripts record-commit-ctl lib/overseer-launch.sh)" || exit 1
mutate_file "$RECCTL/lib/overseer-launch.sh" '  if [[ -n "$OL_PRIOR" ]] && ! ol_record_restore; then' \
  '  if [[ -n "${OL_WRITE_RETURNED:-}" ]] && ! ol_record_restore; then'
mutate_file "$RECCTL/lib/overseer-launch.sh" 'set oversee overseer "$record" >/dev/null 2>"$DEP_ERR"' \
  'set oversee overseer "$record" 2>"$DEP_ERR" >/dev/null || return 1; OL_WRITE_RETURNED=1'
record_commit_run "$RECCTL"
assert_eq "$RC|$(caller_open)|$(overseers)|generation=$(orec generation)" \
  "1|yes|0|generation=6" \
  "control: a put-back gated on the write returning leaves the closed successor recorded"

new_caller "$UNDER_MARK"
run_succeed under 'claude:fable:high'
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=80|0|none" \
  "1M window under the context mark: context-below-mark, nothing launched"


# A window under 1M is judged at the same share as any other, and a reading
# whose window its adapter could not name is unmeasured rather than guessed at.
for row in \
  "  kendex (ken-1453) Opus 5 (200k context) 41% (fixture@example.com)     /rc|context-below-mark tokens=82000 window=200000 mark=50 headroom=80|a 200k window is judged at the same share as a 1M one" \
  "  kendex (ken-1453) Sonnet 4.5 52% (fixture@example.com)     /rc|context-unmeasured reason=window-unnamed headroom=80|a model whose window the adapter leaves out is unmeasured, not guessed at"; do
  IFS='|' read -r row_screen row_want row_label <<<"$row"
  new_caller "$row_screen"
  run_succeed window 'claude:fable:high'
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
    "0|oversee-succeed: $row_want|0|none" \
    "$row_label"
done

# --- the judgement on its own -------------------------------------------
# `--check-marks` is the same two marks, stopped at the answer: the watch runs
# it every pass and turns a reached mark into the event that wakes the overseer,
# so a judgement here that picked a lane or opened a window would spend an
# account on every pass of every fleet.
new_caller "$MARK"
BEFORE_LINE="$(recorded_line)"
run_succeed checkcontext '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(caller_open)|$(recorded claude)" \
  "0|oversee-succeed: mark-reached kind=context value=520000 mark=50 succession=on headroom=unreadable window=1000000|0|yes|none" \
  "--check-marks at the context mark: the mark is reported, nothing is launched"
assert_eq "$(recorded_line)" "$BEFORE_LINE" \
  "and the fleet state keeps the launch line it had: a judgement records none"

# A mistyped ORCH_QUESTION_TOOL rides along: a judgement builds no
# line, so the setting is not read and cannot silence the mark.
new_caller "$UNDER_MARK"
QUESTION_TOOL=sometimes run_succeed checkunder '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(caller_open)" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=80|0|yes" \
  "--check-marks under both marks: the below-mark line, nothing launched, a mistyped question-tool setting unread"

# The caller's headroom is read off this machine's copy of its account, the
# copy its session spends, even on a fleet whose lane provider reports that
# account with more room. The run's own repository carries the caller's
# context reading, since oversee-succeed reads it under its project root.
HOSTED_WORK="$TMP_ROOT/hosted-work"
mkdir -p "$HOSTED_WORK/tmp/lane-mail/overseer"
git -C "$HOSTED_WORK" init -q -b main
git -C "$HOSTED_WORK" config gc.auto 0
git -C "$HOSTED_WORK" config maintenance.auto false
hosted_caller() { new_caller "$UNDER_MARK" && cp -- "$OVERSEER_RECORD" "$HOSTED_WORK/tmp/lane-mail/overseer/context.json"; }
printf 'account=%s\tharness=claude\tsession-5h-pct=5\tweekly-pct=5\tmodel-pct=5\tmodel-label=Fable 5.1\n' "$H/.claude" > "$TMP_ROOT/accounts-room.tsv"
hosted_caller
RUN_DIR="$HOSTED_WORK" LANE_HOST_ACCOUNTS="$TMP_ROOT/accounts-room.tsv" run_succeed hostedcaller '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=80" \
  "a provider row with more room leaves the caller's headroom at this machine's reading"
# Control: a caller read that inherits the fleet's provider takes the host row.
HOSTCALLER="$(mutant_scripts hostcaller oversee-succeed)" || exit 1
mutate_file "$HOSTCALLER/oversee-succeed" 'caller_record="$(ol_lanes pick' 'caller_record="$("$SCRIPT_DIR/lanes" pick'
hosted_caller
RUN_DIR="$HOSTED_WORK" LANE_HOST_ACCOUNTS="$TMP_ROOT/accounts-room.tsv" SUCCEED_BIN="$HOSTCALLER/oversee-succeed" \
  run_succeed hostedcallerctl '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=95" \
  "control: a caller read under the fleet's provider takes the host row's headroom"

# The projected wall is measured from the displaced cache sample. A fast burn
# reaches the setting. A slow burn does not. Missing, close, and flat samples
# are each reported as unmeasured rather than read as a safe rate.
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
stage_usage_pair ratefast 40 20 600
new_caller "$UNDER_MARK"
WALL_MINUTES=30 run_succeed ratefast '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: mark-reached kind=rate value=30 mark=30 succession=on account=claude|0" \
  "a sixty-point headroom burning two points a minute fires the rate trigger"
new_caller "$UNDER_MARK"
WALL_MINUTES=30 run_succeed ratefast ''
assert_eq "$RC|$(caller_open)|$(recorded claude)" \
  "0|no|lane=$H/.eclaude;-n;overseer;$CLAUDE_COMPACT;$BRIEF;" \
  "a rate trigger moves off the caller account even when it has more headroom"
stage_usage_pair rateslow 22 20 600
new_caller "$UNDER_MARK"
WALL_MINUTES=30 run_succeed rateslow '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=78|0" \
  "a projected wall beyond the setting does not fire"
stage_usage_pair ratedefaultat 60 40 600
new_caller "$UNDER_MARK"
WALL_MINUTES=default run_succeed ratedefaultat '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: mark-reached kind=rate value=20 mark=20 succession=on account=claude|0" \
  "the default wall notice fires at twenty projected minutes"
stage_usage_pair ratedefaultabove 58 38 600
new_caller "$UNDER_MARK"
WALL_MINUTES=default run_succeed ratedefaultabove '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=42|0" \
  "the default wall notice stays clear at twenty-one projected minutes"
for rate_row in \
  "rateone|40|none|0|one-sample" \
  "rateclose|40|20|30|samples-too-close" \
  "rateflat|20|20|600|not-increasing"; do
  IFS='|' read -r rate_name rate_current rate_prior rate_gap rate_reason <<<"$rate_row"
  stage_usage_pair "$rate_name" "$rate_current" "$rate_prior" "$rate_gap"
  new_caller "$UNDER_MARK"
  WALL_MINUTES=30 run_succeed "$rate_name" '' --check-marks
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
    "0|oversee-succeed: mark-unmeasured kind=rate reason=$rate_reason succession=on|0" \
    "an unmeasurable rate reports $rate_reason"
done
# A Codex overseer room on its credits carries usage_rate_state `credits`: no
# plan window binds it, so the rate trigger does not apply, as at a setting of 0.
jq -n '{rate_limit: {primary_window: {used_percent: 100, reset_at: 1785000000, limit_window_seconds: 18000}, secondary_window: null},
  credits: {has_credits: true, unlimited: false, overage_limit_reached: false, balance: "62300"},
  spend_control: {reached: false}}' > "$FIXTURE_DIR/.codex.json"
new_caller "$CODEX_SCREEN" 'Context 48% left'
NO_CONTEXT=1 CALLER_LANE="CODEX_HOME=$H/.codex" WALL_MINUTES=default run_succeed ratecredits '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: account-below-mark headroom=0|0" \
  "a Codex overseer on its credits reads below the account marks, its rate trigger not applying"
# Control: a rate arm that reads every state but `measured` as a failed reading
# holds the same overseer unmeasured.
RATECREDITS="$(mutant_scripts ratecredits oversee-succeed)" || exit 1
mutate_file "$RATECREDITS/oversee-succeed" ' && "$RATE_STATE" != credits ]]' ' ]]'
new_caller "$CODEX_SCREEN" 'Context 48% left'
NO_CONTEXT=1 CALLER_LANE="CODEX_HOME=$H/.codex" WALL_MINUTES=default SUCCEED_BIN="$RATECREDITS/oversee-succeed" \
  run_succeed ratecreditsctl '' --check-marks
codex_usage 20 > "$FIXTURE_DIR/.codex.json"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-unmeasured kind=rate reason=credits succession=on" \
  "control: a rate arm blind to credits reads the credit overseer as unmeasured"
new_caller "$UNDER_MARK"
WALL_MINUTES=bad run_succeed badwall '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|oversee-succeed: invalid-wall-minutes ORCH_OVERSEER_WALL_MINUTES=bad" \
  "a malformed projected-wall setting is refused before judgement"
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=bad run_succeed badsuccessors '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|oversee-succeed: invalid-successor-accounts ORCH_OVERSEER_SUCCESSOR_ACCOUNTS=bad" \
  "a malformed successor-account setting is refused before judgement"
# A preference entry outside harness:model:effort is refused before any pick,
# by lib/overseer-launch.sh's parser, the one `oversee launch` reads the same
# setting with.
new_caller "$MARK"
run_succeed badpreference 'claude:Opus:high' --wait-secs 5
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "1|oversee-succeed: invalid-preference entry=claude:Opus:high|0" \
  "a preference entry outside the shape is refused before any pick, nothing opened"
# A runtime other than tmux is refused before anything is printed, written or
# opened, by the library rule `oversee launch` reads: this script verifies the
# successor's account off its pane, so a provider path is never opened through
# and recorded as tmux.
new_caller "$MARK"
OVERSEER_HOST="$TMP_ROOT/other" run_succeed otherhost 'claude:fable:high' --wait-secs 5
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(grep -c '^oversee-succeed: successor-launch ' <<<"$OUT")|$(overseers)" \
  "1|oversee-succeed: runtime-unsupported host=$TMP_ROOT/other|0|0" \
  "a runtime other than tmux is refused before the pre-launch line, nothing opened"
stage_usage_pair rateleadingzero 40 20 600
new_caller "$UNDER_MARK"
WALL_MINUTES=030 run_succeed rateleadingzero '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-reached kind=rate value=30 mark=30 succession=on account=claude" \
  "a leading-zero wall setting remains valid decimal input"

# The chooser itself counts the accounts above the trigger, and this session's
# own is among them where it has room, so the count reads the same from every
# account it covers. Three accounts above the trigger leave the overseer in
# place, and so do two with the overseer on one of them, however the two
# readings stand: the other account here has MORE headroom, which is the
# reading a count without this session's own account would move it on.
make_lane "$H" nclaude
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.nclaude.json"
THREE_LANES="$H/.claude:$H/.eclaude:$H/.nclaude"
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=1 LANE_DIRS="$THREE_LANES" run_succeed qualifyingthree '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=40|0" \
  "three accounts above the trigger do not fire the qualifying-set trigger"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.nclaude.json"
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=01 LANE_DIRS="$THREE_LANES" run_succeed qualifyingtwo '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=40|0" \
  "two accounts above the trigger, the overseer on one of them, do not fire the qualifying-set trigger"
# The count's one control: a count without this session's own account, which
# reads one on the same two accounts.
EXCLUSIVECTL="$(mutant_scripts exclusivectl oversee-succeed)" || exit 1
mutate_file "$EXCLUSIVECTL/oversee-succeed" \
  '&& "$CALLER_STATE" != at-trigger && "$QUALIFYING_STATE" != inert' '&& "$CALLER_STATE" != at-trigger'
mutate_file "$EXCLUSIVECTL/oversee-succeed" \
  '[[ "$CALLER_STATE" != has-room ]] || QUALIFYING_TOTAL=$((QUALIFYING_COUNT + 1))' ''
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=1 LANE_DIRS="$THREE_LANES" SUCCEED_BIN="$EXCLUSIVECTL/oversee-succeed" \
  run_succeed exclusivectl '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-reached kind=qualifying value=1 mark=1 succession=on headroom=40" \
  "control: a count that leaves this session's own account out fires on the same two accounts"

# One account above the trigger other than this session's own, whose own is
# not measured above it, fires the mark and moves the overseer there. An own
# account MEASURED at the trigger fires the headroom mark first, which leads.
mv "$FIXTURE_DIR/.claude.json" "$FIXTURE_DIR/.claude.json.held"
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=1 LANE_DIRS="$THREE_LANES" run_succeed qualifyingone '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: mark-reached kind=qualifying value=1 mark=1 succession=on headroom=none|0" \
  "one account above the trigger, this session's own not, fires the named qualifying-set trigger"
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=1 LANE_DIRS="$THREE_LANES" run_succeed qualifyinglaunch ''
mv "$FIXTURE_DIR/.claude.json.held" "$FIXTURE_DIR/.claude.json"
assert_eq "$RC|$(caller_open)|$(recorded claude)" \
  "0|no|lane=$H/.eclaude;-n;overseer;$CLAUDE_COMPACT;$BRIEF;" \
  "the qualifying-set trigger succeeds onto the remaining account"

# A setting at the count of two meets the count from either account, so a
# successor would read the same two from the one it lands on and fire again once
# the headroom readings crossed: no entry settles the mark, and it does not fire
# in the judgement or in a succession.
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=2 LANE_DIRS="$THREE_LANES" run_succeed qualifyingtwomark '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=40" \
  "a count no successor settles does not fire the qualifying-set trigger"
# The judgement walks the preference as a succession would: a codex entry whose
# successor finds no other codex account above the trigger settles the same
# count, a pi entry on a provider no lane measures reads no count and is passed
# over, and a preference the walk cannot read refuses the judgement.
codex_usage 20 > "$FIXTURE_DIR/.codex.json"
for pref_row in \
  "codex:gpt-6-astra:high|0|oversee-succeed: mark-reached kind=qualifying value=2 mark=2 succession=on headroom=40" \
  "pi:openai/gpt-5:high,codex:gpt-6-astra:high|0|oversee-succeed: mark-reached kind=qualifying value=2 mark=2 succession=on headroom=40" \
  "bogus|1|oversee-succeed: invalid-preference entry=bogus"; do
  IFS='|' read -r pref_value pref_rc pref_want <<<"$pref_row"
  new_caller "$UNDER_MARK"
  SUCCESSOR_ACCOUNTS=2 LANE_DIRS="$THREE_LANES:$H/.codex" \
    run_succeed "qualifyingpref-${pref_value%%:*}" "$pref_value" --check-marks
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")" "$pref_rc|$pref_want" \
    "a qualifying judgement walks the preference $pref_value"
done
# A cross-harness entry no permission posture can cross, which a succession
# skips, is skipped by the judgement too, though it is handed no flags: pi's
# row writes no permission word and names none to transfer. A claude caller's
# pi-claude entry on Fable would settle the count, the caller's account, whose
# record names Sonnet, being walled for Fable alone; a pi caller's codex entry
# would settle it as the claude caller's does above. Neither fires the mark.
qualifying_cross_row() { # ROW PREFERENCE [SUCCEED_BIN]
  SUCCESSOR_ACCOUNTS=2 LANE_DIRS="$THREE_LANES:$H/.codex" SUCCEED_BIN="${3:-}" \
    run_succeed "$1" "$2" --check-marks
}
# caller_record HARNESS MODEL — this pane's launch record on .claude.
caller_record() {
  jq --arg server "$SERVER_PID" --arg pane "$CALLER_PANE" --arg account "$H/.claude" \
    --arg harness "$1" --arg model "$2" --argjson start "$SERVER_START" \
    '.overseer = {runtime: "tmux", generation: 1, server: $server, pane: $pane, harness: $harness,
      account: $account, home: $account, model: $model, effort: "high", server_start: $start}' \
    "$FLEET_STATE" > "$FLEET_STATE.tmp" && mv -- "$FLEET_STATE.tmp" "$FLEET_STATE"
}
cp -p -- "$FLEET_STATE" "$FLEET_STATE.held"
claude_usage 60 20 99 "Fable 5.1" > "$FIXTURE_DIR/.claude.json"
new_caller "$UNDER_MARK"
caller_record claude claude-sonnet-5
qualifying_cross_row qualifyingpi 'pi:pi-claude/claude-fable-5-1:high'
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=40" \
  "a claude caller's judgement skips a pi entry no permission posture crosses to"
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
new_caller "$UNDER_MARK"
caller_record pi pi-claude/claude-fable-5-1
qualifying_cross_row qualifyingpicaller 'codex:gpt-6-astra:high'
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=40" \
  "a pi caller's judgement skips a codex entry no permission posture crosses from pi to"
# Their control: a judgement that leaves the transfer test to the succession
# fires the mark on each entry that succession would skip.
CROSSCTL="$(mutant_scripts crossctl lib/overseer-launch.sh)" || exit 1
mutate_file "$CROSSCTL/lib/overseer-launch.sh" \
  '  [[ "$OL_HARNESS" != "$OL_WALK_SOURCE_HARNESS" ]] || return 0' \
  '  [[ "$OL_HARNESS" != "$OL_WALK_SOURCE_HARNESS" ]] && (( ! OL_WALK_SOURCE_ROWS )) || return 0'
claude_usage 60 20 99 "Fable 5.1" > "$FIXTURE_DIR/.claude.json"
new_caller "$UNDER_MARK"
caller_record claude claude-sonnet-5
qualifying_cross_row crossctlpi 'pi:pi-claude/claude-fable-5-1:high' "$CROSSCTL/oversee-succeed"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-reached kind=qualifying value=2 mark=2 succession=on headroom=40" \
  "control: a judgement without the transfer test fires on the claude caller's pi entry"
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
new_caller "$UNDER_MARK"
caller_record pi pi-claude/claude-fable-5-1
qualifying_cross_row crossctlpicaller 'codex:gpt-6-astra:high' "$CROSSCTL/oversee-succeed"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-reached kind=qualifying value=2 mark=2 succession=on headroom=40" \
  "control: a judgement without the transfer test fires on the pi caller's codex entry"
mv -- "$FLEET_STATE.held" "$FLEET_STATE"
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=2 LANE_DIRS="$THREE_LANES" run_succeed qualifyingrefires ''
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=40|yes|0|none" \
  "and a succession on it launches nothing, the caller kept"
# The judgement's control: the walk's answer ignored, so the count alone fires
# a mark no succession can settle.
SETTLECTL="$(mutant_scripts settlectl oversee-succeed)" || exit 1
mutate_file "$SETTLECTL/oversee-succeed" '      [[ -n "$chosen" ]] || MARK_KIND=""' ''
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=2 LANE_DIRS="$THREE_LANES" SUCCEED_BIN="$SETTLECTL/oversee-succeed" \
  run_succeed settlectl '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-reached kind=qualifying value=2 mark=2 succession=on headroom=40" \
  "control: a judgement that ignores the walk fires on a count no successor settles"
# The successor count's control: never judged, so the walk opens the successor
# onto the other account.
REFIRECTL="$(mutant_scripts refirectl lib/overseer-launch.sh)" || exit 1
mutate_file "$REFIRECTL/lib/overseer-launch.sh" \
  'if (( count > 0 && count + 1 <= OL_WALK_SUCCESSOR_BOUND )); then continue; fi' ':'
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=2 LANE_DIRS="$THREE_LANES" SUCCEED_BIN="$REFIRECTL/oversee-succeed" \
  run_succeed refirectl ''
assert_eq "$RC|$(caller_open)|$(recorded claude)" \
  "0|no|lane=$H/.eclaude;-n;overseer;$CLAUDE_COMPACT;$BRIEF;" \
  "control: a walk that never counts for its successor opens it onto the other account"

# The headroom comparison still holds a count the setting reaches: an account
# with no more headroom than this one is no reason to move.
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.claude.json"
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=2 LANE_DIRS="$THREE_LANES" run_succeed qualifyingequal '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=50" \
  "an equal-headroom successor does not fire the qualifying-set trigger"

# The Stop hook and oversee-watch consume these mark lines. Log the real
# chooser's calls to prove an inert mark avoids the capacity scan.
PICKLOG="$(mutant_scripts qualifying-picks lanes)" || exit 1
cp -p -- "$PICKLOG/lanes" "$PICKLOG/lanes-real"
cat > "$PICKLOG/lanes" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TMP_ROOT/qualifying-picks.log"
exec "$PICKLOG/lanes-real" "\$@"
WRAPPER
for pick_row in \
  'two|1|60|context-below-mark tokens=100000 window=1000000 mark=50 headroom=40|caller' \
  'one|1|none|mark-reached kind=qualifying value=1 mark=1 succession=on headroom=none|capacity' \
  'equal|2|50|context-below-mark tokens=100000 window=1000000 mark=50 headroom=50|capacity'; do
  IFS='|' read -r pick_name pick_bound pick_usage pick_want pick_calls <<<"$pick_row"
  claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  if [[ "$pick_usage" == none ]]; then
    mv "$FIXTURE_DIR/.claude.json" "$FIXTURE_DIR/.claude.json.held"
  else
    claude_usage "$pick_usage" 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  fi
  new_caller "$UNDER_MARK"
  : > "$TMP_ROOT/qualifying-picks.log"
  SUCCESSOR_ACCOUNTS="$pick_bound" LANE_DIRS="$THREE_LANES" SUCCEED_BIN="$PICKLOG/oversee-succeed" \
    run_succeed "pick-$pick_name" '' --check-marks
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")" "0|oversee-succeed: $pick_want" "qualifying pick row $pick_name"
  picks="$(grep '^pick ' "$TMP_ROOT/qualifying-picks.log")"
  assert_eq "$(sed -n 1p <<<"$picks")" \
    "pick --lane $H/.claude --harness claude --for-overseer --min-headroom-pct $TRIGGER --model claude-fable-5-1 --json" \
    "qualifying $pick_name reads the caller first"
  if [[ "$pick_calls" == caller ]]; then
    assert_eq "$(wc -l <<<"$picks" | tr -d ' ')" 1 "an inert qualifying mark runs only the caller pick"
  else
    assert_contains "$(sed -n 2p <<<"$picks")" '--for-overseer' "qualifying $pick_name reads capacity second"
  fi
  [[ "$pick_usage" != none ]] || mv "$FIXTURE_DIR/.claude.json.held" "$FIXTURE_DIR/.claude.json"
done
PICKCTL="$(mutant_scripts qualifying-pickctl oversee-succeed)" || exit 1
rm -- "$PICKCTL/lanes"
cp -p -- "$PICKLOG/lanes" "$PICKCTL/lanes"
mutate_file "$PICKCTL/oversee-succeed" \
  '&& "$CALLER_STATE" != at-trigger && "$QUALIFYING_STATE" != inert' '&& "$CALLER_STATE" != at-trigger'
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
new_caller "$UNDER_MARK"
: > "$TMP_ROOT/qualifying-picks.log"
SUCCESSOR_ACCOUNTS=1 LANE_DIRS="$THREE_LANES" SUCCEED_BIN="$PICKCTL/oversee-succeed" \
  run_succeed qualifying-pickctl '' --check-marks
picks="$(grep '^pick ' "$TMP_ROOT/qualifying-picks.log")"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  '0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=40' \
  'control: removing the skip preserves the below-mark line'
assert_eq "$(wc -l <<<"$picks" | tr -d ' ')" 2 'control: removing the skip fails the one-pick bound'
assert_contains "$(sed -n 2p <<<"$picks")" '--for-overseer' 'control: the extra pick scans successor capacity'
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.claude.json"

# A known harness remains enough to judge account triggers when its context
# line is absent. The account read receives no model, and the context reading
# remains unmeasured when none of those triggers fires.
NO_CONTEXT='fixture known claude without context'
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
new_known_claude_caller "$NO_CONTEXT"
run_succeed knownheadroom '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-reached kind=headroom value=$TRIGGER mark=$TRIGGER succession=on account=claude resets=$CLAUDE_USAGE_SESSION_RESET" \
  "a known harness with no context line still fires the headroom trigger"

stage_usage_pair knownrate 40 20 600
new_known_claude_caller "$NO_CONTEXT"
WALL_MINUTES=30 run_succeed knownrate '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-reached kind=rate value=30 mark=30 succession=on account=claude" \
  "a known harness with no context line still fires the rate trigger"

claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
mv "$FIXTURE_DIR/.claude.json" "$FIXTURE_DIR/.claude.json.held"
new_known_claude_caller "$NO_CONTEXT"
SUCCESSOR_ACCOUNTS=1 LANE_DIRS="$THREE_LANES" run_succeed knownqualifying '' --check-marks
mv "$FIXTURE_DIR/.claude.json.held" "$FIXTURE_DIR/.claude.json"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-reached kind=qualifying value=1 mark=1 succession=on headroom=none" \
  "a known harness with no context line still fires the qualifying-set trigger"

claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.nclaude.json"
new_known_claude_caller "$NO_CONTEXT"
SUCCESSOR_ACCOUNTS=1 LANE_DIRS="$THREE_LANES" run_succeed knownunmeasured '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: account-below-mark headroom=40" \
  "a known harness handed no reading judges its account triggers alone"
new_caller "$NO_CONTEXT" "$NO_CONTEXT"
run_succeed unknowncontext '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|oversee-succeed: harness-unnamed pane=$CALLER_PANE" \
  "a pane with no known harness and no reading naming one still refuses"
# A Codex overseer's pane reads node, which names neither harness, and before
# its first turn end no reading names one either: --harness does, so the watch
# can record its launch line inside that first turn.
new_caller "$NO_CONTEXT" "$NO_CONTEXT" "cat '$TMP_ROOT/caller.screen'; exec '$BIN/node' 100000"
CALLER_LANE="CODEX_HOME=$H/.codex" run_succeed nodeprint '' --print-launch-line --harness codex -- --verbose
assert_eq "$RC|$(grep -c ' codex ' <<<"$OUT")|$(grep -c 'claude' <<<"$OUT")" "0|1|0" \
  "a node pane with no reading prints its codex line where --harness names codex"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.nclaude.json"

claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"

# The account mark leads, and only its line names the account and the reset the
# operator waits on: at the context mark the overseer's own account either has
# room or was never measured, so there is none to name.
new_caller "$UNDER_MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
run_succeed checkheadroom '' --check-marks
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(caller_open)" \
  "0|oversee-succeed: mark-reached kind=headroom value=$TRIGGER mark=$TRIGGER succession=on account=claude resets=$CLAUDE_USAGE_SESSION_RESET|0|yes" \
  "--check-marks at the account mark: the headroom mark, its account and its reset"

# Succession off launches nothing, and a judgement launches nothing either: the
# overseer is still past its mark and still has to hand over by hand, so the
# answer is reported with the setting on it rather than withheld.
new_caller "$MARK"
SUCCESSION=off run_succeed checkoff '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(caller_open)" \
  "0|oversee-succeed: mark-reached kind=context value=520000 mark=50 succession=off headroom=unreadable window=1000000|0|yes" \
  "--check-marks with succession off still judges, and says the setting is off"

# A reading that could not be taken is not a mark that did not fire, and only
# `check` tells them apart: the watch holds a standing mark across such a pass,
# where the succeed path has the documented fallback of letting the mark it CAN
# read decide alone. The context mark still leads: a mark that fired is what
# the caller must act on, whatever the other reading could not say.
new_caller "$UNDER_MARK"
LANE_DIRS="$H/.openclaude" CALLER_LANE="CLAUDE_CONFIG_DIR=$H/.openclaude" \
  run_succeed checkunmeasured '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(caller_open)" \
  "0|oversee-succeed: mark-unmeasured kind=headroom reason=headroom-none succession=on|0|yes" \
  "--check-marks with an account nothing measured: mark-unmeasured, naming the missing figure"
new_caller "$MARK"
LANE_DIRS="$H/.openclaude" CALLER_LANE="CLAUDE_CONFIG_DIR=$H/.openclaude" \
  run_succeed checkunmeasuredpast '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: mark-reached kind=context value=520000 mark=50 succession=on headroom=unreadable window=1000000|0" \
  "and a context mark that fired outranks it: a mark the caller must act on is reported"

# A reading whose window its adapter could not name: the context mark could not
# be judged at all, which is not the measured 200k window the rows above judge.
new_caller "  kendex (ken-1453) Sonnet 4.5 52% (fixture@example.com)     /rc"
run_succeed checkwindownone '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: mark-unmeasured kind=context reason=window-unnamed succession=on|0" \
  "--check-marks with no window to measure against: mark-unmeasured names the window"
new_caller "  kendex (ken-1453) Opus 5 (200k context) 41% (fixture@example.com)     /rc"
run_succeed checkwindowsmall '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: context-below-mark tokens=82000 window=200000 mark=50 headroom=80|0" \
  "a 200k window this reader DID measure is judged, a below-mark answer under the share"

# Exact equality with the default percentage still leaves room.
new_caller "$CODEX_AT_MARK" 'Context 10% left'
CONTEXT_PCT=90 CALLER_LANE="CODEX_HOME=$H/.codex" run_succeed codexatmark '' --check-marks
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: context-below-mark tokens=232560 window=258400 mark=90 headroom=80|0" \
  "a codex overseer at exactly 90 percent of its 258400 window has room"

# The real hook's --context input: independent limits, settings resolution,
# and a node pane with no recorded identity. Only due checks skip identity.
while IFS='|' read -r pane reading mark expected; do
  if [[ "$pane" == node ]]; then
    new_caller "$NO_CONTEXT" "$NO_CONTEXT" "cat '$TMP_ROOT/caller.screen'; exec '$BIN/node' 100000"
  else
    new_caller "$UNDER_MARK"
  fi
  [[ "$pane" != foreign ]] || record_caller "$UNDER_MARK" '%999'
  CONTEXT_PCT="$mark" run_succeed independentcontext '' --check-marks --context "$reading"
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" "${expected//PANE/$CALLER_PANE}|0" \
    "the $pane caller judges $reading at requested percent $mark"
done <<'ROWS'
record|520000:1000000|60|0|oversee-succeed: mark-reached kind=context value=520000 mark=60 succession=on headroom=unreadable window=1000000
record|520000:1000000|40|0|oversee-succeed: mark-reached kind=context value=520000 mark=40 succession=on headroom=unreadable window=1000000
record|520000:1000000|percent|0|oversee-succeed: mark-reached kind=context value=520000 mark=90 succession=on headroom=unreadable window=1000000
record|520000:1000000|050|1|oversee-succeed: invalid-context-mark ORCH_HANDOFF_CONTEXT_PCT=050
record|520000:1000000|101|1|oversee-succeed: invalid-context-mark ORCH_HANDOFF_CONTEXT_PCT=101
record|399999:1000000|90|0|oversee-succeed: context-below-mark tokens=399999 window=1000000 mark=90 headroom=80
record|400000:1000000|90|0|oversee-succeed: mark-reached kind=context value=400000 mark=90 succession=on headroom=unreadable window=1000000
record|400000:|90|0|oversee-succeed: mark-reached kind=context value=400000 mark=90 succession=on headroom=unreadable window=
record|399999:|90|0|oversee-succeed: mark-unmeasured kind=context reason=window-unnamed succession=on
record|180000:200000|100|0|oversee-succeed: context-below-mark tokens=180000 window=200000 mark=90 headroom=80
record|180001:200000|100|0|oversee-succeed: mark-reached kind=context value=180001 mark=90 succession=on headroom=unreadable window=200000
record|160000:200000|80|0|oversee-succeed: context-below-mark tokens=160000 window=200000 mark=80 headroom=80
record|160001:200000|80|0|oversee-succeed: mark-reached kind=context value=160001 mark=80 succession=on headroom=unreadable window=200000
node|400000:1000000|90|0|oversee-succeed: mark-reached kind=context value=400000 mark=90 succession=on headroom=unreadable window=1000000
node|400000:|90|0|oversee-succeed: mark-reached kind=context value=400000 mark=90 succession=on headroom=unreadable window=
node|232561:258400|90|0|oversee-succeed: mark-reached kind=context value=232561 mark=90 succession=on headroom=unreadable window=258400
node|232560:258400|90|1|oversee-succeed: harness-unnamed pane=PANE
node|399999:|90|1|oversee-succeed: harness-unnamed pane=PANE
foreign|100000:1000000|50|1|oversee-succeed: harness-unnamed pane=PANE
ROWS

# A stored due reading never supplies context to either judging mode.
while IFS='|' read -r check expected; do
  new_caller "$MARK"
  NO_CONTEXT=1 run_succeed stored '' ${check:+"$check"}
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
    "0|oversee-succeed: $expected|0|none" "a stored due reading launches nothing in ${check:-succession}"
done <<'ROWS'
--check-marks|account-below-mark headroom=80
|context-unmeasured reason=context-unread headroom=80
ROWS

# The reading is TOKENS:WINDOW as the hook writes it, and only a judging run
# takes one.
new_caller "$MARK"
for row in "badcontext|--check-marks --context 12|1|oversee-succeed: invalid-context value=12" \
           "printcontext|--print-launch-line --context 12:100|1|oversee-succeed: mode-conflict mode=print context=12:100" \
           "badharness|--print-launch-line --harness opencode|1|oversee-succeed: invalid-harness value=opencode"; do
  IFS='|' read -r row_name row_args row_rc row_first <<<"$row"
  # shellcheck disable=SC2086
  NO_CONTEXT=1 run_succeed "$row_name" '' $row_args
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")" "$row_rc|$row_first" "$row_name: $row_first"
done

# --check-marks' one control: the judgement runs on past its own answer. It is
# the launch path's own steps that follow, so a check that does not stop opens
# a successor window and spends an account every pass the watch makes. The
# line is matched whole: an indented twin of it answers the unmeasured states.
CHECKCTL="$(mutant_scripts checkctl oversee-succeed)" || exit 1
awk -v line='if [[ "$MODE" == check ]]; then' \
  '$0 == line { print "if false; then"; hits++; next } { print }
   END { if (hits != 1) exit 1 }' "$SUCCEED" > "$CHECKCTL/oversee-succeed" \
  || { echo "fixture: checkctl found no single site to mutate" >&2; exit 1; }
new_caller "$UNDER_MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 20 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
SUCCEED_BIN="$CHECKCTL/oversee-succeed" run_succeed checkctl '' --check-marks
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
assert_eq "$RC|$(overseers)|$(caller_open)" \
  "0|1|no" "control: a judgement that does not stop opens a successor and closes the caller"

# ORCH_OVERSEER_SUCCESSION over a screen past the mark, which would launch.
for row in \
  "off|0|oversee-succeed: succession-off ORCH_OVERSEER_SUCCESSION=off" \
  "true|1|oversee-succeed: invalid-succession ORCH_OVERSEER_SUCCESSION=true"; do
  IFS='|' read -r row_value row_rc row_want <<<"$row"
  new_caller "$MARK"
  SUCCESSION="$row_value" run_succeed succession 'claude:fable:high'
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
    "$row_rc|$row_want|0|none" \
    "succession $row_value: nothing launched"
done

echo "=== an overseer that DIED, which reaches none of the marks above ==="
# A dead pane runs no harness and records no reading, so nothing there names
# the harness, the model or the account the session ran on. Two modes carry
# that case over ONE launch path: `--print-launch-line` builds the command
# while the overseer is alive, and `--dead-pane` sends that record into the
# dead overseer's window slot. Neither judges a mark, because the death is the
# trigger.

# The screen under the context mark is where the first mode refuses, so a row
# that answers on it shows the print judging no mark.
new_caller "$UNDER_MARK"
run_succeed printline '' --print-launch-line -- --verbose
assert_eq "$RC|$OUT|$(caller_open)|$(overseers)|$(recorded claude)" \
  "0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer $CLAUDE_COMPACT_LINE --verbose '$BRIEF'|yes|0|none" \
  "--print-launch-line prints the caller's own line, judges no mark and launches nothing"

new_caller "$UNDER_MARK"
WALL_MINUTES=bad SUCCESSOR_ACCOUNTS=bad run_succeed printbadmarks '' --print-launch-line
assert_eq "$RC|$OUT|$(overseers)" \
  "0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer $CLAUDE_COMPACT_LINE '$BRIEF'|0" \
  "malformed trigger settings do not block a non-judging launch-line print"

# The preference names where a LATER successor goes; the printed line records
# what THIS session runs, so it walks the caller entry whatever it says and
# reads no account at all.
new_caller "$UNDER_MARK"
run_succeed printpref 'codex:gpt-6-astra:high' --print-launch-line
assert_eq "$RC|$OUT|$(recorded codex)" \
  "0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer $CLAUDE_COMPACT_LINE '$BRIEF'|none" \
  "--print-launch-line walks the caller entry whatever the preference names"

# The account the printed line opens its successor on is the one the fleet
# state records for this pane, where it records one: `oversee launch`,
# `oversee register` and a succession write it before the session's first
# turn, and a session launched from a stored token has no lane variable for
# the environment to answer with. A record naming another pane is another
# session's and leaves the environment's answer standing. The harness is
# named on the line, as a watch recording inside the first turn names it.
record_account() { # PANE ACCOUNT
  jq --arg server "$SERVER_PID" --arg pane "$1" --arg account "$2" --argjson start "$SERVER_START" \
    '.overseer = {runtime: "tmux", generation: 1, server: $server, pane: $pane, account: $account, server_start: $start}' \
    "$FLEET_STATE" > "$FLEET_STATE.tmp" && mv "$FLEET_STATE.tmp" "$FLEET_STATE"
}
new_caller "$UNDER_MARK"
record_account "$CALLER_PANE" "$H/.eclaude"
run_succeed printrecord '' --print-launch-line --harness claude
assert_eq "$RC|$OUT" \
  "0|env CLAUDE_CONFIG_DIR='$H/.eclaude' claude -n overseer $CLAUDE_COMPACT_LINE '$BRIEF'" \
  "the printed line opens on the account the fleet state records for this pane"
new_caller "$UNDER_MARK"
record_account '%999' "$H/.eclaude"
run_succeed printother '' --print-launch-line --harness claude
assert_eq "$RC|$OUT" \
  "0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer $CLAUDE_COMPACT_LINE '$BRIEF'" \
  "a record naming another pane is another session's: the environment's account stands"
# The control on the record fallback: a copy that never reads the recorded
# account prints the environment's for the pane the record names.
PRINTREC="$(mutant_scripts printrec oversee-succeed)" || exit 1
mutate_file "$PRINTREC/oversee-succeed" 'CALLER_CFG="$OL_KNOWN_ACCOUNT"' 'CALLER_CFG=""'
new_caller "$UNDER_MARK"
record_account "$CALLER_PANE" "$H/.eclaude"
SUCCEED_BIN="$PRINTREC/oversee-succeed" run_succeed printrecctl '' --print-launch-line --harness claude
assert_eq "$RC|$OUT" \
  "0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer $CLAUDE_COMPACT_LINE '$BRIEF'" \
  "control: a print that ignores the record names the environment's account for the recorded pane"
fleet_state

# A Copilot overseer: the printed line is its own row's, the brief on -i and
# the account its record names under COPILOT_HOME with the rest of a Copilot
# launch's environment. Its marks are judged on the account's monthly pool,
# which lanes measures; a record naming no account refuses the line rather
# than print one on an account nothing named.
COPILOT_ENV="env -u COPILOT_GITHUB_TOKEN COPILOT_SKILLS_DIRS='$H/.agents/skills' COPILOT_ALLOW_ALL=true"
COPILOT_LINE="$COPILOT_ENV COPILOT_HOME='$H/.1copilot' copilot --autopilot --max-autopilot-continues 3 --context long_context --no-auto-update --allow-all -i '$BRIEF'"
copilot_row() { # NAME [SUCCEED_BIN] ARGS... — the run on a pane whose record names $H/.1copilot
  local name="$1" bin="$2"
  shift 2
  new_caller "$UNDER_MARK"
  record_account "$CALLER_PANE" "$H/.1copilot"
  SUCCEED_BIN="${bin:-$SUCCEED}" run_succeed "$name" '' "$@"
}
copilot_row printcopilot '' --print-launch-line --harness copilot -- --allow-all
assert_eq "$RC|$OUT|$(overseers)" "0|$COPILOT_LINE|0" \
  "a copilot overseer's printed line runs copilot on its recorded account with the brief on -i"
# The account its record names holds a stored login and an 80 percent spent
# pool.
mkdir -p "$H/.1copilot"
printf '{"copilot_tokens":"gho_fixture"}\n' > "$H/.1copilot/config.json"
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":200}}}' > "$FIXTURE_DIR/.1copilot.json"
COPILOT_DIRS="$H/.claude:$H/.eclaude:$H/.codex:$H/.1copilot"
LANE_DIRS="$COPILOT_DIRS" copilot_row checkcopilot '' --check-marks --harness copilot
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=20" \
  "a copilot overseer's marks are judged on its account's monthly pool"
fleet_state

# A Copilot overseer succeeds as the others do: at its headroom mark, and on a
# wall, `lanes pick --harness copilot` names a second Copilot account, whose
# status line writes the session record its successor's context is judged on.
# @SL@ is that status line, an executable copilot-statusline.
COP_SL="$TMP_ROOT/sl/copilot-statusline"
mkdir -p "$TMP_ROOT/sl" "$H/.2copilot"
printf '#!/bin/sh\n' > "$COP_SL"
chmod +x "$COP_SL"
printf '{"copilot_tokens":"gho_second"}\n' > "$H/.2copilot/config.json"
printf '{"statusLine":{"type":"command","command":"%s","refreshInterval":30}}\n' "$COP_SL" > "$H/.2copilot/settings.json"
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":900}}}' > "$FIXTURE_DIR/.2copilot.json"
# The caller's own pool at 97 percent used, at or under the headroom trigger.
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":30}}}' > "$FIXTURE_DIR/.1copilot.json"
COPILOT_PAIR="$H/.claude:$H/.eclaude:$H/.codex:$H/.1copilot:$H/.2copilot"
COP_SUCCESSOR="lane=$H/.2copilot;--autopilot;--max-autopilot-continues;3;--context;long_context;--no-auto-update;--allow-all;-i;$BRIEF;"
LANE_DIRS="$COPILOT_PAIR" copilot_row copsucceed '' --harness copilot -- --allow-all
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded copilot)" "0|0 overseer;|no|$COP_SUCCESSOR" \
  "a copilot overseer at its headroom mark succeeds onto the second copilot account"
# The successor starts without a statusLine dependency; its installed
# extension supplies the first usage event to the real hook.
copilot_context_flow "$TMP_ROOT/work" "$H" "$H/.2copilot" "$SRC_DIR" \
  TMUX="$TMUX_ADDR" TMUX_PANE="$(jq -r .overseer.pane "$FLEET_STATE")" \
  ORCH_LANES_FETCH_CMD="$FETCHER" FIXTURE_DIR="$FIXTURE_DIR"
assert_eq "$FLOW_RECORD|$(jq -r '.decision' <<<"$FLOW_STOP")" '199000:217600|block' \
  "oversee-succeed installs a reader that reaches the successor's first turn end"
fleet_state
new_caller "$UNDER_MARK"
record_account "$CALLER_PANE" "$H/.1copilot"
LANE_DIRS="$COPILOT_PAIR" run_succeed copwalled '' --walled-pane "$CALLER_PANE" --harness copilot -- --allow-all
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded copilot)" "0|0 overseer;|no|$COP_SUCCESSOR" \
  "a walled copilot overseer is replaced on the second copilot account"
fleet_state
# The second account's status line gone: it writes no record, so it is no
# successor, and the walk ends with no lane qualifying.
printf '{"enabledFeatureFlags":{"EXTENSIONS":false}}\n' > "$H/.2copilot/settings.json"
LANE_DIRS="$COPILOT_PAIR" copilot_row copnostatus '' --harness copilot -- --allow-all
assert_eq "$RC|$(grep -c "^oversee-succeed: successor-status-line lane=$H/.2copilot entry=caller detail=disabled cause=no-status-line" <<<"$OUT")|$(recorded copilot)" "3|1|none" \
  "a copilot account whose status line writes no record is skipped as a successor"
printf '{"statusLine":{"type":"command","command":"%s","refreshInterval":30}}\n' "$COP_SL" > "$H/.2copilot/settings.json"
fleet_state
# Control: the harness list ol_pick_record once kept, restored, reads a
# copilot account as one lanes does not measure and the succession dies.
COPILOTLIST="$(mutant_scripts copilotlist lib/overseer-launch.sh)" || exit 1
mutate_file "$COPILOTLIST/lib/overseer-launch.sh" '  ol_account_measured "$harness" || return 4' '  case "$harness" in claude | codex | pi) ;; *) return 4 ;; esac'
LANE_DIRS="$COPILOT_PAIR" copilot_row copsucceedctl "$COPILOTLIST/oversee-succeed" --harness copilot -- --allow-all
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" "1|oversee-succeed: lanes-failed entry=caller exit=4" \
  "control: with its own harness list the pick fails a copilot succession as a lanes read that never ran"
# Control: the successor status-line check cut, the account writing no record
# is picked.
COPILOTSL="$(mutant_scripts copilotsl lib/overseer-launch.sh)" || exit 1
mutate_file "$COPILOTSL/lib/overseer-launch.sh" '    if [[ "$OL_HARNESS" == copilot ]] && ! copilot_context_install "$OL_PICKED_DIR"; then' '    if false; then'
printf '{"enabledFeatureFlags":{"EXTENSIONS":false}}\n' > "$H/.2copilot/settings.json"
LANE_DIRS="$COPILOT_PAIR" copilot_row copnostatusctl "$COPILOTSL/oversee-succeed" --harness copilot -- --allow-all
assert_eq "$RC|$(recorded copilot)" "0|$COP_SUCCESSOR" \
  "control: without the check a successor opens on an account whose context nothing measures"
printf '{"statusLine":{"type":"command","command":"%s","refreshInterval":30}}\n' "$COP_SL" > "$H/.2copilot/settings.json"
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":200}}}' > "$FIXTURE_DIR/.1copilot.json"
fleet_state
new_caller "$UNDER_MARK"
run_succeed printcopilotnone '' --print-launch-line --harness copilot -- --allow-all
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" "1|oversee-succeed: copilot-account-unknown pane=$CALLER_PANE" \
  "a copilot overseer whose record names no account prints no line"
# Controls, one per rule: the builder's copilot arm, the refusal of every
# judging mode, and the refusal of a line with no account.
COPILOTARM="$(mutant_scripts copilotarm lib/overseer-launch.sh)" || exit 1
mutate_file "$COPILOTARM/lib/overseer-launch.sh" '    copilot) cmd="copilot" brief_flag=" -i" ;;' '    copilot-x) ;;'
copilot_row printcopilotctl "$COPILOTARM/oversee-succeed" --print-launch-line --harness copilot -- --allow-all
assert_eq "$RC|$(grep -c -F "$COPILOT_ENV COPILOT_HOME='$H/.1copilot' codex " <<<"$OUT")" "0|1" \
  "control: without its arm the copilot line is built as codex's"
COPILOTMODE="$(mutant_scripts copilotmode lib/lane-launch.sh)" || exit 1
mutate_file "$COPILOTMODE/lib/lane-launch.sh" '    claude | codex | copilot) printf' '    claude | codex) printf'
LANE_DIRS="$COPILOT_DIRS" copilot_row checkcopilotctl "$COPILOTMODE/oversee-succeed" --check-marks --harness copilot
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" "0|oversee-succeed: mark-unmeasured kind=headroom reason=headroom-none succession=on" \
  "control: with lanes judging no copilot pick the copilot overseer's account is one lanes measures none of"
COPILOTACCT="$(mutant_scripts copilotacct oversee-succeed)" || exit 1
mutate_file "$COPILOTACCT/oversee-succeed" '[[ "$CALLER_HARNESS" != copilot || -n "$CALLER_CFG" ]] || die copilot-account-unknown' ': || die copilot-account-unknown'
fleet_state
new_caller "$UNDER_MARK"
SUCCEED_BIN="$COPILOTACCT/oversee-succeed" run_succeed printcopilotnonectl '' --print-launch-line --harness copilot -- --allow-all
assert_eq "$RC|$(grep -cF 'detail=relative-home' <<<"$OUT")" "3|1" \
  "control: without the account refusal an unknown account reaches the retained reader gate"
fleet_state

# A Copilot CLI pane reports `node`, its npm loader, or `copilot`, the binary
# started directly, and no reading names a harness before its first turn end;
# with no record and no --harness the harness is the process under the pane
# carrying one of Copilot's own names, `MainThread` the native binary on Linux
# or `copilot`, within two levels, and the account is the COPILOT_HOME, else
# HOME/.copilot, that process was started with (lib/lane-context.sh §
# lane_context_pane_shape). A Copilot run a Codex session starts sits under its
# tool shells, deeper. Each process is a copy of sleep under that name, so ps
# reads the name and no stub runs. A host with no per-process environment to
# read names the harness and no account, and refuses the line.
mkdir -p "$TMP_ROOT/procs"
for proc in MainThread copilot other; do cp "$(command -v sleep)" "$TMP_ROOT/procs/$proc"; done
copilot_node_caller() { # TREE [ENV] — a node or copilot pane with no fleet record
  local p="$TMP_ROOT/procs" run
  local env="${2:-export COPILOT_HOME='$H/.1copilot' HOME='$H'}"
  case "$1" in
    MainThread | copilot | other) run="'$p/$1' 100000 & exec '$BIN/node' 100000" ;;
    # The pane shell stays and runs the loader as its foreground job, so the
    # binary sits two levels down, the layout a shell's `copilot` command makes.
    # Job control is turned on by `set -m` inside the script: Bash 3.2 ignores
    # `-m` on a `-c` command line, which leaves the shell as the pane's
    # foreground process and the pane reading `bash`.
    loader) run="exec bash -c \"set -m; sh -c \\\"'$p/MainThread' 100000 & exec '$BIN/node' 100000\\\"; :\"" ;;
    direct) run="exec '$p/copilot' 100000" ;;
    deep) run="sh -c \"sh -c \\\"'$p/copilot' 100000; :\\\"; :\" & exec '$BIN/node' 100000" ;;
  esac
  fleet_state
  new_caller "$NO_CONTEXT" "$NO_CONTEXT" "cat '$TMP_ROOT/caller.screen'; $env; $run"
}
copilot_model_line() { # ACCOUNT
  printf '%s\n' "$COPILOT_ENV COPILOT_HOME='$1' copilot --autopilot --max-autopilot-continues 3 --context long_context --no-auto-update --model claude-fable-5.1 --reasoning-effort high --allow-all -i '$BRIEF'"
}
# expect_copilot ACCOUNT — the first line a node Copilot pane prints on this host.
expect_copilot() {
  if lane_process_env_readable; then
    printf '0|%s\n' "$(copilot_model_line "$1")"
  else
    printf '1|oversee-succeed: copilot-account-unknown pane=%s\n' "$CALLER_PANE"
  fi
}
# SOURCE names the harness ahead of the pane and leaves the account to it: a
# fleet record naming harness copilot and no account, as register wrote one
# from a Copilot pane with no --account, or --harness copilot.
while IFS='|' read -r tree env source expected; do
  copilot_node_caller "$tree" ${env:+"$env"}
  args=()
  case "$source" in
    record)
      jq --arg server "$SERVER_PID" --arg pane "$CALLER_PANE" --argjson start "$SERVER_START" \
        '.overseer = {runtime: "tmux", generation: 1, server: $server, pane: $pane, harness: "copilot", server_start: $start}' \
        "$FLEET_STATE" > "$FLEET_STATE.tmp" && mv "$FLEET_STATE.tmp" "$FLEET_STATE" ;;
    harness) args=(--harness copilot) ;;
  esac
  case "$expected" in
    copilot:*) expected="$(expect_copilot "${expected#copilot:}")" ;;
    *) expected="1|oversee-succeed: $expected pane=$CALLER_PANE" ;;
  esac
  run_succeed "nodecopilot$tree$source" '' --print-launch-line ${args[@]+"${args[@]}"} -- --model claude-fable-5.1 --reasoning-effort high --allow-all
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")" "$expected" \
    "a pane over the $tree process tree, the harness named by ${source:-the pane}, prints its line ${env:+(}${env}${env:+)}"
done <<ROWS
MainThread|||copilot:$H/.1copilot
copilot|||copilot:$H/.1copilot
loader|||copilot:$H/.1copilot
direct|||copilot:$H/.1copilot
MainThread|unset COPILOT_HOME; export HOME='$H'||copilot:$H/.copilot
MainThread||record|copilot:$H/.1copilot
MainThread||harness|copilot:$H/.1copilot
other|||harness-unnamed
deep|||harness-unnamed
ROWS
# A process table that cannot be read names nothing: the pane is unreadable.
mkdir -p "$TMP_ROOT/psfail"
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/psfail/ps"
chmod +x "$TMP_ROOT/psfail/ps"
copilot_node_caller MainThread
PATH_PREFIX="$TMP_ROOT/psfail" run_succeed nodepsfail '' --print-launch-line -- --allow-all
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" "1|oversee-succeed: pane-unreadable pane=$CALLER_PANE field=process-table" \
  "a node pane whose process table cannot be read refuses as an unreadable pane"
# The same pane at its headroom mark succeeds onto the second Copilot account
# with the predecessor's model, effort and flags, from no record.
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":30}}}' > "$FIXTURE_DIR/.1copilot.json"
COP_MODEL_SUCCESSOR="lane=$H/.2copilot;--autopilot;--max-autopilot-continues;3;--context;long_context;--no-auto-update;--model;claude-fable-5.1;--reasoning-effort;high;--allow-all;-i;$BRIEF;"
copilot_node_caller loader
LANE_DIRS="$COPILOT_PAIR" run_succeed nodecopsucceed '' -- --model claude-fable-5.1 --reasoning-effort high --allow-all
if lane_process_env_readable; then
  assert_eq "$RC|$(layout)|$(caller_open)|$(recorded copilot)" "0|0 overseer;|no|$COP_MODEL_SUCCESSOR" \
    "a node pane over Copilot's binary with no record succeeds onto the second copilot account at its headroom mark"
else
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(recorded copilot)" "1|oversee-succeed: copilot-account-unknown pane=$CALLER_PANE|none" \
    "a node pane over Copilot's binary on a host with no process environment refuses for want of an account"
fi
# Controls, one per rule of the reader and of the caller's use of its account.
# Each mutates a copy and runs the MainThread row's pane unless it names one.
while IFS='@' read -r name file old new tree env expected; do
  dir="$(mutant_scripts "$name" "$file")" || exit 1
  mutate_file "$dir/$file" "$old" "$new"
  copilot_node_caller "$tree" ${env:+"$env"}
  case "$expected" in
    copilot:*) expected="$(expect_copilot "${expected#copilot:}")" ;;
    *) expected="1|oversee-succeed: $expected pane=$CALLER_PANE" ;;
  esac
  SUCCEED_BIN="$dir/oversee-succeed" run_succeed "$name" '' --print-launch-line -- --model claude-fable-5.1 --reasoning-effort high --allow-all
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")" "$expected" "control $name: $file without its rule reads the $tree pane wrongly"
done <<ROWS
nodecopilotctl@lib/lane-context.sh@    node | copilot)@    node-x)@MainThread@@harness-unnamed
nodedepthctl@lib/lane-context.sh@"\$name_re" 1 2 pids)@"\$name_re" 1 "" pids)@deep@@copilot:$H/.1copilot
nodeselfctl@lib/lane-context.sh@"\$name_re" 1 2 pids)@"\$name_re" 0 2 pids)@direct@@harness-unnamed
nodecophomectl@lib/lane-context.sh@            COPILOT_HOME=*)@            COPILOT_HOME-X=*)@MainThread@@copilot:$H/.copilot
nodehomectl@lib/lane-context.sh@copilot_home="\$home/.copilot"@copilot_home=""@MainThread@unset COPILOT_HOME; export HOME='$H'@copilot-account-unknown
nodeacctctl@oversee-succeed@|| CALLER_CFG="\$LANE_PANE_ACCOUNT"@|| :@MainThread@@copilot-account-unknown
ROWS
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":200}}}' > "$FIXTURE_DIR/.1copilot.json"
fleet_state

# The printed line is replayed verbatim into a DEAD pane, and nobody is at that
# pane to answer a folder-trust question either. A codex line therefore carries
# the same preparation a live succession makes and names the home the trust was
# made in, rather than the bare account: the two are one launch, and a line
# recorded without it relaunches onto the very question this preparation exists
# to answer ahead of the pane.
# Each row pins the LINE alone. Whether that home trusts the directory is the
# walled row's clause above and lane-launch-trust.sh's, and both have already
# written this very home by the time a print row runs: asserting it here would
# read back another row's state rather than this mode's own.
# --print-launch-line's one control. The preparation is made in
# lib/overseer-launch.sh's ol_command_line, the one builder every launch and
# every printed line go through, so the copy whose builder skips it is what a
# print without the preparation would record.
PRINTSKIP="$(mutant_scripts printskip lib/overseer-launch.sh)" || exit 1
awk -v call='  if ! lane_trust_prepare "$harness" "$lane_dir" "$launch_dir"; then' \
  '$0 == call { print "  LANE_TRUST_HOME=\"$lane_dir\" LANE_TRUST_ROUTE=none LANE_TRUST_REASON=\"\"; if false; then"; calls++; next }
   { print }
   END { if (calls != 1) exit 1 }' "$SRC_DIR/lib/overseer-launch.sh" > "$PRINTSKIP/lib/overseer-launch.sh" \
  || { echo "fixture: printskip found no single site to mutate" >&2; exit 1; }
assert_eq "$(cmp -s "$PRINTSKIP/lib/overseer-launch.sh" "$SRC_DIR/lib/overseer-launch.sh" && echo same || echo differs)|$(bash -n "$PRINTSKIP/lib/overseer-launch.sh" && echo parses || echo broken)" \
  "differs|parses" "control printskip really drops the preparation from the builder"
new_caller "$CODEX_SCREEN" 'Context 48% left'
PRINT_CWD="$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')"
PRINT_HOME="$(lane_codex_home_path "$H/.codex" "$PRINT_CWD")"
CALLER_LANE="CODEX_HOME=$H/.codex" SUCCEED_BIN="$PRINTSKIP/oversee-succeed" \
  run_succeed printskip '' --print-launch-line
assert_eq "$RC|$OUT" "0|env CODEX_HOME='$H/.codex' ORCH_COMPACTION_OVERRIDES='$CODEX_COMPACTION' codex -c check_for_update_on_startup=false -c features.daemon_auto_start=false --dangerously-bypass-hook-trust -c model_auto_compact_token_limit=9223372036854775807 -c model_auto_compact_token_limit_scope=body_after_prefix -c model_post_turn_compact_threshold_percent=0 '$BRIEF'" \
  "control: a print that skips the preparation records the bare account, not the prepared home"

# Both arms of lib/lane-context.sh's answer for the caller's own lane: the
# variable where the session carries one, and the default under LANES_HOME where
# it names none. Neither may answer the empty string, which the preparation
# would meet as no lane and refuse.
for row in \
  "CODEX_HOME=$H/.codex|a CODEX_HOME the session carries" \
  "none|the default under LANES_HOME, the session naming no account variable" \
  ; do
  IFS='|' read -r row_lane row_what <<<"$row"
  new_caller "$CODEX_SCREEN" 'Context 48% left'
  CALLER_LANE="$row_lane" run_succeed printcodex '' --print-launch-line
  assert_eq "$RC|$OUT|$(overseers)" "0|env CODEX_HOME='$PRINT_HOME' ORCH_COMPACTION_OVERRIDES='$CODEX_COMPACTION' codex -c check_for_update_on_startup=false -c features.daemon_auto_start=false --dangerously-bypass-hook-trust -c model_auto_compact_token_limit=9223372036854775807 -c model_auto_compact_token_limit_scope=body_after_prefix -c model_post_turn_compact_threshold_percent=0 '$BRIEF'|0" \
    "--print-launch-line on a codex caller records the home trust was made in, under $row_what"
done
# A codex caller launched by this script already runs with the startup update
# check off, and a caller entry hands its flags on whole: the line still carries
# the setting once, where the successor build writes it.
new_caller "$CODEX_SCREEN" 'Context 48% left'
CALLER_LANE="CODEX_HOME=$H/.codex" run_succeed printcodex-settings '' --print-launch-line -- \
  --verbose -c check_for_update_on_startup=false -c features.daemon_auto_start=false --dangerously-bypass-hook-trust
assert_eq "$RC|$OUT" "0|env CODEX_HOME='$PRINT_HOME' ORCH_COMPACTION_OVERRIDES='$CODEX_COMPACTION' codex -c check_for_update_on_startup=false -c features.daemon_auto_start=false --dangerously-bypass-hook-trust -c model_auto_compact_token_limit=9223372036854775807 -c model_auto_compact_token_limit_scope=body_after_prefix -c model_post_turn_compact_threshold_percent=0 --verbose '$BRIEF'" \
  "a codex caller entry carrying the update setting keeps it exactly once"

# A codex caller is judged on the window its own rollout names, like any other.
# The account mark still reads a figure here, and the account it reads is the
# codex default: this session names no account variable, and the harness its
# recorded reading names is what turns that silence into a directory. The codex
# fixture holds 80 percent headroom, well above the trigger.
new_caller "$CODEX_SCREEN" 'Context 48% left'
CALLER_LANE=none run_succeed codexwindow ''
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=258400 mark=50 headroom=80|yes|0" \
  "a codex caller with room ends under the context mark of its own 258400 window"

# Printing launches nothing, so the setting that governs launching does not
# gate it: the record is what an owner's later relaunch by hand reads.
new_caller "$UNDER_MARK"
SUCCESSION=off run_succeed printoff '' --print-launch-line
assert_eq "$RC|$OUT|$(overseers)" \
  "0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer $CLAUDE_COMPACT_LINE '$BRIEF'|0" \
  "succession off still prints the line: printing launches nothing"

# A successor overseer carries the words that take its harness question tool
# away, the words every lane launch carries, unless ORCH_QUESTION_TOOL is
# `overseer`; unset is off. The setting alone decides: a caller's own copy of
# the words is dropped under overseer and carried once under off. A value
# that is neither refuses before a line is built.
for row in \
  "claude|unset||0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer $CLAUDE_COMPACT_LINE --disallowedTools=AskUserQuestion\\,EnterPlanMode '$BRIEF'|unset takes the claude question tool away" \
  "claude|off||0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer $CLAUDE_COMPACT_LINE --disallowedTools=AskUserQuestion\\,EnterPlanMode '$BRIEF'|off takes the claude question tool away" \
  "claude|overseer||0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer $CLAUDE_COMPACT_LINE '$BRIEF'|overseer keeps the claude question tool" \
  "claude|overseer|--disallowedTools=AskUserQuestion,EnterPlanMode --verbose|0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer $CLAUDE_COMPACT_LINE --verbose '$BRIEF'|overseer drops the caller's own question-tool words" \
  "claude|off|--disallowedTools=AskUserQuestion,EnterPlanMode --verbose|0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer $CLAUDE_COMPACT_LINE --disallowedTools=AskUserQuestion\\,EnterPlanMode --verbose '$BRIEF'|off carries a caller's own copy of the words once" \
  "codex|off||0|env CODEX_HOME='$PRINT_HOME' ORCH_COMPACTION_OVERRIDES='$CODEX_COMPACTION' codex -c check_for_update_on_startup=false -c features.daemon_auto_start=false --dangerously-bypass-hook-trust -c model_auto_compact_token_limit=9223372036854775807 -c model_auto_compact_token_limit_scope=body_after_prefix -c model_post_turn_compact_threshold_percent=0 -c features.default_mode_request_user_input=false '$BRIEF'|off takes the codex question tool away" \
  "claude|on||1|oversee-succeed: invalid-question-tool ORCH_QUESTION_TOOL=on|on is not a value: refused before a line is built" \
  "claude|sometimes||1|oversee-succeed: invalid-question-tool ORCH_QUESTION_TOOL=sometimes|a value that is neither off nor overseer refuses" \
  ; do
  IFS='|' read -r row_harness row_value row_flags row_rc row_want row_what <<<"$row"
  if [[ "$row_harness" == codex ]]; then
    new_caller "$CODEX_SCREEN" 'Context 48% left'
    row_lane="CODEX_HOME=$H/.codex"
  else
    new_caller "$UNDER_MARK"
    row_lane="CLAUDE_CONFIG_DIR=$H/.claude"
  fi
  # shellcheck disable=SC2086  # a row's flags are its own words, split on purpose.
  CALLER_LANE="$row_lane" QUESTION_TOOL="$row_value" run_succeed "printquestion-$row_harness" '' --print-launch-line \
    ${row_flags:+-- $row_flags}
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" "$row_rc|$row_want|0" "question tool: $row_what"
done

# The dead overseer's window: a pane running no harness and recorded by nothing,
# at an index of its own, so a row reads which window the successor
# landed in and whether the caller's own was touched.
new_dead_pane() {
  local spec
  spec="$(tm new-window -d -t fleet:5 -c "$TMP_ROOT/work" -P -F '#{pane_id} #{window_id}' 'exec sleep 100000')"
  read -r DEAD_PANE DEAD_WINDOW <<<"$spec"
}
dead_open() { if [[ "$(tm list-windows -t fleet -F '#{window_id}')" == *"$DEAD_WINDOW"* ]]; then echo yes; else echo no; fi; }
overseer_index() { tm list-windows -t fleet -F '#{window_index} #{window_name}' | awk '$2 == "overseer" { printf "%s", $1 }'; }
# The recorded line names its lane, as every line the print and succeed modes
# build does: the harness reads that lane's own folder trust.
RECORDED_LINE="env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer 'relaunched from the record'"
printf '%s\n' "$RECORDED_LINE" > "$TMP_ROOT/line-file"

# A mistyped ORCH_QUESTION_TOOL rides along: the recorded line is sent
# as it stands, so the setting is not read and cannot refuse the relaunch.
new_caller "$MARK"
new_dead_pane
QUESTION_TOOL=sometimes run_succeed deadpane '' --dead-pane "$DEAD_PANE" --line-file "$TMP_ROOT/line-file"
assert_eq "$RC|$(overseer_index)|$(caller_open)|$(dead_open)|$(recorded claude)" \
  "0|0|yes|no|lane=$H/.claude;-n;overseer;relaunched from the record;" \
  "--dead-pane sends the recorded line into the dead overseer's window, asking that pane nothing, a mistyped question-tool setting unread"
new_caller "$MARK"
new_dead_pane
SUCCESSION=off run_succeed deadoff '' --dead-pane "$DEAD_PANE" --line-file "$TMP_ROOT/line-file"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(dead_open)|$(recorded claude)" \
  "0|oversee-succeed: succession-off ORCH_OVERSEER_SUCCESSION=off|0|yes|none" \
  "succession off refuses the relaunch, and the dead window stays as it was"
# A relaunch whose successor never shows a running turn is refused, and the
# watch that ran it logs that failure itself, so this run writes no fleet log
# row: its words would say a caller keeps running that is dead.
new_caller "$MARK"
new_dead_pane
fleet_state
touch "$TMP_ROOT/idle"
VIRTUAL_CLOCK=1 run_succeed deadidle '' --dead-pane "$DEAD_PANE" --line-file "$TMP_ROOT/line-file" --wait-secs "$IDLE_WAIT"
rm -f "${TMP_ROOT:?}/idle"
assert_eq "$RC|$(keyed successor-not-working "$OUT" | sed -n 1p | cut -d' ' -f1-2)|$(idle_log)" \
  "1|oversee-succeed: successor-not-working|" \
  "a dead-pane relaunch whose successor never works writes no fleet log row"
# Its control: an abandon that logs in every mode writes the row here too.
DEADLOGCTL="$(mutant_scripts deadlogctl oversee-succeed)" || exit 1
mutate_file "$DEADLOGCTL/oversee-succeed" '  [[ "${MODE:-}" != succeed ]] || fleet_log_refusal "$@"' '  fleet_log_refusal "$@"'
new_caller "$MARK"
new_dead_pane
fleet_state
touch "$TMP_ROOT/idle"
VIRTUAL_CLOCK=1 SUCCEED_BIN="$DEADLOGCTL/oversee-succeed" run_succeed deadlogctl '' --dead-pane "$DEAD_PANE" --line-file "$TMP_ROOT/line-file" --wait-secs "$IDLE_WAIT"
rm -f "${TMP_ROOT:?}/idle"
assert_eq "$RC|$(idle_log | cut -d' ' -f1-4)" \
  "1|close overseer oversee-succeed: successor-not-working" \
  "control: an abandon logging in every mode writes a dead-pane row"

# What the four modes refuse of each other. Each is a different run, and a
# combination read as one of the others would send a line built for another
# pane, none at all, or judge a mark against a pane that is dead. Every row
# refuses before tmux is asked anything.
: > "$TMP_ROOT/empty-line"
for row in \
  "--dead-pane %9 --line-file $TMP_ROOT/line-file -- --verbose|mode-conflict dead-pane=%9 print=0 check=0 flags=1 walled-pane=none|permission flags beside a recorded line" \
  "--dead-pane %9 --print-launch-line --line-file $TMP_ROOT/line-file|mode-conflict dead-pane=%9 print=1 check=0 flags=0 walled-pane=none|a print asked of a dead pane" \
  "--dead-pane %9 --check-marks --line-file $TMP_ROOT/line-file|mode-conflict dead-pane=%9 print=0 check=1 flags=0 walled-pane=none|a mark judged on a dead pane" \
  "--check-marks -- --verbose|mode-conflict check=1 print=0 line-file=none flags=1 handoff=0 wait-secs=0|permission flags beside a judgement that launches nothing" \
  "--check-marks --print-launch-line|mode-conflict check=1 print=1 line-file=none flags=0 handoff=0 wait-secs=0|a judgement and a printed line at once" \
  "--check-marks --handoff tmp/other.md|mode-conflict check=1 print=0 line-file=none flags=0 handoff=1 wait-secs=0|a handoff path for a run that opens no window" \
  "--check-marks --wait-secs 5|mode-conflict check=1 print=0 line-file=none flags=0 handoff=0 wait-secs=1|a successor deadline for a run that launches no successor" \
  "--dead-pane %9|mode-conflict dead-pane=%9 line-file=none|a dead pane with no line to send" \
  "--line-file $TMP_ROOT/line-file|mode-conflict line-file=$TMP_ROOT/line-file dead-pane=none|a line file with no dead pane" \
  "--print-launch-line --line-file $TMP_ROOT/line-file|mode-conflict print=1 line-file=$TMP_ROOT/line-file|a line file beside a print" \
  "--dead-pane fleet:5 --line-file $TMP_ROOT/line-file|invalid-dead-pane value=fleet:5|a window target where a pane id belongs" \
  "--dead-pane %9 --line-file $TMP_ROOT/nosuch|invalid-line-file path=$TMP_ROOT/nosuch|a line file that is not there" \
  "--dead-pane %9 --line-file $TMP_ROOT/empty-line|invalid-line-file path=$TMP_ROOT/empty-line|a line file holding nothing"; do
  IFS='|' read -r row_args row_want row_label <<<"$row"
  new_caller "$MARK"
  # shellcheck disable=SC2086
  run_succeed modeguard '' $row_args
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(caller_open)" \
    "1|oversee-succeed: $row_want|0|yes" \
    "$row_label: refused, nothing launched"
done

# A succession without fleet state cannot prove the handoff generation.
mv -- "$FLEET_STATE" "$TMP_ROOT/fleet-state.away"
new_caller "$MARK"
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
run_succeed nostate ''
assert_eq "$RC|$(keyed handoff-stale "$OUT" | sed -n 1p)|$(overseers)|$(caller_open)" \
  "1|oversee-succeed: handoff-stale path=tmp/handoffs/OVERSEER-HANDOFF.md expected=unknown|0|yes" \
  "a succession without fleet state refuses before opening a successor"
mv -- "$TMP_ROOT/fleet-state.away" "$FLEET_STATE"

# The predecessor writes this text protocol (../references/communication-modes.md § Handoff).
# Older handoffs have no header; a delayed writer can carry an earlier generation.
HANDOFF_FILE="$TMP_ROOT/work/tmp/handoffs/OVERSEER-HANDOFF.md"
for row in \
  'legacy|1|In flight: open item|1' \
  'stale|1|Start here: 2026-10-01T00:00:00Z generation=0|1' \
  'future|1|Start here: 2026-10-01T00:00:00Z generation=2|1' \
  'prepended|1|Start here: 2026-10-01T00:00:00Z generation=1\nStart here: 2026-10-01T00:00:00Z generation=1|1' \
  'missing|1||1' \
  'empty-generation|""|In flight: open item|unknown' \
  'text-generation|"current"|Start here: 2026-10-01T00:00:00Z generation=1|unknown' \
  'fractional-generation|1.5|Start here: 2026-10-01T00:00:00Z generation=1|unknown' \
  'negative-generation|-1|Start here: 2026-10-01T00:00:00Z generation=1|unknown' \
  ; do
  IFS='|' read -r row_name row_generation row_text row_expected <<<"$row"
  fleet_state
  jq --argjson generation "$row_generation" '.overseer.generation = $generation' \
    "$FLEET_STATE" > "$FLEET_STATE.tmp" || exit 1
  mv -- "$FLEET_STATE.tmp" "$FLEET_STATE"
  new_caller "$MARK"
  printf '%b\n' "$row_text" > "$HANDOFF_FILE"
  [[ "$row_name" != missing ]] || rm -- "$HANDOFF_FILE"
  HANDOFF_FIXTURE=off run_succeed "handoff-$row_name" ''
  assert_eq "$RC|$(keyed handoff-stale "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
    "1|oversee-succeed: handoff-stale path=tmp/handoffs/OVERSEER-HANDOFF.md expected=$row_expected|yes|0" \
    "handoff $row_name: refuse before launching"
done
# One current snapshot replaces the predecessor's stale header, then the real
# succession launches and records the successor generation.
fleet_state
new_caller "$MARK"
printf 'Start here: 2026-10-01T00:00:00Z generation=0\n' > "$HANDOFF_FILE"
run_succeed handoff-rewritten ''
assert_eq "$RC|$(caller_open)|$(overseers)|$(orec generation)" '0|no|1|2' \
  'a replacement snapshot admits one succession'

# The watch recovers a predecessor that could not rewrite its handoff.
# Its dead and walled modes must launch without a current snapshot.
RECOVERYCTL="$(mutant_scripts recoveryctl oversee-succeed)" || exit 1
mutate_file "$RECOVERYCTL/oversee-succeed" \
  'if [[ "$MODE" == succeed ]]; then' \
  'if [[ "$MODE" == succeed || "$MODE" == dead || "$MODE" == walled ]]; then'
claude_usage 20 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
for row in \
  'dead|stale|normal|0|1|yes|2|0' \
  'dead|missing|normal|0|1|yes|2|0' \
  'walled|stale|normal|0|1|no|2|0' \
  'walled|missing|normal|0|1|no|2|0' \
  'walled|stale|control|1|0|yes|1|1' \
  ; do
  IFS='|' read -r row_mode row_handoff row_script row_rc row_count row_open row_generation row_stale <<<"$row"
  fleet_state
  new_caller "$MARK"
  row_text='Start here: 2026-10-01T00:00:00Z generation=0'
  printf '%s\n' "$row_text" > "$HANDOFF_FILE"
  if [[ "$row_handoff" == missing ]]; then
    rm -- "$HANDOFF_FILE"
    row_text=absent
  fi
  row_args=(--walled-pane "$CALLER_PANE")
  if [[ "$row_mode" == dead ]]; then
    new_dead_pane
    row_args=(--dead-pane "$DEAD_PANE" --line-file "$TMP_ROOT/line-file")
  fi
  row_bin="$SUCCEED"
  [[ "$row_script" != control ]] || row_bin="$RECOVERYCTL/oversee-succeed"
  SUCCEED_BIN="$row_bin" run_succeed "recovery-$row_mode-$row_handoff-$row_script" '' "${row_args[@]}"
  handoff_text=absent
  [[ ! -f "$HANDOFF_FILE" ]] || handoff_text="$(cat -- "$HANDOFF_FILE")"
  stale_count="$(awk '/^oversee-succeed: handoff-stale / { n++ } END { print n+0 }' <<<"$OUT")"
  assert_eq "$RC|$(overseers)|$(caller_open)|$(orec generation)|$stale_count|$handoff_text" \
    "$row_rc|$row_count|$row_open|$row_generation|$row_stale|$row_text" \
    "recovery $row_mode/$row_handoff/$row_script: only live self-succession requires a current handoff"
done
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"

HANDOFFCTL="$(mutant_scripts handoffctl oversee-succeed)" || exit 1
mutate_file "$HANDOFFCTL/oversee-succeed" \
  '[[ "$handoff_generation" == "$generation" ]]' \
  '[[ "$handoff_generation" == "$generation" ]] || true'
fleet_state
new_caller "$MARK"
printf 'Start here: 2026-10-01T00:00:00Z generation=0\n' > "$HANDOFF_FILE"
HANDOFF_FIXTURE=off SUCCEED_BIN="$HANDOFFCTL/oversee-succeed" run_succeed handoffctl ''
assert_eq "$RC|$(caller_open)|$(overseers)" '0|no|1' \
  'control: disabling the generation comparison admits the stale snapshot'

HANDOFFGENCTL="$(mutant_scripts handoffgenctl oversee-succeed)" || exit 1
mutate_file "$HANDOFFGENCTL/oversee-succeed" \
  '[[ "$generation" =~ ^[0-9]+$ ]]' \
  '[[ "$generation" =~ ^[0-9]+$ ]] || true'
fleet_state
jq '.overseer.generation = ""' "$FLEET_STATE" > "$FLEET_STATE.tmp" || exit 1
mv -- "$FLEET_STATE.tmp" "$FLEET_STATE"
new_caller "$MARK"
printf 'In flight: open item\n' > "$HANDOFF_FILE"
HANDOFF_FIXTURE=off SUCCEED_BIN="$HANDOFFGENCTL/oversee-succeed" run_succeed handoffgenctl ''
assert_eq "$RC|$(caller_open)|$(overseers)" '0|no|1' \
  'control: disabling generation validation admits an empty generation without Start here'

# --dead-pane's one control: the dead pane asked for its harness after all.
# It runs none, so the relaunch refuses and the fleet keeps no overseer —
# which is what the recorded line exists to prevent.
DEADCTL="$(mutant_scripts deadctl oversee-succeed)" || exit 1
mutate_file "$DEADCTL/oversee-succeed" 'if [[ "$MODE" != dead ]]; then' 'if true; then'
new_caller "$MARK"
new_dead_pane
SUCCEED_BIN="$DEADCTL/oversee-succeed" run_succeed deadctl '' --dead-pane "$DEAD_PANE" --line-file "$TMP_ROOT/line-file"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(dead_open)" \
  "1|oversee-succeed: harness-unnamed pane=$DEAD_PANE|0|yes" \
  "control: a mode that reads the dead pane refuses it and launches no successor"

# ORCH_OVERSEER_HEADROOM_PCT over the same screen. A value the guard lets
# through reaches bash arithmetic, and a malformed one would read as 0: the
# account mark would never fire and the pick bound would fall to 0, opening
# successors on accounts at the wall.
for row in \
  "twenty|1|oversee-succeed: invalid-headroom-trigger ORCH_OVERSEER_HEADROOM_PCT=twenty" \
  "101|1|oversee-succeed: invalid-headroom-trigger ORCH_OVERSEER_HEADROOM_PCT=101" \
  "-5|1|oversee-succeed: invalid-headroom-trigger ORCH_OVERSEER_HEADROOM_PCT=-5"; do
  IFS='|' read -r row_value row_rc row_want <<<"$row"
  new_caller "$MARK"
  HEADROOM_PCT="$row_value" run_succeed headroomguard 'claude:fable:high'
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
    "$row_rc|$row_want|0|none" \
    "headroom trigger $row_value: refused, nothing launched"
done

# A valid NON-DEFAULT trigger, read end to end: the caller sits at 50 headroom,
# which is above the default 10 and at or below 60, so only a setting that is
# actually read fires the account mark here.
new_caller "$UNDER_MARK"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 20 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
HEADROOM_PCT=60 run_succeed headroomset 'claude:fable:high'
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|0 overseer;|no|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$CLAUDE_COMPACT;$BRIEF;" \
  "a non-default trigger is read: 50 headroom fires the account mark at 60"

# The trigger's own boundary, caller side. `at or below` is the documented
# rule, so exactly TRIGGER fires and one percent above it does not.
new_caller "$UNDER_MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed calleratbound 'claude:fable:high'
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|0 overseer;|no|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$CLAUDE_COMPACT;$BRIEF;" \
  "caller at exactly the trigger fires the account mark"

new_caller "$UNDER_MARK"
claude_usage "$ABOVE_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
run_succeed callerabovebound 'claude:fable:high'
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=$((TRIGGER + 1))|0|none" \
  "caller one percent above the trigger falls through to the context mark"

# The SHIPPED default, which no row above pins: every one of them derives its
# fixtures from TRIGGER, so a default that drifts carries them along with it.
# These two rows state their figures literally instead. The 7 in each sits
# above the shipped default and below 10. Raising the default to 10 flips
# both answers. The pair covers both jobs the number does.
#
# The mark side: a caller with room to spare under the shipped default is not
# succeeded on its account, and the context mark answers for it instead.
new_caller "$UNDER_MARK"
claude_usage 93 0 0 Opus > "$FIXTURE_DIR/.claude.json"
run_succeed defaultspares 'claude:fable:high'
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=7|0|none" \
  "the shipped default leaves a caller at 7 percent headroom unsucceeded"

# The floor side, which is the job the shipped default answers: the caller is
# past its own mark and the only candidate sits at 7, so the successor opens
# there. A larger default rules that candidate out and refuses the succession.
new_caller "$UNDER_MARK"
claude_usage 95 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 93 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed defaultfloor 'claude:fable:high'
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|0 overseer;|no|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$CLAUDE_COMPACT;$BRIEF;" \
  "the shipped default opens the successor on a candidate at 7 percent headroom"

# The same boundary on the pick side: the only candidate sits exactly at the
# trigger and must be refused, then one percent above it and must be chosen.
new_caller "$MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed pickatbound 'claude:fable:high'
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: no-lane-qualifies entries=1 fallback=claude walled=4 unmeasured=0 mark=headroom account=claude resets=$CLAUDE_USAGE_SESSION_RESET|yes|0|none" \
  "a candidate at exactly the trigger is refused, not picked"

new_caller "$MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage "$ABOVE_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed pickabovebound 'claude:fable:high'
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|0 overseer;|no|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$CLAUDE_COMPACT;$BRIEF;" \
  "a candidate one percent above the trigger is chosen"

# An account nothing could measure is its own state, never a healthy one. With
# no usage body the caller's lane reports no headroom, so the context-mark
# succession must still go through the pick rather than reopen on the unchecked
# caller account.
new_caller "$MARK"
mv "$FIXTURE_DIR/.claude.json" "$FIXTURE_DIR/.claude.json.held"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed unmeasured ''
mv "$FIXTURE_DIR/.claude.json.held" "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|0 overseer;|no|lane=$H/.eclaude;-n;overseer;$CLAUDE_COMPACT;$BRIEF;" \
  "an unmeasured caller account is not reused at the context mark"

# The same unmeasured account where the pick names NO lane. At the context
# mark the successor spends the account the caller already spends, so the
# caller's own account is kept, named on one keyed line with its record's
# status and detail and in one fleet-log row, rather than leaving a person to
# hand over by hand.
fleet_state
new_caller "$MARK"
mv "$FIXTURE_DIR/.claude.json" "$FIXTURE_DIR/.claude.json.held"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed unmeasuredwall ''
mv "$FIXTURE_DIR/.claude.json.held" "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
assert_eq "$RC|$(grep -m1 '^oversee-succeed: successor-account-unmeasured ' <<<"$OUT" | sed 's/ detail=.*/ detail=/')|$(caller_open)|$(recorded claude)|$(jq -r --arg l "oversee-succeed: successor-account-unmeasured lane=$H/.claude status=unreachable detail=" '[(.fleet_log // [])[] | select(.text | startswith($l))] | length' "$FLEET_STATE")" \
  "0|oversee-succeed: successor-account-unmeasured lane=$H/.claude status=unreachable detail=|no|lane=$H/.claude;-n;overseer;$CLAUDE_COMPACT;$BRIEF;|1" \
  "an unmeasured caller with every lane of its harness walled keeps its own account at the context mark"

# The same wall with the caller's own account MEASURED at the trigger: the
# refusal names that account and when its binding bucket frees up, and the
# caller's own lane is not reopened on the way there either.
new_caller "$UNDER_MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed callerwall ''
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: no-lane-qualifies entries=0 fallback=claude walled=2 unmeasured=0 mark=headroom account=claude resets=$CLAUDE_USAGE_SESSION_RESET|yes|0|none" \
  "a caller at the trigger with every lane walled refuses at the account mark"

# A claim from this server already naming the caller's pane changes nothing
# about which account the mark judges: that is the account this session's own
# environment names, whatever the claim store holds, and at the trigger the
# mark fires and the successor goes to the lane the pick names.
new_caller "$UNDER_MARK"
write_own_claim claimedcaller "$CALLER_PANE" "$H/.claude"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed claimedcaller ''
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|0 overseer;|no|lane=$H/.eclaude;-n;overseer;$CLAUDE_COMPACT;$BRIEF;" \
  "a claim on the caller pane does not move the judged account, and its account mark fires"

# The other side of that rule: a caller account MEASURED above the trigger
# keeps its own lane, and it is the one launch `lanes pick` does not name. The
# two answers are made to differ — the caller holds 50 percent headroom and the
# other claude lane 90, so the pick would name the other one — because a
# fixture where both answers agree passes whether the rule is read or not.
new_caller "$MARK"
claude_usage 50 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 10 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed callerhasroom ''
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|0 overseer;|no|lane=$H/.claude;-n;overseer;$CLAUDE_COMPACT;$BRIEF;" \
  "a caller with room above the trigger keeps its own lane, not the roomier one the pick names"

# The account mark reads the buckets THIS session spends. The caller's recorded
# reading names Fable, and its account's only spent window is scoped to Opus at
# exactly the trigger: that window walls no Fable turn, so the mark does not
# fire and the run falls through to the context mark, which reports the
# model-scoped headroom it read. The caller's model is what decides it, so the
# matched row below moves the same percentage onto the Fable window and the
# mark fires.
new_caller "$UNDER_MARK"
jq -n --argjson m "$AT_TRIGGER" '{
  five_hour: {utilization: 0, resets_at: "2099-07-27T06:00:00Z"},
  seven_day: {utilization: 0, resets_at: "2099-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: $m, resets_at: "2099-08-01T06:00:00Z",
            scope: {model: {display_name: "Opus"}}}]
}' > "$FIXTURE_DIR/.claude.json"
run_succeed unmatchedbucket 'claude:fable:high'
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=100|0|none" \
  "a spent window scoped to a model this overseer does not run leaves the account mark unfired"

# The matched side of the same rule: the spent window is scoped to the model
# the caller's own recorded reading names, so it walls this session and the mark
# fires. Nothing but the window's label differs from the row above. The
# second claude lane has room, so the successor has somewhere to go.
new_caller "$UNDER_MARK"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
jq -n --argjson m "$AT_TRIGGER" '{
  five_hour: {utilization: 0, resets_at: "2099-07-27T06:00:00Z"},
  seven_day: {utilization: 0, resets_at: "2099-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: $m, resets_at: "2099-08-01T06:00:00Z",
            scope: {model: {display_name: "Fable 5.1"}}}]
}' > "$FIXTURE_DIR/.claude.json"
run_succeed matchedbucket 'claude:fable:high'
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|0 overseer;|no|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$CLAUDE_COMPACT;$BRIEF;" \
  "a spent window scoped to the model this overseer runs fires the account mark"

# The model reaches the account mark on every claude tier, not only the ones
# the window table names. This caller runs Sonnet 4.5, which that table leaves out,
# so its reading carries no window. Judged with no model at all, this account's
# only spent window, scoped to Opus at exactly the trigger, would fire and hand
# the session over for a window no Sonnet turn draws on.
new_caller "$NO_TABLE_TIER"
jq -n --argjson m "$AT_TRIGGER" '{
  five_hour: {utilization: 0, resets_at: "2099-07-27T06:00:00Z"},
  seven_day: {utilization: 0, resets_at: "2099-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: $m, resets_at: "2099-08-01T06:00:00Z",
            scope: {model: {display_name: "Opus"}}}]
}' > "$FIXTURE_DIR/.claude.json"
run_succeed tiernotintable 'claude:fable:high'
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-unmeasured reason=window-unnamed headroom=100|0|none" \
  "a tier the window table leaves out still carries its model into the account mark"

# The caller fallback entry names no model in the LAUNCH, and its pick is still
# judged on one: that successor carries this overseer's own flags, so it runs
# the model this pane runs. The second claude lane has room for it, its shared
# windows reading 5 and 20, and its Opus window at 95 walls nothing either
# overseer will draw on. Judged with no model the pick reads that 95 and
# refuses an account that would have carried the successor.
new_caller "$UNDER_MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
jq -n '{
  five_hour: {utilization: 5, resets_at: "2099-07-27T06:00:00Z"},
  seven_day: {utilization: 20, resets_at: "2099-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: 95, resets_at: "2099-08-01T06:00:00Z",
            scope: {model: {display_name: "Opus"}}}]
}' > "$FIXTURE_DIR/.eclaude.json"
run_succeed callerfallbackmodel ''
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|0 overseer;|no|lane=$H/.eclaude;-n;overseer;$CLAUDE_COMPACT;$BRIEF;" \
  "the caller fallback pick is judged on the model this overseer runs"

# The successor pick and the successor's own first judgement read ONE bucket.
# The second claude lane has room for the model this entry passes, its Fable
# window being at 10, and its Opus window is at 95. The entry launches Fable, so
# the Opus window walls nothing that successor will run: it is picked, and at
# its own account mark it reads the same Fable-scoped figure and keeps running.
# Held to the account-wide bucket instead, the pick would refuse this lane over
# a window neither overseer spends and the fleet would sit on a walled caller.
new_caller "$UNDER_MARK"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"
jq -n '{
  five_hour: {utilization: 5, resets_at: "2099-07-27T06:00:00Z"},
  seven_day: {utilization: 20, resets_at: "2099-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: 95, resets_at: "2099-08-01T06:00:00Z",
            scope: {model: {display_name: "Opus"}}},
           {kind: "weekly_scoped", percent: 10, resets_at: "2099-08-01T06:00:00Z",
            scope: {model: {display_name: "Fable 5.1"}}}]
}' > "$FIXTURE_DIR/.eclaude.json"
run_succeed bindingfloor 'claude:fable:high'
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|0 overseer;|no|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$CLAUDE_COMPACT;$BRIEF;" \
  "a lane with room for the entry's model and none outside it is opened on"

# Which reading the pick is held to is lib/lane-context.sh's answer, because it
# is the rule the successor's own account mark applies to its recorded reading
# later. A claude successor is judged on its model, so the pick names it too
# and the two judgements read one bucket. A codex successor is judged on the
# account's binding bucket whatever model it was launched on, and the pick is
# held there with --binding-floor. The RULE is pinned here, where it is
# decided; the row below it pins the FORWARDING of the flag that rule selects,
# over a stubbed judge, because no usage fixture can distinguish the two walls
# for codex: lanes' codex parser reports no model-scoped window at all, so a
# local codex account's two readings are already one number, and only the host
# accounts protocol carries a scoped codex window.
assert_eq "$(lane_context_mark_model claude fable)|$(lane_context_mark_model codex gpt-6-astra)|$(lane_context_mark_model claude '')|$(lane_context_mark_model '' fable)" \
  "fable|||" \
  "the pick reading follows the harness judged on its model"

# The forwarding itself, over a `lanes` that answers the two picks a succession
# makes and distinguishes the two walls by the one flag under test. It stands
# in for the account the finding names: a hosted codex account whose binding
# bucket is a model window this launch will not pass, so the model reading has
# room and the account has none of its own. The caller's own mark is at the
# trigger, so the succession fires; the caller-harness sweep is walled, so the
# walk ends in a refusal whenever the codex sweep refuses.
STUB_LANES="$TMP_ROOT/stub-lanes"
cat > "$STUB_LANES" <<STUB
#!/bin/sh
set -eu
args=" \$* "
case "\$args" in
  *" --lane "*)
    printf '%s\n' '{"wall": 97, "alias": "fixture@example.com", "binding_resets_at": "2026-09-22T00:00:00Z"}'
    exit 3 ;;
  *" --harness codex "*)
    case "\$args" in
      *" --binding-floor "*) ;;
      *) printf '%s\n' '{"config_dir": "$H/.codex"}'; exit 0 ;;
    esac ;;
esac
printf '%s\n' '{"walled": 1, "unmeasured": 0}'
exit 3
STUB
chmod +x "$STUB_LANES"
FLOORFWD="$(mutant_scripts floorfwd lanes)" || exit 1
cp "$STUB_LANES" "$FLOORFWD/lanes"
new_caller "$MARK"
SUCCEED_BIN="$FLOORFWD/oversee-succeed" run_succeed floorfwd 'codex:gpt-6-astra:high' -- "$BYPASS"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded codex)" \
  "3|oversee-succeed: no-lane-qualifies entries=1 fallback=claude walled=2 unmeasured=0 mark=headroom account=fixture@example.com resets=2026-09-22T00:00:00Z|yes|0|none" \
  "the codex sweep is asked with the binding floor, so an account walled on its own bucket is refused"

# ── One command builder: the launcher form, and the trust dialog ─────────────
#
# A config dir with a command named for it is launched THROUGH that command,
# with no environment prefix: such a wrapper exports the lane variable for its
# own name, so a prefix in front of it is overwritten and the successor starts
# on the bare account with nothing on screen saying so. These rows run a lane at
# `.4claude`, whose shim records the lane variable it was handed and the path it
# was invoked by.
#
# The rendered shape — the launcher's absolute path, no prefix — is pinned here
# and in open-terminal-lane.sh's launcher rows, so the two launchers are held to
# one shape rather than to a comparison of the shared builder with itself.
make_lane "$H" 4claude
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.4claude.json"
cat > "$BIN/4claude" <<STUB
#!/bin/sh
{ printf 'lane=%s\n' "\${CLAUDE_CONFIG_DIR:-}"; printf 'argv0=%s\n' "\$0"; printf '%s\n' "\$@"; } > "$TMP_ROOT/argv.4claude"
# What makes such a wrapper the only selector that survives: it exports the
# variable for its OWN name after recording whatever it was handed, so the
# account check reads the account this command selected.
# Which account this wrapper ends up selecting is the row's to choose:
# \$TMP_ROOT/selects holds a dir for a wrapper that selects ANOTHER account,
# \$TMP_ROOT/selects-nothing is a wrapper that exports none at all, and neither
# marker is the ordinary case of selecting its own.
# \$TMP_ROOT/selects-late names an account this wrapper hands over to only as
# the harness starts: it stands on the picked one first, so a reading taken
# before the pane shows a running turn settles on a value the pane is about to
# stop carrying. /proc holds what a process was HANDED at execve, so only the
# exec below changes what a reader can see.
if [ -f "$TMP_ROOT/selects-late" ]; then
  other="\$(cat "$TMP_ROOT/selects-late")"
  # \$TMP_ROOT/late-gate holds it on the picked account until the row releases
  # it, so a row places the handover at an event in the caller's run rather
  # than at a time. The child carrying the picked account publishes this
  # wrapper's pid and its pane there, so a published gate proves the pane
  # stands on that account.
  if [ -f "$TMP_ROOT/late-gate" ]; then
    CLAUDE_CONFIG_DIR="$H/.4claude" sh -c 'printf "%s %s\n" "\$2" "\$TMUX_PANE" > "\$3.tmp" && mv -f "\$3.tmp" "\$3"
      until [ -f "\$1" ]; do "$STUB_REAL_SLEEP" 0.05; done' _ "$TMP_ROOT/late-release" "\$\$" "$TMP_ROOT/late-gate"
  else
    CLAUDE_CONFIG_DIR="$H/.4claude" sh -c 'sleep 3'
  fi
  CLAUDE_CONFIG_DIR="\$other"
  export CLAUDE_CONFIG_DIR
  echo 'esc to interrupt'
  # The real sleep, here and in the gate: a virtual-clock run hands the pane its
  # PATH, whose stub sleep finds no real one in the pane's environment and
  # fails at once, ending the process that carries the handed-over account.
  exec "$STUB_REAL_SLEEP" 100000
fi
if [ -f "$TMP_ROOT/selects-nothing" ]; then
  unset CLAUDE_CONFIG_DIR
else
  if [ -f "$TMP_ROOT/selects" ]; then CLAUDE_CONFIG_DIR="\$(cat "$TMP_ROOT/selects")"
  else CLAUDE_CONFIG_DIR="$H/.4claude"; fi
  export CLAUDE_CONFIG_DIR
fi
# \$TMP_ROOT/dialog holds the LINE this run parks at, so a row picks the dialog
# spelling it is pinning rather than the fixture picking one for every row.
if [ -f "$TMP_ROOT/dialog" ]; then cat "$TMP_ROOT/dialog"
elif [ -f "$TMP_ROOT/idle" ]; then :
else echo 'esc to interrupt'; fi
exec sleep 100000
STUB
chmod +x "$BIN/4claude"

# succeed_shim ROW ARGS... — a run whose whole lane inventory is the 4claude one.
# Only argv.* is cleared, which is the run's OUTPUT. Every marker is a row's
# INPUT: a row that wants one writes it before the call and removes it after,
# so no row can be read without seeing the world it ran in.
succeed_shim() {
  rm -f "${TMP_ROOT:?}"/argv.*
  RC=0
  OUT="$(exec env TMUX="$TMUX_ADDR" TMUX_PANE="$CALLER_PANE" LANE_DIRS="$H/.4claude" \
    "$TMP_ROOT/succeed-env" "$@" 2>&1)" || RC=$?
}

new_caller "$MARK"
succeed_shim shim 'claude:fable:high'
assert_eq "$RC|$(caller_open)|$(keyed successor-launch "$OUT" | sed -n 1p)|$(recorded_argv0 4claude)|$(recorded 4claude)|$(recorded claude)" \
  "0|no|oversee-succeed: successor-launch form=launcher:$BIN/4claude lane=$H/.4claude trust=account-config|$BIN/4claude|lane=;-n;overseer;--model;fable;--effort;high;$CLAUDE_COMPACT;$BRIEF;|none" \
  "a lane whose launcher is on PATH is launched through it by absolute path, with no environment prefix"

# A successor stopped at a folder-trust dialog is reported as that, with the
# pane line under the keyed one, and never as a deadline that names nothing.
# BOTH spellings the question ships with are pinned: the predicate claims both,
# and a spelling nobody asserts is a spelling a narrowing edit silently drops,
# leaving a parked successor to time out naming nothing.
for spelling in folder directory; do
  new_caller "$MARK"
  printf 'Do you trust the files in this %s?\n' "$spelling" > "$TMP_ROOT/dialog"
  succeed_shim "dialog-$spelling" 'claude:fable:high' --wait-secs 30
  rm -f "${TMP_ROOT:?}/dialog"
  assert_eq "$RC|$(keyed successor-dialog "$OUT" | sed -n '1p;3p' | sed 's/window=@[0-9]*/window=@N/; s/waited=[0-9]*/waited=N/' | tr '\n' ';')|$(caller_open)|$(overseers)" \
    "1|oversee-succeed: successor-dialog window=@N waited=N;Do you trust the files in this $spelling?;|yes|0" \
    "a successor at the $spelling spelling of the trust dialog: successor-dialog with the pane line"
done

# A claude successor is given the folder trust its harness asks for BEFORE it
# starts, in the picked config dir's own .claude.json, so a config dir that
# never opened the caller's directory does not park the successor on the
# dialog. A fresh lane, so nothing an earlier row prepared answers for it.
make_lane "$H" tclaude
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.tclaude.json"
new_caller "$MARK"
TCLAUDE_CWD="$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')"
LANE_DIRS="$H/.tclaude" run_succeed trustclaude 'claude:fable:high'
assert_eq "$RC|$(caller_open)|$(overseers)|$(keyed successor-launch "$OUT" | sed -n 1p)|$(jq -r --arg d "$TCLAUDE_CWD" '[.hasCompletedOnboarding, .projects[$d].hasTrustDialogAccepted] | map(tostring) | join(",")' "$H/.tclaude/.claude.json")" \
  "0|no|1|oversee-succeed: successor-launch form=prefix lane=$H/.tclaude trust=account-config|true,true" \
  "a claude successor on a config dir new to the caller directory is given the trust entry and starts"
# A picked config dir whose .claude.json does not parse refuses the successor
# rather than rebuilding the file over the account it keeps there, and the
# refusal carries the parser's own words under its keyed line. The caller
# keeps running and its window stands.
make_lane "$H" jclaude
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.jclaude.json"
printf '{"projects": ' > "$H/.jclaude/.claude.json"
new_caller "$MARK"
JCLAUDE_CWD="$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')"
LANE_DIRS="$H/.jclaude" run_succeed trustjson 'claude:fable:high'
assert_eq "$RC|$(caller_open)|$(overseers)|$(keyed launch-trust-missing "$OUT" | sed -n '1p;3p' | sed '2s/ .*//' | tr '\n' ';')" \
  "1|yes|0|oversee-succeed: launch-trust-missing lane=$H/.jclaude dir=$JCLAUDE_CWD reason=config-unreadable;jq:;" \
  "a claude config that does not parse refuses the successor, with the parser's words under the refusal"
# The control: a builder whose claude arm records nothing leaves the config
# dir without the entry, and the successor opens on the dialog.
TRUSTCTL="$(mutant_scripts trustctl lib/lane-launch.sh)" || exit 1
mutate_file "$TRUSTCTL/lib/lane-launch.sh" '    claude) lane_claude_trust_prepare "$2" "$3" ;;' '    claude) LANE_TRUST_ROUTE=none ;;'
make_lane "$H" uclaude
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.uclaude.json"
new_caller "$MARK"
LANE_DIRS="$H/.uclaude" SUCCEED_BIN="$TRUSTCTL/oversee-succeed" run_succeed trustctl 'claude:fable:high' --wait-secs 30
assert_eq "$RC|$(keyed successor-dialog "$OUT" | sed -n '1p;3p' | sed 's/window=@[0-9]*/window=@N/; s/waited=[0-9]*/waited=N/' | tr '\n' ';')|$(caller_open)|$(overseers)|$(test -e "$H/.uclaude/.claude.json" && echo entry || echo none)" \
  "1|oversee-succeed: successor-dialog window=@N waited=N;Do you trust the files in this folder?;|yes|0|none" \
  "control: a builder that records no claude trust leaves the successor on the dialog and the config dir without the entry"

# A lane directory carrying an apostrophe still reaches the harness. The env
# prefix crosses the pane's own shell, so a bare pair of quotes around such a
# path closes early and the shell rejects the line for an unterminated string:
# no harness starts, and the wait can only report silence. Nothing upstream of
# this builder refuses such a dir for a successor launch.
QLANE="q'claude"
make_lane "$H" "$QLANE"
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.$QLANE.json"
new_caller "$MARK"
rm -f "${TMP_ROOT:?}"/argv.*
RC=0
OUT="$(exec env TMUX="$TMUX_ADDR" TMUX_PANE="$CALLER_PANE" LANE_DIRS="$H/.$QLANE" \
  "$TMP_ROOT/succeed-env" quoted 'claude:fable:high' 2>&1)" || RC=$?
assert_eq "$RC|$(caller_open)|$(recorded claude)" \
  "0|no|lane=$H/.$QLANE;-n;overseer;--model;fable;--effort;high;$CLAUDE_COMPACT;$BRIEF;" \
  "a lane directory carrying an apostrophe is quoted for the pane shell and reaches the harness"

# ── The account the pane is really on ───────────────────────────────────────
#
# Read back before the caller's window is given up, and before the successor
# has had a turn in which to open a work-item window or write to the tracker on
# an account nobody picked.
#
# The reading is /proc/<pid>/environ and nothing else, so a host without /proc
# observes no account at all: lane_account_check names no-process-environment
# and the launch stands. A row whose outcome turns on an account the check
# OBSERVED cannot run there — its pass and the very defect it exists to catch
# both come out as that same standing launch. Those rows name themselves as
# skipped instead, off the check's own predicate.

# observed_row NAME — true where this host can produce NAME's outcome; else the
# row names itself skipped and the caller runs nothing.
observed_row() { # NAME
  lane_process_env_readable && return 0
  printf '  skip  %s (no readable per-process environment)\n' "$1"
  return 1
}

if observed_row "a successor whose wrapper selected another account"; then
  new_caller "$MARK"
  printf '%s\n' "$H/.claude" > "$TMP_ROOT/selects"
  succeed_shim wronglane 'claude:fable:high' --wait-secs 20
  assert_eq "$RC|$(keyed successor-wrong-lane "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
    "1|oversee-succeed: successor-wrong-lane picked=$H/.4claude observed=$H/.claude|yes|0" \
    "a successor whose wrapper selected another account: successor-wrong-lane, caller kept, successor closed"
fi

rm -f -- "${TMP_ROOT:?}/selects"

# A wrapper that stands on the picked account while it comes up and hands over
# only as the harness starts. A reading taken before the pane shows a running
# turn settles on the picked value and confirms an account the pane is about to
# stop carrying, which is why the reading that decides is taken after.
if observed_row "a wrapper that hands the account over as the harness starts is caught"; then
  new_caller "$MARK"
  printf '%s\n' "$H/.claude" > "$TMP_ROOT/selects-late"
  succeed_shim latelane 'claude:fable:high' --wait-secs 12
  assert_eq "$RC|$(keyed successor-wrong-lane "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
    "1|oversee-succeed: successor-wrong-lane picked=$H/.4claude observed=$H/.claude|yes|0" \
    "a wrapper that hands the account over as the harness starts is caught, the deciding read coming after the running turn"
fi

rm -f -- "${TMP_ROOT:?}/selects-late"

# An account the check could not observe is not a disagreement it did observe:
# the launch stands, the reason is named, and the successor takes the slot. This
# row runs on every host, because every host can reach it: which reason it
# reaches it by is the host's, and the wrapper that exports nothing is only how
# a machine with a readable per-process environment gets there.
UNOBSERVED_REASON=no-lane-variable
lane_process_env_readable || UNOBSERVED_REASON=no-process-environment
new_caller "$MARK"
touch "$TMP_ROOT/selects-nothing"
succeed_shim unobserved 'claude:fable:high' --wait-secs 3
rm -f -- "${TMP_ROOT:?}/selects-nothing"
assert_eq "$RC|$(keyed successor-lane-unobserved "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
  "0|oversee-succeed: successor-lane-unobserved reason=$UNOBSERVED_REASON|no|1" \
  "a successor whose account could not be observed: named on stderr, launch stands"

# --wait-secs is ONE deadline over the account read and the running-turn wait,
# which the help tells a caller to size its shell timeout by. The clock around
# the call, not the reported figure: that is exactly what the budgeting under
# test decides, so asserting it would assert the defect as readily as the fix.
# An unobservable launch that never works spends the read's whole cap and then
# the rest of the budget, which is the longest this path can take. Where no
# per-process environment is readable the read answers at once instead and the
# seconds go to the wait; the ceiling is what this row pins either way, which
# is what a caller sizes its timeout by.
#
# The run waits on the virtual clock, so the figure is how far that clock moved
# across the whole call: every wait the script made, and none of the work it
# did besides waiting, which costs whole seconds more on the macOS runner than
# on Linux. The ceiling is the promise ol_budget_bound's floor states,
# --wait-secs plus at most one settle; two deadlines push past it by the read's
# half of the budget. BOUND_CLOCK is the second the clock's real-epoch seed can
# sit past the reading taken before the call.
BOUND_WAIT=16
BOUND_CLOCK=1
BOUND_CEILING=$(( BOUND_WAIT + LANE_SETTLE_MIN_SECS + BOUND_CLOCK ))
new_caller "$MARK"
touch "$TMP_ROOT/selects-nothing" "$TMP_ROOT/idle"
bound_real="$(date +%s)"
VIRTUAL_CLOCK=1 succeed_shim bound 'claude:fable:high' --wait-secs "$BOUND_WAIT"
bound_elapsed=$(( $(cat "$STUB_CLOCK") - bound_real ))
bound_real=$(( $(date +%s) - bound_real ))
assert_eq "$RC|$(in_range within "$bound_elapsed" '' "$BOUND_CEILING")" \
  "1|within" "a run that never works returns inside one --wait-secs bound, not the sum of two"
assert_eq "$(( bound_elapsed >= BOUND_WAIT )) $(( bound_real < BOUND_WAIT ))" "1 1" \
  "control: the whole --wait-secs bound is spent on the virtual clock in less than that in wall time"
# The inverse: the same run with the clock waived spends its bound in real
# seconds, the wall time the row above holds the virtual run under. The run
# ends on its own deadline, never on a signal: a ceiling's TERM lands wherever
# the host's pace has the script by then, and a run that TERM does not end
# holds the suite with no bound of its own.
touch "$TMP_ROOT/selects-nothing" "$TMP_ROOT/idle"
new_caller "$MARK"
bound_real="$(date +%s)"
succeed_shim boundwaived 'claude:fable:high' --wait-secs "$BOUND_WAIT"
bound_real=$(( $(date +%s) - bound_real ))
assert_eq "$RC|$(( bound_real >= BOUND_WAIT ))" "1|1" \
  "control: with the clock waived the run spends its whole --wait-secs bound in wall time"

rm -f -- "${TMP_ROOT:?}/selects-nothing" "${TMP_ROOT:?}/idle"

# A handover whose running turn lands with the budget already spent. At
# --wait-secs 1 the early read's floored share is the whole of it, so the
# running-turn wait starts with nothing left and the deciding read has only
# ol_budget_bound's floor to look in. It still looks, because the caller's
# window closes on that read and a read that could not look is not an answer to
# close a window on.
#
# The virtual clock makes the early read's settle spend the whole budget, and
# a tmux shim places both reads by event. It holds the early read until the
# wrapper has published that it stands on the picked account, and the
# running-turn wait's single probe, a capture of the successor's pane,
# releases the handover and returns once the exec has landed and the pane
# shows the running turn. So the early read sees the picked account and the
# deciding read the other, on any runner's pace.
#
# lastsecond_run ROW [SUCCEED_BIN] — that run, the shim on PATH for it alone.
lastsecond_run() {
  new_caller "$MARK"
  printf '%s\n' "$H/.claude" > "$TMP_ROOT/selects-late"
  : > "$TMP_ROOT/late-gate"
  cat > "$BIN/tmux" <<SHIM
#!/bin/sh
# Every wait stops at 200 looks, which fails the row. The caller's own pane
# passes straight through.
gate="\$(cat "$TMP_ROOT/late-gate" 2>/dev/null)"
n=0
case " \$* " in
  *" $CALLER_PANE "*) ;;
  *" display-message "*" #{pane_pid} "*)
    # An account read's first call: held until the wrapper has published its
    # pid and pane, so the early read finds it standing on the picked account.
    until [ -n "\$gate" ]; do
      n=\$((n + 1)); [ "\$n" -lt 200 ] || break
      sleep 0.05
      gate="\$(cat "$TMP_ROOT/late-gate" 2>/dev/null)"
    done ;;
  *" capture-pane "*" \${gate#* } "*)
    if [ -n "\$gate" ] && [ ! -f "$TMP_ROOT/late-release" ]; then
      : > "$TMP_ROOT/late-release"
      until [ "\$(cat "/proc/\${gate%% *}/comm" 2>/dev/null)" = sleep ] &&
        "$REAL_TMUX" "\$@" | grep -q 'esc to interrupt'; do
        n=\$((n + 1)); [ "\$n" -lt 200 ] || break
        sleep 0.05
      done
    fi ;;
esac
exec "$REAL_TMUX" "\$@"
SHIM
  chmod +x "$BIN/tmux"
  VIRTUAL_CLOCK=1 SUCCEED_BIN="${2:-$SUCCEED}" succeed_shim "$1" 'claude:fable:high' --wait-secs 1
  printf '%s\n' "$OUT" > "$TMP_ROOT/lastsecond.out"
  [[ ! -f "$TMP_ROOT/work/tmp/oversee-watch.err" ]] || cat "$TMP_ROOT/work/tmp/oversee-watch.err" >> "$TMP_ROOT/lastsecond.out"
  rm -f -- "${BIN:?}/tmux" "${TMP_ROOT:?}/selects-late" "${TMP_ROOT:?}/late-gate" "${TMP_ROOT:?}/late-release"
}
if observed_row "a deciding read with the budget already spent still looks, and catches the handover"; then
  lastsecond_run lastsecond
  assert_eq "$RC|$(keyed successor-wrong-lane "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
    "1|oversee-succeed: successor-wrong-lane picked=$H/.4claude observed=$H/.claude|yes|0" \
    "a deciding read with the budget already spent still looks, and catches the handover" "$TMP_ROOT/lastsecond.out"
  # The control: the deciding read handed the raw budget instead of its floor
  # cannot look, so the row above reaches that read with the budget spent.
  NOFLOOR="$(mutant_scripts nofloor lib/overseer-launch.sh)" || exit 1
  mutate_file "$NOFLOOR/lib/overseer-launch.sh" \
    '"$form" "$(ol_budget_bound)" final' \
    '"$form" "$(ol_budget_raw)" final'
  lastsecond_run nofloor "$NOFLOOR/oversee-succeed"
  assert_eq "$RC|$(keyed successor-lane-unobserved "$OUT" | sed -n 1p)" \
    "0|oversee-succeed: successor-lane-unobserved reason=no-settle-budget" \
    "control: a deciding read handed the raw budget cannot look, and the handover stands" "$TMP_ROOT/lastsecond.out"
fi

echo "=== an overseer whose ACCOUNT is spent, which reaches none of the marks either ==="
# A walled overseer is not dead: its harness is still its pane's foreground
# command, so nothing here needs a recorded line. What it cannot
# do is take a turn, so it never reaches the marks that hand a session over.
# `--walled-pane` is therefore the succession with the wall in place of the
# mark: no mark judged, the caller's own account never kept, every entry
# through `lanes pick`.
#
# The world every row below runs in is the one the `callerhasroom` row above
# uses, and for the same reason: the caller holds 50 percent headroom, which
# a live succession KEEPS, and the other claude lane holds 90, which the pick
# names. A fixture where both answers agree would pass whether the walled
# rule is read or not.
walled_world() { claude_usage 50 0 0 Opus > "$FIXTURE_DIR/.claude.json"; claude_usage 10 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"; }
walled_world_reset() { claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"; claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"; }

new_caller "$MARK"
walled_world
run_succeed walledpane '' --walled-pane "$CALLER_PANE"
WALLED_LINE="env CLAUDE_CONFIG_DIR='$H/.eclaude' claude -n overseer $CLAUDE_COMPACT_LINE '$BRIEF'"
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|0 overseer;|no|lane=$H/.eclaude;-n;overseer;$CLAUDE_COMPACT;$BRIEF;" \
  "--walled-pane opens the successor on the lane the pick named, never on the caller's own"
# The line is on stdout ahead of every keyed line, and in the fleet state: the
# caller is oversee-watch, which reports the recovery it just performed, and a
# later death must not relaunch from the walled session's own line.
assert_eq "$(sed -n 1p <<<"$OUT")|$(recorded_line)" \
  "$WALLED_LINE|$WALLED_LINE" \
  "the walled recovery prints the line it built and records it for a later relaunch"

# The context mark well under its trigger and the account mark well over its
# own: a live succession ends at `context-below-mark` here and launches
# nothing. The walled run launches, because the wall is its trigger.
new_caller "$UNDER_MARK"
run_succeed walledmarkless ''
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)" \
  "0|oversee-succeed: context-below-mark tokens=100000 window=1000000 mark=50 headroom=50|yes|0" \
  "the same world under both marks: a live succession launches nothing"
new_caller "$UNDER_MARK"
run_succeed walledundermark '' --walled-pane "$CALLER_PANE"
assert_eq "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|0 overseer;|no|lane=$H/.eclaude;-n;overseer;$CLAUDE_COMPACT;$BRIEF;" \
  "and the walled recovery of it launches, judging no mark at all"

# Succession off launches nothing here as everywhere else: the operator's
# setting is read before the pane is.
new_caller "$MARK"
SUCCESSION=off run_succeed walledoff '' --walled-pane "$CALLER_PANE"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: succession-off ORCH_OVERSEER_SUCCESSION=off|yes|0|none" \
  "succession off refuses the walled recovery and keeps the caller's window"

# Every claude lane at or below the trigger. The refusal is exit 3, the status
# `lanes pick` itself answers "no lane clears the bound" with, so the caller
# can tell a fleet with no room from a launch that broke; it carries
# `mark=wall` and names no account, no mark having been judged to name one by.
# The sweep counts one walled account: the walled pane's own is left out of it.
new_caller "$MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed wallednoroom '' --walled-pane "$CALLER_PANE"
walled_world
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: no-lane-qualifies entries=0 fallback=claude walled=1 unmeasured=0 mark=wall|yes|0|none" \
  "no account above the trigger: the walled recovery refuses at exit 3 under mark=wall"

# The caller entry's successor keeps THIS session's model, effort and
# permission flags and changes the account alone, so launch_choice_write
# writes no model or effort beside the ones the caller's own flags already
# carry: a command naming two models runs on whichever the harness reads last,
# which is a model no pick judged. A named entry walked ahead of it is
# oversee_succeed_ladder.sh's.
new_caller "$MARK"
walled_world
run_succeed walledflags '' --walled-pane "$CALLER_PANE" -- --model fable --effort high --permission-mode bypassPermissions --verbose
assert_eq "$RC|$(recorded claude)|$(recorded codex)" \
  "0|lane=$H/.eclaude;-n;overseer;$CLAUDE_COMPACT;--model;fable;--effort;high;--permission-mode;bypassPermissions;--verbose;$BRIEF;|none" \
  "--walled-pane's caller entry keeps this session's own model, effort and permission words"

# The one account this recovery may never open on is the one it is recovering
# from. The caller's own lane is given the MOST room here, so a pick that
# judged it would name it; the pick leaves it out, and the successor opens on
# the next account.
new_caller "$MARK"
claude_usage 10 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 50 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed walledspent '' --walled-pane "$CALLER_PANE"
walled_world
assert_eq "$RC|$(caller_open)|$(recorded claude)" \
  "0|no|lane=$H/.eclaude;-n;overseer;$CLAUDE_COMPACT;$BRIEF;" \
  "the walled account is left out of the pick, although it reads the most room"

# The backstop for an inventory that names it anyway: a `lanes` that answers
# every pick with the walled account. The entry is skipped and the run refuses
# rather than relaunching into the wall. The account is spelled with a
# trailing slash on this side, the cheapest way to have one account spelled
# twice: the two are compared through the pairing lane_account_check compares
# an observed account against a picked one with, never as strings, so without
# that pairing the guard does not fire and the successor opens on the account
# that just walled.
cat > "$TMP_ROOT/spent-lanes" <<STUB
#!/bin/sh
case " \$* " in
  *" pick "*) printf '%s\n' '{"config_dir": "$H/.claude"}'; exit 0 ;;
esac
exit 3
STUB
chmod +x "$TMP_ROOT/spent-lanes"
SPENTINV="$(mutant_scripts spentinv lanes)" || exit 1
cp "$TMP_ROOT/spent-lanes" "$SPENTINV/lanes"
new_caller "$MARK"
CALLER_LANE="CLAUDE_CONFIG_DIR=$H/.claude/" SUCCEED_BIN="$SPENTINV/oversee-succeed" \
  run_succeed walledspentslash '' --walled-pane "$CALLER_PANE"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: successor-lane-spent lane=$H/.claude/ entry=caller|yes|0|none" \
  "an inventory naming the walled account, spelled another way, is still refused"

# What this mode refuses of the other four. A combination read as one of them
# would send a line built for another pane, judge a mark against a pane that
# takes no turn, or reopen on the account that walled. Every row refuses
# before tmux is asked anything.
for row in \
  "--walled-pane %9 --dead-pane %8 --line-file $TMP_ROOT/line-file|mode-conflict dead-pane=%8 print=0 check=0 flags=0 walled-pane=%9|a walled pane beside a dead one" \
  "--walled-pane %9 --print-launch-line|mode-conflict walled-pane=%9 print=1 check=0 line-file=none|a print asked of a walled pane" \
  "--walled-pane %9 --check-marks|mode-conflict walled-pane=%9 print=0 check=1 line-file=none|a mark judged on a walled pane" \
  "--walled-pane %9 --line-file $TMP_ROOT/line-file|mode-conflict walled-pane=%9 print=0 check=0 line-file=$TMP_ROOT/line-file|a recorded line beside a re-picked account" \
  "--walled-pane fleet:5|invalid-walled-pane value=fleet:5|a window target where a pane id belongs"; do
  IFS='|' read -r row_args row_want row_label <<<"$row"
  new_caller "$MARK"
  # shellcheck disable=SC2086
  run_succeed walledguard '' $row_args
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(caller_open)" \
    "1|oversee-succeed: $row_want|0|yes" \
    "$row_label: refused, nothing launched"
done

# --walled-pane's one control: the caller entry kept unpicked in `walled` as
# in `print`. It then keeps the account the walled session was spending, and
# the successor opens straight back into the wall.
WALLCTL="$(mutant_scripts wallctl oversee-succeed)" || exit 1
mutate_file "$WALLCTL/oversee-succeed" '    print:*) OL_WALK_CALLER_KEEP=1 ;;' '    print:* | walled:*) OL_WALK_CALLER_KEEP=1 ;;'
new_caller "$MARK"
SUCCEED_BIN="$WALLCTL/oversee-succeed" run_succeed wallctl '' --walled-pane "$CALLER_PANE"
assert_eq "$RC|$(recorded claude)" \
  "0|lane=$H/.claude;-n;overseer;$CLAUDE_COMPACT;$BRIEF;" \
  "control: without that gate the successor opens on the account that walled"
walled_world_reset

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
