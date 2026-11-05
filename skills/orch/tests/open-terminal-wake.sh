#!/usr/bin/env bash
# Surface: open-terminal, the wake of a lane on this machine: the line that
# reads the lane's inbox handed to the session its record and its harness
# store name, as a second process in print mode (claude) or through
# pi-bridge (pi), once the runtime's lane status reads the lane idle; a codex
# or copilot lane the runtime reads idle still holds its live session and is
# refused; a record not in flight is refused by its status; the lane record
# rewritten with the session it resumed and the identity of the turn it
# started; every refusal by name, starting nothing.
#
# Each wake runs a copy of the orch scripts in a temp git repo, with the
# worktree CLI, the runtime's lane status and the harness binaries stubbed:
# a harness stub records the argv it was woken with and the environment it
# was handed, and holds while a row's hold file stands.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-wake: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-wake: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-wake: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# lane_process_start, so the identity rows read the started turn's own start
# beside the one the wake recorded.
# shellcheck source=../scripts/lib/lane-state.sh
source "$SCRIPTS_DIR/lib/lane-state.sh"

# The fleet home: the harness store and the accounts every wake reads. HOME
# is it too, so nothing a wake writes lands in the developer's own account.
SESSION_HOME="$TMP_ROOT/session-home"
mkdir -p "$SESSION_HOME/.agents/skills" "$SESSION_HOME/.aclaude" "$SESSION_HOME/.other-claude"
CLAUDE222=22222222-2222-2222-2222-222222222222
UNATTENDED="$(bash -c 'source "$1" && printf "%s" "$LAUNCH_UNATTENDED_TEXT"' _ "$SCRIPTS_DIR/lib/lane-launch.sh")"
[[ -n "$UNATTENDED" ]] || { echo "lib/lane-launch.sh named no unattended text" >&2; exit 1; }
WAKE_LINE="Run .agents/skills/mailbox/scripts/lane-mail inbox --item CC-1 and act on every envelope it prints, answers and directives alike, as its text directs."

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
# The harness a wake runs detached: its argv lands in the capture, renamed
# into place once whole, and the environment it was handed beside it, written
# first. It holds while the file STUB_HOLD names exists, a woken turn still
# running, and exits STUB_RC.
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${OT_CAPTURE:-}" ]]; then
  printf 'CLAUDE_CONFIG_DIR=%s CLAUDECODE=%s KENDEX_LANE_ORIGIN=%s KENDEX_USER_EMAIL=%s DISPLAY=%s\n' \
    "${CLAUDE_CONFIG_DIR-unset}" "${CLAUDECODE-unset}" "${KENDEX_LANE_ORIGIN-unset}" "${KENDEX_USER_EMAIL-unset}" "${DISPLAY-unset}" > "$OT_CAPTURE.env"
  printf '%s\n' "${0##*/} $*" > "$OT_CAPTURE.part" && mv -- "$OT_CAPTURE.part" "$OT_CAPTURE"
fi
while [[ -n "${STUB_HOLD:-}" && -e "$STUB_HOLD" ]]; do sleep 0.1; done
exit "${STUB_RC:-0}"
EOF
chmod +x "$BIN/claude"
for harness in codex copilot pi-bridge; do ln -s claude "$BIN/$harness"; done
# The runtime's lane status, the one judge of whether a lane is idle: the
# state STUB_LANE_STATE plants, idle by default, as the one field the wake
# reads of the verb's reply; with STUB_LANE_STATUS_FAIL set the verb refuses
# on its own keyed line.
cat > "$BIN/orch-runtime" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" lane status --item "*)
    [[ -z "${STUB_LANE_STATUS_FAIL:-}" ]] || { printf 'orch-runtime: %s\n' "$STUB_LANE_STATUS_FAIL" >&2; exit 1; }
    printf '{"ok":true,"result":{"state":"%s"}}\n' "${STUB_LANE_STATE:-idle}" ;;
  *) printf 'orch-runtime: fixture-verb verb=%s\n' "$*" >&2; exit 2 ;;
