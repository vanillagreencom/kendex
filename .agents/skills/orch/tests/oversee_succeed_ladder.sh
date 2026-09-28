#!/usr/bin/env bash
# Tests for the model ladder oversee-succeed's successor walk takes: each
# ORCH_OVERSEER_PREFERENCE entry names the model its successor runs, the pick
# is judged on the bucket that walls that model, and an unset setting walks
# lib/overseer-launch.sh's default ladder. Run over a real tmux server on a
# private socket, as oversee_succeed.sh is; claude, codex, pi and kendex are stubs
# on PATH, and `lanes pick` answers from the lanes-fixture usage bodies. The
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

TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SOCK="oversee-succeed-ladder-$$"
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
tm() { tmux -L "$SOCK" "$@"; }

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN" "$TMP_ROOT/work/tmp"
# A harness stub records its lane and argv and draws the hint a running turn
# shows, so the successor reads as working. A pi successor runs on claude's
# account variable, the one the pi-claude bridge reads.
for harness in claude codex pi; do
  lane_var=CLAUDE_CONFIG_DIR
  [[ "$harness" != codex ]] || lane_var=CODEX_HOME
  cat > "$BIN/$harness" <<STUB
#!/bin/sh
{ printf 'lane=%s\n' "\${$lane_var:-}"; printf '%s\n' "\$@"; } > "$TMP_ROOT/argv.$harness"
echo 'esc to interrupt'
exec sleep 100000
STUB
done
# The tier ladder as `kendex tier-model` answers it, four ranks on each
# harness and a refusal past the fourth.
cat > "$BIN/kendex" <<'STUB'
#!/bin/sh
case "$1:$2:$3" in
  tier-model:claude:1) echo fable ;;
  tier-model:claude:2) echo opus ;;
  tier-model:claude:3) echo sonnet ;;
  tier-model:claude:4) echo haiku ;;
  tier-model:codex:1) echo gpt-6-astra ;;
  tier-model:codex:2) echo gpt-5.6-sol ;;
  tier-model:codex:3) echo gpt-5.6-terra ;;
  tier-model:codex:4) echo gpt-5.6-luna ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BIN/claude" "$BIN/codex" "$BIN/pi" "$BIN/kendex"
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
    five_hour: {utilization: $s, resets_at: "2026-07-27T06:00:00Z"},
    seven_day: {utilization: 20, resets_at: "2026-08-01T06:00:00Z"},
    limits: [{kind: "weekly_scoped", percent: $f, resets_at: "2026-08-01T06:00:00Z",
              scope: {model: {display_name: "Fable 5.1"}}},
             {kind: "weekly_scoped", percent: $o, resets_at: "2026-08-01T06:00:00Z",
              scope: {model: {display_name: "Opus"}}}]
  }' > "$FIXTURE_DIR/.$1.json"
}
codex_seat() { # LANE USED_PCT
  jq -n --argjson u "$2" '{rate_limit: {primary_window: {used_percent: $u, reset_at: 1785000000, limit_window_seconds: 18000}, secondary_window: null}}' \
    > "$FIXTURE_DIR/.$1.json"
}

env PATH="$BIN:$PATH" tmux -L "$SOCK" -f /dev/null new-session -d -s fleet -x 220 -y 50 'exec sleep 100000'
tm set-option -g default-shell /bin/sh
tm set-option -g renumber-windows off
# The successor pane is a non-login shell under this fixture's PATH, so the
# stubs above are the harness it runs.
tm set-option -g default-command "PATH=$BIN:\$PATH; export PATH; exec /bin/sh"
TMUX_ADDR="$(tm display-message -p '#{socket_path},#{pid},0')"
SERVER_PID="$(tm display-message -p '#{pid}')"
# A pane that stays live for the whole run, for a claim to name.
CLAIM_PANE="$(tm display-message -p -t fleet:0 '#{pane_id}')"

MAILBOX_DIR="$TMP_ROOT/work/tmp/lane-mail/overseer"
# new_caller [codex] — an overseer at index 1 well under the context mark,
# Fable on .claude, or with `codex` GPT-5.6 Sol on .codex; sets CALLER_PANE
# and CALLER_WINDOW.
new_caller() {
  local spec cmd="exec '$BIN/hclaude' 100000"
  [[ "${1:-}" != codex ]] || cmd="exec '$TMP_ROOT/cbin/codex' 100000"
  tm kill-window -a -t fleet:0
  rm -f -- "${TMP_ROOT:?}"/argv.*
  spec="$(tm new-window -d -t fleet:1 -P -F '#{pane_id} #{window_id}' "$cmd")"
  read -r CALLER_PANE CALLER_WINDOW <<<"$spec"
  mkdir -p "$MAILBOX_DIR"
  if [[ "${1:-}" == codex ]]; then
    lane_context_record "$MAILBOX_DIR" codex 100000 258400 gpt-5.6-sol "" "$SERVER_PID $CALLER_PANE"
  else
    lane_context_record "$MAILBOX_DIR" claude 100000 1000000 claude-fable-5-1 "" "$SERVER_PID $CALLER_PANE"
  fi
}

