#!/usr/bin/env bash
# open-terminal's lane record: the `lanes[]` entry every launch writes to the
# caller checkout's oversee workflow state, which `oversee-watch --state` reads
# the live fleet from. A launch appends one record under the item's
# workflow-state id; a relaunch rewrites the fields a relaunch can move and
# keeps launched_at; a wake rewrites the session it resumed; a state that
# cannot be created refuses before any window opens, and a record that cannot
# be written into it fails the item with the window standing.
#
# The suite runs a copy of open-terminal beside a copy of workflow-state in a
# temp git repo, with the worktree CLI, gh, the GUI terminal, tmux and the
# harness binaries stubbed, and an absolute --state-dir so no record lands in
# a real checkout; the rows about the flag's absence run from a checkout of
# their own. One row per behaviour; shaped input (the model flag spellings)
# is one table.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
export ORCH_LANE_HOST=local
# Every row launches into one fleet state; the fleet cap has its own suite,
# open-terminal-cap.sh, and is out of this one's way.
export ORCH_OVERSEER_LANES=1000
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
# shellcheck source=lib/process-table.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/process-table.sh"
# shellcheck source=lib/question-off.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/question-off.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-record: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-record: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-record: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# Stubs: the GUI terminal and the harness binaries exit 0 without running
# anything, gh answers nothing, lanes clears every lane, and tmux answers the
# few reads a --cmd launch and a wake make; a hosted row sets STUB_PANE_CMD
# and STUB_PANE_TEXT so the pane reads as an ssh session at its prompt. The
# launching pane's session is STUB_SESSION_NAME; with that empty the read
# fails with tmux's own error line, and with STUB_PANE_GONE set it answers an
# empty name and status 0, as tmux 3.4 answers for a pane it does not hold; a session_name read with no -t is the attached client's, `client`.
# list-windows, new-window, kill-window and that read each log `OP TARGET` to STUB_TMUX_LOG,
# TARGET being the -t value or `none`. has-session
# answers tmux's own refusal for a session STUB_DEAD_SESSIONS names, for an
# empty name the error tmux 3.4 prints for `-t =`, and STUB_HAS_SESSION_ERR,
# where set, for every name. list-panes lists the one pane new-window makes,
# and fails with tmux's own line where STUB_LIST_PANES_FAIL is set. A
# paste-buffer marks STUB_PASTED, which run_ot clears before each launch.
# The pane's process is STUB_PANE_PID where a row sets it, the stub's own
# otherwise.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/ghostty"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
# The resolver's `gh repo view` rung, answered only where a row arms it.
[[ "${1:-}" == repo && -n "${STUB_GH_REPO:-}" ]] || exit 1
printf '%s\n' "$STUB_GH_REPO"
EOF
# lanes judges every lane with room; where a row sets STUB_PICK_CLAIMS its
# pick answers a reading charging that many claims, and otherwise none.
cat > "$BIN/lanes" <<'LANES'
#!/usr/bin/env bash
case "${1:-}" in
  check) exit 0 ;;
  list) echo "[]" ;;
  pick) [[ -z "${STUB_PICK_CLAIMS:-}" ]] || jq -cn --argjson n "$STUB_PICK_CLAIMS" '{config_dir: "/stub/lane", claims: $n}' ;;
esac
exit 0
LANES
# claude holds while the file STUB_CLAUDE_HOLD names exists, a woken turn
# still running, and exits at once where no row sets it.
printf '#!/usr/bin/env bash\nwhile [[ -n "${STUB_CLAUDE_HOLD:-}" && -e "$STUB_CLAUDE_HOLD" ]]; do sleep 0.1; done\nexit 0\n' > "$BIN/claude"
# kendex hooks-off, which a Copilot fleet launch asks whether Copilot's settings
# switch its hooks off: nothing does here.
cat > "$BIN/kendex" <<'EOF'
#!/usr/bin/env bash
printf '{"switched_off_by":null}\n'
EOF
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
t=none; prev=""
for a in "$@"; do [[ "$prev" != -t ]] || t="$a"; prev="$a"; done
logged() { [[ -z "${STUB_TMUX_LOG:-}" ]] || printf '%s %s\n' "$1" "$t" >> "$STUB_TMUX_LOG"; }
case "${1:-}" in
  list-windows) logged list-windows; echo 1 ;;
  has-session) [[ -z "${STUB_HAS_SESSION_ERR:-}" ]] || { echo "$STUB_HAS_SESSION_ERR" >&2; exit 1; }
    t="${3#=}"; [[ -n "$t" ]] || { echo 'no mouse target' >&2; exit 1; }; [[ " ${STUB_DEAD_SESSIONS:-} " != *" $t "* ]] || { echo "can't find session: $t" >&2; exit 1; } ;;
  new-window) logged new-window
    [[ -z "${STUB_OPENED_AT:-}" ]] || { date -u +%Y-%m-%dT%H:%M:%SZ > "$STUB_OPENED_AT"; sleep "${STUB_OPEN_DELAY:-0}"; }; echo "$$ %1" ;;
  display-message) if [[ "$*" == *session_name* ]]; then logged session-read; [[ "$t" != none ]] || { echo client; exit 0; }
      [[ -z "${STUB_PANE_GONE:-}" ]] || exit 0
      [[ -n "${STUB_SESSION_NAME:-}" ]] || { echo 'error connecting to /tmp/tmux-stub/default (No such file or directory)' >&2; exit 1; }
      echo "$STUB_SESSION_NAME"
    elif [[ "$*" == *pane_current_command* ]]; then echo "${STUB_PANE_CMD:-0}"; else echo 0; fi ;;
  kill-window) logged kill-window ;;
  list-panes) [[ -z "${STUB_LIST_PANES_FAIL:-}" ]] || { echo 'no server running on /tmp/tmux-stub/default' >&2; exit 1; }
    # The pane writer's identity read: the window's shell until a paste lands,
    # then what the row says the pane runs, ssh for a hosted one.
    if [[ "$*" == *pane_current_command* ]]; then
      running=bash
      [[ ! -e "${STUB_PASTED:-}" ]] || running="${STUB_PANE_CMD:-claude}"
      printf '%%1\t%s\t%s\n' "${STUB_PANE_PID:-$$}" "$running"
    else echo %1; fi ;;
  load-buffer) cat -- "${@: -1}" > "$STUB_PANE_BUFFER" || exit 1
    [[ -z "${STUB_BUFFER_LOG:-}" ]] || cat -- "$STUB_PANE_BUFFER" >> "$STUB_BUFFER_LOG" ;;
  paste-buffer) [[ -z "${STUB_PASTED:-}" ]] || : > "$STUB_PASTED" ;;
  capture-pane)
    if [[ -n "${STUB_HARNESS_TEXT:-}" && -f "$STUB_PANE_BUFFER" ]] && grep -q '^exec bash -lc ' "$STUB_PANE_BUFFER"; then printf '%s\n' "$STUB_HARNESS_TEXT"
    else printf '%s\n' "${STUB_PANE_TEXT:-}"; fi ;;
esac
exit 0
EOF
chmod +x "$BIN/ghostty" "$BIN/gh" "$BIN/lanes" "$BIN/claude" "$BIN/kendex" "$BIN/tmux"
export TERMINAL=ghostty
PROC_BIN="$TMP_ROOT/proc-bin"
proc_table_install "$PROC_BIN"
PROC_TABLE="$TMP_ROOT/proc-table.txt"
PROC_CWD_FILE="$TMP_ROOT/proc-cwd.txt"
PROC_HIDDEN_PIDS=""
export PROC_TABLE PROC_CWD_FILE PROC_HIDDEN_PIDS
proc_table_write "$PROC_TABLE"
proc_cwd_write "$PROC_CWD_FILE"

# worktree: create and path answer with a directory under $TMP_ROOT/wt,
# exists reads $EXISTS_DIR, merged answers unmerged.
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
d="$TMP_ROOT/wt/\${2:-unknown}"
case "\${1:-}" in
  exists) [[ -f "\$EXISTS_DIR/\${2:-}" ]] && echo true || echo false ;;
  merged) exit 1 ;;
  path) printf '%s\n' "\$d" ;;
  create) mkdir -p "\$d"; git init -q "\$d"; git -C "\$d" config gc.auto 0; git -C "\$d" config maintenance.auto false; printf '%s\n' "\$d" ;;
  *) echo "unexpected worktree stub call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUB"
EXISTS_DIR="$TMP_ROOT/exists"
mkdir -p "$EXISTS_DIR"

REPO="$TMP_ROOT/repo"
mutant_scripts repo >/dev/null || exit 1
orch_fixture_shared_libs "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
OT="$REPO/scripts/open-terminal"
WS="$REPO/scripts/workflow-state"
# Every fleet state sits in the temp repo every row launches from unless it
# names another, where an overseer's state sits, so the overseer binding reads
# the fleet's repository off the state directory.
FLEET_ROOT="$REPO/tmp"
mkdir -p "$FLEET_ROOT"
STATE="$FLEET_ROOT/state"
LANE_DIR="$TMP_ROOT/.eclaude"
mkdir -p "$LANE_DIR"

# Claude transcripts naming CC-1, for the relaunch and wake rows, and CC-40,
# for the wake of an item no record names.
SESSION_HOME="$TMP_ROOT/session-home"
CLAUDE222=22222222-2222-2222-2222-222222222222
CLAUDE444=44444444-4444-4444-4444-444444444444
mkdir -p "$SESSION_HOME/.claude-shared/projects/repo"
printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$TMP_ROOT/wt/CC-1\",\"message\":{\"content\":\"start cc-1\"}}" > "$SESSION_HOME/.claude-shared/projects/repo/$CLAUDE222.jsonl"
printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$TMP_ROOT/wt/CC-40\",\"message\":{\"content\":\"start cc-40\"}}" > "$SESSION_HOME/.claude-shared/projects/repo/$CLAUDE444.jsonl"

# run_ot [SCRIPT=PATH] [STATE_DIR=PATH] [CWD=PATH] ARGS... — one launch; sets
# OUT (stdout), ERR and RC. STATE_DIR= is passed as --state-dir, the flag that
# names the fleet; an empty one passes no flag, so the launch names no fleet
# unless ARGS carry the flag themselves. CWD= is the directory the launch
# runs from, the temp repo where unset.
run_ot() {
  local script="$OT" state_dir="$STATE" cwd="$REPO" state_args=()
  while [[ "${1:-}" == SCRIPT=* || "${1:-}" == STATE_DIR=* || "${1:-}" == CWD=* ]]; do
    case "$1" in SCRIPT=*) script="${1#SCRIPT=}" ;; STATE_DIR=*) state_dir="${1#STATE_DIR=}" ;; CWD=*) cwd="${1#CWD=}" ;; esac
    shift
  done
  [[ -z "$state_dir" ]] || state_args=(--state-dir "$state_dir")
  rm -f -- "${TMP_ROOT:?}/pasted"
  rm -f -- "${TMP_ROOT:?}/pane-buffer"
  set +e
  OUT="$(cd "$cwd" && PATH="$BIN:$PROC_BIN:$PATH" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/claims" STUB_PASTED="$TMP_ROOT/pasted" STUB_PANE_BUFFER="$TMP_ROOT/pane-buffer" \
    WORKTREE_CLI="$STUB" LANES_CLI="$BIN/lanes" LANES_HOME="$SESSION_HOME" EXISTS_DIR="$EXISTS_DIR" \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' TMUX="${RUN_TMUX:-}" ORCH_TMUX_SESSION="${RUN_SESSION-stub}" TMUX_PANE="${RUN_PANE:-}" \
    STUB_SESSION_NAME="${STUB_SESSION_NAME:-}" STUB_TMUX_LOG="${STUB_TMUX_LOG:-}" STUB_DEAD_SESSIONS="${STUB_DEAD_SESSIONS:-}" STUB_PANE_GONE="${STUB_PANE_GONE:-}" STUB_HAS_SESSION_ERR="${STUB_HAS_SESSION_ERR:-}" STUB_PANE_PID="${STUB_PANE_PID:-}" STUB_CLAUDE_HOLD="${STUB_CLAUDE_HOLD:-}" GH_REPO="" STUB_GH_REPO="${STUB_GH_REPO:-}" \
    "$script" ${state_args[@]+"${state_args[@]}"} "$@" 2>"$TMP_ROOT/err")"
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/err")"
}

# record ITEM — the item's record as `field=value` words, null spelled null.
# running_at and session_since are left out: each is a clock read at the
# launch, which running_at ITEM and session_since ITEM read on their own rows
# below. launch is left out too: launch_of ITEM reads it on its own rows. So
# is wake, whose start a wake reads while a turn that exits at once may be gone.
record() {
  "$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$1"'") | to_entries | map(select(.key != "running_at" and .key != "session_since" and .key != "tier" and .key != "tier_inputs" and .key != "launch" and .key != "wake" and .key != "recovery")) | map("\(.key)=\(.value // "null")") | join(" ")'
}
launch_of() { "$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$1"'") | .launch | if . == null then null else [.pane, (.server | type), .pid, .start] end' | jq -c .; }
running_at() { "$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$1"'") | .running_at // "null"' | tr -d '"'; }
session_since() { "$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$1"'") | .session_since // "null"' | tr -d '"'; }
records() { "$WS" --state-dir "$STATE" get oversee '[.lanes[] | select(.item == "'"$1"'")] | length'; }
stamped() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && echo iso || echo "$1"; }
field() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$1"; }
# pick_claims ITEM — the claims the record's pick reading charged, none without one.
pick_claims() { "$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$1"'") | .pick.claims // "none"' | tr -d '"'; }

