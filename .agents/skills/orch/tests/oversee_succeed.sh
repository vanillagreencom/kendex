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

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN" "$TMP_ROOT/work"
for harness in claude codex; do
  lane_var=CLAUDE_CONFIG_DIR
  [[ "$harness" == claude ]] || lane_var=CODEX_HOME
  cat > "$BIN/$harness" <<STUB
#!/bin/sh
{ printf 'lane=%s\n' "\${$lane_var:-}"; printf 'argv0=%s\n' "\$0"; printf '%s\n' "\$@"; } > "$TMP_ROOT/argv.$harness"
[ -f "$TMP_ROOT/idle" ] || echo 'esc to interrupt'
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

new_home fleet
make_lane "$H" claude
make_codex_lane "$H/.codex"
FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"
jq -n '{rate_limit: {primary_window: {used_percent: 20, reset_at: 1785000000, limit_window_seconds: 18000}, secondary_window: null}}' \
  > "$FIXTURE_DIR/.codex.json"

env PATH="$BIN:$PATH" tmux -L "$SOCK" -f /dev/null new-session -d -s fleet -x 220 -y 50 'exec sleep 100000'
tm set-option -g default-shell /bin/sh
# The successor window is the one pane this suite does not start with a command
# of its own, so tmux would run the shell as a LOGIN shell there: it re-reads
# the machine's profiles, and a developer with a real `claude` earlier on the
# rebuilt PATH gets that instead of the stub beside this file. A plain shell
# keeps the server's PATH, which is the one the stubs were put on.
tm set-option -g default-command /bin/sh
tm set-option -g renumber-windows off
TMUX_ADDR="$(tm display-message -p '#{socket_path},#{pid},0')"

MARK='  kendex (ken-1453) Fable 5.1 (1M context) 52% (fixture@example.com)     /rc'
# The line a status-line command that prints the percentage alone draws: no
# window at all, which is what the overseer this feature was built for shows.
NO_WINDOW_1M='  kendex (ken-1453) Fable 5.1 52% (fixture@example.com)     /rc'
UNDER_MARK='  kendex (ken-1453) Fable 5.1 (1M context) 10% (fixture@example.com)     /rc'

# The same script over a lane-context.sh whose window table is empty, which is
# what this reader did before the table existed. The tree is
# symlinks but for that one file, so every other dependency is the real one.
SRC_DIR="$(cd "$(dirname "$SUCCEED")" && pwd)"
UNPATCHED="$TMP_ROOT/unpatched"
mkdir -p "$UNPATCHED"
ln -s "$SRC_DIR"/* "$UNPATCHED/"
rm -f -- "${UNPATCHED:?}/lib"
mkdir "$UNPATCHED/lib"
ln -s "$SRC_DIR"/lib/* "$UNPATCHED/lib/"
rm -f -- "${UNPATCHED:?}/lib/lane-context.sh"
sed "s/^LANE_CONTEXT_DEFAULT_WINDOWS=.*/LANE_CONTEXT_DEFAULT_WINDOWS=''/" \
  "$SRC_DIR/lib/lane-context.sh" > "$UNPATCHED/lib/lane-context.sh"

# new_caller SCREEN — every window past index 0 closed, then a caller pane at
# index 1 showing SCREEN; sets CALLER_PANE and CALLER_WINDOW.
new_caller() {
  local f="$TMP_ROOT/caller.screen" spec
  printf '%s\n' "$1" > "$f"
  tm kill-window -a -t fleet:0
  spec="$(tm new-window -d -t fleet:1 -P -F '#{pane_id} #{window_id}' "cat '$f'; exec sleep 100000")"
  read -r CALLER_PANE CALLER_WINDOW <<<"$spec"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ "$(tm capture-pane -p -t "$CALLER_PANE")" != *'(fixture@example.com)'* ]] || return 0
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
cd "$TMP_ROOT/work" && exec env -i HOME="$H" PATH="$BIN:$PATH" TMUX="\$TMUX" TMUX_PANE="\$TMUX_PANE" \\
  LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state-\$row" \\
  ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="\${LANE_DIRS:-$H/.claude:$H/.codex}" ORCH_OVERSEER_PREFERENCE="\$pref" \\
  ORCH_OVERSEER_SUCCESSION="\${SUCCESSION:-on}" \\
  "\${SUCCEED_BIN:-$SUCCEED}" "\$@"
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

echo "=== oversee-succeed ==="

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
  "3 overseer;|no|oversee-succeed: successor-launch form=prefix lane=$H/.claude;oversee-succeed: successor-working window=@N pane=%N;|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;--verbose;$BRIEF;"

new_caller "$MARK"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"
run_succeed walled 'claude:1:high,codex:1:high'
check "walled claude entry: codex entry picked" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)|$(recorded codex)" \
  "0|1 overseer;|no|none|lane=$H/.codex;-m;gpt-6-astra;-c;model_reasoning_effort=high;$BRIEF;"
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

