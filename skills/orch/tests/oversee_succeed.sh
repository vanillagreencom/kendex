#!/usr/bin/env bash
# Tests for scripts/oversee-succeed over a real tmux server on a private
# socket. The caller is a pane whose screen carries a claude status line;
# claude, codex and kendex are stubs on PATH, and `lanes pick` answers from
# the lanes-fixture usage bodies. The harness stubs record their lane and argv
# and print the interrupt hint a running turn draws. The success row runs the
# script inside the caller's own pane, whose close HUPs it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/lanes-fixture.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUCCEED="${OVERSEE_SUCCEED_UNDER_TEST:-$TEST_DIR/../scripts/oversee-succeed}"

TMP_ROOT="$(mktemp -d)"
SOCK="oversee-succeed-$$"
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  [[ -z "${FOREIGN_PID:-}" ]] || kill "$FOREIGN_PID" 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
tm() { tmux -L "$SOCK" "$@"; }

PASS=0
FAIL=0
check() { # NAME GOT WANT
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$1" "$3" "$2"; fi
}
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
for harness in claude codex; do
  lane_var=CLAUDE_CONFIG_DIR
  [[ "$harness" == claude ]] || lane_var=CODEX_HOME
  cat > "$BIN/$harness" <<STUB
#!/bin/sh
{ printf 'lane=%s\n' "\${$lane_var:-}"; printf 'argv0=%s\n' "\$0"; printf '%s\n' "\$@"; } > "$TMP_ROOT/argv.$harness"
if [ -f "$TMP_ROOT/idle" ]; then echo 'FIXTURE successor startup waiting'; else echo 'esc to interrupt'; fi
[ ! -f "$TMP_ROOT/asking" ] || echo 'Do you want to proceed?'
exec sleep 100000
STUB
done
cat > "$BIN/kendex" <<'STUB'
#!/bin/sh
case "$1:$2:$3" in
  tier-model:claude:1) echo fable ;;
  tier-model:codex:1) echo gpt-6-astra ;;
  *) exit 1 ;;
esac
STUB
# A caller pane whose foreground process NAMES a harness, which is what
# lib/lane-context.sh needs before it will answer which account that session is
# spending from the account variable alone: a pane running anything else is
# offered both shapes and takes a variable only where exactly one is set. The
# `claude` stub above cannot hold the pane — it records its argv, and the
# successor's row would be the caller's.
#
# A COPY of the shell, never a script named for the harness: the kernel names a
# `#!` script's process for its interpreter, so tmux reports such a pane as `sh`
# and the shape rule never sees the harness word at all.
cp "$(command -v sh)" "$BIN/hclaude"
chmod +x "$BIN/claude" "$BIN/codex" "$BIN/kendex" "$BIN/hclaude"

# The trigger every headroom fixture below is derived from: a lane at exactly
# TRIGGER percent headroom has no room and one at TRIGGER+1 does, so the rows
# move with the setting instead of pinning 90 and 89 by hand. It follows the
# script's own default, which the rows below leave unset; the two rows that
# pin the SHIPPED default state their figures literally and say why.
TRIGGER=10
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

MARK='  kendex (ken-1453) Fable 5.1 (1M context) 52% (fixture@example.com)     /rc'
# The line a status-line command that prints the percentage alone draws: no
# window at all, which is what the overseer this feature was built for shows.
NO_WINDOW_1M='  kendex (ken-1453) Fable 5.1 52% (fixture@example.com)     /rc'
UNDER_MARK='  kendex (ken-1453) Fable 5.1 (1M context) 10% (fixture@example.com)     /rc'
# A codex caller reads its own shape: the status line is the final non-empty
# row, and the reset its account carries is parsed from a Unix epoch.
CODEX_SCREEN='  Context 48% left'
# A tier LANE_CONTEXT_DEFAULT_WINDOWS leaves out, on a line naming no window
# either: the parse then prints three empty fields before the model, the one
# shape a split that collapses a tab run reads as a shifted row.
NO_TABLE_TIER='  kendex (ken-1453) Sonnet 4.5 47% (fixture@example.com)     /rc'

