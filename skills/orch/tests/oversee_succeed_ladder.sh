#!/usr/bin/env bash
# Tests for the model ladder oversee-succeed's successor walk takes: each
# ORCH_OVERSEER_PREFERENCE entry names the model its successor runs, on
# claude, codex, copilot or pi, the pick is judged on the bucket that walls
# that model, the walk takes the setting's order and no other, and an unset
# setting walks lib/overseer-launch.sh's default. Run over a real tmux server
# on a private socket, as oversee_succeed.sh is; claude, codex, copilot and pi
# are stubs on PATH, and `lanes pick` answers from the lanes-fixture usage
# bodies. The
# caller's own account is walled for the model it runs in every row, so every
# row reaches the headroom mark, or is the wall recovery, and walks.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/lanes-fixture.sh"
# mutant_scripts and mutate_file, the two halves of the ladder's control.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUCCEED="$TEST_DIR/../scripts/oversee-succeed"
# The context reading a turn-end hook records in the overseer mailbox.
# shellcheck source=../scripts/lib/lane-context.sh
source "$TEST_DIR/../scripts/lib/lane-context.sh"
# The caller's full-bypass permission word, read from the launch table the
# launcher writes it from, so this file spells no permission switch.
# shellcheck source=../scripts/lib/lane-launch.sh
source "$TEST_DIR/../scripts/lib/lane-launch.sh"
BYPASS="$(launch_choice_permission_write claude)" || { echo "fixture: no claude permission word in the launch table" >&2; exit 1; }

TMP_ROOT="$(mktemp -d)" || { echo "oversee_succeed_ladder: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "oversee_succeed_ladder: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "oversee_succeed_ladder: scratch=resolve-failed" >&2; exit 1; }
SOCK="oversee-succeed-ladder-$$"
cleanup() {
  [[ ! -f "$TMP_ROOT/work/tmp/oversee-watch.pid" ]] || fixture_watch_stop "$TMP_ROOT/work/tmp/workflow-state-oversee.json" || true
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
source "$TEST_DIR/lib/watch-fixture.sh"
QUIET_SCRIPTS="$(mutant_scripts fixture-watch oversee-succeed)" || exit 1
cp -p -- "$SUCCEED" "$QUIET_SCRIPTS/oversee-succeed"
SUCCEED="$QUIET_SCRIPTS/oversee-succeed"
fixture_watch_neighbor "$SUCCEED"
tm() { tmux -L "$SOCK" "$@"; }

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN" "$TMP_ROOT/work/tmp"
# A harness stub records its lane and argv and draws the hint a running turn
# shows, so the successor reads as working. A pi successor runs on claude's
# account variable, the one the pi-claude bridge reads.
for harness in claude codex copilot pi; do
  lane_var=CLAUDE_CONFIG_DIR
  [[ "$harness" != codex ]] || lane_var=CODEX_HOME
  [[ "$harness" != copilot ]] || lane_var=COPILOT_HOME
  cat > "$BIN/$harness" <<STUB
#!/bin/sh
{ printf 'lane=%s\n' "\${$lane_var:-}"; printf '%s\n' "\$@"; } > "$TMP_ROOT/argv.$harness"
echo 'esc to interrupt'
exec sleep 100000
STUB
done
chmod +x "$BIN/claude" "$BIN/codex" "$BIN/copilot" "$BIN/pi"
# A caller whose foreground process names claude: a copy of sleep, since a
# script or a shell named for the harness can reset the name tmux reads.
cp "$(command -v sleep)" "$BIN/hclaude"
# A codex caller's pane: a copy of sleep named codex, apart from the stub the
# successor runs.
mkdir -p "$TMP_ROOT/cbin"
cp "$(command -v sleep)" "$TMP_ROOT/cbin/codex"

new_home fleet
make_lane "$H" claude
make_lane "$H" eclaude
make_lane "$H" fclaude
make_codex_lane "$H/.codex"
make_codex_lane "$H/.dcodex"
FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"
# A pi install a pi successor may open on: its user settings turn compaction
# off, and its pi-hooks carrier sends the context window.
mkdir -p "$H/.pi/agent/packages/@vanillagreen/pi-hooks/extensions"
jq -n '{compaction: {enabled: false}}' > "$H/.pi/agent/settings.json"
printf 'payload.context_window = usage.contextWindow;\n' > "$H/.pi/agent/packages/@vanillagreen/pi-hooks/extensions/stop.ts"

# seat LANE SESSION_PCT FABLE_PCT OPUS_PCT — LANE's usage: the 5-hour window
# at SESSION_PCT, which walls every model, the weekly window at 20, and the
# Fable and Opus windows, each of which walls its own model alone.
seat() {
  jq -n --argjson s "$2" --argjson f "$3" --argjson o "$4" '{
    five_hour: {utilization: $s, resets_at: "2099-07-27T06:00:00Z"},
    seven_day: {utilization: 20, resets_at: "2099-08-01T06:00:00Z"},
    limits: [{kind: "weekly_scoped", percent: $f, resets_at: "2099-08-01T06:00:00Z",
              scope: {model: {display_name: "Fable 5.1"}}},
             {kind: "weekly_scoped", percent: $o, resets_at: "2099-08-01T06:00:00Z",
              scope: {model: {display_name: "Opus"}}}]
  }' > "$FIXTURE_DIR/.$1.json"
}
codex_seat() { # LANE USED_PCT
  jq -n --argjson u "$2" '{rate_limit: {primary_window: {used_percent: $u, reset_at: 1785000000, limit_window_seconds: 18000}, secondary_window: null}}' \
    > "$FIXTURE_DIR/.$1.json"
}

env PATH="$BIN:$PATH" tmux -L "$SOCK" -f /dev/null new-session -d -s fleet -x 220 -y 50 'exec sleep 100000'
KEEP_WINDOW="$(tm display-message -p -t fleet:0 '#{window_id}')"
tm set-option -g default-shell /bin/sh
tm set-option -g renumber-windows off
# The successor pane is a non-login shell under this fixture's PATH, so the
# stubs above are the harness it runs.
tm set-option -g default-command "PATH=$BIN:\$PATH; export PATH; exec /bin/sh"
TMUX_ADDR="$(tm display-message -p '#{socket_path},#{pid},0')"
SERVER_PID="$(tm display-message -p '#{pid}')"
# The server's start, which the launch record below binds its server by.
SERVER_START="$(tm display-message -p '#{start_time}')"
# A pane that stays live for the whole run, for a claim to name.
CLAIM_PANE="$(tm display-message -p -t fleet:0 '#{pane_id}')"

MAILBOX_DIR="$TMP_ROOT/work/tmp/lane-mail/overseer"
# new_caller [codex] — an overseer at index 1 well under the context mark,
# Fable on .claude, or with `codex` GPT-5.6 Sol on .codex; sets CALLER_PANE
# and CALLER_WINDOW.
new_caller() {
  fixture_watch_stop "$TMP_ROOT/work/tmp/workflow-state-oversee.json"
  local spec cmd="exec '$BIN/hclaude' 100000"
  [[ -f "$TMP_ROOT/work/tmp/workflow-state-oversee.json" ]] || printf '{"issue_id":"oversee","overseer":{"generation":1}}\n' > "$TMP_ROOT/work/tmp/workflow-state-oversee.json"
  [[ "${1:-}" != codex ]] || cmd="exec '$TMP_ROOT/cbin/codex' 100000"
  tm kill-window -a -t "$KEEP_WINDOW"
  tm move-window -r -t fleet
  rm -f -- "${TMP_ROOT:?}"/argv.*
  spec="$(tm new-window -d -t fleet:1 -c "$TMP_ROOT/work" -P -F '#{pane_id} #{window_id}' "$cmd")"
  read -r CALLER_PANE CALLER_WINDOW <<<"$spec"
  fixture_watch_predecessor "$SUCCEED" "$TMP_ROOT/work/tmp/workflow-state-oversee.json" "$TMP_ROOT/work" "$CALLER_PANE"
  mkdir -p "$MAILBOX_DIR"
  if [[ "${1:-}" == codex ]]; then
    lane_context_record "$MAILBOX_DIR" codex 100000 258400 "${2-gpt-5.6-sol}" "" "$SERVER_PID $CALLER_PANE"
  else
    lane_context_record "$MAILBOX_DIR" claude 100000 1000000 "${2-claude-fable-5-1}" "" "$SERVER_PID $CALLER_PANE"
  fi
}