# A fleet launch names its harness and carries the words the fleet gate asks
# for; a row about some other part of the launch passes that gate with this.
FLEET_CMD=(--harness claude --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL")

echo "=== a launch appends one record under the item's workflow-state id ==="
printf '%s\n' '/orch small CC-1' \
  'tier=small brief=small cause=estimate-within-small production=40 estimate=12 delta=40 paths=3' > "$TMP_ROOT/brief"
run_ot --ghostty --harness claude --cmd "true --model opus --verbose --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL {brief}" --brief-file "$TMP_ROOT/brief" CC-1
REC="$(record CC-1)"
assert_eq "rc=$RC records=$(records CC-1)" "rc=0 records=1" "a GUI launch writes one record and the state is created for it"
assert_eq "$(sed "s/ launched_at=[^ ]*//" <<<"$REC")" \
  "item=CC-1 tracker=linear repo=null harness=claude window=null account=null host=null kind=local mail_root=$TMP_ROOT/wt/CC-1 surface=gui model=opus effort=high session_id=null status=running over_cap=null allow_all=null" \
  "the record carries the item, no window off tmux, the worktree as mail_root, the flags' model and status running"
assert_eq "$(stamped "$(field "$REC" launched_at)")" "iso" "launched_at is a UTC timestamp"
assert_eq "$(stamped "$(running_at CC-1)")" "iso" "a launch recording the lane running stamps running_at, the watch's start-stall anchor"
LAUNCHED_AT="$(field "$REC" launched_at)"
assert_eq "session_since=$(session_since CC-1)" "session_since=$LAUNCHED_AT" \
  "a launch records its own launch stamp as session_since, the floor the lane readers bind its session to"

# Every launcher, not only an overseer, records its brief and sizing line.
assert_eq "$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-1") | [.tier, .tier_inputs]' | jq -e '. == ["small", {estimate:12, delta:40, paths:3}]')" \
  'true' "a sized file-backed small launch records its tier and inputs"
while IFS='|' read -r item prompt tier; do
  run_ot --ghostty --harness claude --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL \"$prompt $item
 tier=$tier brief=small cause=estimate-within-small production=40 estimate=12 delta=40 paths=3\"" "$item"
  assert_eq "rc=$RC metadata=$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$item"'") | [.tier, .tier_inputs]' | jq -e --arg tier "$tier" '. == [$tier, {estimate:12, delta:40, paths:3}]')" \
    'rc=0 metadata=true' "launch tier inputs: $prompt"
done <<'ROWS'
CC-170|/orch micro|micro
CC-171|/skill:orch small|small
CC-172|$orch small|small
CC-173|Read .agents/skills/orch/SKILL.md and execute the orch start workflow for|standard
ROWS
TIER_OT="$(mutant_scripts tier-mutant open-terminal)/open-terminal" || exit 1
mutate_file "$TIER_OT" '+ $tier_record' '+ ($tier_record | .tier_inputs.estimate = null)'
run_ot SCRIPT="$TIER_OT" --ghostty --harness claude --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL \"/orch small CC-174
 tier=small brief=small cause=estimate-within-small estimate=12 delta=40 paths=3\"" CC-174
assert_eq "rc=$RC $("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-174") | .tier_inputs.estimate')" \
  'rc=0 null' "control: a discarded estimate turns the launch input assertion red"

# The choice words sit INSIDE the --cmd command, which is the command this
# launch runs: a template is rendered verbatim and no launch flag is appended to
# it, so the model recorded here is the model the harness was started with.
RUN_TMUX=stub,1,0 run_ot --tmux --harness claude --lane "$LANE_DIR" --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-2
assert_eq "rc=$RC $(sed "s/ launched_at=[^ ]*//" <<<"$(record CC-2)")" \
  "rc=0 item=CC-2 tracker=linear repo=null harness=claude window=stub:CC-2 account=$LANE_DIR host=null kind=local mail_root=$TMP_ROOT/wt/CC-2 surface=tmux model=opus effort=high session_id=null status=running over_cap=null allow_all=null" \
  "a tmux launch under a lane records its window, its account dir, the tmux surface and the model its own command names"
assert_eq "launch=$(launch_of CC-2) unread=$(grep -c '^open-terminal: launch-identity-unread item=CC-2 pane=%1 step=harness$' <<<"$ERR" || true)" \
  'launch=["%1","number",null,null] unread=1' \
  "a tmux launch whose pane runs no harness records its pane and server, no harness, and says so"
gui_launch="$(launch_of CC-1)"
assert_eq "launch=$gui_launch" 'launch=null' "a GUI launch records no launch identity"

# The launch identity lane-close stops the harness by: the pane and its tmux
# server from the window's creation and, once the launch stands, the harness
# process under the pane's own with its start time. This shell stands in for
# that harness, the pane's process itself.
launch_identity_row() { # ITEM [SCRIPT]
  proc_table_write "$PROC_TABLE" "$$ 1 claude"
  STUB_PANE_PID=$$ RUN_TMUX=stub,1,0 run_ot ${2:+SCRIPT="$2"} --tmux --harness claude --lane "$LANE_DIR" --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" "$1"
  proc_table_write "$PROC_TABLE"
}
SHELL_START="$(bash -c '. "$1" && lane_process_start "$2"' _ "$SCRIPTS_DIR/lib/lane-state.sh" "$$")"
[[ -n "$SHELL_START" ]] || { echo "open-terminal-record: shell-start-unread pid=$$" >&2; exit 1; }
launch_identity_row CC-3
assert_eq "rc=$RC launch=$(launch_of CC-3)" "rc=0 launch=$(jq -cn --argjson pid $$ --arg start "$SHELL_START" '["%1", "number", $pid, $start]')" \
  "a confirmed local launch records its pane, server, harness pid and the harness's start"
IDENTITY_OT="$(mutant_scripts identity-mutant open-terminal)/open-terminal" || exit 1
mutate_file "$IDENTITY_OT" '[[ "$launch_rc" -ne 0 || -n "$target" ]] || launch_identity_read "$pane" "$title"' '[[ "$launch_rc" -ne 0 || -n "$target" ]] || true'
launch_identity_row CC-4 "$IDENTITY_OT"
assert_eq "rc=$RC launch=$(launch_of CC-4)" 'rc=0 launch=["%1","number",null,null]' \
  "control: without the read at confirmation the record names no harness"
STUB_GH_REPO=o/r RUN_TMUX=stub,1,0 run_ot --tmux --tracker github --repo o/r "${FLEET_CMD[@]}" 2709
assert_eq "rc=$RC $(record issue-2709 | sed -E 's/ (account|host|kind|mail_root|surface|model|effort|session_id|launched_at|over_cap|allow_all)=[^ ]*//g')" \
  "rc=0 item=issue-2709 tracker=github repo=o/r harness=claude window=stub:gh-2709 status=running" \
  "a GitHub item is recorded under its workflow-state id with the window the watch reads it through"

# A Copilot lane records whether its command grants the full allow-all mode,
# the one posture lib/copilot-session.sh names a policy stop for; the
# tools-only spelling and none are no such grant.
# Their items are ids no later case launches: their copilot records share
# $STATE, where a later codex relaunch of the same id reads a harness switch.
# copilot_allow_all ITEM FLAGS [SCRIPT] — rc and the record's allow_all.
# The account, LANES_HOME's default copilot home, holds the hooks the fleet
# gate asks of a Copilot lane, and the gate makes it load the context reader.
mkdir -p "$SESSION_HOME/.copilot/hooks"
for name in lane-mail-check lane-mail-compact lane-mail-start; do : > "$SESSION_HOME/.copilot/hooks/$name.sh"; : > "$SESSION_HOME/.copilot/hooks/$name.json"; done
copilot_allow_all() {
  run_ot ${3:+SCRIPT="$3"} --ghostty --harness copilot --cmd "copilot $2 --no-ask-user -i start-{item} $UNATTENDED_ALL" "$1"
  printf 'rc=%s %s\n' "$RC" "$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$1"'") | .allow_all')"
}
while IFS='|' read -r item flags want; do
  assert_eq "$(copilot_allow_all "$item" "$flags")" "rc=0 $want" "a Copilot launch naming [$flags] records allow_all $want"
done <<'ROWS'
CC-150|--allow-all|true
CC-151|--yolo|true
CC-152|--allow-all-tools|false
CC-153||false
ROWS
ALLOW_ALL_OT="$(mutant_scripts allow-all-mutant open-terminal)/open-terminal" || exit 1
mutate_file "$ALLOW_ALL_OT" '! lane_copilot_allows_all "$cmd" || LAUNCH_ALLOW_ALL=true' '! false || LAUNCH_ALLOW_ALL=true'
assert_eq "$(copilot_allow_all CC-154 --allow-all "$ALLOW_ALL_OT")" "rc=0 false" \
  "control: without the allow-all test a lane launched with --allow-all records no grant"

# --repo is optional on a supported GitHub launch: the resolver answers and
# every launch command carries that answer, so the record carries it too. A
# record left null here is a lane whose close-out cannot read its item.
STUB_GH_REPO=o/resolved RUN_TMUX=stub,1,0 run_ot --tmux --tracker github "${FLEET_CMD[@]}" 2711
assert_eq "rc=$RC repo=$(field "$(record issue-2711)" repo)" "rc=0 repo=o/resolved" \
  "a GitHub launch with no --repo records the repository its resolver answered"

# A Copilot fleet lane is recorded as any other lane is, once its gate has its
# hooks where the lane loads them, no settings file switching them off, and
# has made its home load the context reader (open-terminal-copilot-context.sh
# holds those rules).
COP_RECORD_HOME="$TMP_ROOT/copilot-home"
mkdir -p "$COP_RECORD_HOME/hooks"
for name in lane-mail-check lane-mail-compact lane-mail-start; do : > "$COP_RECORD_HOME/hooks/$name.sh"; : > "$COP_RECORD_HOME/hooks/$name.json"; done
COPILOT_HOME="$COP_RECORD_HOME" RUN_TMUX=stub,1,0 run_ot --tmux --harness copilot --launch-flags "--model claude-opus-5 --reasoning-effort high" CC-140
assert_eq "rc=$RC $(record CC-140 | sed -E 's/ (launched_at|over_cap|allow_all)=[^ ]*//g') extensions=$(jq -r .enabledFeatureFlags.EXTENSIONS "$COP_RECORD_HOME/settings.json" 2>/dev/null)" \
  "rc=0 item=CC-140 tracker=linear repo=null harness=copilot window=stub:CC-140 account=null host=null kind=local mail_root=$TMP_ROOT/wt/CC-140 surface=tmux model=claude-opus-5 effort=high session_id=null status=running extensions=true" \
  "a Copilot fleet launch opens its window and records the lane, its harness and model, its home loading the reader"
assert_eq "$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-140") | [.tier, .tier_inputs]' | jq -e '. == ["standard", {estimate:null, delta:null, paths:null}]')" \
  'true' "a native standard launch records unknown inputs"