# The same script over a lane-context.sh whose window table is empty, which is
# what this reader did before the table existed.
SRC_DIR="$(cd "$(dirname "$SUCCEED")" && pwd)"
# The account read's own condition, taken from the library the script under
# test sources, so every host decision below is the check's own answer and not
# a second copy of its test. See § The account the pane is really on.
# shellcheck source=../scripts/lib/lane-launch.sh
source "$SRC_DIR/lib/lane-launch.sh"
# The owner of which reading a session takes of its own account, asked directly
# by the row that pins the pick's bound. See § the pick reading.
# shellcheck source=../scripts/lib/lane-context.sh
source "$SRC_DIR/lib/lane-context.sh"
# script_copy DIR — the script tree at DIR as symlinks to the real files, with
# lib/ a real directory of symlinks so a caller can drop ONE library file and
# write its own in that place while every other dependency stays the real one.
# The three controls below each patch a different file and are otherwise the
# same tree; built once here so a reader sees that at a glance rather than by
# diffing three spellings of it.
script_copy() { # DIR
  mkdir -p "$1"
  ln -s "$SRC_DIR"/* "$1/"
  rm -f -- "${1:?}/lib"
  mkdir "$1/lib"
  ln -s "$SRC_DIR"/lib/* "$1/lib/"
}

UNPATCHED="$TMP_ROOT/unpatched"
script_copy "$UNPATCHED"
rm -f -- "${UNPATCHED:?}/lib/lane-context.sh"
sed "s/^LANE_CONTEXT_DEFAULT_WINDOWS=.*/LANE_CONTEXT_DEFAULT_WINDOWS=''/" \
  "$SRC_DIR/lib/lane-context.sh" > "$UNPATCHED/lib/lane-context.sh"

# new_caller SCREEN [MARKER] [COMMAND] — every window past index 0 closed, then
# a caller pane at index 1 showing SCREEN; sets CALLER_PANE and CALLER_WINDOW.
# MARKER is the text that says the pane has drawn, defaulting to the claude
# screens' own. COMMAND is the pane's own command, defaulting to one whose
# foreground process names no harness.
new_caller() {
  local f="$TMP_ROOT/caller.screen" spec marker="${2:-(fixture@example.com)}"
  local cmd="${3:-cat '$f'; exec sleep 100000}"
  printf '%s\n' "$1" > "$f"
  tm kill-window -a -t fleet:0
  spec="$(tm new-window -d -t fleet:1 -P -F '#{pane_id} #{window_id}' "$cmd")"
  read -r CALLER_PANE CALLER_WINDOW <<<"$spec"
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
  new_caller "$1" "$1" "exec '$BIN/hclaude' -c \"cat '$TMP_ROOT/caller.screen'; read _held\""
}

# succeed-env ROW PREFERENCE ARGS... — the script under an explicit, whole
# environment, with TMUX and TMUX_PANE taken from the caller of this file: the
# test passes them, and a pane's own shell already carries them.
cat > "$TMP_ROOT/succeed-env" <<ENV
#!/bin/sh
row="\$1" pref="\$2"
shift 2
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
cm=""
[ -z "\${CONTEXT_TOKENS:-}" ] || cm="ORCH_HANDOFF_CONTEXT_TOKENS=\$CONTEXT_TOKENS"
# A lanes setting the row can spoil, for the one row that needs the account
# judge itself to fail rather than answer.
ttl=""
[ -z "\${USAGE_TTL:-}" ] || ttl="ORCH_LANES_USAGE_TTL=\$USAGE_TTL"
wall="ORCH_OVERSEER_WALL_MINUTES=\${WALL_MINUTES:-0}"
successors="ORCH_OVERSEER_SUCCESSOR_ACCOUNTS=\${SUCCESSOR_ACCOUNTS:-0}"
cd "$TMP_ROOT/work" && exec env -i HOME="$H" PATH="$BIN:$PATH" TMUX="\$TMUX" TMUX_PANE="\$TMUX_PANE" \\
  LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state-\$row" \\
  \$lane \\
  ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="\${LANE_DIRS:-$H/.claude:$H/.eclaude:$H/.codex}" ORCH_OVERSEER_PREFERENCE="\$pref" \\
  ORCH_OVERSEER_SUCCESSION="\${SUCCESSION:-on}" \\
  \$hp \$cm \$ttl \$wall \$successors "\${SUCCEED_BIN:-$SUCCEED}" "\$@"
ENV
# in-pane ARGS... — a caller pane's own command: draw the screen, wait until
# tmux shows it, then become the script.
cat > "$TMP_ROOT/in-pane" <<PANE
#!/bin/sh
cat "$TMP_ROOT/caller.screen"
until tmux capture-pane -p -t "\$TMUX_PANE" | grep -q 'fixture@example.com'; do sleep 0.1; done
exec "$TMP_ROOT/succeed-env" "\$@" > "$TMP_ROOT/in-pane.out" 2>&1
PANE
chmod +x "$TMP_ROOT/succeed-env" "$TMP_ROOT/in-pane"

# exec_succeed ROW PREFERENCE ARGS... — replaces the calling subshell with
# the script, so a background launch's pid is the script's own.
exec_succeed() {
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
  (cd "$TMP_ROOT/work" && env -i HOME="$H" PATH="$BIN:$PATH" LANES_HOME="$H" \
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
layout() { tm list-windows -t fleet -F '#{window_index} #{window_name}' | awk '$1 > 0' | tr '\n' ';'; }
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
fleet_state() { mkdir -p "$(dirname "$FLEET_STATE")"; printf '{"issue_id": "oversee"}\n' > "$FLEET_STATE"; }
recorded_line() { jq -r '.overseer.launch_line // "none"' "$FLEET_STATE" 2>/dev/null || echo unreadable; }
fleet_state

# The caller at index 3 over a gap, renumber-windows off: the successor must
# take index 3 itself, and no other window may move.
printf '%s\n' "$MARK" > "$TMP_ROOT/caller.screen"
tm kill-window -a -t fleet:0
rm -f "${TMP_ROOT:?}"/argv.*
spec="$(tm new-window -d -t fleet:3 -P -F '#{pane_id} #{window_id} #{pane_pid}' \
  "exec '$TMP_ROOT/in-pane' success 'claude:1:high' -- --verbose")"
read -r CALLER_PANE CALLER_WINDOW caller_pid <<<"$spec"
for _ in $(seq 1 100); do kill -0 "$caller_pid" 2>/dev/null || break; sleep 0.2; done
check "success in the caller's own pane: successor at the caller's index, caller window gone" \
  "$(layout)|$(caller_open)|$(grep '^oversee-succeed:' "$TMP_ROOT/in-pane.out" | sed 's/window=@[0-9]*/window=@N/; s/pane=%[0-9]*/pane=%N/' | tr '\n' ';')|$(recorded claude)" \
  "3 overseer;|no|oversee-succeed: successor-launch form=prefix lane=$H/.claude trust=none;${UNOBSERVED_LINE}oversee-succeed: successor-working window=@N pane=%N;|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;--verbose;$BRIEF;"

# The same launch's record, written before the window opened: the close kills
# this script's own window, so a write placed after it may never run.
check "a succession records the line it launched, for a later dead-overseer relaunch" \
  "$(recorded_line)" \
  "env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer --model fable --effort high --verbose '$BRIEF'"
new_caller "$MARK"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"
# A codex successor opens into the caller's own directory, which the account's
# config does not trust: the harness would stop on the folder-trust question in
# a pane nobody is at. The launch therefore runs under a CODEX_HOME of its own
# carrying that trust, so `lane=` here is that home rather than the account, and
# the route it took is on the launch line.
CALLER_CWD="$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')"
CODEX_LAUNCH_HOME="$(lane_codex_home_path "$H/.codex" "$CALLER_CWD")"
run_succeed walled 'claude:1:high,codex:1:high'
check "walled claude entry: codex entry picked, under a home that trusts the caller directory" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)|$(recorded codex)|$(keyed successor-launch "$OUT" | sed -n 1p)|$(lane_codex_trusted "$CODEX_LAUNCH_HOME/config.toml" "$CALLER_CWD" && echo trusted || echo untrusted)" \
  "0|1 overseer;|no|none|lane=$CODEX_LAUNCH_HOME;-m;gpt-6-astra;-c;model_reasoning_effort=high;$BRIEF;|oversee-succeed: successor-launch form=prefix lane=$H/.codex trust=launch-home|trusted"
# The other side of that preparation: an account config that exists and cannot
# be read refuses the successor rather than launching it onto a config with
# every table the account was approved for gone. The caller keeps running and
# its window stands.
new_caller "$MARK"
TRUSTFAIL_CWD="$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')"
CODEX_CONFIG_SAVED="$(cat "$H/.codex/config.toml" 2>/dev/null || true)"
ln -sfn "$H/no-such-render.toml" "${H:?}/.codex/config.toml"
run_succeed trustfail 'claude:1:high,codex:1:high'
printf '%s\n' "$CODEX_CONFIG_SAVED" > "$H/.codex/config.toml"
check "an unreadable account config refuses the successor and keeps the caller" \
  "$RC|$(caller_open)|$(overseers)|$(recorded codex)|$(keyed launch-trust-missing "$OUT" | sed -n 1p)" \
  "1|yes|0|none|oversee-succeed: launch-trust-missing lane=$H/.codex dir=$TRUSTFAIL_CWD reason=config-unreadable"

# A NAMED entry's launch takes the model and effort words its OWN row writes,
# and out of the flags after -- everything but that pair. Those flags are the
# claude caller's: codex has no effort flag at all, so a successor handed
# --effort high does not start, and --model fable beside the -m gpt-6-astra
# this entry chose names a model the pick was never judged on. Which two words
# to drop is lib/lane-launch.sh's row for the CALLER's harness, so nothing here
# spells them and a row added there reaches both halves. The caller word this
# fixture carries through states nothing about permissions: what a caller's
# permission switches should do at a successor of ANOTHER harness is a
# separate question from the pair this strip owns.
new_caller "$MARK"
STRIP_CWD="$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')"
STRIP_HOME="$(lane_codex_home_path "$H/.codex" "$STRIP_CWD")"
run_succeed stripflags 'codex:1:high' -- --model fable --effort high --verbose
check "a named entry keeps the caller's other words and drops its model and effort" \
  "$RC|$(overseers)|$(recorded claude)|$(recorded codex)" \
  "0|1|none|lane=$STRIP_HOME;-m;gpt-6-astra;-c;model_reasoning_effort=high;--verbose;$BRIEF;"

# The must-fail inverse on the same fixture: with the entry test at the filter
# gone, every entry takes the caller's flags whole, and the codex successor is
# launched with a second --model and an --effort its own launch form has no
# flag for. The append it stood as before the filter.
UNSTRIPPED="$TMP_ROOT/unstripped"
script_copy "$UNSTRIPPED"
rm -f -- "${UNSTRIPPED:?}/oversee-succeed"
awk -v line='  if [[ "$chosen" == caller ]]; then' \
  '$0 == line { print "  if true; then"; hits++; next } { print }
   END { if (hits != 1) exit 1 }' "$SUCCEED" > "$UNSTRIPPED/oversee-succeed"
chmod +x "$UNSTRIPPED/oversee-succeed"
check "control: the mutant really keeps the caller's flags for every entry" \
  "$(cmp -s "$UNSTRIPPED/oversee-succeed" "$SUCCEED" && echo same || echo differs)" "differs"
new_caller "$MARK"
UNSTRIP_CWD="$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')"
UNSTRIP_HOME="$(lane_codex_home_path "$H/.codex" "$UNSTRIP_CWD")"
SUCCEED_BIN="$UNSTRIPPED/oversee-succeed" run_succeed unstripped 'codex:1:high' \
  -- --model fable --effort high --verbose
check "control: unfiltered, the codex entry is launched with a second model and an effort flag it has none of" \
  "$RC|$(overseers)|$(recorded codex)" \
  "0|1|lane=$UNSTRIP_HOME;-m;gpt-6-astra;-c;model_reasoning_effort=high;--model;fable;--effort;high;--verbose;$BRIEF;"

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
check "every row's written words read back as the model and effort they were written from" \
  "$(roundtrip claude fable high)|$(roundtrip codex gpt-6-astra high)|$(roundtrip opencode grok-5 high)|$(roundtrip pi sonnet high)" \
  "fable;high|gpt-6-astra;high|grok-5;|sonnet;high"

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
check "control: those words spelt as ones no row names read back neither choice" \
  "$(misspelt claude fable high)|$(misspelt codex gpt-6-astra high)|$(misspelt opencode grok-5 high)|$(misspelt pi sonnet high)" \
  ";|;|;|;"

# The same table's effort spellings, which open-terminal prints in its
# launch-effort-missing refusal and whose EMPTINESS is that launcher's whole
# answer to "is this launch asked for an effort at all". An accessor that handed
# back the `-` sentinel would print it in that refusal and ask a harness with no
# effort flag for one; one that answered for a harness the table does not name
# would refuse every custom launch. Both are pinned here, beside the row list
# they are read from.
check "the effort spellings accessor answers each row's list, and nothing for a flagless or unnamed harness" \
  "$(launch_choice_effort_spellings claude)|$(launch_choice_effort_spellings codex)|$(launch_choice_effort_spellings pi)|$(launch_choice_effort_spellings opencode)|$(launch_choice_effort_spellings nosuch)|$(launch_choice_effort_spellings '')" \
  "--effort|model_reasoning_effort=|--thinking|||"

# The account mark, with the context well under the context mark: the caller's
# own account is at headroom 5 and the successor goes to the claude lane
# `lanes pick` names above the trigger, never back onto the walled one.
new_caller "$UNDER_MARK"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed headroom 'claude:1:high'
check "account headroom under the trigger: succession fires under the context mark, on the picked lane" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$BRIEF;"

# The empty preference keeps the caller's own harness and passes no model or
# effort flag; at the account mark it still leaves the account that ran out.
new_caller "$UNDER_MARK"
run_succeed headroom-caller '' -- --verbose
check "empty preference at the account mark: the caller's own account is left behind" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.eclaude;-n;overseer;--verbose;$BRIEF;"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"

# Every account at or below the trigger: the wall is a refusal naming the
# caller's own account and when its binding bucket frees up, not a silent park.
new_caller "$UNDER_MARK"
codex_usage 95 > "$FIXTURE_DIR/.codex.json"
run_succeed headroom-wall 'claude:1:high,codex:1:high'
codex_usage 20 > "$FIXTURE_DIR/.codex.json"
check "every account under the trigger: refusal names the account and its reset" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)|$(recorded codex)" \
  "3|oversee-succeed: no-lane-qualifies entries=2 fallback=claude walled=5 unmeasured=0 mark=headroom account=claude resets=2026-07-27T06:00:00Z|yes|0|none|none"
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"

# The entry's model is resolved before its lane, because the lane is judged on
# it. A rank the tier ladder cannot answer is therefore a setting to fix rather
# than a lane to pass over: the run ends there and the next entry is never
# reached, so a preference list cannot quietly run on a tier nobody asked for.
new_caller "$MARK"
run_succeed norank 'claude:9:high,codex:1:high'
check "an entry whose rank the ladder cannot answer refuses model-failed and stops the walk" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded codex)" \
  "1|oversee-succeed: model-failed entry=claude:9:high|yes|0|none"

# An overseer started by hand names no account in its environment, and the one
# it is spending is the harness's own default. The caller entry launches its
# successor THERE, read through the same lib/lane-context.sh owner that measured
# the room this succession turned on, rather than with no prefix at all — which
# left the successor to take whatever account the tmux server hands a new pane,
# never the one judged. The pane runs a harness-named process, which is what
# lets that owner name the account from the default alone.
new_caller "$MARK" '(fixture@example.com)' "exec '$BIN/hclaude' -c \"cat '$TMP_ROOT/caller.screen'; read _held\""
CALLER_LANE=none run_succeed callerdefault ''
check "a caller entry naming no account variable launches on the account its room was measured on" \
  "$RC|$(caller_open)|$(keyed successor-launch "$OUT" | sed -n 1p)|$(recorded claude)" \
  "0|no|oversee-succeed: successor-launch form=prefix lane=$H/.claude trust=none|lane=$H/.claude;-n;overseer;$BRIEF;"

# The same refusal from a CODEX overseer. Its account's reset arrives from the
# harness as a Unix epoch, and the field must name a time in the one spelling a
# claude overseer prints, not an integer the operator has to convert.
new_caller "$CODEX_SCREEN" 'Context 48% left'
codex_usage 95 > "$FIXTURE_DIR/.codex.json"
CALLER_LANE="CODEX_HOME=$H/.codex" run_succeed codexwall 'codex:1:high'
codex_usage 20 > "$FIXTURE_DIR/.codex.json"
check "a codex overseer's refusal names its reset as a time, not an epoch" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded codex)" \
  "3|oversee-succeed: no-lane-qualifies entries=1 fallback=codex walled=2 unmeasured=0 mark=headroom account=codex resets=2026-07-25T17:20:00Z|yes|0|none"

# The account judged is the one this session's own environment names, and a
# claim is not that answer: pane ids restart at %0 on every tmux server, so a
# claim from another server can carry this pane's number while naming an
# unrelated account. Here that foreign account holds 5 percent headroom and the
# caller's own holds 80; reading the claim would succeed an overseer with room.
new_caller "$UNDER_MARK"
write_foreign_claim foreign-pane "$CALLER_PANE" "$H/.eclaude"
run_succeed foreign-pane 'claude:1:high'
check "a foreign server's claim on the caller's pane number does not name the judged account" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=80|0|none"

# An account judge that cannot answer says nothing about this account: the run
# reports no headroom, the context mark decides alone, and the cause rides the
# message rather than ending the run. A usage TTL that is not a whole number of
# seconds is what `lanes` refuses before it measures anything.
new_caller "$UNDER_MARK"
USAGE_TTL=forever run_succeed lanesfail 'claude:1:high'
check "an unanswerable account judge leaves the account mark unfired, not the run refused" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=unreadable|0|none"

# A preference naming another harness, every account of it walled. The walk
# does not end there: it falls through to the fleet-wide sweep of the CALLER'S
# harness, whose account holds 80 percent headroom, and the successor opens on
# it. Before the fallback was unconditional this one-entry preference refused
# with nine claude accounts unexamined, which is the fleet this was measured on.
new_caller "$MARK"
codex_usage 95 > "$FIXTURE_DIR/.codex.json"
run_succeed crossharness 'codex:1:high'
check "a one-entry preference whose harness is walled falls through to the caller-harness sweep" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)|$(recorded codex)" \
  "0|1 overseer;|no|lane=$H/.claude;-n;overseer;$BRIEF;|none"