# run_succeed ROW PREFERENCE [ARGS...] — the script under an explicit, whole
# environment from the caller pane, ARGS ahead of its flags. The caller runs
# under full bypass on .claude, the one permission posture a successor of the
# other harness takes, unless CALLER_LANE names its account variable and
# CALLER_FLAGS its flags. The fleet is the claude and codex accounts, or
# LANE_DIRS where a row sets it. PREFERENCE `unset` exports no
# ORCH_OVERSEER_PREFERENCE. Sets OUT (both streams) and RC.
CALLER_FLAGS=("$BYPASS")
run_succeed() {
  fixture_watch_neighbor "${SUCCEED_BIN:-$SUCCEED}"
  local row="$1" pref=(ORCH_OVERSEER_PREFERENCE="$2") lane="${CALLER_LANE:-CLAUDE_CONFIG_DIR=$H/.claude}"
  local -a wait=(--wait-secs 20)
  [[ "$2" != unset ]] || pref=()
  # --check-marks refuses --wait-secs, so a check row sets NO_WAIT.
  [[ -z "${NO_WAIT:-}" ]] || wait=()
  shift 2
  case " $* " in
    *' --check-marks '*|*' --print-launch-line '*|*' --dead-pane '*|*' --walled-pane '*) ;;
    *) fixture_succession_handoff "$TMP_ROOT/work/tmp/workflow-state-oversee.json" "$TMP_ROOT/work/tmp/handoffs/OVERSEER-HANDOFF.md" ;;
  esac
  RC=0
  OUT="$(cd "$TMP_ROOT/work" && env -i HOME="$H" PATH="$BIN:$PATH" TMUX="$TMUX_ADDR" TMUX_PANE="$CALLER_PANE" \
    LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state-$row" \
    "$lane" ORCH_LANES_FETCH_CMD="${LANES_FETCHER:-$FETCHER}" \
    ORCH_LANE_EXCLUDE="${LANE_EXCLUDE:-}" ORCH_LANE_RETIRE="${LANE_RETIRE:-}" \
    ORCH_LANE_DIRS="${LANE_DIRS:-$H/.claude:$H/.eclaude:$H/.fclaude:$H/.codex:$H/.dcodex}" ORCH_LANES_USAGE_TTL="${USAGE_TTL:-0}" \
    ORCH_OVERSEER_WALL_MINUTES=0 ORCH_OVERSEER_SUCCESSOR_ACCOUNTS="${SUCCESSOR_ACCOUNTS:-0}" ORCH_QUESTION_TOOL=overseer \
    ${pref[@]+"${pref[@]}"} "${SUCCEED_BIN:-$SUCCEED}" ${wait[@]+"${wait[@]}"} "$@" -- ${CALLER_FLAGS[@]+"${CALLER_FLAGS[@]}"} 2>&1)" || RC=$?
  printf '%s\n' "$OUT" > "$TMP_ROOT/out"
}
# A claim from this suite's tmux server on a pane that stays live, on LANE.
write_claim() { # ROW LANE
  mkdir -p "$TMP_ROOT/state-$1/claims"
  printf '%s\t%s\t%s\t%s\t2026-09-18T00:00:00Z\n' \
    "$SERVER_PID" "$CLAIM_PANE" "$H/.$2" ken-claimed > "$TMP_ROOT/state-$1/claims/claimed.claim"
}
# launched HARNESS — the lane and the model the HARNESS stub was started on,
# as `<lane> <model>`, the model the word after --model or -m; `none` where no
# successor of that harness started.
launched() {
  [[ -f "$TMP_ROOT/argv.$1" ]] || { printf 'none'; return 0; }
  awk 'NR == 1 { sub(/^lane=/, ""); lane = $0 } want { model = $0; want = 0 }
       $0 == "--model" || $0 == "-m" { want = 1 } END { printf "%s %s", lane, model }' "$TMP_ROOT/argv.$1"
}
caller_open() { if [[ "$(tm list-windows -t fleet -F '#{window_id}')" == *"$CALLER_WINDOW"* ]]; then echo yes; else echo no; fi; }
first_key() { sed -n 1p <<<"$OUT" | awk '{print $2}'; }
# keyed KEY — the first line OUT carries under KEY, or `none`.
keyed() { grep -m1 "^oversee-succeed: $1 " <<<"$OUT" || echo none; }

echo "=== oversee-succeed: the model ladder ==="

# Every claude seat is Fable-walled, .eclaude alone has Opus room, and codex is
# walled. Under the default ladder the first entry is Opus and that
# entry takes .eclaude: the seat is judged on the bucket that walls Opus, not
# on its binding bucket, which the Fable window holds at 99.
seat claude 10 99 99
seat eclaude 10 99 10
seat fclaude 99 99 10
codex_seat codex 99
codex_seat dcodex 99
new_caller
run_succeed opus unset
assert_eq "$RC|$(caller_open)|$(launched claude)|$(launched codex)|$(grep -cx -e --effort -e high "$TMP_ROOT/argv.claude")" \
  "0|no|$H/.eclaude claude-opus-5-5|none|2" \
  "a Fable-walled seat with Opus room is chosen for the default ladder's Opus entry, at high effort"

# An overseer that hits the Fable wall mid-turn takes no turn, so the watch
# recovers it through --walled-pane. That recovery walks the same ladder, so
# the wall itself moves it onto Opus, never onto the account that walled.
new_caller
run_succeed walled unset --walled-pane "$CALLER_PANE"
assert_eq "$RC|$(caller_open)|$(launched claude)" \
  "0|no|$H/.eclaude claude-opus-5-5" \
  "a walled Fable overseer is recovered onto the ladder's Opus entry"
# Its control: a walled recovery that walks the caller entry alone stays on
# Fable and refuses the fleet the ladder recovers on.
WALLEDCTL="$(mutant_scripts walledctl oversee-succeed)" || exit 1
mutate_file "$WALLEDCTL/oversee-succeed" '  if [[ "$MODE" == print ]]; then' '  if [[ "$MODE" == print || "$MODE" == walled ]]; then'
new_caller
SUCCEED_BIN="$WALLEDCTL/oversee-succeed" run_succeed walledctl unset --walled-pane "$CALLER_PANE"
assert_eq "$RC|$(keyed no-lane-qualifies | awk '{print $2, $3}')|$(caller_open)|$(launched claude)" \
  "3|no-lane-qualifies entries=0|yes|none" \
  "control: a walled recovery walking the caller entry alone refuses a fleet with Opus room"

