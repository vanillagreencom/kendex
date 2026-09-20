#!/usr/bin/env bash
# lane-close resolves one recorded pane, refuses live lanes, and closes in order.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$TEST_DIR" rev-parse --show-toplevel)"
mkdir -p "$PROJECT_ROOT/tmp"
TMP_ROOT="$(mktemp -d "$PROJECT_ROOT/tmp/lane-close.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
PASS=0
FAIL=0

ok() { printf 'ok: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL: %s\n  %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
assert_eq() { [[ "$1" == "$2" ]] && ok "$3" || bad "$3" "expected: $2 | got: $1"; }

FIXTURE="$TMP_ROOT/repo"
SCRIPTS="$FIXTURE/skills/orch/scripts"
BIN="$TMP_ROOT/bin"
STATE="$TMP_ROOT/state.json"
ROWS="$TMP_ROOT/rows"
SCREEN="$TMP_ROOT/screen"
PHASE="$TMP_ROOT/phase"
CALLS="$TMP_ROOT/calls"
HOST_CALLS="$TMP_ROOT/host-calls"
mkdir -p "$SCRIPTS/lib" "$FIXTURE/skills/linear/scripts" "$BIN"
cp "$TEST_DIR/../scripts/lane-close" "$SCRIPTS/lane-close"
cp "$TEST_DIR/../scripts/lib/lane-state.sh" "$SCRIPTS/lib/lane-state.sh"
chmod +x "$SCRIPTS/lane-close"

cat >"$SCRIPTS/workflow-state" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
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
if [[ "${LANE_CLOSE_HOST_STATUS:-0}" -ne 0 ]]; then
  [[ "$LANE_CLOSE_HOST_STATUS" -ne 3 ]] || printf 'lane-host-ssh: close-refused path=/srv/clone\n' >&2
  exit "$LANE_CLOSE_HOST_STATUS"
fi
printf 'kept=/fleet/archive/item.tgz\n'
EOF
chmod +x "$SCRIPTS/lane-host"

cat >"$FIXTURE/skills/linear/scripts/linear.sh" <<'EOF'
#!/usr/bin/env bash
[[ "${LANE_CLOSE_TRACKER_FAIL:-0}" == 0 ]] || exit "$LANE_CLOSE_TRACKER_FAIL"
printf '{"state":"%s"}\n' "${LANE_CLOSE_TRACKER_STATE:-Done}"
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
case "$1" in
  list-panes)
    count=$(cat "$LANE_CLOSE_TMUX_LIST_COUNT" 2>/dev/null || echo 0)
    count=$((count + 1)); printf '%s\n' "$count" >"$LANE_CLOSE_TMUX_LIST_COUNT"
    [[ "${LANE_CLOSE_TMUX_LIST_FAIL_AT:-0}" != "$count" ]] || exit 9
    if [[ "${*: -1}" == '#{pane_id}' ]]; then
      awk -F'\t' '{print $4}' "$LANE_CLOSE_ROWS"
    elif [[ "${*: -1}" == '#{pane_id}'$'\t''#{pane_pid}'$'\t''#{pane_current_command}' ]]; then
      awk -F'\t' '{print $4 "\t" $5 "\t" $6}' "$LANE_CLOSE_ROWS"
    else
      cat -- "$LANE_CLOSE_ROWS"
    fi ;;
  capture-pane)
    [[ "${LANE_CLOSE_CAPTURE_FAIL:-0}" == 0 ]] || exit "$LANE_CLOSE_CAPTURE_FAIL"
    case "$(cat "$LANE_CLOSE_PHASE")" in
      dialog) printf 'Exit and stop tasks\n' ;;
      exited) printf '\n' ;;
      *) cat -- "$LANE_CLOSE_SCREEN" ;;
    esac ;;
  display-message)
    [[ "${LANE_CLOSE_MODE_FAIL:-0}" == 0 ]] || exit "$LANE_CLOSE_MODE_FAIL"
    printf '%s\n' "${LANE_CLOSE_MODE:-0}" ;;
  load-buffer) cp -- "$2" "$LANE_CLOSE_BUFFER" ;;
  paste-buffer) ;;
  send-keys)
    if [[ "${*: -1}" == Enter ]]; then
      if [[ "$(cat "$LANE_CLOSE_BUFFER" 2>/dev/null || true)" == /exit ]]; then
        if [[ "$LANE_CLOSE_HARNESS" == claude ]]; then
          [[ "${LANE_CLOSE_NO_DIALOG:-0}" != 1 ]] || :
          [[ "${LANE_CLOSE_NO_DIALOG:-0}" == 1 ]] || printf 'dialog\n' >"$LANE_CLOSE_PHASE"
        elif [[ "${LANE_CLOSE_NO_EXIT:-0}" != 1 ]]; then
          printf 'exited\n' >"$LANE_CLOSE_PHASE"; sed -i 's/\tpython$/\tbash/' "$LANE_CLOSE_ROWS"
        fi
        : >"$LANE_CLOSE_BUFFER"
      elif [[ "$(cat "$LANE_CLOSE_PHASE")" == dialog && "${LANE_CLOSE_NO_EXIT:-0}" != 1 ]]; then
        printf 'exited\n' >"$LANE_CLOSE_PHASE"
        sed -i 's/\tpython$/\tbash/' "$LANE_CLOSE_ROWS"
      fi
    fi ;;
  kill-window) : >"$LANE_CLOSE_ROWS" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$BIN/tmux"

cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
[[ "${LANE_CLOSE_TRACKER_FAIL:-0}" == 0 ]] || exit "$LANE_CLOSE_TRACKER_FAIL"
printf '%s\n' "${LANE_CLOSE_GITHUB_STATE:-CLOSED}"
EOF
chmod +x "$BIN/gh"

write_state() { # STATUS HARNESS HOST [TRACKER] [REPO]
  jq -n --arg status "$1" --arg harness "$2" --arg host "$3" \
    --arg tracker "${4:-linear}" --arg repo "${5:-}" \
    '{lanes:[{item:(if $tracker == "github" then "issue-1" else "KEN-1" end),tracker:$tracker,repo:(if $repo == "" then null else $repo end),harness:$harness,window:"KEN-1",account:"/lane",host:(if $host == "" then null else $host end),mail_root:"/srv/worktree",surface:"tmux",model:"model",session_id:null,launched_at:"2026-09-20T00:00:00Z",status:$status}]}' >"$STATE"
}

write_panes() { # COMMAND [DUPLICATE]
  printf '$1\t@1\tKEN-1\t%%7\t999\t%s\n' "$1" >"$ROWS"
  if [[ "${2:-}" == duplicate ]]; then printf '$2\t@2\tKEN-1\t%%8\t998\t%s\n' "$1" >>"$ROWS"; fi
}

run_close() { # SCRIPT [ARGS...]
  local script="$1"
  shift
  : >"$CALLS"; : >"$HOST_CALLS"; : >"$PHASE"; : >"$TMP_ROOT/buffer"; : >"$TMP_ROOT/list-count"
  set +e
  OUT="$(PATH="$BIN:$PATH" LANE_CLOSE_STATE="$STATE" LANE_CLOSE_ROWS="$ROWS" \
    LANE_CLOSE_SCREEN="$SCREEN" LANE_CLOSE_PHASE="$PHASE" LANE_CLOSE_BUFFER="$TMP_ROOT/buffer" \
    LANE_CLOSE_TMUX_LIST_COUNT="$TMP_ROOT/list-count" \
    LANE_CLOSE_TMUX_CALLS="$CALLS" LANE_CLOSE_HOST_CALLS="$HOST_CALLS" \
    LANE_CLOSE_HARNESS="$(jq -r '.lanes[0].harness' "$STATE")" ORCH_LANE_CLOSE_SECS=1 \
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

echo '=== lane-close refuses ambiguous and live panes ==='
write_state running claude /host
write_panes bash duplicate
printf '\n' >"$SCREEN"
run_close "$SCRIPT"
assert_eq "rc=$RC ambiguous=$(grep -c '^lane-close: pane-ambiguous ' <<<"$ERR" || true) host=$(wc -l <"$HOST_CALLS") kills=$(grep -c '^kill-window ' "$CALLS" || true)" \
  'rc=1 ambiguous=1 host=0 kills=0' 'two panes sharing the recorded name refuse before sandbox or window close'

write_state running codex /host
write_panes python
printf '› run\n  press to interrupt\n' >"$SCREEN"
run_close "$SCRIPT"
assert_eq "rc=$RC live=$(grep -c '^lane-close: lane-live item=KEN-1 state=working pane=%7$' <<<"$ERR" || true) host=$(wc -l <"$HOST_CALLS") kills=$(grep -c '^kill-window ' "$CALLS" || true)" \
  'rc=1 live=1 host=0 kills=0' 'a working pane refuses before sandbox or window close'

echo '=== a finished hosted lane closes in one call ==='
write_state running claude /host
write_panes bash
printf '\n' >"$SCREEN"
run_close "$SCRIPT"
assert_eq "rc=$RC host=$(wc -l <"$HOST_CALLS") kill=$(grep -c '^kill-window -t %7$' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE") kept=$(grep -c '^kept=' <<<"$OUT" || true)" \
  'rc=0 host=1 kill=1 status=done kept=1' 'an exited hosted lane closes the provider once, kills by pane id and records done'

