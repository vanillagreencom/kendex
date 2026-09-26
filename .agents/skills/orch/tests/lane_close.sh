#!/usr/bin/env bash
# lane-close resolves one recorded pane, refuses live lanes, and closes in order.
# One must-fail control closes the file: lane-close is one script, one surface.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/process-table.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$TEST_DIR" rev-parse --show-toplevel)"
mkdir -p "$PROJECT_ROOT/tmp"
TMP_ROOT="$(mktemp -d "$PROJECT_ROOT/tmp/lane-close.XXXXXX")"
LANE_PIDS=""
cleanup() {
  local pid
  for pid in $LANE_PIDS; do kill -KILL "$pid" 2>/dev/null || true; done
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
PASS=0
FAIL=0

ok() { printf 'ok: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL: %s\n  %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
assert_eq() { [[ "$1" == "$2" ]] && ok "$3" || bad "$3" "expected: $2 | got: $1"; }
host_call_count() { awk 'END { print NR + 0 }' "$HOST_CALLS"; }
close_call_count() { grep -c '^close ' "$HOST_CALLS" || true; }
# The provider stop calls that name this harness, and the pane-writing tmux
# verbs the close made. The stub fails every one of those verbs, so any count
# above zero is a close that typed into a lane.
stop_count() { grep -c -- "^stop --item $1 --harness $2 host=" "$HOST_CALLS" || true; }
typed_count() { grep -cE '^(load-buffer|paste-buffer|send-keys) ' "$CALLS" || true; }
state_call_count() { awk -v p="$1" 'index($0, p) == 1 { c++ } END { print c + 0 }' "$STATE_CALLS"; }

# The screens a lane is read from. Claude Code draws its composer as the
# marker then U+00A0, draft or not; Codex's empty composer is the byte-exact
# capture the watch suites already measure.
CLAUDE_COMPOSER=$'\xe2\x9d\xaf\xc2\xa0'
PANE_FIXTURES="$TEST_DIR/fixtures/oversee-watch"

FIXTURE="$TMP_ROOT/repo"
SCRIPTS="$FIXTURE/skills/orch/scripts"
BIN="$TMP_ROOT/bin"
STATE="$TMP_ROOT/state.json"
ROWS="$TMP_ROOT/rows"
SCREEN="$TMP_ROOT/screen"
PHASE="$TMP_ROOT/phase"
CALLS="$TMP_ROOT/calls"
HOST_CALLS="$TMP_ROOT/host-calls"
GH_CALLS="$TMP_ROOT/gh-calls"
STATE_CALLS="$TMP_ROOT/state-calls"
MAIL_CALLS="$TMP_ROOT/mail-calls"
# The fleet state directory the watch passes every close. It exists because a
# real one does; this stub reads the state file it is handed either way.
FLEET_DIR="$TMP_ROOT/fleet-state"
mkdir -p "$FLEET_DIR"
mkdir -p "$SCRIPTS/lib" "$FIXTURE/skills/linear/scripts" "$BIN"
cp "$TEST_DIR/../scripts/lane-close" "$SCRIPTS/lane-close"
cp "$TEST_DIR/../scripts/lib/lane-state.sh" "$SCRIPTS/lib/lane-state.sh"
chmod +x "$SCRIPTS/lane-close"

cat >"$SCRIPTS/workflow-state" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$LANE_CLOSE_STATE_CALLS"
if [[ "${1:-}" == --state-dir ]]; then shift 2; fi
verb="$1"; shift
[[ "$1" == oversee ]]; shift
case "$verb" in
  get) jq "$1" "$LANE_CLOSE_STATE" ;;
  update)
    [[ "${LANE_CLOSE_STATE_WRITE_FAIL:-0}" == 0 ]] || exit "$LANE_CLOSE_STATE_WRITE_FAIL"
    args=()
    while [[ "${1:-}" == --arg ]]; do args+=(--arg "$2" "$3"); shift 3; done
    expr="$1"
    jq "${args[@]}" "$expr" "$LANE_CLOSE_STATE" >"$LANE_CLOSE_STATE.next"
    mv -- "$LANE_CLOSE_STATE.next" "$LANE_CLOSE_STATE" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$SCRIPTS/workflow-state"

cat >"$SCRIPTS/lane-host" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$* host=$ORCH_LANE_HOST" >>"$LANE_CLOSE_HOST_CALLS"
# stop is the provider signalling the lane's harness on its host: the harness
# ends, and the pane falls back to the bare shell its window keeps, which the
# lane judge reads as exited. LANE_CLOSE_NO_EXIT is a harness that outlives the
# signal, LANE_CLOSE_STOP_STATUS a stop that fails, 4 being the protocol's
# answer for an item whose worktree is gone, LANE_CLOSE_STOP_SANDBOX a 4 that
# is instead a provider's own lane-stopped answer for a sandbox in that state,
# and LANE_CLOSE_STOP_OUT the answer it prints in place of the protocol's line.
if [[ "$1" == stop ]]; then
  case "${LANE_CLOSE_STOP_STATUS:-0}" in
    0) ;;
    4)
      if [[ -n "${LANE_CLOSE_STOP_SANDBOX:-}" ]]; then
        printf 'lane-stopped item=%s state=%s verb=stop\n' "$3" "$LANE_CLOSE_STOP_SANDBOX" >&2
      else
        printf 'lane-host-ssh: stop-worktree-removed item=%s\n' "$3" >&2
      fi
      exit 4 ;;
    *) printf 'lane-host-ssh: stop-timeout item=%s\n' "$3" >&2; exit "$LANE_CLOSE_STOP_STATUS" ;;
  esac
  if [[ "${LANE_CLOSE_NO_EXIT:-0}" != 1 ]]; then
    printf 'exited\n' >"$LANE_CLOSE_PHASE"
    awk -F'\t' 'BEGIN { OFS = "\t" } { $5 = "bash"; print }' "$LANE_CLOSE_ROWS" >"$LANE_CLOSE_ROWS.next"
    mv -- "$LANE_CLOSE_ROWS.next" "$LANE_CLOSE_ROWS"
  fi
  printf '%s\n' "${LANE_CLOSE_STOP_OUT-stopped item=$3 processes=1}"
  exit 0
fi
if [[ "${LANE_CLOSE_HOST_STATUS:-0}" -ne 0 ]]; then
  [[ "$LANE_CLOSE_HOST_STATUS" -ne 3 ]] || printf 'lane-host-ssh: close-refused path=/srv/clone\n' >&2
  exit "$LANE_CLOSE_HOST_STATUS"
fi
printf 'kept=/fleet/archive/item.tgz\n'
EOF
chmod +x "$SCRIPTS/lane-host"

cat >"$SCRIPTS/lane-mail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s host=%s\n' "$*" "${ORCH_LANE_HOST-unset}" >>"$LANE_CLOSE_MAIL_CALLS"
if [[ "${LANE_CLOSE_MAIL_STATUS:-0}" -ne 0 ]]; then
  printf 'lane-mail: mail-read-failed=%s\n' "${5-}" >&2
  exit "$LANE_CLOSE_MAIL_STATUS"
