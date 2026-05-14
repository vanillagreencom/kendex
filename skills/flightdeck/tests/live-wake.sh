#!/usr/bin/env bash
# Flightdeck live wake smoke test.
#
# Full mode spawns a real Pi master in tmux, starts flightdeck-daemon in a
# visible daemon window, rings an inner-pane bell, and verifies the wake arrives
# through pi-bridge as a user message. `--no-tmux` is CI-friendly shape mode:
# it performs syntax/preflight checks but does not spawn tmux, pi, or daemon
# processes.
set -euo pipefail

CYAN='\033[1;36m'; GREEN='\033[1;32m'; RED='\033[1;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
section() { echo; echo -e "${CYAN}══ $* ══${NC}"; }
pass() { echo -e "${GREEN}✓${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }
note() { echo -e "${YELLOW}·${NC} $*"; }
usage() {
  cat <<'USAGE'
Usage: live-wake.sh [--no-tmux] [--use-ts]

Full mode (default):
  Spawn a real Pi master in tmux, run flightdeck-daemon --in-tmux-window,
  ring an inner pane bell, and assert the master receives the wake through
  pi-bridge history.

Shape mode:
  --no-tmux    Validate script paths, GNU bash/date, and bash syntax only.
               Does not require tmux, pi, or a daemon spawn.

TS port mode:
  --use-ts     Run the full live-wake test under the TS daemon trampoline
               (FLIGHTDECK_USE_TS_FLIGHTDECK_DAEMON=1 +
                FLIGHTDECK_USE_TS_DAEMON_START=1). The bash daemon body is
               not exercised. Use this to validate the TS run-loop end-
               to-end before flipping per-script defaults.

Environment overrides:
  FD_LIVE_TMUX_SESSION   tmux session to use (default: current tmux session, or VS)
  PI_BIN                 pi binary path
  PI_BRIDGE_BIN          pi-bridge CLI path
  PI_SESSION_BRIDGE_EXTENSION  Pi session bridge extension path
  FD_STATE_DIR           daemon state directory
USAGE
}

NO_TMUX=0
USE_TS=0
while (($#)); do
  case "$1" in
    --no-tmux) NO_TMUX=1; shift ;;
    --use-ts) USE_TS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

if (( USE_TS )); then
  export FLIGHTDECK_USE_TS_FLIGHTDECK_DAEMON=1
  export FLIGHTDECK_USE_TS_DAEMON_START=1
  command -v bun >/dev/null 2>&1 || fail "--use-ts requires bun on PATH"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
DAEMON="${FLIGHTDECK_DAEMON:-$SKILL_DIR/scripts/flightdeck-daemon}"
PANE_POLL="$SKILL_DIR/scripts/pane-poll"
PANE_REGISTRY="$SKILL_DIR/scripts/pane-registry"
FLIGHTDECK_STATE="$SKILL_DIR/scripts/flightdeck-state"
BRIDGE="${PI_BRIDGE_BIN:-}"
if [[ -z "$BRIDGE" && -x "$REPO_ROOT/pi-extensions/pi-session-bridge/bin/pi-bridge.js" ]]; then
  BRIDGE="$REPO_ROOT/pi-extensions/pi-session-bridge/bin/pi-bridge.js"
fi
if [[ -z "$BRIDGE" ]]; then
  BRIDGE="$HOME/.pi/agent/bin/pi-bridge"
fi
PI_BIN="${PI_BIN:-$(command -v pi || true)}"
PI_EXT="${PI_SESSION_BRIDGE_EXTENSION:-}"
if [[ -z "$PI_EXT" && -f "$REPO_ROOT/pi-extensions/pi-session-bridge/extensions/session-bridge.ts" ]]; then
  PI_EXT="$REPO_ROOT/pi-extensions/pi-session-bridge/extensions/session-bridge.ts"
fi

require_gnu_bash_5() {
  [[ -n "${BASH_VERSION:-}" ]] || fail "must run under bash"
  local major="${BASH_VERSINFO[0]:-0}"
  (( major >= 5 )) || fail "GNU bash 5+ required (found $BASH_VERSION)"
}

require_gnu_date() {
  date --version >/dev/null 2>&1 || fail "GNU date required (date --version failed)"
}

shape_checks() {
  section "shape checks"
  require_gnu_bash_5
  require_gnu_date
  for path in "$DAEMON" "$PANE_POLL" "$PANE_REGISTRY" "$FLIGHTDECK_STATE"; do
    [[ -x "$path" ]] || fail "expected executable script: $path"
    bash -n "$path" || fail "bash syntax failed: $path"
    pass "syntax ok: ${path#$SKILL_DIR/}"
  done
  bash -n "$0" || fail "bash syntax failed: $0"
  pass "live-wake shape ok"
}

if (( NO_TMUX )); then
  shape_checks
  exit 0
fi

require_gnu_bash_5
require_gnu_date
for cmd in git jq tmux; do
  command -v "$cmd" >/dev/null 2>&1 || fail "missing required cmd: $cmd"
done
[[ -x "$DAEMON" ]] || fail "daemon not executable at $DAEMON"
[[ -x "$BRIDGE" ]] || fail "pi-bridge not executable at $BRIDGE"
[[ -x "$PI_BIN" ]] || fail "pi binary not found"

if [[ -n "${FD_LIVE_TMUX_SESSION:-}" ]]; then
  VS_SESSION="$FD_LIVE_TMUX_SESSION"
else
  VS_SESSION="$(tmux display-message -p '#S' 2>/dev/null || true)"
  VS_SESSION="${VS_SESSION:-VS}"
fi
tmux has-session -t "$VS_SESSION" 2>/dev/null || fail "tmux session $VS_SESSION not found"

TMP_DIR=$(mktemp -d /tmp/fdlive-XXXXXX)
MASTER_PANE=""
INNER_PANE=""
DAEMON_WINDOW=""
MASTER_PID=""
SESSION_KEY=""
FD_DIR=""

cleanup_fdlive_windows() {
  tmux list-windows -t "$VS_SESSION" -F '#{window_id} #{window_name}' 2>/dev/null \
    | while read -r wid wname; do
        case "$wname" in
          fdlive-*) tmux kill-window -t "$wid" 2>/dev/null || true ;;
        esac
      done
}

