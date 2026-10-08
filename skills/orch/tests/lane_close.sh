#!/usr/bin/env bash
# lane-close resolves one recorded pane, refuses live lanes, and closes in order.
# Each independent close protection has a must-fail control.
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
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

host_call_count() { awk 'END { print NR + 0 }' "$HOST_CALLS"; }
close_call_count() { grep -c '^close ' "$HOST_CALLS" || true; }
# The provider stop calls that name this harness, and the pane-writing tmux
# verbs the close made. The stub fails every one of those verbs, so any count
# above zero is a close that typed into a lane.
stop_count() { grep -c -- "^stop --item $1 --harness $2 host=" "$HOST_CALLS" || true; }
typed_count() { grep -cE '^(load-buffer|paste-buffer|send-keys) ' "$CALLS" || true; }
# The exit wait's pane reads by id, lane_pane_by_id's columns; the window
# resolver asks tmux for others.
exit_wait_count() { grep -c -x -F 'list-panes -a -F #{pane_id} #{pane_pid} #{pane_current_command}' "$CALLS" || true; }
# A windowless close whose tracker read failed, as its rows and control read it.
windowless_unread() {
  printf 'rc=%s read=%s missing=%s host=%s status=%s' "$RC" \
    "$(grep -c '^lane-close: tracker-read-failed item=KEN-1 tracker=linear source=given cause=read-failed$' <<<"$ERR" || true)" \
    "$(grep -c '^lane-close: pane-missing ' <<<"$ERR" || true)" "$(host_call_count)" "$(jq -r '.lanes[0].status' "$STATE")"
}
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
cp "$TEST_DIR/../scripts/lib/lane-state.sh" "$TEST_DIR/../scripts/lib/date-ladder.sh" \
  "$TEST_DIR/../scripts/lib/usage-reset.sh" "$TEST_DIR/../scripts/lib/lane-host-slots.sh" \
  "$TEST_DIR/../scripts/lib/lane-capabilities.sh" "$TEST_DIR/../scripts/lib/tmux-server.sh" \
  "$TEST_DIR/../scripts/lib/lane-gitfile.sh" "$SCRIPTS/lib/"
chmod +x "$SCRIPTS/lane-close"

cat >"$SCRIPTS/workflow-state" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$LANE_CLOSE_STATE_CALLS"
if [[ "${1:-}" == --state-dir ]]; then shift 2; fi
verb="$1"; shift
if [[ "$verb" == remove ]]; then
  [[ "${LANE_CLOSE_REMOVE_STATUS:-0}" == 0 ]] || { printf 'workflow-state: remove-failed path=/fleet/x\n' >&2; exit "$LANE_CLOSE_REMOVE_STATUS"; }
  printf 'removed path=/fleet/completion-summary-%s.md\n' "$1"
  exit 0
fi
[[ "$1" == oversee ]]; shift
case "$verb" in
  get) jq "$1" "$LANE_CLOSE_STATE" ;;
  update-report)
    expr="$1"; shift
    jq "$@" "$expr" "$LANE_CLOSE_STATE" >"$LANE_CLOSE_STATE.report"
    jq '.state' "$LANE_CLOSE_STATE.report" >"$LANE_CLOSE_STATE.next"
    mv -- "$LANE_CLOSE_STATE.next" "$LANE_CLOSE_STATE"
    jq '.report' "$LANE_CLOSE_STATE.report" ;;
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
# capabilities is the record's kind, answered before the call log so the
# counts below stay the provider verbs: claude-cloud declares stop=none, and
# every other host the stop its kind declares.
if [[ "${1:-}" == capabilities ]]; then
  case "${ORCH_LANE_HOST:-local}" in
    local) printf 'kind=local\tstop=window\n' ;;
    claude-cloud) printf 'kind=claude-cloud\tstop=none\n' ;;
    *) printf 'kind=ssh\tstop=verb\n' ;;
  esac
  exit 0
fi
printf '%s\n' "$* host=$ORCH_LANE_HOST" >>"$LANE_CLOSE_HOST_CALLS"
# cat is the read of the item's worktree .git, which a merged lane's own
# close-out removes: missing, the protocol's 2 that touch confirms, unless
# LANE_CLOSE_HOST_GITFILE is standing, a linked worktree's line, failed, a
# read the provider could not make, or busy, the dispatcher's refusal at its
# per-home cap.
if [[ "$1" == cat ]]; then
  case "${LANE_CLOSE_HOST_GITFILE:-gone}" in
    standing) printf 'gitdir: /srv/clone/.git/worktrees/ken-1\n'; exit 0 ;;
    failed) printf 'lane-host-ssh: ssh-failed item=%s\n' "$3" >&2; exit 255 ;;
    busy) printf 'lane-host: lane-host-busy item=%s\n' "$3" >&2; exit 69 ;;
    *) exit 2 ;;
  esac
fi
[[ "$1" != touch ]] || exit 0
# list is the provider's inventory, read only after a hosted mailbox read
# fails: LANE_CLOSE_HOST_LIST replaces its rows, a row naming KEN-1 by
# default, and LANE_CLOSE_HOST_LIST_STATUS fails it.
if [[ "$1" == list ]]; then
  [[ "${LANE_CLOSE_HOST_LIST_STATUS:-0}" -eq 0 ]] \
    || { printf 'lane-host-fixture: list-failed\n' >&2; exit "$LANE_CLOSE_HOST_LIST_STATUS"; }
  printf '%b' "${LANE_CLOSE_HOST_LIST-acme/repo/KEN-1\trunning\t1h\tsandbox-1\n}"
  exit 0
fi
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
  # A host holding nothing of the item (LANE_CLOSE_HOST_ABSENT below) has no
  # harness to stop: the protocol's empty match.
  if [[ -n "${LANE_CLOSE_HOST_ABSENT:-}" ]]; then printf 'stopped item=%s processes=0\n' "$3"; exit 0; fi
  if [[ "${LANE_CLOSE_NO_EXIT:-0}" != 1 ]]; then
    printf 'exited\n' >"$LANE_CLOSE_PHASE"
    awk -F'\t' 'BEGIN { OFS = "\t" } { $5 = "bash"; print }' "$LANE_CLOSE_ROWS" >"$LANE_CLOSE_ROWS.next"
    mv -- "$LANE_CLOSE_ROWS.next" "$LANE_CLOSE_ROWS"
  fi
  printf '%s\n' "${LANE_CLOSE_STOP_OUT-stopped item=$3 processes=1}"
  exit 0
fi
# stop-sandbox is the park's provider call: LANE_CLOSE_STOP_SANDBOX_STATUS
# fails it and LANE_CLOSE_STOP_SANDBOX_OUT replaces the protocol's line. Its
# --check form is the judge's capability read: LANE_CLOSE_STOP_SANDBOX_CHECK_STATUS
# is a provider without the pair (2 is lane-host-ssh's absent-verb status) and
# LANE_CLOSE_STOP_SANDBOX_CHECK_OUT replaces its line.
if [[ "$1 ${2:-}" == "stop-sandbox --check" ]]; then
  [[ "${LANE_CLOSE_STOP_SANDBOX_CHECK_STATUS:-0}" -eq 0 ]] \
    || { printf 'lane-host-ssh: verb-invalid verb=stop-sandbox\n' >&2; exit "$LANE_CLOSE_STOP_SANDBOX_CHECK_STATUS"; }
  printf '%s\n' "${LANE_CLOSE_STOP_SANDBOX_CHECK_OUT-sandbox-stoppable item=$4}"
  exit 0
fi
if [[ "$1" == stop-sandbox ]]; then
  [[ "${LANE_CLOSE_STOP_SANDBOX_STATUS:-0}" -eq 0 ]] \
    || { printf 'lane-host-fixture: stop-sandbox-failed item=%s\n' "$3" >&2; exit "$LANE_CLOSE_STOP_SANDBOX_STATUS"; }
  printf '%s\n' "${LANE_CLOSE_STOP_SANDBOX_OUT-sandbox-stopped item=$3}"
  exit 0
fi
# LANE_CLOSE_HOST_MARKER is an item marker the close takes: a close that finds
# it gone refuses as unowned, so a second host close fails the run.
if [[ -n "${LANE_CLOSE_HOST_MARKER:-}" ]]; then
  [[ -e "$LANE_CLOSE_HOST_MARKER" ]] || { printf 'lane-host-ssh: close-unowned item=%s\n' "$3" >&2; exit 75; }
  rm -f -- "$LANE_CLOSE_HOST_MARKER"
fi
# LANE_CLOSE_HOST_ABSENT is a host that no longer holds the item, answering
# close as the protocol states, as its stop above does; a status of 1 is a
# provider failing the close with its own words for that state on stderr.
if [[ -n "${LANE_CLOSE_HOST_ABSENT:-}" ]]; then printf 'closed=absent item=%s\n' "$3"; exit 0; fi
if [[ "${LANE_CLOSE_HOST_STATUS:-0}" -ne 0 ]]; then
  [[ "$LANE_CLOSE_HOST_STATUS" -ne 3 ]] || printf 'lane-host-ssh: close-refused path=/srv/clone\n' >&2
  [[ "$LANE_CLOSE_HOST_STATUS" -ne 1 ]] || printf 'lane-host-fixture: item-unknown item=%s\n' "$3" >&2
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

# lanes answers `pick --lane` for the account the record names with the exit
# LANE_CLOSE_LANES_STATUS gives it: 0 room, 3 walled, 5 unmeasured. The
# ORCH_LANE_HOST each call ran under goes to its own log, `unset` for none.
export LANE_CLOSE_LANES_CALLS="$TMP_ROOT/lanes-calls"
cat >"$SCRIPTS/lanes" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LANE_CLOSE_LANES_CALLS"
printf '%s\n' "${ORCH_LANE_HOST-unset}" >>"$LANE_CLOSE_LANES_CALLS.host"
status="${LANE_CLOSE_LANES_STATUS:-0}"
if [[ -n "${LANE_CLOSE_WALLED_ACCOUNT:-}" ]]; then
  status=0
  [[ "$3" != "$LANE_CLOSE_WALLED_ACCOUNT" ]] || status=3
fi
case "$status" in
  0) printf 'CLAUDE_CONFIG_DIR=%s\n' "$3" ;;
  3) printf 'lanes: pick-lane-walled %s wall=100\n' "$3" >&2 ;;
esac
exit "$status"
EOF
chmod +x "$SCRIPTS/lanes"

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

# The review-gate reducer the park judge asks: LANE_CLOSE_PRWATCH_RC is its
# exit status and LANE_CLOSE_PRWATCH_OUT a file holding its attention lines;
# every call's argv and GH_REPO land in the call log.
export LANE_CLOSE_PRWATCH_CALLS="$TMP_ROOT/prwatch-calls"
mkdir -p "$FIXTURE/skills/review-gate/scripts"
PR_WATCH_STUB="$FIXTURE/skills/review-gate/scripts/pr-watch.sh"
cat >"$PR_WATCH_STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s repo=%s\n' "$*" "${GH_REPO-unset}" >>"$LANE_CLOSE_PRWATCH_CALLS"
[[ -z "${LANE_CLOSE_PRWATCH_OUT:-}" ]] || cat -- "$LANE_CLOSE_PRWATCH_OUT"
[[ "${LANE_CLOSE_PRWATCH_RC:-0}" -ne 2 ]] || printf 'pr-watch: read failure\n' >&2
exit "${LANE_CLOSE_PRWATCH_RC:-0}"
EOF
chmod +x "$PR_WATCH_STUB"

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

# worktree merged, the merge judge a close asks where the record carries no
# cycle: LANE_CLOSE_WORKTREE_MERGED is its exit, 0 merged, 1 not merged, and
# any other a lookup that did not answer; each call lands in the call log.
export LANE_CLOSE_WORKTREE_CALLS="$TMP_ROOT/worktree-calls"
mkdir -p "$FIXTURE/skills/worktree/scripts"
cat >"$FIXTURE/skills/worktree/scripts/worktree" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LANE_CLOSE_WORKTREE_CALLS"
case "${LANE_CLOSE_WORKTREE_MERGED:-1}" in
  0) printf 'abc123\n' ;;
  1) printf 'worktree: unmerged ken-1\n' >&2 ;;
  *) printf 'worktree: merge-unverified ken-1\n' >&2 ;;
esac
exit "${LANE_CLOSE_WORKTREE_MERGED:-1}"
EOF
chmod +x "$FIXTURE/skills/worktree/scripts/worktree"

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
    elif [[ "${*: -1}" == '#{pane_id} #{pane_pid} #{pane_current_command}' ]]; then
      awk -F'\t' '{print $3 " " $4 " " $5}' "$LANE_CLOSE_ROWS"
    elif [[ "${*: -1}" == '#{pid} #{start_time} #{pane_id}' ]]; then
      # The stub's server is pid 999, the one start_local_harness records,
      # unless a row names another to stand for a server this close misses.
      awk -F'\t' -v s="${LANE_CLOSE_TMUX_PID:-999}" '{print s " 1 " $3}' "$LANE_CLOSE_ROWS"
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

# `pr view` answers the park judge from LANE_CLOSE_PR_VIEW, a pull request on
# the item's branch, open, armed and CLEAN unless a row says otherwise, and
# `api graphql` its queue membership from LANE_CLOSE_PR_QUEUE, out of the
# queue unless a row says otherwise, failing under LANE_CLOSE_PR_QUEUE_STATUS;
# `repo view` answers the repository a record without one resolves.
cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LANE_CLOSE_GH_CALLS"
if [[ "${LANE_CLOSE_TRACKER_FAIL:-0}" != 0 ]]; then
  printf 'gh: HTTP 401: Bad credentials\n' >&2
  exit "$LANE_CLOSE_TRACKER_FAIL"
fi
case "$1 $2" in
  "pr view")
    [[ "${LANE_CLOSE_PR_VIEW_STATUS:-0}" -eq 0 ]] || { printf 'gh: Could not resolve to a PullRequest\n' >&2; exit "$LANE_CLOSE_PR_VIEW_STATUS"; }
    if [[ -z "${LANE_CLOSE_PR_VIEW+x}" ]]; then
      LANE_CLOSE_PR_VIEW='{"state":"OPEN","headRefOid":"abc123","headRefName":"ken-1","autoMergeRequest":{"enabledAt":"t"},"mergeStateStatus":"CLEAN"}'
    fi
    printf '%s\n' "$LANE_CLOSE_PR_VIEW" ;;
  "repo view") printf 'owner/resolved\n' ;;
  "api graphql")
    [[ "${LANE_CLOSE_PR_QUEUE_STATUS:-0}" -eq 0 ]] || { printf 'gh: graphql: Something went wrong\n' >&2; exit "$LANE_CLOSE_PR_QUEUE_STATUS"; }
    queue='{"data":{"repository":{"pullRequest":{"isInMergeQueue":false,"mergeQueueEntry":null}}}}'
    printf '%s\n' "${LANE_CLOSE_PR_QUEUE-$queue}" ;;
  *) printf '%s\n' "${LANE_CLOSE_GITHUB_STATE:-CLOSED COMPLETED}" ;;
esac
EOF
chmod +x "$BIN/gh"
# The issue read a GitHub lane's close makes, as the gh stub logs it.
GH_ISSUE_READ='issue view 1 --repo owner/repo --json state,stateReason --jq .state + " " + (.stateReason // "")'

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
# A limit banner under the lane's last turn, above its composer, naming RESET.
walled_screen() { # RESET
  printf '%s\n\n%s\n%s\n' '⏺ I will keep going.' "You've hit your session limit · resets $1" "$CLAUDE_COMPOSER" >"$SCREEN"
}
codex_screen() { cp -- "$PANE_FIXTURES/codex-composer-idle.txt" "$SCREEN"; }
copilot_screen() { cp -- "$PANE_FIXTURES/copilot-idle.txt" "$SCREEN"; }

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
# NAME is the process name, the harness's own where none is given: Copilot's
# binary carries MainThread on Linux. ON_TERM is the harness's SIGTERM trap,
# `exit 0` where none is given and empty for one that ignores the signal. The
# record write_state left gains the launch identity open-terminal records for
# it, read by the library's own start reader as the launch reads it.
start_local_harness() { # HARNESS [NAME] [ON_TERM]
  local name="${2:-$1}" start
  [[ -x "$HARNESS_BIN/$name" ]] || cp -- "$(command -v bash)" "$HARNESS_BIN/$name"
  LANE_PID="$( (cd -- "$LANE_ROOT" && exec "$HARNESS_BIN/$name" -c "trap '${3-exit 0}' TERM; while :; do sleep 0.1; done" \
    </dev/null >/dev/null 2>&1 & printf '%s' "$!") )"
  LANE_PIDS+=" $LANE_PID"
  proc_table_write "$PROC_TABLE" "$LANE_PID 1 $name"
  proc_cwd_write "$PROC_CWD_FILE" "$LANE_PID=$LANE_ROOT_REAL"
  start="$(bash -c '. "$1" && lane_process_start "$2"' _ "$LANE_CLOSE_STATE_LIB" "$LANE_PID")"
  [[ -n "$start" ]] || { printf 'lane-close-test: harness-start-unread pid=%s\n' "$LANE_PID" >&2; exit 1; }
  jq --argjson pid "$LANE_PID" --arg start "$start" '.lanes[0].launch = {pane: "%7", server: 999, pid: $pid, start: $start}' "$STATE" >"$STATE.tmp"
  mv -- "$STATE.tmp" "$STATE"
}