fi
[[ -z "${LANE_CLOSE_MAIL_PENDING:-}" ]] || printf '%s\n' "$LANE_CLOSE_MAIL_PENDING"
EOF
chmod +x "$SCRIPTS/lane-mail"

# One unanswered ask, minted the way lane-mail mints one: the id opens with the
# epoch second the ask was made, which is where lane-close reads the wait from.
pending_ask() { # AGE_SECONDS
  local now
  now="$(date -u +%s)"
  printf '{"id":"%s-9-31","kind":"ask","at":"2026-09-21T05:45:00Z","from":"KEN-1","text":"which base"}' \
    "$((now - $1))"
}

# dev-validate-run records each --stop. The records' /srv/worktree is no
# directory here, so only a row that points mail_root at one reaches it.
export LANE_CLOSE_VALIDATE_CALLS="$TMP_ROOT/validate-calls"
cat >"$SCRIPTS/dev-validate-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LANE_CLOSE_VALIDATE_CALLS"
[[ "${LANE_CLOSE_VALIDATE_STATUS:-0}" -eq 0 ]] || { printf 'dev-validate-run: stop-failed step=kill\n' >&2; exit "$LANE_CLOSE_VALIDATE_STATUS"; }
printf 'state=stopped units=0 groups=0\n'
EOF
chmod +x "$SCRIPTS/dev-validate-run"

cat >"$FIXTURE/skills/linear/scripts/linear.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${LANE_CLOSE_TRACKER_FAIL:-0}" != 0 ]]; then
  printf 'linear.sh: api-unreachable\n' >&2
  exit "$LANE_CLOSE_TRACKER_FAIL"
fi
printf '{"state":"%s","state_type":"%s"}\n' \
  "${LANE_CLOSE_TRACKER_STATE:-Done}" "${LANE_CLOSE_TRACKER_STATE_TYPE-completed}"
EOF
chmod +x "$FIXTURE/skills/linear/scripts/linear.sh"

cat >"$BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN/pgrep"

cat >"$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$LANE_CLOSE_TMUX_CALLS"
# A local lane's harness leaving its pane once its process has gone: the
# screen goes blank and the pane process falls back to the bare shell the
# window keeps, which is what the lane judge reads as exited. A zombie is gone.
# The state is read from /proc, never through ps, which the local rows stub.
harness_gone() {
  local state
  [[ -n "${LANE_CLOSE_LANE_PID:-}" ]] || return 1
  source "$LANE_CLOSE_STATE_LIB"
  state="$(lane_process_state "$LANE_CLOSE_LANE_PID")"
  [[ -z "$state" || "$state" == Z ]]
}
if [[ "$(cat "$LANE_CLOSE_PHASE")" != exited ]] && harness_gone; then
  printf 'exited\n' >"$LANE_CLOSE_PHASE"
  awk -F'\t' 'BEGIN { OFS = "\t" } { $5 = "bash"; print }' "$LANE_CLOSE_ROWS" >"$LANE_CLOSE_ROWS.next"
  mv -- "$LANE_CLOSE_ROWS.next" "$LANE_CLOSE_ROWS"
fi
case "$1" in
  list-panes)
    count=$(cat "$LANE_CLOSE_TMUX_LIST_COUNT" 2>/dev/null || echo 0)
    count=$((count + 1)); printf '%s\n' "$count" >"$LANE_CLOSE_TMUX_LIST_COUNT"
    [[ "${LANE_CLOSE_TMUX_LIST_FAIL_AT:-0}" != "$count" ]] || exit 9
    if [[ "${*: -1}" == '#{pane_id}' ]]; then
      awk -F'\t' '{print $3}' "$LANE_CLOSE_ROWS"
    elif [[ "${*: -1}" == '#{pane_id}'$'\t''#{pane_pid}'$'\t''#{pane_current_command}' ]]; then
      awk -F'\t' '{print $3 "\t" $4 "\t" $5}' "$LANE_CLOSE_ROWS"
    else
      cat -- "$LANE_CLOSE_ROWS"
    fi ;;
  capture-pane)
    count=$(cat "$LANE_CLOSE_CAPTURE_COUNT" 2>/dev/null || echo 0)
    count=$((count + 1)); printf '%s\n' "$count" >"$LANE_CLOSE_CAPTURE_COUNT"
    [[ "${LANE_CLOSE_CAPTURE_FAIL_AT:-0}" != "$count" ]] || exit 9
    [[ "${LANE_CLOSE_CAPTURE_FAIL:-0}" == 0 ]] || exit "$LANE_CLOSE_CAPTURE_FAIL"
    case "$(cat "$LANE_CLOSE_PHASE")" in
      exited) printf '\n' ;;
      *) cat -- "$LANE_CLOSE_SCREEN" ;;
    esac ;;
  # Every verb that writes into a pane fails, logged first, so a close that
  # types anything is both a refusal and a line in the call log.
  load-buffer|paste-buffer|send-keys) exit 97 ;;
  kill-window) : >"$LANE_CLOSE_ROWS" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$BIN/tmux"

cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LANE_CLOSE_GH_CALLS"
if [[ "${LANE_CLOSE_TRACKER_FAIL:-0}" != 0 ]]; then
  printf 'gh: HTTP 401: Bad credentials\n' >&2
  exit "$LANE_CLOSE_TRACKER_FAIL"
fi
printf '%s\n' "${LANE_CLOSE_GITHUB_STATE:-CLOSED}"
EOF
chmod +x "$BIN/gh"

# MAIL_ROOT is the lane's worktree as the record names it: a path on the host
# for a hosted lane, and for a local lane the directory its harness runs in.
MAIL_ROOT=/srv/worktree
write_state() { # STATUS HARNESS HOST [TRACKER] [REPO] [WINDOW]
  jq -n --arg status "$1" --arg harness "$2" --arg host "$3" \
    --arg tracker "${4:-linear}" --arg repo "${5:-}" --arg window "${6:-KEN-1}" --arg root "$MAIL_ROOT" \
    '{lanes:[{item:(if $tracker == "github" then "issue-1" else "KEN-1" end),tracker:$tracker,repo:(if $repo == "" then null else $repo end),harness:$harness,window:$window,account:"/lane",host:(if $host == "" then null else $host end),mail_root:$root,surface:"tmux",model:"model",session_id:null,launched_at:"2026-09-20T00:00:00Z",status:$status}]}' >"$STATE"
}

# A record as the launcher wrote it before it recorded the lane's tracker,
# repository and harness: those three keys are absent, not null.
write_legacy_state() { # STATUS HOST [ITEM]
  jq -n --arg status "$1" --arg host "$2" --arg item "${3:-KEN-1}" \
    '{lanes:[{item:$item,window:"KEN-1",account:"/lane",host:(if $host == "" then null else $host end),mail_root:"/srv/worktree",surface:"tmux",model:"model",session_id:null,launched_at:"2026-09-20T00:00:00Z",status:$status}]}' >"$STATE"
}

# tmux's own `list-panes -a` columns for the format the shared resolver asks
# for: the pane's session name, its window name, then the pane itself.
write_panes() { # COMMAND [DUPLICATE] [SESSION]
  local session="${3:-kendex}"
  printf '%s\tKEN-1\t%%7\t999\t%s\n' "$session" "$1" >"$ROWS"
  if [[ "${2:-}" == duplicate ]]; then printf '%s\tKEN-1\t%%8\t998\t%s\n' "$session" "$1" >>"$ROWS"; fi
}

