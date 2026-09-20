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
host_call_count() { awk 'END { print NR + 0 }' "$HOST_CALLS"; }
state_call_count() { awk -v p="$1" 'index($0, p) == 1 { c++ } END { print c + 0 }' "$STATE_CALLS"; }

# The screens a lane is read from. Claude Code draws its composer as the
# marker then U+00A0, draft or not; Codex's empty and drafted composers are the
# byte-exact captures the watch suites already measure.
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
      awk -F'\t' '{print $3}' "$LANE_CLOSE_ROWS"
    elif [[ "${*: -1}" == '#{pane_id}'$'\t''#{pane_pid}'$'\t''#{pane_current_command}' ]]; then
      awk -F'\t' '{print $3 "\t" $4 "\t" $5}' "$LANE_CLOSE_ROWS"
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
          printf 'exited\n' >"$LANE_CLOSE_PHASE"
          sed 's/\tpython$/\tbash/' "$LANE_CLOSE_ROWS" >"$LANE_CLOSE_ROWS.next"
          mv -- "$LANE_CLOSE_ROWS.next" "$LANE_CLOSE_ROWS"
        fi
        : >"$LANE_CLOSE_BUFFER"
      elif [[ "$(cat "$LANE_CLOSE_PHASE")" == dialog && "${LANE_CLOSE_NO_EXIT:-0}" != 1 ]]; then
        printf 'exited\n' >"$LANE_CLOSE_PHASE"
        sed 's/\tpython$/\tbash/' "$LANE_CLOSE_ROWS" >"$LANE_CLOSE_ROWS.next"
        mv -- "$LANE_CLOSE_ROWS.next" "$LANE_CLOSE_ROWS"
      fi
    fi ;;
  kill-window) : >"$LANE_CLOSE_ROWS" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$BIN/tmux"

cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LANE_CLOSE_GH_CALLS"
[[ "${LANE_CLOSE_TRACKER_FAIL:-0}" == 0 ]] || exit "$LANE_CLOSE_TRACKER_FAIL"
printf '%s\n' "${LANE_CLOSE_GITHUB_STATE:-CLOSED}"
EOF
chmod +x "$BIN/gh"