esac
EOF
chmod +x "$BIN/orch-runtime"
# The worktree CLI: `path ITEM` names the lane's tree under $TMP_ROOT/wt.
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == path ]] || { echo "unexpected worktree stub call: \$*" >&2; exit 1; }
printf '%s\n' "$TMP_ROOT/wt/\${2:-unknown}"
EOF
chmod +x "$STUB"
# A path with every tool of this suite's but setsid and perl, so a detached
# start has no route and refuses before any process runs.
NODETACH="$TMP_ROOT/nodetach"
mkdir -p "$NODETACH"
IFS=':' read -r -a path_dirs <<<"$PATH"
for dir in "${path_dirs[@]}"; do
  [[ -d "$dir" ]] || continue
  for tool in "$dir"/*; do
    name="${tool##*/}"
    case "$name" in setsid | perl) continue ;; esac
    [[ -e "$NODETACH/$name" || ! -x "$tool" ]] || ln -s "$tool" "$NODETACH/$name"
  done
done

# The lane's worktree and the session the store holds for it: one Claude
# transcript naming it, under the fleet home.
WT="$TMP_ROOT/wt/CC-1"
mkdir -p "$WT" "$SESSION_HOME/.claude-shared/projects/repo"
git -C "$WT" init -q
printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$WT\",\"isSidechain\":false,\"message\":{\"content\":\"Continue.\"}}" > "$SESSION_HOME/.claude-shared/projects/repo/$CLAUDE222.jsonl"

REPO="$TMP_ROOT/repo"
mutant_scripts repo >/dev/null || exit 1
orch_fixture_shared_libs "$REPO"
git -C "$REPO" init -q
OT="$REPO/scripts/open-terminal"
WS="$REPO/scripts/workflow-state"
STATE="$TMP_ROOT/state"
"$WS" --state-dir "$STATE" init oversee >/dev/null

# record ITEM HARNESS [FIELDS_JSON] — the lane record a launch wrote, running,
# with the fields a wake must leave as they are, FIELDS merged over them.
record() { # ITEM HARNESS [FIELDS]
  local fields='{}'
  [ -z "${3:-}" ] || fields="$3"
  jq -nc --arg item "$1" --arg harness "$2" --arg wt "$TMP_ROOT/wt/$1" --argjson fields "$fields" \
    '{item: $item, tracker: "linear", repo: null, harness: $harness, window: ("fleet:" + $item), account: null, host: null, kind: "local",
      mail_root: $wt, surface: "tmux", model: "opus", effort: "high", session_id: null, session_since: "2026-01-29T15:00:00Z",
      launched_at: "2026-01-29T15:00:00Z", running_at: "2026-01-29T15:00:01Z", status: "running", over_cap: null, allow_all: null,
      tier: "small", tier_inputs: {estimate: 12, delta: 40, paths: 3}, touched: ["a.sh"], in_scope: [],
      obligation: {repo: "o/r", item: $item, parent_repo: null, parent_item: null},
      launch: {pane: "%1", server: 41020, pid: null, start: null}} + $fields'
}
# plant RECORD... — the fleet's lanes, replaced.
plant() {
  local rows
  rows="$(printf '%s\n' "$@" | jq -sc .)"
  "$WS" --state-dir "$STATE" update oversee --argjson lanes "$rows" '.lanes = $lanes' >/dev/null
}
# field ITEM FIELD — the item's record field, compact.
field() { "$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$1"'") | .'"$2"' | tojson'; }

# run_wake [SCRIPT=PATH] [ENV=NAME=VALUE]... ARGS... — one wake into $STATE
# from the temp repo, the harness capture in $CAPTURE; sets OUT, ERR, RC and
# CMD, the woken line, empty where none ran.
run_wake() {
  local script="$OT" extra=() i
  while [[ "${1:-}" == SCRIPT=* || "${1:-}" == ENV=* ]]; do
    case "$1" in SCRIPT=*) script="${1#SCRIPT=}" ;; ENV=*) extra+=("${1#ENV=}") ;; esac
    shift
  done
  CAPTURE="$TMP_ROOT/capture.$$.$RANDOM"
  rm -f -- "$CAPTURE" "$CAPTURE.env"
  set +e
  OUT="$(cd "$REPO" && env PATH="$BIN:$PATH" HOME="$SESSION_HOME" LANES_HOME="$SESSION_HOME" \
    CLAUDECODE=1 WORKTREE_CLI="$STUB" ORCH_RUNTIME_CLI="$BIN/orch-runtime" \
    OT_CAPTURE="$CAPTURE" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' TMUX= TMUX_PANE= ${extra[@]+"${extra[@]}"} \
    "$script" --state-dir "$STATE" "$@" 2>"$TMP_ROOT/err")"
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/err")"
  CMD=""
  if [[ "$RC" -eq 0 ]]; then
    for i in $(seq 1 50); do [[ -s "$CAPTURE" ]] && break; sleep 0.1; done
    CMD="$(cat "$CAPTURE" 2>/dev/null || true)"
  fi
}
env_of() { cat "$CAPTURE.env" 2>/dev/null || echo unwritten; }
woken() { grep -c '^open-terminal: lane-woken item=CC-1 ' <<<"$OUT" || true; }