# The lane's screen. `claude_screen [TEXT]` draws Claude Code's composer with
# TEXT after the marker: nothing, or a draft nobody sent. `codex_screen` is the
# measured Codex capture.
claude_screen() { printf '%s%s\n' "$CLAUDE_COMPOSER" "${1:-}" >"$SCREEN"; }
codex_screen() { cp -- "$PANE_FIXTURES/codex-composer-idle.txt" "$SCREEN"; }

# A local lane's harness: a real process, so the SIGTERM and its exit are
# real, started detached so init reaps it rather than this shell holding it as
# a zombie. LANE_PID is its pid, which the tmux stub reads as
# LANE_CLOSE_LANE_PID. What the ownership read sees is staged, not the host's:
# the shared stub pair (lib/process-table.sh) on LOCAL_PATH answers `ps` with a
# table holding that one pid under the harness name and `readlink` with the
# lane's worktree as its directory, so another user's session on this box is
# never read and the read never races the child's exec. The tmux stub reads its
# state from /proc and proc_state_after its exit, so these rows run where
# proc_table_readable holds.
LANE_ROOT="$TMP_ROOT/lane-worktree"
HARNESS_BIN="$TMP_ROOT/harness-bin"
PROC_BIN="$TMP_ROOT/proc-bin"
mkdir -p "$LANE_ROOT" "$HARNESS_BIN"
LANE_ROOT_REAL="$(cd -- "$LANE_ROOT" && pwd -P)"
PROC_TABLE="$TMP_ROOT/proc-table"
PROC_CWD_FILE="$TMP_ROOT/proc-cwd"
export PROC_TABLE PROC_CWD_FILE
LANE_CLOSE_STATE_LIB="$SCRIPTS/lib/lane-state.sh"
export LANE_CLOSE_STATE_LIB
proc_table_install "$PROC_BIN"
LOCAL_PATH="$PROC_BIN:$PATH"
LANE_PID=""
start_local_harness() { # HARNESS
  [[ -x "$HARNESS_BIN/$1" ]] || cp -- "$(command -v bash)" "$HARNESS_BIN/$1"
  LANE_PID="$( (cd -- "$LANE_ROOT" && exec "$HARNESS_BIN/$1" -c 'trap "exit 0" TERM; while :; do sleep 0.1; done' \
    </dev/null >/dev/null 2>&1 & printf '%s' "$!") )"
  LANE_PIDS+=" $LANE_PID"
  proc_table_write "$PROC_TABLE" "$LANE_PID 1 $1"
  proc_cwd_write "$PROC_CWD_FILE" "$LANE_PID=$LANE_ROOT_REAL"
}

run_close() { # SCRIPT [ARGS...]
  local script="$1"
  shift
  : >"$CALLS"; : >"$HOST_CALLS"; : >"$GH_CALLS"; : >"$STATE_CALLS"; : >"$MAIL_CALLS"; : >"$PHASE"; : >"$TMP_ROOT/list-count"; : >"$TMP_ROOT/capture-count"
  set +e
  OUT="$(PATH="$BIN:$PATH" LANE_CLOSE_STATE="$STATE" LANE_CLOSE_ROWS="$ROWS" \
    LANE_CLOSE_SCREEN="$SCREEN" LANE_CLOSE_PHASE="$PHASE" \
    LANE_CLOSE_TMUX_LIST_COUNT="$TMP_ROOT/list-count" LANE_CLOSE_CAPTURE_COUNT="$TMP_ROOT/capture-count" \
    LANE_CLOSE_TMUX_CALLS="$CALLS" LANE_CLOSE_HOST_CALLS="$HOST_CALLS" LANE_CLOSE_GH_CALLS="$GH_CALLS" \
    LANE_CLOSE_STATE_CALLS="$STATE_CALLS" LANE_CLOSE_MAIL_CALLS="$MAIL_CALLS" \
    LANE_CLOSE_LANE_PID="${LANE_CLOSE_LANE_PID:-}" ORCH_LANE_CLOSE_SECS=1 \
    "$script" "$@" "$(jq -r '.lanes[0].item' "$STATE")" 2>"$TMP_ROOT/err")"
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/err")"
}

mutant() { # NAME OLD NEW
  local name="$1" old="$2" new="$3" path
  path="$SCRIPTS/$name"
  python3 - "$SCRIPT" "$path" "$old" "$new" <<'PY'
import pathlib, sys
source, target, old, new = sys.argv[1:]
text = pathlib.Path(source).read_text()
if text.count(old) != 1:
    raise SystemExit(f"mutation match count={text.count(old)} old={old!r}")
changed = text.replace(old, new)
if changed == text:
    raise SystemExit("mutation did not change the script")
pathlib.Path(target).write_text(changed)
PY
  chmod +x "$path"
  printf '%s\n' "$path"
}

SCRIPT="$SCRIPTS/lane-close"

# What lives in lib/lane-state.sh takes a fixture tree of its own: links to
# the same lane-close and stubs over one changed library copy. OLD is replaced
# by NEW where OLD is given, and APPEND, where given, is added at the end,
# where it redefines a function the library defined above it.
lib_mutant() { # NAME OLD NEW [APPEND]
  local name="$1" old="$2" new="$3" dir sibling
  dir="$TMP_ROOT/libmut-$name"
  mkdir -p "$dir/skills/orch/scripts/lib" "$dir/skills/linear/scripts"
  for sibling in lane-close workflow-state lane-host lane-mail dev-validate-run; do
    ln -s "$SCRIPTS/$sibling" "$dir/skills/orch/scripts/$sibling"
  done
  ln -s "$FIXTURE/skills/linear/scripts/linear.sh" "$dir/skills/linear/scripts/linear.sh"
  python3 - "$SCRIPTS/lib/lane-state.sh" "$dir/skills/orch/scripts/lib/lane-state.sh" "$old" "$new" "${4:-}" <<'MUTPY'
import pathlib, sys
source, target, old, new, append = sys.argv[1:]
text = pathlib.Path(source).read_text()
if old:
    if text.count(old) != 1:
        raise SystemExit(f"mutation match count={text.count(old)} old={old!r}")
    text = text.replace(old, new)
if append:
    text += "\n" + append + "\n"
pathlib.Path(target).write_text(text)
MUTPY
  printf '%s\n' "$dir/skills/orch/scripts/lane-close"
}

# A host without /proc, macOS among them, reads a process's directory through
# lsof. NOPROC is lane-close over a library that says this host has no /proc,
# and the lsof on NOPROC_PATH answers as lsof does, from the directory the
# staged readlink holds, so the local rows run under both readers.
NO_PROC='lane_proc_readable() { return 1; }'
NOPROC="$(lib_mutant no-proc '' '' "$NO_PROC")"
if proc_table_readable; then
  mkdir -p "$TMP_ROOT/lsof-bin"
  cat >"$TMP_ROOT/lsof-bin/lsof" <<'EOF'
#!/usr/bin/env bash
pid=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -p ]]; then pid="$2"; shift; fi
  shift