echo "=== a tmux launch opens its window in the fleet's named session ==="
# A window target with no session is the client's current session, and a
# launch from no pane has none of its own: tmux then picks whichever session it
# calls current. Every row reads the session the window was opened in off the
# new-window target, the session the last window index was read from off the
# list-windows target, the pane asked for its session off that read's target,
# the recorded one off the state's tmux.session, and the refusal off the first
# keyed session line, its key and fields.
# session_row STATE ITEM — runs the launch with the row's own environment
# already set, then prints `rc= target= list= pane= window= recorded= refused=`.
TMUX_LOG="$TMP_ROOT/tmux-targets"
# logged OP — the target the last OP call named, empty where none was made.
logged() { awk -v op="$1" '$1 == op { t = $2 } END { print t }' "$TMUX_LOG"; }
session_row() {
  local state="$FLEET_ROOT/$1"
  : > "$TMUX_LOG"
  STUB_TMUX_LOG="$TMUX_LOG" RUN_TMUX="${RUN_TMUX-stub,1,0}" run_ot STATE_DIR="$state" --tmux "${FLEET_CMD[@]}" "$2"
  printf 'rc=%s target=%s list=%s pane=%s window=%s recorded=%s refused=%s' "$RC" \
    "$(logged new-window)" "$(logged list-windows)" "$(logged session-read)" \
    "$("$WS" --state-dir "$state" get oversee "[.lanes[]? | select(.item == \"$2\") | .window] | first // \"none\"" 2>/dev/null || echo none)" \
    "$("$WS" --state-dir "$state" get oversee '.tmux.session // "none"' 2>/dev/null || echo none)" \
    "$(awk '/^open-terminal: (tmux-session-|session-record-failed|tmux-failed operation=has-session|tmux-missing)/ { sub(/^open-terminal: /, ""); print; exit }' <<<"$ERR" | tr ' ' '+')"
}
assert_eq "$(RUN_SESSION=fleetx session_row sess-env CC-100)" \
  "rc=0 target==fleetx:1 list==fleetx pane= window=fleetx:CC-100 recorded=fleetx refused=" \
  "a launch from no pane with ORCH_TMUX_SESSION opens and records its window in that session"
assert_eq "$(RUN_SESSION= session_row sess-none CC-101)" \
  "rc=1 target= list= pane= window=none recorded=none refused=tmux-session-unresolved+item=CC-101+consulted=ORCH_TMUX_SESSION,tmux.session,TMUX_PANE+pane=unset" \
  "a launch from no pane with no session named or recorded refuses, naming the sources it read, and opens nothing"
# What the TMUX_PANE read found, one row per value the refusal names; unset is
# the row above. A pane tmux does not hold answers an empty name and status 0,
# which is not a failed read, and a failed read leaves tmux's line above.
assert_eq "$(RUN_SESSION= RUN_PANE=%9 STUB_PANE_GONE=1 session_row sess-gone CC-124)" \
  "rc=1 target= list= pane=%9 window=none recorded=none refused=tmux-session-unresolved+item=CC-124+consulted=ORCH_TMUX_SESSION,tmux.session,TMUX_PANE+pane=none" \
  "a launch whose TMUX_PANE names a pane tmux does not hold refuses with pane=none"
RUN_SESSION= RUN_PANE=%9 session_row sess-unread CC-125 > "$TMP_ROOT/unread-row"
assert_eq "$(cat "$TMP_ROOT/unread-row") above=$(awk '/^error connecting to / { e = NR } /^open-terminal: tmux-session-unresolved / { print (e && e < NR) ? 1 : 0; exit }' <<<"$ERR")" \
  "rc=1 target= list= pane=%9 window=none recorded=none refused=tmux-session-unresolved+item=CC-125+consulted=ORCH_TMUX_SESSION,tmux.session,TMUX_PANE+pane=read-failed above=1" \
  "a launch whose pane read fails refuses with pane=read-failed below tmux's own line"
assert_eq "$(RUN_SESSION=fleetz STUB_DEAD_SESSIONS=fleetz session_row sess-typo CC-106)" \
  "rc=1 target= list= pane= window=none recorded=none refused=tmux-session-missing+item=CC-106+session=fleetz+source=ORCH_TMUX_SESSION+server=stub" \
  "a first launch naming a session tmux does not hold refuses, naming it, its source and the server, and records nothing"
# From outside tmux, with no $TMUX at all: ORCH_TMUX_SESSION names the fleet
# session, and the launch reaches it on the person's own tmux server, the
# socket tmux derives from their uid (lib/tmux-server.sh), which a session
# that server does not hold is refused naming.
OWN_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default"
assert_eq "$(RUN_TMUX= RUN_SESSION=fleetx session_row sess-outside CC-130)" \
  "rc=0 target==fleetx:1 list==fleetx pane= window=fleetx:CC-130 recorded=fleetx refused=" \
  "a launch with no \$TMUX and ORCH_TMUX_SESSION set opens in that session on the person's own server"
assert_eq "$(RUN_TMUX= RUN_SESSION=fleetz STUB_DEAD_SESSIONS=fleetz session_row sess-outside-typo CC-131)" \
  "rc=1 target= list= pane= window=none recorded=none refused=tmux-session-missing+item=CC-131+session=fleetz+source=ORCH_TMUX_SESSION+server=$OWN_SOCKET" \
  "a launch with no \$TMUX naming a session the person's server does not hold refuses naming that server"
assert_eq "$(RUN_SESSION= RUN_PANE=%9 STUB_SESSION_NAME=fleety session_row sess-pane CC-102)" \
  "rc=0 target==fleety:1 list==fleety pane=%9 window=fleety:CC-102 recorded=fleety refused=" \
  "the fleet's first launch from a pane opens in that pane's session and records it"
assert_eq "$(RUN_SESSION= session_row sess-pane CC-103)" \
  "rc=0 target==fleety:1 list==fleety pane= window=fleety:CC-103 recorded=fleety refused=" \
  "a later launch from no pane opens in the session the fleet recorded"
assert_eq "$(RUN_SESSION=fleetx session_row sess-pane CC-104)" \
  "rc=0 target==fleetx:1 list==fleetx pane= window=fleetx:CC-104 recorded=fleety refused=" \
  "ORCH_TMUX_SESSION outranks the recorded session and leaves the record as it was"
assert_eq "$(RUN_SESSION= RUN_PANE=%9 STUB_SESSION_NAME=other STUB_DEAD_SESSIONS=fleety session_row sess-pane CC-107)" \
  "rc=1 target= list= pane= window=none recorded=fleety refused=tmux-session-missing+item=CC-107+session=fleety+source=tmux.session+server=stub" \
  "a recorded session the server lost refuses from a pane in another session, naming the record as the source"
NOFLEET_SESSION="$TMP_ROOT/nofleet-session"
mkdir -p "$NOFLEET_SESSION"
git -C "$NOFLEET_SESSION" init -q
git -C "$NOFLEET_SESSION" config gc.auto 0
git -C "$NOFLEET_SESSION" config maintenance.auto false
: > "$TMUX_LOG"
RUN_SESSION= RUN_PANE=%9 STUB_SESSION_NAME=own STUB_TMUX_LOG="$TMUX_LOG" RUN_TMUX=stub,1,0 \
  run_ot STATE_DIR= CWD="$NOFLEET_SESSION" --tmux --cmd true CC-105
assert_eq "rc=$RC target=$(logged new-window) pane=$(logged session-read)" "rc=0 target==own:1 pane=%9" \
  "a launch naming no fleet opens in the session of the pane TMUX_PANE names"
# nofleet_row ITEM — the launch naming no fleet, with the row's own environment
# already set, as `rc= target= pane=`.
nofleet_row() {
  : > "$TMUX_LOG"
  STUB_TMUX_LOG="$TMUX_LOG" RUN_TMUX=stub,1,0 run_ot STATE_DIR= CWD="$NOFLEET_SESSION" --tmux --cmd true "$1"
  printf 'rc=%s target=%s pane=%s' "$RC" "$(logged new-window)" "$(logged session-read)"
}
assert_eq "$(RUN_SESSION=fleetx RUN_PANE=%9 STUB_SESSION_NAME=other nofleet_row CC-109)" "rc=0 target==fleetx:1 pane=" \
  "a launch naming no fleet takes ORCH_TMUX_SESSION over a live pane in another session"
RUN_SESSION= STUB_TMUX_LOG="$TMUX_LOG" RUN_TMUX=stub,1,0 run_ot STATE_DIR= CWD="$NOFLEET_SESSION" --tmux --cmd true CC-108
assert_eq "rc=$RC first=$(grep '^open-terminal: tmux-session-' <<<"$ERR")" \
  "rc=1 first=open-terminal: tmux-session-unresolved item=CC-108 consulted=ORCH_TMUX_SESSION,TMUX_PANE pane=unset" \
  "a launch naming no fleet and no session lists no fleet state among the sources it read"

# A fleet state whose tmux entry is no object: the session read fails, and the
# launch refuses naming the state rather than opening anywhere.
session_row sess-broken CC-117 >/dev/null
"$WS" --state-dir "$FLEET_ROOT/sess-broken" update oversee '.tmux = 42' >/dev/null
assert_eq "$(RUN_SESSION=fleetx session_row sess-broken CC-118)" \
  "rc=1 target= list= pane= window=none recorded=none refused=session-record-failed+item=CC-118+state=oversee" \
  "a fleet state whose tmux entry cannot be read refuses as session-record-failed and opens nothing"
# The write of a first launch's session: a fleet state this launch can read
# and not lock takes the same refusal. The state's own lock path is a
# directory, which workflow-state cannot open; the fleet launch lock beside it
# is another file, so the launch reaches the session write.
"$WS" --state-dir "$FLEET_ROOT/sess-ro" init oversee >/dev/null
mkdir "$FLEET_ROOT/sess-ro/workflow-state-oversee.json.lock"
assert_eq "$(RUN_SESSION=fleetx session_row sess-ro CC-128)" \
  "rc=1 target= list= pane= window=none recorded=none refused=session-record-failed+item=CC-128+state=oversee" \
  "a fleet state whose tmux entry cannot be written refuses as session-record-failed and opens nothing"
# A has-session that fails for another reason than an absent session, the
# answer a restarted server gives a launch still carrying its $TMUX.
assert_eq "$(RUN_SESSION=fleetx STUB_HAS_SESSION_ERR='no server running on /tmp/tmux-1000/default' session_row sess-noserver CC-127)" \
  "rc=1 target= list= pane= window=none recorded=none refused=tmux-failed+operation=has-session+item=CC-127+detail=no+server+running+on+/tmp/tmux-1000/default" \
  "a has-session that fails for another reason refuses as tmux-failed operation=has-session and opens nothing"


echo "=== --launch-flags beside --cmd reach nothing and are refused ==="
# start_cmd renders a template verbatim and appends no flag to it, so a model
# left in --launch-flags would be gated and recorded while the harness ran its
# own default. Nothing launches and nothing is recorded.
run_ot --ghostty --harness claude --lane "$LANE_DIR" --cmd true --launch-flags "--model opus --effort high" CC-14
assert_eq "rc=$RC refused=$(grep -c '^open-terminal: launch-flags-unreachable option=--launch-flags flags=--model opus --effort high$' <<<"$ERR" || true) records=$(records CC-14)" \
  "rc=1 refused=1 records=0" \
  "launch flags passed beside a --cmd template refuse the launch, naming the flags that reach nothing, and record nothing"

echo "=== a relaunch rewrites the moved fields in place and keeps launched_at ==="
# launched_at is moved to a fixed past value first: a stamp of this second
# would separate a kept value from a rewritten one only by the runner's speed.
touch "$EXISTS_DIR/CC-1"
LAUNCHED_AT=2026-01-01T00:00:00Z
"$WS" --state-dir "$STATE" update oversee '(.lanes[] | select(.item == "CC-1")) |= (.status = "done" | .launched_at = "'"$LAUNCHED_AT"'" | .running_at = "'"$LAUNCHED_AT"'")' >/dev/null
run_ot --relaunch --ghostty --harness claude --lane "$LANE_DIR" --launch-flags "--model opus --effort low" CC-1
assert_eq "$RC $("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-1") | .recovery' | jq -c .)" \
  "0 $(jq -cn --arg cwd "$REPO" '{cwd:$cwd,flags:"--model opus --effort low",session:"",refresh:false}')" \
  "a native relaunch records its original flags and launch checkout for automatic recovery"
RELAUNCH_RUNNING_AT="$(running_at CC-1)"
assert_eq "$(stamped "$RELAUNCH_RUNNING_AT") renewed=$([[ "$RELAUNCH_RUNNING_AT" != "$LAUNCHED_AT" ]] && echo yes || echo no)" "iso renewed=yes" \
  "a relaunch renews running_at, so the watch counts a fresh start-stall window from it"
assert_eq "rc=$RC records=$(records CC-1) $(record CC-1)" \
  "rc=0 records=1 item=CC-1 tracker=linear repo=null harness=claude window=null account=$LANE_DIR host=null kind=local mail_root=$TMP_ROOT/wt/CC-1 surface=gui model=opus effort=low session_id=$CLAUDE222 launched_at=$LAUNCHED_AT status=running over_cap=null allow_all=null" \
  "a relaunch keeps one record: the resumed session id and the new account land, launched_at stands, and a done lane runs again"
assert_eq "$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-1") | [.tier, .tier_inputs]' | jq -e '. == ["small", {estimate:12, delta:40, paths:3}]')" \
  'true' "a native relaunch retains the first file-backed launch tier and inputs"

echo "=== a relaunch reads the handoff record where the lane wrote it ==="
# The lane writes its record from its own worktree, whose common root is that
# worktree here, while --state-dir names the fleet's directory, which holds
# none. The relaunch asks where the lane wrote it and starts afresh.
# retired_under SCRIPT — rc, the retirement line, the session id recorded,
# whether session_since, first moved to the fixed past launched_at holds, was
# renewed, and launched_at. The fresh start reads no session id, so the lane
# readers bind its record through session_since alone, which must name this
# relaunch and not the launch whose session it retired.
retired_under() {
  "$WS" --state-dir "$STATE" update oversee '(.lanes[] | select(.item == "CC-1")) |= (.session_since = "'"$LAUNCHED_AT"'")' >/dev/null
  mkdir -p "$TMP_ROOT/wt/CC-1/tmp"
  printf '%s\n' '{"handoff":{"merged":[],"remaining":["open the PR"],"written_at":"2000-01-01T06:00:00Z"}}' \
    > "$TMP_ROOT/wt/CC-1/tmp/workflow-state-CC-1.json"
  run_ot SCRIPT="$1" --relaunch --ghostty --harness claude --lane "$LANE_DIR" --launch-flags "--model opus --effort high" CC-1
  rm -f -- "${TMP_ROOT:?}/wt/CC-1/tmp/workflow-state-CC-1.json"
  local since
  since="$(session_since CC-1)"
  printf 'rc=%s retired=%s session=%s since=%s launched_at=%s' "$RC" "$(grep -c '^open-terminal: session-retired item=CC-1 harness=claude$' <<<"$OUT" || true)" \
    "$(field "$(record CC-1)" session_id)" "$([[ "$since" != "$LAUNCHED_AT" ]] && stamped "$since" || echo kept)" "$(field "$(record CC-1)" launched_at)"
}
assert_eq "$(retired_under "$OT")" "rc=0 retired=1 session=null since=iso launched_at=$LAUNCHED_AT" \
  "a record only the lane's worktree state holds retires its session though --state-dir names another directory, and the fresh start renews session_since while launched_at stands"
SINCE_MUTANT="$(mutant_scripts since-mutant open-terminal)" || exit 1
mutate_file "$SINCE_MUTANT/open-terminal" 'del(.launched_at, .over_cap, .tier, .tier_inputs)' 'del(.launched_at, .session_since, .over_cap, .tier, .tier_inputs)'
assert_eq "$(retired_under "$SINCE_MUTANT/open-terminal")" "rc=0 retired=1 session=null since=kept launched_at=$LAUNCHED_AT" \
  "control: a relaunch that keeps session_since leaves the fresh start bound to the launch whose session it retired"
RETIRED_MUTANT="$(mutant_scripts retired-mutant open-terminal)" || exit 1
mutate_file "$RETIRED_MUTANT/open-terminal" 'lane_handoff_standing "$3" "" "$WORKFLOW_STATE" handoff-standing "$2" --worktree "$3"' \
  'lane_handoff_standing "$3" "" "$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} handoff-standing "$2"'