# The walled account's own Opus window has room too, and it carries no lane
# claim, so a pick that judged it could name it for the Opus entry. The pick
# leaves the walled account out, so the Opus entry lands on .eclaude rather
# than being dropped.
seat claude 10 99 10
new_caller
run_succeed walledopus unset --walled-pane "$CALLER_PANE"
assert_eq "$RC|$(caller_open)|$(launched claude)" \
  "0|no|$H/.eclaude claude-opus-5-5" \
  "a walled account with Opus room of its own is left out of the Opus pick"
# Its control: a walled pick that keeps the walled account names it, the entry
# is dropped, and the recovery refuses with .eclaude's Opus room unused.
EXCLUDECTL="$(mutant_scripts excludectl oversee-succeed)" || exit 1
mutate_file "$EXCLUDECTL/oversee-succeed" '  [[ "$MODE" != walled ]] || exclude="$WALLED_LANE"' ''
new_caller
SUCCEED_BIN="$EXCLUDECTL/oversee-succeed" run_succeed excludectl unset --walled-pane "$CALLER_PANE"
assert_eq "$RC|$(keyed successor-lane-spent | awk '{print $2, $4}')|$(caller_open)|$(launched claude)" \
  "3|successor-lane-spent entry=claude:claude-opus-5-5:high|yes|none" \
  "control: a walled pick that keeps the walled account drops the Opus entry"
seat claude 10 99 99

# An entry naming no model, zero or an empty field, is a setting
# to fix: refused with a keyed line before any pick, on a fleet with Opus room.
for entry in 'claude:0:high' 'claude::high' 'codex:high' 'copilot:0:high'; do
  new_caller
  run_succeed nomodelentry "$entry"
  assert_eq "$RC|$(keyed invalid-preference | awk '{print $2, $3}')|$(caller_open)|$(launched claude)" \
    "1|invalid-preference entry=$entry|yes|none" \
    "an entry naming no model, $entry, refuses invalid-preference"