# The must-fail inverse of that row, on the same fixture: with the fallback
# entry never appended, the walk is the preference and nothing else, so the one
# walled codex entry refuses and every claude account stands unexamined. The
# mutant must differ from the source or the control proves nothing.
NOFALLBACK="$TMP_ROOT/nofallback"
script_copy "$NOFALLBACK"
rm -f -- "${NOFALLBACK:?}/oversee-succeed"
sed '/^  ENTRIES+=(caller)$/d' "$SUCCEED" > "$NOFALLBACK/oversee-succeed"
chmod +x "$NOFALLBACK/oversee-succeed"
check "control: the mutant really drops the fallback entry" \
  "$(cmp -s "$NOFALLBACK/oversee-succeed" "$SUCCEED" && echo same || echo differs)" "differs"
new_caller "$MARK"
SUCCEED_BIN="$NOFALLBACK/oversee-succeed" run_succeed nofallback 'codex:1:high'
codex_usage 20 > "$FIXTURE_DIR/.codex.json"
check "control: without the fallback the same preference refuses with the caller's harness unwalked" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: no-lane-qualifies entries=1 fallback=none walled=1 unmeasured=0 mark=context|yes|0|none"

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
new_caller "$MARK"
touch "$TMP_ROOT/idle"
run_succeed idle 'claude:1:high' --wait-secs "$IDLE_WAIT"
rm -f "$TMP_ROOT/idle"
idle_waited="$(keyed successor-not-working "$OUT" | sed -n 1p | sed 's/.*waited=//')"
idle_budget="$(in_range spent "$idle_waited" "$IDLE_WAIT" "$((IDLE_WAIT + SCHED_SLACK))")"
check "never working: refused after its whole budget, caller kept, successor closed" \
  "$RC|$(keyed successor-not-working "$OUT" | sed -n 1p | sed 's/window=@[0-9]*/window=@N/; s/waited=[0-9]*/waited=N/')|$idle_budget|$(grep -cF 'FIXTURE successor startup waiting' <<<"$OUT")|$(caller_open)|$(overseers)" \
  "1|oversee-succeed: successor-not-working window=@N waited=N|spent|1|yes|0"

# Control: without the bounded capture before cleanup, the keyed refusal has no
# screen that can explain why the successor did not start.
CAPTURECTL="$TMP_ROOT/no-timeout-capture"
script_copy "$CAPTURECTL"
rm -f -- "${CAPTURECTL:?}/oversee-succeed"
sed '/^    printf '\''%s\\n'\'' "$succ_screen" > "$DEP_ERR"$/d' \
  "$SUCCEED" > "$CAPTURECTL/oversee-succeed"
chmod +x "$CAPTURECTL/oversee-succeed"
new_caller "$MARK"
touch "$TMP_ROOT/idle"
SUCCEED_BIN="$CAPTURECTL/oversee-succeed" run_succeed idlectl 'claude:1:high' --wait-secs "$IDLE_WAIT"
rm -f "$TMP_ROOT/idle"
check "control: a timeout without the capture loses the successor screen" \
  "$(grep -cF 'FIXTURE successor startup waiting' <<<"$OUT")" "0"

# The wait asks the turn-in-flight predicate, not the lane_state judge beside
# it. A successor drawing a dialog line in its very first turn is a launched
# successor, and the judge would call that pane `asking` — not `working` — and
# abandon a succession that had in fact taken.
new_caller "$MARK"
touch "$TMP_ROOT/asking"
run_succeed asking 'claude:1:high'
rm -f "$TMP_ROOT/asking"
check "a first turn that also prints a dialog line is a launched successor, not an abandoned one" \
  "$RC|$(layout)|$(caller_open)" \
  "0|1 overseer;|no"

# A shell tool that times out sends TERM mid-wait. The harness stub writes its
# argv only once the launch is typed, which is after the traps are set.
new_caller "$MARK"
touch "$TMP_ROOT/idle"
rm -f "${TMP_ROOT:?}"/argv.*
( exec_succeed interrupted 'claude:1:high' --wait-secs 30 ) > "$TMP_ROOT/interrupted.out" 2>&1 &
succ_pid=$!
for _ in $(seq 1 50); do [[ ! -f "$TMP_ROOT/argv.claude" ]] || break; sleep 0.2; done
kill -TERM "$succ_pid"
RC=0
wait "$succ_pid" || RC=$?
rm -f "${TMP_ROOT:?}/idle"
check "interrupted mid-wait: refused, caller kept, successor closed" \
  "$RC|$(keyed interrupted "$(cat "$TMP_ROOT/interrupted.out")" | sed -n 1p | sed 's/window=@[0-9]*/window=@N/')|$(caller_open)|$(overseers)" \
  "1|oversee-succeed: interrupted window=@N signal=TERM|yes|0"

new_caller "$UNDER_MARK"
run_succeed under 'claude:1:high'
check "1M window under the context mark: context-below-mark, nothing launched" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=80|0|none"

new_caller "$NO_WINDOW_1M"
run_succeed window 'claude:1:high'
check "a line naming no window takes the window its model runs, and the successor launches" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;$BRIEF;"

# What a refusal's window rests on. A window the line NAMES is read off the
# line whatever the table holds for that model, and a model the table leaves
# out is no window at all rather than another model's figure.
for row in \
  "  kendex (ken-1453) Opus 5 (200k context) 41% (fixture@example.com)     /rc|window=200000 source=status-line headroom=80|a named window under 1M is read off the line, not off the table" \
  "  kendex (ken-1453) Sonnet 4.5 52% (fixture@example.com)     /rc|window=none source=none headroom=80|a model the table leaves out is unmeasured, not guessed at"; do
  IFS='|' read -r row_screen row_want row_label <<<"$row"
  new_caller "$row_screen"
  run_succeed window 'claude:1:high'
  check "$row_label" \
    "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
    "0|oversee-succeed: window-below-mark $row_want|0|none"
done

# --- the judgement on its own -------------------------------------------
# `--check-marks` is the same two marks, stopped at the answer: the watch runs
# it every pass and turns a reached mark into the event that wakes the overseer,
# so a judgement here that picked a lane or opened a window would spend an
# account on every pass of every fleet.
new_caller "$MARK"
BEFORE_LINE="$(recorded_line)"
run_succeed checkcontext '' --check-marks
check "--check-marks at the context mark: the mark is reported, nothing is launched" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(caller_open)|$(recorded claude)" \
  "0|oversee-succeed: mark-reached kind=context value=520000 mark=500000 succession=on headroom=80|0|yes|none"
check "and the fleet state keeps the launch line it had: a judgement records none" \
  "$(recorded_line)" "$BEFORE_LINE"

new_caller "$UNDER_MARK"
run_succeed checkunder '' --check-marks
check "--check-marks under both marks: the below-mark line, nothing launched" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(caller_open)" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=80|0|yes"

# The projected wall is measured from the displaced cache sample. A fast burn
# reaches the setting. A slow burn does not. Missing, close, and flat samples
# are each reported as unmeasured rather than read as a safe rate.
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
stage_usage_pair ratefast 40 20 600
new_caller "$UNDER_MARK"
WALL_MINUTES=30 run_succeed ratefast '' --check-marks
check "a sixty-point headroom burning two points a minute fires the rate trigger" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: mark-reached kind=rate value=30 mark=30 succession=on account=claude|0"
new_caller "$UNDER_MARK"
WALL_MINUTES=30 run_succeed ratefast ''
check "a rate trigger moves off the caller account even when it has more headroom" \
  "$RC|$(caller_open)|$(recorded claude)" \
  "0|no|lane=$H/.eclaude;-n;overseer;$BRIEF;"
stage_usage_pair rateslow 22 20 600
new_caller "$UNDER_MARK"
WALL_MINUTES=30 run_succeed rateslow '' --check-marks
check "a projected wall beyond the setting does not fire" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=78|0"
for rate_row in \
  "rateone|40|none|0|one-sample" \
  "rateclose|40|20|30|samples-too-close" \
  "rateflat|20|20|600|not-increasing"; do
  IFS='|' read -r rate_name rate_current rate_prior rate_gap rate_reason <<<"$rate_row"
  stage_usage_pair "$rate_name" "$rate_current" "$rate_prior" "$rate_gap"
  new_caller "$UNDER_MARK"
  WALL_MINUTES=30 run_succeed "$rate_name" '' --check-marks
  check "an unmeasurable rate reports $rate_reason" \
    "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
    "0|oversee-succeed: mark-unmeasured kind=rate reason=$rate_reason succession=on|0"
done
new_caller "$UNDER_MARK"
WALL_MINUTES=bad run_succeed badwall '' --check-marks
check "a malformed projected-wall setting is refused before judgement" \
  "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|oversee-succeed: invalid-wall-minutes ORCH_OVERSEER_WALL_MINUTES=bad"
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=bad run_succeed badsuccessors '' --check-marks
check "a malformed successor-account setting is refused before judgement" \
  "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|oversee-succeed: invalid-successor-accounts ORCH_OVERSEER_SUCCESSOR_ACCOUNTS=bad"
stage_usage_pair rateleadingzero 40 20 600
new_caller "$UNDER_MARK"
WALL_MINUTES=030 run_succeed rateleadingzero '' --check-marks
check "a leading-zero wall setting remains valid decimal input" \
  "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-reached kind=rate value=30 mark=30 succession=on account=claude"

# The chooser itself counts successor accounts after omitting this session.
# Two leave the overseer in place. One fires and moves it to that account.
make_lane "$H" nclaude
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.nclaude.json"
THREE_LANES="$H/.claude:$H/.eclaude:$H/.nclaude"
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=1 LANE_DIRS="$THREE_LANES" run_succeed qualifyingtwo '' --check-marks
check "two successor accounts do not fire the qualifying-set trigger" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=40|0"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.nclaude.json"
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=01 LANE_DIRS="$THREE_LANES" run_succeed qualifyingone '' --check-marks
check "one successor account fires the named qualifying-set trigger" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: mark-reached kind=qualifying value=1 mark=1 succession=on|0"
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=1 LANE_DIRS="$THREE_LANES" run_succeed qualifyinglaunch ''
check "the qualifying-set trigger succeeds onto the remaining account" \
  "$RC|$(caller_open)|$(recorded claude)" \
  "0|no|lane=$H/.eclaude;-n;overseer;$BRIEF;"
new_caller "$UNDER_MARK"
CALLER_LANE="CLAUDE_CONFIG_DIR=$H/.eclaude" SUCCESSOR_ACCOUNTS=1 LANE_DIRS="$THREE_LANES" \
  run_succeed qualifyingstable '' --check-marks
check "the successor stays in place when no remaining account has more headroom" \
  "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=50"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.claude.json"
new_caller "$UNDER_MARK"
SUCCESSOR_ACCOUNTS=1 LANE_DIRS="$THREE_LANES" run_succeed qualifyingequal '' --check-marks
check "an equal-headroom successor does not fire the qualifying-set trigger" \
  "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=50"

# A known harness remains enough to judge account triggers when its context
# line is absent. The account read receives no model, and the context reading
# remains unmeasured when none of those triggers fires.
NO_CONTEXT='fixture known claude without context'
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
new_known_claude_caller "$NO_CONTEXT"
run_succeed knownheadroom '' --check-marks
check "a known harness with no context line still fires the headroom trigger" \
  "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-reached kind=headroom value=$TRIGGER mark=$TRIGGER succession=on account=claude resets=2026-07-27T06:00:00Z"

