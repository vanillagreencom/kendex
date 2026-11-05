#!/usr/bin/env bash
# Surface: open-terminal, the wake of a lane on this machine: the line that
# reads the lane's inbox handed to the session its record and its harness
# store name, as a second process in print mode (claude, codex, copilot) or
# through pi-bridge (pi), once the runtime's lane status reads the lane idle;
# the lane record rewritten with the session it resumed and the identity of
# the turn it started; every refusal by name, starting nothing.
#
# Each wake runs a copy of the orch scripts in a temp git repo, with the
# worktree CLI, the account listing, the runtime's lane status and the harness
# binaries stubbed: a harness stub records the argv it was woken with and the
# environment it was handed, and holds while a row's hold file stands.
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
# lane_launch_home_account, so a row asking which account a codex wake ran
# under reads the account back out of a private launch home.
# shellcheck source=../scripts/lib/lane-home.sh
source "$SCRIPTS_DIR/lib/lane-home.sh"
# shellcheck source=../scripts/lib/lane-state.sh
source "$SCRIPTS_DIR/lib/lane-state.sh"

# The fleet home: the harness stores and the accounts every wake reads. HOME
# is it too, so a codex trust preparation writes under it and never into the
# developer's own account.
SESSION_HOME="$TMP_ROOT/session-home"
mkdir -p "$SESSION_HOME/.agents/skills"
CLAUDE222=22222222-2222-2222-2222-222222222222
CODEX444=44444444-4444-4444-4444-444444444444
COPILOT_ID=22222222-bbbb-4bbb-8bbb-222222222222
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
  printf 'CLAUDE_CONFIG_DIR=%s CODEX_HOME=%s COPILOT_HOME=%s COPILOT_ALLOW_ALL=%s COPILOT_SKILLS_DIRS=%s COPILOT_GITHUB_TOKEN=%s GH_TOKEN=%s CLAUDECODE=%s KENDEX_LANE_ORIGIN=%s KENDEX_USER_EMAIL=%s DISPLAY=%s\n' \
    "${CLAUDE_CONFIG_DIR-unset}" "${CODEX_HOME-unset}" "${COPILOT_HOME-unset}" "${COPILOT_ALLOW_ALL-unset}" "${COPILOT_SKILLS_DIRS-unset}" \
    "${COPILOT_GITHUB_TOKEN-unset}" "${GH_TOKEN-unset}" "${CLAUDECODE-unset}" "${KENDEX_LANE_ORIGIN-unset}" "${KENDEX_USER_EMAIL-unset}" "${DISPLAY-unset}" > "$OT_CAPTURE.env"
  printf '%s\n' "${0##*/} $*" > "$OT_CAPTURE.part" && mv -- "$OT_CAPTURE.part" "$OT_CAPTURE"
fi
while [[ -n "${STUB_HOLD:-}" && -e "$STUB_HOLD" ]]; do sleep 0.1; done
exit "${STUB_RC:-0}"
EOF
chmod +x "$BIN/claude"
for harness in codex copilot pi-bridge; do ln -s claude "$BIN/$harness"; done
# The account listing a codex session scan reads: the one codex account.
cat > "$BIN/lanes" <<EOF
#!/usr/bin/env bash
[[ "\$*" == "list --local --harness codex --json" ]] || exit 1
printf '[{"config_dir":"%s"}]\n' "$SESSION_HOME/.selected-codex"
EOF
chmod +x "$BIN/lanes"
# The runtime's lane status, the one judge of whether a lane is idle: the
# state STUB_LANE_STATE plants, idle by default, in the verb's reply; with
# STUB_LANE_STATUS_FAIL set the verb refuses on its own keyed line.
cat > "$BIN/orch-runtime" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" lane status --item "*)
    [[ -z "${STUB_LANE_STATUS_FAIL:-}" ]] || { printf 'orch-runtime: %s\n' "$STUB_LANE_STATUS_FAIL" >&2; exit 1; }
    printf '{"protocol":"orch-runtime-v1","ok":true,"result":{"item":"CC-1","window":"fleet:CC-1","pane_key":"%%1","identity":"live","review_rounds":0,"fix_receipts":0,"validation_runs":0,"restacks":0,"repeated_class_rounds":0,"stage":null,"counts_cause":null,"state":"%s","capacity":false}}\n' "${STUB_LANE_STATE:-idle}" ;;
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