done
# Its control: a parse that reads a bare number as a model admits the rank
# entry, which then fails somewhere other than the parse.
RANKCTL="$(mutant_scripts rankctl lib/overseer-launch.sh)" || exit 1
mutate_file "$RANKCTL/lib/overseer-launch.sh" \
  '    elif ! [[ "$parsed_entry" =~ ^(claude|codex|copilot):[a-z][a-z0-9.-]*:[a-z]+$ \' \
  '    elif ! [[ "$parsed_entry" =~ ^(claude|codex|copilot):([0-9]+|[a-z][a-z0-9.-]*):[a-z]+$ \'
new_caller
SUCCEED_BIN="$RANKCTL/oversee-succeed" run_succeed rankctl 'claude:0:high'
assert_eq "$(keyed invalid-preference)" "none" \
  "control: a parse that reads a bare number as a model admits the rank entry"

# The ladder's must-fail control: a walk that reads an entry's model name as no
# model judges each seat on its binding bucket, the Fable window, and refuses
# the same fleet the default ladder succeeds on.
NOMODEL="$(mutant_scripts nomodel lib/overseer-launch.sh)" || exit 1
mutate_file "$NOMODEL/lib/overseer-launch.sh" \
  '  [[ -n "$OL_ENTRY_MODEL" ]] || OL_ENTRY_MODEL="${OL_WALK_CALLER_MODEL:-$OL_PREFERENCE_CALLER_MODEL}"' \
  '  OL_ENTRY_MODEL=""'
new_caller
SUCCEED_BIN="$NOMODEL/oversee-succeed" run_succeed nomodel unset
assert_eq "$RC|$(first_key)|$(caller_open)|$(launched claude)" \
  "3|no-lane-qualifies|yes|none" \
  "control: a walk that drops the entry's model refuses the fleet the ladder succeeds on"

# Set to empty, the setting names no entry: the walk is the caller's own
# harness alone, on Fable, and the unset default is what reached Opus above.
new_caller
run_succeed empty ''
assert_eq "$RC|$(sed -n 1p <<<"$OUT" | awk '{print $2, $3}')" \
  "3|no-lane-qualifies entries=0" \
  "an empty preference walks no ladder"

# Two seats with equal Opus room, the first in the fleet's order carrying a
# live lane claim: the successor goes to the empty one. The row after it is
# the same fleet with no claim, where the first seat is taken.
seat fclaude 10 99 10
new_caller
write_claim claimed eclaude
run_succeed claimed unset
assert_eq "$RC|$(launched claude)" \
  "0|$H/.fclaude claude-opus-5-5" \
  "a seat carrying a lane claim is skipped for an empty one at equal headroom"
new_caller
run_succeed unclaimed unset
assert_eq "$RC|$(launched claude)" \
  "0|$H/.eclaude claude-opus-5-5" \
  "the same fleet with no claim takes the first seat"

# Every claude seat walled for every model: the default reaches codex on
# GPT-6.1 Sol, the second entry.
seat eclaude 99 99 10
seat fclaude 99 99 10
codex_seat codex 20
new_caller
run_succeed codex unset
assert_eq "$RC|$(caller_open)|$(launched claude)|$(launched codex | awk '{print $2}')|$(grep -cx 'model_reasoning_effort=high' "$TMP_ROOT/argv.codex")" \
  "0|no|none|gpt-6.1-sol|1" \
  "every claude entry walled: the default reaches codex on GPT-6.1 Sol"

# The setting is the one list of models: a codex model no tier ladder and no
# script names launches as the setting writes it.
new_caller
run_succeed unlisted 'codex:gpt-7-nova:high'
assert_eq "$RC|$(launched codex | awk '{print $2}')" "0|gpt-7-nova" \
  "a codex model no list names launches as the setting writes it"

# The order is the setting's alone: an edited order, codex first, opens on
# codex although a claude seat has Fable room, with no code change.
seat fclaude 10 10 10
order_row() { # [SUCCEED_BIN]
  new_caller
  SUCCEED_BIN="${1:-}" run_succeed "order${1:+ctl}" 'codex:gpt-5.6-sol:high,claude:fable:high'
}
order_row
assert_eq "$RC|$(launched claude)|$(launched codex | awk '{print $2}')" "0|none|gpt-5.6-sol" \
  "an edited order is walked in the setting's order"
# Its control: a walk that reads a built-in order in place of the setting
# opens on Opus, the built-in first entry, and ignores the edit.
ORDERCTL="$(mutant_scripts orderctl lib/overseer-launch.sh)" || exit 1
mutate_file "$ORDERCTL/lib/overseer-launch.sh" \
  '"${ORCH_OVERSEER_PREFERENCE-$OL_DEFAULT_PREFERENCE}"' '"$OL_DEFAULT_PREFERENCE"'
order_row "$ORDERCTL/oversee-succeed"
assert_eq "$RC|$(launched claude | awk '{print $2}')|$(launched codex)" "0|claude-opus-5-5|none" \
  "control: a walk on a built-in order ignores the edited setting"

# A copilot entry: `lanes pick --harness copilot` judges a Copilot account on
# its monthly pool, so the entry opens on the account the pick names, its
# status line writing the session record the successor's context is read
# from, with the model and effort the entry names and the full-bypass word
# copilot's row writes for the claude caller's.
COP_SL="$TMP_ROOT/sl/copilot-statusline"
mkdir -p "$TMP_ROOT/sl" "$H/.1copilot"
printf '#!/bin/sh\n' > "$COP_SL"
chmod +x "$COP_SL"
printf '{"copilot_tokens":"gho_fixture"}\n' > "$H/.1copilot/config.json"
printf '{"statusLine":{"type":"command","command":"%s","refreshInterval":30}}\n' "$COP_SL" > "$H/.1copilot/settings.json"
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":900}}}' > "$FIXTURE_DIR/.1copilot.json"
copilot_row() { # [SUCCEED_BIN]
  new_caller
  LANE_DIRS="$H/.claude:$H/.eclaude:$H/.fclaude:$H/.codex:$H/.dcodex:$H/.1copilot" \
    SUCCEED_BIN="${1:-}" run_succeed "copilot${1:+ctl}" 'copilot:gpt-5.3-codex:high'
}
copilot_row
assert_eq "$RC|$(caller_open)|$(launched copilot)|$(grep -cx -e --reasoning-effort -e high -e "$(launch_choice_permission_write copilot)" "$TMP_ROOT/argv.copilot")" \
  "0|no|$H/.1copilot gpt-5.3-codex|3" \
  "a copilot entry opens on the picked copilot account with its model and effort"
# Its control: with `lanes` judging no copilot pick, the copilot entry has no
# account to open on, and the walk refuses and opens nothing.
COPILOTCTL="$(mutant_scripts copilotctl lib/lane-launch.sh)" || exit 1
mutate_file "$COPILOTCTL/lib/lane-launch.sh" '    claude | codex | copilot) printf' '    claude | codex) printf'
copilot_row "$COPILOTCTL/oversee-succeed"
assert_eq "$RC|$(first_key)|$(launched copilot)" "1|lanes-failed|none" \
  "control: with lanes judging no copilot pick the copilot entry refuses and opens nothing"

# Numeric entries keep the observed launch model before account normalization,
# or the flags-only model where the caller has no recorded model. The supplied
# preference effort replaces the caller flags' low effort.
mkdir -p "$H/.2copilot"
cp "$H/.1copilot/"*.json "$H/.2copilot/"
cp "$FIXTURE_DIR/.1copilot.json" "$FIXTURE_DIR/.2copilot.json"
seat eclaude 10 10 10
codex_seat codex 99
codex_seat dcodex 20
for row in \
  'claude|observed|claude-fable-5-1|CLAUDE_CONFIG_DIR|eclaude|--effort|high|2' \
  'codex|observed|gpt-5.6-sol|CODEX_HOME|dcodex|model_reasoning_effort=high|model_reasoning_effort=high|1' \
  'claude|flags|claude-fable-5-1|CLAUDE_CONFIG_DIR|eclaude|--effort|high|2' \
  'codex|flags|gpt-5.6-sol|CODEX_HOME|dcodex|model_reasoning_effort=high|model_reasoning_effort=high|1' \
  'copilot|flags|gpt-5.3-codex|COPILOT_HOME|2copilot|--reasoning-effort|high|2' \
  'pi|flags|pi-claude/claude-fable-5-1|CLAUDE_CONFIG_DIR|eclaude|--thinking|high|2'; do
  IFS='|' read -r harness source model var successor effort_word effort_value effort_count <<<"$row"
  permission=""
  [[ "$harness" == pi ]] || permission="$(launch_choice_permission_write "$harness")" || exit 1
  if [[ "$source" == observed ]]; then
    new_caller "$harness"
    CALLER_FLAGS=("$permission")
  else
    new_caller "$harness" ""
    case "$harness" in
      claude) CALLER_FLAGS=(--model "$model" --effort low "$BYPASS") ;;
      codex) CALLER_FLAGS=(-m "$model" -c model_reasoning_effort=low "$permission") ;;
      copilot) CALLER_FLAGS=(--model "$model" --reasoning-effort low "$permission") ;;
      pi) CALLER_FLAGS=(--provider pi-claude --model claude-fable-5-1 --thinking low) ;;
    esac
  fi
  caller_lane="$H/.$harness"
  case "$harness" in pi) caller_lane="$H/.claude" ;; copilot) caller_lane="$H/.1copilot" ;; esac
  # Copilot names its account from the launch record, never COPILOT_HOME in
  # an external recovery process. Leave the model empty to exercise flags.
  if [[ "$harness" == copilot ]]; then
    jq -n --arg server "$SERVER_PID" --argjson start "$SERVER_START" --arg pane "$CALLER_PANE" \
      --arg account "$caller_lane" \
      '{issue_id: "oversee", overseer: {runtime: "tmux", generation: 1, server: $server,
        server_start: $start, pane: $pane, harness: "copilot", account: $account,
        home: $account, model: "", effort: "", cwd: null, launch_line: "recorded"}}' \
      > "$TMP_ROOT/work/tmp/workflow-state-oversee.json"
  fi
  CALLER_LANE="$var=$caller_lane" LANE_DIRS="$H/.claude:$H/.eclaude:$H/.codex:$H/.dcodex:$H/.1copilot:$H/.2copilot" \
    run_succeed "numeric-$harness-$source" "$harness:1:high" --walled-pane "$CALLER_PANE" --harness "$harness"
  launch_home="$H/.$successor"
  if [[ "$harness" == codex ]]; then
    # The only private home under this account is the one this fixture opens.
    # Discover it independently of the launch builder, then pin CODEX_HOME.
    CODEX_LAUNCH_HOME="$(find "$H/.dcodex/lane-launch" -mindepth 2 -maxdepth 2 -type d -name home)" || exit 1
    [[ -n "$CODEX_LAUNCH_HOME" && "$CODEX_LAUNCH_HOME" != *$'\n'* ]] || { echo 'fixture: codex-home=not-single' >&2; exit 1; }
    launch_home="$CODEX_LAUNCH_HOME"
  fi
  assert_eq "$RC|$(caller_open)|$(launched "$harness")|$(grep -cx -e "$effort_word" -e "$effort_value" "$TMP_ROOT/argv.$harness")|$(grep '^preference-deprecated ' <<<"$OUT")" \
    "0|no|$launch_home $model|$effort_count|preference-deprecated entry=$harness:1:high form=harness:model:effort" \
    "numeric $harness preference keeps the $source model and supplied effort" "$TMP_ROOT/out"
done
# Normalizing the observed Codex model for account measurement must not erase
# the model passed to its successor. A flags-only Codex caller covers the other
# source of the same launch identity. Dropping either source takes the default
# preference model instead of the caller's model asserted above.
permission="$(launch_choice_permission_write codex)" || exit 1
for control in observed flags; do
  NUMERICCTL="$(mutant_scripts "numeric-$control-ctl" oversee-succeed)" || exit 1
  case "$control" in
    observed)
      mutate_file "$NUMERICCTL/oversee-succeed" '  OL_PREFERENCE_CALLER_MODEL="$caller_model"' '  : OL_PREFERENCE_CALLER_MODEL="$caller_model"; OL_PREFERENCE_CALLER_MODEL="$CALLER_MODEL"'
      new_caller codex
      CALLER_FLAGS=("$permission") ;;
    flags)
      mutate_file "$NUMERICCTL/oversee-succeed" '  caller_model="${OL_KNOWN_MODEL:-${reading_model:-$flag_model}}"' '  : caller_model="${OL_KNOWN_MODEL:-${reading_model:-$flag_model}}"; caller_model="${OL_KNOWN_MODEL:-$reading_model}"'
      new_caller codex ""
      CALLER_FLAGS=(-m gpt-5.6-sol -c model_reasoning_effort=low "$permission") ;;
  esac
  CALLER_LANE="CODEX_HOME=$H/.codex" SUCCEED_BIN="$NUMERICCTL/oversee-succeed" \
    run_succeed "numeric-$control-ctl" 'codex:1:high' --walled-pane "$CALLER_PANE" --harness codex
  assert_eq "$RC|$(launched codex)|$(grep -cx 'model_reasoning_effort=high' "$TMP_ROOT/argv.codex")" \
    "0|$CODEX_LAUNCH_HOME gpt-6.1-sol|1" "control: dropping the $control model breaks numeric launch identity"
