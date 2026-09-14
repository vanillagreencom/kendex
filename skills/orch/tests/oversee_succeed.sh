#!/usr/bin/env bash
# Tests for scripts/oversee-succeed over a real tmux server on a private
# socket. The caller is a pane whose screen carries a claude status line;
# claude, codex and kendex are stubs on PATH, and `lanes pick` answers from
# the lanes-fixture usage bodies. The harness stubs record their lane and argv
# and print the interrupt hint a running turn draws.
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
TMUX_ADDR="$(tm display-message -p '#{socket_path},#{pid},0')"

MARK='  kendex (ken-1453) Fable 5.1 (1M context) 52% (fixture@example.com)     /rc'
NO_WINDOW='  kendex (ken-1453) Opus 5 41% (fixture@example.com)     /rc'

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

# run_succeed ROW PREFERENCE ARGS... — sets OUT (both streams) and RC.
run_succeed() {
  local row="$1" pref="$2"
  shift 2
  rm -f "$TMP_ROOT"/argv.*
  RC=0
  OUT="$(cd "$TMP_ROOT/work" && env -i HOME="$H" PATH="$BIN:$PATH" \
    TMUX="$TMUX_ADDR" TMUX_PANE="$CALLER_PANE" LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" \
    OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state-$row" ORCH_LANES_FETCH_CMD="$FETCHER" \
    ORCH_LANE_DIRS="$H/.claude:$H/.codex" ORCH_OVERSEER_PREFERENCE="$pref" \
    "$SUCCEED" "$@" 2>&1)" || RC=$?
}

# Windows past index 0 as `index name;`, whether the caller's window is
# still open, and how many windows are named overseer.
layout() { tm list-windows -t fleet -F '#{window_index} #{window_name}' | awk '$1 > 0' | tr '\n' ';'; }
caller_open() { if [[ "$(tm list-windows -t fleet -F '#{window_id}')" == *"$CALLER_WINDOW"* ]]; then echo yes; else echo no; fi; }
overseers() { tm list-windows -t fleet -F '#{window_name}' | awk '$0 == "overseer"' | wc -l | tr -d ' '; }
recorded() { if [[ -f "$TMP_ROOT/argv.$1" ]]; then tr '\n' ';' < "$TMP_ROOT/argv.$1"; else printf 'none'; fi; }
BRIEF_TAIL='oversee workflow after reading the overseer handoff at tmp/handoffs/OVERSEER-HANDOFF.md'

echo "=== oversee-succeed ==="

new_caller "$MARK"
run_succeed success 'claude:1:high' -- --dangerously-skip-permissions
check "success: successor at index 1, caller window gone" \
  "$RC|$(layout)|$(caller_open)|$(recorded claude)" \
  "0|1 overseer;|no|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;--dangerously-skip-permissions;/goal Load the orch skill and run the orch $BRIEF_TAIL;"

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

new_caller "$NO_WINDOW"
run_succeed below 'claude:1:high'
check "no 1M window: window-below-mark, nothing launched" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded claude)" \
  "0|oversee-succeed: window-below-mark window=none|0|none"

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