done
cwd="$(readlink -- "/proc/$pid/cwd" 2>/dev/null)" || exit 1
printf 'p%s\nfcwd\nn%s\n' "$pid" "$cwd"
EOF
  chmod +x "$TMP_ROOT/lsof-bin/lsof"
  NOPROC_PATH="$TMP_ROOT/lsof-bin:$LOCAL_PATH"
fi

echo '=== lane-close refuses ambiguous and live panes ==='
write_state running claude /host
write_panes bash duplicate
printf '\n' >"$SCREEN"
run_close "$SCRIPT"
assert_eq "rc=$RC ambiguous=$(grep -c '^lane-close: pane-ambiguous ' <<<"$ERR" || true) host=$(host_call_count) kills=$(grep -c '^kill-window ' "$CALLS" || true)" \
  'rc=1 ambiguous=1 host=0 kills=0' 'two panes sharing the recorded name refuse before sandbox or window close'

write_state running codex /host
write_panes python
printf '› run\n  press to interrupt\n' >"$SCREEN"
run_close "$SCRIPT"
assert_eq "rc=$RC live=$(grep -c '^lane-close: lane-live item=KEN-1 state=working pane=%7$' <<<"$ERR" || true) host=$(host_call_count) kills=$(grep -c '^kill-window ' "$CALLS" || true)" \
  'rc=1 live=1 host=0 kills=0' 'a working pane refuses before sandbox or window close'

echo '=== a finished hosted lane closes in one call ==='
write_state running pi /host
write_panes bash
printf '\n' >"$SCREEN"
run_close "$SCRIPT"
assert_eq "rc=$RC host=$(host_call_count) kill=$(grep -c '^kill-window -t %7$' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE") kept=$(grep -c '^kept=' <<<"$OUT" || true)" \
  'rc=0 host=1 kill=1 status=done kept=1' 'an exited hosted Pi lane closes the provider once, kills by pane id and records done'

echo '=== a local lane ends the validations its worktree still runs ==='
validate_calls() { awk 'END { print NR + 0 }' "$LANE_CLOSE_VALIDATE_CALLS"; }
LANE_WORKTREE="$TMP_ROOT/worktrees/ken-1"
mkdir -p "$LANE_WORKTREE"
# A record whose mail_root is the lane worktree on this disk, as open-terminal
# writes a local lane's.
lane_state() { # HOST
  write_state running pi "$1"; write_panes bash; printf '\n' >"$SCREEN"; : >"$LANE_CLOSE_VALIDATE_CALLS"
  jq --arg root "$LANE_WORKTREE" '.lanes[0].mail_root = $root' "$STATE" >"$STATE.next" && mv -- "$STATE.next" "$STATE"
}
# label|record host|validate-run status|expected
STOP_ROWS=(
  "an exited local lane stops its worktree's runs, then closes|-|0|rc=0 calls=1 stop=1 kill=1 status=done"
  "a stop that fails refuses before the window or the record changes|-|1|rc=1 calls=1 stop=1 kill=0 status=running refused=1 relayed=1"
  "a hosted lane stops nothing here: its runs end with its sandbox|/host|0|rc=0 calls=0 stop=0 kill=1 status=done"
)
for row in "${STOP_ROWS[@]}"; do
  IFS='|' read -r label record_host validate_status want <<<"$row"
  [[ "$record_host" != - ]] || record_host=""
  lane_state "$record_host"
  LANE_CLOSE_VALIDATE_STATUS="$validate_status" run_close "$SCRIPT"
  got="rc=$RC calls=$(validate_calls) stop=$(grep -c -x -- "--stop --worktree $LANE_WORKTREE" "$LANE_CLOSE_VALIDATE_CALLS" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")"
  [[ "$validate_status" -eq 0 ]] \
    || got+=" refused=$(grep -c -x "lane-close: validate-stop-failed item=KEN-1 worktree=$LANE_WORKTREE status=1" <<<"$ERR" || true) relayed=$(grep -c -x 'dev-validate-run: stop-failed step=kill' <<<"$ERR" || true)"
  assert_eq "$got" "$want" "$label"
done
write_state running pi ""; write_panes bash; printf '\n' >"$SCREEN"; : >"$LANE_CLOSE_VALIDATE_CALLS"
run_close "$SCRIPT"
assert_eq "rc=$RC calls=$(validate_calls) status=$(jq -r '.lanes[0].status' "$STATE")" 'rc=0 calls=0 status=done' \
  'a local lane whose mail_root is no directory on this disk stops nothing and closes'
mv -- "$SCRIPTS/dev-validate-run" "$SCRIPTS/dev-validate-run.off"
lane_state ""
run_close "$SCRIPT"
assert_eq "rc=$RC missing=$(grep -c -x "lane-close: helper-missing item=KEN-1 path=$SCRIPTS/dev-validate-run" <<<"$ERR" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 missing=1 kill=0 status=running' 'a missing dev-validate-run refuses naming its path, before the window or record changes'
mv -- "$SCRIPTS/dev-validate-run.off" "$SCRIPTS/dev-validate-run"

echo '=== a provider refusal stays unchanged and preserves the window ==='
write_state running claude /host
write_panes bash
printf '\n' >"$SCREEN"
LANE_CLOSE_HOST_STATUS=3 run_close "$SCRIPT"
assert_eq "rc=$RC refusal=$(grep -c '^lane-host-ssh: close-refused path=/srv/clone$' <<<"$ERR" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=3 refusal=1 kill=0 status=running' 'lane-host exit 3 reaches the caller unchanged and kills nothing'

echo '=== an idle harness ends by signal, nothing typed into its pane ==='
# HARNESS|DRAFT: a draft in the composer no longer stands in the way, since
# nothing is typed for it to be sent with.
for row in 'claude|' 'codex|' 'pi|' 'claude|finish this later'; do
  IFS='|' read -r harness draft <<<"$row"
  write_state running "$harness" /host
  write_panes python
  if [[ "$harness" == codex ]]; then codex_screen; else claude_screen "$draft"; fi
  run_close "$SCRIPT"
  assert_eq "rc=$RC stop=$(stop_count KEN-1 "$harness") typed=$(typed_count) kill=$(grep -c '^kill-window -t %7$' "$CALLS" || true) close=$(close_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=0 stop=1 typed=0 kill=1 close=1 status=done' "a hosted $harness lane${draft:+ whose composer holds a draft} is stopped by its provider, then closed"
done

