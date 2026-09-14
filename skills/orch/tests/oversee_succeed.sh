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
{ printf 'lane=%s\n' "\${$lane_var:-}"; printf '%s\n' "\$@"; } > "$TMP_ROOT/argv.$harness"
[ -f "$TMP_ROOT/idle" ] || echo 'esc to interrupt'
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
  ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="$H/.claude:$H/.codex" ORCH_OVERSEER_PREFERENCE="\$pref" \\
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

# Windows past index 0 as `index name;`, whether the caller's window is
# still open, and how many windows are named overseer.
layout() { tm list-windows -t fleet -F '#{window_index} #{window_name}' | awk '$1 > 0' | tr '\n' ';'; }
caller_open() { if [[ "$(tm list-windows -t fleet -F '#{window_id}')" == *"$CALLER_WINDOW"* ]]; then echo yes; else echo no; fi; }
overseers() { tm list-windows -t fleet -F '#{window_name}' | awk '$0 == "overseer"' | wc -l | tr -d ' '; }
recorded() { if [[ -f "$TMP_ROOT/argv.$1" ]]; then tr '\n' ';' < "$TMP_ROOT/argv.$1"; else printf 'none'; fi; }
BRIEF_TAIL='oversee workflow after reading the overseer handoff at tmp/handoffs/OVERSEER-HANDOFF.md'

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
  "3 overseer;|no|oversee-succeed: successor-working window=@N pane=%N;|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;--verbose;/goal Load the orch skill and run the orch $BRIEF_TAIL;"

new_caller "$MARK"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"
run_succeed walled 'claude:1:high,codex:1:high'
check "walled claude entry: codex entry picked" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)|$(recorded codex)" \
  "0|1 overseer;|no|none|lane=$H/.codex;-m;gpt-6-astra;-c;model_reasoning_effort=high;Read .agents/skills/orch/SKILL.md and execute the orch $BRIEF_TAIL;"
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"

new_caller "$MARK"
touch "$TMP_ROOT/idle"
run_succeed idle 'claude:1:high' --wait-secs 2
rm -f "$TMP_ROOT/idle"
check "never working: refused, caller kept, successor closed" \
  "$RC|$(sed -n 1p <<<"$OUT" | sed 's/window=@[0-9]*/window=@N/')|$(caller_open)|$(overseers)" \
  "1|oversee-succeed: successor-not-working window=@N waited=2|yes|0"

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
  "$RC|$(sed -n 1p "$TMP_ROOT/interrupted.out" | sed 's/window=@[0-9]*/window=@N/')|$(caller_open)|$(overseers)" \
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
  "0|1 overseer;|no|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;/goal Load the orch skill and run the orch $BRIEF_TAIL;"

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

new_caller "$NO_WINDOW_1M"
SUCCEED_BIN="$UNPATCHED/oversee-succeed" run_succeed control 'claude:1:high'
check "control: with the window table empty the same screen refuses and launches nothing" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: window-below-mark window=none source=none|0|none"

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