# The lane's worktree and the sessions the stores hold for it: one Claude
# transcript, one Codex rollout and one Copilot session record naming it, all
# under the fleet home.
WT="$TMP_ROOT/wt/CC-1"
mkdir -p "$WT" "$SESSION_HOME/.claude-shared/projects/repo" "$SESSION_HOME/.selected-codex/sessions/2026" "$SESSION_HOME/.copilot/session-state/$COPILOT_ID"
git -C "$WT" init -q
printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$WT\",\"isSidechain\":false,\"message\":{\"content\":\"Continue.\"}}" > "$SESSION_HOME/.claude-shared/projects/repo/$CLAUDE222.jsonl"
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$CODEX444\",\"cwd\":\"$WT\"}}" > "$SESSION_HOME/.selected-codex/sessions/2026/session.jsonl"
printf 'id: %s\ncwd: %s\ngit_root: %s\nbranch: cc-1\nclient_name: github/cli\nuser_named: false\n' "$COPILOT_ID" "$WT" "$WT" > "$SESSION_HOME/.copilot/session-state/$COPILOT_ID/workspace.yaml"
printf '%s\n' '{"type":"session.start"}' > "$SESSION_HOME/.copilot/session-state/$COPILOT_ID/events.jsonl"

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
  OUT="$(cd "$REPO" && env PATH="$BIN:$PATH" HOME="$SESSION_HOME" LANES_HOME="$SESSION_HOME" CODEX_HOME="$SESSION_HOME/.selected-codex" COPILOT_HOME="$SESSION_HOME/.copilot" \
    COPILOT_GITHUB_TOKEN=copilot-fixture GH_TOKEN=gh-fixture CLAUDECODE=1 WORKTREE_CLI="$STUB" LANES_CLI="$BIN/lanes" ORCH_RUNTIME_CLI="$BIN/orch-runtime" \
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

echo "=== each harness's wake delivers the inbox line through its native resume in print mode ==="
CLAUDE_COMPACTION='--settings={"env":{"DISABLE_AUTO_COMPACT":"1"}}'
CODEX_LEAD='-c check_for_update_on_startup=false -c features.daemon_auto_start=false -c notice.hide_rate_limit_model_nudge=true --dangerously-bypass-hook-trust -c model_auto_compact_token_limit=9223372036854775807 -c model_auto_compact_token_limit_scope=body_after_prefix -c model_post_turn_compact_threshold_percent=0 -c features.default_mode_request_user_input=false'
COPILOT_FLAGS='--model claude-opus-5 --reasoning-effort high --allow-all'
while IFS='|' read -r harness flags expected; do
  plant "$(record CC-1 "$harness")"
  run_wake --wake --harness "$harness" ${flags:+--launch-flags "$flags"} CC-1
  assert_eq "rc=$RC woken=$(woken)" "rc=0 woken=1" "$harness wake reports the lane woken" "$TMP_ROOT/err"
  assert_contains "$OUT" "open-terminal: lane-woken item=CC-1 harness=$harness log=$WT/tmp/lane-wake-CC-1.log" "$harness wake names its log"
  assert_eq "$CMD" "$expected" "$harness wake delivers the inbox line through its native resume"
  assert_eq "$(field CC-1 status)|$(field CC-1 session_id)" "\"running\"|$(case "$harness" in claude) echo "\"$CLAUDE222\"" ;; codex) echo "\"$CODEX444\"" ;; copilot) echo "\"$COPILOT_ID\"" ;; pi) echo null ;; esac)" \
    "$harness wake records the session it resumed and the lane running"
  assert_contains "$(env_of)" "CLAUDECODE=unset KENDEX_LANE_ORIGIN=$WT KENDEX_USER_EMAIL= " "$harness wake runs its turn scrubbed of the caller's session, in the lane's origin, as nobody"