assert_eq "$(retired_under "$RETIRED_MUTANT/open-terminal")" "rc=0 retired=0 session=$CLAUDE222 since=iso launched_at=$LAUNCHED_AT" \
  "control: asked under the fleet's --state-dir the relaunch misses the record and resumes the retired session"
# The worktree's state directory setting names another directory, and the
# record stands in the worktree's own tmp, where a lane whose launch forbids
# writing elsewhere keeps it: the relaunch reads that place too.
printf '[env]\nORCH_STATE_DIR = "state"\n' > "$TMP_ROOT/wt/CC-1/kendex.settings.toml"
assert_eq "$(retired_under "$OT")" "rc=0 retired=1 session=null since=iso launched_at=$LAUNCHED_AT" \
  "a record in the lane worktree's tmp retires its session where its state directory setting names another"
PLACE_MUTANT="$(mutant_scripts place-mutant open-terminal)" || exit 1
mutate_file "$PLACE_MUTANT/open-terminal" 'handoff-standing "$2" --worktree "$3"' 'handoff-standing "$2"'
assert_eq "$(retired_under "$PLACE_MUTANT/open-terminal")" "rc=0 retired=0 session=$CLAUDE222 since=iso launched_at=$LAUNCHED_AT" \
  "control: a relaunch naming no worktree misses that record and resumes the retired session"
rm -f -- "${TMP_ROOT:?}/wt/CC-1/kendex.settings.toml"
# Each is a relaunch renewing running_at, so the wake row below reads the
# stamp the last of them left.
RELAUNCH_RUNNING_AT="$(running_at CC-1)"

echo "=== a wake rewrites the session it resumed and nothing else ==="
"$WS" --state-dir "$STATE" update oversee '(.lanes[] | select(.item == "CC-1")) |= (.session_id = null | .status = "done" | .session_since = "'"$LAUNCHED_AT"'")' >/dev/null
run_ot --wake --harness claude CC-1
assert_eq "rc=$RC woken=$(grep -c '^open-terminal: lane-woken item=CC-1 ' <<<"$OUT" || true) $(record CC-1)" \
  "rc=0 woken=1 item=CC-1 tracker=linear repo=null harness=claude window=null account=$LANE_DIR host=null kind=local mail_root=$TMP_ROOT/wt/CC-1 surface=gui model=opus effort=high session_id=$CLAUDE222 launched_at=$LAUNCHED_AT status=running over_cap=null allow_all=null" \
  "a wake sets the resumed session id and status running and leaves the launch's fields as they were"
assert_eq "$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-1") | [.tier, .tier_inputs]' | jq -e '. == ["small", {estimate:12, delta:40, paths:3}]')" \
  'true' "a wake retains the first file-backed launch tier and inputs"
assert_eq "running_at=$(running_at CC-1)" "running_at=$RELAUNCH_RUNNING_AT" "a wake keeps running_at: the lane it rouses already started"
assert_eq "session_since=$(session_since CC-1)" "session_since=$LAUNCHED_AT" "a wake keeps session_since: it resumes the session the last launch started"

echo "=== a wake records the identity of the turn it started ==="
# The turn runs detached, outside the pane's process tree, so lane-close stops
# it by this identity: the detached shell's pid and its start, read while the
# resumed harness below it still holds.
wake_identity_row() { # [SCRIPT]
  : >"$TMP_ROOT/wake-hold"
  STUB_CLAUDE_HOLD="$TMP_ROOT/wake-hold" run_ot ${1:+SCRIPT="$1"} --wake --harness claude CC-1
  WAKE_PID="$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-1") | .wake.pid // empty')"
  WAKE_WANT=null
  if [[ -n "$WAKE_PID" ]]; then
    WAKE_WANT="$(jq -cn --argjson pid "$WAKE_PID" --arg start "$(bash -c '. "$1" && lane_process_start "$2"' _ "$SCRIPTS_DIR/lib/lane-state.sh" "$WAKE_PID")" '{pid: $pid, start: $start}')"
  fi
  WAKE_GOT="$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-1") | .wake' | jq -c .)"
  rm -f -- "${TMP_ROOT:?}/wake-hold"
}
wake_identity_row
assert_eq "rc=$RC recorded=$([[ -n "$WAKE_PID" ]] && echo yes || echo no) wake=$WAKE_GOT" "rc=0 recorded=yes wake=$WAKE_WANT" \
  "a wake records the pid and start of the detached turn it started"
WAKE_OT="$(mutant_scripts wake-mutant open-terminal)/open-terminal" || exit 1
mutate_file "$WAKE_OT" '  if start="$(lane_process_start "$pid")"; then' '  if start=""; then'
wake_identity_row "$WAKE_OT"
assert_eq "rc=$RC wake=$WAKE_GOT" 'rc=0 wake=null' "control: without the start read a wake records no turn to stop"

echo "=== a wake is not judged on the fleet cap ==="
# The fleet already runs more lanes than a cap of 1 allows; a wake rouses one of
# them and adds none.
ORCH_OVERSEER_LANES=1 run_ot --wake --harness claude CC-1
assert_eq "rc=$RC woken=$(grep -c '^open-terminal: lane-woken item=CC-1 ' <<<"$OUT" || true) capped=$(grep -c '^open-terminal: cap-' <<<"$OUT$ERR" || true)" \
  "rc=0 woken=1 capped=0" \
  "a wake at a full fleet goes through with no cap line"

echo "=== a wake of an item no record names is refused as record-missing, with nothing written ==="
touch "$EXISTS_DIR/CC-40"
mkdir -p "$TMP_ROOT/wt/CC-40"
run_ot --wake --harness claude CC-40
assert_eq "rc=$RC woken=$(grep -c '^open-terminal: lane-woken item=CC-40 ' <<<"$OUT" || true) missing=$(grep -c '^open-terminal: record-missing item=CC-40 state=oversee$' <<<"$ERR" || true) records=$(records CC-40)" \
  "rc=1 woken=1 missing=1 records=0" \
  "a wake names the item this launcher never launched, after the session it resumed is up, and appends no record"

echo "=== a hosted launch records its host and the root its mailbox is read under ==="
# The provider stub answers create with ssh-target lane.example and path
# /srv/lane; the tmux stub reads as an ssh pane at its prompt. The watch turns
# host and mail_root into its --hosted entry, the one route to that mailbox.
HOST_STUB="$TEST_DIR/fixtures/lane-host"
# The provider's disk. The lane's `.git` there names the clone whose common git
# directory holds its marker, and the marker the launch writes lands under it.
HOSTED_DISK="$TMP_ROOT/remote"
mkdir -p "$HOSTED_DISK/srv/lane"
printf 'gitdir: /srv/clone/.git/worktrees/lane\n' > "$HOSTED_DISK/srv/lane/.git"
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-60
assert_eq "rc=$RC $(sed "s/ launched_at=[^ ]*//" <<<"$(record CC-60)")" \
  "rc=0 item=CC-60 tracker=linear repo=o/r harness=claude window=stub:CC-60 account=$LANE_DIR host=$HOST_STUB kind=ssh mail_root=/srv/lane surface=tmux model=opus effort=high session_id=null status=running over_cap=null allow_all=null" \
  "a hosted record carries the host spec and the remote path create named, never the local tree"

echo "=== a hosted launch writes its lane's marker on the host and reads it back ==="
# `hooks/lane-mail-check.sh` reads a session as a launched lane only where the
# marker under the common git directory holds the root that session opens in.
# The stub provider writes none, which is the provider these rows are about:
# the launcher writes the marker over the transport and reads it back, or the
# item is not launched and nothing is counted.
#
# marker_at LOWER_ITEM — `root` where the marker holds the path the lane opens
# in, `other` where it holds anything else, `none` where none was written.
marker_at() {
  local m="$HOSTED_DISK/srv/clone/.git/lane-mail/$1" held
  [[ -f "$m" ]] || { printf none; return; }
  held="$(cat "$m")"
  [[ "$held" != /srv/lane ]] || { printf root; return; }
  printf other
}

STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-63
assert_eq "rc=$RC marker=$(marker_at cc-63) records=$(records CC-63) summary=$(grep -c '^open-terminal: summary launched=1 ' <<<"$OUT" || true)" \
  "rc=0 marker=root records=1 summary=1" \
  "a hosted launch binds its lowercased item to the root the lane opens in, under the clone the provider's worktree names"

STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" LANE_HOST_STUB_PUT_STATUS=1 RUN_TMUX=stub,1,0 \
  run_ot --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-64
assert_eq "rc=$RC marker=$(marker_at cc-64) records=$(records CC-64) refused=$(grep -c '^open-terminal: marker-failed item=CC-64 path=/srv/clone/.git/lane-mail/cc-64$' <<<"$ERR" || true) summary=$(grep -c '^open-terminal: summary launched=0 ' <<<"$ERR" || true)" \
  "rc=1 marker=none records=0 refused=1 summary=1" \
  "a hosted launch whose marker write fails names the item and the marker path, records nothing and launches nothing"

# A relaunch onto a host whose create wrote no marker: the lane is recovered
# and marked, so a sandbox made before its provider wrote records is not deaf
# for the rest of its life.
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot --relaunch --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-65
assert_eq "rc=$RC marker=$(marker_at cc-65) relaunch=$(grep -c '^create --item CC-65 .*--relaunch $' "$TMP_ROOT/host.log" || true)" \
  "rc=0 marker=root relaunch=1" \
  "a hosted relaunch writes the marker its host never carried"

echo "=== a relaunch of a parked record starts its sandbox before create --relaunch ==="
# lane-close --park left the record parked with its sandbox stopped. The
# relaunch asks the provider to start it, requires the protocol's line, and
# only then creates with --relaunch; the record it rewrites reads running and
# carries no `parked`, the park kept as a pause from its time to the start.
# A start that fails, or answers without the line, fails the item before any
# create, and the record stays parked.
PARKED_AT=2026-09-20T10:00:00Z
PAUSE_READ='[.lanes[] | select(.item == "CC-65") | .pauses[-1] | [.from, .cause, (.to | fromdate) > (.from | fromdate)]] | first'
"$WS" --state-dir "$STATE" update oversee --arg at "$PARKED_AT" '(.lanes[] | select(.item == "CC-65")) |= (.status = "parked" | .parked = {pr: 65, head: "abc", repo: "o/r", at: $at})' >/dev/null
: > "$TMP_ROOT/host.log"
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot --relaunch --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-65
assert_eq "rc=$RC started=$(grep -c '^open-terminal: host-started item=CC-65 ' <<<"$OUT" || true) order=$(awk '$1 == "start" || $1 == "create" { print $1 }' "$TMP_ROOT/host.log" | paste -sd, -) start=$(grep -c '^start --item CC-65 $' "$TMP_ROOT/host.log" || true) status=$(field "$(record CC-65)" status) parked=$("$WS" --state-dir "$STATE" get oversee '[.lanes[] | select(.item == "CC-65") | has("parked")] | first') pause=$("$WS" --state-dir "$STATE" get oversee "$PAUSE_READ" | jq -c .)" \
  "rc=0 started=1 order=start,create start=1 status=running parked=false pause=[\"$PARKED_AT\",\"parked\",true]" \
  "a parked record's relaunch starts the sandbox, then creates with --relaunch, and the running record drops parked and keeps it as a pause"
for row in 'LANE_HOST_STUB_START_STATUS=1|host-start-failed item=CC-65 exit=1' 'LANE_HOST_STUB_START_OUT=|host-start-failed item=CC-65 cause=answer-unparsed'; do
  IFS='|' read -r plant expect <<<"$row"
  "$WS" --state-dir "$STATE" update oversee '(.lanes[] | select(.item == "CC-65")) |= (.status = "parked" | .parked = {pr: 65, head: "abc", repo: "o/r", at: "t"})' >/dev/null
  : > "$TMP_ROOT/host.log"
  ( export "$plant"
    STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
      run_ot --relaunch --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-65
    printf '%s\n' "$RC" > "$TMP_ROOT/park-rc"; printf '%s\n' "$ERR" > "$TMP_ROOT/park-err" )
  RC="$(cat "$TMP_ROOT/park-rc")"; ERR="$(cat "$TMP_ROOT/park-err")"
  assert_eq "rc=$RC refused=$(grep -c "^open-terminal: $expect\$" <<<"$ERR" || true) creates=$(grep -c '^create ' "$TMP_ROOT/host.log" || true) status=$(field "$(record CC-65)" status)" \
    "rc=1 refused=1 creates=0 status=parked" \
    "$plant: a start the provider fails or leaves unconfirmed creates nothing and keeps the record parked"
done
# A start the provider confirmed is a sandbox up with no harness in it, which
# is what stopped means: the record reads so before the create, and a create
# that fails from there leaves it stopped, never parked over a running sandbox.
"$WS" --state-dir "$STATE" update oversee '(.lanes[] | select(.item == "CC-65")) |= (.status = "parked" | .parked = {pr: 65, head: "abc", repo: "o/r", at: "t"})' >/dev/null
: > "$TMP_ROOT/host.log"
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" LANE_HOST_STUB_CREATE_OWNED=CC-65 RUN_TMUX=stub,1,0 \
  run_ot --relaunch --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-65
assert_eq "rc=$RC started=$(grep -c '^open-terminal: host-started item=CC-65 host=.* status=stopped$' <<<"$OUT" || true) creates=$(grep -c '^create ' "$TMP_ROOT/host.log" || true) status=$(field "$(record CC-65)" status) parked=$("$WS" --state-dir "$STATE" get oversee '[.lanes[] | select(.item == "CC-65") | has("parked")] | first')" \
  "rc=75 started=1 creates=1 status=stopped parked=false" \
  "a create that fails after a confirmed start leaves the record stopped with parked dropped, the sandbox being up"