# run_succeed ROW PREFERENCE [ARGS...] — the script under an explicit, whole
# environment from the caller pane, ARGS ahead of its flags. The caller runs
# under full bypass on .claude, the one permission posture a successor of the
# other harness takes, unless CALLER_LANE names its account variable and
# CALLER_FLAGS its flags. PREFERENCE `unset` exports no
# ORCH_OVERSEER_PREFERENCE. Sets OUT (both streams) and RC.
CALLER_FLAGS=("$BYPASS")
run_succeed() {
  local row="$1" pref=(ORCH_OVERSEER_PREFERENCE="$2") lane="${CALLER_LANE:-CLAUDE_CONFIG_DIR=$H/.claude}"
  [[ "$2" != unset ]] || pref=()
  shift 2
  RC=0
  OUT="$(cd "$TMP_ROOT/work" && env -i HOME="$H" PATH="$BIN:$PATH" TMUX="$TMUX_ADDR" TMUX_PANE="$CALLER_PANE" \
    LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state-$row" \
    "$lane" ORCH_LANES_FETCH_CMD="$FETCHER" \
    ORCH_LANE_DIRS="$H/.claude:$H/.eclaude:$H/.fclaude:$H/.codex:$H/.dcodex" ORCH_LANES_USAGE_TTL=0 \
    ORCH_OVERSEER_WALL_MINUTES=0 ORCH_OVERSEER_SUCCESSOR_ACCOUNTS=0 ORCH_QUESTION_TOOL=overseer \
    ${pref[@]+"${pref[@]}"} "${SUCCEED_BIN:-$SUCCEED}" --wait-secs 20 "$@" -- "${CALLER_FLAGS[@]}" 2>&1)" || RC=$?
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
# walled. Under the default ladder the Fable entry finds no seat and the Opus
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

# The issue's control on the same fleet: a ladder with no model dimension walks
# Fable alone and then the caller's own harness on the model it already runs,
# so the walk refuses with a seat that has Opus room standing.
new_caller
run_succeed rankonly 'claude:1:high'
assert_eq "$RC|$(first_key)|$(caller_open)|$(launched claude)" \
  "3|no-lane-qualifies|yes|none" \
  "a ladder with no model dimension refuses no-lane-qualifies on a fleet with Opus room"

# The ladder's must-fail control: a walk that reads an entry's model name as no
# model judges each seat on its binding bucket, the Fable window, and refuses
# the same fleet the default ladder succeeds on.
NOMODEL="$(mutant_scripts nomodel lib/overseer-launch.sh)" || exit 1
mutate_file "$NOMODEL/lib/overseer-launch.sh" \
  '      "codex:$known"|"claude:"*"$known"*) return 0 ;;' \
  '      "codex:$known"|"claude:"*"$known"*) OL_ENTRY_MODEL=""; return 0 ;;'
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

# Every claude seat walled for every model: the ladder reaches codex on
# GPT-5.6 Sol.
seat eclaude 99 99 10
seat fclaude 99 99 10
codex_seat codex 20
new_caller
run_succeed codex unset
assert_eq "$RC|$(caller_open)|$(launched claude)|$(launched codex | awk '{print $2}')|$(grep -cx 'model_reasoning_effort=high' "$TMP_ROOT/argv.codex")" \
  "0|no|none|gpt-5.6-sol|1" \
  "every claude entry walled: the ladder reaches codex on GPT-5.6 Sol"

# A model name the tier ladder does not know is a setting to fix, refused
# before any pick as a rank past the ladder is, on a fleet whose codex seat
# has room: the misspelling never reaches a launch line.
new_caller
run_succeed misspelled 'codex:gpt-5.6-sl:high'
assert_eq "$RC|$(first_key) $(sed -n 1p <<<"$OUT" | awk '{print $3}')|$(caller_open)|$(launched codex)" \
  "1|model-failed entry=codex:gpt-5.6-sl:high|yes|none" \
  "a codex model name the tier ladder does not name refuses model-failed"