done <<ROWS
claude||claude -n CC-1 $CLAUDE_COMPACTION --disallowedTools=AskUserQuestion,EnterPlanMode --resume $CLAUDE222 -p $WAKE_LINE $UNATTENDED
codex||codex exec resume $CODEX_LEAD $CODEX444 $WAKE_LINE $UNATTENDED
pi||pi-bridge send --cwd $WT $WAKE_LINE $UNATTENDED
copilot|$COPILOT_FLAGS|copilot --autopilot --max-autopilot-continues 3 --context long_context --no-auto-update --no-ask-user --model claude-opus-5 --reasoning-effort high --allow-all --resume=$COPILOT_ID -p $WAKE_LINE $UNATTENDED
ROWS

echo "=== a wake rewrites the session it resumed, the lane running and the turn's identity, and nothing else ==="
plant "$(record CC-1 claude '{"status": "done", "live_display": true}')"
BEFORE="$("$WS" --state-dir "$STATE" get oversee '.lanes[0] | del(.session_id, .status, .wake)' | jq -c .)"
: > "$TMP_ROOT/hold"
run_wake ENV="STUB_HOLD=$TMP_ROOT/hold" ENV=DISPLAY=:0 --wake --harness claude CC-1
WAKE_PID="$(field CC-1 wake.pid)"
WAKE_WANT=null
[[ "$WAKE_PID" == null ]] || WAKE_WANT="$(jq -cn --argjson pid "$WAKE_PID" --arg start "$(lane_process_start "$WAKE_PID")" '{pid: $pid, start: $start}')"
WAKE_GOT="$(field CC-1 wake)"
rm -f -- "${TMP_ROOT:?}/hold"
assert_eq "rc=$RC wake=$WAKE_GOT" "rc=0 wake=$WAKE_WANT" "a wake records the pid and start of the detached turn it started"
assert_eq "$WAKE_PID" "$(jq -r .pid <<<"$WAKE_GOT")" "the recorded turn is a process the wake started"
assert_eq "$("$WS" --state-dir "$STATE" get oversee '.lanes[0] | del(.session_id, .status, .wake)' | jq -c .)" "$BEFORE" \
  "a wake leaves every other field of the record as the launch wrote it"
assert_eq "$(field CC-1 status)|$(field CC-1 session_id)" "\"running\"|\"$CLAUDE222\"" "a wake sets the resumed session id and status running"
assert_contains "$(env_of)" "DISPLAY=:0" "a wake of a lane recorded live_display keeps the owner's display for its turn"
plant "$(record CC-1 claude)"
run_wake ENV=DISPLAY=:0 --wake --harness claude CC-1
assert_contains "$(env_of)" "DISPLAY=unset" "a wake of a lane recorded without live_display clears the owner's display"

echo "=== a wake spends the account the record names, or the --lane named ==="
plant "$(record CC-1 codex "{\"account\": \"$SESSION_HOME/.selected-codex\"}")"
run_wake --wake --harness codex CC-1
assert_eq "$(lane_launch_home_account "$(sed -n 's/.* CODEX_HOME=\([^ ]*\) .*/\1/p' "$CAPTURE.env")")" "$SESSION_HOME/.selected-codex" \
  "a codex wake runs under the account the record names"
mkdir -p "$SESSION_HOME/.other-codex"
run_wake --wake --harness codex --lane "$SESSION_HOME/.other-codex" CC-1
assert_eq "$(lane_launch_home_account "$(sed -n 's/.* CODEX_HOME=\([^ ]*\) .*/\1/p' "$CAPTURE.env")")" "$SESSION_HOME/.other-codex" \
  "a --lane names the account the woken turn spends"