new_caller "$MARK"
touch "$TMP_ROOT/idle"
run_succeed idle 'claude:1:high' --wait-secs 2
rm -f "$TMP_ROOT/idle"
check "never working: refused, caller kept, successor closed" \
  "$RC|$(keyed successor-not-working "$OUT" | sed -n 1p | sed 's/window=@[0-9]*/window=@N/')|$(caller_open)|$(overseers)" \
  "1|oversee-succeed: successor-not-working window=@N waited=2|yes|0"

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
  "0|oversee-succeed: context-below-mark tokens=100000 mark=500000|0|none"

new_caller "$NO_WINDOW_1M"
run_succeed window 'claude:1:high'
check "a line naming no window takes the window its model runs, and the successor launches" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;$BRIEF;"

# What a refusal's window rests on. A window the line NAMES is read off the
# line whatever the table holds for that model, and a model the table leaves
# out is no window at all rather than another model's figure.
for row in \
  "  kendex (ken-1453) Opus 5 (200k context) 41% (fixture@example.com)     /rc|window=200000 source=status-line|a named window under 1M is read off the line, not off the table" \
  "  kendex (ken-1453) Sonnet 4.5 52% (fixture@example.com)     /rc|window=none source=none|a model the table leaves out is unmeasured, not guessed at"; do
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

new_caller "$NO_WINDOW_1M"
SUCCEED_BIN="$UNPATCHED/oversee-succeed" run_succeed control 'claude:1:high'
check "control: with the window table empty the same screen refuses and launches nothing" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: window-below-mark window=none source=none|0|none"

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
  "0|no|oversee-succeed: successor-launch form=launcher:$BIN/4claude lane=$H/.4claude|$BIN/4claude|lane=;-n;overseer;--model;fable;--effort;high;$BRIEF;|none"