# A local lane: the same stop, run here against the worktree its record names,
# ends the harness process itself, under both directory readers.
if proc_table_readable; then
  for reader_row in "proc|$SCRIPT|$LOCAL_PATH" "lsof|$NOPROC|$NOPROC_PATH"; do
    IFS='|' read -r reader reader_script reader_path <<<"$reader_row"
    for harness in claude codex pi; do
      MAIL_ROOT="$LANE_ROOT" write_state running "$harness" ""
      write_panes python; claude_screen
      start_local_harness "$harness"
      PATH="$reader_path" LANE_CLOSE_LANE_PID="$LANE_PID" run_close "$reader_script"
      assert_eq "rc=$RC lane=$(proc_state_after "$LANE_PID") typed=$(typed_count) host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
        'rc=0 lane=gone typed=0 host=0 status=done' "a local $harness lane is stopped by SIGTERM to its own process, its directory read through $reader"
    done
  done

  # A host with no directory reader at all refuses under its own cause, never
  # as a failed process read.
  MAIL_ROOT="$LANE_ROOT" write_state running claude ""; write_panes python; claude_screen
  start_local_harness claude
  MUTANT="$(lib_mutant reader-missing '' '' 'lane_process_cwd() { return 3; }')"
  PATH="$LOCAL_PATH" LANE_CLOSE_LANE_PID="$LANE_PID" run_close "$MUTANT"
  assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=claude cause=cwd-reader-missing$' <<<"$ERR" || true) lane=$(proc_state_after "$LANE_PID") status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=1 failed=1 lane=alive status=running' 'a host with neither /proc nor lsof refuses the local stop as cwd-reader-missing'
  kill -KILL "$LANE_PID" 2>/dev/null || true

  # A local stop that fails on one process names it: a signal refused to a
  # harness that is still live.
  MAIL_ROOT="$LANE_ROOT" write_state running claude ""; write_panes python; claude_screen
  start_local_harness claude
  MUTANT="$(lib_mutant signal-refused '' '' 'kill() { return 1; }')"
  PATH="$LOCAL_PATH" LANE_CLOSE_LANE_PID="$LANE_PID" run_close "$MUTANT"
  assert_eq "rc=$RC failed=$(grep -c "^lane-close: stop-failed item=KEN-1 harness=claude pid=$LANE_PID cause=signal-refused\$" <<<"$ERR" || true) lane=$(proc_state_after "$LANE_PID") status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=1 failed=1 lane=alive status=running' 'a local stop refused on one process names that process'
  kill -KILL "$LANE_PID" 2>/dev/null || true
else
  printf '  skip  the local lane rows stage their process read through procfs\n'
fi

# A local stop that cannot run refuses, naming the step, rather than waiting
# the lane out: a record whose worktree is not on this machine resolves none.
write_state running claude ""; write_panes python; claude_screen
run_close "$SCRIPT"
assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=claude cause=worktree-read-failed$' <<<"$ERR" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 failed=1 kill=0 status=running' 'a local stop that cannot resolve the worktree refuses and keeps the window'

echo '=== a failed stop keeps the lane and its record ==='
write_state running codex /host; write_panes python; codex_screen
LANE_CLOSE_STOP_STATUS=1 run_close "$SCRIPT"
assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=codex cause=provider status=1$' <<<"$ERR" || true) relay=$(grep -c '^lane-host-ssh: stop-timeout item=KEN-1$' <<<"$ERR" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) close=$(close_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 failed=1 relay=1 kill=0 close=0 status=running' 'a provider stop that fails refuses, relaying its words, and closes nothing'

write_state running codex /host; write_panes python; codex_screen
LANE_CLOSE_STOP_OUT='' run_close "$SCRIPT"
assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=codex cause=answer-unparsed$' <<<"$ERR" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 failed=1 kill=0 status=running' 'a provider stop that prints no stopped line refuses as unparsed'

echo '=== a finished hosted lane whose worktree is gone closes without a stop ==='
# The provider's removed-worktree answer signals nothing, so the harness still
# runs and the pane never reads exited: the host close and the window kill are
# what end it. On a nonterminal item the stop is never reached, and under
# --keep-sandbox nothing would end the harness, so both refuse.
write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_STOP_STATUS=4 run_close "$SCRIPT"
assert_eq "rc=$RC skipped=$(grep -c '^lane-close: stop-skipped item=KEN-1 harness=claude cause=worktree-removed$' <<<"$OUT" || true) stop=$(stop_count KEN-1 claude) close=$(close_call_count) kill=$(grep -c '^kill-window -t %7$' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 skipped=1 stop=1 close=1 kill=1 status=done' 'a terminal idle lane whose worktree is gone skips the stop, closes the host and window and records done'
write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_STOP_STATUS=4 LANE_CLOSE_TRACKER_STATE=Todo LANE_CLOSE_TRACKER_STATE_TYPE=unstarted run_close "$SCRIPT"
assert_eq "rc=$RC live=$(grep -c '^lane-close: lane-live item=KEN-1 state=idle pane=%7$' <<<"$ERR" || true) stop=$(stop_count KEN-1 claude) close=$(close_call_count) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 live=1 stop=0 close=0 kill=0 status=running' 'the same provider answer on a nonterminal item is never asked for: the lane refuses as live'
write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_STOP_STATUS=4 run_close "$SCRIPT" --keep-sandbox
assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=claude cause=provider status=4$' <<<"$ERR" || true) skipped=$(grep -c '^lane-close: stop-skipped ' <<<"$OUT" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 failed=1 skipped=0 kill=0 status=running' 'under --keep-sandbox the removed-worktree answer refuses, since the kept sandbox keeps the harness'

echo '=== a stopped sandbox answering 4 without the removed-worktree line refuses ==='
write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_STOP_STATUS=4 LANE_CLOSE_STOP_SANDBOX=stopped run_close "$SCRIPT"
assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=claude cause=provider status=4$' <<<"$ERR" || true) relay=$(grep -c '^lane-stopped item=KEN-1 state=stopped verb=stop$' <<<"$ERR" || true) skipped=$(grep -c '^lane-close: stop-skipped ' <<<"$OUT" || true) close=$(close_call_count) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 failed=1 relay=1 skipped=0 close=0 kill=0 status=running' 'a provider 4 for its stopped sandbox refuses under its own words and never reads as a removed worktree'

echo '=== --keep-sandbox leaves a stopped record for later close ==='
write_state running codex /host
write_panes python
codex_screen
run_close "$SCRIPT" --keep-sandbox
assert_eq "rc=$RC stop=$(stop_count KEN-1 codex) close=$(close_call_count) status=$(jq -r '.lanes[0].status' "$STATE") kill=$(grep -c '^kill-window -t %7$' "$CALLS" || true)" \
  'rc=0 stop=1 close=0 status=stopped kill=1' 'keep-sandbox stops the harness, removes its window and records stopped'
run_close "$SCRIPT"
assert_eq "rc=$RC host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 host=1 status=done' 'a later close removes the kept sandbox without requiring its former pane'

echo '=== tracker terminal routes close idle work ==='
for row in 'linear|Done|completed' 'linear|Abandoned|canceled' 'github|CLOSED|'; do
  IFS='|' read -r tracker tracker_state tracker_type <<<"$row"
  write_state running claude /host "$tracker" 'owner/repo'; write_panes python; claude_screen
  if [[ "$tracker" == linear ]]; then
    LANE_CLOSE_TRACKER_STATE="$tracker_state" LANE_CLOSE_TRACKER_STATE_TYPE="$tracker_type" run_close "$SCRIPT"
  else LANE_CLOSE_GITHUB_STATE="$tracker_state" run_close "$SCRIPT"; fi
  assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE")" 'rc=0 status=done' \
    "$tracker $tracker_state work closes an idle lane"
done

echo '=== a recorded window resolves in both forms tmux accepts ==='
write_state running claude /host linear '' 'kendex:KEN-1'; write_panes bash; claude_screen
run_close "$SCRIPT"
assert_eq "rc=$RC kill=$(grep -c '^kill-window -t %7$' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 kill=1 status=done' 'a session-qualified record resolves the pane whose session name matches'