done
CALLER_FLAGS=("$BYPASS")
seat eclaude 10 99 10
codex_seat dcodex 99

# A codex overseer under a permission posture no claude word matches, the
# setting unset: the ladder's claude entries are skipped before their picks,
# although a claude seat has Fable room, and the walk reaches the codex entry,
# whose successor keeps the caller's permission words.
seat eclaude 10 10 10
codex_seat codex 99
codex_seat dcodex 20
new_caller codex
CALLER_FLAGS=(-m gpt-5.6-sol -c model_reasoning_effort=high -a never)
CALLER_LANE="CODEX_HOME=$H/.codex" run_succeed codexcaller unset
assert_eq "$RC|$(keyed entry-permission-untransferable)|$(launched claude)|$(launched codex | sed "s|^$H/.dcodex[^ ]* |dcodex |")|$(grep -cx never "$TMP_ROOT/argv.codex")" \
  "0|oversee-succeed: entry-permission-untransferable entry=claude:claude-opus-5-5:high source=codex target=claude|none|dcodex gpt-6.1-sol|1" \
  "a codex caller whose permission words cannot cross skips the claude entries and succeeds on codex"
# Its control: a walk that chooses the claude entry anyway refuses after it,
# launching nothing.
SKIPCTL="$(mutant_scripts skipctl lib/overseer-launch.sh)" || exit 1
mutate_file "$SKIPCTL/lib/overseer-launch.sh" '      ol_entry_permitted "$permitted_entry" || continue' '      : ol_entry_permitted "$permitted_entry" || continue'
new_caller codex
CALLER_LANE="CODEX_HOME=$H/.codex" SUCCEED_BIN="$SKIPCTL/oversee-succeed" run_succeed skipctl unset
assert_eq "$RC|$(first_key)|$(launched claude)|$(launched codex)" \
  "1|launch-choice-failed|none|none" \
  "control: a walk that chooses the untransferable entry refuses and launches nothing"
CALLER_FLAGS=("$BYPASS")

# A Copilot overseer whose ladder starts on claude, under the whole line a
# Copilot overseer runs: the deprecated numeric entry would run the caller's
# Copilot model spelling on the claude CLI, so it is skipped with the keyed
# line naming that model, and the named Opus entry launches on claude's own
# words alone, the caller's full bypass written as claude's. No other caller
# word crosses: the run mode, its count, the context tier and the update
# setting are all words of the Copilot CLI.
COPILOT_LINE=(--model claude-opus-5.5 --reasoning-effort high --yolo --autopilot
  --max-autopilot-continues 5 --context long_context --no-auto-update)
CLAUDE_COMPACT="$(launch_choice_compaction_off claude)"
BRIEF='Read .agents/skills/orch/SKILL.md and execute the orch oversee workflow after reading the overseer handoff at tmp/handoffs/OVERSEER-HANDOFF.md'
# copilot_ladder ROW walled|check|context|below [SUCCEED_BIN] [caller|empty|restricted] [PREFERENCE] — the
# Copilot caller, its launch record naming its account, run as the wall
# recovery under its whole line, as a succession past its context mark
# (`context`) or below it (`below`), or as --check-marks, handed no flags,
# against the same preference.
copilot_ladder() { # ROW walled|check|context|below [SUCCEED_BIN] [caller|empty|restricted] [PREFERENCE]
  local -a mode_args=(--walled-pane)
  local no_wait=""
  new_caller copilot ""
  # The shipped Copilot usage hook records an empty model.
  lane_context_record "$MAILBOX_DIR" copilot 100000 800000 "" "" "$SERVER_PID $CALLER_PANE"
  jq -n --arg server "$SERVER_PID" --argjson start "$SERVER_START" --arg pane "$CALLER_PANE" \
    --arg account "$H/.1copilot" \
    '{issue_id: "oversee", overseer: {runtime: "tmux", generation: 1, server: $server,
      server_start: $start, pane: $pane, harness: "copilot", account: $account,
      home: $account, model: "", effort: "", cwd: null, launch_line: "recorded"}}' \
    > "$TMP_ROOT/work/tmp/workflow-state-oversee.json"
  CALLER_FLAGS=("${COPILOT_LINE[@]}")
  case "${4:-caller}" in
    empty) CALLER_FLAGS=("${COPILOT_LINE[@]:2}") ;;
    restricted) CALLER_FLAGS=(--allow-all-tools) ;;
  esac
  case "$2" in
    check) CALLER_FLAGS=() mode_args=(--check-marks) no_wait=1 ;;
    context) mode_args=(--context 790000:800000) ;;
    below) mode_args=(--context 100000:800000) ;;
    *) mode_args+=("$CALLER_PANE") ;;
  esac
  CALLER_LANE="COPILOT_HOME=$H/.1copilot" LANE_DIRS="$H/.claude:$H/.eclaude:$H/.1copilot:$H/.2copilot" \
    SUCCEED_BIN="${3:-}" NO_WAIT="$no_wait" \
    run_succeed "$1" "${5-claude:1:high,claude:claude-opus-5-5:high}" "${mode_args[@]}" --harness copilot
  CALLER_FLAGS=("$BYPASS")
}
# claude_argv — the claude successor's recorded lane and argv, `;`-joined.
claude_argv() { if [[ -f "$TMP_ROOT/argv.claude" ]]; then tr '\n' ';' < "$TMP_ROOT/argv.claude"; else printf none; fi; }
CLAUDE_SUCCESSOR="lane=$H/.eclaude;-n;overseer;--model;claude-opus-5-5;--effort;high;$BYPASS;$CLAUDE_COMPACT"
copilot_ladder copilotcaller walled
assert_eq "$RC|$(keyed entry-permission-untransferable)|$(claude_argv)" \
  "0|oversee-succeed: entry-permission-untransferable entry=claude::high source=copilot target=claude model=claude-opus-5.5|$CLAUDE_SUCCESSOR;$BRIEF;" \
  "a Copilot caller onto claude skips the numeric entry and carries no Copilot word onto the claude line"
# Its controls, one per rule: a walk that hands the caller's other words on,
# as the cross-harness line once did, puts the Copilot words on the claude
# line, and a walk that admits the numeric entry hands claude the Copilot
# model spelling.
CARRYCTL="$(mutant_scripts carryctl lib/overseer-launch.sh)" || exit 1
mutate_file "$CARRYCTL/lib/overseer-launch.sh" '    LAUNCH_CHOICE_KEPT=()' '    launch_choice_strip "$source" "$@"'
copilot_ladder carryctl walled "$CARRYCTL/oversee-succeed"
assert_eq "$RC|$(claude_argv)" \
  "0|$CLAUDE_SUCCESSOR;--yolo;--autopilot;--max-autopilot-continues;5;$BRIEF;" \
  "control: a cross-harness line keeping the caller's other words carries Copilot's run mode onto claude"
NUMCTL="$(mutant_scripts numctl lib/overseer-launch.sh)" || exit 1
mutate_file "$NUMCTL/lib/overseer-launch.sh" '  if [[ "$1" == *::* ]]; then' '  if false; then'
copilot_ladder numctl walled "$NUMCTL/oversee-succeed"
assert_eq "$RC|$(keyed entry-permission-untransferable)|$(launched claude)" "0|none|$H/.eclaude claude-opus-5.5" \
  "control: a walk admitting the numeric entry hands claude the Copilot model spelling"