write_state() { # STATUS HARNESS HOST [TRACKER] [REPO] [WINDOW]
  jq -n --arg status "$1" --arg harness "$2" --arg host "$3" \
    --arg tracker "${4:-linear}" --arg repo "${5:-}" --arg window "${6:-KEN-1}" \
    '{lanes:[{item:(if $tracker == "github" then "issue-1" else "KEN-1" end),tracker:$tracker,repo:(if $repo == "" then null else $repo end),harness:$harness,window:$window,account:"/lane",host:(if $host == "" then null else $host end),mail_root:"/srv/worktree",surface:"tmux",model:"model",session_id:null,launched_at:"2026-09-20T00:00:00Z",status:$status}]}' >"$STATE"
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
# TEXT after the marker: nothing, a draft, or the trailing blanks tmux pads the
# drawn row with. `codex_screen [idle|draft]` is the measured Codex capture.
claude_screen() { printf '%s%s\n' "$CLAUDE_COMPOSER" "${1:-}" >"$SCREEN"; }
codex_screen() { cp -- "$PANE_FIXTURES/codex-composer-${1:-idle}.txt" "$SCREEN"; }

run_close() { # SCRIPT [ARGS...]
  local script="$1" harness prev="" arg
  shift
  # The harness the stub imitates is the one this run closes with, resolved the
  # way the script resolves it: the record's, and the --harness option only
  # where the record carries none, in either spelling the parser takes.
  harness="$(jq -r '.lanes[0].harness // empty' "$STATE")"
  if [[ -z "$harness" ]]; then
    for arg in "$@"; do
      [[ "$prev" != --harness ]] || harness="$arg"
      [[ "$arg" != --harness=* ]] || harness="${arg#--harness=}"
      prev="$arg"
    done
  fi
  : >"$CALLS"; : >"$HOST_CALLS"; : >"$GH_CALLS"; : >"$STATE_CALLS"; : >"$PHASE"; : >"$TMP_ROOT/buffer"; : >"$TMP_ROOT/list-count"
  set +e
  OUT="$(PATH="$BIN:$PATH" LANE_CLOSE_STATE="$STATE" LANE_CLOSE_ROWS="$ROWS" \
    LANE_CLOSE_SCREEN="$SCREEN" LANE_CLOSE_PHASE="$PHASE" LANE_CLOSE_BUFFER="$TMP_ROOT/buffer" \
    LANE_CLOSE_TMUX_LIST_COUNT="$TMP_ROOT/list-count" \
    LANE_CLOSE_TMUX_CALLS="$CALLS" LANE_CLOSE_HOST_CALLS="$HOST_CALLS" LANE_CLOSE_GH_CALLS="$GH_CALLS" \
    LANE_CLOSE_STATE_CALLS="$STATE_CALLS" \
    LANE_CLOSE_HARNESS="$harness" ORCH_LANE_CLOSE_SECS=1 \
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
  if [[ "$harness" == claude ]]; then claude_screen; else codex_screen; fi
  run_close "$SCRIPT"
  assert_eq "rc=$RC pasted=$(grep -c '^paste-buffer -p -d -t %7$' "$CALLS" || true) enters=$(grep -c '^send-keys -t %7 Enter$' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
    "rc=0 pasted=1 enters=$([[ "$harness" == claude ]] && echo 2 || echo 1) status=done" "$harness exits before close-out"
done

echo '=== --keep-sandbox leaves a stopped record for later close ==='
write_state running codex /host
write_panes python
codex_screen
run_close "$SCRIPT" --keep-sandbox
assert_eq "rc=$RC host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE") kill=$(grep -c '^kill-window -t %7$' "$CALLS" || true)" \
  'rc=0 host=0 status=stopped kill=1' 'keep-sandbox exits the lane, removes its window and records stopped'
run_close "$SCRIPT"
assert_eq "rc=$RC host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=0 host=1 status=done' 'a later close removes the kept sandbox without requiring its former pane'

echo '=== tracker terminal routes close idle work ==='
for row in 'linear|Done' 'github|CLOSED'; do
  IFS='|' read -r tracker tracker_state <<<"$row"
  write_state running claude "" "$tracker" 'owner/repo'; write_panes python; claude_screen
  if [[ "$tracker" == linear ]]; then LANE_CLOSE_TRACKER_STATE="$tracker_state" run_close "$SCRIPT"
  else LANE_CLOSE_GITHUB_STATE="$tracker_state" run_close "$SCRIPT"; fi
  assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE")" 'rc=0 status=done' \
    "$tracker terminal work closes an idle lane"
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
assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE") pasted=$(grep -c '^paste-buffer -p -d -t %7$' "$CALLS" || true)" \
  'rc=0 status=done pasted=1' 'launch options supply the identity an idle legacy record lacks'

write_legacy_state running /host; write_panes python; claude_screen
run_close "$SCRIPT"
assert_eq "rc=$RC read=$(grep -c '^lane-close: tracker-read-failed item=KEN-1 tracker=unknown$' <<<"$ERR" || true) option=$(grep -c -- '--tracker linear' <<<"$ERR" || true) host=$(host_call_count)" \
  'rc=1 read=1 option=1 host=0' 'an idle legacy record with no options refuses and names the tracker option'

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

write_state running claude /host; write_panes python; claude_screen '   '
run_close "$SCRIPT"
assert_eq "rc=$RC status=$(jq -r '.lanes[0].status' "$STATE") pasted=$(grep -c '^paste-buffer -p -d -t %7$' "$CALLS" || true)" \
  'rc=0 status=done pasted=1' 'a composer row tmux padded with trailing blanks closes like the unpadded one'

write_state running claude /host; write_panes python; claude_screen
run_close "$SCRIPT" --harness codex
assert_eq "rc=$RC invalid=$(grep -c '^lane-close: record-invalid item=KEN-1 field=harness recorded=claude option=codex$' <<<"$ERR" || true) typed=$(grep -cE '^(load-buffer|paste-buffer|send-keys) ' "$CALLS" || true)" \
  'rc=1 invalid=1 typed=0' 'an option contradicting a recorded field refuses record-invalid and types nothing'

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

echo '=== a composer holding a draft is never typed into ==='
write_state running claude /host; write_panes python; claude_screen 'finish this later'
run_close "$SCRIPT"
assert_eq "rc=$RC draft=$(grep -c '^lane-close: composer-draft item=KEN-1 pane=%7 harness=claude$' <<<"$ERR" || true) typed=$(grep -cE '^(load-buffer|paste-buffer|send-keys) ' "$CALLS" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 draft=1 typed=0 status=running' 'a drafted Claude composer refuses and types nothing'

write_state running codex /host; write_panes python; codex_screen draft
run_close "$SCRIPT"
assert_eq "rc=$RC draft=$(grep -c '^lane-close: composer-draft item=KEN-1 pane=%7 harness=codex$' <<<"$ERR" || true) typed=$(grep -cE '^(load-buffer|paste-buffer|send-keys) ' "$CALLS" || true)" \
  'rc=1 draft=1 typed=0' 'a drafted Codex composer refuses and types nothing'

write_state running claude /host; write_panes python; printf '\xe2\x9d\xaf hello\n' >"$SCREEN"
run_close "$SCRIPT"
assert_eq "rc=$RC unreadable=$(grep -c '^lane-close: composer-unreadable item=KEN-1 pane=%7 harness=claude$' <<<"$ERR" || true) typed=$(grep -cE '^(load-buffer|paste-buffer|send-keys) ' "$CALLS" || true)" \
  'rc=1 unreadable=1 typed=0' 'a live input line matching neither composer refuses rather than guess'

run_boundary() { # RULE SCRIPT
  local rule="$1" script="$2"
  case "$rule" in
    local-host) write_state running claude ""; write_panes bash; printf '\n' >"$SCREEN"; run_close "$script"
      RESULT="rc=$RC host=$(host_call_count) status=$(jq -r '.lanes[0].status' "$STATE")" ;;
    linear-open|github-open)
      tracker="${rule%-open}"; write_state running claude "" "$tracker" 'owner/repo'; write_panes python; claude_screen
      if [[ "$tracker" == linear ]]; then LANE_CLOSE_TRACKER_STATE=Started run_close "$script"
      else LANE_CLOSE_GITHUB_STATE=OPEN run_close "$script"; fi
      RESULT="rc=$RC live=$(grep -c '^lane-close: lane-live .* state=idle pane=%7$' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" ;;
    capture-read) write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"; LANE_CLOSE_CAPTURE_FAIL=9 run_close "$script"
      RESULT="rc=$RC read=$(grep -c '^lane-close: pane-read-failed ' <<<"$ERR" || true) host=$(host_call_count)" ;;
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
write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_TRACKER_FAIL=8 run_close "$SCRIPT"
assert_eq "rc=$RC read=$(grep -c '^lane-close: tracker-read-failed ' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 read=1 status=running' 'a failed tracker read leaves the idle lane running'