echo "=== a claude wake delivers the inbox line through its native resume in print mode, a pi wake through pi-bridge ==="
CLAUDE_COMPACTION='--settings={"env":{"DISABLE_AUTO_COMPACT":"1"}}'
while IFS='|' read -r harness expected; do
  plant "$(record CC-1 "$harness")"
  run_wake --wake --harness "$harness" CC-1
  assert_eq "rc=$RC woken=$(woken)" "rc=0 woken=1" "$harness wake reports the lane woken" "$TMP_ROOT/err"
  assert_contains "$OUT" "open-terminal: lane-woken item=CC-1 harness=$harness log=$WT/tmp/lane-wake-CC-1.log" "$harness wake names its log"
  assert_eq "$CMD" "$expected" "$harness wake delivers the inbox line through its native resume"
  assert_eq "$(field CC-1 status)|$(field CC-1 session_id)" "\"running\"|$(case "$harness" in claude) echo "\"$CLAUDE222\"" ;; pi) echo null ;; esac)" \
    "$harness wake records the session it resumed and the lane running"
  assert_contains "$(env_of)" "CLAUDECODE=unset KENDEX_LANE_ORIGIN=$WT KENDEX_USER_EMAIL= " "$harness wake runs its turn scrubbed of the caller's session, in the lane's origin, as nobody"
done <<ROWS
claude|claude -n CC-1 $CLAUDE_COMPACTION --disallowedTools=AskUserQuestion,EnterPlanMode --resume $CLAUDE222 -p $WAKE_LINE $UNATTENDED
pi|pi-bridge send --cwd $WT $WAKE_LINE $UNATTENDED
ROWS

echo "=== a codex or copilot lane the runtime reads idle still holds its live session and is not woken ==="
# The runtime reads a pane idle only with the harness in the foreground, and
# neither harness publishes an idle signal, so idle is a live session no
# second process may run beside.
for harness in codex copilot; do
  plant "$(record CC-1 "$harness")"
  run_wake --wake --harness "$harness" CC-1
  assert_eq "rc=$RC $(grep -c '^open-terminal: wake-refused item=CC-1 reason=unjudged$' <<<"$ERR" || true) started=${CMD:-none}" "rc=1 1 started=none" \
    "a $harness lane the runtime reads idle is refused as unjudged and no second process starts"
done

echo "=== a wake rewrites the session it resumed, the lane running and the turn's identity, and nothing else ==="
# The turn runs detached, outside the pane's process tree, so lane-close
# stops it by the identity the wake records: the detached shell's pid and
# start, read here while the held turn still runs, independently of what the
# record says.
wake_identity_read() {
  WAKE_GOT="$(field CC-1 wake)"
  WAKE_PID="$(jq -r '.pid // empty' <<<"$WAKE_GOT")"
  WAKE_WANT=""
  [[ -z "$WAKE_PID" ]] || WAKE_WANT="$(jq -cn --argjson pid "$WAKE_PID" --arg start "$(lane_process_start "$WAKE_PID")" '{pid: $pid, start: $start}')"
}
wake_identity_ok() { [[ "$RC" -eq 0 && -n "$WAKE_PID" && "$WAKE_GOT" == "$WAKE_WANT" ]]; }
plant "$(record CC-1 claude '{"live_display": true}')"
BEFORE="$("$WS" --state-dir "$STATE" get oversee '.lanes[0] | del(.session_id, .status, .wake)' | jq -c .)"
: > "$TMP_ROOT/hold"
run_wake ENV="STUB_HOLD=$TMP_ROOT/hold" ENV=DISPLAY=:0 --wake --harness claude CC-1
wake_identity_read
rm -f -- "${TMP_ROOT:?}/hold"
if wake_identity_ok; then pass "a wake records the pid and start of the detached turn it started"
else fail "a wake records the pid and start of the detached turn it started" "rc=$RC wake=$WAKE_GOT want=${WAKE_WANT:-a recorded pid}"; fi
assert_eq "$("$WS" --state-dir "$STATE" get oversee '.lanes[0] | del(.session_id, .status, .wake)' | jq -c .)" "$BEFORE" \
  "a wake leaves every other field of the record as the launch wrote it"