run_close() { # SCRIPT [ARGS...]
  local script="$1"
  shift
  : >"$CALLS"; : >"$HOST_CALLS"; : >"$GH_CALLS"; : >"$STATE_CALLS"; : >"$MAIL_CALLS"; : >"$LANE_CLOSE_PRWATCH_CALLS"; : >"$PHASE"; : >"$TMP_ROOT/list-count"; : >"$TMP_ROOT/capture-count"
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
  for sibling in lane-close workflow-state lane-host lane-mail dev-validate-run lanes lib/date-ladder.sh lib/usage-reset.sh; do
    ln -s "$SCRIPTS/$sibling" "$dir/skills/orch/scripts/$sibling"
  done
  ln -s "$FIXTURE/skills/linear/scripts/linear.sh" "$dir/skills/linear/scripts/linear.sh"
  ln -s "$FIXTURE/skills/worktree" "$dir/skills/worktree"
  ln -s "$SCRIPTS/lib/lane-host-slots.sh" "$dir/skills/orch/scripts/lib/lane-host-slots.sh"
  ln -s "$SCRIPTS/lib/lane-capabilities.sh" "$dir/skills/orch/scripts/lib/lane-capabilities.sh"
  ln -s "$SCRIPTS/lib/tmux-server.sh" "$dir/skills/orch/scripts/lib/tmux-server.sh"
  ln -s "$SCRIPTS/lib/lane-gitfile.sh" "$dir/skills/orch/scripts/lib/lane-gitfile.sh"
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

echo "=== a full close of a finished item removes its files through workflow-state remove ==="
# An exited hosted lane, closed under OPTION with the remove stub answering
# REMOVE_STATUS, the host close HOST_STATUS and the tracker as TRACKER_ENV
# sets it. ITEM_FILES reads what the close did: the removal, the host close,
# the window kill, the record, and the kept and refused lines.
item_files_row() { # OPTION REMOVE_STATUS HOST_STATUS TRACKER_ENV
  local option=()
  [[ "$1" == - ]] || option=("$1")
  write_state running pi /host; write_panes bash; printf '\n' >"$SCREEN"
  export "$4"
  LANE_CLOSE_REMOVE_STATUS="$2" LANE_CLOSE_HOST_STATUS="$3" run_close "$SCRIPT" --state-dir "$FLEET_DIR" ${option[@]+"${option[@]}"}
  unset "${4%%=*}"
  ITEM_FILES="rc=$RC remove=$(grep -c -x -- "--state-dir $FLEET_DIR remove KEN-1" "$STATE_CALLS" || true) close=$(close_call_count) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE") kept=$(sed -n 's/^lane-close: item-files-kept item=KEN-1 cause=//p' <<<"$OUT") refused=$(grep -c -x "lane-close: item-files-failed item=KEN-1 status=$2" <<<"$ERR" || true)"
}
# label|option|remove status|host status|tracker env|expected
ITEM_FILE_ROWS=(
  "a finished item's full close removes its files in the state directory it was handed|-|0|0|LANE_CLOSE_NONE=1|rc=0 remove=1 close=1 kill=1 status=done kept= refused=0"
  "a removal that fails refuses before the host close, with host, window and record unchanged|-|5|0|LANE_CLOSE_NONE=1|rc=1 remove=1 close=0 kill=0 status=running kept= refused=1"
  "a host close that refuses after the removal leaves the record running|-|0|3|LANE_CLOSE_NONE=1|rc=3 remove=1 close=1 kill=0 status=running kept= refused=0"
  "a close that keeps the sandbox keeps the item's files|--keep-sandbox|0|0|LANE_CLOSE_NONE=1|rc=0 remove=0 close=0 kill=1 status=stopped kept= refused=0"
  "an exited lane whose item is still open closes and keeps its files|-|0|0|LANE_CLOSE_TRACKER_STATE_TYPE=started|rc=0 remove=0 close=1 kill=1 status=done kept=open refused=0"
  "an exited lane whose tracker does not answer closes and keeps its files|-|0|0|LANE_CLOSE_TRACKER_FAIL=1|rc=0 remove=0 close=1 kill=1 status=done kept=read-failed refused=0"
)
for row in "${ITEM_FILE_ROWS[@]}"; do
  IFS='|' read -r label option remove_status host_status tracker_env want <<<"$row"
  item_files_row "$option" "$remove_status" "$host_status" "$tracker_env"
  assert_eq "$ITEM_FILES" "$want" "$label"
done
# The retry the refusal promises, against a host whose close takes its item
# marker: after a failed removal, a second close reaches the removal and the
# host close.
: >"$TMP_ROOT/host-marker"
export LANE_CLOSE_HOST_MARKER="$TMP_ROOT/host-marker"
item_files_row - 5 0 LANE_CLOSE_NONE=1
LANE_CLOSE_REMOVE_STATUS=0 run_close "$SCRIPT" --state-dir "$FLEET_DIR"
unset LANE_CLOSE_HOST_MARKER
assert_eq "rc=$RC remove=$(grep -c -x -- "--state-dir $FLEET_DIR remove KEN-1" "$STATE_CALLS" || true) close=$(close_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" 'rc=0 remove=1 close=1 status=done' \
  'a second close after a failed removal removes the files, closes the host and records done'

echo '=== a full close after the merge passes --merged to the host close ==='
# An exited hosted lane, or a parked record, whose record carries the cycle of
# pull request CYCLE's merge, or none for -, closed by SCRIPT with worktree
# merged exiting WT_STATUS and the tracker as TRACKER_ENV sets it. MERGED reads
# the host close with and without the flag, the worktree asks, the
# merged-unjudged notice and the worktree words relayed. A TRACKER_ENV setting
# the GitHub state closes the GitHub lane issue-1.
merged_row() { # SCRIPT STATUS CYCLE WT_STATUS TRACKER_ENV
  local item=KEN-1 tracker=linear
  if [[ "$5" == LANE_CLOSE_GITHUB_STATE=* ]]; then item=issue-1 tracker=github; fi
  write_state "$2" pi /host "$tracker" owner/repo; write_panes bash; printf '\n' >"$SCREEN"
  if [[ "$3" != - ]]; then
    jq --argjson pr "$3" '.lanes[0].cycle = {pr: $pr}' "$STATE" >"$STATE.next" && mv -- "$STATE.next" "$STATE"
  fi
  : >"$LANE_CLOSE_WORKTREE_CALLS"
  export "$5"
  LANE_CLOSE_WORKTREE_MERGED="$4" run_close "$1" --state-dir "$FLEET_DIR"
  unset "${5%%=*}"
  MERGED="rc=$RC merged=$(grep -c -x "close --item $item --merged host=/host" "$HOST_CALLS" || true) plain=$(grep -c -x "close --item $item host=/host" "$HOST_CALLS" || true) asked=$(grep -c -x "merged $item" "$LANE_CLOSE_WORKTREE_CALLS" || true) unjudged=$(sed -n "s/^lane-close: merged-unjudged item=$item //p" <<<"$OUT") relay=$(grep -c '^worktree: ' <<<"$ERR" || true)"
}
# label|record status|cycle|worktree merged exit|tracker env|expected
MERGED_ROWS=(
  "a finished item whose record carries its merge's cycle closes with --merged, asking worktree nothing|running|7|1|LANE_CLOSE_NONE=1|rc=0 merged=1 plain=0 asked=0 unjudged= relay=0"
  "worktree merged proves a merge the record carries no cycle of|running|-|0|LANE_CLOSE_NONE=1|rc=0 merged=1 plain=0 asked=1 unjudged= relay=0"
  "a finished item neither reading shows merged closes without the flag, its worktree answer kept quiet|running|-|1|LANE_CLOSE_NONE=1|rc=0 merged=0 plain=1 asked=1 unjudged= relay=0"
  "a cycle an earlier merge left passes no flag while the tracker holds the item open|running|7|0|LANE_CLOSE_TRACKER_STATE_TYPE=started|rc=0 merged=0 plain=1 asked=0 unjudged= relay=0"
  "a tracker that does not answer passes no flag|running|7|0|LANE_CLOSE_TRACKER_FAIL=1|rc=0 merged=0 plain=1 asked=0 unjudged= relay=0"
  "a canceled item whose record carries an earlier merge's cycle closes without the flag|running|7|0|LANE_CLOSE_TRACKER_STATE_TYPE=canceled|rc=0 merged=0 plain=1 asked=0 unjudged= relay=0"
  "a GitHub issue closed as completed after its merge closes with --merged|running|7|1|LANE_CLOSE_GITHUB_STATE=CLOSED COMPLETED|rc=0 merged=1 plain=0 asked=0 unjudged= relay=0"
  "a GitHub issue closed as not planned closes without the flag|running|7|0|LANE_CLOSE_GITHUB_STATE=CLOSED NOT_PLANNED|rc=0 merged=0 plain=1 asked=0 unjudged= relay=0"
  "a merge worktree merged cannot judge closes without the flag, named with its words|running|-|2|LANE_CLOSE_NONE=1|rc=0 merged=0 plain=1 asked=1 unjudged=status=2 relay=1"
  "a parked record's close after its merge passes --merged|parked|7|1|LANE_CLOSE_NONE=1|rc=0 merged=1 plain=0 asked=0 unjudged= relay=0"
)
for row in "${MERGED_ROWS[@]}"; do
  IFS='|' read -r label status cycle wt_status tracker_env want <<<"$row"
  merged_row "$SCRIPT" "$status" "$cycle" "$wt_status" "$tracker_env"
  assert_eq "$MERGED" "$want" "$label"
done
# One control per rule of the flag: the cycle as evidence, worktree merged's
# exit 1 as not merged, the finished item, the completed item, and GitHub's
# COMPLETED reason as completed. Each mutant turns its row red.
# The fields are split on ^, since the replaced code holds a pipe.
# label^old^new^status^cycle^worktree merged exit^tracker env^expected
MERGED_CONTROLS=(
  "control: without the cycle reading a recorded merge closes without the flag^  record_merged && return 0^  :^running^7^1^LANE_CLOSE_NONE=1^merged=0"
  "control: worktree merged's exit 1 read as merged passes the flag for an unmerged item^    1) return 1 ;;^    1) return 0 ;;^running^-^1^LANE_CLOSE_NONE=1^merged=1"
  "control: without the finished gate a stale cycle passes the flag for an open item^  if [[ \"\$ITEM_END\" == completed ]] && item_merged; then^  if item_merged; then^running^7^0^LANE_CLOSE_TRACKER_STATE_TYPE=started^merged=1"
  "control: a gate on any terminal state passes the flag for a canceled item^  if [[ \"\$ITEM_END\" == completed ]] && item_merged; then^  if [[ -n \"\$ITEM_END\" ]] && item_merged; then^running^7^0^LANE_CLOSE_TRACKER_STATE_TYPE=canceled^merged=1"
  "control: any GitHub close reason read as completed passes the flag for an issue not planned^      if [[ \"\$reason\" == COMPLETED ]]; then^      if [[ -n \"\$reason\" ]]; then^running^7^0^LANE_CLOSE_GITHUB_STATE=CLOSED NOT_PLANNED^merged=1"
)
n=0
for row in "${MERGED_CONTROLS[@]}"; do
  IFS='^' read -r label old new status cycle wt_status tracker_env want <<<"$row"
  n=$((n + 1))
  merged_row "$(mutant "lane-close-merged-$n" "$old" "$new")" "$status" "$cycle" "$wt_status" "$tracker_env"
  assert_eq "$(grep -o 'merged=[0-9]*' <<<"$MERGED")" "$want" "$label"
done

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

echo '=== a host that no longer holds the item closes the record ==='
# A hosted lane closed by SCRIPT, exited in its window or, for a PANE of -,
# with no window left on a terminal item, which stops before it closes; the
# provider answers as HOST_ENV sets it. ABSENT_CLOSE reads the relayed
# closed=absent line, a kept=none line, the provider stop, the window kill and
# the record.
absent_row() { # SCRIPT PANE HOST_ENV
  local envs var
  write_state running claude /host; printf '\n' >"$SCREEN"
  if [[ "$2" == - ]]; then : >"$ROWS"; else write_panes "$2"; fi
  read -ra envs <<<"$3"
  for var in "${envs[@]}"; do export "$var"; done
  run_close "$1"
  for var in "${envs[@]}"; do unset "${var%%=*}"; done
  ABSENT_CLOSE="rc=$RC absent=$(grep -cx 'closed=absent item=KEN-1' <<<"$OUT" || true) none=$(grep -cx 'kept=none' <<<"$OUT" || true) stop=$(stop_count KEN-1 claude) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")"
}
# label|script|pane|host env|expected
ABSENT_ROWS=(
  "a provider answering closed=absent closes the record done, with no kept=none|$SCRIPT|bash|LANE_CLOSE_HOST_ABSENT=1|rc=0 absent=1 none=0 stop=0 kill=1 status=done"
  "a windowless record whose provider holds nothing stops with processes=0 and closes done|$SCRIPT|-|LANE_CLOSE_HOST_ABSENT=1|rc=0 absent=1 none=0 stop=1 kill=0 status=done"
  "control: a provider exiting 1 with item-unknown on stderr still refuses, window and record kept|$SCRIPT|bash|LANE_CLOSE_HOST_STATUS=1|rc=1 absent=0 none=0 stop=0 kill=0 status=running"
  "control: a windowless record whose provider stop fails still refuses before the host close|$SCRIPT|-|LANE_CLOSE_HOST_ABSENT=1 LANE_CLOSE_STOP_STATUS=75|rc=1 absent=0 none=0 stop=1 kill=0 status=running"
  "control: a close that does not read closed=absent claims kept=none|$(mutant lane-close-absent ' && ! grep -qxF "closed=absent item=$ITEM" "$out"' '')|bash|LANE_CLOSE_HOST_ABSENT=1|rc=0 absent=1 none=1 stop=0 kill=1 status=done"
)
for row in "${ABSENT_ROWS[@]}"; do
  IFS='|' read -r label script pane host_env want <<<"$row"
  absent_row "$script" "$pane" "$host_env"
  assert_eq "$ABSENT_CLOSE" "$want" "$label"
done