# A walled Copilot account with no recorded, observed or flagged model must
# reach the numeric target's available account. A caller-spelled model still
# cannot cross harnesses, and resolving a model does not transfer permissions.
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":0}}}' > "$FIXTURE_DIR/.1copilot.json"
cp "$FIXTURE_DIR/.1copilot.json" "$FIXTURE_DIR/.2copilot.json"
for row in 'empty|0|none' 'caller|3|model' 'restricted|3|permission'; do
  IFS='|' read -r source expected_rc skip_kind <<<"$row"
  copilot_ladder "numeric-target-$source" walled "" "$source" 'claude:1:high'
  assert_eq "$RC" "$expected_rc" "numeric target resolution retains the $source eligibility rule"
  if [[ "$skip_kind" == none ]]; then
    assert_eq "$(keyed entry-permission-untransferable)|$(claude_argv)" \
      "none|$CLAUDE_SUCCESSOR;$BRIEF;" \
      "a model-less walled Copilot caller reaches the numeric Claude target with its model and effort"
  else
    assert_eq "$(launched claude)|$(keyed no-lane-qualifies | awk '{print $2}')" "none|no-lane-qualifies" \
      "a numeric target cannot bypass the $skip_kind rule"
    assert_contains "$OUT" 'oversee-succeed: entry-permission-untransferable ' "the numeric target records its eligibility refusal"
  fi
done
TARGETCTL="$(mutant_scripts targetctl lib/overseer-launch.sh)" || exit 1
mutate_file "$TARGETCTL/lib/overseer-launch.sh" \
  '[[ -z "$OL_ENTRY_MODEL" ]] || permitted_entry="$OL_ENTRY_HARNESS:$OL_ENTRY_MODEL:$OL_ENTRY_EFFORT"' \
  ': [[ -z "$OL_ENTRY_MODEL" ]] || permitted_entry="$OL_ENTRY_HARNESS:$OL_ENTRY_MODEL:$OL_ENTRY_EFFORT"'
copilot_ladder targetctl walled "$TARGETCTL/oversee-succeed" empty 'claude:1:high'
assert_eq "$RC|$(launched claude)" "3|none" \
  "control: treating the target default as caller-derived loses the available Claude successor"
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":900}}}' > "$FIXTURE_DIR/.1copilot.json"
# The judgement oversee-watch and the turn-end hook ask, --check-marks, walks
# the same preference to learn whether a qualifying mark has a successor: the
# other Copilot account has more room than the caller's, and two accounts
# above the trigger are at the setting. With no caller model, the numeric
# Claude entry resolves the target model and settles the mark.
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":950}}}' > "$FIXTURE_DIR/.2copilot.json"
SUCCESSOR_ACCOUNTS=2 copilot_ladder copilotcheck check
assert_eq "$RC|$(keyed mark-reached)|$(keyed entry-permission-untransferable)" \
  "0|oversee-succeed: mark-reached kind=qualifying value=2 mark=2 succession=on headroom=90|none" \
  "the check judgement of a model-less Copilot caller resolves the numeric Claude entry"
# A target with no transferable permission posture stays a silent skip in
# check mode. Pi's launch row supplies that independent permission refusal.
SUCCESSOR_ACCOUNTS=2 copilot_ladder quietcheck check "" empty 'pi:openai/gpt-5:high,claude:1:high'
assert_eq "$RC|$(keyed entry-permission-untransferable)" "0|none" \
  "the check judgement keeps an untransferable permission skip silent"
QUIETCTL="$(mutant_scripts quietctl lib/overseer-launch.sh)" || exit 1
mutate_file "$QUIETCTL/lib/overseer-launch.sh" \
  $'\n  (( OL_WALK_SOURCE_ROWS )) \\' $'\n  (( OL_WALK_SOURCE_ROWS )) && false \\'
SUCCESSOR_ACCOUNTS=2 copilot_ladder quietctl check "$QUIETCTL/oversee-succeed" empty 'pi:openai/gpt-5:high,claude:1:high'
assert_eq "$RC|$(keyed entry-permission-untransferable)" \
  "0|oversee-succeed: entry-permission-untransferable entry=pi:openai/gpt-5:high source=copilot target=pi" \
  "control: a check that does not keep the permission skip silent prints it"
cp "$FIXTURE_DIR/.1copilot.json" "$FIXTURE_DIR/.2copilot.json"

# A Copilot caller whose pool nothing measures, its login unreadable, past its
# context mark, with the other Copilot account spent: its successor spends the
# pool the caller already spends, so the walk keeps the caller's own account,
# names it with the record's status and detail, and writes one fleet-log row.
COPILOT_WALLED='{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":0}}}'
mv "$H/.1copilot/config.json" "$H/.1copilot/config.json.held"
printf '%s\n' "$COPILOT_WALLED" > "$FIXTURE_DIR/.2copilot.json"
# kept_line — the keyed line with its detail value cut, which is the record's
# own words; `none` where the run printed none.
kept_line() { grep -m1 '^oversee-succeed: successor-account-unmeasured ' <<<"$OUT" | sed 's/ detail=.*/ detail=/' || echo none; }
kept_rows() { jq -r '[(.fleet_log // [])[] | select(.text | startswith("oversee-succeed: successor-account-unmeasured "))] | length' "$TMP_ROOT/work/tmp/workflow-state-oversee.json"; }
KEPT_LINE="oversee-succeed: successor-account-unmeasured lane=$H/.1copilot status=no_credentials detail="
copilot_ladder unmeasuredkeep context "" caller ''
assert_eq "$RC|$(kept_line)|$(kept_rows)|$(caller_open)|$(launched copilot)" \
  "0|$KEPT_LINE|1|no|$H/.1copilot claude-opus-5.5" \
  "an unmeasured Copilot caller past its context mark keeps its own account, named once on stdout and in the fleet log"
# Its control: a walk that never keeps the unmeasured account refuses.
KEEPCTL="$(mutant_scripts keepctl oversee-succeed)" || exit 1
mutate_file "$KEEPCTL/oversee-succeed" \
  '  [[ "$CALLER_STATE:$MARK_KIND" != unmeasured:context ]] || OL_WALK_KEEP_UNMEASURED="$CALLER_ACCOUNT_HARNESS"' ''
copilot_ladder keepctl context "$KEEPCTL/oversee-succeed" caller ''
assert_eq "$RC|$(first_key)|$(caller_open)|$(launched copilot)" "3|no-lane-qualifies|yes|none" \
  "control: a walk that never keeps the unmeasured account refuses no-lane-qualifies"
# A Copilot-first preference with Claude room: the named Copilot entry's pick
# finds no Copilot account with room, so it keeps the caller's own account and
# launches its own model and effort there, ahead of the Claude entry.
copilot_ladder unmeasuredfirst context "" caller 'copilot:claude-opus-5.5:high,claude:claude-opus-5-5:high'
assert_eq "$RC|$(kept_line)|$(launched copilot)|$(grep -cx -e --reasoning-effort -e high "$TMP_ROOT/argv.copilot")|$(launched claude)" \
  "0|$KEPT_LINE|$H/.1copilot claude-opus-5.5|2|none" \
  "a Copilot-first preference keeps the unmeasured caller's own account ahead of a Claude account with room"
# Policy refusal and a recovered usage fetch reach both forms of the fallback.
# The fetch command fails once for the caller, as a transport failure does,
# then serves the spent pool through the shared usage fixture.
RECOVER_FETCH="$TMP_ROOT/recover-fetch"
cat > "$RECOVER_FETCH" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$2" == "$H/.1copilot" && ! -f "$TMP_ROOT/recovered" ]]; then
  : > "$TMP_ROOT/recovered"
  exit 1