echo '=== a provider refusal stays unchanged and preserves the window ==='
write_state running claude /host
write_panes bash
printf '\n' >"$SCREEN"
LANE_CLOSE_HOST_STATUS=3 run_close "$SCRIPT"
assert_eq "rc=$RC refusal=$(grep -c '^lane-host-ssh: close-refused path=/srv/clone$' <<<"$ERR" || true) kill=$(grep -c '^kill-window ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=3 refusal=1 kill=0 status=running' 'lane-host exit 3 reaches the caller unchanged and kills nothing'

echo '=== idle harnesses exit through their own pane ==='
for harness in claude codex; do
  write_state running "$harness" /host
  write_panes python
  if [[ "$harness" == claude ]]; then printf '❯ \n' >"$SCREEN"; else printf '› \n' >"$SCREEN"; fi
  run_close "$SCRIPT"
  assert_eq "rc=$RC pasted=$(grep -c '^paste-buffer -p -d -t %7$' "$CALLS" || true) enters=$(grep -c '^send-keys -t %7 Enter$' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
    "rc=0 pasted=1 enters=$([[ "$harness" == claude ]] && echo 2 || echo 1) status=done" "$harness exits before close-out"
done

echo '=== --keep-sandbox leaves a stopped record for later close ==='
write_state running codex /host
write_panes python
printf '› \n' >"$SCREEN"
run_close "$SCRIPT" --keep-sandbox
assert_eq "rc=$RC host=$(wc -l <"$HOST_CALLS") status=$(jq -r '.lanes[0].status' "$STATE") kill=$(grep -c '^kill-window -t %7$' "$CALLS" || true)" \
  'rc=0 host=0 status=stopped kill=1' 'keep-sandbox exits the lane, removes its window and records stopped'
run_close "$SCRIPT"
assert_eq "rc=$RC host=$(wc -l <"$HOST_CALLS") status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 host=1 status=done' 'a later close removes the kept sandbox without requiring its former pane'

echo '=== tracker terminal routes close idle work ==='
for row in 'linear|Done' 'github|CLOSED'; do
  IFS='|' read -r tracker tracker_state <<<"$row"
  write_state running claude "" "$tracker" 'owner/repo'; write_panes python; printf '❯ \n' >"$SCREEN"
  if [[ "$tracker" == linear ]]; then LANE_CLOSE_TRACKER_STATE="$tracker_state" run_close "$SCRIPT"
  else LANE_CLOSE_GITHUB_STATE="$tracker_state" run_close "$SCRIPT"; fi
  assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE")" 'rc=0 status=done' \
    "$tracker terminal work closes an idle lane"
done