stage_usage_pair knownrate 40 20 600
new_known_claude_caller "$NO_CONTEXT"
WALL_MINUTES=30 run_succeed knownrate '' --check-marks
check "a known harness with no context line still fires the rate trigger" \
  "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-reached kind=rate value=30 mark=30 succession=on account=claude"

claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
new_known_claude_caller "$NO_CONTEXT"
SUCCESSOR_ACCOUNTS=1 LANE_DIRS="$THREE_LANES" run_succeed knownqualifying '' --check-marks
check "a known harness with no context line still fires the qualifying-set trigger" \
  "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-reached kind=qualifying value=1 mark=1 succession=on"

claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.nclaude.json"
new_known_claude_caller "$NO_CONTEXT"
SUCCESSOR_ACCOUNTS=1 LANE_DIRS="$THREE_LANES" run_succeed knownunmeasured '' --check-marks
check "a known harness with no account trigger reports its context as unmeasured" \
  "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: mark-unmeasured kind=context reason=window-none source=none succession=on"
new_caller "$NO_CONTEXT" "$NO_CONTEXT"
run_succeed unknowncontext '' --check-marks
check "a pane with no known harness and no context line still refuses" \
  "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|oversee-succeed: no-status-line pane=$CALLER_PANE"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.nclaude.json"

NORATE="$TMP_ROOT/no-rate-trigger"
script_copy "$NORATE"
rm -f -- "${NORATE:?}/oversee-succeed"
awk '$0 == "elif (( WALL_MINUTES > 0 )) && [[ \"$RATE_STATE\" == measured ]] \\" {
       print "elif false; then"; getline; hits++; next } { print }
     END { if (hits != 1) exit 1 }' "$SUCCEED" > "$NORATE/oversee-succeed"
chmod +x "$NORATE/oversee-succeed"
stage_usage_pair ratecontrol 40 20 600
new_caller "$UNDER_MARK"
SUCCEED_BIN="$NORATE/oversee-succeed" WALL_MINUTES=30 run_succeed ratecontrol '' --check-marks
check "control: without the rate trigger the fast burn stays below the context mark" \
  "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=60"

NOQUALIFY="$TMP_ROOT/no-qualifying-trigger"
script_copy "$NOQUALIFY"
rm -f -- "${NOQUALIFY:?}/oversee-succeed"
awk '$0 == "elif (( SUCCESSOR_ACCOUNTS > 0 )) && [[ \"$QUALIFYING_STATE\" == measured ]] \\" {
       print "elif false; then"; getline; getline; hits++; next } { print }
     END { if (hits != 1) exit 1 }' "$SUCCEED" > "$NOQUALIFY/oversee-succeed"
chmod +x "$NOQUALIFY/oversee-succeed"
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
new_caller "$UNDER_MARK"
SUCCEED_BIN="$NOQUALIFY/oversee-succeed" SUCCESSOR_ACCOUNTS=1 LANE_DIRS="$THREE_LANES" \
  run_succeed qualifyingcontrol '' --check-marks
check "control: without the qualifying-set trigger one successor does not fire" \
  "$RC|$(sed -n 1p <<<"$OUT")" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=80"
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"

# The account mark leads, and only its line names the account and the reset the
# operator waits on: at the context mark the overseer's own account either has
# room or was never measured, so there is none to name.
new_caller "$UNDER_MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
run_succeed checkheadroom '' --check-marks
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
check "--check-marks at the account mark: the headroom mark, its account and its reset" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(caller_open)" \
  "0|oversee-succeed: mark-reached kind=headroom value=$TRIGGER mark=$TRIGGER succession=on account=claude resets=2026-07-27T06:00:00Z|0|yes"

# Succession off launches nothing, and a judgement launches nothing either: the
# overseer is still past its mark and still has to hand over by hand, so the
# answer is reported with the setting on it rather than withheld.
new_caller "$MARK"
SUCCESSION=off run_succeed checkoff '' --check-marks
check "--check-marks with succession off still judges, and says the setting is off" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(caller_open)" \
  "0|oversee-succeed: mark-reached kind=context value=520000 mark=500000 succession=off headroom=80|0|yes"

# The context mark is ORCH_HANDOFF_CONTEXT_TOKENS, the one the lane turn-end
# hook judges. A screen past the default and under a raised setting reaches the
# mark only where the setting is read, so a mark hard-coded here reddens this.
new_caller "$MARK"
CONTEXT_TOKENS=600000 run_succeed checkraised '' --check-marks
check "a context mark the setting raises is not reached at the same screen" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: context-below-mark tokens=520000 mark=600000 headroom=80|0"
new_caller "$MARK"
CONTEXT_TOKENS=400000 run_succeed checklowered '' --check-marks
check "and one the setting lowers is reported against the value that was set" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: mark-reached kind=context value=520000 mark=400000 succession=on headroom=80|0"

# The mark is read through `orch-env`, which owns the ladder AND the fallback:
# a value it cannot read as a number falls back to the default, which is what
# the turn-end hook then judges at. Reading the variable here instead would
# keep the value orch-env dropped, and the two would judge one overseer at two
# marks. A leading zero is the value orch-env passes through and bash
# arithmetic reads as octal, so that one is refused rather than reinterpreted.
new_caller "$MARK"
CONTEXT_TOKENS=tokens run_succeed contextfallback '' --check-marks
check "a context mark orch-env cannot read falls back to the default both readers use" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: mark-reached kind=context value=520000 mark=500000 succession=on headroom=80|0"
new_caller "$MARK"
CONTEXT_TOKENS=0500000 run_succeed contextguard '' --check-marks
check "a context mark spelled with a leading zero: refused, nothing judged" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "1|oversee-succeed: invalid-context-mark ORCH_HANDOFF_CONTEXT_TOKENS=0500000|0"

# A reading that could not be taken is not a mark that did not fire, and only
# `check` tells them apart: the watch holds a standing mark across such a pass,
# where the succeed path has the documented fallback of letting the mark it CAN
# read decide alone. The context mark still leads: a mark that fired is what
# the caller must act on, whatever the other reading could not say.
new_caller "$UNDER_MARK"
LANE_DIRS="$H/.openclaude" CALLER_LANE="CLAUDE_CONFIG_DIR=$H/.openclaude" \
  run_succeed checkunmeasured '' --check-marks
check "--check-marks with an account nothing measured: mark-unmeasured, naming the missing figure" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(caller_open)" \
  "0|oversee-succeed: mark-unmeasured kind=headroom reason=headroom-none succession=on|0|yes"
new_caller "$MARK"
LANE_DIRS="$H/.openclaude" CALLER_LANE="CLAUDE_CONFIG_DIR=$H/.openclaude" \
  run_succeed checkunmeasuredpast '' --check-marks
check "and a context mark that fired outranks it: a mark the caller must act on is reported" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: mark-reached kind=context value=520000 mark=500000 succession=on headroom=none|0"

# A status line naming a window this reader holds no row for: the context
# reading could not be taken at all, which is not the measured 200k window the
# window-below-mark rows above report.
new_caller "  kendex (ken-1453) Sonnet 4.5 52% (fixture@example.com)     /rc"
run_succeed checkwindownone '' --check-marks
check "--check-marks with no window to measure against: mark-unmeasured names the window" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: mark-unmeasured kind=context reason=window-none source=none succession=on|0"
new_caller "  kendex (ken-1453) Opus 5 (200k context) 41% (fixture@example.com)     /rc"
run_succeed checkwindowsmall '' --check-marks
check "a window this reader DID measure and that is under 1M stays a below-mark answer" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: window-below-mark window=200000 source=status-line headroom=80|0"

# Control: an unmeasured reading answers as a mark that did not fire. The watch
# then clears its standing row on that pass and reports the same standing mark
# as a fresh crossing on the next one, so the repeat count never bounds it.
UNMEASCTL="$TMP_ROOT/unmeasctl"
script_copy "$UNMEASCTL"
rm -f -- "${UNMEASCTL:?}/oversee-succeed"
awk -v line='    if [[ "$MODE" == check ]]; then' \
  '$0 == line { print "    if false; then"; next } { print }' "$SUCCEED" > "$UNMEASCTL/oversee-succeed"
chmod +x "$UNMEASCTL/oversee-succeed"
check "control: the copy really drops the unmeasured answers" \
  "$(cmp -s "$UNMEASCTL/oversee-succeed" "$SUCCEED" && echo same || echo differs)" "differs"
new_caller "  kendex (ken-1453) Sonnet 4.5 52% (fixture@example.com)     /rc"
SUCCEED_BIN="$UNMEASCTL/oversee-succeed" run_succeed unmeasctl '' --check-marks
check "control: without them a reading nothing took answers as a mark that did not fire" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "0|oversee-succeed: window-below-mark window=none source=none headroom=80|0"

# Control: the judgement runs on past its own answer. It is the launch path's
# own steps that follow, so a check that does not stop opens a successor window
# and spends an account every pass the watch makes.
CHECKCTL="$TMP_ROOT/checkctl"
script_copy "$CHECKCTL"
rm -f -- "${CHECKCTL:?}/oversee-succeed"
awk -v line='if [[ "$MODE" == check ]]; then' \
  '$0 == line { print "if false; then"; next } { print }' "$SUCCEED" > "$CHECKCTL/oversee-succeed"
chmod +x "$CHECKCTL/oversee-succeed"
check "control: the copy really runs past the judgement" \
  "$(cmp -s "$CHECKCTL/oversee-succeed" "$SUCCEED" && echo same || echo differs)" "differs"
new_caller "$MARK"
SUCCEED_BIN="$CHECKCTL/oversee-succeed" run_succeed checkctl '' --check-marks
check "control: a judgement that does not stop opens a successor and closes the caller" \
  "$RC|$(overseers)|$(caller_open)" "0|1|no"

# ORCH_OVERSEER_SUCCESSION over a screen past the mark, which would launch.
for row in \
  "off|0|oversee-succeed: succession-off ORCH_OVERSEER_SUCCESSION=off" \
  "true|1|oversee-succeed: invalid-succession ORCH_OVERSEER_SUCCESSION=true"; do
  IFS='|' read -r row_value row_rc row_want <<<"$row"
  new_caller "$MARK"
  SUCCESSION="$row_value" run_succeed succession 'claude:1:high'
  check "succession $row_value: nothing launched" \
    "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
    "$row_rc|$row_want|0|none"
done

echo "=== an overseer that DIED, which reaches none of the marks above ==="
# A dead pane shows no status line and holds no harness, so nothing there names
# the harness, the model or the account the session ran on. Two modes carry
# that case over ONE launch path: `--print-launch-line` builds the command
# while the overseer is alive, and `--dead-pane` sends that record into the
# dead overseer's window slot. Neither judges a mark, because the death is the
# trigger.

# The screen under the context mark is where the first mode refuses, so a row
# that answers on it shows the print judging no mark.
new_caller "$UNDER_MARK"
run_succeed printline '' --print-launch-line -- --verbose
check "--print-launch-line prints the caller's own line, judges no mark and launches nothing" \
  "$RC|$OUT|$(caller_open)|$(overseers)|$(recorded claude)" \
  "0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer --verbose '$BRIEF'|yes|0|none"

