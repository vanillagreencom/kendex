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
chmod +x "$BIN/claude" "$BIN/codex" "$BIN/kendex"

# The trigger every headroom fixture below is derived from: a lane at exactly
# TRIGGER percent headroom has no room and one at TRIGGER+1 does, so the rows
# move with the setting instead of pinning 80 and 79 by hand.
TRIGGER=20
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
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
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

# The same script over a lane-context.sh whose window table is empty, which is
# what this reader did before the table existed.
SRC_DIR="$(cd "$(dirname "$SUCCEED")" && pwd)"
# The account read's own condition, taken from the library the script under
# test sources, so every host decision below is the check's own answer and not
# a second copy of its test. See § The account the pane is really on.
# shellcheck source=../scripts/lib/lane-launch.sh
source "$SRC_DIR/lib/lane-launch.sh"
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

# new_caller SCREEN [MARKER] — every window past index 0 closed, then a caller
# pane at index 1 showing SCREEN; sets CALLER_PANE and CALLER_WINDOW. MARKER is
# the text that says the pane has drawn, defaulting to the claude screens' own.
new_caller() {
  local f="$TMP_ROOT/caller.screen" spec marker="${2:-(fixture@example.com)}"
  printf '%s\n' "$1" > "$f"
  tm kill-window -a -t fleet:0
  spec="$(tm new-window -d -t fleet:1 -P -F '#{pane_id} #{window_id}' "cat '$f'; exec sleep 100000")"
  read -r CALLER_PANE CALLER_WINDOW <<<"$spec"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ "$(tm capture-pane -p -t "$CALLER_PANE")" != *"$marker"* ]] || return 0
    sleep 0.2
  done
  echo "fixture: caller pane never drew its screen" >&2
  exit 1
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
cd "$TMP_ROOT/work" && exec env -i HOME="$H" PATH="$BIN:$PATH" TMUX="\$TMUX" TMUX_PANE="\$TMUX_PANE" \\
  LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state-\$row" \\
  "\${CALLER_LANE:-CLAUDE_CONFIG_DIR=$H/.claude}" \\
  ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="\${LANE_DIRS:-$H/.claude:$H/.eclaude:$H/.codex}" ORCH_OVERSEER_PREFERENCE="\$pref" \\
  ORCH_OVERSEER_SUCCESSION="\${SUCCESSION:-on}" \\
  \$hp "\${SUCCEED_BIN:-$SUCCEED}" "\$@"
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
  "1|oversee-succeed: no-lane-qualifies entries=2 mark=account account=claude resets=2026-07-27T06:00:00Z|yes|0|none|none"
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

# The same refusal from a CODEX overseer. Its account's reset arrives from the
# harness as a Unix epoch, and the field must name a time in the one spelling a
# claude overseer prints, not an integer the operator has to convert.
new_caller "$CODEX_SCREEN" 'Context 48% left'
codex_usage 95 > "$FIXTURE_DIR/.codex.json"
CALLER_LANE="CODEX_HOME=$H/.codex" run_succeed codexwall 'codex:1:high'
codex_usage 20 > "$FIXTURE_DIR/.codex.json"
check "a codex overseer's refusal names its reset as a time, not an epoch" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded codex)" \
  "1|oversee-succeed: no-lane-qualifies entries=1 mark=account account=codex resets=2026-07-25T17:20:00Z|yes|0|none"

# A pane id is not a session: ids restart at %0 on every tmux server, a claim
# from another server survives the read as a row of its own, and the caller's
# row is appended last. Keyed on the pane id alone the account mark would take
# that foreign account's headroom of 5 and succeed an overseer whose own
# account holds 80.
new_caller "$UNDER_MARK"
write_foreign_claim foreign-pane "$CALLER_PANE" "$H/.eclaude"
run_succeed foreign-pane 'claude:1:high'
check "a foreign server's claim on the caller's pane number is not the caller's row" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=80|0|none"

# A `lanes context` that cannot answer says nothing about this account: the
# lane reports no headroom, the context mark decides alone, and the cause rides
# the message. A claims path that is a file rather than a directory is what
# `lanes` refuses `context-claims` on.
new_caller "$UNDER_MARK"
mkdir -p "$TMP_ROOT/state-ctxfail"
: > "$TMP_ROOT/state-ctxfail/claims"
run_succeed ctxfail 'claude:1:high'
check "an unanswerable lanes context leaves the account mark unfired, not the run refused" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=unreadable|0|none"

# A preference naming another harness walks that harness's lanes alone, so the
# caller's own claude account with 80 headroom is not what ran out. The refusal
# says which mark fired and names no account at the context mark.
new_caller "$MARK"
codex_usage 95 > "$FIXTURE_DIR/.codex.json"
run_succeed crossharness 'codex:1:high'
codex_usage 20 > "$FIXTURE_DIR/.codex.json"
check "context mark with another harness walled: the refusal names no account" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded codex)" \
  "1|oversee-succeed: no-lane-qualifies entries=1 mark=context|yes|0|none"

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

# What the three modes refuse of each other. Each is a different launch, and a
# combination read as one of the two would send a line built for another pane
# or none at all. Every row refuses before tmux is asked anything.
: > "$TMP_ROOT/empty-line"
for row in \
  "--dead-pane %9 --line-file $TMP_ROOT/line-file -- --verbose|mode-conflict dead-pane=%9 print=0 flags=1|permission flags beside a recorded line" \
  "--dead-pane %9 --print-launch-line --line-file $TMP_ROOT/line-file|mode-conflict dead-pane=%9 print=1 flags=0|a print asked of a dead pane" \
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
# which is above the default 20 and at or below 60, so only a setting that is
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

# The same boundary on the pick side: the only candidate sits exactly at the
# trigger and must be refused, then one percent above it and must be chosen.
new_caller "$MARK"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed pickatbound 'claude:1:high'
check "a candidate at exactly the trigger is refused, not picked" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "1|oversee-succeed: no-lane-qualifies entries=1 mark=account account=claude resets=2026-07-27T06:00:00Z|yes|0|none"

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
  "1|oversee-succeed: no-lane-qualifies entries=1 mark=context|yes|0|none"

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
  "1|oversee-succeed: no-lane-qualifies entries=1 mark=account account=claude resets=2026-07-27T06:00:00Z|yes|0|none"

# The account mark on the OTHER caller-row path: a claim from this server
# already names the caller's pane, so the flag goes onto that record instead of
# onto an appended one. Lose the flag there and no row is the caller's, the
# account reads as unmeasured, and this row stops at the context mark.
new_caller "$UNDER_MARK"
write_own_claim claimedcaller "$CALLER_PANE" "$H/.claude"
claude_usage "$AT_TRIGGER" 0 0 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 50 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
run_succeed claimedcaller ''
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
check "a caller pane a claim already names is the flagged row, and its account mark fires" \
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

# A model wall alone is not the whole question for this caller. The second
# claude lane has room for the model this entry passes, its Fable window being
# at 10, and none of its own, its Opus window being at 95 so its headroom is 5.
# Opened there, the successor reads that headroom at its own account mark on the
# first judgement it makes and succeeds itself again, costing a window swap and
# a handoff per cycle. The pick is held to the trigger on BOTH walls, so the
# entry is skipped and the run refuses; without the floor this row launches.
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
check "a lane with room for the entry's model and none of its own is not opened on" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(caller_open)|$(overseers)|$(recorded claude)" \
  "1|oversee-succeed: no-lane-qualifies entries=1 mark=account account=claude resets=2026-07-27T06:00:00Z|yes|0|none"

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

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