# Control: with the launcher verdict out of the shared builder the same lane is
# launched under the environment prefix a shim overwrites, so the lane's own
# command is never invoked and the bare harness takes the prefix instead.
SHIMCTL="$TMP_ROOT/prefix-only"
mkdir -p "$SHIMCTL"
ln -s "$SRC_DIR"/* "$SHIMCTL/"
rm -f -- "${SHIMCTL:?}/lib"
mkdir "$SHIMCTL/lib"
ln -s "$SRC_DIR"/lib/* "$SHIMCTL/lib/"
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

new_caller "$MARK"
printf '%s\n' "$H/.claude" > "$TMP_ROOT/selects"
succeed_shim wronglane 'claude:1:high' --wait-secs 20
check "a successor whose wrapper selected another account: successor-wrong-lane, caller kept, successor closed" \
  "$RC|$(keyed successor-wrong-lane "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
  "1|oversee-succeed: successor-wrong-lane picked=$H/.4claude observed=$H/.claude|yes|0"

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

new_caller "$MARK"
SUCCEED_BIN="$LANECTL/oversee-succeed" succeed_shim wronglanectl 'claude:1:high' --wait-secs 20
check "control: without the abandon the caller closes and the successor keeps the wrong account" \
  "$RC|$(caller_open)|$(overseers)" "0|no|1"
rm -f -- "${TMP_ROOT:?}/selects"

# A wrapper that stands on the picked account while it comes up and hands over
# only as the harness starts. A reading taken before the pane shows a running
# turn settles on the picked value and confirms an account the pane is about to
# stop carrying, which is why the reading that decides is taken after.
new_caller "$MARK"
printf '%s\n' "$H/.claude" > "$TMP_ROOT/selects-late"
succeed_shim latelane 'claude:1:high' --wait-secs 12
check "a wrapper that hands the account over as the harness starts is caught, the deciding read coming after the running turn" \
  "$RC|$(keyed successor-wrong-lane "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
  "1|oversee-succeed: successor-wrong-lane picked=$H/.4claude observed=$H/.claude|yes|0"

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

new_caller "$MARK"
SUCCEED_BIN="$LATECTL/oversee-succeed" succeed_shim latelanectl 'claude:1:high' --wait-secs 12
check "control: without the deciding read the handover is never seen and the caller closes" \
  "$RC|$(caller_open)|$(overseers)" "0|no|1"
rm -f -- "${TMP_ROOT:?}/selects-late"

# An account the check could not observe is not a disagreement it did observe:
# the launch stands, the reason is named, and the successor takes the slot.
new_caller "$MARK"
touch "$TMP_ROOT/selects-nothing"
succeed_shim unobserved 'claude:1:high' --wait-secs 3
rm -f -- "${TMP_ROOT:?}/selects-nothing"
check "a successor whose account could not be observed: named on stderr, launch stands" \
  "$RC|$(keyed successor-lane-unobserved "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
  "0|oversee-succeed: successor-lane-unobserved reason=no-lane-variable|no|1"

# --wait-secs is ONE deadline over the account read and the running-turn wait,
# which the help tells a caller to size its shell timeout by. Wall clock, not
# the reported counter: the counter is exactly what the seed under test decides,
# so asserting it would assert the defect as readily as the fix. An
# unobservable launch that never works spends the read's whole cap and then the
# rest of the budget, which is the longest this path can take.
new_caller "$MARK"
touch "$TMP_ROOT/selects-nothing" "$TMP_ROOT/idle"
bound_started=$(date +%s)
succeed_shim bound 'claude:1:high' --wait-secs 6
bound_elapsed=$(( $(date +%s) - bound_started ))
check "a run that never works returns inside one --wait-secs bound, not the sum of two" \
  "$RC|$([[ "$bound_elapsed" -le 7 ]] && echo within || echo "over:$bound_elapsed")" "1|within"

# The copy that budgets the old way: each wait counting for itself off `waited`
# rather than every wait asking the clock, which is the shape that let the
# running-turn wait start a second deadline and the deciding read reach zero.
# One shape, two lines, and both are asserted before any row runs on it.
BOUNDCTL="$TMP_ROOT/two-bounds"
mkdir -p "$BOUNDCTL"
ln -s "$SRC_DIR"/* "$BOUNDCTL/"
rm -f -- "${BOUNDCTL:?}/oversee-succeed"
sed -e 's/^waited=\$(( \$(date +%s) - succ_started ))$/waited=0/' \
    -e 's/(( \$(succ_budget_raw) > 0 ))/(( waited < WAIT_SECS ))/' \
    "$SRC_DIR/oversee-succeed" > "$BOUNDCTL/oversee-succeed"
chmod +x "$BOUNDCTL/oversee-succeed"
check "control: the loop counts from zero in the copy" \
  "$(grep -c '^waited=0$' "$BOUNDCTL/oversee-succeed")" "1"
check "control: the counter drives the loop in the copy" \
  "$(grep -c '(( waited < WAIT_SECS ))' "$BOUNDCTL/oversee-succeed")" "1"

new_caller "$MARK"
bound_started=$(date +%s)
SUCCEED_BIN="$BOUNDCTL/oversee-succeed" succeed_shim boundctl 'claude:1:high' --wait-secs 6
bound_elapsed=$(( $(date +%s) - bound_started ))
check "control: budgeting off the counter gives the running-turn wait a second deadline" \
  "$RC|$([[ "$bound_elapsed" -le 7 ]] && echo within || echo over)" "1|over"
rm -f -- "${TMP_ROOT:?}/selects-nothing" "${TMP_ROOT:?}/idle"

# A handover whose running turn lands with the budget already spent. At
# --wait-secs 1 the early read's floored share is the whole of it, so the
# running-turn wait starts with nothing left and the deciding read has only
# succ_budget_bound's floor to look in. It still looks, because the caller's
# window closes on that read and a read that could not look is not an answer to
# close a window on.
new_caller "$MARK"
printf '%s
' "$H/.claude" > "$TMP_ROOT/selects-late"
printf '0.2
' > "$TMP_ROOT/late-secs"
succeed_shim lastsecond 'claude:1:high' --wait-secs 1
check "a deciding read with the budget already spent still looks, and catches the handover" \
  "$RC|$(keyed successor-wrong-lane "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
  "1|oversee-succeed: successor-wrong-lane picked=$H/.4claude observed=$H/.claude|yes|0"

# The copy that subtracts for the deciding read instead of asking for a bound,
# which is how that read was handed a zero it could not settle in.
LASTCTL="$TMP_ROOT/spent-budget"
mkdir -p "$LASTCTL"
ln -s "$SRC_DIR"/* "$LASTCTL/"
rm -f -- "${LASTCTL:?}/oversee-succeed"
sed 's/^account_verdict "\$(succ_budget_bound)" final$/account_verdict "$(( WAIT_SECS - waited ))" final/' \
  "$SRC_DIR/oversee-succeed" > "$LASTCTL/oversee-succeed"
chmod +x "$LASTCTL/oversee-succeed"
check "control: the deciding read takes the counter's remainder in the copy" \
  "$(grep -c '^account_verdict "\$(( WAIT_SECS - waited ))" final$' "$LASTCTL/oversee-succeed")" "1"

new_caller "$MARK"
SUCCEED_BIN="$LASTCTL/oversee-succeed" succeed_shim lastsecondctl 'claude:1:high' --wait-secs 1
check "control: subtracting for it leaves the deciding read nothing, and the caller closes on it" \
  "$RC|$(keyed successor-lane-unobserved "$OUT" | sed -n 1p)|$(caller_open)|$(overseers)" \
  "0|oversee-succeed: successor-lane-unobserved reason=no-settle-budget|no|1"
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