# The preference names where a LATER successor goes; the printed line records
# what THIS session runs, so it walks the caller entry whatever it says and
# reads no account at all.
new_caller "$UNDER_MARK"
run_succeed printpref 'codex:1:high' --print-launch-line
check "--print-launch-line walks the caller entry whatever the preference names" \
  "$RC|$OUT|$(recorded codex)" \
  "0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer '$BRIEF'|none"

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
PRINTSKIP="$TMP_ROOT/printskip"
script_copy "$PRINTSKIP"
rm -f -- "${PRINTSKIP:?}/oversee-succeed"
# The call's own line carries a continuation, so it is re-emitted from the file
# rather than retyped: an awk -v value cannot hold a trailing backslash.
awk -v call='  lane_codex_trust_prepare "$harness" "$lane_dir" "$CALLER_PATH"' \
    -v home='  launch_home="$LANE_TRUST_HOME"' \
  'index($0, call) == 1 { print "  if [[ \"$MODE\" != succeed ]]; then LANE_TRUST_HOME=\"$lane_dir\" LANE_TRUST_ROUTE=none";
                          print "  else " substr($0, 3); calls++; next }
   $0 == home { print "  fi"; print; homes++; next }
   { print }
   END { if (calls != 1 || homes != 1) exit 1 }' "$SUCCEED" > "$PRINTSKIP/oversee-succeed" \
  || { echo "fixture: printskip found no single site to mutate" >&2; exit 1; }
chmod +x "$PRINTSKIP/oversee-succeed"
check "control printskip really keeps the preparation for the live succession alone" \
  "$(cmp -s "$PRINTSKIP/oversee-succeed" "$SUCCEED" && echo same || echo differs)|$(bash -n "$PRINTSKIP/oversee-succeed" && echo parses || echo broken)" \
  "differs|parses"
new_caller "$CODEX_SCREEN" 'Context 48% left'
PRINT_CWD="$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')"
PRINT_HOME="$(lane_codex_home_path "$H/.codex" "$PRINT_CWD")"
CALLER_LANE="CODEX_HOME=$H/.codex" SUCCEED_BIN="$PRINTSKIP/oversee-succeed" \
  run_succeed printskip '' --print-launch-line
check "control: a print that skips the preparation records the bare account, not the prepared home" \
  "$RC|$OUT" "0|env CODEX_HOME='$H/.codex' codex '$BRIEF'"

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
  check "--print-launch-line on a codex caller records the home trust was made in, under $row_what" \
    "$RC|$OUT|$(overseers)" "0|env CODEX_HOME='$PRINT_HOME' codex '$BRIEF'|0"
done

# Why `print` is the only mode that records the caller's own codex lane. A
# codex status line names no context window, so a succession that is not
# already at its account trigger ends here, before the entry list is built; and
# at the trigger the caller's lane is not kept, `lanes pick` naming the lane
# instead. A codex caller therefore never carries lane_context_caller_cfg's
# answer into a live launch, and the rows above are where that arm is read.
#
# The account mark still reads a figure here, and the account it reads is the
# codex default: this session names no account variable, and the harness its
# own status line names is what turns that silence into a directory. The codex
# fixture holds 80 percent headroom, well above the trigger.
new_caller "$CODEX_SCREEN" 'Context 48% left'
CALLER_LANE=none run_succeed codexnowindow ''
check "a codex caller with room ends at the context mark, its status line naming no window" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)" \
  "0|oversee-succeed: window-below-mark window=none source=none headroom=80|yes|0"

# Printing launches nothing, so the setting that governs launching does not
# gate it: the record is what an owner's later relaunch by hand reads.
new_caller "$UNDER_MARK"
SUCCESSION=off run_succeed printoff '' --print-launch-line
check "succession off still prints the line: printing launches nothing" \
  "$RC|$OUT|$(overseers)" \
  "0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer '$BRIEF'|0"

# The dead overseer's window: a pane drawing NOTHING — no status line, no
# harness — at an index of its own, so a row reads which window the successor
# landed in and whether the caller's own was touched.
new_dead_pane() {
  local spec
  spec="$(tm new-window -d -t fleet:5 -P -F '#{pane_id} #{window_id}' 'exec sleep 100000')"
  read -r DEAD_PANE DEAD_WINDOW <<<"$spec"
}
dead_open() { if [[ "$(tm list-windows -t fleet -F '#{window_id}')" == *"$DEAD_WINDOW"* ]]; then echo yes; else echo no; fi; }
overseer_index() { tm list-windows -t fleet -F '#{window_index} #{window_name}' | awk '$2 == "overseer" { printf "%s", $1 }'; }
RECORDED_LINE="claude -n overseer 'relaunched from the record'"
printf '%s\n' "$RECORDED_LINE" > "$TMP_ROOT/line-file"

new_caller "$MARK"
new_dead_pane
run_succeed deadpane '' --dead-pane "$DEAD_PANE" --line-file "$TMP_ROOT/line-file"
check "--dead-pane sends the recorded line into the dead overseer's window, asking that pane nothing" \
  "$RC|$(overseer_index)|$(caller_open)|$(dead_open)|$(recorded claude)" \
  "0|5|yes|no|lane=;-n;overseer;relaunched from the record;"
new_caller "$MARK"
new_dead_pane
SUCCESSION=off run_succeed deadoff '' --dead-pane "$DEAD_PANE" --line-file "$TMP_ROOT/line-file"
check "succession off refuses the relaunch, and the dead window stays as it was" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(dead_open)|$(recorded claude)" \
  "0|oversee-succeed: succession-off ORCH_OVERSEER_SUCCESSION=off|0|yes|none"

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
  check "$row_label: refused, nothing launched" \
    "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(caller_open)" \
    "1|oversee-succeed: $row_want|0|yes"
done

# A succession outside a fleet has no state to record its line in. That is a
# notice on the way out, never a reason to leave the fleet unattended.
mv -- "$FLEET_STATE" "$TMP_ROOT/fleet-state.away"
new_caller "$MARK"
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
run_succeed nostate ''
check "a succession with no fleet state names the unrecorded line and still opens the successor" \
  "$RC|$(keyed line-unrecorded "$OUT" | sed -n 1p)|$(overseers)|$(caller_open)" \
  "0|oversee-succeed: line-unrecorded field=overseer.launch_line|1|no"
mv -- "$TMP_ROOT/fleet-state.away" "$FLEET_STATE"

# Control: the dead pane asked for a status line after all. It draws none, so
# the relaunch refuses and the fleet keeps no overseer — which is what the
# recorded line exists to prevent.
DEADCTL="$TMP_ROOT/deadctl"
script_copy "$DEADCTL"
rm -f -- "${DEADCTL:?}/oversee-succeed"
awk -v line='if [[ "$MODE" != dead ]]; then' \
  '$0 == line { print "if true; then"; next } { print }' "$SUCCEED" > "$DEADCTL/oversee-succeed"
chmod +x "$DEADCTL/oversee-succeed"
check "control: the copy really asks the dead pane what it was running" \
  "$(cmp -s "$DEADCTL/oversee-succeed" "$SUCCEED" && echo same || echo differs)" "differs"
new_caller "$MARK"
new_dead_pane
SUCCEED_BIN="$DEADCTL/oversee-succeed" run_succeed deadctl '' --dead-pane "$DEAD_PANE" --line-file "$TMP_ROOT/line-file"
check "control: a mode that reads the dead pane refuses it and launches no successor" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(dead_open)" \
  "1|oversee-succeed: no-status-line pane=$DEAD_PANE|0|yes"

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
  HEADROOM_PCT="$row_value" run_succeed headroomguard 'claude:1:high'
  check "headroom trigger $row_value: refused, nothing launched" \
    "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
    "$row_rc|$row_want|0|none"
done

# A valid NON-DEFAULT trigger, read end to end: the caller sits at 50 headroom,
# which is above the default 10 and at or below 60, so only a setting that is
# actually read fires the account mark here.
new_caller "$UNDER_MARK"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 20 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
HEADROOM_PCT=60 run_succeed headroomset 'claude:1:high'
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
check "a non-default trigger is read: 50 headroom fires the account mark at 60" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$BRIEF;"

# The trigger's own boundary, caller side. `at or below` is the documented
# rule, so exactly TRIGGER fires and one percent above it does not.
new_caller "$UNDER_MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed calleratbound 'claude:1:high'
check "caller at exactly the trigger fires the account mark" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$BRIEF;"

new_caller "$UNDER_MARK"
claude_usage "$ABOVE_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
run_succeed callerabovebound 'claude:1:high'
check "caller one percent above the trigger falls through to the context mark" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=$((TRIGGER + 1))|0|none"

# The SHIPPED default, which no row above pins: every one of them derives its
# fixtures from TRIGGER, so a default that drifts carries them along with it.
# These two rows state their figures literally instead. The 15 in each sits
# above the default and below twice it, so a default raised to that doubled
# figure flips both answers, and between them the pair covers both jobs the
# one number does.
#
# The mark side: a caller with room to spare under the shipped default is not
# succeeded on its account, and the context mark answers for it instead.
new_caller "$UNDER_MARK"
claude_usage 85 0 0 Opus > "$FIXTURE_DIR/.claude.json"
run_succeed defaultspares 'claude:1:high'
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
check "the shipped default leaves a caller at 15 percent headroom unsucceeded" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=15|0|none"

# The floor side, which is the job the shipped default answers: the caller is
# past its own mark and the only candidate sits at 15, so the successor opens
# there. A larger default rules that candidate out and refuses the succession.
new_caller "$UNDER_MARK"
claude_usage 92 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 85 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed defaultfloor 'claude:1:high'
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
check "the shipped default opens the successor on a candidate at 15 percent headroom" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$BRIEF;"

# The same boundary on the pick side: the only candidate sits exactly at the
# trigger and must be refused, then one percent above it and must be chosen.
new_caller "$MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed pickatbound 'claude:1:high'
check "a candidate at exactly the trigger is refused, not picked" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: no-lane-qualifies entries=1 fallback=claude walled=4 unmeasured=0 mark=headroom account=claude resets=2026-07-27T06:00:00Z|yes|0|none"

new_caller "$MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage "$ABOVE_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed pickabovebound 'claude:1:high'
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
check "a candidate one percent above the trigger is chosen" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$BRIEF;"

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
check "an unmeasured caller account is not reused at the context mark" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.eclaude;-n;overseer;$BRIEF;"

# The same unmeasured account where the pick names NO lane. `lanes pick` is the
# one judge of account room and its refusal is never overridden, so a walled
# fleet refuses rather than reopening the successor on an account nothing
# measured and closing the window that was still running.
new_caller "$MARK"
mv "$FIXTURE_DIR/.claude.json" "$FIXTURE_DIR/.claude.json.held"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed unmeasuredwall ''
mv "$FIXTURE_DIR/.claude.json.held" "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
check "an unmeasured caller with every lane of its harness walled refuses at the context mark" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: no-lane-qualifies entries=0 fallback=claude walled=1 unmeasured=1 mark=context|yes|0|none"

# The same wall with the caller's own account MEASURED at the trigger: the
# refusal names that account and when its binding bucket frees up, and the
# caller's own lane is not reopened on the way there either.
new_caller "$UNDER_MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed callerwall ''
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
check "a caller at the trigger with every lane walled refuses at the account mark" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: no-lane-qualifies entries=0 fallback=claude walled=2 unmeasured=0 mark=headroom account=claude resets=2026-07-27T06:00:00Z|yes|0|none"

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
check "a claim on the caller pane does not move the judged account, and its account mark fires" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.eclaude;-n;overseer;$BRIEF;"

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
check "a caller with room above the trigger keeps its own lane, not the roomier one the pick names" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.claude;-n;overseer;$BRIEF;"