write_state running claude /host; : >"$ROWS"; printf '\n' >"$SCREEN"; run_close "$SCRIPT"
assert_eq "rc=$RC missing=$(grep -c '^lane-close: pane-missing ' <<<"$ERR" || true) host=$(host_call_count)" \
  'rc=1 missing=1 host=0' 'a missing recorded pane refuses before provider close'

write_state running pi /host; write_panes python; claude_screen; run_close "$SCRIPT"
assert_eq "rc=$RC unsupported=$(grep -c '^lane-close: harness-unsupported ' <<<"$ERR" || true) host=$(host_call_count)" \
  'rc=1 unsupported=1 host=0' 'a harness with no close path refuses before provider close'

write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"
LANE_CLOSE_TMUX_LIST_FAIL_AT=1 run_close "$SCRIPT"
assert_eq "rc=$RC read=$(grep -c '^lane-close: pane-read-failed ' <<<"$ERR" || true) host=$(host_call_count)" \
  'rc=1 read=1 host=0' 'an initial tmux pane read failure closes nothing'

write_state running codex /host; write_panes python; codex_screen
LANE_CLOSE_MODE_FAIL=7 run_close "$SCRIPT"
assert_eq "rc=$RC tmux=$(grep -c '^lane-close: tmux-failed .* operation=submit-exit' <<<"$ERR" || true) host=$(host_call_count)" \
  'rc=1 tmux=1 host=0' 'a tmux mode read failure submits nothing and closes nothing'

echo '=== exit and finalization failures keep the record nonterminal ==='
write_state running claude /host; write_panes python; claude_screen
LANE_CLOSE_NO_DIALOG=1 run_close "$SCRIPT"
assert_eq "rc=$RC timeout=$(grep -c '^lane-close: exit-dialog-missing ' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 timeout=1 status=running' 'Claude must show its exit dialog before confirmation'