assert_eq "$(field CC-1 status)|$(field CC-1 session_id)" "\"running\"|\"$CLAUDE222\"" "a wake sets the resumed session id and status running"
assert_contains "$(env_of)" "DISPLAY=:0" "a wake of a lane recorded live_display keeps the owner's display for its turn"
plant "$(record CC-1 claude)"
run_wake ENV=DISPLAY=:0 --wake --harness claude CC-1
assert_contains "$(env_of)" "DISPLAY=unset" "a wake of a lane recorded without live_display clears the owner's display"

echo "=== a wake spends the account the record names, or the --lane named ==="
plant "$(record CC-1 claude "{\"account\": \"$SESSION_HOME/.aclaude\"}")"
run_wake --wake --harness claude CC-1
assert_contains "$(env_of)" "CLAUDE_CONFIG_DIR=$SESSION_HOME/.aclaude " "a wake runs under the account the record names"
run_wake --wake --harness claude --lane "$SESSION_HOME/.other-claude" CC-1
assert_contains "$(env_of)" "CLAUDE_CONFIG_DIR=$SESSION_HOME/.other-claude " "a --lane names the account the woken turn spends"
run_wake --wake --harness claude --lane "$TMP_ROOT/no-such-account" CC-1
assert_eq "rc=$RC $(grep -c '^open-terminal: lane-unknown lane=' <<<"$ERR" || true)" "rc=1 1" "a --lane naming no directory is refused before anything starts"

echo "=== a GitHub wake names the worktree id its mailbox is bound under ==="
mkdir -p "$TMP_ROOT/wt/issue-2708"
git -C "$TMP_ROOT/wt/issue-2708" init -q
plant "$(record issue-2708 pi '{"tracker": "github", "repo": "o/r"}')"
run_wake --wake --tracker github --repo o/r --harness pi 2708
assert_eq "$CMD" "pi-bridge send --cwd $TMP_ROOT/wt/issue-2708 Run .agents/skills/mailbox/scripts/lane-mail inbox --item issue-2708 and act on every envelope it prints, answers and directives alike, as its text directs. $UNATTENDED" \
  "a GitHub wake names the worktree id its mailbox is bound under, never the bare issue number"

echo "=== a wake into a lane the runtime reads working, or cannot judge, starts nothing ==="
plant "$(record CC-1 claude)"
run_wake ENV=STUB_LANE_STATE=working --wake --harness claude CC-1
assert_eq "rc=$RC $(grep -c '^open-terminal: wake-refused item=CC-1 reason=working$' <<<"$ERR" || true) started=${CMD:-none}" "rc=1 1 started=none" \
  "a working lane is refused by the runtime's word and no second process starts"
run_wake ENV=STUB_LANE_STATUS_FAIL='lane-missing item=CC-1' --wake --harness claude CC-1
assert_eq "rc=$RC $(grep -c '^open-terminal: wake-refused item=CC-1 reason=unjudged$' <<<"$ERR" || true) started=${CMD:-none}" "rc=1 1 started=none" \
  "a lane the runtime cannot judge is refused as unjudged and nothing starts"
assert_contains "$ERR" "orch-runtime: lane-missing item=CC-1" "the runtime's own line reaches the caller under the refusal"
run_wake ENV=STUB_LANE_STATE=working --wake --harness pi CC-1
assert_eq "rc=$RC woken=$(woken)" "rc=0 woken=1" "a pi wake enters the live session through pi-bridge and is not judged"

echo "=== a wake whose delivery exits non-zero, or whose detached start refuses, is refused by name ==="
plant "$(record CC-1 pi)"
run_wake ENV=STUB_RC=3 --wake --harness pi CC-1
assert_eq "$RC" "1" "a wake whose delivery exits non-zero exits 1"
assert_contains "$ERR" "open-terminal: wake-failed item=CC-1 harness=pi exit=3 log=$WT/tmp/lane-wake-CC-1.log" "a failed delivery is refused as wake-failed"
assert_not_contains "$OUT" "open-terminal: lane-woken" "a failed delivery is not reported woken"
run_wake ENV="PATH=$BIN:$NODETACH" --wake --harness pi CC-1
assert_eq "rc=$RC $(grep -c '^open-terminal: wake-unstarted item=CC-1 harness=pi$' <<<"$ERR" || true) started=${CMD:-none}" "rc=1 1 started=none" \
  "a detached start that refuses before any process runs is refused as wake-unstarted, not aborted"