fi
exec "$FETCHER" "\$@"
STUB
chmod +x "$RECOVER_FETCH"
POLICYCTL="$(mutant_scripts retained-policy lib/overseer-launch.sh)" || exit 1
mutate_file "$POLICYCTL/lib/overseer-launch.sh" \
  '        ol_lanes check "$OL_WALK_CALLER_LANE" >/dev/null 2>"$DEP_ERR" || rc=$?' \
  '        : ol_lanes check "$OL_WALK_CALLER_LANE" >/dev/null 2>"$DEP_ERR" || rc=$?'
MEASURECTL="$(mutant_scripts retained-account lib/overseer-launch.sh)" || exit 1
mutate_file "$MEASURECTL/lib/overseer-launch.sh" \
  '        ol_pick_record "$OL_HARNESS" "$OL_PICK_MODEL" "$trigger" "" "$OL_WALK_CALLER_LANE" || rc=$?' \
  '        ol_pick_record "$OL_HARNESS" "$OL_PICK_MODEL" "$trigger" "" "$OL_WALK_CALLER_LANE" || rc=$?; rc=5'
for entry in caller named; do
  pref=''
  [[ "$entry" != named ]] || pref='copilot:claude-opus-5.5:high'
  for refusal in retired excluded recovered; do
    LANE_RETIRE="" LANE_EXCLUDE="" LANES_FETCHER="$FETCHER"
    case "$refusal" in
      retired) LANE_RETIRE='1copilot=2000-01-01' ;;
      excluded) LANE_EXCLUDE=1copilot ;;
      recovered)
        mv "$H/.1copilot/config.json.held" "$H/.1copilot/config.json"
        printf '%s\n' "$COPILOT_WALLED" > "$FIXTURE_DIR/.1copilot.json"
        rm -f "$TMP_ROOT/recovered"
        LANES_FETCHER="$RECOVER_FETCH"
        ;;
    esac
    copilot_ladder "retained-$entry-$refusal" context "" caller "$pref"
    assert_eq "$RC|$(keyed no-lane-qualifies | awk '{print $2}')|$(kept_line)|$(kept_rows)|$(caller_open)|$(launched copilot)" \
      '3|no-lane-qualifies|none|0|yes|none' \
      "the $entry entry refuses the $refusal caller at the context fallback"
    case "$refusal" in
      retired)
        copilot_ladder "retained-$entry-policy-control" context "$POLICYCTL/oversee-succeed" caller "$pref"
        assert_eq "$RC|$(caller_open)|$(launched copilot)" \
          "0|no|$H/.1copilot claude-opus-5.5" \
          "control: the $entry entry launches a retired caller when retention omits the policy check"
        ;;
      recovered)
        assert_eq "$(jq -r 'select(.config_dir == $d) | .usage.quota_snapshots.premium_interactions.remaining' \
          --arg d "$H/.1copilot" "$TMP_ROOT/state-retained-$entry-$refusal/usage/"*.json)" \
          0 "the recovered fetch measured the $entry caller's spent pool before refusal"
        rm -f "$TMP_ROOT/recovered"
        copilot_ladder "retained-$entry-measure-control" context "$MEASURECTL/oversee-succeed" caller "$pref"
        assert_eq "$RC|$(caller_open)|$(launched copilot)" \
          "0|no|$H/.1copilot claude-opus-5.5" \
          "control: the $entry entry launches the spent caller when retention ignores its current account verdict"
        mv "$H/.1copilot/config.json" "$H/.1copilot/config.json.held"
        ;;
    esac
  done
done
LANE_RETIRE="" LANE_EXCLUDE="" LANES_FETCHER="$FETCHER"
# Below the context mark nothing is kept: with one other Copilot account
# with room the qualifying mark fires, its successor must move, and the walk
# opens it on that account, never on the caller's unmeasured one.
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":900}}}' > "$FIXTURE_DIR/.2copilot.json"
SUCCESSOR_ACCOUNTS=1 copilot_ladder unmeasuredqualifying below "" caller ''
assert_eq "$RC|$(kept_line)|$(launched copilot)" "0|none|$H/.2copilot claude-opus-5.5" \
  "an unmeasured Copilot caller at the qualifying mark moves off its own account"
printf '%s\n' "$COPILOT_WALLED" > "$FIXTURE_DIR/.2copilot.json"
# The headroom mark: the caller's own account measured at the trigger and the
# other spent, so no account qualifies and the caller's is not kept.
mv "$H/.1copilot/config.json.held" "$H/.1copilot/config.json"
printf '%s\n' "$COPILOT_WALLED" > "$FIXTURE_DIR/.1copilot.json"
copilot_ladder measuredwall below "" caller ''
assert_eq "$RC|$(keyed no-lane-qualifies | awk '{print $2, $7}')|$(kept_line)|$(caller_open)|$(launched copilot)" \
  "3|no-lane-qualifies mark=headroom|none|yes|none" \
  "a Copilot caller at its headroom mark with no account qualifying still refuses"
# An unreadable judge keeps nothing: a usage TTL `lanes` refuses before it
# measures anything leaves the account judge without an answer, and the
# caller entry still goes through its pick, whose refusal ends the run.
USAGE_TTL=forever copilot_ladder unreadablejudge context "" caller ''
assert_eq "$RC|$(keyed lanes-failed | awk '{print $2, $3}')|$(kept_line)|$(caller_open)|$(launched copilot)" \
  "1|lanes-failed entry=caller|none|yes|none" \
  "an unreadable judge keeps no account and the caller entry refuses on its own pick"
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":900}}}' > "$FIXTURE_DIR/.1copilot.json"
cp "$FIXTURE_DIR/.1copilot.json" "$FIXTURE_DIR/.2copilot.json"

# The ladder's first rung: the first claude seat with Opus room takes an Opus
# successor, ahead of another seat with room for both Fable and Opus.
seat claude 10 99 99
seat eclaude 10 99 10
seat fclaude 10 10 10
codex_seat codex 99
codex_seat dcodex 99
new_caller
run_succeed fable unset
assert_eq "$RC|$(launched claude)|$(launched codex)" \
  "0|$H/.eclaude claude-opus-5-5|none" \
  "the default ladder opens on Opus on the first seat with Opus room"