write_state running claude /host; write_panes python; claude_screen
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
MUTANT="$(mutant ambiguous '  *) message pane-ambiguous "item=$ITEM" "window=$window_name" "count=$LANE_PANE_COUNT" >&2; exit 1 ;;' '  *) ;;')"
write_state running claude /host; write_panes bash duplicate; printf '\n' >"$SCREEN"; run_close "$MUTANT"
assert_eq "ambiguous=$(grep -c '^lane-close: pane-ambiguous ' <<<"$ERR" || true) live=$(grep -c '^lane-close: lane-live .* state=unjudged ' <<<"$ERR" || true)" \
  'ambiguous=0 live=1' 'control: removing the ambiguity refusal loses its reason, leaving an unresolved pane reported as unjudged'
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
write_state running claude /host; write_panes python; claude_screen; LANE_CLOSE_TRACKER_FAIL=8 run_close "$MUTANT"
assert_eq "rc=$RC closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" 'rc=0 closed=1' \
  'control: ignoring a failed tracker read closes an idle lane whose work state is unknown'
MUTANT="$(mutant missing '  0) message pane-missing "item=$ITEM" "window=$window_name" >&2; exit 1 ;;' '  0) ;;')"
write_state running claude /host; : >"$ROWS"; printf '\n' >"$SCREEN"; run_close "$MUTANT"
assert_eq "missing=$(grep -c '^lane-close: pane-missing ' <<<"$ERR" || true) live=$(grep -c '^lane-close: lane-live .* state=unjudged ' <<<"$ERR" || true)" \
  'missing=0 live=1' 'control: removing the missing-pane guard loses its required refusal reason'
MUTANT="$(mutant harness '[[ "$harness" == claude || "$harness" == codex ]] \' '[[ "$harness" == claude || "$harness" == codex || "$harness" == pi ]] \')"
write_state running pi /host; write_panes python; claude_screen; run_close "$MUTANT"
assert_eq "rc=$RC closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" 'rc=0 closed=1' \
  'control: accepting an unsupported harness closes it through an undefined path'
MUTANT="$(mutant list-read '  || { message pane-read-failed "item=$ITEM" "window=$window_name" >&2; exit 1; }' '  || :')"
write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"; LANE_CLOSE_TMUX_LIST_FAIL_AT=1 run_close "$MUTANT"
assert_eq "read=$(grep -c '^lane-close: pane-read-failed ' <<<"$ERR" || true) missing=$(grep -c '^lane-close: pane-missing ' <<<"$ERR" || true)" \
  'read=0 missing=1' 'control: ignoring the initial pane read failure misreports a missing pane'