assert_eq "$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-65") | .pending_pr | {pr,repo,head}' | jq -c .)" '{"pr":65,"repo":"o/r","head":"abc"}' \
  "failed create keeps the PR wait after the sandbox starts"
# The control: a copy of the launcher whose unpark drops the park without
# keeping it, beside links to its helpers in a git repo of its own.
UNPAUSED_OT="$(mutant_scripts unpaused open-terminal)/open-terminal" || exit 1
git -C "$TMP_ROOT/unpaused" init -q
git -C "$TMP_ROOT/unpaused" config gc.auto 0
git -C "$TMP_ROOT/unpaused" config maintenance.auto false
orch_fixture_shared_libs "$TMP_ROOT/unpaused"
mutate_file "$UNPAUSED_OT" '  else .pauses = ((.pauses // []) + [{from: .parked.at, to: $at, cause: "parked"}]) end)' '  else . end)'
"$WS" --state-dir "$STATE" update oversee --arg at "$PARKED_AT" '(.lanes[] | select(.item == "CC-65")) |= (del(.pauses) | .status = "parked" | .parked = {pr: 65, head: "abc", repo: "o/r", at: $at})' >/dev/null
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot SCRIPT="$UNPAUSED_OT" --relaunch --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-65
assert_eq "rc=$RC pauses=$("$WS" --state-dir "$STATE" get oversee '[.lanes[] | select(.item == "CC-65") | .pauses // [] | length] | first')" "rc=0 pauses=0" \
  "control: without the pause the unpark keeps, a relaunch loses the parked time"
# A stopped record, --keep-sandbox's, is not parked: its sandbox is up and the
# relaunch asks for no start.
"$WS" --state-dir "$STATE" update oversee '(.lanes[] | select(.item == "CC-65")) |= (.status = "stopped")' >/dev/null
: > "$TMP_ROOT/host.log"
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot --relaunch --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-65
assert_eq "rc=$RC start=$(grep -c '^start ' "$TMP_ROOT/host.log" || true) creates=$(grep -c '^create --item CC-65 .*--relaunch $' "$TMP_ROOT/host.log" || true)" \
  "rc=0 start=0 creates=1" "a stopped record's relaunch starts no sandbox"
assert_eq "$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-65") | .pending_pr | {pr,repo,head}' | jq -c .)" '{"pr":65,"repo":"o/r","head":"abc"}' \
  "a later successful relaunch retains the same PR wait"

# The two reads ahead of the marker. A provider answers a file it does not
# have with a status and no line of its own, and the gitfile reader prints
# nothing either, so neither reaches the operator unless the launcher names it.
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" \
  LANE_HOST_STUB_CAT_STATUS=2 LANE_HOST_STUB_CAT_PATH=/srv/lane/.git RUN_TMUX=stub,1,0 \
  run_ot --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-68
assert_eq "rc=$RC first=$(grep -c '^open-terminal: host-gitfile-unread item=CC-68 path=/srv/lane/.git$' <<<"$ERR" || true) marker_failed=$(grep -c '^open-terminal: marker-failed ' <<<"$ERR" || true) records=$(records CC-68)" \
  "rc=1 first=1 marker_failed=0 records=0" \
  "a lane whose .git the host cannot produce names that read, not the marker write"

# A .git holding anything but a linked worktree's gitdir line: its own disk, so
# the rows above keep the one the launches read.
BENT_DISK="$TMP_ROOT/remote-bent"
mkdir -p "$BENT_DISK/srv/lane"
printf 'gitdir: worktrees/lane\n' > "$BENT_DISK/srv/lane/.git"
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$BENT_DISK" RUN_TMUX=stub,1,0 \
  run_ot --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-69
assert_eq "rc=$RC first=$(grep -c '^open-terminal: host-gitfile-invalid item=CC-69 path=/srv/lane/.git value=gitdir: worktrees/lane$' <<<"$ERR" || true) marker_failed=$(grep -c '^open-terminal: marker-failed ' <<<"$ERR" || true) records=$(records CC-69)" \
  "rc=1 first=1 marker_failed=0 records=0" \
  "a .git that names no linked worktree git directory names that read and the line it held"

# The read-back. A provider that accepts the whole transfer and lands other
# bytes reports no failure of its own, so the marker holds a root no session
# opens in and lane-mail-check reads that lane as none.
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" \
  LANE_HOST_STUB_PUT_BYTES=/srv/stale RUN_TMUX=stub,1,0 \
  run_ot --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-70
assert_eq "rc=$RC marker=$(marker_at cc-70) records=$(records CC-70) refused=$(grep -cx 'open-terminal: marker-failed item=CC-70 path=/srv/clone/.git/lane-mail/cc-70' <<<"$ERR" || true)" \
  "rc=1 marker=other records=0 refused=1" \
  "a marker that reads back holding another root fails the item and records nothing"

echo "=== --state-dir is the record's one address, wherever the launch runs from ==="
ELSEWHERE="$TMP_ROOT/elsewhere"
mkdir -p "$ELSEWHERE"
git -C "$ELSEWHERE" init -q
git -C "$ELSEWHERE" config gc.auto 0
git -C "$ELSEWHERE" config maintenance.auto false
# The fleet's overseer runs in that checkout, as its record names.
"$WS" --state-dir "$TMP_ROOT/named" init oversee >/dev/null
"$WS" --state-dir "$TMP_ROOT/named" update oversee --arg cwd "$ELSEWHERE" '.overseer = {cwd: $cwd}' >/dev/null
run_ot STATE_DIR= CWD="$ELSEWHERE" --ghostty "${FLEET_CMD[@]}" --state-dir "$TMP_ROOT/named" CC-50
assert_eq "rc=$RC named=$(jq -r '[.lanes[] | select(.item == "CC-50")] | length' "$TMP_ROOT/named/workflow-state-oversee.json" 2>/dev/null || echo none) launch_dir=$([[ -e "$ELSEWHERE/tmp/workflow-state-oversee.json" ]] && echo written || echo none)" \
  "rc=0 named=1 launch_dir=none" \
  "a launch run from another checkout records into the named state directory and not into that checkout's own"

echo "=== a record that cannot be written into a live state fails the item with its window standing ==="
# The oversee workflow has surface 2 hand-append lane records; a non-object entry
# (which the watch's own filter anticipates) makes the update-report filter
# index it and fail, the write path record-write-failed guards. The state is
# created by an ordinary launch first, then broken.
run_ot STATE_DIR="$FLEET_ROOT/rwf-state" --ghostty "${FLEET_CMD[@]}" CC-80
"$WS" --state-dir "$FLEET_ROOT/rwf-state" update oversee '.lanes += [42]' >/dev/null
run_ot STATE_DIR="$FLEET_ROOT/rwf-state" --ghostty "${FLEET_CMD[@]}" CC-81
assert_eq "rc=$RC opened=$(grep -c '^open-terminal: terminal-opened item=CC-81 ' <<<"$OUT" || true) refused=$(grep -c '^open-terminal: record-write-failed item=CC-81 state=oversee$' <<<"$ERR" || true) summary=$(grep -o 'failed=[0-9]*' <<<"$ERR")" \
  "rc=1 opened=1 refused=1 summary=failed=1" \
  "a launch whose record write fails opens its window, is reported record-write-failed after the cause workflow-state names, and counts failed"

echo "=== launched_at is read before the window opens ==="
# The tmux stub notes when the window opened and then holds the open for two
# seconds, longer than the stamp's resolution: a stamp read before the open is
# not later than that moment, and one read after it is.
OPENED_AT="$TMP_ROOT/opened-at"
STUB_OPENED_AT="$OPENED_AT" STUB_OPEN_DELAY=2 RUN_TMUX=stub,1,0 run_ot --tmux "${FLEET_CMD[@]}" CC-95
assert_eq "rc=$RC order=$([[ "$(field "$(record CC-95)" launched_at)" > "$(cat "$OPENED_AT")" ]] && echo later || echo not-later)" "rc=0 order=not-later" \
  "the recorded launched_at is not later than the moment the window opened"

echo "=== a launch with no --state-dir names no fleet: no record, no state ==="
# The handoff workflow's launch-only commands pass no --state-dir; the launcher then
# writes nothing into the launch checkout's own oversee state, which is the
# file an overseer in that project reads.
NOFLEET="$TMP_ROOT/nofleet"
mkdir -p "$NOFLEET"
git -C "$NOFLEET" init -q
git -C "$NOFLEET" config gc.auto 0
git -C "$NOFLEET" config maintenance.auto false
run_ot STATE_DIR= CWD="$NOFLEET" --ghostty --cmd true CC-90
assert_eq "rc=$RC opened=$(grep -c '^open-terminal: terminal-opened item=CC-90 ' <<<"$OUT" || true) launch_dir=$([[ -e "$NOFLEET/tmp/workflow-state-oversee.json" ]] && echo written || echo none)" \
  "rc=0 opened=1 launch_dir=none" \
  "a launch with no --state-dir opens its window and writes no record and no state anywhere"

echo "=== a refused item and a wake create no state where none exists ==="
# Both rows share one directory no earlier row wrote: the state is minted only
# past the item refusals, and a wake mints none, so a mistyped id or a wake
# pointed at the wrong address leaves no empty fleet for the watch to read.
EMPTY_STATE="$FLEET_ROOT/empty-state"
run_ot STATE_DIR="$EMPTY_STATE" --ghostty "${FLEET_CMD[@]}" bad_id
assert_eq "rc=$RC refused=$(grep -c '^open-terminal: issue-invalid item=bad_id$' <<<"$ERR" || true) state=$([[ -e "$EMPTY_STATE/workflow-state-oversee.json" ]] && echo written || echo none)" \
  "rc=1 refused=1 state=none" \
  "an item id matching no pattern is refused, after the line git-context prints, before the state is created"
run_ot STATE_DIR="$EMPTY_STATE" --wake --harness claude CC-40
assert_eq "rc=$RC refused=$(grep -c "^open-terminal: state-absent item=CC-40 state=$EMPTY_STATE/workflow-state-oversee.json\$" <<<"$ERR" || true) woken=$(grep -c '^open-terminal: lane-woken ' <<<"$OUT" || true) state=$([[ -e "$EMPTY_STATE/workflow-state-oversee.json" ]] && echo written || echo none)" \
  "rc=1 refused=1 woken=0 state=none" \
  "a wake against an address holding no state names the file it looked for, wakes nothing and creates nothing"

echo "=== a state that cannot be created refuses the batch before any window opens ==="
: > "$FLEET_ROOT/blocker"
run_ot STATE_DIR="$FLEET_ROOT/blocker/state" --ghostty "${FLEET_CMD[@]}" CC-20 CC-21
assert_eq "rc=$RC opened=$(grep -c '^open-terminal: terminal-opened ' <<<"$OUT" || true) refused=$(grep -c '^open-terminal: state-unwritable state=oversee$' <<<"$ERR" || true) summary=$(grep -c '^open-terminal: summary ' <<<"$ERR$OUT" || true)" \
  "rc=1 opened=0 refused=1 summary=0" \
  "a state directory under a file refuses the whole batch as state-unwritable, with no window opened and no summary"

# fixture_copy NAME — a copy of the launcher beside its helpers under
# $TMP_ROOT/NAME, for the row that takes a helper away.
fixture_copy() {
  local dir="$TMP_ROOT/$1"
  mutant_scripts "$1" >/dev/null || exit 1
  orch_fixture_shared_libs "$dir"
  git -C "$dir" init -q
  git -C "$dir" config gc.auto 0
  git -C "$dir" config maintenance.auto false
}

echo "=== a launcher with no workflow-state beside it refuses before any window opens ==="
fixture_copy nohelper
rm "$TMP_ROOT/nohelper/scripts/workflow-state"
run_ot SCRIPT="$TMP_ROOT/nohelper/scripts/open-terminal" --ghostty "${FLEET_CMD[@]}" CC-70
assert_eq "rc=$RC first=$(sed -n 1p <<<"$ERR") opened=$(grep -c '^open-terminal: terminal-opened ' <<<"$OUT" || true)" \
  "rc=1 first=open-terminal: helper-missing path=$TMP_ROOT/nohelper/scripts/workflow-state opened=0" \
  "the missing helper is named first and no terminal opens"

echo "=== the must-fail control ==="
# The suite's one control: the record write gone from a copy of the launcher,
# beside links to its helpers in a git repo of its own.
UNWRITTEN_OT="$(mutant_scripts unwritten open-terminal)/open-terminal" || exit 1
git -C "$TMP_ROOT/unwritten" init -q
git -C "$TMP_ROOT/unwritten" config gc.auto 0
git -C "$TMP_ROOT/unwritten" config maintenance.auto false
orch_fixture_shared_libs "$TMP_ROOT/unwritten"
mutate_file "$UNWRITTEN_OT" '    lane_record_write "$RECORD_MODE" "$wt_id" "$record_window" "$record_root" "$record_session" "$launched_at" || record_rc=$?' '    :'
run_ot SCRIPT="$UNWRITTEN_OT" STATE_DIR="$FLEET_ROOT/unwritten-state" --ghostty "${FLEET_CMD[@]}" CC-30
assert_eq "rc=$RC records=$("$WS" --state-dir "$FLEET_ROOT/unwritten-state" get oversee '(.lanes // []) | length')" "rc=0 records=0" \
  "control: without the write a launch leaves the created state with no record and reports success"