assert_contains "$ERR" "lane-launch: detached=missing-command commands=perl" "the start's own line reaches the caller under the refusal"

echo "=== a wake with no session, no record, no worktree, a hosted lane, a record not in flight or a launch option is refused by name ==="
plant "$(record CC-1 claude)" "$(record CC-9 claude)" "$(record CC-8 claude)" "$(record CC-7 claude '{"host": "/srv/box", "kind": "ssh"}')" \
  "$(record CC-6 claude '{"status": "done"}')" "$(record CC-4 claude '{"status": "stopped"}')"
mkdir -p "$TMP_ROOT/wt/CC-9"
while IFS='|' read -r key argv; do
  read -r -a wake_argv <<<"$argv"
  run_wake "${wake_argv[@]}"
  assert_eq "rc=$RC started=${CMD:-none}" "rc=1 started=none" "wake refusal starts nothing: ${key%% *}"
  assert_contains "$ERR" "open-terminal: $key" "wake refusal names its key: ${key%% *}"
done <<'ROWS'
session-missing item=CC-9 harness=claude|--wake --harness claude CC-9
directory-missing item=CC-8|--wake --harness claude CC-8
record-missing item=CC-5 state=oversee|--wake --harness claude CC-5
wake-invalid option=--wake harness=claude host=/srv/box|--wake --harness claude CC-7
wake-invalid option=--wake harness=claude status=done|--wake --harness claude CC-6
wake-invalid option=--wake harness=claude status=stopped|--wake --harness claude CC-4
wake-invalid option=--wake harness=opencode|--wake --harness opencode CC-1
wake-only|--harness claude CC-1
harness-missing|--wake CC-1
ROWS
run_wake --wake --relaunch --harness claude CC-1
assert_eq "rc=$RC $(grep -c '^open-terminal: option-unknown option=--relaunch$' <<<"$ERR" || true)" "rc=2 1" "a launch option is refused: the launch is the runtime's"
run_wake --wake --harness claude --launch-flags 'x; rm -rf /' CC-1
assert_eq "rc=$RC $(grep -c '^open-terminal: flags-invalid ' <<<"$ERR" || true) started=${CMD:-none}" "rc=1 1 started=none" "a flag word with a shell metacharacter is refused before anything starts"
set +e
OUT="$(cd "$REPO" && env PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --state-dir "$TMP_ROOT/no-state" --wake --harness claude CC-1 2>"$TMP_ROOT/err")"; RC=$?
set -e
assert_eq "rc=$RC $(grep -c '^open-terminal: state-absent ' "$TMP_ROOT/err" || true)" "rc=1 1" "a wake into an address holding no fleet state refuses as state-absent"
set +e
OUT="$(cd "$REPO" && "$OT" --help 2>"$TMP_ROOT/err")"; RC=$?
set -e
assert_eq "rc=$RC $(grep -c '^Usage: open-terminal --wake' <<<"$OUT" || true)" "rc=0 1" "--help prints the usage and runs nothing"

echo "=== control: the identity assertion rejects a wake that records no turn ==="
WAKE_OT="$(mutant_scripts wake-mutant open-terminal)/open-terminal" || exit 1
mutate_file "$WAKE_OT" '  if start="$(lane_process_start "$pid")"; then' '  if start=""; then'
plant "$(record CC-1 claude)"
: > "$TMP_ROOT/hold"
run_wake SCRIPT="$WAKE_OT" ENV="STUB_HOLD=$TMP_ROOT/hold" --wake --harness claude CC-1
wake_identity_read
rm -f -- "${TMP_ROOT:?}/hold"
if wake_identity_ok; then fail "control: the identity assertion rejects a wake that records no turn" "rc=$RC wake=$WAKE_GOT"
else pass "control: the identity assertion rejects a wake that records no turn"; fi
assert_eq "rc=$RC wake=$WAKE_GOT" 'rc=0 wake=null' "control: without the start read a wake records no turn to stop"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