# Its control: an entry reader that takes every name as written launches the
# misspelled model.
NAMECTL="$(mutant_scripts namectl lib/overseer-launch.sh)" || exit 1
mutate_file "$NAMECTL/lib/overseer-launch.sh" \
  "  # Every rank until \`kendex tier-model\` refuses one past the ladder's end." '  return 0'
new_caller
SUCCEED_BIN="$NAMECTL/oversee-succeed" run_succeed namectl 'codex:gpt-5.6-sl:high'
assert_eq "$RC|$(launched codex | awk '{print $2}')" "0|gpt-5.6-sl" \
  "control: an entry reader that skips the name check launches the misspelled model"

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
  "0|oversee-succeed: entry-permission-untransferable entry=claude:fable:high source=codex target=claude|none|dcodex gpt-5.6-sol|1" \
  "a codex caller whose permission words cannot cross skips the claude entries and succeeds on codex"
# Its control: a walk that chooses the claude entry anyway refuses after it,
# launching nothing.
SKIPCTL="$(mutant_scripts skipctl lib/overseer-launch.sh)" || exit 1
mutate_file "$SKIPCTL/lib/overseer-launch.sh" '      ol_entry_permitted "$entry" || continue' '      :'
new_caller codex
CALLER_LANE="CODEX_HOME=$H/.codex" SUCCEED_BIN="$SKIPCTL/oversee-succeed" run_succeed skipctl unset
assert_eq "$RC|$(first_key)|$(launched claude)|$(launched codex)" \
  "1|launch-choice-failed|none|none" \
  "control: a walk that chooses the untransferable entry refuses and launches nothing"
CALLER_FLAGS=("$BYPASS")

# The ladder's first rung: a claude seat with Fable room takes a Fable
# successor, although another seat has Opus room. A default that starts on
# Opus, or puts Opus ahead of Fable, moves this successor down a model.
seat claude 10 99 99
seat eclaude 10 99 10
seat fclaude 10 10 10
codex_seat codex 99
codex_seat dcodex 99
new_caller
run_succeed fable unset
assert_eq "$RC|$(launched claude)|$(launched codex)" \
  "0|$H/.fclaude fable|none" \
  "the default ladder opens on Fable where a seat has Fable room"

# A pi overseer on the pi-claude provider, its pane naming no harness and its
# launch record naming pi, Fable and the account .claude, whose Fable and Opus
# windows are spent. Its wall recovery walks a pi entry on Opus, which spends a
# claude account: the pick leaves the walled account out and lands on .eclaude.
FLEET_STATE="$TMP_ROOT/work/tmp/workflow-state-oversee.json"
new_pi_caller() { # [norecord]
  tm kill-window -a -t fleet:0
  rm -f -- "${TMP_ROOT:?}"/argv.* "${FLEET_STATE:?}"
  CALLER_PANE="$(tm new-window -d -t fleet:1 -c "$TMP_ROOT/work" -P -F '#{pane_id}' 'exec sleep 100000')"
  CALLER_WINDOW="$(tm display-message -p -t "$CALLER_PANE" '#{window_id}')"
  [[ "${1:-}" != norecord ]] || return 0
  jq -n --arg server "$SERVER_PID" --arg pane "$CALLER_PANE" --arg account "$H/.claude" --arg cwd "$TMP_ROOT/work" \
    '{issue_id: "oversee", overseer: {runtime: "tmux", generation: 1, server: $server, pane: $pane,
      harness: "pi", account: $account, home: $account, model: "pi-claude/claude-fable-5-1",
      effort: "high", cwd: $cwd, launch_line: "recorded"}}' > "$FLEET_STATE"
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
  '       || "$entry" =~ ^pi:[a-z][a-z0-9.-]*/[a-z0-9][a-z0-9._/-]*:[a-z]+$ ]]' '       ]]'
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
# A pi-claude model the claude ladder does not name is a setting to fix,
# refused before any pick as a misspelled claude name is.
new_pi_caller
run_succeed pibogus 'pi:pi-claude/claude-bogus:high' --walled-pane "$CALLER_PANE" --harness pi
assert_eq "$RC|$(keyed model-failed | awk '{print $2, $3}')|$(caller_open)|$(launched pi)" \
  "1|model-failed entry=pi:pi-claude/claude-bogus:high|yes|none" \
  "a pi-claude entry naming a model the claude ladder does not know refuses model-failed"

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