echo '=== a provider that lists no sandbox for a terminal item closes the record alone ==='
# The provider's close --force removed the sandbox and it answers item-unknown
# to every item verb, the mailbox read first, so lane-mail refuses. A hosted
# record, windowless (PANE -), stopped (PANE stopped) or idle in its window
# under PANE, is closed by SCRIPT on
# the env ENV sets; GONE_CLOSE reads the host-absent line, the refusal, the
# provider list, stop and close, the item files, the window kill and record.
gone_row() { # SCRIPT PANE ENV [ARGS...]
  local envs var script="$1" pane="$2"
  case "$pane" in
    -) write_state running claude /host; : >"$ROWS"; printf '\n' >"$SCREEN" ;;
    stopped) write_state stopped claude /host; : >"$ROWS"; printf '\n' >"$SCREEN" ;;
    *) write_state running claude /host; write_panes "$pane"; claude_screen ;;
  esac
  read -ra envs <<<"$3"
  shift 3
  for var in "${envs[@]}"; do export "$var"; done
  run_close "$script" "$@"
  for var in "${envs[@]}"; do unset "${var%%=*}"; done
  GONE_CLOSE="rc=$RC absent=$(grep -cx 'lane-close: host-absent item=KEN-1 host=/host mail-status=2' <<<"$OUT" || true) refused=$(grep -c '^lane-close: mail-read-failed item=KEN-1 ' <<<"$ERR" || true) list=$(grep -c '^list host=/host$' "$HOST_CALLS" || true) stop=$(stop_count KEN-1 claude) close=$(close_call_count) removed=$(grep -c -x 'remove KEN-1' "$STATE_CALLS" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")"
}
NO_ROW='acme/repo/KEN-9\trunning\t1h\tsandbox-9\n'
# label|script|pane|env|args|expected
GONE_ROWS=(
  "an available host naming the item holds no sandbox and closes the record alone|$SCRIPT|-|LANE_CLOSE_MAIL_STATUS=2 LANE_CLOSE_HOST_LIST=acme/repo/ken-1\tavailable\t1h\thost-1\n||rc=0 absent=1 refused=0 list=1 stop=0 close=0 removed=1 kill=0 status=done"
  "control: the unchanged suffix match treats an available host as the item still present|$(mutant lane-close-gone-available '          $2 == "available" { next }' '')|-|LANE_CLOSE_MAIL_STATUS=2 LANE_CLOSE_HOST_LIST=acme/repo/ken-1\tavailable\t1h\thost-1\n||rc=1 absent=0 refused=1 list=1 stop=0 close=0 removed=0 kill=0 status=running"
  "a windowless record on a canceled item whose provider lists no sandbox closes done, no stop or close|$SCRIPT|-|LANE_CLOSE_MAIL_STATUS=2 LANE_CLOSE_TRACKER_STATE_TYPE=canceled LANE_CLOSE_HOST_LIST=$NO_ROW||rc=0 absent=1 refused=0 list=1 stop=0 close=0 removed=1 kill=0 status=done"
  "an idle record on a terminal item whose provider lists no sandbox closes done and kills its window|$SCRIPT|python|LANE_CLOSE_MAIL_STATUS=2 LANE_CLOSE_HOST_LIST=||rc=0 absent=1 refused=0 list=1 stop=0 close=0 removed=1 kill=1 status=done"
  "a provider still listing the item, in another case, keeps the refusal|$SCRIPT|-|LANE_CLOSE_MAIL_STATUS=2 LANE_CLOSE_HOST_LIST=acme/repo/ken-1\trunning\t1h\tsandbox-1\n||rc=1 absent=0 refused=1 list=1 stop=0 close=0 removed=0 kill=0 status=running"
  "a list that fails keeps the refusal|$SCRIPT|-|LANE_CLOSE_MAIL_STATUS=2 LANE_CLOSE_HOST_LIST_STATUS=1||rc=1 absent=0 refused=1 list=1 stop=0 close=0 removed=0 kill=0 status=running"
  "a stopped record on a terminal item reads its tracker there and closes done|$SCRIPT|stopped|LANE_CLOSE_MAIL_STATUS=2 LANE_CLOSE_HOST_LIST=$NO_ROW||rc=0 absent=1 refused=0 list=1 stop=0 close=0 removed=1 kill=0 status=done"
  "a stopped record on an item the tracker holds open reads no list and keeps the refusal|$SCRIPT|stopped|LANE_CLOSE_MAIL_STATUS=2 LANE_CLOSE_TRACKER_STATE_TYPE=started LANE_CLOSE_HOST_LIST=$NO_ROW||rc=1 absent=0 refused=1 list=0 stop=0 close=0 removed=0 kill=0 status=stopped"
  "--keep-sandbox reads no list and keeps the refusal|$SCRIPT|python|LANE_CLOSE_MAIL_STATUS=2 LANE_CLOSE_HOST_LIST=$NO_ROW|--keep-sandbox|rc=1 absent=0 refused=1 list=0 stop=0 close=0 removed=0 kill=0 status=running"
  "control: without the list reading the gone sandbox strands the record at mail-read-failed|$(mutant lane-close-gone '  if [[ -n "$host" && "$KEEP_SANDBOX" == false && "$PARK" == false ]]; then' '  if false; then')|-|LANE_CLOSE_MAIL_STATUS=2 LANE_CLOSE_TRACKER_STATE_TYPE=canceled LANE_CLOSE_HOST_LIST=$NO_ROW||rc=1 absent=0 refused=1 list=0 stop=0 close=0 removed=0 kill=0 status=running"
  "control: a list read without the item match closes a listed sandbox's record|$(mutant lane-close-gone-match "END { exit !found }' <<<\"\$listing\"; then" "END { exit 1 }' <<<\"\$listing\"; then")|-|LANE_CLOSE_MAIL_STATUS=2 LANE_CLOSE_HOST_LIST=acme/repo/ken-1\\trunning\\t1h\\tsandbox-1\\n||rc=0 absent=1 refused=0 list=1 stop=0 close=0 removed=1 kill=0 status=done"
)
for row in "${GONE_ROWS[@]}"; do
  IFS='|' read -r label script pane gone_env gone_args want <<<"$row"
  if [[ -n "$gone_args" ]]; then gone_row "$script" "$pane" "$gone_env" "$gone_args"; else gone_row "$script" "$pane" "$gone_env"; fi
  assert_eq "$GONE_CLOSE" "$want" "$label"
done
# A list lane-host refuses at its per-home cap ran no provider, so it says
# nothing about the sandbox: the close exits with lane-host's 69, which the
# watch retries, record and window kept. SCRIPT|label|expected
GONE_BUSY_ROWS=(
  "$SCRIPT|a list lane-host refused at its cap is lane-host-busy, record kept|rc=69 busy=1 refused=0 status=running"
  "$(mutant lane-close-gone-busy '      [[ "$rc" -ne "$LANE_HOST_BUSY_EXIT" ]] || { message lane-host-busy "item=$ITEM" step=list >&2; exit "$rc"; }' '')|control: without the busy arm a capped list refuses as mail-read-failed|rc=1 busy=0 refused=1 status=running"
)
for row in "${GONE_BUSY_ROWS[@]}"; do
  IFS='|' read -r script label want <<<"$row"
  gone_row "$script" - "LANE_CLOSE_MAIL_STATUS=2 LANE_CLOSE_HOST_LIST_STATUS=69"
  assert_eq "rc=$RC busy=$(grep -cx 'lane-close: lane-host-busy item=KEN-1 step=list' <<<"$ERR" || true) refused=$(grep -c '^lane-close: mail-read-failed item=KEN-1 ' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" "$want" "$label"
done

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