write_state running claude /host linear '' 'kendex:KEN-1'; write_panes bash '' other; claude_screen
run_close "$SCRIPT"
assert_eq "rc=$RC missing=$(grep -c '^lane-close: pane-missing item=KEN-1 window=kendex:KEN-1$' <<<"$ERR" || true) host=$(host_call_count)" \
  'rc=1 missing=1 host=0' 'a qualified record whose session name differs refuses pane-missing'

write_state running claude /host linear '' 'kendex:KEN-1'; write_panes bash duplicate; claude_screen
run_close "$SCRIPT"
assert_eq "rc=$RC ambiguous=$(grep -c '^lane-close: pane-ambiguous item=KEN-1 window=kendex:KEN-1 count=2$' <<<"$ERR" || true) kills=$(grep -c '^kill-window ' "$CALLS" || true)" \
  'rc=1 ambiguous=1 kills=0' 'two panes under one session and name refuse pane-ambiguous'

echo '=== a record written before lane identity was recorded ==='
write_legacy_state running /host; write_panes bash; claude_screen
run_close "$SCRIPT"
assert_eq "rc=$RC host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" 'rc=0 host=1 status=done' \
  'an exited lane closes with no recorded harness, tracker or repo'

write_legacy_state running /host; write_panes python; claude_screen
run_close "$SCRIPT" --harness claude --tracker linear
assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE") stop=$(stop_count KEN-1 claude)" \
  'rc=0 status=done stop=1' 'launch options supply the identity an idle legacy record lacks'

# The two fields the record can answer for itself once it is read rather than
# asked for: the item key names the tracker, and the pane names the harness it
# is running. With both, a pre-record lane closes on its item alone, one row
# per harness the pane can name.
for harness in claude codex pi; do
  write_legacy_state running /host; write_panes "$harness"
  if [[ "$harness" == codex ]]; then codex_screen; else claude_screen; fi
  run_close "$SCRIPT"
  assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE") stop=$(stop_count KEN-1 "$harness")" \
    'rc=0 status=done stop=1' "an idle legacy record closes on its item alone, the $harness harness read off its pane"
done

# issue-N is what open-terminal keys a GitHub lane by AND what a Linear lane is
# keyed by wherever GH_ISSUE_PATTERN accepts that spelling, so the key picks no
# tracker and the close asks for one. The cause is what the row pins: the
# refusal body lists every cause on every refusal, so grepping it for an option
# string proves nothing about which cause this run took.
write_legacy_state running /host issue-1; write_panes claude; claude_screen
run_close "$SCRIPT"
assert_eq "rc=$RC read=$(grep -c '^lane-close: tracker-read-failed item=issue-1 tracker= source=derived cause=key-ambiguous$' <<<"$ERR" || true) gh=$(awk 'END { print NR + 0 }' "$GH_CALLS") typed=$(grep -cE '^(load-buffer|paste-buffer|send-keys) ' "$CALLS" || true) host=$(host_call_count)" \
  'rc=1 read=1 gh=0 typed=0 host=0' 'an issue-N key names no tracker: the close asks for one, reads no issue and types nothing'

write_legacy_state running /host issue-1; write_panes claude; claude_screen
run_close "$SCRIPT" --tracker github --repo owner/repo
assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE") gh=$(grep -c '^issue view 1 --repo owner/repo --json state --jq .state$' "$GH_CALLS" || true)" \
  'rc=0 status=done gh=1' 'the same legacy issue-N record closes once --tracker and --repo name the lane'

# A supplied value stands against the pane, and against the item key. Each row
# pins the value by where it lands: the harness in the stop the provider is
# asked for, and a github tracker on a KEN-1 key in a refusal the linear reader
# never reaches.
write_legacy_state running /host; write_panes claude; claude_screen
run_close "$SCRIPT" --harness codex
assert_eq "rc=$RC codex=$(stop_count KEN-1 codex) claude=$(stop_count KEN-1 claude)" \
  'rc=0 codex=1 claude=0' 'a supplied harness beats the pane the derivation would have read'

write_legacy_state running /host; write_panes claude; claude_screen
run_close "$SCRIPT" --tracker github
assert_eq "rc=$RC read=$(grep -c '^lane-close: tracker-read-failed item=KEN-1 tracker=github source=given cause=key-not-issue$' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 read=1 status=running' 'a supplied tracker beats the item key the derivation would have read'

write_legacy_state running /host; write_panes python; claude_screen
run_close "$SCRIPT" --tracker linear
assert_eq "rc=$RC unsupported=$(grep -c '^lane-close: harness-unsupported item=KEN-1 harness=unknown$' <<<"$ERR" || true) option=$(grep -c -- '--harness claude' <<<"$ERR" || true) host=$(host_call_count)" \
  'rc=1 unsupported=1 option=1 host=0' 'an idle legacy record with a tracker but no harness names the harness option'

# Both spellings the parser takes, over the option the other rows never reach:
# --repo is what the GitHub tracker read is built from, and a value dropped
# anywhere between the parser and that read leaves the lane unclosable.
for spelling in space equals; do
  write_legacy_state running /host issue-1; write_panes python; claude_screen
  case "$spelling" in
    space) run_close "$SCRIPT" --harness claude --tracker github --repo owner/repo ;;
    equals) run_close "$SCRIPT" --harness=claude --tracker=github --repo=owner/repo ;;
  esac
  assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE") gh=$(grep -c '^issue view 1 --repo owner/repo --json state --jq .state$' "$GH_CALLS" || true)" \
    'rc=0 status=done gh=1' "a legacy GitHub record closes through its $spelling options and the repository reaches gh"
done

write_state running claude /host; write_panes python; claude_screen
run_close "$SCRIPT" --harness codex
assert_eq "rc=$RC invalid=$(grep -c '^lane-close: record-invalid item=KEN-1 field=harness recorded=claude option=codex$' <<<"$ERR" || true) host=$(host_call_count)" \
  'rc=1 invalid=1 host=0' 'an option contradicting a recorded field refuses record-invalid and stops nothing'

# The invocation oversee.md section 4 documents for the automatic close. Both
# reads of the fleet state are made through it, so a value lost anywhere
# between the parser and them sends the close to the default state file, where
# no record names the item and a merged lane never closes.
echo '=== the fleet state directory reaches every workflow-state call ==='
for spelling in space equals; do
  write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"
  case "$spelling" in
    space) run_close "$SCRIPT" --state-dir "$FLEET_DIR" ;;
    equals) run_close "$SCRIPT" "--state-dir=$FLEET_DIR" ;;
  esac
  assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE") get=$(state_call_count "--state-dir $FLEET_DIR get oversee ") update=$(state_call_count "--state-dir $FLEET_DIR update oversee ")" \
    'rc=0 status=done get=1 update=1' "the $spelling spelling carries the fleet state directory into the read and the write"
done