# The account mark reads the buckets THIS session spends. The caller's status
# line names Fable, and its account's only spent window is scoped to Opus at
# exactly the trigger: that window walls no Fable turn, so the mark does not
# fire and the run falls through to the context mark, which reports the
# model-scoped headroom it read. The caller's model is what decides it, so the
# matched row below moves the same percentage onto the Fable window and the
# mark fires.
new_caller "$UNDER_MARK"
jq -n --argjson m "$AT_TRIGGER" '{
  five_hour: {utilization: 0, resets_at: "2026-07-27T06:00:00Z"},
  seven_day: {utilization: 0, resets_at: "2026-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: $m, resets_at: "2026-08-01T06:00:00Z",
            scope: {model: {display_name: "Opus"}}}]
}' > "$FIXTURE_DIR/.claude.json"
run_succeed unmatchedbucket 'claude:1:high'
check "a spent window scoped to a model this overseer does not run leaves the account mark unfired" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=100|0|none"

# The must-fail inverse: the account judged with no model named, which is what
# the mark read before. Every window then counts, so the same fixture fires on
# the Opus window and hands the session over for a bucket neither overseer
# spends. The successor lands on the very account that fired it, because the
# entry's pick reads the Fable window there and finds it empty — the succession
# loop, paid in a window swap and a handoff, with a roomier second lane sitting
# unused beside it.
WIDEMARK="$TMP_ROOT/widemark"
script_copy "$WIDEMARK"
rm -f -- "${WIDEMARK:?}/oversee-succeed"
sed 's/ \${CALLER_MODEL:+--model "\$CALLER_MODEL"}//' "$SUCCEED" > "$WIDEMARK/oversee-succeed"
chmod +x "$WIDEMARK/oversee-succeed"
check "control: the mutant really drops the model from the account judge" \
  "$(cmp -s "$WIDEMARK/oversee-succeed" "$SUCCEED" && echo same || echo differs)" "differs"
new_caller "$UNDER_MARK"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
SUCCEED_BIN="$WIDEMARK/oversee-succeed" run_succeed widemark 'claude:1:high'
check "control: judged on every window the same account fires the mark and hands over to itself" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;$BRIEF;"

# The matched side of the same rule: the spent window is scoped to the model
# the caller's own status line names, so it walls this session and the mark
# fires. Nothing but the window's label differs from the row above.
new_caller "$UNDER_MARK"
jq -n --argjson m "$AT_TRIGGER" '{
  five_hour: {utilization: 0, resets_at: "2026-07-27T06:00:00Z"},
  seven_day: {utilization: 0, resets_at: "2026-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: $m, resets_at: "2026-08-01T06:00:00Z",
            scope: {model: {display_name: "Fable 5.1"}}}]
}' > "$FIXTURE_DIR/.claude.json"
run_succeed matchedbucket 'claude:1:high'
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
check "a spent window scoped to the model this overseer runs fires the account mark" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$BRIEF;"

# The model reaches the account mark on every claude tier, not only the ones
# the window table names. This caller runs Sonnet, which that table leaves out,
# so its line carries no window and the parse prints three empty fields before
# the model. Read with a split that collapses a tab run, the model lands in the
# token field and the mark is judged with no model at all: this account's only
# spent window is scoped to Opus at exactly the trigger, so it would fire and
# hand the session over for a window no Sonnet turn draws on.
new_caller "$NO_TABLE_TIER"
jq -n --argjson m "$AT_TRIGGER" '{
  five_hour: {utilization: 0, resets_at: "2026-07-27T06:00:00Z"},
  seven_day: {utilization: 0, resets_at: "2026-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: $m, resets_at: "2026-08-01T06:00:00Z",
            scope: {model: {display_name: "Opus"}}}]
}' > "$FIXTURE_DIR/.claude.json"
run_succeed tiernotintable 'claude:1:high'
check "a tier the window table leaves out still carries its model into the account mark" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: window-below-mark window=none source=none headroom=100|0|none"

# The must-fail inverse of that row, on the same screen and the same fixture:
# with the model gone from the account judge the Opus window counts, the mark
# fires, and the successor opens.
new_caller "$NO_TABLE_TIER"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
SUCCEED_BIN="$WIDEMARK/oversee-succeed" run_succeed tiermutant 'claude:1:high'
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
check "control: with no model in the judge the same Sonnet caller fires on its Opus window" \
  "$RC|$(layout)|$(caller_open)" \
  "0|1 overseer;|no"

# The caller fallback entry names no model in the LAUNCH, and its pick is still
# judged on one: that successor carries this overseer's own flags, so it runs
# the model this pane runs. The second claude lane has room for it, its shared
# windows reading 5 and 20, and its Opus window at 95 walls nothing either
# overseer will draw on. Judged with no model the pick reads that 95 and
# refuses an account that would have carried the successor.
new_caller "$UNDER_MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
jq -n '{
  five_hour: {utilization: 5, resets_at: "2026-07-27T06:00:00Z"},
  seven_day: {utilization: 20, resets_at: "2026-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: 95, resets_at: "2026-08-01T06:00:00Z",
            scope: {model: {display_name: "Opus"}}}]
}' > "$FIXTURE_DIR/.eclaude.json"
run_succeed callerfallbackmodel ''
check "the caller fallback pick is judged on the model this overseer runs" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.eclaude;-n;overseer;$BRIEF;"

# The must-fail inverse: the caller entry judged with no model, which is what
# that pick read before. The Opus window then walls the only lane with room and
# the run refuses with the caller still at its trigger.
NOCALLERMODEL="$TMP_ROOT/nocallermodel"
script_copy "$NOCALLERMODEL"
rm -f -- "${NOCALLERMODEL:?}/oversee-succeed"
sed 's/^    pick_model="\$CALLER_MODEL"$/    pick_model=""/' "$SUCCEED" > "$NOCALLERMODEL/oversee-succeed"
chmod +x "$NOCALLERMODEL/oversee-succeed"
check "control: the mutant really drops the caller model from its pick" \
  "$(cmp -s "$NOCALLERMODEL/oversee-succeed" "$SUCCEED" && echo same || echo differs)" "differs"
new_caller "$UNDER_MARK"
SUCCEED_BIN="$NOCALLERMODEL/oversee-succeed" run_succeed nocallermodel ''
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
check "control: judged with no model the caller fallback refuses the lane that had room" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: no-lane-qualifies entries=0 fallback=claude walled=2 unmeasured=0 mark=headroom account=claude resets=2026-07-27T06:00:00Z|yes|0|none"

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
  five_hour: {utilization: 5, resets_at: "2026-07-27T06:00:00Z"},
  seven_day: {utilization: 20, resets_at: "2026-08-01T06:00:00Z"},
  limits: [{kind: "weekly_scoped", percent: 95, resets_at: "2026-08-01T06:00:00Z",
            scope: {model: {display_name: "Opus"}}},
           {kind: "weekly_scoped", percent: 10, resets_at: "2026-08-01T06:00:00Z",
            scope: {model: {display_name: "Fable 5.1"}}}]
}' > "$FIXTURE_DIR/.eclaude.json"
run_succeed bindingfloor 'claude:1:high'
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
check "a lane with room for the entry's model and none outside it is opened on" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;$BRIEF;"

# Which reading the pick is held to is lib/lane-context.sh's answer, because it
# is the reading THAT file takes off the successor's own status line later. A
# claude line names the model, so the pick names it too and the two judgements
# read one bucket. A codex line names none, so a codex successor is judged on
# the account's binding bucket whatever model it was launched on, and the pick
# is held there with --binding-floor. The RULE is pinned here, where it is
# decided; the row below it pins the FORWARDING of the flag that rule selects,
# over a stubbed judge, because no usage fixture can distinguish the two walls
# for codex: lanes' codex parser reports no model-scoped window at all, so a
# local codex account's two readings are already one number, and only the host
# accounts protocol carries a scoped codex window.
check "the pick reading follows the harness whose status line names the model" \
  "$(lane_context_mark_model claude fable)|$(lane_context_mark_model codex gpt-6-astra)|$(lane_context_mark_model claude '')|$(lane_context_mark_model '' fable)" \
  "fable|||"

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
FLOORFWD="$TMP_ROOT/floorfwd"
script_copy "$FLOORFWD"
rm -f -- "${FLOORFWD:?}/lanes"
cp "$STUB_LANES" "$FLOORFWD/lanes"
new_caller "$MARK"
SUCCEED_BIN="$FLOORFWD/oversee-succeed" run_succeed floorfwd 'codex:1:high'
check "the codex sweep is asked with the binding floor, so an account walled on its own bucket is refused" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded codex)" \
  "3|oversee-succeed: no-lane-qualifies entries=1 fallback=claude walled=2 unmeasured=0 mark=headroom account=fixture@example.com resets=2026-09-22T00:00:00Z|yes|0|none"

# The must-fail inverse: with the floor expansion dropped from the pick call,
# the same stub answers the codex sweep with room and the successor opens on
# the very account whose own first mark would succeed it again.
FLOORDROP="$TMP_ROOT/floordrop"
script_copy "$FLOORDROP"
rm -f -- "${FLOORDROP:?}/lanes" "${FLOORDROP:?}/oversee-succeed"
cp "$STUB_LANES" "$FLOORDROP/lanes"
awk -v line='    ${floor[@]+"${floor[@]}"} ${exclude[@]+"${exclude[@]}"} ${2:+--model "$2"} --json 2>"$DEP_ERR")" || rc=$?' \
    -v repl='    ${exclude[@]+"${exclude[@]}"} ${2:+--model "$2"} --json 2>"$DEP_ERR")" || rc=$?' \
  '$0 == line { print repl; hits++; next } { print }
   END { if (hits != 1) exit 1 }' "$SUCCEED" > "$FLOORDROP/oversee-succeed"
chmod +x "$FLOORDROP/oversee-succeed"
check "control: the mutant really drops the binding floor from the pick" \
  "$(cmp -s "$FLOORDROP/oversee-succeed" "$SUCCEED" && echo same || echo differs)" "differs"
new_caller "$MARK"
FLOORDROP_CWD="$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')"
FLOORDROP_HOME="$(lane_codex_home_path "$H/.codex" "$FLOORDROP_CWD")"
SUCCEED_BIN="$FLOORDROP/oversee-succeed" run_succeed floordrop 'codex:1:high'
check "control: without the floor the same account is picked and the successor opens on it" \
  "$RC|$(overseers)|$(recorded codex)" \
  "0|1|lane=$FLOORDROP_HOME;-m;gpt-6-astra;-c;model_reasoning_effort=high;$BRIEF;"

new_caller "$NO_WINDOW_1M"
SUCCEED_BIN="$UNPATCHED/oversee-succeed" run_succeed control 'claude:1:high'
check "control: with the window table empty the same screen refuses and launches nothing" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: window-below-mark window=none source=none headroom=80|0|none"