# A local lane: the same stop, run here against the launch identity its record
# names, ends the harness process itself.
if proc_table_readable; then
  # HARNESS:PROCESS: a copilot lane's pane reads node, its npm loader, and
  # its screen is Copilot's own idle composer.
  for harness_row in claude:claude codex:codex pi:pi copilot:MainThread; do
    harness="${harness_row%%:*}"
    MAIL_ROOT="$LANE_ROOT" write_state running "$harness" ""
    if [[ "$harness" == copilot ]]; then write_panes node; copilot_screen; else write_panes python; claude_screen; fi
    start_local_harness "$harness" "${harness_row#*:}"
    PATH="$LOCAL_PATH" LANE_CLOSE_LANE_PID="$LANE_PID" run_close "$SCRIPT"
    assert_eq "rc=$RC lane=$(proc_state_after "$LANE_PID") typed=$(typed_count) host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
      'rc=0 lane=gone typed=0 host=0 status=done' "a local $harness lane is stopped by SIGTERM to its recorded process"
  done

  # The lane's own close-out (../workflows/merge-pr.md § 5 step 6) removed its
  # worktree, the record's mail_root, and either left it gone or a later one
  # made a tree at the same path: the recorded harness, whose directory is the
  # removed tree, is still the one stopped. A stop that found the harness by
  # the directory cannot resolve a removed one and would find none in a
  # recreated one. The lane-mail stub answers no ask for any root, as the real
  # `lane-mail pending` does for a root that does not exist.
  worktree_gone_row() { # MODE SCRIPT; MODE is removed or recreated
    mkdir -p -- "$LANE_ROOT"
    MAIL_ROOT="$LANE_ROOT" write_state running claude ""; write_panes python; claude_screen
    start_local_harness claude
    rm -rf -- "${LANE_ROOT:?}"
    case "$1" in
      removed) ;;
      recreated) mkdir -p -- "$LANE_ROOT" ;;
      *) printf 'lane-close-test: worktree-mode-unknown mode=%s\n' "$1" >&2; exit 1 ;;
    esac
    PATH="$LOCAL_PATH" LANE_CLOSE_LANE_PID="$LANE_PID" run_close "$2"
  }
  # MODE|label
  WORKTREE_GONE_ROWS=(
    "removed|a worktree its close-out removed still stops the recorded harness and closes"
    "recreated|a worktree removed and recreated at the same path still stops the recorded harness"
  )
  for row in "${WORKTREE_GONE_ROWS[@]}"; do
    IFS='|' read -r mode label <<<"$row"
    worktree_gone_row "$mode" "$SCRIPT"
    assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed ' <<<"$ERR" || true) lane=$(proc_state_after "$LANE_PID") status=$(jq -r '.lanes[0].status' "$STATE")" \
      'rc=0 failed=0 lane=gone status=done' "$label"
  done
  # Control: a close that drops the recorded identity reads the pane, whose
  # process holds no harness here, and stops nothing.
  MUTANT="$(mutant lane-close-record-identity '    record_identity launch' '    RECORD_PID="" RECORD_START=""')"
  worktree_gone_row recreated "$MUTANT"
  assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=claude cause=identity-unread$' <<<"$ERR" || true) lane=$(proc_state_after "$LANE_PID") status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=1 failed=1 lane=alive status=running' 'control: without the recorded identity the recreated tree stops nothing'
  kill "$LANE_PID" 2>/dev/null || true
  # Control: a close whose local stop finds the harness by the worktree
  # directory cannot resolve the removed one and refuses with it still alive.
  MUTANT="$(mutant lane-close-directory-stop \
    '    if ! lane_stop_local "$pane_pid" "$RECORD_PID" "$RECORD_START" "$wake_pid" "$wake_start" "$harness"; then' \
    '    if ! lane_stop_owned "$mail_root" "$harness"; then')"
  worktree_gone_row removed "$MUTANT"
  assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=claude cause=worktree-read-failed$' <<<"$ERR" || true) lane=$(proc_state_after "$LANE_PID") status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=1 failed=1 lane=alive status=running' 'control: a directory stop refuses the removed worktree and stops nothing'
  kill "$LANE_PID" 2>/dev/null || true
  mkdir -p -- "$LANE_ROOT"

  # A record naming no identity reads it off the pane: the harness under the
  # pane's own process.
  MAIL_ROOT="$LANE_ROOT" write_state running claude ""; claude_screen
  start_local_harness claude
  jq 'del(.lanes[0].launch)' "$STATE" >"$STATE.tmp" && mv -- "$STATE.tmp" "$STATE"
  printf 'kendex\tKEN-1\t%%7\t%s\tpython\n' "$LANE_PID" >"$ROWS"
  PATH="$LOCAL_PATH" LANE_CLOSE_LANE_PID="$LANE_PID" run_close "$SCRIPT"
  assert_eq "rc=$RC lane=$(proc_state_after "$LANE_PID") status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=0 lane=gone status=done' 'a record naming no launch identity stops the harness under its pane'
  # Control: an identity read that skips the pane's own process finds no
  # harness where the pane runs it directly.
  MUTANT="$(lib_mutant identity-root '  found="$(lane_process_below "$table" "$1" "$name_re" 1 "" pids)" || return 2' \
    '  found="$(lane_process_below "$table" "$1" "$name_re" 0 "" pids)" || return 2')"
  MAIL_ROOT="$LANE_ROOT" write_state running claude ""; claude_screen
  start_local_harness claude
  jq 'del(.lanes[0].launch)' "$STATE" >"$STATE.tmp" && mv -- "$STATE.tmp" "$STATE"
  printf 'kendex\tKEN-1\t%%7\t%s\tpython\n' "$LANE_PID" >"$ROWS"
  PATH="$LOCAL_PATH" LANE_CLOSE_LANE_PID="$LANE_PID" run_close "$MUTANT"
  assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=claude cause=identity-unread$' <<<"$ERR" || true) lane=$(proc_state_after "$LANE_PID")" \
    'rc=1 failed=1 lane=alive' 'control: an identity read that skips the pane process stops nothing'
  kill "$LANE_PID" 2>/dev/null || true

  # The recorded pid now started at another time is a later process handed
  # that pid: it is never signalled, and with no harness under the pane either
  # the close refuses as a stale identity, naming the pid, rather than reading
  # a stop of nothing and waiting the pane out.
  start_time_row() { # SCRIPT
    MAIL_ROOT="$LANE_ROOT" write_state running claude ""; write_panes python; claude_screen
    start_local_harness claude
    jq '.lanes[0].launch.start = "Thu Jan 1 00:00:00 1970"' "$STATE" >"$STATE.tmp" && mv -- "$STATE.tmp" "$STATE"
    PATH="$LOCAL_PATH" LANE_CLOSE_LANE_PID="$LANE_PID" run_close "$1"
  }
  start_time_row "$SCRIPT"
  assert_eq "rc=$RC failed=$(grep -c "^lane-close: stop-failed item=KEN-1 harness=claude pid=$LANE_PID cause=identity-stale\$" <<<"$ERR" || true) timeout=$(grep -c '^lane-close: exit-timeout ' <<<"$ERR" || true) lane=$(proc_state_after "$LANE_PID") kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=1 failed=1 timeout=0 lane=alive kill=0 status=running' 'a recorded pid that started at another time is never signalled and refuses as stale'
  kill "$LANE_PID" 2>/dev/null || true
  # Control: without the start comparison the later process is signalled.
  MUTANT="$(lib_mutant start-check '  [[ -n "$start" && "$start" == "$2" ]] || { LANE_STOP_CAUSE=identity-stale; return 3; }' \
    '  [[ -n "$start" ]] || { LANE_STOP_CAUSE=identity-stale; return 3; }')"
  start_time_row "$MUTANT"
  assert_eq "lane=$(proc_state_after "$LANE_PID")" 'lane=gone' 'control: without the start comparison a reused pid is signalled'

  # A live recorded pid whose start reads empty is no answer, never a stale
  # identity: the close refuses on that pid and leaves it running.
  empty_start_row() { # SCRIPT
    MAIL_ROOT="$LANE_ROOT" write_state running claude ""; write_panes python; claude_screen
    start_local_harness claude
    PATH="$LOCAL_PATH" LANE_CLOSE_LANE_PID="$LANE_PID" run_close "$1"
  }
  MUTANT="$(lib_mutant empty-start '' '' "lane_process_start() { printf '\\n'; }")"
  empty_start_row "$MUTANT"
  assert_eq "rc=$RC failed=$(grep -c "^lane-close: stop-failed item=KEN-1 harness=claude pid=$LANE_PID cause=start-read-failed\$" <<<"$ERR" || true) lane=$(proc_state_after "$LANE_PID") status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=1 failed=1 lane=alive status=running' 'an empty start read on a live recorded pid refuses as start-read-failed'
  kill "$LANE_PID" 2>/dev/null || true
  # Control: without the second state read the empty start reads as a pid that
  # exited, a stale identity.
  MUTANT="$(lib_mutant empty-start-stale '      [[ -z "$state" || "$state" == Z ]] || { LANE_STOP_CAUSE=start-read-failed; return 1; }' '      :' \
    "lane_process_start() { printf '\\n'; }")"
  empty_start_row "$MUTANT"
  assert_eq "rc=$RC failed=$(grep -c "^lane-close: stop-failed item=KEN-1 harness=claude pid=$LANE_PID cause=identity-stale\$" <<<"$ERR" || true) lane=$(proc_state_after "$LANE_PID")" \
    'rc=1 failed=1 lane=alive' 'control: without the second state read an empty start reads as a stale identity'
  kill "$LANE_PID" 2>/dev/null || true

  # A harness restarted by hand in its pane: the recorded one has exited, and
  # the one now running is the process under the pane, which the close reads
  # and stops.
  restarted_row() { # SCRIPT
    local identity
    MAIL_ROOT="$LANE_ROOT" write_state running claude ""; claude_screen
    start_local_harness claude
    identity="$(jq -c '.lanes[0].launch' "$STATE")"
    kill -KILL "$LANE_PID"
    while [[ "$(proc_state_after "$LANE_PID")" != gone ]]; do sleep 0.05; done
    start_local_harness claude
    jq --argjson launch "$identity" '.lanes[0].launch = $launch' "$STATE" >"$STATE.tmp" && mv -- "$STATE.tmp" "$STATE"
    printf 'kendex\tKEN-1\t%%7\t%s\tpython\n' "$LANE_PID" >"$ROWS"
    PATH="$LOCAL_PATH" LANE_CLOSE_LANE_PID="$LANE_PID" run_close "$1"
  }
  restarted_row "$SCRIPT"
  assert_eq "rc=$RC lane=$(proc_state_after "$LANE_PID") status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=0 lane=gone status=done' 'a recorded harness that exited leaves the stop to the harness now under the pane'
  # Control: a stale recorded identity that refuses at once never reads the pane.
  MUTANT="$(lib_mutant stale-pane '      3) unread=identity-stale ;;' '      3) return 1 ;;')"
  restarted_row "$MUTANT"
  assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=claude pid=[0-9]* cause=identity-stale$' <<<"$ERR" || true) lane=$(proc_state_after "$LANE_PID")" \
    'rc=1 failed=1 lane=alive' 'control: a stale identity that skips the pane read leaves the restarted harness running'
  kill "$LANE_PID" 2>/dev/null || true

  # A wake's turn runs detached, outside the pane's process tree, so no stop of
  # the harness reaches it: the close finds it by the record's wake. PANE is
  # `exited`, a lane whose harness is already gone, where the close stops the
  # turn alone, or `idle`, whose harness the close stops by its launch with the
  # turn after it in one library stop, the one lane-reach.md's mail that cannot
  # wait runs by hand, or `stuck`, an idle lane whose harness ignores its
  # SIGTERM. WAKE is the turn: `live`, `exited` before the close, a turn
  # already over, or `ignores` its SIGTERM. The refusal's pid reads WAKE or
  # LANE.
  wake_row() { # SCRIPT PANE WAKE
    local wake refusal
    MAIL_ROOT="$LANE_ROOT" write_state running claude ""
    if [[ "$2" != exited ]]; then write_panes python; claude_screen; else write_panes bash; printf '\n' >"$SCREEN"; fi
    if [[ "$3" == ignores ]]; then start_local_harness claude claude ''; else start_local_harness claude; fi
    WAKE_PID="$LANE_PID"
    wake="$(jq -c '.lanes[0].launch | {pid, start}' "$STATE")"
    jq --argjson wake "$wake" '.lanes[0].wake = $wake | del(.lanes[0].launch)' "$STATE" >"$STATE.tmp" && mv -- "$STATE.tmp" "$STATE"
    if [[ "$3" == exited ]]; then
      kill -KILL "$WAKE_PID"
      while [[ "$(proc_state_after "$WAKE_PID")" != gone ]]; do sleep 0.05; done
    fi
    LANE_PID=""
    if [[ "$2" != exited ]]; then
      if [[ "$2" == stuck ]]; then start_local_harness claude claude ''; else start_local_harness claude; fi
      printf '%s 1 claude\n' "$WAKE_PID" >>"$PROC_TABLE"
    fi
    PATH="$LOCAL_PATH" LANE_CLOSE_LANE_PID="$LANE_PID" run_close "$1"
    refusal="$(grep '^lane-close: stop-failed ' <<<"$ERR" || true)"
    WAKE_GOT="rc=$RC wake=$(proc_state_after "$WAKE_PID")${LANE_PID:+ lane=$(proc_state_after "$LANE_PID")} status=$(jq -r '.lanes[0].status' "$STATE") refusal=[${refusal//pid=$WAKE_PID /pid=WAKE }]"
    [[ -z "$LANE_PID" ]] || WAKE_GOT="${WAKE_GOT//pid=$LANE_PID /pid=LANE }"
    kill -KILL "$WAKE_PID" ${LANE_PID:+"$LANE_PID"} 2>/dev/null || true
  }
  WAKE_TIMEOUT='lane-close: stop-failed item=KEN-1 harness=claude target=wake pid=WAKE cause=timeout'
  # One control per rule: the exited lane's wake stop, a stale wake as a turn
  # already over, the refusal of a wake that will not end, the idle lane's
  # wake in the harness's own stop, the wake stopped after a harness stop that
  # failed, and the refusal naming the wake as its target.
  WAKE_SKIP="$(mutant lane-close-wake '  [[ -n "$host" ]] || { [[ -n "$STOP_IDENTITY" ]] || stop_wake; stop_validations; }' '  [[ -n "$host" ]] || stop_validations')"
  WAKE_STALE="$(lib_mutant wake-stale '    0|3) lane_stop_reset ;;' '    0) lane_stop_reset ;;')"
  WAKE_UNREFUSED="$(lib_mutant wake-unrefused '    *) LANE_STOP_TARGET=wake; return 1 ;;' '    *) LANE_STOP_TARGET=wake; return 0 ;;')"
  WAKE_LOCAL_SKIP="$(lib_mutant wake-local-skip '  lane_stop_wake "$4" "$5" "$6" || return 1' '  :')"
  WAKE_AFTER_FAIL_SKIP="$(lib_mutant wake-after-fail-skip '    lane_stop_wake "$4" "$5" "$6" || :' '    :')"
  WAKE_UNTARGETED="$(mutant lane-close-wake-target '      [[ "$LANE_STOP_TARGET" != wake ]] || fields+=("target=wake")' '      :')"
  # label|script|pane|wake|expected
  WAKE_ROWS=(
    "an exited lane's close stops its woken turn before it records done|$SCRIPT|exited|live|rc=0 wake=gone status=done refusal=[]"
    "a woken turn already over lets an exited lane's close go on|$SCRIPT|exited|exited|rc=0 wake=gone status=done refusal=[]"
    "a woken turn that outlives its signal refuses the close and keeps the record running|$SCRIPT|exited|ignores|rc=1 wake=alive status=running refusal=[$WAKE_TIMEOUT]"
    "an idle lane's stop ends its woken turn with its harness|$SCRIPT|idle|live|rc=0 wake=gone lane=gone status=done refusal=[]"
    "an idle lane's woken turn that outlives its signal refuses as the wake's stop|$SCRIPT|idle|ignores|rc=1 wake=alive lane=gone status=running refusal=[$WAKE_TIMEOUT]"
    "control: without the wake stop the woken turn outlives its exited lane|$WAKE_SKIP|exited|live|rc=0 wake=alive status=done refusal=[]"
    "control: a stale wake read as a failure refuses a turn already over|$WAKE_STALE|exited|exited|rc=1 wake=gone status=running refusal=[lane-close: stop-failed item=KEN-1 harness=claude target=wake pid=WAKE cause=identity-stale]"
    "control: a wake stop that fails without refusing records done over the running turn|$WAKE_UNREFUSED|exited|ignores|rc=0 wake=alive status=done refusal=[]"
    "control: a local stop that skips the wake leaves the idle lane's woken turn running|$WAKE_LOCAL_SKIP|idle|live|rc=0 wake=alive lane=gone status=done refusal=[]"
    "a stuck harness's stop still ends its woken turn and refuses as the harness's stop|$SCRIPT|stuck|live|rc=1 wake=gone lane=alive status=running refusal=[lane-close: stop-failed item=KEN-1 harness=claude pid=LANE cause=timeout]"
    "control: a harness stop that fails before the wake stop leaves the woken turn running|$WAKE_AFTER_FAIL_SKIP|stuck|live|rc=1 wake=alive lane=alive status=running refusal=[lane-close: stop-failed item=KEN-1 harness=claude pid=LANE cause=timeout]"
    "control: a refusal without its target names the wake's failure as the harness's|$WAKE_UNTARGETED|idle|ignores|rc=1 wake=alive lane=gone status=running refusal=[lane-close: stop-failed item=KEN-1 harness=claude pid=WAKE cause=timeout]"
  )
  for row in "${WAKE_ROWS[@]}"; do
    IFS='|' read -r label script pane wake want <<<"$row"
    wake_row "$script" "$pane" "$wake"
    assert_eq "$WAKE_GOT" "$want" "$label"
  done

  # The record is never done while the recorded harness lives: one that
  # outlives its signal refuses the close, its window and record kept.
  MAIL_ROOT="$LANE_ROOT" write_state running claude ""; write_panes python; claude_screen
  start_local_harness claude claude ''
  PATH="$LOCAL_PATH" LANE_CLOSE_LANE_PID="$LANE_PID" run_close "$SCRIPT"
  assert_eq "rc=$RC failed=$(grep -c "^lane-close: stop-failed item=KEN-1 harness=claude pid=$LANE_PID cause=timeout\$" <<<"$ERR" || true) lane=$(proc_state_after "$LANE_PID") kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=1 failed=1 lane=alive kill=0 status=running' 'a recorded harness that outlives its signal keeps the record running'
  kill -KILL "$LANE_PID" 2>/dev/null || true

  # Control: read under its harness name alone, the copilot lane's process is
  # none of its harness's, so the stop signals nothing and the pane outlives
  # the close.
  MAIL_ROOT="$LANE_ROOT" write_state running copilot ""; write_panes node; copilot_screen
  start_local_harness copilot MainThread
  MUTANT="$(lib_mutant copilot-name "    copilot) printf '%s\\n' '^(copilot|MainThread)\$' ;;" '')"
  PATH="$LOCAL_PATH" LANE_CLOSE_LANE_PID="$LANE_PID" ORCH_LANE_CLOSE_SECS=1 run_close "$MUTANT"
  assert_eq "rc=$RC timeout=$(grep -c '^lane-close: exit-timeout item=KEN-1 harness=copilot pane=%7 processes=0 identity=recorded$' <<<"$ERR" || true) lane=$(proc_state_after "$LANE_PID") status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=1 timeout=1 lane=alive status=running' "control: under its harness name alone a copilot lane's MainThread is never signalled"
  kill "$LANE_PID" 2>/dev/null || true

  # A record naming no harness over a pane that started the Copilot binary
  # directly, whose command then reads copilot: the pane names the harness,
  # and the stop ends the MainThread process in the worktree.
  copilot_unnamed() { # SCRIPT
    MAIL_ROOT="$LANE_ROOT" write_state running copilot ""
    jq 'del(.lanes[0].harness)' "$STATE" >"$STATE.tmp" && mv -- "$STATE.tmp" "$STATE"
    write_panes copilot; copilot_screen
    start_local_harness copilot MainThread
    PATH="$LOCAL_PATH" LANE_CLOSE_LANE_PID="$LANE_PID" run_close "$1"
  }
  copilot_unnamed "$SCRIPT"
  assert_eq "rc=$RC lane=$(proc_state_after "$LANE_PID") status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=0 lane=gone status=done' "a record naming no harness takes copilot from a pane that reads copilot"
  # Control: the pane command read without copilot leaves the harness unnamed.
  # The copy replaces the mutant tree's link to lane-close by rename, so the
  # shipped script is never written through it.
  MUTANT="$(lib_mutant copilot-pane '' '')"
  sed 's/^  claude|codex|pi|copilot) derive_identity harness "$pane_cmd" ;;$/  claude|codex|pi) derive_identity harness "$pane_cmd" ;;/' \
    "$SCRIPTS/lane-close" >"$MUTANT.copy"
  chmod +x "$MUTANT.copy"
  mv -f -- "$MUTANT.copy" "$MUTANT"
  assert_eq "$(grep -c '^  claude|codex|pi) derive_identity harness' "$MUTANT")" 1 "control: the mutant drops copilot from the pane read"
  copilot_unnamed "$MUTANT"
  assert_eq "rc=$RC refusal=$(grep -c '^lane-close: harness-unsupported item=KEN-1 harness=unknown$' <<<"$ERR" || true) lane=$(proc_state_after "$LANE_PID")" \
    'rc=1 refusal=1 lane=alive' "control: without copilot in the pane read the record's missing harness refuses"
  kill "$LANE_PID" 2>/dev/null || true

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

# A local stop with no identity to stop by refuses, naming the step, rather
# than waiting the lane out: the record names none and no harness runs under
# the pane.
write_state running claude ""; write_panes python; claude_screen
proc_table_write "$PROC_TABLE"
PATH="$LOCAL_PATH" run_close "$SCRIPT"
assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=claude cause=identity-unread$' <<<"$ERR" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 failed=1 kill=0 status=running' 'a local stop with no launch identity refuses and keeps the window'
# The process table read under the pane failing is no answer, never a pane
# with no harness under it: the refusal names the failed read.
pane_read_row() { # SCRIPT
  write_state running claude ""; write_panes python; claude_screen
  PATH="$LOCAL_PATH" PROC_TABLE="$TMP_ROOT/no-proc-table" run_close "$1"
  PANE_READ_GOT="rc=$RC failed=$(grep -c -x 'lane-close: stop-failed item=KEN-1 harness=claude cause=process-read-failed' <<<"$ERR" || true) unread=$(grep -c 'cause=identity-unread' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")"
}
pane_read_row "$SCRIPT"
assert_eq "$PANE_READ_GOT" 'rc=1 failed=1 unread=0 status=running' 'a process read that fails under the pane refuses as process-read-failed'
# Control: the failed read taking the unread cause reads as no harness.
pane_read_row "$(lib_mutant pane-read-cause '    *) lane_stop_reset; LANE_STOP_CAUSE=process-read-failed; return 1 ;;' '    *) LANE_STOP_CAUSE="$unread"; return 1 ;;')"
assert_eq "$PANE_READ_GOT" 'rc=1 failed=0 unread=1 status=running' 'control: a failed read under the pane given the unread cause reads as no harness'

echo '=== a limit banner the account has outlived does not hold a finished lane ==='
# A banner stays below the last turn of a lane it parked after the window
# resets. The account the record names settles it: room lifts a banner that
# dates no reset still ahead, and the finished lane closes like any idle one.
# A clock reset leaves the account to answer alone; a dated one, the weekly
# wall's shape, printing its year, lifts once that date is behind. The account
# is read for the model the record names, the one the launch gate judged it on,
# and over the whole account where the record names none.
while IFS='|' read -r model reset argv name; do
  write_state running claude /host; write_panes python; walled_screen "$reset"; : >"$LANE_CLOSE_LANES_CALLS"
  jq --arg model "$model" '.lanes[0].model = (if $model == "-" then null else $model end)' "$STATE" >"$STATE.next" && mv -- "$STATE.next" "$STATE"
  run_close "$SCRIPT" </dev/null
  assert_eq "rc=$RC lanes=$(cat "$LANE_CLOSE_LANES_CALLS") stop=$(stop_count KEN-1 claude) status=$(jq -r '.lanes[0].status' "$STATE")" \
    "rc=0 lanes=pick --lane /lane --harness claude$argv stop=1 status=done" "$name"
done <<'ROWS'
model|21:00| --model model|a lifted banner over an account reading room for the recorded model closes the finished lane
model|Oct 7, 2020, 11:32am (UTC)| --model model|a dated banner whose reset is behind, over an account reading room, closes the finished lane
-|21:00||a record naming no model reads the whole account
ROWS
# The account is read under the record's own host, empty for a local lane, so
# a hosted lane's wall is the copy it runs on, whatever the caller's setting.
while IFS='|' read -r host want name; do
  write_state running claude "$host"; write_panes python; walled_screen 21:00
  : >"$LANE_CLOSE_LANES_CALLS"; : >"$LANE_CLOSE_LANES_CALLS.host"
  ORCH_LANE_HOST=/other run_close "$SCRIPT" </dev/null
  assert_eq "reads=$(grep -c . "$LANE_CLOSE_LANES_CALLS" || true) host=$(cat "$LANE_CLOSE_LANES_CALLS.host")" "reads=1 host=$want" "$name"
done <<'ROWS'
/host|/host|a hosted lane's account is read under the record's host
||a local lane's account is read under no host
ROWS
# Control: a read that inherits the caller's setting reads another host's copy.
MUTANT="$(mutant lane-close-wall-host '  ORCH_LANE_HOST="$host" "$LANES" pick --lane' '  "$LANES" pick --lane')"
write_state running claude /host; write_panes python; walled_screen 21:00; : >"$LANE_CLOSE_LANES_CALLS.host"
ORCH_LANE_HOST=/other run_close "$MUTANT" </dev/null
assert_eq "host=$(cat "$LANE_CLOSE_LANES_CALLS.host")" "host=/other" \
  "control: without the record's host the wall is read under the caller's setting"
# Each reading the wall stands on refuses, naming it.
while IFS='|' read -r lanes_status reset want name; do
  write_state running claude /host; write_panes python; walled_screen "$reset"
  LANE_CLOSE_LANES_STATUS="$lanes_status" run_close "$SCRIPT" </dev/null
  assert_eq "rc=$RC live=$(grep -c "^lane-close: lane-live item=KEN-1 state=walled pane=%7 $want\$" <<<"$ERR" || true) stop=$(stop_count KEN-1 claude) status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=1 live=1 stop=0 status=running' "$name"
done <<'ROWS'
3|21:00|account=walled|a stale banner over an account still walled refuses as walled
0|Oct 7, 2099, 11:32am (Mars/Olympus)|account=room resets=unresolved|a reset in a zone this host has no zoneinfo for keeps the wall
0|Feb 30, 2099, 4pm (UTC)|account=room resets=unresolved|a dated reset date rejects keeps the wall
5|21:00|account=unmeasured|an account nothing measured leaves the banner standing
4|21:00|account=unlisted|an account no configured lane names leaves the banner standing
1|21:00|account=read-failed|a lanes read that fails leaves the banner standing
0|Oct 7, 2099, 11:32am (UTC)|account=room resets=2099-10-07T11:32:00Z|a banner dating its reset still ahead outranks a room reading
ROWS