MUTANT="$(mutant mode $'  local mode\n''  mode="$(tmux display-message -p -t "$pane_id" '\''#{pane_in_mode}'\'' 2>/dev/null)" || return 1' $'  local mode\n''  mode="$(tmux display-message -p -t "$pane_id" '\''#{pane_in_mode}'\'' 2>/dev/null)" || mode=0')"
write_state running codex /host; write_panes python; codex_screen; LANE_CLOSE_MODE_FAIL=7 run_close "$MUTANT"
assert_eq "rc=$RC closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" 'rc=0 closed=1' \
  'control: treating a failed mode read as normal submits and closes the lane'
MUTANT="$(mutant dialog '    [[ "$dialog" == true ]] \' '    true \')"
write_state running claude /host; write_panes python; claude_screen; LANE_CLOSE_NO_DIALOG=1 run_close "$MUTANT"
assert_eq "dialog=$(grep -c '^lane-close: exit-dialog-missing ' <<<"$ERR" || true) timeout=$(grep -c '^lane-close: exit-timeout ' <<<"$ERR" || true)" \
  'dialog=0 timeout=1' 'control: removing the dialog guard loses the dialog refusal and waits on an exit never confirmed'
MUTANT="$(mutant exit-timeout '    1) message exit-timeout "item=$ITEM" "harness=$harness" "pane=$pane_id" >&2; exit 1 ;;' '    1) ;;')"
write_state running claude /host; write_panes python; claude_screen; LANE_CLOSE_NO_EXIT=1 run_close "$MUTANT"
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

MUTANT="$(mutant state-dir '    --state-dir) need_value "$@"; STATE_DIR="$2"; shift 2 ;;' '    --state-dir) need_value "$@"; shift 2 ;;')"
write_state running claude /host; write_panes bash; printf '\n' >"$SCREEN"; run_close "$MUTANT" --state-dir "$FLEET_DIR"
assert_eq "closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true) named=$(state_call_count "--state-dir $FLEET_DIR ")" \
  'closed=1 named=0' 'control: discarding the --state-dir value closes against the default state, naming the directory in no call'

MUTANT="$(mutant identity $'    message record-invalid "item=$ITEM" "field=$2" "recorded=$recorded" "option=$supplied" >&2\n''    exit 1' '    :')"
write_state running claude /host; write_panes python; claude_screen; run_close "$MUTANT" --harness codex
assert_eq "rc=$RC invalid=$(grep -c '^lane-close: record-invalid ' <<<"$ERR" || true) closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true) enters=$(grep -c '^send-keys -t %7 Enter$' "$CALLS" || true)" \
  'rc=0 invalid=0 closed=1 enters=2' 'control: dropping the identity conflict refusal closes the lane on the record it contradicts'

MUTANT="$(mutant composer-unreadable '    *) message composer-unreadable "item=$ITEM" "pane=$pane_id" "harness=$harness" >&2; exit 1 ;;' '    *) ;;')"
write_state running claude /host; write_panes python; printf '\xe2\x9d\xaf hello\n' >"$SCREEN"; run_close "$MUTANT"
assert_eq "unreadable=$(grep -c '^lane-close: composer-unreadable ' <<<"$ERR" || true) pasted=$(grep -c '^paste-buffer -p -d -t %7$' "$CALLS" || true)" \
  'unreadable=0 pasted=1' 'control: removing the unreadable-composer refusal types /exit into a pane nothing measured'

MUTANT="$(mutant repo-value '    --repo) need_value "$@"; OPT_REPO="$2"; shift 2 ;;' '    --repo) need_value "$@"; shift 2 ;;')"
write_legacy_state running /host issue-1; write_panes python; claude_screen
run_close "$MUTANT" --harness claude --tracker github --repo owner/repo
assert_eq "rc=$RC read=$(grep -c '^lane-close: tracker-read-failed ' <<<"$ERR" || true) status=$(jq -r '.lanes[0].status' "$STATE")" \
  'rc=1 read=1 status=running' 'control: discarding the --repo value leaves the GitHub lane unclosable'

MUTANT="$(mutant composer '    1) message composer-draft "item=$ITEM" "pane=$pane_id" "harness=$harness" >&2; exit 1 ;;' '    1) ;;')"
write_state running claude /host; write_panes python; claude_screen 'finish this later'; run_close "$MUTANT"
assert_eq "rc=$RC typed=$(grep -c '^paste-buffer -p -d -t %7$' "$CALLS" || true) closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true)" \
  'rc=0 typed=1 closed=1' 'control: removing the composer check submits the draft together with /exit'

# The resolution the rows above exercise lives in lib/lane-state.sh, so its
# control needs a fixture tree of its own: the same lane-close and stubs over
# one mutated library.
lib_mutant() { # NAME OLD NEW
  local name="$1" old="$2" new="$3" dir
  dir="$TMP_ROOT/libmut-$name"
  mkdir -p "$dir/skills/orch/scripts/lib" "$dir/skills/linear/scripts"
  cp "$SCRIPTS/lane-close" "$SCRIPTS/workflow-state" "$SCRIPTS/lane-host" "$dir/skills/orch/scripts/"
  cp "$FIXTURE/skills/linear/scripts/linear.sh" "$dir/skills/linear/scripts/linear.sh"
  python3 - "$SCRIPTS/lib/lane-state.sh" "$dir/skills/orch/scripts/lib/lane-state.sh" "$old" "$new" <<'MUTPY'
import pathlib, sys
source, target, old, new = sys.argv[1:]
text = pathlib.Path(source).read_text()
if text.count(old) != 1:
    raise SystemExit(f"mutation match count={text.count(old)} old={old!r}")
pathlib.Path(target).write_text(text.replace(old, new))
MUTPY
  chmod +x "$dir/skills/orch/scripts/lane-close" "$dir/skills/orch/scripts/workflow-state" \
    "$dir/skills/orch/scripts/lane-host" "$dir/skills/linear/scripts/linear.sh"
  printf '%s\n' "$dir/skills/orch/scripts/lane-close"
}

MUTANT="$(lib_mutant session-column '(q == 0 || $1 == s) && $2 == n { print }' '$2 == n { print }')"
write_state running claude /host linear '' 'kendex:KEN-1'; write_panes bash '' other; claude_screen
run_close "$MUTANT"
assert_eq "rc=$RC closed=$(grep -c '^lane-close: closed ' <<<"$OUT" || true) missing=$(grep -c '^lane-close: pane-missing ' <<<"$ERR" || true)" \
  'rc=0 closed=1 missing=0' 'control: ignoring the session column closes a same-named window of another session'

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