# The running_at stamp's own control: dropped from a copy of the launcher, a
# lane recorded running carries none, so the watch would fall back to a
# launch time a relaunch keeps.
UNSTAMPED_OT="$(mutant_scripts unstamped open-terminal)/open-terminal" || exit 1
git -C "$TMP_ROOT/unstamped" init -q
git -C "$TMP_ROOT/unstamped" config gc.auto 0
git -C "$TMP_ROOT/unstamped" config maintenance.auto false
orch_fixture_shared_libs "$TMP_ROOT/unstamped"
mutate_file "$UNSTAMPED_OT" '  [[ "$status" != running ]] || running_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1' '  :'
run_ot SCRIPT="$UNSTAMPED_OT" STATE_DIR="$FLEET_ROOT/unstamped-state" --ghostty "${FLEET_CMD[@]}" CC-31
assert_eq "rc=$RC running_at=$("$WS" --state-dir "$FLEET_ROOT/unstamped-state" get oversee '.lanes[0].running_at // "null"' | tr -d '"')" "rc=0 running_at=null" \
  "control: without the stamp a lane recorded running carries no running_at"

echo "=== a host still preparing the item hands the launch to a background job ==="
# The provider accepts the item with state=preparing and holds wait shut until
# its gate file exists. The launch returns with the gate shut: the window and
# its claim are open, the record names the lane preparing, and no launch step
# has reached the host yet. The job it left finishes the launch once the gate
# opens and records the outcome in the record's status.
PREPARING_LINE=$'ssh-target=lane.example\tpath=/srv/lane\tremote-prefix=exec bash -lc\tstate=preparing'
# prepared ITEM — the record's status, whether it carries a prepare record, and
# the failure reason that record names.
prepared() {
  "$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$1"'") | "\(.status) \(if .prepare then "prepare" else "none" end) \(.prepare.reason // "none")"' | tr -d '"'
}
# settled ITEM — the same once the job has left preparing, 20 seconds at most.
settled() {
  local now=""
  for _ in $(seq 80); do
    now="$(prepared "$1")"
    [[ "$now" == preparing* ]] || break
    sleep 0.25
  done
  printf '%s' "$now"
}
# log_line FILE LINE — how many whole lines of FILE are LINE once one is, 20
# seconds at most: the job prints its verdict after the record it describes.
log_line() {
  local n=0
  for _ in $(seq 80); do
    n="$(grep -cxF -- "$2" "$1" 2>/dev/null || true)"
    [[ "$n" == 0 ]] || break
    sleep 0.25
  done
  printf '%s' "$n"
}
claims_for() { grep -l "	$1	" "$TMP_ROOT/claims/claims/"*.claim 2>/dev/null | awk 'END { print NR + 0 }'; }
# hand_off ITEM [ENV=VALUE]... [-- ARGS...] — one hosted fleet launch of ITEM
# against the preparing provider, its tmux calls logged afresh. ARGS lead the
# launch's own, run_ot's SCRIPT= and STATE_DIR= first. HAND_OFF_HARNESS and
# HAND_OFF_CMD replace the claude harness and its command.
hand_off() {
  local item="$1" envs=() args=()
  shift
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  [[ $# -eq 0 ]] || { shift; args=("$@"); }
  : >"$TMUX_LOG"
  export STUB_TMUX_LOG="$TMUX_LOG" STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" \
    LANE_HOST_STUB_DIR="$HOSTED_DISK" LANE_HOST_STUB_CREATE_LINE="$PREPARING_LINE" RUN_TMUX=stub,1,0
  local kv
  for kv in ${envs[@]+"${envs[@]}"}; do export "${kv?}"; done
  local cmd_args=(--cmd "${HAND_OFF_CMD:-true --model opus --effort high} $QUESTION_OFF_ALL $COMPACTION_OFF_ALL")
  [[ "${HAND_OFF_CMD:-}" != - ]] || cmd_args=()
  run_ot ${args[@]+"${args[@]}"} --tmux --harness "${HAND_OFF_HARNESS:-claude}" --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r ${cmd_args[@]+"${cmd_args[@]}"} "$item"
  for kv in ${envs[@]+"${envs[@]}"}; do unset "${kv%%=*}"; done
  unset STUB_TMUX_LOG STUB_PANE_CMD STUB_PANE_TEXT LANE_HOST_STUB_LOG LANE_HOST_STUB_DIR LANE_HOST_STUB_CREATE_LINE RUN_TMUX
}

hand_off CC-73 LANE_HOST_STUB_WAIT_GATE="$TMP_ROOT/gate-73"
assert_eq "rc=$RC summary=$(grep -c '^open-terminal: summary launched=0 preparing=1 skipped=0 failed=0 ' <<<"$OUT" || true) handed=$(grep -c "^open-terminal: lane-preparing item=CC-73 log=$STATE/lane-prepare-CC-73.log$" <<<"$OUT" || true) record=$(prepared CC-73) pid=$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-73") | .prepare.pid | type') window=$(grep -c '^new-window =stub:1$' "$TMUX_LOG" || true) claims=$(claims_for CC-73) marker=$(marker_at cc-73)" \
  "rc=0 summary=1 handed=1 record=preparing prepare none pid=number window=1 claims=1 marker=none" \
  "a launch whose host is still preparing returns at once with its window and claim open, the lane recorded preparing under its job's pid, and nothing launched on the host"
assert_eq "running_at=$(running_at CC-73)" "running_at=null" "a lane recorded preparing carries no running_at: its host's time is not the lane's"
touch "$TMP_ROOT/gate-73"
assert_eq "record=$(settled CC-73) marker=$(marker_at cc-73) window=$(field "$(record CC-73)" window) root=$(field "$(record CC-73)" mail_root) running_at=$(stamped "$(running_at CC-73)")" \
  "record=running prepare none marker=root window=stub:CC-73 root=/srv/lane running_at=iso" \
  "once the host is ready the job launches the lane in its window and records it running, stamping running_at then"
# A later launch that is not handed off drops the preparation it replaces, or
# the watch would read that stale record of a live lane.
STUB_PICK_CLAIMS=3 STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot --relaunch --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-73
assert_eq "rc=$RC record=$(prepared CC-73) pick=$(pick_claims CC-73)" "rc=0 record=running none none pick=3" \
  "a relaunch whose host answers at once drops the earlier preparation from the record and records its own pick reading"

# A relaunch has not taken while its host prepares or after that wait fails,
# so the pick reading of the launch that took stays beside its account.
HAND_OFF_CMD="true --model claude-sonnet-5 --effort low" hand_off CC-73 STUB_PICK_CLAIMS=7 LANE_HOST_STUB_WAIT_GATE="$TMP_ROOT/gate-73-relaunch" LANE_HOST_STUB_WAIT_STATUS=1 -- --relaunch
assert_eq "rc=$RC record=$(prepared CC-73) model=$(field "$(record CC-73)" model) effort=$(field "$(record CC-73)" effort) pick=$(pick_claims CC-73)" \
  "rc=0 record=preparing prepare none model=opus effort=high pick=3" "a preparing relaunch keeps the prior model, effort and pick reading"
touch "$TMP_ROOT/gate-73-relaunch"
assert_eq "record=$(settled CC-73) model=$(field "$(record CC-73)" model) effort=$(field "$(record CC-73)" effort) pick=$(pick_claims CC-73)" \
  "record=stopped prepare wait-failed model=opus effort=high pick=3" "a stopped relaunch keeps the prior model, effort and pick reading"
# A relaunch that runs on no judged reading drops the earlier one.
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot --relaunch --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-73
assert_eq "rc=$RC record=$(prepared CC-73) pick=$(pick_claims CC-73)" "rc=0 record=running none none pick=none" \
  "a running relaunch on no judged reading drops the pick an earlier launch recorded"
# Controls, one per rule. A record that drops the pick on a relaunch that has
# not taken shows the new reading beside the old account; one that keeps it
# through a running relaunch on no reading shows the old reading.
PICK_KEEP_OT="$(mutant_scripts pick-keep-mutant open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/pick-keep-mutant"
mutate_file "$PICK_KEEP_OT" 'del(.harness, .model, .effort, .preference_entry, .pick, .account, .session_id, .recovery)' 'del(.harness, .model, .effort, .preference_entry, .account, .session_id, .recovery)'
PICK_DROP_OT="$(mutant_scripts pick-drop-mutant open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/pick-drop-mutant"
mutate_file "$PICK_DROP_OT" 'del(.preference_entry, .pick)' 'del(.preference_entry)'
STUB_PICK_CLAIMS=4 STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot --relaunch --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-73
HAND_OFF_CMD="true --model claude-sonnet-5 --effort low" hand_off CC-73 STUB_PICK_CLAIMS=7 LANE_HOST_STUB_WAIT_GATE="$TMP_ROOT/gate-73-keep" LANE_HOST_STUB_WAIT_STATUS=1 -- SCRIPT="$PICK_KEEP_OT" --relaunch
assert_eq "rc=$RC record=$(prepared CC-73) pick=$(pick_claims CC-73)" "rc=0 record=preparing prepare none pick=7" \
  "control: a preparing relaunch that drops the kept pick records a reading its account was never judged on"
touch "$TMP_ROOT/gate-73-keep"
settled CC-73 >/dev/null
STUB_PICK_CLAIMS=4 STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot --relaunch --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-73
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot SCRIPT="$PICK_DROP_OT" --relaunch --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-73
assert_eq "rc=$RC record=$(prepared CC-73) pick=$(pick_claims CC-73)" "rc=0 record=running none none pick=4" \
  "control: a running relaunch that keeps the earlier pick records a reading this launch never took"

# The host's preparation fails: the job closes the window and records the lane
# stopped with the reason, the record lane-close takes.
hand_off CC-74 LANE_HOST_STUB_WAIT_STATUS=1
assert_eq "rc=$RC logged=$(log_line "$STATE/lane-prepare-CC-74.log" 'open-terminal: lane-prepare-failed item=CC-74 reason=wait-failed') record=$(prepared CC-74) closed=$(grep -c '^kill-window %1$' "$TMUX_LOG" || true) marker=$(marker_at cc-74)" \
  "rc=0 logged=1 record=stopped prepare wait-failed closed=1 marker=none" \
  "a preparation the host reports failed closes the window and leaves a stopped record naming the failed wait"
# A pane read that fails is a tmux failure, never a closed window: the job
# names it, kills nothing it cannot see, and still records its outcome.
hand_off CC-89 LANE_HOST_STUB_WAIT_STATUS=1 STUB_LIST_PANES_FAIL=1
assert_eq "rc=$RC logged=$(log_line "$STATE/lane-prepare-CC-89.log" 'open-terminal: lane-prepare-failed item=CC-89 reason=wait-failed') read=$(grep -c '^open-terminal: tmux-failed operation=list-panes item=CC-89$' "$STATE/lane-prepare-CC-89.log" || true) closed=$(grep -c '^kill-window ' "$TMUX_LOG" || true) record=$(prepared CC-89)" \
  "rc=0 logged=1 read=1 closed=0 record=stopped prepare wait-failed" \
  "a window close whose pane read fails reports tmux-failed operation=list-panes and kills nothing"
# A ready host whose launch step fails: the marker write here.
hand_off CC-77 LANE_HOST_STUB_PUT_STATUS=1
assert_eq "rc=$RC logged=$(log_line "$STATE/lane-prepare-CC-77.log" 'open-terminal: lane-prepare-failed item=CC-77 reason=launch-failed') record=$(prepared CC-77) step=$(grep -c '^open-terminal: marker-failed item=CC-77 ' "$STATE/lane-prepare-CC-77.log" || true)" \
  "rc=0 logged=1 record=stopped prepare launch-failed step=1" \
  "a launch step failing after the host is ready is recorded as launch-failed under the step's own line"

# The hand-off record cannot be written: the state holds an entry the write
# path cannot index. Nothing is left running and the window closes.
run_ot STATE_DIR="$FLEET_ROOT/pu-state" --ghostty "${FLEET_CMD[@]}" CC-80
"$WS" --state-dir "$FLEET_ROOT/pu-state" update oversee '.lanes += [42]' >/dev/null
hand_off CC-78 -- STATE_DIR="$FLEET_ROOT/pu-state"
assert_eq "rc=$RC refused=$(grep -c '^open-terminal: prepare-unrecorded item=CC-78 state=oversee$' <<<"$ERR" || true) closed=$(grep -c '^kill-window %1$' "$TMUX_LOG" || true) summary=$(grep -o 'launched=[0-9]* skipped=[0-9]* failed=[0-9]*' <<<"$ERR")" \
  "rc=1 refused=1 closed=1 summary=launched=0 skipped=0 failed=1" \
  "a hand-off whose record cannot be written names prepare-unrecorded, closes its window and counts failed"

# A batch whose one item another session owns and whose other is handed off
# launched something, so it is not the all-owned exit 75.
hand_off CC-79 LANE_HOST_STUB_CREATE_OWNED=CC-79 -- CC-86
touch "$TMP_ROOT/gate-86"
assert_eq "rc=$RC summary=$(grep -c '^open-terminal: summary launched=0 preparing=1 skipped=1 failed=0 ' <<<"$OUT" || true)" \
  "rc=0 summary=1" "a batch of one owned item and one handed off exits 0 and counts both"
settled CC-86 >/dev/null

# A create line naming any other state is not a host this launcher knows.
hand_off CC-81 LANE_HOST_STUB_CREATE_LINE=$'ssh-target=lane.example\tpath=/srv/lane\tremote-prefix=exec bash -lc\tstate=ready'
assert_eq "rc=$RC refused=$(grep -c '^open-terminal: host-line-invalid item=CC-81$' <<<"$ERR" || true) windows=$(grep -c '^new-window ' "$TMUX_LOG" || true)" \
  "rc=1 refused=1 windows=0" "a create line naming a state other than preparing is host-line-invalid and opens nothing"

# With no fleet there is no record to report the outcome through, so the
# launch waits for the host itself.
hand_off CC-75 -- STATE_DIR=
assert_eq "rc=$RC waited=$(grep -c '^wait --item CC-75 $' "$TMP_ROOT/host.log" || true) marker=$(marker_at cc-75) summary=$(grep -c '^open-terminal: summary launched=1 skipped=0 ' <<<"$OUT" || true)" \
  "rc=0 waited=1 marker=root summary=1" \
  "a launch naming no fleet waits for a preparing host in the foreground"
hand_off CC-82 LANE_HOST_STUB_WAIT_STATUS=1 -- STATE_DIR=
assert_eq "rc=$RC refused=$(grep -c '^open-terminal: host-prepare-failed item=CC-82$' <<<"$ERR" || true) marker=$(marker_at cc-82) summary=$(grep -o 'launched=[0-9]* skipped=[0-9]* failed=[0-9]*' <<<"$ERR")" \
  "rc=1 refused=1 marker=none summary=launched=0 skipped=0 failed=1" \
  "a foreground wait the host fails is host-prepare-failed and launches nothing"

# A hosted codex relaunch that resumes carries no continuation line;
# resume-lineless must reach the caller, so that relaunch waits in the
# foreground even in a fleet. One whose record names claude starts fresh on its
# start brief, which carries the line, so it is handed off like any launch.
CODEX_RELAUNCH=(-- --relaunch --launch-flags "-m gpt-5 -c model_reasoning_effort=high")
HAND_OFF_HARNESS=codex HAND_OFF_CMD=- hand_off CC-83 LANE_HOST_STUB_SELECTION=resume STUB_BUFFER_LOG="$TMP_ROOT/codex-typed" STUB_HARNESS_TEXT='Working (esc to interrupt)' "${CODEX_RELAUNCH[@]}"
assert_eq "rc=$RC waited=$(grep -c '^wait --item CC-83 $' "$TMP_ROOT/host.log" || true) handed=$(grep -c '^open-terminal: lane-preparing ' <<<"$OUT" || true) lineless=$(grep -c '^open-terminal: resume-lineless item=CC-83 harness=codex$' <<<"$ERR" || true) record=$(prepared CC-83)" \
  "rc=0 waited=1 handed=0 lineless=1 record=running none none" \
  "a hosted codex relaunch that resumes waits for its host in the foreground and reports resume-lineless to the caller"
: > "$TMP_ROOT/host.log"
HAND_OFF_HARNESS=codex HAND_OFF_CMD=- hand_off CC-83 STUB_BUFFER_LOG="$TMP_ROOT/codex-typed" ORCH_TMUX_VERIFY_SECS=1 "${CODEX_RELAUNCH[@]}"
assert_eq "rc=$RC waited=$(grep -c '^wait --item CC-83 $' "$TMP_ROOT/host.log" || true) missing=$(grep -c '^open-terminal: harness-screen-missing item=CC-83 seconds=2$' <<<"$ERR" || true) record=$(prepared CC-83)" \
  "rc=1 waited=1 missing=1 record=stopped none none" \
  "a foreground hosted codex relaunch at a bare shell fails and records stopped"
NO_SCREEN_OT="$(mutant_scripts no-screen open-terminal)" || exit 1
mutate_file "$NO_SCREEN_OT/open-terminal" '    tmux_wait_harness "$pane" "$harness_secs" || harness_rc=$?' '    :'
HAND_OFF_HARNESS=codex HAND_OFF_CMD=- hand_off CC-83 LANE_HOST_STUB_SELECTION=resume STUB_BUFFER_LOG="$TMP_ROOT/codex-typed" -- SCRIPT="$NO_SCREEN_OT/open-terminal" "${CODEX_RELAUNCH[@]:1}"
assert_eq "rc=$RC record=$(prepared CC-83)" "rc=0 record=running none none" \
  "control: without the screen check a bare shell renews the record as running"
"$WS" --state-dir "$STATE" update oversee '.lanes += [{item: "CC-87", harness: "claude", status: "running"}]' >/dev/null
HAND_OFF_HARNESS=codex HAND_OFF_CMD=- hand_off CC-87 STUB_HARNESS_TEXT='Working (esc to interrupt)' "${CODEX_RELAUNCH[@]}"
assert_eq "rc=$RC handed=$(grep -c '^open-terminal: lane-preparing item=CC-87 ' <<<"$OUT" || true) lineless=$(grep -c 'resume-lineless' <<<"$ERR" || true) record=$(settled CC-87)" \
  "rc=0 handed=1 lineless=0 record=running prepare none" \
  "a hosted codex relaunch across a harness switch starts fresh and is handed off"
LINELESS_MUTANT="$(mutant_scripts lineless-mutant open-terminal)" || exit 1
mutate_file "$LINELESS_MUTANT/open-terminal" '"$FLEET" == true && -z "$HOST_SELECTION_FILE" && -z "$host_pending_step" ]]' '"$FLEET" == true && "$HARNESS" != codex ]]'
"$WS" --state-dir "$STATE" update oversee '.lanes += [{item: "CC-88", harness: "claude", status: "running"}]' >/dev/null
HAND_OFF_HARNESS=codex HAND_OFF_CMD=- hand_off CC-88 STUB_HARNESS_TEXT='Working (esc to interrupt)' -- SCRIPT="$LINELESS_MUTANT/open-terminal" "${CODEX_RELAUNCH[@]:1}"
assert_eq "handed=$(grep -c '^open-terminal: lane-preparing item=CC-88 ' <<<"$OUT" || true)" "handed=0" \
  "control: gated on every hosted codex relaunch the switched one waits in the foreground"

# lane-host refuses a call at its per-home cap once every slot stays taken. A
# slot naming this suite's own shell, alive throughout, fills a cap of 1 in a
# home of the suite's own, and
# the provider below plants that slot as create runs, so create is admitted
# and the launch's next host call is the one refused; under BUSY_PLANT_ON it
# plants it as that verb runs instead, the capabilities read every launch makes
# first, so create is the call refused.
BUSY_HOME="$TMP_ROOT/busy-home"
BUSY_SLOTS="$BUSY_HOME/.cache/orch/lane-host-slots"
mkdir -p "$BUSY_SLOTS/short"
BUSY_SLOT="$BUSY_SLOTS/slot.$$"
BUSY_HOST="$TMP_ROOT/busy-provider"
cat > "$BUSY_HOST" <<EOF
#!/usr/bin/env bash
[ "\$1" != "\${BUSY_PLANT_ON:-create}" ] || : > "\${BUSY_PLANT_SLOT:-$BUSY_SLOT}"
exec "$HOST_STUB" "\$@"
EOF
chmod +x "$BUSY_HOST"
# busy_hand_off ITEM [ENV=VALUE]... [-- ARGS...] — hand_off against that
# provider, under a cap of 1 that refuses at once.
busy_hand_off() {
  local item="$1"
  shift
  HOME="$BUSY_HOME" HOST_STUB="$BUSY_HOST" hand_off "$item" ORCH_LANE_HOST_MAX_CALLS=1 ORCH_LANE_HOST_BUSY_WAIT_SECS=0 ORCH_LANE_HOST_SHORT_MAX_CALLS=1 ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS=0 "$@"
}
# A background job exists to wait for its host: a wait refused at the cap is
# asked again, the record stays preparing and the window open, and the launch
# finishes once a slot frees.
busy_hand_off CC-91
busy="$(log_line "$STATE/lane-prepare-CC-91.log" 'lane-host: lane-host-busy count=1 cap=1 verb=wait item=CC-91')"
assert_eq "rc=$RC busy=$([[ "$busy" -ge 1 ]] && echo yes || echo "$busy") record=$(prepared CC-91) closed=$(grep -c '^kill-window ' "$TMUX_LOG" || true) failed=$(grep -c '^open-terminal: lane-prepare-failed ' "$STATE/lane-prepare-CC-91.log" || true)" \
  "rc=0 busy=yes record=preparing prepare none closed=0 failed=0" \
  "a background wait lane-host refused at its cap keeps the record preparing and the window open"
rm -f -- "${BUSY_SLOT:?}"
assert_eq "record=$(settled CC-91) marker=$(marker_at cc-91)" "record=running prepare none marker=root" \
  "once a slot frees the job's next wait is admitted and the lane launches"
# A foreground launch has no job to wait in: the refused step is lane-host-busy,
# never the host failing. STEP|ITEM|ENV: create is refused by the slot the
# capabilities read plants, wait and marker by the slot create plants, marker
# after a create that answers ready.
TAB=$'\t'
while IFS='|' read -r step item env; do
  [[ -n "$step" ]] || continue
  busy_hand_off "$item" ${env:+"$env"} -- STATE_DIR=
  unset BUSY_PLANT_ON
  rm -f -- "${BUSY_SLOT:?}" "$BUSY_SLOTS/short/slot.$$"
  expected_rc=0 expected_failed=0
  [[ "$step" != create ]] || { expected_rc=1; expected_failed=1; }
  assert_eq "rc=$RC busy=$(grep -cE "^open-terminal: lane-host-busy item=$item step=$step( |\$)" <<<"$ERR" || true) other=$(grep -cE '^open-terminal: (host-create-failed|host-prepare-failed|host-gitfile-unread) ' <<<"$ERR" || true) failed=$(grep -o 'failed=[0-9]*' <<<"$ERR$OUT")" \
    "rc=$expected_rc busy=1 other=0 failed=failed=$expected_failed" \
    "a foreground $step lane-host refused at its cap is lane-host-busy and launches nothing"
done <<ROWS
create|CC-92|BUSY_PLANT_ON=capabilities
wait|CC-93|
marker|CC-94|BUSY_PLANT_SLOT=$BUSY_SLOTS/short/slot.$$
ROWS

# The job outlives a kill of the caller's process group, which is what a
# harness sends the command it ran on return or timeout. The launch runs in a
# group of its own here, which is killed once the launch has returned.
group_killed() { # SCRIPT ITEM
  set -m
  (hand_off "$2" LANE_HOST_STUB_WAIT_GATE="$TMP_ROOT/gate-$2" -- SCRIPT="$1") >/dev/null &
  local group=$!
  wait "$group" || true
  set +m
  kill -TERM -- "-$group" 2>/dev/null || true
  touch "$TMP_ROOT/gate-$2"
  settled "$2"
}
assert_eq "record=$(group_killed "$OT" CC-84)" "record=running prepare none" \
  "a launch job survives a kill of the caller's process group and finishes the launch"

# The busy controls, each a copy of the launcher with one line changed beside
# links to its helpers in a git repo of its own: without the retry a
# background wait refused at the cap stops the lane, and without the create's
# busy branch a refused create reads as the host failing.
busy_mutant() { # NAME OLD NEW — sets BUSY_MUTANT_OT
  BUSY_MUTANT_OT="$(mutant_scripts "$1" open-terminal)/open-terminal" || exit 1
  git -C "$TMP_ROOT/$1" init -q
  git -C "$TMP_ROOT/$1" config gc.auto 0
  git -C "$TMP_ROOT/$1" config maintenance.auto false
  orch_fixture_shared_libs "$TMP_ROOT/$1"
  mutate_file "$BUSY_MUTANT_OT" "$2" "$3"
}
busy_mutant unretried '  HOST_BUSY_RETRY=true' '  :'
busy_hand_off CC-95 -- SCRIPT="$BUSY_MUTANT_OT"
assert_eq "record=$(settled CC-95)" "record=stopped prepare wait-failed" \
  "control: without the retry a background wait refused at the cap stops the lane"
busy_mutant createbusy '  elif [[ "$create_rc" -eq "$LANE_HOST_BUSY_EXIT" && "$LANE_HOST" != local ]]; then' '  elif false; then'
rm -f -- "${BUSY_SLOT:?}"
busy_hand_off CC-96 BUSY_PLANT_ON=capabilities -- SCRIPT="$BUSY_MUTANT_OT" STATE_DIR=
unset BUSY_PLANT_ON
rm -f -- "${BUSY_SLOT:?}"
assert_eq "failed=$(grep -c '^open-terminal: host-create-failed item=CC-96 exit=69$' <<<"$ERR" || true)" "failed=1" \
  "control: without the busy branch a create refused at the cap is host-create-failed"

echo "=== a hosted Pi fleet lane is judged on its host's own Pi settings and carrier ==="
# Read through the provider once create stands and before the window opens:
# the settings under the Pi root create names, else under Pi's default root in
# the host home, the lane tree's project file, and the pi-hooks carrier the
# tree or else that root installs. This machine's Pi settings, absent here and
# so compaction on, are not the lane's, nor is its carrier, which sends the
# window. `label|pi-root|carrier|user settings|project settings|env|answer`,
# `-` for none; carrier is `sends` or `old` under the root, `nowake`, one
# under the root that sends and lists no lane mail wake, `project-nowake`, a
# stale project carrier ahead of the current global carrier, `none`, or
# `shadowed`, a tree carrier from before vocab.ts ahead of a root one that
# sends. The answer is `launched` or the refusal line.
PI_LOCAL="$TMP_ROOT/pi-local"
mkdir -p "$PI_LOCAL/packages/@vanillagreen/pi-hooks/extensions"
printf 'export const f = { context_window: 1 };\n' > "$PI_LOCAL/packages/@vanillagreen/pi-hooks/extensions/vocab.ts"
PI_WAKE_MANIFEST='{"pi":{"extensions":["./extensions/hooks.ts","./extensions/lane-mail-wake.ts"]}}'
printf '%s\n' "$PI_WAKE_MANIFEST" > "$PI_LOCAL/packages/@vanillagreen/pi-hooks/package.json"
OFF='{"compaction":{"enabled":false}}' ON='{"compaction":{"enabled":true}}'
printf '%s\n' "$OFF" > "$PI_LOCAL/settings.json"

# Fleet's lane_records reads the resolved effort beside model. Opencode has
# no fleet adapter: its writer fixture bypasses admission, not the recorder.
EFFORT_SCRIPTS="$(mutant_scripts effort-writer open-terminal)" || exit 1
mutate_file "$EFFORT_SCRIPTS/open-terminal" '    *) ot_message unsupported-for-oversee "harness=${LAUNCH_HARNESS:-none}" >&2; return 1 ;;' '    *) ;;'
while IFS='|' read -r item harness flags want; do
  effort_ot="$OT"
  [[ "$harness" != opencode ]] || effort_ot="$EFFORT_SCRIPTS/open-terminal"
  PI_CODING_AGENT_DIR="$PI_LOCAL" COPILOT_HOME="$COP_RECORD_HOME" run_ot SCRIPT="$effort_ot" CWD="$REPO" --ghostty --harness "$harness" \
    --cmd "true $flags $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" "$item"
  assert_eq "rc=$RC effort=$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$item"'") | [has("effort"), .effort]' | jq -c .)" \
    "rc=0 effort=[true,$want]" "$harness launch effort: $flags" "$TMP_ROOT/err"