echo '=== a failed stop keeps the lane and its record ==='
write_state running codex /host; write_panes python; codex_screen
LANE_CLOSE_STOP_STATUS=1 run_close "$SCRIPT"
assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=codex cause=provider status=1$' <<<"$ERR" || true) relay=$(grep -c '^lane-host-ssh: stop-timeout item=KEN-1$' <<<"$ERR" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) close=$(close_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 failed=1 relay=1 kill=0 close=0 status=running' 'a provider stop that fails refuses, relaying its words, and closes nothing'

write_state running codex /host; write_panes python; codex_screen
LANE_CLOSE_STOP_OUT='' run_close "$SCRIPT"
assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=codex cause=answer-unparsed$' <<<"$ERR" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 failed=1 kill=0 status=running' 'a provider stop that prints no stopped line refuses as unparsed'

echo '=== a call lane-host refused at its per-home cap changes nothing and exits 69 ==='
# STEP|VARIABLE|REMOVED: the stub fails that step with lane-host's busy
# status. The pane reads exited once the stop ran, so the close step is the
# host close. REMOVED counts the item-file removals the close made first: the
# host close runs after them, and a second close's removal finds nothing.
for row in 'stop|LANE_CLOSE_STOP_STATUS|0' 'close|LANE_CLOSE_HOST_STATUS|1' 'mail-read|LANE_CLOSE_MAIL_STATUS|0'; do
  IFS='|' read -r step var removed <<<"$row"
  write_state running claude /host; write_panes python; claude_screen
  export "$var=69"
  run_close "$SCRIPT"
  unset "$var"
  assert_eq "rc=$RC busy=$(grep -cE "^lane-close: lane-host-busy item=KEN-1 (harness=claude )?step=$step\$" <<<"$ERR" || true) failed=$(grep -cE '^lane-close: (stop-failed|mail-read-failed) ' <<<"$ERR" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE") removed=$(grep -c -x 'remove KEN-1' "$STATE_CALLS" || true)" \
    "rc=69 busy=1 failed=0 kill=0 status=running removed=$removed" "a $step lane-host refused at its cap is lane-host-busy, keeping the window and the record"
done
# The busy branch's control: without it a refused stop reads as the provider
# failing.
MUTANT="$(mutant lane-close-busy-stop '    [[ "$rc" -ne "$LANE_HOST_BUSY_EXIT" ]] || { message lane-host-busy "${fields[@]}" step=stop >&2; exit "$rc"; }
' '')"
write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_STOP_STATUS=69 run_close "$MUTANT"
assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=claude cause=provider status=69$' <<<"$ERR" || true)" 'rc=1 failed=1' \
  "control: without the busy branch a refused stop reads as the provider failing"

echo '=== a finished hosted lane whose worktree is gone closes without a stop ==='
# The provider's removed-worktree answer signals nothing, so the harness still
# runs and the pane never reads exited: the host close and the window kill are
# what end it. Under --keep-sandbox nothing would end the harness, so that
# refuses. A nonterminal item reaches the stop only with a merge cycle on its
# record, the next section's rows, which also refuse it with none.
write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_STOP_STATUS=4 run_close "$SCRIPT"
assert_eq "rc=$RC skipped=$(grep -c '^lane-close: stop-skipped item=KEN-1 harness=claude cause=worktree-removed$' <<<"$OUT" || true) stop=$(stop_count KEN-1 claude) close=$(close_call_count) kill=$(grep -c '^kill-window -t %7$' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 skipped=1 stop=1 close=1 kill=1 status=done' 'a terminal idle lane whose worktree is gone skips the stop, closes the host and window and records done'
write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_STOP_STATUS=4 run_close "$SCRIPT" --keep-sandbox
assert_eq "rc=$RC failed=$(grep -c '^lane-close: stop-failed item=KEN-1 harness=claude cause=provider status=4$' <<<"$ERR" || true) skipped=$(grep -c '^lane-close: stop-skipped ' <<<"$OUT" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 failed=1 skipped=0 kill=0 status=running' 'under --keep-sandbox the removed-worktree answer refuses, since the kept sandbox keeps the harness'

echo '=== an idle lane whose merge cycle is recorded closes while its item stays open ==='
# A merged lane whose item has been reopened after a later failed check.
# SCRIPT closes it with the record carrying pull request CYCLE's merge, or no
# cycle for -, its worktree as WHERE says:
#   hosted-gone      the close-out removed it: cat finds no .git, and the stop
#                    answers with the removed-worktree line;
#   hosted-standing  a relaunch for more work, or a lane inside its merge
#                    close-out: the .git stands and the stop would succeed;
#   hosted-unread    the .git read fails;
#   hosted-busy      lane-host refuses the read at its per-home cap;
#   local-gone       a local lane whose recorded worktree no longer exists,
#                    its harness a real process;
#   local-standing   a local lane whose recorded worktree stands.
# MERGED_OPEN reads the refusals, the skipped stop, the provider stop, the host
# close with and without --merged, the window kill, the record, the files kept
# and their removal, and a local harness's state after the close.
merged_open_row() { # SCRIPT CYCLE WHERE
  local stop=0 gitfile=gone path="$PATH" pid="" lane=-
  case "$3" in
    hosted-gone) write_state running claude /host; stop=4 ;;
    hosted-standing) write_state running claude /host; gitfile=standing ;;
    hosted-unread) write_state running claude /host; gitfile=failed ;;
    hosted-busy) write_state running claude /host; gitfile=busy ;;
    local-gone) MAIL_ROOT="$TMP_ROOT/merged-open-removed" write_state running claude "" ;;
    local-standing) MAIL_ROOT="$LANE_ROOT" write_state running claude "" ;;
    *) printf 'lane-close-test: merged-open-where-unknown where=%s\n' "$3" >&2; exit 1 ;;
  esac
  write_panes python; claude_screen
  if [[ "$2" != - ]]; then
    jq --argjson pr "$2" '.lanes[0].cycle = {pr: $pr}' "$STATE" >"$STATE.next" && mv -- "$STATE.next" "$STATE"
  fi
  if [[ "$3" == local-gone ]]; then
    start_local_harness claude
    path="$LOCAL_PATH" pid="$LANE_PID"
  fi
  LANE_CLOSE_STOP_STATUS="$stop" LANE_CLOSE_HOST_GITFILE="$gitfile" PATH="$path" LANE_CLOSE_LANE_PID="$pid" \
    LANE_CLOSE_TRACKER_STATE='In Progress' LANE_CLOSE_TRACKER_STATE_TYPE=started run_close "$1" --state-dir "$FLEET_DIR"
  if [[ -n "$pid" ]]; then
    lane="$(proc_state_after "$pid")"
    kill "$pid" 2>/dev/null || true
  fi
  MERGED_OPEN="rc=$RC busy=$(grep -c '^lane-close: lane-host-busy item=KEN-1 step=worktree-read$' <<<"$ERR" || true) live=$(grep -c '^lane-close: lane-live item=KEN-1 state=idle pane=%7$' <<<"$ERR" || true) unread=$(grep -c '^lane-close: worktree-read-failed item=KEN-1 root=/srv/worktree cause=read-failed$' <<<"$ERR" || true) skipped=$(grep -c '^lane-close: stop-skipped item=KEN-1 harness=claude cause=worktree-removed$' <<<"$OUT" || true) stop=$(stop_count KEN-1 claude) plain=$(grep -c -x 'close --item KEN-1 host=/host' "$HOST_CALLS" || true) merged=$(grep -c -x 'close --item KEN-1 --merged host=/host' "$HOST_CALLS" || true) kill=$(grep -c '^kill-window -t %7$' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE") kept=$(sed -n 's/^lane-close: item-files-kept item=KEN-1 cause=//p' <<<"$OUT") remove=$(grep -c -x -- "--state-dir $FLEET_DIR remove KEN-1" "$STATE_CALLS" || true) lane=$lane"
}
# label|cycle|where|expected
MERGED_OPEN_ROWS=(
  "a merged-cycle idle lane with an open item and no worktree closes, its item and files kept|7|hosted-gone|rc=0 busy=0 live=0 unread=0 skipped=1 stop=1 plain=1 merged=0 kill=1 status=done kept=open remove=0 lane=-"
  "the same lane with no cycle recorded refuses as live and is never stopped|-|hosted-gone|rc=1 busy=0 live=1 unread=0 skipped=0 stop=0 plain=0 merged=0 kill=0 status=running kept= remove=0 lane=-"
  "a merged-cycle idle lane whose worktree stands, relaunched or inside its close-out, refuses as live and is never stopped|7|hosted-standing|rc=1 busy=0 live=1 unread=0 skipped=0 stop=0 plain=0 merged=0 kill=0 status=running kept= remove=0 lane=-"
  "a merged-cycle idle lane whose worktree read fails refuses and is never stopped|7|hosted-unread|rc=1 busy=0 live=0 unread=1 skipped=0 stop=0 plain=0 merged=0 kill=0 status=running kept= remove=0 lane=-"
  "a merged-cycle idle lane whose worktree read lane-host refuses at its cap is lane-host-busy and is never stopped|7|hosted-busy|rc=69 busy=1 live=0 unread=0 skipped=0 stop=0 plain=0 merged=0 kill=0 status=running kept= remove=0 lane=-"
  "a merged-cycle idle local lane whose worktree stands refuses as live|7|local-standing|rc=1 busy=0 live=1 unread=0 skipped=0 stop=0 plain=0 merged=0 kill=0 status=running kept= remove=0 lane=-"
)
# A local lane whose worktree is gone is stopped as a real process, which the
# tmux stub reads from /proc.
if proc_table_readable; then
  MERGED_OPEN_ROWS+=("a merged-cycle idle local lane whose worktree is gone stops its harness and closes, its item kept|7|local-gone|rc=0 busy=0 live=0 unread=0 skipped=0 stop=0 plain=0 merged=0 kill=1 status=done kept=open remove=0 lane=gone")
fi
for row in "${MERGED_OPEN_ROWS[@]}"; do
  IFS='|' read -r label cycle where want <<<"$row"
  merged_open_row "$SCRIPT" "$cycle" "$where"
  assert_eq "$MERGED_OPEN" "$want" "$label"
done
MERGED_OPEN_CALL='      1) { record_merged && worktree_gone; } || {'
MUTANT="$(mutant lane-close-merged-open "$MERGED_OPEN_CALL" '      1) {')"
merged_open_row "$MUTANT" 7 hosted-gone
assert_eq "$(grep -o '^rc=[0-9]* busy=[0-9]* live=[0-9]*' <<<"$MERGED_OPEN")" 'rc=1 busy=0 live=1' \
  'control: without the merged-cycle acceptance a merged idle lane on an open item refuses as live'
MUTANT="$(mutant lane-close-merged-open-worktree "$MERGED_OPEN_CALL" '      1) record_merged || {')"
merged_open_row "$MUTANT" 7 hosted-standing
assert_eq "$(grep -o '^rc=[0-9]* busy=[0-9]* live=[0-9]* unread=[0-9]* skipped=[0-9]* stop=[0-9]*' <<<"$MERGED_OPEN")" 'rc=0 busy=0 live=0 unread=0 skipped=0 stop=1' \
  'control: without the worktree check a relaunched lane whose cycle stayed is stopped'
MUTANT="$(mutant lane-close-merged-open-hosted '    0 | 3) return 1 ;;' '    0 | 3) return 0 ;;')"
merged_open_row "$MUTANT" 7 hosted-standing
assert_eq "$(grep -o '^rc=[0-9]* busy=[0-9]* live=[0-9]*' <<<"$MERGED_OPEN")" 'rc=0 busy=0 live=0' \
  'control: a hosted read taking a standing .git for gone stops the lane'
MUTANT="$(mutant lane-close-merged-open-local '    [[ ! -e "$mail_root" && ! -L "$mail_root" ]]' '    :')"
merged_open_row "$MUTANT" 7 local-standing
assert_eq "$(grep -o ' live=[0-9]*' <<<"$MERGED_OPEN")" ' live=0' \
  'control: a local check that reads every worktree as gone passes the live guard'
MUTANT="$(mutant lane-close-merged-open-unread '    *) message worktree-read-failed "item=$ITEM" "root=$mail_root" "cause=read-failed" >&2; exit 1 ;;' '    *) return 0 ;;')"
merged_open_row "$MUTANT" 7 hosted-unread
assert_eq "$(grep -o '^rc=[0-9]* busy=[0-9]* live=[0-9]* unread=[0-9]* skipped=[0-9]* stop=[0-9]*' <<<"$MERGED_OPEN")" 'rc=0 busy=0 live=0 unread=0 skipped=0 stop=1' \
  'control: a failed worktree read taken as gone stops the lane'
MUTANT="$(mutant lane-close-merged-open-busy '    4) message lane-host-busy "item=$ITEM" step=worktree-read >&2; exit "$LANE_HOST_BUSY_EXIT" ;;' '')"
merged_open_row "$MUTANT" 7 hosted-busy
assert_eq "$(grep -o '^rc=[0-9]* busy=[0-9]* live=[0-9]* unread=[0-9]*' <<<"$MERGED_OPEN")" 'rc=1 busy=0 live=0 unread=1' \
  'control: without the busy arm a capped read refuses as a failed read, not lane-host-busy'

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

write_state running claude '' linear '' 'kendex:KEN-1'; write_panes bash '' other; claude_screen
LANE_CLOSE_TRACKER_STATE='In Progress' LANE_CLOSE_TRACKER_STATE_TYPE=started run_close "$SCRIPT"
assert_eq "rc=$RC missing=$(grep -c '^lane-close: pane-missing item=KEN-1 window=kendex:KEN-1$' <<<"$ERR" || true) host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 missing=1 host=0 status=running' 'a local record on an open item whose qualified window no pane carries refuses pane-missing'

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
assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE") gh=$(grep -c -F -x -- "$GH_ISSUE_READ" "$GH_CALLS" || true)" \
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
  assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE") gh=$(grep -c -F -x -- "$GH_ISSUE_READ" "$GH_CALLS" || true)" \
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

# This background launch has written no
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

echo '=== a saved selection keeps the started harness close protections ==='
# The busy selection read in launch_record_finish reaches host_launch_pending
# after open_tmux starts Codex. Run those production record writers rather
# than copy their JSON format. The fixture replaces only the state transport.
SELECTION_WRITERS="$TMP_ROOT/selection-writers.sh"
python3 - "$TEST_DIR/../scripts/open-terminal" "$SELECTION_WRITERS" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
parts = []
start = text.index("UNPARK_JQ='")
end = text.index("'\n", start) + 2
parts.append(text[start:end])
for name in ("lane_record_write", "host_launch_pending"):
    marker = f"\n{name}() {{"
    if text.count(marker) != 1:
        raise SystemExit(f"writer match count={text.count(marker)} name={name}")
    start = text.index(marker) + 1
    end = text.index("\n}\n", start) + 3
    parts.append(text[start:end])