run_boundary() { # RULE SCRIPT
  local rule="$1" script="$2"
  case "$rule" in
    local-host) write_state running claude ""; write_panes bash; printf '\n' >"$SCREEN"; run_close "$script"
      RESULT="rc=$RC host=$(wc -l <"$HOST_CALLS") status=$(jq -r '.lanes[0].status' "$STATE")" ;;
    linear-open|github-open)
      tracker="${rule%-open}"; write_state running claude "" "$tracker" 'owner/repo'; write_panes python; printf '❯ \n' >"$SCREEN"
      if [[ "$tracker" == linear ]]; then LANE_CLOSE_TRACKER_STATE=Started run_close "$script"
      else LANE_CLOSE_GITHUB_STATE=OPEN run_close "$script"; fi
      RESULT="rc=$RC live=$(grep -c '^lane-close: lane-live .* state=idle pane=%7$' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" ;;
    capture-read) write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"; LANE_CLOSE_CAPTURE_FAIL=9 run_close "$script"
      RESULT="rc=$RC read=$(grep -c '^lane-close: pane-read-failed ' <<<"$ERR" || true) host=$(wc -l <"$HOST_CALLS")" ;;
  esac
}

echo '=== close boundaries pair normal cases with controls ==='
for rule in local-host linear-open github-open capture-read; do
  case "$rule" in
    local-host) MUTANT="$(mutant "$rule" '[[ -n "$host" ]] || return 0' '[[ -n "$host" ]] || host=/host')"; expected='rc=0 host=0 status=done|rc=0 host=1 status=done' ;;
    linear-open|github-open) MUTANT="$(mutant "$rule" '      1) message lane-live "item=$ITEM" "state=idle" "pane=$pane_id" >&2; exit 1 ;;' '      1) ;;')"; expected='rc=1 live=1 status=running|rc=0 live=0 status=done' ;;
    capture-read) MUTANT="$(mutant "$rule" 'pane_screen="$(tmux capture-pane -pJ -t "$pane_id" 2>/dev/null)" \
  || { message pane-read-failed "item=$ITEM" "pane=$pane_id" >&2; exit 1; }' 'pane_screen=""')"; expected='rc=1 read=1 host=0|rc=0 read=0 host=1' ;;
  esac
  run_boundary "$rule" "$SCRIPT"; normal="$RESULT"; run_boundary "$rule" "$MUTANT"
  assert_eq "$normal|$RESULT" "$expected" "$rule runs its normal assertion and matching control"
done

echo '=== refusal reads fail closed ==='
write_state running claude /host; write_panes python; printf '❯ \n' >"$SCREEN"
LANE_CLOSE_TRACKER_FAIL=8 run_close "$SCRIPT"
assert_eq "rc=$RC read=$(grep -c '^lane-close: tracker-read-failed ' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 read=1 status=running' 'a failed tracker read leaves the idle lane running'

write_state running claude /host; : >"$ROWS"; printf '\n' >"$SCREEN"; run_close "$SCRIPT"
assert_eq "rc=$RC missing=$(grep -c '^lane-close: pane-missing ' <<<"$ERR" || true) host=$(wc -l <"$HOST_CALLS")" \
  'rc=1 missing=1 host=0' 'a missing recorded pane refuses before provider close'

write_state running pi /host; write_panes bash; printf '\n' >"$SCREEN"; run_close "$SCRIPT"
assert_eq "rc=$RC unsupported=$(grep -c '^lane-close: harness-unsupported ' <<<"$ERR" || true) host=$(wc -l <"$HOST_CALLS")" \
  'rc=1 unsupported=1 host=0' 'a harness with no close path refuses before provider close'

write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"
LANE_CLOSE_TMUX_LIST_FAIL_AT=1 run_close "$SCRIPT"
assert_eq "rc=$RC read=$(grep -c '^lane-close: pane-read-failed ' <<<"$ERR" || true) host=$(wc -l <"$HOST_CALLS")" \
  'rc=1 read=1 host=0' 'an initial tmux pane read failure closes nothing'