# The model and effort words come from lib/lane-launch.sh's table. A harness the
# table holds no row for is not a launch this builder can write: nothing here
# knows how that harness spells a model, and a successor started without one
# runs on whatever default it ships and spends the account either way. Reached
# by taking the rows away rather than by naming a third harness, because the
# preference parser and `lanes pick` each admit claude and codex alone, so one
# planted defect cannot otherwise arrive at the builder.
ROWLESS="$TMP_ROOT/rowless"
script_copy "$ROWLESS"
rm -f -- "${ROWLESS:?}/lib/lane-launch.sh"
sed "s/printf '%s\\\\n' \"\$row\"; return;/return;/" \
  "$SRC_DIR/lib/lane-launch.sh" > "$ROWLESS/lib/lane-launch.sh"
check "control rowless finds the row print to drop" \
  "$(grep -c "printf '%s\\\\n' \"\$row\"; return;" "$ROWLESS/lib/lane-launch.sh")" "0"
new_caller "$MARK"
SUCCEED_BIN="$ROWLESS/oversee-succeed" run_succeed rowless 'claude:1:high'
check "control: with the table holding no row the successor is refused, and none is launched" \
  "$RC|$(keyed launch-choice-failed "$OUT" | sed -n 1p)|$(overseers)|$(recorded claude)" \
  "1|oversee-succeed: launch-choice-failed harness=claude|0|none"


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
  # \$TMP_ROOT/late-secs is how long it stands on the picked account first, so a
  # row places the handover where it needs it in the caller's budget.
  late_secs=3
  [ ! -f "$TMP_ROOT/late-secs" ] || late_secs="\$(cat "$TMP_ROOT/late-secs")"
  CLAUDE_CONFIG_DIR="$H/.4claude" sh -c "sleep \$late_secs"
  CLAUDE_CONFIG_DIR="\$other"
  export CLAUDE_CONFIG_DIR
  echo 'esc to interrupt'
  exec sleep 100000
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
succeed_shim shim 'claude:1:high'
check "a lane whose launcher is on PATH is launched through it by absolute path, with no environment prefix" \
  "$RC|$(caller_open)|$(keyed successor-launch "$OUT" | sed -n 1p)|$(recorded_argv0 4claude)|$(recorded 4claude)|$(recorded claude)" \
  "0|no|oversee-succeed: successor-launch form=launcher:$BIN/4claude lane=$H/.4claude trust=none|$BIN/4claude|lane=;-n;overseer;--model;fable;--effort;high;$BRIEF;|none"

# Control: with the launcher verdict out of the shared builder the same lane is
# launched under the environment prefix a shim overwrites, so the lane's own
# command is never invoked and the bare harness takes the prefix instead.
SHIMCTL="$TMP_ROOT/prefix-only"
script_copy "$SHIMCTL"
rm -f -- "${SHIMCTL:?}/lib/lane-launch.sh"
sed "s/^    printf 'launcher:%s\\\\n' \"\$path\"\$/    printf 'prefix\\\\n'/" \
  "$SRC_DIR/lib/lane-launch.sh" > "$SHIMCTL/lib/lane-launch.sh"
check "control: the launcher verdict is gone from the copy" \
  "$(grep -c "printf 'launcher:%s" "$SHIMCTL/lib/lane-launch.sh")" "0"

new_caller "$MARK"
SUCCEED_BIN="$SHIMCTL/oversee-succeed" succeed_shim shimctl 'claude:1:high' --wait-secs 3
check "control: without the launcher verdict the lane's own command is never invoked" \
  "$(recorded 4claude)" "none"

# A successor stopped at a folder-trust dialog is reported as that, with the
# pane line under the keyed one, and never as a deadline that names nothing.
# BOTH spellings the question ships with are pinned: the predicate claims both,
# and a spelling nobody asserts is a spelling a narrowing edit silently drops,
# leaving a parked successor to time out naming nothing.
for spelling in folder directory; do
  new_caller "$MARK"
  printf 'Do you trust the files in this %s?\n' "$spelling" > "$TMP_ROOT/dialog"
  succeed_shim "dialog-$spelling" 'claude:1:high' --wait-secs 30
  rm -f "${TMP_ROOT:?}/dialog"
  check "a successor at the $spelling spelling of the trust dialog: successor-dialog with the pane line" \
    "$RC|$(keyed successor-dialog "$OUT" | sed -n '1p;3p' | sed 's/window=@[0-9]*/window=@N/; s/waited=[0-9]*/waited=N/' | tr '\n' ';')|$(caller_open)|$(overseers)" \
    "1|oversee-succeed: successor-dialog window=@N waited=N;Do you trust the files in this $spelling?;|yes|0"
done

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
  "$TMP_ROOT/succeed-env" quoted 'claude:1:high' 2>&1)" || RC=$?
check "a lane directory carrying an apostrophe is quoted for the pane shell and reaches the harness" \
  "$RC|$(caller_open)|$(recorded claude)" \
  "0|no|lane=$H/.$QLANE;-n;overseer;--model;fable;--effort;high;$BRIEF;"

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
# both come out as that same standing launch — and neither can a control whose
# defect only shows once a read has an account to settle on. Those rows name
# themselves as skipped instead, off the check's own predicate.

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
  succeed_shim wronglane 'claude:1:high' --wait-secs 20
  check "a successor whose wrapper selected another account: successor-wrong-lane, caller kept, successor closed" \
    "$RC|$(keyed successor-wrong-lane "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
    "1|oversee-succeed: successor-wrong-lane picked=$H/.4claude observed=$H/.claude|yes|0"
fi