pathlib.Path(sys.argv[2]).write_text("\n".join(parts))
PY
selection_state() ( # [WRITERS] [STEP]
  WORKFLOW_STATE="$SCRIPTS/workflow-state"
  LANE_HOST=/host LANE_ENV=CODEX_HOME=/lane HARNESS=codex RELAUNCH=false
  FLEET=true RECORD_MODE="${SELECTION_RECORD_MODE:-launch}" wt_id=KEN-1 title=KEN-1 remote_path="$MAIL_ROOT"
  [[ "$RECORD_MODE" != relaunch ]] || RELAUNCH=true
  LAUNCH_SESSION=kendex LAUNCH_PANE=%7 LAUNCH_SERVER=999 LAUNCH_HARNESS_ID=""
  LAUNCH_HARNESS=codex LAUNCH_MODEL=model LAUNCH_EFFORT=medium TERMINAL_MODE=tmux
  TRACKER=linear REPO=owner/repo CONNECTED_REPO="" PREFERENCE_ENTRY="" CAP_PASSED=""
  LAUNCH_TIER_RECORD='{}' HOST_KIND=ssh
  launched_at=2026-09-20T00:00:00Z
  host_line=$'ssh-target=host\tpath=/srv/worktree\tremote-prefix=cd /srv/worktree'
  host_pending_step="" host_pending_record=""
  source "${1:-$SELECTION_WRITERS}"
  LANE_CLOSE_STATE="$STATE" LANE_CLOSE_STATE_CALLS="$STATE_CALLS" host_launch_pending "${2:-selection}"
)
selection_close() { # SCRIPT CASE [OPTIONS...]
  local script="$1" kind="$2"
  shift 2
  write_state running codex /host linear owner/repo
  selection_state
  write_panes codex
  case "$kind" in
    live) printf '› run\n  press to interrupt\n' >"$SCREEN"; run_close "$script" "$@" ;;
    ask) codex_screen; LANE_CLOSE_MAIL_PENDING="$ASK" run_close "$script" "$@" ;;
    idle) codex_screen; run_close "$script" "$@" ;;
  esac
  SELECTION_GOT="rc=$RC stop=$(stop_count KEN-1 codex) close=$(close_call_count) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")"
}
for options in full keep; do
  selection_args=()
  [[ "$options" != keep ]] || selection_args=(--keep-sandbox)
  for kind in live ask idle; do
    selection_close "$SCRIPT" "$kind" ${selection_args[@]+"${selection_args[@]}"}
    case "$kind:$options" in
      live:*|ask:*) expected='rc=1 stop=0 close=0 kill=0 status=preparing' ;;
      idle:full) expected='rc=0 stop=1 close=1 kill=1 status=done' ;;
      idle:keep) expected='rc=0 stop=1 close=0 kill=1 status=stopped' ;;
    esac
    assert_eq "$SELECTION_GOT" "$expected" "selection $kind $options preserves its close protection"
    case "$kind" in
      live) assert_eq "$(grep -c '^lane-close: lane-live ' <<<"$ERR" || true)" 1 'the live pane reaches the live-lane guard' ;;
      ask) assert_eq "$(grep -c '^lane-close: ask-unanswered ' <<<"$ERR" || true)" 1 'the pending ask reaches the unanswered-ask guard' ;;
    esac
  done
done
# Each control preserves the changed routing and disables one protection.
# shellcheck disable=SC2016
MUTANT="$(mutant selection-live '  *) message lane-live "item=$ITEM" "state=$state" "pane=$pane_id" >&2; exit 1 ;;' '  *) : ;; # message lane-live')"
selection_close "$MUTANT" live
assert_eq "$SELECTION_GOT" 'rc=0 stop=0 close=1 kill=1 status=done' 'control: the live-lane guard prevents selection close'
# shellcheck disable=SC2016
MUTANT="$(mutant selection-ask '  refuse_unanswered_ask
  close_secs=' '  : # refuse_unanswered_ask
  close_secs=')"