cleanup() {
  set +e
  tmux set-environment -t "$VS_SESSION" -u FD_GRACE_SEC 2>/dev/null
  tmux set-environment -t "$VS_SESSION" -u FD_POLL_SEC 2>/dev/null
  tmux set-environment -t "$VS_SESSION" -u FD_HEARTBEAT_TICKS 2>/dev/null
  tmux set-environment -t "$VS_SESSION" -u FLIGHTDECK_USE_TS_FLIGHTDECK_DAEMON 2>/dev/null
  tmux set-environment -t "$VS_SESSION" -u FLIGHTDECK_USE_TS_DAEMON_START 2>/dev/null
  [[ -n "$MASTER_PANE" ]] && tmux kill-pane -t "$MASTER_PANE" 2>/dev/null
  [[ -n "$INNER_PANE" ]] && tmux kill-pane -t "$INNER_PANE" 2>/dev/null
  [[ -n "$DAEMON_WINDOW" ]] && tmux kill-window -t "$DAEMON_WINDOW" 2>/dev/null
  cleanup_fdlive_windows
  rm -rf "$TMP_DIR" 2>/dev/null
}
trap cleanup EXIT INT TERM

section "setup"
cleanup_fdlive_windows
( cd "$TMP_DIR" && git init -q )
note "tmp project: $TMP_DIR"
MASTER_PANE=$(tmux new-window -t "$VS_SESSION" -n "fdlive-master" -d -P -F '#{pane_id}' -c "$TMP_DIR")
PI_LAUNCH=("$PI_BIN")
if [[ -n "$PI_EXT" && -f "$PI_EXT" ]]; then
  PI_LAUNCH+=("-e" "$PI_EXT")
fi
PI_LAUNCH+=("--model" "openai-codex/gpt-5.5:xhigh")
printf -v PI_CMD '%q ' "${PI_LAUNCH[@]}"
tmux send-keys -t "$MASTER_PANE" "$PI_CMD" Enter
note "master pane: $MASTER_PANE"

section "wait for pi bridge"
deadline=$((SECONDS + 45))
while (( SECONDS < deadline )); do
  OUT=$("$BRIDGE" list --json 2>/dev/null || echo '[]')
  MASTER_PID=$(jq -r --arg cwd "$TMP_DIR" '(. // []) | map(select((.cwd // "") == $cwd)) | sort_by(.startedAt // .started_at // 0) | last | .pid // empty' <<< "$OUT" 2>/dev/null || echo "")
  if [[ "$MASTER_PID" =~ ^[1-9][0-9]*$ ]]; then
    pass "pi bridge registered pid=$MASTER_PID"
    break
  fi
  sleep 0.5