done <<'ROWS'
CC-180|claude|--model opus --effort high|"high"
CC-181|codex|-m gpt-5 -c model_reasoning_effort=medium|"medium"
CC-182|copilot|--model claude-opus-5 --reasoning-effort high|"high"
CC-183|pi|--model sonnet:high|"high"
CC-184|pi|--model sonnet --thinking medium|"medium"
CC-185|opencode|--model example/model|null
CC-186|claude|--model opus|null
ROWS
EFFORT_MUTANT="$(mutant_scripts effort-mutant open-terminal)" || exit 1
mutate_file "$EFFORT_MUTANT/open-terminal" 'model: $model, effort: $effort,' 'model: $model,'
run_ot SCRIPT="$EFFORT_MUTANT/open-terminal" --ghostty "${FLEET_CMD[@]}" CC-187
EFFORT_CONTROL="$(FAIL=0; assert_eq "rc=$RC effort=$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-187") | [has("effort"), .effort]' | jq -c .)" \
  'rc=0 effort=[true,"high"]' 'launch effort' > "$TMP_ROOT/effort-control"; printf '%s' "$FAIL")"
assert_eq "rc=$RC failures=$EFFORT_CONTROL" 'rc=0 failures=1' "control: removing effort from the record turns the launch effort assertion red"