run_wake --wake --harness codex --lane "$TMP_ROOT/no-such-account" CC-1
assert_eq "rc=$RC $(grep -c '^open-terminal: lane-unknown lane=' <<<"$ERR" || true)" "rc=1 1" "a --lane naming no directory is refused before anything starts"

echo "=== a copilot wake runs under the launch environment, COPILOT_GITHUB_TOKEN cleared ==="
plant "$(record CC-1 copilot)"
run_wake --wake --harness copilot --launch-flags "$COPILOT_FLAGS" CC-1
assert_contains "$(env_of)" "COPILOT_ALLOW_ALL=true COPILOT_SKILLS_DIRS=$SESSION_HOME/.agents/skills COPILOT_GITHUB_TOKEN=unset GH_TOKEN=gh-fixture" \
  "the woken copilot runs under the launch environment, COPILOT_GITHUB_TOKEN cleared and GH_TOKEN kept"
run_wake ENV=COPILOT_ALLOW_ALL=true --wake --harness copilot --launch-flags "--model claude-opus-5 --reasoning-effort high" CC-1
assert_contains "$(env_of)" "COPILOT_ALLOW_ALL= COPILOT_SKILLS_DIRS=" \
  "a wake naming no allow-all spelling under an exported COPILOT_ALLOW_ALL=true runs copilot with it empty"

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

echo "=== a wake whose delivery exits non-zero is refused as wake-failed ==="
plant "$(record CC-1 pi)"
run_wake ENV=STUB_RC=3 --wake --harness pi CC-1
assert_eq "$RC" "1" "a wake whose delivery exits non-zero exits 1"
assert_contains "$ERR" "open-terminal: wake-failed item=CC-1 harness=pi exit=3 log=$WT/tmp/lane-wake-CC-1.log" "a failed delivery is refused as wake-failed"
assert_not_contains "$OUT" "open-terminal: lane-woken" "a failed delivery is not reported woken"

echo "=== a wake with no session, no record, no worktree, a hosted lane or a launch option is refused by name ==="
plant "$(record CC-1 claude)" "$(record CC-9 claude)" "$(record CC-8 codex)" "$(record CC-7 claude '{"host": "/srv/box", "kind": "ssh"}')"
mkdir -p "$TMP_ROOT/wt/CC-9"
while IFS='|' read -r key argv; do
  read -r -a wake_argv <<<"$argv"
  run_wake "${wake_argv[@]}"
  assert_eq "rc=$RC started=${CMD:-none}" "rc=1 started=none" "wake refusal starts nothing: ${key%% *}"
  assert_contains "$ERR" "open-terminal: $key" "wake refusal names its key: ${key%% *}"
done <<'ROWS'
session-missing item=CC-9 harness=claude|--wake --harness claude CC-9
directory-missing item=CC-8|--wake --harness codex CC-8
record-missing item=CC-5 state=oversee|--wake --harness claude CC-5
wake-invalid option=--wake harness=claude host=/srv/box|--wake --harness claude CC-7
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

echo "=== control: without the start read a wake records no turn to stop ==="
WAKE_OT="$(mutant_scripts wake-mutant open-terminal)/open-terminal" || exit 1
mutate_file "$WAKE_OT" '  if start="$(lane_process_start "$pid")"; then' '  if start=""; then'
plant "$(record CC-1 claude)"
: > "$TMP_ROOT/hold"
run_wake SCRIPT="$WAKE_OT" ENV="STUB_HOLD=$TMP_ROOT/hold" --wake --harness claude CC-1
WAKE_GOT="$(field CC-1 wake)"
rm -f -- "${TMP_ROOT:?}/hold"
assert_eq "rc=$RC wake=$WAKE_GOT" 'rc=0 wake=null' "control: without the start read a wake records no turn to stop"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