write_state running codex /host; write_panes python; printf '› \n' >"$SCREEN"
LANE_CLOSE_MODE_FAIL=7 run_close "$SCRIPT"
assert_eq "rc=$RC tmux=$(grep -c '^lane-close: tmux-failed .* operation=submit-exit' <<<"$ERR" || true) host=$(wc -l <"$HOST_CALLS")" \
  'rc=1 tmux=1 host=0' 'a tmux mode read failure submits nothing and closes nothing'

echo '=== exit and finalization failures keep the record nonterminal ==='
write_state running claude /host; write_panes python; printf '❯ \n' >"$SCREEN"
LANE_CLOSE_NO_DIALOG=1 run_close "$SCRIPT"
assert_eq "rc=$RC timeout=$(grep -c '^lane-close: exit-dialog-missing ' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 timeout=1 status=running' 'Claude must show its exit dialog before confirmation'

write_state running claude /host; write_panes python; printf '❯ \n' >"$SCREEN"
LANE_CLOSE_NO_EXIT=1 run_close "$SCRIPT"
assert_eq "rc=$RC timeout=$(grep -c '^lane-close: exit-timeout ' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 timeout=1 status=running' 'a harness that does not exit before the bound keeps its record running'

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
echo '=== must-fail controls ==='
MUTANT="$(mutant ambiguous '  *) message pane-ambiguous "item=$ITEM" "window=$window_name" "count=$pane_count" >&2; exit 1 ;;' '  *) pane_count=1 ;;')"
write_state running claude /host; write_panes bash duplicate; printf '\n' >"$SCREEN"; run_close "$MUTANT"
assert_eq "rc=$RC closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" 'rc=0 closed=1' 'control: removing the ambiguity refusal closes the wrong pane'
MUTANT="$(mutant live '  *) message lane-live "item=$ITEM" "state=$state" "pane=$pane_id" >&2; exit 1 ;;' '  *) ;;')"
write_state running codex /host; write_panes python; printf '› run\n  press to interrupt\n' >"$SCREEN"; run_close "$MUTANT"
assert_eq "rc=$RC closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" 'rc=0 closed=1' 'control: removing the live-state refusal closes a working lane'
MUTANT="$(mutant provider 'if [[ "$KEEP_SANDBOX" != true ]]; then close_host || exit $?; fi' 'if [[ "$KEEP_SANDBOX" != true ]]; then close_host || :; fi')"
write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"; LANE_CLOSE_HOST_STATUS=3 run_close "$MUTANT"
assert_eq "rc=$RC kill=$(grep -c '^kill-window -t %7$' "$CALLS" || true)" 'rc=0 kill=1' 'control: ignoring provider exit 3 destroys the window'
MUTANT="$(mutant pane-id '  0) tmux kill-window -t "$pane_id" \' '  0) tmux kill-window -t "$window_name" \')"
write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"; run_close "$MUTANT"
assert_eq "pane=$(grep -c '^kill-window -t %7$' "$CALLS" || true) name=$(grep -c '^kill-window -t KEN-1$' "$CALLS" || true)" \
  'pane=0 name=1' 'control: replacing the pane id makes the test observe the unsafe window-name target'
MUTANT="$(mutant tracker-read '      *) message tracker-read-failed "item=$ITEM" "tracker=${tracker:-unknown}" >&2; exit 1 ;;' '      *) ;;')"
write_state running claude /host; write_panes python; printf '❯ \n' >"$SCREEN"; LANE_CLOSE_TRACKER_FAIL=8 run_close "$MUTANT"
assert_eq "rc=$RC closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" 'rc=0 closed=1' \
  'control: ignoring a failed tracker read closes an idle lane whose work state is unknown'
MUTANT="$(mutant missing '  0) message pane-missing "item=$ITEM" "window=$window_name" >&2; exit 1 ;;' '  0) ;;')"
write_state running claude /host; : >"$ROWS"; printf '\n' >"$SCREEN"; run_close "$MUTANT"
assert_eq "missing=$(grep -c '^lane-close: pane-missing ' <<<"$ERR" || true) read=$(grep -c '^lane-close: pane-read-failed ' <<<"$ERR" || true)" \
  'missing=0 read=1' 'control: removing the missing-pane guard loses its required refusal reason'