echo '=== the exit wait reads the pane after the stop ==='
write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_NO_EXIT=1 LANE_CLOSE_TMUX_LIST_FAIL_AT=2 run_close "$SCRIPT"
assert_eq "rc=$RC read=$(grep -c '^lane-close: pane-read-failed item=KEN-1 pane=%7$' <<<"$ERR" || true) timeout=$(grep -c '^lane-close: exit-timeout ' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 read=1 timeout=0 status=running' 'a pane probe that fails inside the exit wait refuses rather than waiting the lane out'

write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_NO_EXIT=1 LANE_CLOSE_CAPTURE_FAIL_AT=2 run_close "$SCRIPT"
assert_eq "rc=$RC read=$(grep -c '^lane-close: pane-read-failed item=KEN-1 pane=%7$' <<<"$ERR" || true) timeout=$(grep -c '^lane-close: exit-timeout ' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 read=1 timeout=0 status=running' 'a screen capture that fails inside the exit wait refuses as the read it was'

echo '=== a lane holding an unanswered ask is never closed ==='
ASK="$(pending_ask 3600)"
ASK_ID="$(jq -r .id <<<"$ASK")"
write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_MAIL_PENDING="$ASK" run_close "$SCRIPT"
assert_eq "rc=$RC ask=$(grep -cE "^lane-close: ask-unanswered item=KEN-1 ask=$ASK_ID age=360[0-9]s count=1\$" <<<"$ERR" || true) hosted=$(grep -c -- '^pending --item KEN-1 --root /srv/worktree --host host=/host$' "$MAIL_CALLS" || true) stop=$(stop_count KEN-1 claude) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 ask=1 hosted=1 stop=0 status=running' 'an idle lane whose ask nobody answered refuses, naming the ask and its wait, and stops nothing'

if proc_table_readable; then
  MAIL_ROOT="$LANE_ROOT" write_state running claude ""; write_panes python; claude_screen
  start_local_harness claude
  PATH="$LOCAL_PATH" LANE_CLOSE_LANE_PID="$LANE_PID" run_close "$SCRIPT"
  assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE") local=$(grep -c -- "^pending --item KEN-1 --root $LANE_ROOT host=\$" "$MAIL_CALLS" || true)" \
    'rc=0 status=done local=1' 'the same lane closes once the answer lands, a local mailbox read on this disk'
fi

# pending also lists what was sent to the lane and not yet read. A directive
# owes the overseer nothing, so it holds no close.
DIRECTIVE="$(jq -c '.kind = "directive"' <<<"$ASK")"
write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_MAIL_PENDING="$DIRECTIVE" run_close "$SCRIPT"
assert_eq "rc=$RC ask=$(grep -c '^lane-close: ask-unanswered ' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 ask=0 status=done' 'an unread directive pending lists is no unanswered ask, and the lane closes'

write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_MAIL_STATUS=2 run_close "$SCRIPT"
assert_eq "rc=$RC failed=$(grep -c '^lane-close: mail-read-failed item=KEN-1 root=/srv/worktree status=2$' <<<"$ERR" || true) relay=$(grep -c '^lane-mail: mail-read-failed=/srv/worktree$' <<<"$ERR" || true) stop=$(stop_count KEN-1 claude)" \
  'rc=1 failed=1 relay=1 stop=0' 'a mailbox that cannot be read refuses under its own key and stops nothing'

write_state running codex /host; write_panes python; codex_screen
LANE_CLOSE_MAIL_PENDING="$ASK" run_close "$SCRIPT" --keep-sandbox
assert_eq "rc=$RC ask=$(grep -c '^lane-close: ask-unanswered ' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE") kill=$(grep -c '^kill-window ' "$CALLS" || true)" \
  'rc=1 ask=1 status=running kill=0' 'keep-sandbox takes the same refusal and leaves the window standing'

write_state stopped claude /host; : >"$ROWS"; printf '\n' >"$SCREEN"
LANE_CLOSE_MAIL_PENDING="$ASK" run_close "$SCRIPT"
assert_eq "rc=$RC ask=$(grep -c '^lane-close: ask-unanswered ' <<<"$ERR" || true) host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 ask=1 host=0 status=stopped' 'a stopped record holding an ask refuses before its kept sandbox is closed'

write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"
LANE_CLOSE_MAIL_PENDING="$ASK" run_close "$SCRIPT"
assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE") mail=$(awk 'END { print NR + 0 }' "$MAIL_CALLS")" \
  'rc=0 status=done mail=0' 'an exited lane closes with its ask standing, the session an answer would reach being gone'

# The pairing the two rules above make, and the reason they differ: a kept
# sandbox can be relaunched into a session that reads the mailbox, so the ask
# a fully closed lane loses is still owed a reply here.
write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"
LANE_CLOSE_MAIL_PENDING="$ASK" run_close "$SCRIPT" --keep-sandbox
assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE") mail=$(awk 'END { print NR + 0 }' "$MAIL_CALLS")" \
  'rc=0 status=stopped mail=0' 'keep-sandbox on an exited lane holding an ask records stopped and reads no mailbox'
LANE_CLOSE_MAIL_PENDING="$ASK" run_close "$SCRIPT"
assert_eq "rc=$RC ask=$(grep -c '^lane-close: ask-unanswered ' <<<"$ERR" || true) host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 ask=1 host=0 status=stopped' 'the full close of that stopped record refuses until the ask is answered'

# A preparing record: a hosted launch whose background job has written no
# outcome. The job stands in as a process group leader running a script named
# open-terminal that blocks until the test ends it; the close stops that group,
# closes the window, closes or keeps the host, and records done or stopped. A
# pid naming anything else is left alone. prepare_close SCRIPT JOB_PATH
# [ARGS...] runs one close and sets JOB to `stopped` or `running`, read after
# the close returns, then ends the job itself.
JOB_DIR="$TMP_ROOT/job"
mkdir -p "$JOB_DIR"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$JOB_DIR/open-terminal"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$JOB_DIR/other-job"
chmod +x "$JOB_DIR/open-terminal" "$JOB_DIR/other-job"
# A process the close signalled is gone, or a zombie until this shell reaps
# it, within two seconds; a live one is neither.
job_state() { # PID
  local stat
  for _ in $(seq 20); do
    stat="$(ps -o stat= -p "$1" 2>/dev/null)" || { printf stopped; return; }
    [[ "$stat" != Z* ]] || { printf stopped; return; }
    sleep 0.1
  done
  printf running
}
prepare_close() {
  local script="$1" job
  shift
  set -m
  "$1" &
  job=$!
  set +m
  shift
  write_state preparing claude /host
  jq --argjson pid "$job" '.lanes[0].prepare = {since: "2026-09-20T00:00:00Z", log: "/fleet/lane-prepare-KEN-1.log", pid: $pid}' "$STATE" >"$STATE.next"
  mv -- "$STATE.next" "$STATE"
  write_panes bash
  run_close "$script" "$@"
  JOB="$(job_state "$job")"
  kill -TERM -- "-$job" 2>/dev/null || true
  wait "$job" || true
}
prepare_close "$SCRIPT" "$JOB_DIR/open-terminal"
assert_eq "rc=$RC job=$JOB kill=$(grep -c '^kill-window ' "$CALLS" || true) host=$(grep -c '^close ' "$HOST_CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 job=stopped kill=1 host=1 status=done' 'a preparing record closes by stopping its launch job, its window and its host'
prepare_close "$SCRIPT" "$JOB_DIR/open-terminal" --keep-sandbox
assert_eq "rc=$RC job=$JOB kill=$(grep -c '^kill-window ' "$CALLS" || true) host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 job=stopped kill=1 host=0 status=stopped' 'keep-sandbox on a preparing record stops the job and the window and keeps the host'
# A lane with no session holds no ask, and its host need not answer a mailbox
# read while it prepares: a failing read changes nothing and none is made.
LANE_CLOSE_MAIL_STATUS=2 prepare_close "$SCRIPT" "$JOB_DIR/open-terminal"
assert_eq "rc=$RC job=$JOB kill=$(grep -c '^kill-window ' "$CALLS" || true) host=$(grep -c '^close ' "$HOST_CALLS" || true) mail=$(awk 'END { print NR + 0 }' "$MAIL_CALLS") status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 job=stopped kill=1 host=1 mail=0 status=done' 'a preparing record closes with its mailbox unreadable, reading none'
prepare_close "$SCRIPT" "$JOB_DIR/other-job"
assert_eq "rc=$RC job=$JOB status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 job=running status=done' 'a recorded pid that runs anything but open-terminal is left running'