selection_close "$MUTANT" ask
assert_eq "$SELECTION_GOT" 'rc=0 stop=1 close=1 kill=1 status=done' 'control: the ask guard prevents selection close'
# shellcheck disable=SC2016
MUTANT="$(mutant selection-stop '  stop_harness
  [[ "$STOP_SKIPPED"' '  : # stop_harness
  finish_close
  [[ "$STOP_SKIPPED"')"
selection_close "$MUTANT" idle --keep-sandbox
assert_eq "$SELECTION_GOT" 'rc=0 stop=0 close=0 kill=1 status=stopped' 'control: the kept selection must stop its hosted harness'

# A Codex relaunch can move accounts before the post-start selection read.
# Its old account has room; the account running the harness is still walled.
for step in marker selection; do
  write_state stopped codex /host linear owner/repo
  jq '.lanes[0] += {account:"/previous",model:"previous-model",effort:"low"}' "$STATE" >"$STATE.next"
  mv -- "$STATE.next" "$STATE"
  SELECTION_RECORD_MODE=relaunch selection_state "$SELECTION_WRITERS" "$step"
  identity="$(jq -r '.lanes[0] | [.account,.model,.effort] | join(":")' "$STATE")"
  case "$step" in
    marker) expected=/previous:previous-model:low ;;
    selection) expected=/lane:model:medium ;;
  esac
  assert_eq "$identity" "$expected" "a relaunch $step records the identity of the harness that has started"
done
for options in full keep; do
  selection_args=()
  [[ "$options" != keep ]] || selection_args=(--keep-sandbox)
  write_panes codex
  printf '%s\n' 'Usage limit reached. Increase your limits to continue.' '› run' >"$SCREEN"
  LANE_CLOSE_WALLED_ACCOUNT=/lane run_close "$SCRIPT" ${selection_args[@]+"${selection_args[@]}"}
  assert_eq "rc=$RC stop=$(stop_count KEN-1 codex) close=$(close_call_count) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=1 stop=0 close=0 kill=0 status=preparing' "a walled started selection refuses $options close on a terminal item"
  assert_eq "$(grep -c '^lane-close: lane-live item=KEN-1 state=walled pane=%7 account=walled' <<<"$ERR" || true)" 1 \
    'the limit wall is judged on the started account'
done
SELECTION_STALE_WRITERS="$TMP_ROOT/selection-stale-writers.sh"
python3 - "$SELECTION_WRITERS" "$SELECTION_STALE_WRITERS" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
old = 'if .status == "running" or .prepare.step == "selection" then . else del('
if text.count(old) != 1:
    raise SystemExit(f"identity control match count={text.count(old)}")
changed = text.replace(old, 'if .status == "running" then . else del(')
if changed == text:
    raise SystemExit("identity control did not change the writer")
pathlib.Path(sys.argv[2]).write_text(changed)
PY
write_state stopped codex /host linear owner/repo
jq '.lanes[0] += {account:"/previous",model:"previous-model",effort:"low"}' "$STATE" >"$STATE.next"
mv -- "$STATE.next" "$STATE"
SELECTION_RECORD_MODE=relaunch selection_state "$SELECTION_STALE_WRITERS"
write_panes codex
printf '%s\n' 'Usage limit reached. Increase your limits to continue.' '› run' >"$SCREEN"
LANE_CLOSE_WALLED_ACCOUNT=/lane run_close "$SCRIPT" --keep-sandbox
assert_eq "rc=$RC stop=$(stop_count KEN-1 codex) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 stop=1 kill=1 status=stopped' 'control: preserving the previous identity opens the limit-wall close guard'

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

# A hosted lane's window is only a view of its sandbox: a tmux restart that
# ended it leaves a finished item's full close to the provider alone.
write_state running claude /host; : >"$ROWS"; printf '\n' >"$SCREEN"; run_close "$SCRIPT"
assert_eq "rc=$RC stop=$(stop_count KEN-1 claude) close=$(close_call_count) window=$(grep -cE '^(new-window|kill-window) ' "$CALLS" || true) wait=$(exit_wait_count) removed=$(grep -c -x 'remove KEN-1' "$STATE_CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 stop=1 close=1 window=0 wait=0 removed=1 status=done' 'a hosted record with no pane on a terminal item closes through its provider with no exit wait'
write_state running claude /host; : >"$ROWS"; printf '\n' >"$SCREEN"
LANE_CLOSE_TRACKER_STATE='In Progress' LANE_CLOSE_TRACKER_STATE_TYPE=started run_close "$SCRIPT"
assert_eq "rc=$RC missing=$(grep -c '^lane-close: pane-missing item=KEN-1 window=KEN-1$' <<<"$ERR" || true) host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 missing=1 host=0 status=running' 'a hosted record with no pane on an open item refuses pane-missing before any host call'
write_state running claude /host; : >"$ROWS"; printf '\n' >"$SCREEN"
LANE_CLOSE_TRACKER_FAIL=3 run_close "$SCRIPT"
assert_eq "$(windowless_unread)" 'rc=1 read=1 missing=0 host=0 status=running' \
  'a hosted record with no pane whose tracker read fails refuses tracker-read-failed before any host call'
# A local lane's window gone with its item finished, a reboot among the
# causes: no pane is left to read an identity off, so a record naming none has
# no harness to stop, and the close ends the record and the item's files.
local_windowless() { # SCRIPT
  write_state running claude ''; : >"$ROWS"; printf '\n' >"$SCREEN"
  PATH="$LOCAL_PATH" run_close "$1"
  LOCAL_WINDOWLESS_GOT="rc=$RC missing=$(grep -c '^lane-close: pane-missing ' <<<"$ERR" || true) unread=$(grep -c 'cause=identity-unread' <<<"$ERR" || true) host=$(host_call_count) window=$(grep -cE '^(new-window|kill-window) ' "$CALLS" || true) wait=$(exit_wait_count) removed=$(grep -c -x 'remove KEN-1' "$STATE_CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")"
}
proc_table_write "$PROC_TABLE"
local_windowless "$SCRIPT"
assert_eq "$LOCAL_WINDOWLESS_GOT" 'rc=0 missing=0 unread=0 host=0 window=0 wait=0 removed=1 status=done' \
  'a local record with no pane and no launch identity on a terminal item closes with no exit wait'
local_windowless "$(lib_mutant no-pane '  if [[ -z "$1" ]]; then' '  if false; then')"
assert_eq "$LOCAL_WINDOWLESS_GOT" 'rc=1 missing=0 unread=1 host=0 window=0 wait=0 removed=0 status=running' \
  'control: a stop that reads a pane where none is left refuses as identity-unread'
write_state running claude ''; : >"$ROWS"; printf '\n' >"$SCREEN"
LANE_CLOSE_TRACKER_STATE='In Progress' LANE_CLOSE_TRACKER_STATE_TYPE=started run_close "$SCRIPT"
assert_eq "rc=$RC missing=$(grep -c '^lane-close: pane-missing item=KEN-1 window=KEN-1$' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 missing=1 status=running' 'a local record with no pane on an open item refuses pane-missing'
# The recorded harness can outlive its window, one renamed or moved: the
# launch identity still names it, and the close stops it.
if proc_table_readable; then
  MAIL_ROOT="$LANE_ROOT" write_state running claude ''; : >"$ROWS"; printf '\n' >"$SCREEN"
  start_local_harness claude
  PATH="$LOCAL_PATH" run_close "$SCRIPT"
  assert_eq "rc=$RC lane=$(proc_state_after "$LANE_PID") wait=$(exit_wait_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=0 lane=gone wait=0 status=done' 'a local record with no pane stops the harness its launch identity names'
  kill -KILL "$LANE_PID" 2>/dev/null || true
  # A reboot leaves the record naming a pid and start that no longer run: with
  # no pane left, that stale identity is no harness to stop either.
  stale_windowless() { # SCRIPT
    MAIL_ROOT="$LANE_ROOT" write_state running claude ''; : >"$ROWS"; printf '\n' >"$SCREEN"
    start_local_harness claude
    kill -KILL "$LANE_PID"
    while [[ "$(proc_state_after "$LANE_PID")" != gone ]]; do sleep 0.05; done
    proc_table_write "$PROC_TABLE"
    PATH="$LOCAL_PATH" run_close "$1"
    STALE_WINDOWLESS_GOT="rc=$RC stale=$(grep -c "^lane-close: stop-failed item=KEN-1 harness=claude pid=$LANE_PID cause=identity-stale\$" <<<"$ERR" || true) unread=$(grep -c 'cause=identity-unread' <<<"$ERR" || true) wait=$(exit_wait_count) removed=$(grep -c -x 'remove KEN-1' "$STATE_CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")"
  }
  stale_windowless "$SCRIPT"
  assert_eq "$STALE_WINDOWLESS_GOT" 'rc=0 stale=0 unread=0 wait=0 removed=1 status=done' \
    'a local record with no pane and a stale launch identity on a terminal item closes with no exit wait'
  stale_windowless "$(lib_mutant no-pane-stale '  if [[ -z "$1" ]]; then' '  if [[ -z "$1" && -z "$2$3" ]]; then')"
  assert_eq "$STALE_WINDOWLESS_GOT" 'rc=1 stale=1 unread=0 wait=0 removed=0 status=running' \
    'control: a windowless stop kept to records naming no identity refuses a stale one'
fi
# A window renamed, as pi-qol renames a Pi lane's to its session name, leaves
# the record's launch pane listed on the server its launch recorded: the lane
# may run there, and a record naming no live identity would stop nothing, so
# the close refuses. `ps` names the recorded server pid tmux.
SERVER_PS_BIN="$TMP_ROOT/server-ps-bin"
mkdir -p "$SERVER_PS_BIN"
REAL_PS="$(command -v ps)" || { printf 'lane-close-test: no-ps\n' >&2; exit 1; }
cat >"$SERVER_PS_BIN/ps" <<EOF
#!/usr/bin/env bash
[[ "\$*" != '-o comm= -p 999' ]] || { printf 'tmux\\n'; exit 0; }
exec "$REAL_PS" "\$@"
EOF
chmod +x "$SERVER_PS_BIN/ps"
# A record's launch identity as open-terminal writes it, hosted lanes
# included; LANE_CLOSE_TMUX_PID is the server pid the reached tmux answers.
renamed_windowless() { # SCRIPT HOST TMUX_PID
  write_state running pi "$2"
  jq '.lanes[0].launch = {pane: "%7", server: 999, pid: null, start: null}' "$STATE" >"$STATE.tmp" && mv -- "$STATE.tmp" "$STATE"
  printf 'kendex\tπ session\t%%7\t999\tpi\n' >"$ROWS"; printf '\n' >"$SCREEN"
  LANE_CLOSE_TMUX_PID="$3" PATH="$SERVER_PS_BIN:$PATH" run_close "$1"
  RENAMED_WINDOWLESS_GOT="rc=$RC renamed=$(grep -c -x 'lane-close: pane-missing item=KEN-1 window=KEN-1 pane=%7 cause=renamed' <<<"$ERR" || true) unread=$(grep -c -x 'lane-close: pane-read-failed item=KEN-1 pane=%7 server=999' <<<"$ERR" || true) stop=$(stop_count KEN-1 pi) close=$(close_call_count) kill=$(grep -c '^kill-window ' "$CALLS" || true) removed=$(grep -c -x 'remove KEN-1' "$STATE_CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")"
}
RENAMED_WINDOWLESS_ROWS=(
  "a local record whose launch pane its server still lists under another window name refuses pane-missing cause=renamed||999|rc=1 renamed=1 unread=0 stop=0 close=0 kill=0 removed=0 status=running"
  "a local record whose recorded server runs a tmux this close does not reach refuses pane-read-failed||888|rc=1 renamed=0 unread=1 stop=0 close=0 kill=0 removed=0 status=running"
  "a hosted record whose launch pane its server still lists closes through its provider|/host|999|rc=0 renamed=0 unread=0 stop=1 close=1 kill=0 removed=1 status=done"
)
for row in "${RENAMED_WINDOWLESS_ROWS[@]}"; do
  IFS='|' read -r label host_dir server_pid want <<<"$row"
  renamed_windowless "$SCRIPT" "$host_dir" "$server_pid"
  assert_eq "$RENAMED_WINDOWLESS_GOT" "$want" "$label"
done
renamed_windowless "$(mutant renamed-unread '  tmux_pane_live "$server" "" "$pane" || rc=$?' '  rc=1')" '' 999
assert_eq "$RENAMED_WINDOWLESS_GOT" 'rc=0 renamed=0 unread=0 stop=0 close=0 kill=0 removed=1 status=done' \
  'control: without the launch pane read a renamed lane closes with nothing stopped'
renamed_windowless "$(mutant renamed-other-server '    *) message pane-read-failed "item=$ITEM" "pane=$pane" "server=$server" >&2; exit 1 ;;' '    *) ;;')" '' 888
assert_eq "$RENAMED_WINDOWLESS_GOT" 'rc=0 renamed=0 unread=0 stop=0 close=0 kill=0 removed=1 status=done' \
  'control: without the read-failed arm a lane on another tmux server closes with nothing stopped'
renamed_windowless "$(mutant renamed-hosted '    0) [[ -n "$host" ]] || refuse_listed_launch_pane; state=windowless ;;' '    0) refuse_listed_launch_pane; state=windowless ;;')" /host 999
assert_eq "$RENAMED_WINDOWLESS_GOT" 'rc=1 renamed=1 unread=0 stop=0 close=0 kill=0 removed=0 status=running' \
  'control: a renamed check taken for hosted records strands a finished hosted lane'
for args in '--park --pr 7' --keep-sandbox; do
  write_state running claude /host linear owner/repo; : >"$ROWS"; printf '\n' >"$SCREEN"
  # shellcheck disable=SC2086  # the row's options are several words
  run_close "$SCRIPT" $args
  assert_eq "rc=$RC missing=$(grep -c '^lane-close: pane-missing item=KEN-1 window=KEN-1$' <<<"$ERR" || true) host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=1 missing=1 host=0 status=running' "lane-close $args on a hosted record with no pane refuses pane-missing before any host call"
done

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
echo '=== --park stops a clean merge wait: harness, window, then sandbox ==='
# The lane is working in its queue wait, its pane the Codex screen mid-turn,
# and its pull request open, armed and CLEAN with a silent reducer. The judge
# reads GitHub and the reducer before the stop; the record ends parked and
# carries the pull request and head it was judged on.
working_screen() { printf '› run\n  press to interrupt\n' >"$SCREEN"; }
park_count() { grep -c -- '^stop-sandbox --item KEN-1 host=' "$HOST_CALLS" || true; }
prwatch_count() { awk 'END { print NR + 0 }' "$LANE_CLOSE_PRWATCH_CALLS"; }
write_state running codex /host linear owner/repo; write_panes python; working_screen
run_close "$SCRIPT" --park --pr 7
# The order the judge and the stop run in is the call logs' order: the
# provider's side-effect-free check is the first host call, the queue read
# follows the view, and no stop precedes the reducer's answer.
check_count() { grep -c -- '^stop-sandbox --check --item KEN-1 host=' "$HOST_CALLS" || true; }
assert_eq "rc=$RC parked=$(grep -c '^lane-close: parked item=KEN-1 pr=7 head=abc123 status=parked$' <<<"$OUT" || true) view=$(grep -c '^pr view 7 --repo owner/repo --json ' "$GH_CALLS" || true) queue=$(grep -c '^api graphql -f query=.* -F owner=owner -F repo=repo -F number=7$' "$GH_CALLS" || true) reducer=$(grep -c '^7 repo=owner/repo$' "$LANE_CLOSE_PRWATCH_CALLS" || true) stop=$(stop_count KEN-1 codex) kill=$(grep -c '^kill-window -t %7$' "$CALLS" || true) park=$(park_count) close=$(close_call_count) status=$(jq -r '.lanes[0].status' "$STATE") parked_rec=$(jq -c '.lanes[0].parked | [.pr, .head, .repo, (.at | type)]' "$STATE") order=$(awk '{ print $1 ($2 == "--check" ? "-check" : "") }' "$HOST_CALLS" | paste -sd, -)" \
  'rc=0 parked=1 view=1 queue=1 reducer=1 stop=1 kill=1 park=1 close=0 status=parked parked_rec=[7,"abc123","owner/repo","string"] order=stop-sandbox-check,stop,stop-sandbox' \
  'a working hosted lane on an open, armed, CLEAN, silent pull request is parked: the provider checked, the harness stopped, the window closed, the sandbox stopped, the record parked with its pull request and head'

# On a merge-queue base the arm converts to the queue entry once the checks
# are green, so a queued pull request reads autoMergeRequest null for the whole
# wait, and GitHub's merge state is not read for it: the queue's own admission
# is the checks' evidence.
QUEUED='{"data":{"repository":{"pullRequest":{"isInMergeQueue":true,"mergeQueueEntry":{"position":2}}}}}'
QUEUED_VIEW='{"state":"OPEN","headRefOid":"abc123","headRefName":"ken-1","autoMergeRequest":null,"mergeStateStatus":"BLOCKED"}'
write_state running codex /host linear owner/repo; write_panes python; working_screen
LANE_CLOSE_PR_QUEUE="$QUEUED" LANE_CLOSE_PR_VIEW="$QUEUED_VIEW" run_close "$SCRIPT" --park --pr 7
assert_eq "rc=$RC parked=$(grep -c '^lane-close: parked item=KEN-1 pr=7 head=abc123 status=parked$' <<<"$OUT" || true) park=$(park_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 parked=1 park=1 status=parked' 'a queued pull request with no auto-merge request and a BLOCKED merge state is parked on the queue entry alone'

# A record naming no repository takes gh repo view's answer, and a mismatch
# with --repo is the identity refusal every option meets.
write_state running codex /host linear ''; write_panes python; working_screen
run_close "$SCRIPT" --park --pr 7
assert_eq "rc=$RC resolved=$(grep -c '^repo view --json nameWithOwner ' "$GH_CALLS" || true) view=$(grep -c '^pr view 7 --repo owner/resolved ' "$GH_CALLS" || true) reducer=$(grep -c '^7 repo=owner/resolved$' "$LANE_CLOSE_PRWATCH_CALLS" || true) repo=$(jq -r '.lanes[0].parked.repo' "$STATE")" \
  'rc=0 resolved=1 view=1 reducer=1 repo=owner/resolved' 'a record with no repository judges the pull request in the repository gh resolves for this checkout, and records it'

# An exited lane's harness is gone already: no stop, the window still closes,
# the sandbox still stops.
write_state running claude /host linear owner/repo; write_panes bash; printf '\n' >"$SCREEN"
run_close "$SCRIPT" --park --pr 7
assert_eq "rc=$RC stop=$(stop_count KEN-1 claude) kill=$(grep -c '^kill-window ' "$CALLS" || true) park=$(park_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 stop=0 kill=1 park=1 status=parked' 'an exited hosted lane is parked without a stop signal'

echo '=== --park refuses before any signal on every condition it judges ==='
# REASON|ENV|EXPECT: the environment that plants the condition, and the
# refusal's own fields. Every row leaves the lane untouched.
UNARMED='{"state":"OPEN","headRefOid":"abc123","headRefName":"ken-1","autoMergeRequest":null,"mergeStateStatus":"CLEAN"}'
BLOCKED='{"state":"OPEN","headRefOid":"abc123","headRefName":"ken-1","autoMergeRequest":{"enabledAt":"t"},"mergeStateStatus":"BLOCKED"}'
MERGED='{"state":"MERGED","headRefOid":"abc123","headRefName":"ken-1","autoMergeRequest":null,"mergeStateStatus":"UNKNOWN"}'
OTHER='{"state":"OPEN","headRefOid":"abc123","headRefName":"ken-2","autoMergeRequest":{"enabledAt":"t"},"mergeStateStatus":"CLEAN"}'
# The reducer's attention: two kinds on this pull request and one on another,
# which the refusal must not name.
printf '7\tabc123\tthreads-open\t1 unresolved\n7\tabc123\tchanges-requested\tobjection\n9\tdef\tdisarmed\t-\n' >"$TMP_ROOT/prwatch-out"
for row in \
  "not-armed|LANE_CLOSE_PR_VIEW=$UNARMED|reason=not-armed pr=7 head=abc123" \
  "merge-state|LANE_CLOSE_PR_VIEW=$BLOCKED|reason=merge-state pr=7 state=BLOCKED" \
  "pr-not-open|LANE_CLOSE_PR_VIEW=$MERGED|reason=pr-not-open pr=7 state=MERGED" \
  "pr-branch-mismatch|LANE_CLOSE_PR_VIEW=$OTHER|reason=pr-branch-mismatch pr=7 branch=ken-2" \
  "pr-read-failed|LANE_CLOSE_PR_VIEW_STATUS=1|reason=pr-read-failed pr=7 repo=owner/repo" \
  "queue-read-failed|LANE_CLOSE_PR_QUEUE_STATUS=1|reason=queue-read-failed pr=7 repo=owner/repo" \
  "queue-unparsed|LANE_CLOSE_PR_QUEUE={\"data\":null}|reason=queue-read-failed pr=7 cause=payload-unparsed" \
  "provider-unsupported|LANE_CLOSE_STOP_SANDBOX_CHECK_STATUS=2|reason=provider-unsupported host=/host exit=2" \
  "check-unparsed|LANE_CLOSE_STOP_SANDBOX_CHECK_OUT=|reason=provider-unsupported host=/host cause=answer-unparsed" \
  "attention|LANE_CLOSE_PRWATCH_RC=1;LANE_CLOSE_PRWATCH_OUT=$TMP_ROOT/prwatch-out|reason=attention pr=7 kinds=threads-open,changes-requested" \
  "reducer-failed|LANE_CLOSE_PRWATCH_RC=2|reason=reducer-failed pr=7 exit=2"; do
  IFS='|' read -r name envs expect <<<"$row"
  write_state running codex /host linear owner/repo; write_panes python; working_screen
  ( IFS=';'; for pair in $envs; do export "$pair"; done; run_close "$SCRIPT" --park --pr 7
    printf '%s\n' "$RC" >"$TMP_ROOT/park-rc"; printf '%s\n' "$ERR" >"$TMP_ROOT/park-err" )
  RC="$(cat "$TMP_ROOT/park-rc")"; ERR="$(cat "$TMP_ROOT/park-err")"
  assert_eq "rc=$RC refused=$(grep -c "^lane-close: park-refused item=KEN-1 $expect\$" <<<"$ERR" || true) stop=$(stop_count KEN-1 codex) kill=$(grep -c '^kill-window ' "$CALLS" || true) park=$(park_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=1 refused=1 stop=0 kill=0 park=0 status=running' "$name refuses the park and signals nothing"
done
# The reducer's stderr is relayed under its refusal.
assert_eq "$(grep -c '^pr-watch: read failure$' <<<"$ERR" || true)" '1' "the reducer's own words stand above reducer-failed"
# A provider without the pair, lane-host-ssh's absent-verb status, is known
# before GitHub is asked: its own line stands above the refusal and no gh call
# is made.
write_state running codex /host linear owner/repo; write_panes python; working_screen
LANE_CLOSE_STOP_SANDBOX_CHECK_STATUS=2 run_close "$SCRIPT" --park --pr 7
assert_eq "rc=$RC relay=$(grep -c '^lane-host-ssh: verb-invalid verb=stop-sandbox$' <<<"$ERR" || true) gh=$(awk 'END { print NR + 0 }' "$GH_CALLS") check=$(check_count) host=$(host_call_count)" \
  'rc=1 relay=1 gh=0 check=1 host=1' 'a provider that cannot stop a sandbox refuses the park before any GitHub read, its own words above the refusal'
# The reducer is the one OVERSEE_WATCH_PR_WATCH names, as it is for the watch.
mkdir -p "$TMP_ROOT/other-reducer"
cp -- "$PR_WATCH_STUB" "$TMP_ROOT/other-reducer/pr-watch.sh"
write_state running codex /host linear owner/repo; write_panes python; working_screen
LANE_CLOSE_PRWATCH_RC=1 LANE_CLOSE_PRWATCH_OUT="$TMP_ROOT/prwatch-out" OVERSEE_WATCH_PR_WATCH="$TMP_ROOT/other-reducer/pr-watch.sh" run_close "$SCRIPT" --park --pr 7
assert_eq "rc=$RC refused=$(grep -c '^lane-close: park-refused item=KEN-1 reason=attention pr=7 ' <<<"$ERR" || true)" 'rc=1 refused=1' \
  'the reducer OVERSEE_WATCH_PR_WATCH names is the one the judge asks'
mv -- "$PR_WATCH_STUB" "$PR_WATCH_STUB.away"
write_state running codex /host linear owner/repo; write_panes python; working_screen
OVERSEE_WATCH_PR_WATCH="$TMP_ROOT/other-reducer/pr-watch.sh" run_close "$SCRIPT" --park --pr 7
mv -- "$PR_WATCH_STUB.away" "$PR_WATCH_STUB"
assert_eq "rc=$RC parked=$(grep -c '^lane-close: parked item=KEN-1 ' <<<"$OUT" || true) missing=$(grep -c 'reason=reducer-missing' <<<"$ERR" || true)" 'rc=0 parked=1 missing=0' \
  'with the sibling reducer absent, the one OVERSEE_WATCH_PR_WATCH names still parks the lane'
# A local record has no sandbox, and a reducer that is not installed is a
# refusal too: the gate and thread reading is its alone.
write_state running codex '' linear owner/repo; write_panes python; working_screen
run_close "$SCRIPT" --park --pr 7
assert_eq "rc=$RC refused=$(grep -c '^lane-close: park-refused item=KEN-1 reason=local$' <<<"$ERR" || true) gh=$(awk 'END { print NR + 0 }' "$GH_CALLS") status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 refused=1 gh=0 status=running' 'a local lane refuses the park before reading the pull request'
mv -- "$PR_WATCH_STUB" "$PR_WATCH_STUB.away"
write_state running codex /host linear owner/repo; write_panes python; working_screen
run_close "$SCRIPT" --park --pr 7
mv -- "$PR_WATCH_STUB.away" "$PR_WATCH_STUB"
assert_eq "rc=$RC refused=$(grep -c "^lane-close: park-refused item=KEN-1 reason=reducer-missing path=" <<<"$ERR" || true) stop=$(stop_count KEN-1 codex) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 refused=1 stop=0 status=running' 'a fleet without the review-gate reducer parks nothing'
# The judge runs before the stop, so a refused park is the provider's check,
# one gh view, one queue read, no reducer call and no stop at all.
write_state running codex /host linear owner/repo; write_panes python; working_screen
LANE_CLOSE_PR_VIEW="$BLOCKED" run_close "$SCRIPT" --park --pr 7
assert_eq "check=$(check_count) host=$(host_call_count) reducer=$(prwatch_count) park=$(park_count)" 'check=1 host=1 reducer=0 park=0' 'an armed, unqueued pull request GitHub reports blocked never reaches the reducer or a stop'

echo '=== a park whose sandbox stop fails records stopped, which is what stands ==='
# The harness is gone and the window closed by then, the sandbox still up:
# --keep-sandbox's end state, recorded as such, and the refusal names why.
write_state running codex /host linear owner/repo; write_panes python; working_screen
LANE_CLOSE_STOP_SANDBOX_STATUS=1 run_close "$SCRIPT" --park --pr 7
assert_eq "rc=$RC failed=$(grep -c '^lane-close: park-failed item=KEN-1 pr=7 cause=provider status=1$' <<<"$ERR" || true) relay=$(grep -c '^lane-host-fixture: stop-sandbox-failed item=KEN-1$' <<<"$ERR" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE") parked_rec=$(jq -c '.lanes[0].parked' "$STATE")" \
  'rc=1 failed=1 relay=1 kill=1 status=stopped parked_rec=null' 'a provider that cannot stop the sandbox leaves a stopped record and refuses under its own words'
write_state running codex /host linear owner/repo; write_panes python; working_screen
LANE_CLOSE_STOP_SANDBOX_OUT='' run_close "$SCRIPT" --park --pr 7
assert_eq "rc=$RC failed=$(grep -c '^lane-close: park-failed item=KEN-1 pr=7 cause=answer-unparsed$' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 failed=1 status=stopped' 'a stop-sandbox that prints no sandbox-stopped line is not a parked sandbox'
# The check's refusal at the cap is the same transient, named as such and never
# as a provider without the pair, and nothing is read or signalled after it.
write_state running codex /host linear owner/repo; write_panes python; working_screen
LANE_CLOSE_STOP_SANDBOX_CHECK_STATUS=69 run_close "$SCRIPT" --park --pr 7
assert_eq "rc=$RC busy=$(grep -c '^lane-close: lane-host-busy item=KEN-1 pr=7 step=stop-sandbox-check$' <<<"$ERR" || true) refused=$(grep -c '^lane-close: park-refused ' <<<"$ERR" || true) gh=$(awk 'END { print NR + 0 }' "$GH_CALLS") stop=$(stop_count KEN-1 codex) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=69 busy=1 refused=0 gh=0 stop=0 status=running' 'a stop-sandbox --check lane-host refused at its cap is lane-host-busy, not a provider without the pair, and signals nothing'
write_state running codex /host linear owner/repo; write_panes python; working_screen
LANE_CLOSE_STOP_SANDBOX_STATUS=69 run_close "$SCRIPT" --park --pr 7
assert_eq "rc=$RC busy=$(grep -c '^lane-close: lane-host-busy item=KEN-1 pr=7 step=stop-sandbox$' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=69 busy=1 status=stopped' 'a stop-sandbox lane-host refused at its cap is lane-host-busy over a stopped record'
# The stopped record a failed park leaves is parked from the record alone:
# no pane, the judge again, then the sandbox.
run_close "$SCRIPT" --park --pr 7
assert_eq "rc=$RC parked=$(grep -c '^lane-close: parked item=KEN-1 pr=7 head=abc123 status=parked$' <<<"$OUT" || true) reducer=$(prwatch_count) tmux=$(awk 'END { print NR + 0 }' "$CALLS") park=$(park_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 parked=1 reducer=1 tmux=0 park=1 status=parked' 'a stopped record is parked from the record alone, judged again and without a pane'

echo '=== a parked record closes on its provider close alone, and re-parks to nothing ==='
run_close "$SCRIPT"
assert_eq "rc=$RC close=$(close_call_count) mail=$(awk 'END { print NR + 0 }' "$MAIL_CALLS") status=$(jq -r '.lanes[0].status' "$STATE") closed=$(grep -c '^lane-close: closed item=KEN-1 status=done$' <<<"$OUT" || true)" \
  'rc=0 close=1 mail=0 status=done closed=1' 'a parked record closes through the provider without reading the stopped sandbox mailbox'
write_state parked codex /host linear owner/repo
jq '.lanes[0].parked = {pr: 7, head: "abc123", repo: "owner/repo", at: "t"}' "$STATE" >"$STATE.next" && mv -- "$STATE.next" "$STATE"
run_close "$SCRIPT" --park --pr 7
assert_eq "rc=$RC parked=$(grep -c '^lane-close: parked item=KEN-1 pr=7 head=abc123 status=parked$' <<<"$OUT" || true) host=$(host_call_count) gh=$(awk 'END { print NR + 0 }' "$GH_CALLS")" \
  'rc=0 parked=1 host=0 gh=0' 'a park on a parked record changes nothing and asks nothing'
run_close "$SCRIPT" --keep-sandbox
assert_eq "rc=$RC parked=$(grep -c '^lane-close: parked item=KEN-1 ' <<<"$OUT" || true) host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 parked=1 host=0 status=parked' 'keep-sandbox on a parked record changes nothing'
write_state preparing codex /host linear owner/repo
run_close "$SCRIPT" --park --pr 7
assert_eq "rc=$RC invalid=$(grep -c '^lane-close: record-invalid item=KEN-1 field=status value=preparing$' <<<"$ERR" || true) host=$(host_call_count)" \
  'rc=1 invalid=1 host=0' 'preparation before harness start cannot park'

echo '=== the park options are refused in the shapes that name nothing ==='
write_state running codex /host linear owner/repo; write_panes python; working_screen
for row in '--park|missing-value option=--park requires=--pr' '--pr 7|missing-value option=--park requires=--pr' \
  '--park --pr 7 --keep-sandbox|argument-count value=--park conflict=--keep-sandbox' '--park --pr 07|missing-value option=--pr value=07'; do
  IFS='|' read -r args expect <<<"$row"
  # shellcheck disable=SC2086  # the row's options are several words
  run_close "$SCRIPT" $args
  assert_eq "rc=$RC refused=$(grep -c "^lane-close: $expect\$" <<<"$ERR" || true) host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
    'rc=2 refused=1 host=0 status=running' "lane-close $args is refused before any read"
done

echo '=== a stop=none kind closes its record and worktree and keeps the session ==='
cloud_state() { # [WINDOW]
  jq -n --arg root "$TMP_ROOT/cloud-wt" --arg window "${1:-}" '{lanes:[{item:"KEN-1",tracker:"linear",repo:null,harness:"claude",
    window:(if $window == "" then null else $window end),account:"/lane",
    host:"claude-cloud",kind:"claude-cloud",mail_root:$root,session_id:"session_01CLOUD",launched_at:"2026-09-20T00:00:00Z",status:"running"}]}' >"$STATE"
}
cloud_close() { # SCRIPT [ARGS...] — CLOUD_WINDOW names the record's window
  : >"$LANE_CLOSE_WORKTREE_CALLS"
  cloud_state "${CLOUD_WINDOW:-}"
  LANE_CLOSE_WORKTREE_MERGED=0 run_close "$@"
}
cloud_observed() {
  printf 'rc=%s kept=%s host=%s tmux=%s worktree=%s status=%s' "$RC" \
    "$(grep -cxF 'lane-close: host-kept kind=claude-cloud session=session_01CLOUD' <<<"$OUT" || true)" "$(host_call_count)" \
    "$(awk 'END { print NR + 0 }' "$CALLS")" "$(cat "$LANE_CLOSE_WORKTREE_CALLS")" "$(jq -r '.lanes[0].status' "$STATE")"
}
CLOUD_CLOSED="rc=0 kept=1 host=0 tmux=0 worktree=remove $TMP_ROOT/cloud-wt status=done"
cloud_close "$SCRIPT"
assert_eq "$(cloud_observed)" "$CLOUD_CLOSED" \
  'a cloud lane closes its record and local worktree, stops nothing and names the session it keeps'