done
[[ "$MASTER_PID" =~ ^[1-9][0-9]*$ ]] || fail "pi bridge did not register for $TMP_DIR"

INNER_PANE=$(tmux new-window -t "$VS_SESSION" -n "fdlive-inner" -d -P -F '#{pane_id}' -c "$TMP_DIR" bash)
note "inner pane: $INNER_PANE"
SESSION_ID=$(tmux display-message -t "$MASTER_PANE" -p '#{session_id}')
SESSION_KEY="s${SESSION_ID#\$}"
FD_DIR="${FD_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/flightdeck}"
[[ -d "$FD_DIR" ]] || FD_DIR="/tmp/flightdeck-$(id -u)"
rm -f "$FD_DIR"/fd-*"$SESSION_KEY"* 2>/dev/null || true

section "pane-poll batch smoke"
if [[ -n "${TMUX:-}" ]]; then
  BATCH_OUT=$(jq -nc --arg pane "$INNER_PANE" '[{issue:"FDLIVE-BATCH",pane_id:$pane,pane_target:"",harness:"bash",worktree:null,pr_number:null}]' \
    | "$PANE_POLL" --batch -)
  jq -e --arg pane "$INNER_PANE" 'select(.issue == "FDLIVE-BATCH" and .pane_target == $pane and ((.dead // false) | not))' \
    <<< "$BATCH_OUT" >/dev/null || fail "pane-poll --batch did not return live inner pane: $BATCH_OUT"
  pass "pane-poll --batch returned live inner pane"
else
  note "TMUX env unavailable; skipping pane-poll --batch smoke"
fi

section "start daemon"
# tmux new-window does not inherit the caller's temporary env assignments;
# seed the session environment before --in-tmux-window spawns the daemon.
tmux set-environment -t "$VS_SESSION" FD_GRACE_SEC 0
tmux set-environment -t "$VS_SESSION" FD_POLL_SEC 1
tmux set-environment -t "$VS_SESSION" FD_HEARTBEAT_TICKS 5
if (( USE_TS )); then
  # Propagate the TS gates into the tmux session env so the daemon
  # child window (spawned by --in-tmux-window via 'tmux new-window')
  # inherits them. Without this the trampoline inside the daemon
  # window falls back to the bash body.
  tmux set-environment -t "$VS_SESSION" FLIGHTDECK_USE_TS_FLIGHTDECK_DAEMON 1
  tmux set-environment -t "$VS_SESSION" FLIGHTDECK_USE_TS_DAEMON_START 1
  note "running daemon under TS trampoline (FLIGHTDECK_USE_TS_DAEMON_START=1)"
fi
"$DAEMON" start \
  --session "$SESSION_ID" \
  --master "$MASTER_PANE" \
  --master-harness pi \
  --inner "$INNER_PANE" \
  --inner-harnesses bash \
  --in-tmux-window
DAEMON_WINDOW="$VS_SESSION:[fd] daemon-$SESSION_KEY"
if (( USE_TS )); then
  pass "TS daemon started for $SESSION_KEY"
else
  pass "daemon started for $SESSION_KEY"
fi

section "ring inner bell"
tmux send-keys -t "$INNER_PANE" "printf '\\a'; echo fdlive-bell" Enter

section "wait for bridge wake"
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
  HIST=$("$BRIDGE" history --pid "$MASTER_PID" 200 2>/dev/null || echo "")
  if grep -qE '/flightdeck watch --from-daemon|/skill:flightdeck watch --from-daemon' <<< "$HIST"; then
    pass "wake delivered through pi-bridge history"
    LOG_PATH="$FD_DIR/fd-daemon-${SESSION_KEY}.log"
    [[ -f "$LOG_PATH" ]] || fail "daemon log missing: $LOG_PATH"
    note "daemon wake log:"
    grep 'harness=pi via=pi-bridge' "$LOG_PATH" | tail -n 3 | sed 's/^/    /' || true
    grep -q 'harness=pi via=pi-bridge' "$LOG_PATH" || fail "daemon log missing pi-bridge wake channel"
    pass "daemon log shows harness=pi via=pi-bridge"
    exit 0
  fi
  sleep 1
done

LOG_PATH="$FD_DIR/fd-daemon-${SESSION_KEY}.log"
[[ -f "$LOG_PATH" ]] && { note "daemon log tail:"; tail -n 80 "$LOG_PATH" | sed 's/^/    /'; }
fail "wake did not appear in pi-bridge history"