PI_ITEM=140
# pi_carrier_at PACKAGES [VOCAB [MANIFEST]] — a pi-hooks carrier installed
# under PACKAGES on the host disk, with VOCAB as its extensions/vocab.ts and
# MANIFEST as its package.json, one naming no extensions by default.
pi_carrier_at() {
  local pkg="$HOSTED_DISK$1/@vanillagreen/pi-hooks" manifest='{"name":"@vanillagreen/pi-hooks"}'
  mkdir -p "$pkg/extensions"
  printf '%s\n' "${3:-$manifest}" > "$pkg/package.json"
  [[ -z "${2:-}" ]] || printf '%s\n' "$2" > "$pkg/extensions/vocab.ts"
}
# hosted_pi ROOT CARRIER USER PROJECT [ENV]... — one hosted Pi fleet launch of
# the next item over those host files, answering its outcome in PI_OUTCOME.
hosted_pi() {
  local root="$1" carrier="$2" user="$3" project="$4" line
  shift 4
  PI_ITEM=$((PI_ITEM + 1))
  rm -rf -- "${HOSTED_DISK:?}/pi" "${HOSTED_DISK:?}/home" "${HOSTED_DISK:?}/srv/lane/.pi"
  local pi_dir=/home/.pi/agent
  [[ "$root" == - ]] || pi_dir="$root"
  local user_file="$HOSTED_DISK$pi_dir/settings.json"
  if [[ "$user" != - ]]; then mkdir -p "${user_file%/*}"; printf '%s\n' "$user" > "$user_file"; fi
  if [[ "$project" != - ]]; then mkdir -p "$HOSTED_DISK/srv/lane/.pi"; printf '%s\n' "$project" > "$HOSTED_DISK/srv/lane/.pi/settings.json"; fi
  case "$carrier" in
    sends) pi_carrier_at "$pi_dir/packages" 'export const f = { context_window: 1 };' "$PI_WAKE_MANIFEST" ;;
    nowake) pi_carrier_at "$pi_dir/packages" 'export const f = { context_window: 1 };' '{"version":"0.12.0","pi":{"extensions":["./extensions/hooks.ts"]}}' ;;
    project-nowake) pi_carrier_at /srv/lane/.pi/packages 'export const f = { context_window: 1 };' '{"version":"0.12.0","pi":{"extensions":["./extensions/hooks.ts"]}}'
                    pi_carrier_at "$pi_dir/packages" 'export const f = { context_window: 1 };' "$PI_WAKE_MANIFEST" ;;
    old) pi_carrier_at "$pi_dir/packages" 'export const f = { session_id: 1 };' "$PI_WAKE_MANIFEST" ;;
    shadowed) pi_carrier_at /srv/lane/.pi/packages
              pi_carrier_at "$pi_dir/packages" 'export const f = { context_window: 1 };' "$PI_WAKE_MANIFEST" ;;
    none) ;;
  esac
  line=$'ssh-target=lane.example\tpath=/srv/lane\tremote-prefix=exec bash -lc'
  [[ "$root" == - ]] || line+=$'\tpi-root='"$root"
  HAND_OFF_HARNESS=pi HAND_OFF_CMD="true --model sonnet:high" hand_off "CC-$PI_ITEM" \
    PI_CODING_AGENT_DIR="$PI_LOCAL" LANE_HOST_STUB_CREATE_LINE="$line" "$@"
  line="$(grep -E '^open-terminal: (compaction-on|pi-settings-unreadable|pi-carrier-unreadable|unsupported-for-oversee|pi-mail-wake-missing) ' <<<"$ERR" || true)"
  PI_OUTCOME="rc=$RC ${line:-launched} windows=$(grep -c '^new-window ' "$TMUX_LOG" || true) marker=$(marker_at "cc-$PI_ITEM")"
}
VOCAB=/pi/packages/@vanillagreen/pi-hooks/extensions/vocab.ts
while IFS='|' read -r label root carrier user project env want; do
  read -r -a pi_env <<<"${env/#-/}"
  hosted_pi "$root" "$carrier" "$user" "$project" ${pi_env[@]+"${pi_env[@]}"}
  if [[ "$want" == launched ]]; then want="rc=0 launched windows=1 marker=root"; else want="rc=1 $want windows=0 marker=none"; fi
  assert_eq "$PI_OUTCOME" "$want" "$label"
done <<ROWS
compaction off under the Pi root create names launches|/pi|sends|$OFF|-|-|launched
compaction off under Pi's default root in the host home launches|-|sends|$OFF|-|-|launched
compaction on under the named root is refused, naming the host file|/pi|sends|$ON|-|-|open-terminal: compaction-on harness=pi file=/pi/settings.json
compaction on under the default root names its home-relative path|-|sends|$ON|-|-|open-terminal: compaction-on harness=pi file=.pi/agent/settings.json
a user file the host does not hold is Pi's default, compaction on|/pi|sends|-|-|-|open-terminal: compaction-on harness=pi file=/pi/settings.json
a project file turning compaction back on is refused, naming it|/pi|sends|$OFF|$ON|-|open-terminal: compaction-on harness=pi file=/srv/lane/.pi/settings.json
a settings file jq cannot parse is unreadable|/pi|sends|not json|-|-|open-terminal: pi-settings-unreadable file=/pi/settings.json
a settings read the host fails is unreadable|/pi|sends|$OFF|-|LANE_HOST_STUB_CAT_STATUS=1 LANE_HOST_STUB_CAT_PATH=/pi/settings.json|open-terminal: pi-settings-unreadable file=/pi/settings.json
a host carrier that sends no window is refused though this machine's sends one|/pi|old|$OFF|-|-|open-terminal: unsupported-for-oversee harness=pi reason=no-window-read
a host with no carrier installed is refused|/pi|none|$OFF|-|-|open-terminal: unsupported-for-oversee harness=pi reason=no-window-read
a tree carrier from before the field decides over the root's that sends|/pi|shadowed|$OFF|-|-|open-terminal: unsupported-for-oversee harness=pi reason=no-window-read
a stale host carrier that lists no lane mail wake is refused|/pi|nowake|$OFF|-|-|open-terminal: pi-mail-wake-missing harness=pi version=0.12.0 root=/pi scope=global location=hosted update=kendex update-pi --scope global retry=--relaunch
a stale default host carrier names the host home-relative root|-|nowake|$OFF|-|-|open-terminal: pi-mail-wake-missing harness=pi version=0.12.0 root=.pi/agent scope=global location=hosted update=kendex update-pi --scope global retry=--relaunch
a stale project carrier names the host project instead of the current global install|/pi|project-nowake|$OFF|-|-|open-terminal: pi-mail-wake-missing harness=pi version=0.12.0 root=/srv/lane/.pi scope=project location=hosted update=kendex update-pi --scope project retry=--relaunch
a carrier read the host fails is unreadable|/pi|sends|$OFF|-|LANE_HOST_STUB_CAT_STATUS=1 LANE_HOST_STUB_CAT_PATH=$VOCAB|open-terminal: pi-carrier-unreadable file=$VOCAB
ROWS
# Each refusal replaced by a pass, in a copy of the launcher.
busy_mutant pi-on '    0) ot_message compaction-on "harness=pi" "file=${remote[i]}" >&2; return 1 ;;' '    0) ;;'
hosted_pi /pi sends "$ON" - -- SCRIPT="$BUSY_MUTANT_OT"
assert_eq "$PI_OUTCOME" "rc=0 launched windows=1 marker=root" \
  "control: without its refusal a hosted Pi lane its host would compact launches"
busy_mutant pi-unread '      *) ot_message "$3" "file=$1" >&2; cat -- "$dir/err" >&2; return 2 ;;' '      *) return 1 ;;'
hosted_pi /pi sends "$OFF" - LANE_HOST_STUB_CAT_STATUS=1 LANE_HOST_STUB_CAT_PATH=/srv/lane/.pi/settings.json -- SCRIPT="$BUSY_MUTANT_OT"
assert_eq "$PI_OUTCOME" "rc=0 launched windows=1 marker=root" \
  "control: without its refusal a project file the host failed to read counts as none"
busy_mutant pi-window '    || { ot_message unsupported-for-oversee "harness=pi" "reason=no-window-read" >&2; return 1; }' '    || :'
hosted_pi /pi old "$OFF" - -- SCRIPT="$BUSY_MUTANT_OT"
assert_eq "$PI_OUTCOME" "rc=0 launched windows=1 marker=root" \
  "control: without its refusal a hosted Pi lane whose host carrier sends no window launches"
busy_mutant pi-wake '  if [[ "$1" -ne 0 ]]; then' '  if [[ "$1" -ne 0 ]] && false; then'
hosted_pi /pi nowake "$OFF" - -- SCRIPT="$BUSY_MUTANT_OT"
assert_eq "$PI_OUTCOME" "rc=0 launched windows=1 marker=root" \
  "control: without the mail wake refusal a stale hosted Pi carrier launches"
busy_mutant pi-recovery-root '"${packages[i]}" "${packages[0]}" hosted' '"${packages[0]}" "${packages[0]}" hosted'
hosted_pi /pi nowake "$OFF" - -- SCRIPT="$BUSY_MUTANT_OT"
assert_eq "$PI_OUTCOME" \
  "rc=1 open-terminal: pi-mail-wake-missing harness=pi version=0.12.0 root=/srv/lane/.pi scope=project location=hosted update=kendex update-pi --scope project retry=--relaunch windows=0 marker=none" \
  "control: losing the download-to-host mapping repairs the wrong carrier"
busy_mutant pi-recovery-retry '    [[ "$5" != hosted ]] || retry=--relaunch' '    [[ "$5" != hosted ]] || retry=launch'
hosted_pi /pi nowake "$OFF" - -- SCRIPT="$BUSY_MUTANT_OT"
assert_eq "$PI_OUTCOME" \
  "rc=1 open-terminal: pi-mail-wake-missing harness=pi version=0.12.0 root=/pi scope=global location=hosted update=kendex update-pi --scope global retry=launch windows=0 marker=none" \
  "control: losing the relaunch flag breaks recovery of the item create already owns"

echo "=== automatic recovery retains the original launch choices ==="
RECOVERY_FLAGS="--model opus --effort high --permission-mode dontAsk"
run_ot --ghostty --harness claude --lane "$LANE_DIR" --launch-flags "$RECOVERY_FLAGS" --lane-refresh CC-191
RECOVERY_EXPECTED="$(jq -cn --arg cwd "$REPO" --arg flags "$RECOVERY_FLAGS" '{cwd:$cwd,flags:$flags,session:"",refresh:true}')"
assert_eq "$RC $("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-191") | .recovery' | jq -c .)" \
  "0 $RECOVERY_EXPECTED" "a restricted refresh launch records every choice automatic recovery needs"
RECOVERY_OT="$(mutant_scripts recovery-unrecorded/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/recovery-unrecorded/orch"
mutate_file "$RECOVERY_OT" 'flags: $recovery_flags' 'flags: ""'
run_ot SCRIPT="$RECOVERY_OT" --ghostty --harness claude --lane "$LANE_DIR" --launch-flags "$RECOVERY_FLAGS" --lane-refresh CC-192
assert_eq "$RC $("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-192") | .recovery.flags')" \
  '0 ' "control: without the original flag record automatic recovery loses its permission choice"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