run_boundary() { # RULE SCRIPT
  local rule="$1" script="$2"
  case "$rule" in
    local-host) write_state running claude ""; write_panes bash; printf '\n' >"$SCREEN"; run_close "$script"
      RESULT="rc=$RC host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" ;;
    linear-open|github-open)
      tracker="${rule%-open}"; write_state running claude /host "$tracker" 'owner/repo'; write_panes python; claude_screen
      if [[ "$tracker" == linear ]]; then
        LANE_CLOSE_TRACKER_STATE='In Review' LANE_CLOSE_TRACKER_STATE_TYPE=started run_close "$script"
      else LANE_CLOSE_GITHUB_STATE=OPEN run_close "$script"; fi
      RESULT="rc=$RC live=$(grep -c '^lane-close: lane-live .* state=idle pane=%7$' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" ;;
    linear-renamed)
      write_state running claude /host linear 'owner/repo'; write_panes python; claude_screen
      LANE_CLOSE_TRACKER_STATE=Shipped LANE_CLOSE_TRACKER_STATE_TYPE=completed run_close "$script"
      RESULT="rc=$RC live=$(grep -c '^lane-close: lane-live .* state=idle pane=%7$' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" ;;
    capture-read) write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"; LANE_CLOSE_CAPTURE_FAIL=9 run_close "$script"
      RESULT="rc=$RC read=$(grep -c '^lane-close: pane-read-failed ' <<<"$ERR" || true) host=$(host_call_count)" ;;
  esac
}

echo '=== close boundaries ==='
# RULE|expected
for row in 'local-host|rc=0 host=0 status=done' 'linear-open|rc=1 live=1 status=running' \
  'github-open|rc=1 live=1 status=running' 'linear-renamed|rc=0 live=0 status=done' \
  'capture-read|rc=1 read=1 host=0'; do
  IFS='|' read -r rule expected <<<"$row"
  run_boundary "$rule" "$SCRIPT"
  assert_eq "$RESULT" "$expected" "the $rule boundary holds"
done

echo '=== refusal reads fail closed ==='
# Each row pins the cause the refusal carries, never its English: the several
# reads behind one status answer differently and the operator acts on which.
# The CLI's own line is relayed above the refusal, so a close that failed on an
# auth or a network error says so.
write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_TRACKER_FAIL=8 run_close "$SCRIPT"
assert_eq "rc=$RC read=$(grep -c '^lane-close: tracker-read-failed item=KEN-1 tracker=linear source=given cause=read-failed$' <<<"$ERR" || true) relay=$(grep -c '^linear.sh: api-unreachable$' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 read=1 relay=1 status=running' 'a failed linear read leaves the idle lane running and relays what the CLI said'

write_state running claude /host github 'owner/repo'; write_panes python; claude_screen
LANE_CLOSE_TRACKER_FAIL=8 run_close "$SCRIPT"
assert_eq "rc=$RC read=$(grep -c '^lane-close: tracker-read-failed item=issue-1 tracker=github source=given cause=read-failed$' <<<"$ERR" || true) relay=$(grep -c '^gh: HTTP 401: Bad credentials$' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 read=1 relay=1 status=running' 'a github lane carrying its repository refuses for the read, not for the repository it has'

write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_TRACKER_STATE_TYPE= run_close "$SCRIPT"
assert_eq "rc=$RC read=$(grep -c '^lane-close: tracker-read-failed item=KEN-1 tracker=linear source=given cause=no-state-type$' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 read=1 status=running' 'a linear payload carrying no state_type refuses as a read that did not answer'

write_state running claude /host; : >"$ROWS"; printf '\n' >"$SCREEN"; run_close "$SCRIPT"
assert_eq "rc=$RC missing=$(grep -c '^lane-close: pane-missing ' <<<"$ERR" || true) host=$(host_call_count)" \
  'rc=1 missing=1 host=0' 'a missing recorded pane refuses before provider close'

write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"
LANE_CLOSE_TMUX_LIST_FAIL_AT=1 run_close "$SCRIPT"
assert_eq "rc=$RC read=$(grep -c '^lane-close: pane-read-failed ' <<<"$ERR" || true) host=$(host_call_count)" \
  'rc=1 read=1 host=0' 'an initial tmux pane read failure closes nothing'

echo '=== exit and finalization failures keep the record nonterminal ==='
write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_NO_EXIT=1 run_close "$SCRIPT"
assert_eq "rc=$RC timeout=$(grep -c '^lane-close: exit-timeout item=KEN-1 harness=claude pane=%7 processes=1$' <<<"$ERR" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 timeout=1 kill=0 status=running' 'a pane that outlives the stop keeps its window and its record running'

write_state stopped claude /host; : >"$ROWS"; printf '\n' >"$SCREEN"
LANE_CLOSE_HOST_STATUS=9 run_close "$SCRIPT"
assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE")" 'rc=9 status=stopped' \
  'a stopped lane whose provider close fails stays stopped'

write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"
LANE_CLOSE_STATE_WRITE_FAIL=6 run_close "$SCRIPT"
assert_eq "rc=$RC write=$(grep -c '^lane-close: state-write-failed ' <<<"$ERR" || true) closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" \
  'rc=1 write=1 closed=0' 'a state write failure is reported after close and never reported as done'

write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"
LANE_CLOSE_TMUX_LIST_FAIL_AT=2 run_close "$SCRIPT"
assert_eq "rc=$RC read=$(grep -c '^lane-close: pane-read-failed .* pane=%7$' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 read=1 status=running' 'a late pane probe failure does not record done while its window can remain'
echo '=== must-fail control ==='
MUTANT="$(mutant live '  *) message lane-live "item=$ITEM" "state=$state" "pane=$pane_id" >&2; exit 1 ;;' '  *) ;;')"
write_state running codex /host; write_panes python; printf '› run\n  press to interrupt\n' >"$SCREEN"; run_close "$MUTANT"
assert_eq "rc=$RC closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" 'rc=0 closed=1' 'control: removing the live-state refusal closes a working lane'

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