# shellcheck disable=SC2016  # the script's own text, never expanded here.
MUTANT="$(mutant cloud-stop '    [[ "$PARK" != true ]] || park_judge
    [[ -z "$window_name" ]] || resolve_window' '    [[ "$PARK" != true ]] || park_judge
    ORCH_LANE_HOST="$host" "$LANE_HOST" stop --item "$ITEM" --harness claude >/dev/null
    [[ -z "$window_name" ]] || resolve_window')"
cloud_close "$MUTANT"
assert_eq "$(cloud_observed)" "rc=0 kept=1 host=1 tmux=0 worktree=remove $TMP_ROOT/cloud-wt status=done" \
  'control: a stop=none arm that calls a stop verb fails the host=0 pin'
# shellcheck disable=SC2016
MUTANT="$(mutant cloud-kept '    message host-kept "kind=$host_kind" "session=$(record_field session_id)"' '    :')"
cloud_close "$MUTANT"
assert_eq "$(cloud_observed)" "rc=0 kept=0 host=0 tmux=0 worktree=remove $TMP_ROOT/cloud-wt status=done" \
  'control: without its host-kept line the close fails the kept=1 pin alone'
# The window the launch recorded holds the session's local client and its
# lane claim, which the close ends with the record.
write_panes claude
CLOUD_WINDOW=kendex:KEN-1 cloud_close "$SCRIPT"
assert_eq "rc=$RC kill=$(grep -cx 'kill-window -t %7' "$CALLS" || true) kept=$(grep -cxF 'lane-close: host-kept kind=claude-cloud session=session_01CLOUD' <<<"$OUT" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 kill=1 kept=1 status=done' 'a cloud lane whose record names a window closes that window with the record' "$TMP_ROOT/err"
# shellcheck disable=SC2016  # the script's own text, never expanded here.
MUTANT="$(mutant cloud-window '      tmux kill-window -t "$RESOLVED_PANE" \' '      : \')"
# The stub's kill-window empties the pane list, so each close takes it anew.
write_panes claude
CLOUD_WINDOW=kendex:KEN-1 cloud_close "$MUTANT"
assert_eq "kill=$(grep -cx 'kill-window -t %7' "$CALLS" || true)" 'kill=0' \
  'control: a stop=none close that leaves the window fails the kill=1 pin'
# A removal of the item's files that refuses leaves the window standing, as
# item-files-failed says, so a second close finds it.
cloud_files_refused() { # SCRIPT
  write_panes claude
  LANE_CLOSE_REMOVE_STATUS=3 CLOUD_WINDOW=kendex:KEN-1 cloud_close "$1"
  printf 'rc=%s refused=%s kill=%s' "$RC" "$(grep -cx 'lane-close: item-files-failed item=KEN-1 status=3' <<<"$ERR" || true)" \
    "$(grep -cx 'kill-window -t %7' "$CALLS" || true)"
}
assert_eq "$(cloud_files_refused "$SCRIPT")" 'rc=1 refused=1 kill=0' \
  'a cloud close whose item files refuse to go leaves the window standing'
# shellcheck disable=SC2016  # the script's own text, never expanded here.
MUTANT="$(mutant cloud-window-order '    remove_item_files
    if [[ -n "$RESOLVED_PANE" ]]; then
      tmux kill-window -t "$RESOLVED_PANE" \
        || { message tmux-failed "item=$ITEM" "operation=kill-window" "pane=$RESOLVED_PANE" >&2; exit 1; }
    fi' '    if [[ -n "$RESOLVED_PANE" ]]; then
      tmux kill-window -t "$RESOLVED_PANE" \
        || { message tmux-failed "item=$ITEM" "operation=kill-window" "pane=$RESOLVED_PANE" >&2; exit 1; }
    fi
    remove_item_files')"
assert_eq "$(cloud_files_refused "$MUTANT")" 'rc=1 refused=1 kill=1' \
  'control: a stop=none close that kills the window before the files go fails the kill=0 pin'

echo '=== a cloud close deletes the item branch its default branch contains ==='
# A cloud session pushes its commits to origin, so the local item branch
# stays at the base tip the launch pushed, which the default branch contains
# once anything merges. The close runs the real worktree skill over a real
# repository: its remove deletes that branch on ancestry, and the record reads
# done. The tree beside the fixture links lane-close, every entry of its
# lib directory and its stubs, with the worktree skill copied in.
real_worktree_tree() { # NAME [LANE_CLOSE] — prints the tree's lane-close
  local dir="$TMP_ROOT/realwt-$1" sibling entry
  mkdir -p "$dir/skills/orch/scripts/lib" "$dir/skills/linear/scripts"
  for sibling in workflow-state lane-host lane-mail dev-validate-run lanes; do
    ln -s "$SCRIPTS/$sibling" "$dir/skills/orch/scripts/$sibling"
  done
  for entry in "$SCRIPTS"/lib/*; do
    ln -s "$entry" "$dir/skills/orch/scripts/lib/${entry##*/}"
  done
  ln -s "${2:-$SCRIPTS/lane-close}" "$dir/skills/orch/scripts/lane-close"
  ln -s "$FIXTURE/skills/linear/scripts/linear.sh" "$dir/skills/linear/scripts/linear.sh"
  cp -R "$TEST_DIR/../../worktree" "$dir/skills/worktree"
  printf '%s\n' "$dir/skills/orch/scripts/lane-close"
}
# gh answers nothing, so the item branch has no pull request on it.
QUIET_BIN="$TMP_ROOT/quiet-bin"
mkdir -p "$QUIET_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' >"$QUIET_BIN/gh"
chmod +x "$QUIET_BIN/gh"
# cloud_branch_close NAME SCRIPT WORKTREE — a repository whose item worktree ken-1 is
# made and pushed at the base tip by the WORKTREE CLI, a merge on origin's
# main after it, and the cloud record closed by SCRIPT from that repository. CLOUD_BRANCH reads what
# stands after: the close's exit, the local item branch, the worktree and
# the record's status.
cloud_branch_close() {
  local root="$TMP_ROOT/cloud-$1" wt worktree="$3"
  git init -q --bare "$root/origin.git"
  git init -q "$root/repo"
  git -C "$root/repo" symbolic-ref HEAD refs/heads/main
  git -C "$root/repo" config gc.auto 0
  git -C "$root/repo" config maintenance.auto false
  git -C "$root/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  git -C "$root/repo" remote add origin "$root/origin.git"
  git -C "$root/repo" push -q origin main
  git -C "$root/repo" fetch -q origin
  git -C "$root/repo" remote set-head origin main
  wt="$(cd "$root/repo" && PATH="$QUIET_BIN:$PATH" "$worktree" create KEN-1 2>"$root/create.err")" \
    || { cat "$root/create.err" >&2; return 1; }
  (cd "$root/repo" && PATH="$QUIET_BIN:$PATH" "$worktree" push KEN-1 --set-upstream >/dev/null 2>&1)
  git -C "$root/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'squash merge of the session branch'
  git -C "$root/repo" push -q origin main
  git -C "$root/repo" fetch -q origin
  jq -n --arg root "$wt" '{lanes:[{item:"KEN-1",tracker:"linear",repo:null,harness:"claude",window:null,account:"/lane",
    host:"claude-cloud",kind:"claude-cloud",mail_root:$root,session_id:"session_01CLOUD",launched_at:"2026-09-20T00:00:00Z",status:"running"}]}' >"$STATE"
  : >"$STATE_CALLS"
  set +e
  (cd "$root/repo" && PATH="$QUIET_BIN:$BIN:$PATH" LANE_CLOSE_STATE="$STATE" LANE_CLOSE_STATE_CALLS="$STATE_CALLS" \
    LANE_CLOSE_HOST_CALLS="$HOST_CALLS" LANE_CLOSE_TMUX_CALLS="$CALLS" "$2" KEN-1 >"$TMP_ROOT/out" 2>"$TMP_ROOT/err")
  RC=$?
  set -e
  CLOUD_BRANCH="rc=$RC branch=$(git -C "$root/repo" show-ref --verify --quiet refs/heads/ken-1 && echo kept || echo deleted) worktree=$([[ -d "$wt" ]] && echo kept || echo removed) status=$(jq -r '.lanes[0].status' "$STATE")"
}
REAL_CLOSE="$(real_worktree_tree plain)"
cloud_branch_close plain "$REAL_CLOSE" "$TMP_ROOT/realwt-plain/skills/worktree/scripts/worktree"
assert_eq "$CLOUD_BRANCH" 'rc=0 branch=deleted worktree=removed status=done' \
  'a cloud close deletes the local item branch its default branch contains and records the item done' "$TMP_ROOT/err"
# shellcheck disable=SC2016  # the script's own text, never expanded here.
MUTANT="$(mutant cloud-branch '"$WORKTREE" remove "$mail_root" >&2' 'git worktree remove --force "$mail_root" >&2')"
REAL_CLOSE="$(real_worktree_tree kept "$MUTANT")"
cloud_branch_close kept "$REAL_CLOSE" "$TMP_ROOT/realwt-kept/skills/worktree/scripts/worktree"
assert_eq "$CLOUD_BRANCH" 'rc=0 branch=kept worktree=removed status=done' \
  'control: a cloud close that removes the worktree outside the worktree skill keeps the item branch' "$TMP_ROOT/err"

echo '=== must-fail control ==='
MUTANT="$(mutant live '  *) message lane-live "item=$ITEM" "state=$state" "pane=$pane_id" >&2; exit 1 ;;' '  *) ;;')"
write_state running codex /host; write_panes python; printf '› run\n  press to interrupt\n' >"$SCREEN"; run_close "$MUTANT"
assert_eq "rc=$RC closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" 'rc=0 closed=1' 'control: removing the live-state refusal closes a working lane'
# The windowless close's three rules, each planted out on its own copy.
WINDOWLESS='[[ "$PARK" == false && "$KEEP_SANDBOX" == false ]] && tracker_terminal || tracker_rc=$?'
MUTANT="$(mutant windowless-none "$WINDOWLESS" 'false || tracker_rc=$?')"
write_state running claude /host; : >"$ROWS"; run_close "$MUTANT"
assert_eq "rc=$RC missing=$(grep -c '^lane-close: pane-missing ' <<<"$ERR" || true)" 'rc=1 missing=1' 'control: without the windowless close a hosted record with no pane refuses'
MUTANT="$(mutant windowless-hosted "$WINDOWLESS" '[[ -n "$host" && "$PARK" == false && "$KEEP_SANDBOX" == false ]] && tracker_terminal || tracker_rc=$?')"
local_windowless "$MUTANT"
assert_eq "$LOCAL_WINDOWLESS_GOT" 'rc=1 missing=1 unread=0 host=0 window=0 wait=0 removed=0 status=running' 'control: a windowless close kept to hosted records strands a finished local record at pane-missing'
MUTANT="$(mutant windowless-open "$WINDOWLESS" '[[ "$PARK" == false && "$KEEP_SANDBOX" == false ]] || tracker_rc=$?')"
write_state running claude /host; : >"$ROWS"
LANE_CLOSE_TRACKER_STATE='In Progress' LANE_CLOSE_TRACKER_STATE_TYPE=started run_close "$MUTANT"
assert_eq "rc=$RC closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" 'rc=0 closed=1' 'control: without the terminal-item gate a hosted record with no pane closes an open item'
MUTANT="$(mutant windowless-unread '    0) [[ -n "$host" ]] || refuse_listed_launch_pane; state=windowless ;;' '    0|2) [[ -n "$host" ]] || refuse_listed_launch_pane; state=windowless ;;')"
write_state running claude /host; : >"$ROWS"; printf '\n' >"$SCREEN"
LANE_CLOSE_TRACKER_FAIL=3 run_close "$MUTANT"
assert_eq "$(windowless_unread)" 'rc=0 read=0 missing=0 host=2 status=done' 'control: a failed tracker read taken as terminal closes a hosted record with no pane'
MUTANT="$(mutant windowless-wait '[[ "$STOP_SKIPPED" == false && -n "$pane_id" ]] || finish_close' '[[ "$STOP_SKIPPED" == false ]] || finish_close')"
write_state running claude /host; : >"$ROWS"; printf '\n' >"$SCREEN"; run_close "$MUTANT"
assert_eq "rc=$RC wait=$(exit_wait_count)" 'rc=0 wait=1' 'control: without the no-pane term a hosted record with no pane waits on an empty pane id'
for row in 'park|--park --pr 7|"$PARK" == false && ' 'keep|--keep-sandbox| && "$KEEP_SANDBOX" == false'; do
  IFS='|' read -r name args guard <<<"$row"
  MUTANT="$(mutant "windowless-$name" "$WINDOWLESS" "${WINDOWLESS/"$guard"/}")"
  write_state running claude /host linear owner/repo; : >"$ROWS"
  # shellcheck disable=SC2086  # the row's options are several words
  run_close "$MUTANT" $args
  assert_eq "missing=$(grep -c '^lane-close: pane-missing ' <<<"$ERR" || true)" 'missing=0' "control: without its own guard lane-close $args takes a hosted record with no pane past pane-missing"
done

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