# Control: with the mismatch reported instead of abandoned, the same run hands
# the caller's slot to a successor on an account the fleet is not counting, and
# the caller that could have kept running is gone.
LANECTL="$TMP_ROOT/report-only"
mkdir -p "$LANECTL"
ln -s "$SRC_DIR"/* "$LANECTL/"
rm -f -- "${LANECTL:?}/oversee-succeed"
sed 's/mismatch) abandon successor-wrong-lane/mismatch) message successor-wrong-lane/' \
  "$SRC_DIR/oversee-succeed" > "$LANECTL/oversee-succeed"
chmod +x "$LANECTL/oversee-succeed"
check "control: the abandon is gone from the copy" \
  "$(grep -c 'mismatch) abandon successor-wrong-lane' "$LANECTL/oversee-succeed")" "0"

if observed_row "control: without the abandon the caller closes and the successor keeps the wrong account"; then
  new_caller "$MARK"
  SUCCEED_BIN="$LANECTL/oversee-succeed" succeed_shim wronglanectl 'claude:1:high' --wait-secs 20
  check "control: without the abandon the caller closes and the successor keeps the wrong account" \
    "$RC|$(caller_open)|$(overseers)" "0|no|1"
fi
rm -f -- "${TMP_ROOT:?}/selects"

# A wrapper that stands on the picked account while it comes up and hands over
# only as the harness starts. A reading taken before the pane shows a running
# turn settles on the picked value and confirms an account the pane is about to
# stop carrying, which is why the reading that decides is taken after.
if observed_row "a wrapper that hands the account over as the harness starts is caught"; then
  new_caller "$MARK"
  printf '%s\n' "$H/.claude" > "$TMP_ROOT/selects-late"
  succeed_shim latelane 'claude:1:high' --wait-secs 12
  check "a wrapper that hands the account over as the harness starts is caught, the deciding read coming after the running turn" \
    "$RC|$(keyed successor-wrong-lane "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
    "1|oversee-succeed: successor-wrong-lane picked=$H/.4claude observed=$H/.claude|yes|0"
fi

# Control: with the deciding read gone, only the early one is left, and it
# settles on the account the wrapper was still standing on.
LATECTL="$TMP_ROOT/early-only"
mkdir -p "$LATECTL"
ln -s "$SRC_DIR"/* "$LATECTL/"
rm -f -- "${LATECTL:?}/oversee-succeed"
grep -v '^account_verdict "$(succ_budget_bound)" final$' "$SRC_DIR/oversee-succeed" > "$LATECTL/oversee-succeed"
chmod +x "$LATECTL/oversee-succeed"
check "control: the deciding read is gone from the copy" \
  "$(grep -c 'account_verdict "$(succ_budget_bound)" final' "$LATECTL/oversee-succeed")" "0"

if observed_row "control: without the deciding read the handover is never seen and the caller closes"; then
  new_caller "$MARK"
  SUCCEED_BIN="$LATECTL/oversee-succeed" succeed_shim latelanectl 'claude:1:high' --wait-secs 12
  check "control: without the deciding read the handover is never seen and the caller closes" \
    "$RC|$(caller_open)|$(overseers)" "0|no|1"
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
succeed_shim unobserved 'claude:1:high' --wait-secs 3
rm -f -- "${TMP_ROOT:?}/selects-nothing"
check "a successor whose account could not be observed: named on stderr, launch stands" \
  "$RC|$(keyed successor-lane-unobserved "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
  "0|oversee-succeed: successor-lane-unobserved reason=$UNOBSERVED_REASON|no|1"

# --wait-secs is ONE deadline over the account read and the running-turn wait,
# which the help tells a caller to size its shell timeout by. Wall clock, not
# the reported figure: it is exactly what the budgeting under test decides, so
# asserting it would assert the defect as readily as the fix. An
# unobservable launch that never works spends the read's whole cap and then the
# rest of the budget, which is the longest this path can take. Where no
# per-process environment is readable the read answers at once instead and the
# seconds go to the wait; the ceiling is what this row pins either way, which is
# what a caller sizes its timeout by.
#
# The ceiling is the promise succ_budget_bound's floor states — --wait-secs plus
# at most one settle — with two terms on top, since the figure is taken off
# `date +%s` around the whole call rather than inside the script.
# BOUND_OVERHEAD is the part of that window which is not the wait: the shim's
# own fork and capture, the window the run opens and the lane launch under it.
# SCHED_SLACK is the runner's lateness over all of it.
# BOUND_WAIT is sized so that ceiling still sits under the defect the control
# below plants: that copy spends the early read's half-share and only then
# starts its own whole --wait-secs, so it cannot return before one and a half
# of them. 18 seconds is that floor here, and the ceiling is 16, so the three
# terms above may grow by one more second between them before the control stops
# being able to fail this row's claim.
BOUND_WAIT=12
BOUND_OVERHEAD=1
BOUND_CEILING=$(( BOUND_WAIT + LANE_SETTLE_MIN_SECS + BOUND_OVERHEAD + SCHED_SLACK ))
new_caller "$MARK"
touch "$TMP_ROOT/selects-nothing" "$TMP_ROOT/idle"
bound_started=$(date +%s)
succeed_shim bound 'claude:1:high' --wait-secs "$BOUND_WAIT"
bound_elapsed=$(( $(date +%s) - bound_started ))
check "a run that never works returns inside one --wait-secs bound, not the sum of two" \
  "$RC|$(in_range within "$bound_elapsed" '' "$BOUND_CEILING")" "1|within"

# The copy that budgets the old way: the running-turn wait counting its own
# seconds from where it started rather than asking the one clock, which is the
# shape that gave it a second deadline and left the deciding read at zero. One
# line, because the counter it needed is gone from the script under test.
BOUNDCTL="$TMP_ROOT/two-bounds"
mkdir -p "$BOUNDCTL"
ln -s "$SRC_DIR"/* "$BOUNDCTL/"
rm -f -- "${BOUNDCTL:?}/oversee-succeed"
sed 's/if (( \$(succ_budget_raw) <= 0 )); then/if (( \${loop_started:=\$(date +%s)} + WAIT_SECS <= \$(date +%s) )); then/' \
    "$SRC_DIR/oversee-succeed" > "$BOUNDCTL/oversee-succeed"
chmod +x "$BOUNDCTL/oversee-succeed"
check "control: the running-turn wait starts its own deadline in the copy" \
  "$(grep -c 'loop_started:=' "$BOUNDCTL/oversee-succeed")" "1"

# The overrun is the seconds the account read spent before the loop began, so
# this control needs a read that can spend any: where there is no per-process
# environment to look in, the read answers at once and the second deadline lands
# inside the first.
if observed_row "control: a wait that starts its own deadline overruns the one --wait-secs bound"; then
  new_caller "$MARK"
  bound_started=$(date +%s)
  SUCCEED_BIN="$BOUNDCTL/oversee-succeed" succeed_shim boundctl 'claude:1:high' --wait-secs "$BOUND_WAIT"
  bound_elapsed=$(( $(date +%s) - bound_started ))
  check "control: a wait that starts its own deadline overruns the one --wait-secs bound" \
    "$RC|$(in_range over "$bound_elapsed" "$((BOUND_CEILING + 1))" '')" "1|over"
fi
rm -f -- "${TMP_ROOT:?}/selects-nothing" "${TMP_ROOT:?}/idle"

# A handover whose running turn lands with the budget already spent. At
# --wait-secs 1 the early read's floored share is the whole of it, so the
# running-turn wait starts with nothing left and the deciding read has only
# succ_budget_bound's floor to look in. It still looks, because the caller's
# window closes on that read and a read that could not look is not an answer to
# close a window on.
if observed_row "a deciding read with the budget already spent still looks, and catches the handover"; then
  new_caller "$MARK"
  printf '%s
' "$H/.claude" > "$TMP_ROOT/selects-late"
  printf '0.2
' > "$TMP_ROOT/late-secs"
  succeed_shim lastsecond 'claude:1:high' --wait-secs 1
  check "a deciding read with the budget already spent still looks, and catches the handover" \
    "$RC|$(keyed successor-wrong-lane "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
    "1|oversee-succeed: successor-wrong-lane picked=$H/.4claude observed=$H/.claude|yes|0"
fi

# The copy that subtracts for the deciding read instead of asking for a bound,
# which is how that read was handed a zero it could not settle in.
LASTCTL="$TMP_ROOT/spent-budget"
mkdir -p "$LASTCTL"
ln -s "$SRC_DIR"/* "$LASTCTL/"
rm -f -- "${LASTCTL:?}/oversee-succeed"
sed 's/^account_verdict "\$(succ_budget_bound)" final$/account_verdict "$(( WAIT_SECS - $(succ_waited) ))" final/' \
  "$SRC_DIR/oversee-succeed" > "$LASTCTL/oversee-succeed"
chmod +x "$LASTCTL/oversee-succeed"
check "control: the deciding read takes the budget's remainder in the copy" \
  "$(grep -c '^account_verdict "\$(( WAIT_SECS - \$(succ_waited) ))" final$' "$LASTCTL/oversee-succeed")" "1"

# The reason is the pin: a host with no per-process environment closes the
# caller on an unobserved read whatever this copy subtracts, so the row would
# pass there without the defect it plants ever deciding anything.
if observed_row "control: subtracting for it leaves the deciding read nothing, and the caller closes on it"; then
  new_caller "$MARK"
  SUCCEED_BIN="$LASTCTL/oversee-succeed" succeed_shim lastsecondctl 'claude:1:high' --wait-secs 1
  check "control: subtracting for it leaves the deciding read nothing, and the caller closes on it" \
    "$RC|$(keyed successor-lane-unobserved "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
    "0|oversee-succeed: successor-lane-unobserved reason=no-settle-budget|no|1"
fi
rm -f -- "${TMP_ROOT:?}/selects-late" "${TMP_ROOT:?}/late-secs"

# No control for the early read's half-cap, and none is possible from here. Its
# effect is how many probes the running-turn wait gets, and a pane that starts
# a turn stays in one: the uncapped copy's single probe at the deadline sees
# the same working screen the capped copy's earlier probes see, so every
# end-to-end outcome is identical. What the rows above do hold is the deadline
# itself and the deciding read's bound, which is what a caller and an operator
# see.

echo "=== an overseer whose ACCOUNT is spent, which reaches none of the marks either ==="
# A walled overseer is not dead: its harness is running and its pane still
# draws a status line, so nothing here needs a recorded line. What it cannot
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
WALLED_LINE="env CLAUDE_CONFIG_DIR='$H/.eclaude' claude -n overseer '$BRIEF'"
check "--walled-pane opens the successor on the lane the pick named, never on the caller's own" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.eclaude;-n;overseer;$BRIEF;"
# The line is on stdout ahead of every keyed line, and in the fleet state: the
# caller is oversee-watch, which reports the recovery it just performed, and a
# later death must not relaunch from the walled session's own line.
check "the walled recovery prints the line it built and records it for a later relaunch" \
  "$(sed -n 1p <<<"$OUT")|$(recorded_line)" \
  "$WALLED_LINE|$WALLED_LINE"

# The context mark well under its trigger and the account mark well over its
# own: a live succession ends at `context-below-mark` here and launches
# nothing. The walled run launches, because the wall is its trigger.
new_caller "$UNDER_MARK"
run_succeed walledmarkless ''
check "the same world under both marks: a live succession launches nothing" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=50|yes|0"
new_caller "$UNDER_MARK"
run_succeed walledundermark '' --walled-pane "$CALLER_PANE"
check "and the walled recovery of it launches, judging no mark at all" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.eclaude;-n;overseer;$BRIEF;"

# Succession off launches nothing here as everywhere else: the operator's
# setting is read before the pane is.
new_caller "$MARK"
SUCCESSION=off run_succeed walledoff '' --walled-pane "$CALLER_PANE"
check "succession off refuses the walled recovery and keeps the caller's window" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: succession-off ORCH_OVERSEER_SUCCESSION=off|yes|0|none"

# Every claude lane at or below the trigger. The refusal is exit 3, the status
# `lanes pick` itself answers "no lane clears the bound" with, so the caller
# can tell a fleet with no room from a launch that broke; it carries
# `mark=wall` and names no account, no mark having been judged to name one by.
new_caller "$MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed wallednoroom '' --walled-pane "$CALLER_PANE"
walled_world
check "no account above the trigger: the walled recovery refuses at exit 3 under mark=wall" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: no-lane-qualifies entries=0 fallback=claude walled=2 unmeasured=0 mark=wall|yes|0|none"

# The successor keeps THIS session's model, effort and permission flags and
# changes the account alone. The preference names where a later successor
# goes at a MARK and is not walked here, so launch_choice_write writes no
# model or effort beside the ones the caller's own flags already carry: a
# command naming two models runs on whichever the harness reads last, which
# is a model no pick judged.
new_caller "$MARK"
walled_world
run_succeed walledflags 'codex:1:high' --walled-pane "$CALLER_PANE" -- --model fable --effort high --verbose
check "--walled-pane keeps this session's own model and effort, and the preference writes none beside them" \
  "$RC|$(recorded claude)|$(recorded codex)" \
  "0|lane=$H/.eclaude;-n;overseer;--model;fable;--effort;high;--verbose;$BRIEF;|none"

# The one account this recovery may never open on is the one it is recovering
# from. The caller's own lane is given the MOST room here, so the pick names
# it: an inventory that has not caught up with the wall on that pane reads
# exactly like this. The entry is skipped and the run refuses rather than
# relaunching into the wall.
new_caller "$MARK"
claude_usage 10 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 50 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed walledspent '' --walled-pane "$CALLER_PANE"
walled_world
check "a pick naming the walled account itself is skipped, not opened on" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(keyed successor-lane-spent "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: successor-lane-spent lane=$H/.claude entry=caller|oversee-succeed: successor-lane-spent lane=$H/.claude entry=caller|yes|0|none"

# The same account under a spelling the pick does not use. This side is
# whatever the operator's shell exported and the pick's side is whatever lane
# discovery produced, so the two are compared through the pairing
# lane_account_check compares an observed account against a picked one with,
# and never as strings. A trailing slash is the cheapest way to have one
# account spelled twice; without that pairing the guard does not fire and the
# successor opens on the account that just walled.
new_caller "$MARK"
claude_usage 10 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 50 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
CALLER_LANE="CLAUDE_CONFIG_DIR=$H/.claude/" run_succeed walledspentslash '' --walled-pane "$CALLER_PANE"
walled_world
check "the walled account spelled another way is still the walled account" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "3|oversee-succeed: successor-lane-spent lane=$H/.claude/ entry=caller|yes|0|none"

# Control: account identity decided as a bare string, which is what the guard
# read before. The one spelling difference is then two accounts and the
# successor opens straight back into the wall.
SPENTCTL="$TMP_ROOT/spentctl"
script_copy "$SPENTCTL"
rm -f -- "${SPENTCTL:?}/oversee-succeed"
sed 's|^    if \[\[ "\$MODE" == walled && "\$(lane_account_id "\$PICKED_DIR")" == "\$WALLED_LANE_ID" \]\]; then$|    if [[ "$MODE" == walled \&\& "$PICKED_DIR" == "$WALLED_LANE" ]]; then|' \
  "$SUCCEED" > "$SPENTCTL/oversee-succeed"
chmod +x "$SPENTCTL/oversee-succeed"
check "control: the copy really compares the two spellings as strings" \
  "$(cmp -s "$SPENTCTL/oversee-succeed" "$SUCCEED" && echo same || echo differs)|$(bash -n "$SPENTCTL/oversee-succeed" && echo parses || echo broken)" \
  "differs|parses"
new_caller "$MARK"
claude_usage 10 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 50 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
CALLER_LANE="CLAUDE_CONFIG_DIR=$H/.claude/" SUCCEED_BIN="$SPENTCTL/oversee-succeed" \
  run_succeed spentctl '' --walled-pane "$CALLER_PANE"
walled_world
check "control: compared as strings the successor opens on the account that walled" \
  "$RC|$(recorded claude)" \
  "0|lane=$H/.claude;-n;overseer;$BRIEF;"

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
  check "$row_label: refused, nothing launched" \
    "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(caller_open)" \
    "1|oversee-succeed: $row_want|0|yes"
done

# Control: the pick gate naming `succeed` alone, which is what it said before
# this mode existed. The caller entry then keeps the account the walled
# session was spending, and the successor opens straight back into the wall.
WALLCTL="$TMP_ROOT/wallctl"
script_copy "$WALLCTL"
rm -f -- "${WALLCTL:?}/oversee-succeed"
sed 's/^  if \[\[ "\$MODE" == succeed || "\$MODE" == walled \]\] \\$/  if [[ "$MODE" == succeed ]] \\/' \
  "$SUCCEED" > "$WALLCTL/oversee-succeed"
chmod +x "$WALLCTL/oversee-succeed"
check "control: the copy really leaves the walled mode out of the pick gate" \
  "$(cmp -s "$WALLCTL/oversee-succeed" "$SUCCEED" && echo same || echo differs)|$(bash -n "$WALLCTL/oversee-succeed" && echo parses || echo broken)" \
  "differs|parses"
new_caller "$MARK"
SUCCEED_BIN="$WALLCTL/oversee-succeed" run_succeed wallctl '' --walled-pane "$CALLER_PANE"
check "control: without that gate the successor opens on the account that walled" \
  "$RC|$(recorded claude)" \
  "0|lane=$H/.claude;-n;overseer;$BRIEF;"
walled_world_reset

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