MUTANT="$(mutant harness '[[ "$harness" == claude || "$harness" == codex ]] \' '[[ "$harness" == claude || "$harness" == codex || "$harness" == pi ]] \')"
write_state running pi /host; write_panes bash; printf '\n' >"$SCREEN"; run_close "$MUTANT"
assert_eq "rc=$RC closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" 'rc=0 closed=1' \
  'control: accepting an unsupported harness closes it through an undefined path'
MUTANT="$(mutant list-read '  || { message pane-read-failed "item=$ITEM" >&2; exit 1; }' '  || rows=""')"
write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"; LANE_CLOSE_TMUX_LIST_FAIL_AT=1 run_close "$MUTANT"
assert_eq "read=$(grep -c '^lane-close: pane-read-failed ' <<<"$ERR" || true) missing=$(grep -c '^lane-close: pane-missing ' <<<"$ERR" || true)" \
  'read=0 missing=1' 'control: ignoring the initial pane read failure misreports a missing pane'
MUTANT="$(mutant mode $'  local mode\n''  mode="$(tmux display-message -p -t "$pane_id" '\''#{pane_in_mode}'\'' 2>/dev/null)" || return 1' $'  local mode\n''  mode="$(tmux display-message -p -t "$pane_id" '\''#{pane_in_mode}'\'' 2>/dev/null)" || mode=0')"
write_state running codex /host; write_panes python; printf '› \n' >"$SCREEN"; LANE_CLOSE_MODE_FAIL=7 run_close "$MUTANT"
assert_eq "rc=$RC closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" 'rc=0 closed=1' \
  'control: treating a failed mode read as normal submits and closes the lane'
MUTANT="$(mutant dialog '    [[ "$dialog" == true ]] \' '    true \')"
write_state running claude /host; write_panes python; printf '❯ \n' >"$SCREEN"; LANE_CLOSE_NO_DIALOG=1 run_close "$MUTANT"
assert_eq "dialog=$(grep -c '^lane-close: exit-dialog-missing ' <<<"$ERR" || true) timeout=$(grep -c '^lane-close: exit-timeout ' <<<"$ERR" || true)" \
  'dialog=0 timeout=1' 'control: removing the dialog guard loses the dialog refusal and waits on an exit never confirmed'
MUTANT="$(mutant exit-timeout '    1) message exit-timeout "item=$ITEM" "harness=$harness" "pane=$pane_id" >&2; exit 1 ;;' '    1) ;;')"
write_state running claude /host; write_panes python; printf '❯ \n' >"$SCREEN"; LANE_CLOSE_NO_EXIT=1 run_close "$MUTANT"
assert_eq "rc=$RC closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" 'rc=0 closed=1' \
  'control: removing the exit timeout closes a lane whose harness still runs'
MUTANT="$(mutant stopped-provider '  close_host || exit $?' '  close_host || :')"
write_state stopped claude /host; : >"$ROWS"; printf '\n' >"$SCREEN"; LANE_CLOSE_HOST_STATUS=9 run_close "$MUTANT"
assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE")" 'rc=0 status=done' \
  'control: ignoring a stopped provider failure records the sandbox done'
MUTANT="$(mutant state-write '  || { message state-write-failed "item=$ITEM" "status=$next_status" >&2; exit 1; }' '  || :')"
write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"; LANE_CLOSE_STATE_WRITE_FAIL=6 run_close "$MUTANT"
assert_eq "rc=$RC closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" 'rc=0 closed=1' \
  'control: ignoring the state write failure reports a done record that was never written'

MUTANT="$(mutant late-read '  listed="$(tmux list-panes -a -F '\''#{pane_id}'\'' 2>/dev/null)" || return 2' '  listed="$(tmux list-panes -a -F '\''#{pane_id}'\'' 2>/dev/null)" || return 1')"
write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"; LANE_CLOSE_TMUX_LIST_FAIL_AT=2 run_close "$MUTANT"
assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE")" 'rc=0 status=done' \
  'control: treating a late pane read failure as absence records done while the window remains'

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