# A pi overseer on the pi-claude provider, its pane naming no harness and its
# launch record naming pi, Fable and the account .claude, whose Fable and Opus
# windows are spent. Its wall recovery walks a pi entry on Opus, which spends a
# claude account: the pick leaves the walled account out and lands on .eclaude.
FLEET_STATE="$TMP_ROOT/work/tmp/workflow-state-oversee.json"
new_pi_caller() { # [norecord]
  fixture_watch_stop "$FLEET_STATE"
  tm kill-window -a -t "$KEEP_WINDOW"
  tm move-window -r -t fleet
  rm -f -- "${TMP_ROOT:?}"/argv.* "${FLEET_STATE:?}"
  CALLER_PANE="$(tm new-window -d -t fleet:1 -c "$TMP_ROOT/work" -P -F '#{pane_id}' 'exec sleep 100000')"
  CALLER_WINDOW="$(tm display-message -p -t "$CALLER_PANE" '#{window_id}')"
  printf '{"issue_id": "oversee", "overseer": {"generation": 1}}\n' > "$FLEET_STATE"
  fixture_watch_predecessor "$SUCCEED" "$FLEET_STATE" "$TMP_ROOT/work" "$CALLER_PANE"
  [[ "${1:-}" != norecord ]] || return 0
  jq -n --arg server "$SERVER_PID" --arg pane "$CALLER_PANE" --arg account "$H/.claude" --arg cwd "$TMP_ROOT/work" \
    --argjson start "$SERVER_START" \
    '{issue_id: "oversee", overseer: {runtime: "tmux", generation: 1, server: $server, pane: $pane,
      harness: "pi", account: $account, home: $account, model: "pi-claude/claude-fable-5-1",
      effort: "high", cwd: $cwd, launch_line: "recorded", server_start: $start}}' > "$FLEET_STATE"
}
# The walled account's own Opus window has room, so the walled exclusion alone
# keeps the pick off it, as for the claude recovery above.
seat claude 10 99 10
seat eclaude 10 99 10
CALLER_FLAGS=(--model pi-claude/claude-fable-5-1 --thinking high)
new_pi_caller
run_succeed piwalled 'pi:pi-claude/claude-opus-5-5:high' --walled-pane "$CALLER_PANE" --harness pi
assert_eq "$RC|$(caller_open)|$(launched pi)|$(grep -cx -e --thinking -e high "$TMP_ROOT/argv.pi")|$(tail -n 1 "$TMP_ROOT/argv.pi")" \
  "0|no|$H/.eclaude pi-claude/claude-opus-5-5|2|/skill:orch oversee after reading the overseer handoff at tmp/handoffs/OVERSEER-HANDOFF.md" \
  "a walled pi overseer is recovered onto a pi entry with a model, on a claude account with room for it"
seat claude 10 99 99
# Its control: a preference parse naming no pi refuses the entry.
PIPARSECTL="$(mutant_scripts piparsectl lib/overseer-launch.sh)" || exit 1
mutate_file "$PIPARSECTL/lib/overseer-launch.sh" \
  '       || "$parsed_entry" =~ ^pi:[a-z][a-z0-9.-]*/[a-z0-9][a-z0-9._/-]*:[a-z]+$ ]]' '       ]]'
new_pi_caller
SUCCEED_BIN="$PIPARSECTL/oversee-succeed" run_succeed piparsectl 'pi:pi-claude/claude-opus-5-5:high' --walled-pane "$CALLER_PANE" --harness pi
assert_eq "$RC|$(first_key)|$(caller_open)|$(launched pi)" "1|invalid-preference|yes|none" \
  "control: a preference parse naming no pi refuses the pi entry"
# A pi entry naming no provider is no pi model: refused as a setting to fix.
new_pi_caller
run_succeed pinomodel 'pi:fable:high' --walled-pane "$CALLER_PANE" --harness pi
assert_eq "$RC|$(keyed invalid-preference | awk '{print $2, $3}')|$(caller_open)|$(launched pi)" \
  "1|invalid-preference entry=pi:fable:high|yes|none" \
  "a pi entry with no provider/id model refuses invalid-preference"
# A pi caller whose model is split across --provider and --model, handed to a
# pi entry on another provider: the successor line is the entry's alone, its
# model naming its own provider and no --provider word of the caller's beside
# it, which would move the successor onto the caller's provider.
CALLER_FLAGS=(--provider pi-claude --model claude-fable-5-1 --thinking high)
pi_provider_row() { # [SUCCEED_BIN]
  new_pi_caller
  SUCCEED_BIN="${1:-}" run_succeed "piprovider${1:+ctl}" 'pi:openai-codex/gpt-5.6-terra:high' \
    --walled-pane "$CALLER_PANE" --harness pi
}
pi_provider_row
assert_eq "$RC|$(launched pi)|$(grep -cx -e --provider "$TMP_ROOT/argv.pi")" \
  "0| openai-codex/gpt-5.6-terra|0" \
  "a split --provider pi caller's successor on another provider carries no --provider word"
# Its control: a strip that leaves the provider word keeps the caller's.
PIPROVCTL="$(mutant_scripts piprovctl lib/lane-launch.sh)" || exit 1
mutate_file "$PIPROVCTL/lib/lane-launch.sh" \
  '  words="$(launch_choice_model_spellings "$1") $(launch_choice_provider_spelling "$1")"' \
  '  words="$(launch_choice_model_spellings "$1")"'
pi_provider_row "$PIPROVCTL/oversee-succeed"
assert_eq "$RC|$(grep -cx -e --provider "$TMP_ROOT/argv.pi")" "0|1" \
  "control: a strip that leaves the provider word hands the successor the caller's"
CALLER_FLAGS=(--model pi-claude/claude-fable-5-1 --thinking high)

# A pi-claude overseer nothing recorded, at its context mark with Fable room
# on its own account: its --model word names the provider, so its successor
# keeps that claude account.
seat claude 10 10 99
pi_context_row() { # [SUCCEED_BIN]
  new_pi_caller norecord
  SUCCEED_BIN="${1:-}" run_succeed "pictx${1:+ctl}" '' --harness pi --context 950000:1000000
}
pi_context_row
assert_eq "$RC|$(caller_open)|$(launched pi)" "0|no|$H/.claude pi-claude/claude-fable-5-1" \
  "a record-less pi-claude overseer at its context mark succeeds on its own claude account"
# Its control: a caller that reads no --model word cannot name the account
# and refuses, launching nothing.
PICTXCTL="$(mutant_scripts pictxctl oversee-succeed)" || exit 1
mutate_file "$PICTXCTL/oversee-succeed" '    caller_model="$(ol_pi_model "$OL_KNOWN_MODEL" "$flag_model" "$reading_model")"' '    caller_model="$(ol_pi_model "$OL_KNOWN_MODEL" "" "$reading_model")"'
pi_context_row "$PICTXCTL/oversee-succeed"
assert_eq "$RC|$(keyed pi-account-unknown | awk '{print $2}')|$(caller_open)|$(launched pi)" \
  "1|pi-account-unknown|yes|none" \
  "control: a caller that reads no --model word refuses the record-less pi overseer's succession"
rm -f -- "${FLEET_STATE:?}"
seat claude 10 99 99
CALLER_FLAGS=("$BYPASS")

# A claude overseer under full bypass: the pi row names no permission word, so
# its pi entry is skipped before its pick and the walk ends on its own harness.
pi_skip_row() { # [SUCCEED_BIN]
  new_caller
  SUCCEED_BIN="${1:-}" run_succeed "piskip${1:+ctl}" 'pi:pi-claude/claude-opus-5-5:high'
}
pi_skip_row
assert_eq "$RC|$(keyed entry-permission-untransferable)|$(launched pi)|$(launched claude | awk '{print $1}')" \
  "0|oversee-succeed: entry-permission-untransferable entry=pi:pi-claude/claude-opus-5-5:high source=claude target=pi|none|$H/.fclaude" \
  "a claude caller skips a pi entry no permission posture crosses to"
# Its control: a walk that asks the source row alone chooses the pi entry and
# then refuses, launching nothing.
PISKIPCTL="$(mutant_scripts piskipctl lib/overseer-launch.sh)" || exit 1
mutate_file "$PISKIPCTL/lib/overseer-launch.sh" '  if launch_choice_permission_write "$OL_HARNESS" >/dev/null; then' '  if true; then'
pi_skip_row "$PISKIPCTL/oversee-succeed"
assert_eq "$RC|$(first_key)|$(launched pi)|$(launched claude)" "1|launch-choice-failed|none|none" \
  "control: a walk that asks the source row alone chooses the pi entry and refuses"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
