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
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
# shellcheck source=lib/process-table.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/process-table.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
SRC_OT="$SCRIPTS_DIR/open-terminal"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

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
# and fails with tmux's own line where STUB_LIST_PANES_FAIL is set.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/ghostty"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
# The resolver's `gh repo view` rung, answered only where a row arms it.
[[ "${1:-}" == repo && -n "${STUB_GH_REPO:-}" ]] || exit 1
printf '%s\n' "$STUB_GH_REPO"
EOF
printf '#!/usr/bin/env bash\ncase "${1:-}" in check) exit 0 ;; list) echo "[]" ;; esac\nexit 0\n' > "$BIN/lanes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"
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
  list-panes) [[ -z "${STUB_LIST_PANES_FAIL:-}" ]] || { echo 'no server running on /tmp/tmux-stub/default' >&2; exit 1; }; echo %1 ;;
  capture-pane) printf '%s\n' "${STUB_PANE_TEXT:-}" ;;
esac
exit 0
EOF
chmod +x "$BIN/ghostty" "$BIN/gh" "$BIN/lanes" "$BIN/claude" "$BIN/tmux"
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
  create) mkdir -p "\$d"; git init -q "\$d"; printf '%s\n' "\$d" ;;
  *) echo "unexpected worktree stub call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUB"
EXISTS_DIR="$TMP_ROOT/exists"
mkdir -p "$EXISTS_DIR"

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/scripts/lib"
cp "$SRC_OT" "$REPO/scripts/open-terminal"
cp "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" "$SCRIPTS_DIR/lane-marker" "$REPO/scripts/"
cp "$SCRIPTS_DIR/lib"/*.sh "$REPO/scripts/lib/"
orch_fixture_shared_libs "$REPO"
chmod +x "$REPO/scripts/open-terminal"
git -C "$REPO" init -q
OT="$REPO/scripts/open-terminal"
WS="$REPO/scripts/workflow-state"
STATE="$TMP_ROOT/state"
LANE_DIR="$TMP_ROOT/.eclaude"
mkdir -p "$LANE_DIR"

# Claude transcripts naming CC-1, for the relaunch and wake rows, and CC-40,
# for the wake of an item no record names.
SESSION_HOME="$TMP_ROOT/session-home"
CLAUDE222=22222222-2222-2222-2222-222222222222
CLAUDE444=44444444-4444-4444-4444-444444444444
mkdir -p "$SESSION_HOME/.claude-shared/projects/repo"
printf '%s\n' '{"type":"user","message":{"content":"start cc-1"}}' > "$SESSION_HOME/.claude-shared/projects/repo/$CLAUDE222.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"start cc-40"}}' > "$SESSION_HOME/.claude-shared/projects/repo/$CLAUDE444.jsonl"

# run_ot [SCRIPT=PATH] [STATE_DIR=PATH] [CWD=PATH] ARGS... — one launch; sets
# OUT (stdout), ERR and RC. STATE_DIR= is passed as --state-dir, the flag that
# names the fleet; an empty one passes no flag, so the launch names no fleet
# unless ARGS carry the flag themselves. CWD= is the directory the launch
# runs from.
run_ot() {
  local script="$OT" state_dir="$STATE" cwd="$PWD" state_args=()
  while [[ "${1:-}" == SCRIPT=* || "${1:-}" == STATE_DIR=* || "${1:-}" == CWD=* ]]; do
    case "$1" in SCRIPT=*) script="${1#SCRIPT=}" ;; STATE_DIR=*) state_dir="${1#STATE_DIR=}" ;; CWD=*) cwd="${1#CWD=}" ;; esac
    shift
  done
  [[ -z "$state_dir" ]] || state_args=(--state-dir "$state_dir")
  set +e
  OUT="$(cd "$cwd" && PATH="$BIN:$PROC_BIN:$PATH" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/claims" \
    WORKTREE_CLI="$STUB" LANES_CLI="$BIN/lanes" LANES_HOME="$SESSION_HOME" EXISTS_DIR="$EXISTS_DIR" \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' TMUX="${RUN_TMUX:-}" ORCH_TMUX_SESSION="${RUN_SESSION-stub}" TMUX_PANE="${RUN_PANE:-}" \
    STUB_SESSION_NAME="${STUB_SESSION_NAME:-}" STUB_TMUX_LOG="${STUB_TMUX_LOG:-}" STUB_DEAD_SESSIONS="${STUB_DEAD_SESSIONS:-}" STUB_PANE_GONE="${STUB_PANE_GONE:-}" STUB_HAS_SESSION_ERR="${STUB_HAS_SESSION_ERR:-}" GH_REPO="" STUB_GH_REPO="${STUB_GH_REPO:-}" \
    "$script" ${state_args[@]+"${state_args[@]}"} "$@" 2>"$TMP_ROOT/err")"
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/err")"
}

# record ITEM — the item's record as `field=value` words, null spelled null.
record() {
  "$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$1"'") | to_entries | map("\(.key)=\(.value // "null")") | join(" ")'
}
records() { "$WS" --state-dir "$STATE" get oversee '[.lanes[] | select(.item == "'"$1"'")] | length'; }
stamped() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && echo iso || echo "$1"; }
field() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$1"; }

echo "=== a launch appends one record under the item's workflow-state id ==="
run_ot --ghostty --harness claude --launch-flags "--model opus --verbose" CC-1
REC="$(record CC-1)"
assert_eq "rc=$RC records=$(records CC-1)" "rc=0 records=1" "a GUI launch writes one record and the state is created for it"
assert_eq "$(sed "s/ launched_at=[^ ]*//" <<<"$REC")" \
  "item=CC-1 tracker=linear repo=null harness=claude window=null account=null host=null mail_root=$TMP_ROOT/wt/CC-1 surface=gui model=opus session_id=null status=running" \
  "the record carries the item, no window off tmux, the worktree as mail_root, the flags' model and status running"
assert_eq "$(stamped "$(field "$REC" launched_at)")" "iso" "launched_at is a UTC timestamp"
LAUNCHED_AT="$(field "$REC" launched_at)"

# The choice words sit INSIDE the --cmd command, which is the command this
# launch runs: a template is rendered verbatim and no launch flag is appended to
# it, so the model recorded here is the model the harness was started with.
RUN_TMUX=stub,1,0 run_ot --tmux --harness claude --lane "$LANE_DIR" --cmd "true --model opus --effort high" CC-2
assert_eq "rc=$RC $(sed "s/ launched_at=[^ ]*//" <<<"$(record CC-2)")" \
  "rc=0 item=CC-2 tracker=linear repo=null harness=claude window=stub:CC-2 account=$LANE_DIR host=null mail_root=$TMP_ROOT/wt/CC-2 surface=tmux model=opus session_id=null status=running" \
  "a tmux launch under a lane records its window, its account dir, the tmux surface and the model its own command names"
RUN_TMUX=stub,1,0 run_ot --tmux --tracker github --repo o/r --cmd true 2709
assert_eq "rc=$RC $(record issue-2709 | sed -E 's/ (account|host|mail_root|surface|model|session_id|launched_at)=[^ ]*//g')" \
  "rc=0 item=issue-2709 tracker=github repo=o/r harness=null window=stub:gh-2709 status=running" \
  "a GitHub item is recorded under its workflow-state id with the window the watch reads it through"

# --repo is optional on a supported GitHub launch: the resolver answers and
# every launch command carries that answer, so the record carries it too. A
# record left null here is a lane whose close-out cannot read its item.
STUB_GH_REPO=o/resolved RUN_TMUX=stub,1,0 run_ot --tmux --tracker github --cmd true 2711
assert_eq "rc=$RC repo=$(field "$(record issue-2711)" repo)" "rc=0 repo=o/resolved" \
  "a GitHub launch with no --repo records the repository its resolver answered"

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
  local state="$TMP_ROOT/$1"
  : > "$TMUX_LOG"
  STUB_TMUX_LOG="$TMUX_LOG" RUN_TMUX=stub,1,0 run_ot STATE_DIR="$state" --tmux --cmd true "$2"
  printf 'rc=%s target=%s list=%s pane=%s window=%s recorded=%s refused=%s' "$RC" \
    "$(logged new-window)" "$(logged list-windows)" "$(logged session-read)" \
    "$("$WS" --state-dir "$state" get oversee "[.lanes[]? | select(.item == \"$2\") | .window] | first // \"none\"" 2>/dev/null || echo none)" \
    "$("$WS" --state-dir "$state" get oversee '.tmux.session // "none"' 2>/dev/null || echo none)" \
    "$(awk '/^open-terminal: (tmux-session-|session-record-failed|tmux-failed operation=has-session)/ { sub(/^open-terminal: /, ""); print; exit }' <<<"$ERR" | tr ' ' '+')"
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
  "rc=1 target= list= pane= window=none recorded=none refused=tmux-session-missing+item=CC-106+session=fleetz+source=ORCH_TMUX_SESSION" \
  "a first launch naming a session tmux does not hold refuses, naming it and its source, and records nothing"
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
  "rc=1 target= list= pane= window=none recorded=fleety refused=tmux-session-missing+item=CC-107+session=fleety+source=tmux.session" \
  "a recorded session the server lost refuses from a pane in another session, naming the record as the source"
NOFLEET_SESSION="$TMP_ROOT/nofleet-session"
mkdir -p "$NOFLEET_SESSION"
git -C "$NOFLEET_SESSION" init -q
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
"$WS" --state-dir "$TMP_ROOT/sess-broken" update oversee '.tmux = 42' >/dev/null
assert_eq "$(RUN_SESSION=fleetx session_row sess-broken CC-118)" \
  "rc=1 target= list= pane= window=none recorded=none refused=session-record-failed+item=CC-118+state=oversee" \
  "a fleet state whose tmux entry cannot be read refuses as session-record-failed and opens nothing"
# The write of a first launch's session: a state directory this launch can
# read and not lock takes the same refusal. Root writes through mode 555.
if [[ "$(id -u)" -eq 0 ]]; then
  printf '  skip  unwritable fleet state (running as root)\n'
else
  "$WS" --state-dir "$TMP_ROOT/sess-ro" init oversee >/dev/null
  chmod 555 "$TMP_ROOT/sess-ro"
  RUN_SESSION=fleetx session_row sess-ro CC-128 > "$TMP_ROOT/ro-row"
  chmod 755 "$TMP_ROOT/sess-ro"
  assert_eq "$(cat "$TMP_ROOT/ro-row")" \
    "rc=1 target= list= pane= window=none recorded=none refused=session-record-failed+item=CC-128+state=oversee" \
    "a fleet state whose tmux entry cannot be written refuses as session-record-failed and opens nothing"
fi
# A has-session that fails for another reason than an absent session, the
# answer a restarted server gives a launch still carrying its $TMUX.
assert_eq "$(RUN_SESSION=fleetx STUB_HAS_SESSION_ERR='no server running on /tmp/tmux-1000/default' session_row sess-noserver CC-127)" \
  "rc=1 target= list= pane= window=none recorded=none refused=tmux-failed+operation=has-session+item=CC-127+detail=no+server+running+on+/tmp/tmux-1000/default" \
  "a has-session that fails for another reason refuses as tmux-failed operation=has-session and opens nothing"

echo "=== the model is read from the command the launch runs, as the harness reads it ==="
# No --harness here, so no row judges these launches and the record is the only
# reader of the model: it names whatever the launch passes, in every spelling
# the table holds.
for row in "--model=sonnet|CC-10|sonnet" "-m haiku|CC-11|haiku" "|CC-12|null" "--verbose|CC-13|null"; do
  IFS='|' read -r words item want <<<"$row"
  run_ot --ghostty --cmd "true${words:+ $words}" "$item"
  assert_eq "rc=$RC model=$(field "$(record "$item")" model)" "rc=0 model=$want" "command words '$words' record model $want"
done

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
"$WS" --state-dir "$STATE" update oversee '(.lanes[] | select(.item == "CC-1")) |= (.status = "done" | .launched_at = "'"$LAUNCHED_AT"'")' >/dev/null
run_ot --relaunch --ghostty --harness claude --lane "$LANE_DIR" --launch-flags "--model opus --effort high" CC-1
assert_eq "rc=$RC records=$(records CC-1) $(record CC-1)" \
  "rc=0 records=1 item=CC-1 tracker=linear repo=null harness=claude window=null account=$LANE_DIR host=null mail_root=$TMP_ROOT/wt/CC-1 surface=gui model=opus session_id=$CLAUDE222 launched_at=$LAUNCHED_AT status=running" \
  "a relaunch keeps one record: the resumed session id and the new account land, launched_at stands, and a done lane runs again"

echo "=== a wake rewrites the session it resumed and nothing else ==="
"$WS" --state-dir "$STATE" update oversee '(.lanes[] | select(.item == "CC-1")) |= (.session_id = null | .status = "done")' >/dev/null
run_ot --wake --harness claude CC-1
assert_eq "rc=$RC woken=$(grep -c '^open-terminal: lane-woken item=CC-1 ' <<<"$OUT" || true) $(record CC-1)" \
  "rc=0 woken=1 item=CC-1 tracker=linear repo=null harness=claude window=null account=$LANE_DIR host=null mail_root=$TMP_ROOT/wt/CC-1 surface=gui model=opus session_id=$CLAUDE222 launched_at=$LAUNCHED_AT status=running" \
  "a wake sets the resumed session id and status running and leaves the launch's fields as they were"

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
  run_ot --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high" CC-60
assert_eq "rc=$RC $(sed "s/ launched_at=[^ ]*//" <<<"$(record CC-60)")" \
  "rc=0 item=CC-60 tracker=linear repo=o/r harness=claude window=stub:CC-60 account=$LANE_DIR host=$HOST_STUB mail_root=/srv/lane surface=tmux model=opus session_id=null status=running" \
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
  run_ot --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high" CC-63
assert_eq "rc=$RC marker=$(marker_at cc-63) records=$(records CC-63) summary=$(grep -c '^open-terminal: summary launched=1 ' <<<"$OUT" || true)" \
  "rc=0 marker=root records=1 summary=1" \
  "a hosted launch binds its lowercased item to the root the lane opens in, under the clone the provider's worktree names"

STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" LANE_HOST_STUB_PUT_STATUS=1 RUN_TMUX=stub,1,0 \
  run_ot --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high" CC-64
assert_eq "rc=$RC marker=$(marker_at cc-64) records=$(records CC-64) refused=$(grep -c '^open-terminal: marker-failed item=CC-64 path=/srv/clone/.git/lane-mail/cc-64$' <<<"$ERR" || true) summary=$(grep -c '^open-terminal: summary launched=0 ' <<<"$ERR" || true)" \
  "rc=1 marker=none records=0 refused=1 summary=1" \
  "a hosted launch whose marker write fails names the item and the marker path, records nothing and launches nothing"

# A relaunch onto a host whose create wrote no marker: the lane is recovered
# and marked, so a sandbox made before its provider wrote records is not deaf
# for the rest of its life.
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot --relaunch --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high" CC-65
assert_eq "rc=$RC marker=$(marker_at cc-65) relaunch=$(grep -c '^create --item CC-65 .*--relaunch $' "$TMP_ROOT/host.log" || true)" \
  "rc=0 marker=root relaunch=1" \
  "a hosted relaunch writes the marker its host never carried"

# The two reads ahead of the marker. A provider answers a file it does not
# have with a status and no line of its own, and the gitfile reader prints
# nothing either, so neither reaches the operator unless the launcher names it.
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" \
  LANE_HOST_STUB_CAT_STATUS=2 LANE_HOST_STUB_CAT_PATH=/srv/lane/.git RUN_TMUX=stub,1,0 \
  run_ot --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high" CC-68
assert_eq "rc=$RC first=$(grep -c '^open-terminal: host-gitfile-unread item=CC-68 path=/srv/lane/.git$' <<<"$ERR" || true) marker_failed=$(grep -c '^open-terminal: marker-failed ' <<<"$ERR" || true) records=$(records CC-68)" \
  "rc=1 first=1 marker_failed=0 records=0" \
  "a lane whose .git the host cannot produce names that read, not the marker write"

# A .git holding anything but a linked worktree's gitdir line: its own disk, so
# the rows above keep the one the launches read.
BENT_DISK="$TMP_ROOT/remote-bent"
mkdir -p "$BENT_DISK/srv/lane"
printf 'gitdir: worktrees/lane\n' > "$BENT_DISK/srv/lane/.git"
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$BENT_DISK" RUN_TMUX=stub,1,0 \
  run_ot --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high" CC-69
assert_eq "rc=$RC first=$(grep -c '^open-terminal: host-gitfile-invalid item=CC-69 path=/srv/lane/.git value=gitdir: worktrees/lane$' <<<"$ERR" || true) marker_failed=$(grep -c '^open-terminal: marker-failed ' <<<"$ERR" || true) records=$(records CC-69)" \
  "rc=1 first=1 marker_failed=0 records=0" \
  "a .git that names no linked worktree git directory names that read and the line it held"

# The read-back. A provider that accepts the whole transfer and lands other
# bytes reports no failure of its own, so the marker holds a root no session
# opens in and lane-mail-check reads that lane as none.
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" \
  LANE_HOST_STUB_PUT_BYTES=/srv/stale RUN_TMUX=stub,1,0 \
  run_ot --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high" CC-70
assert_eq "rc=$RC marker=$(marker_at cc-70) records=$(records CC-70) refused=$(grep -cx 'open-terminal: marker-failed item=CC-70 path=/srv/clone/.git/lane-mail/cc-70' <<<"$ERR" || true)" \
  "rc=1 marker=other records=0 refused=1" \
  "a marker that reads back holding another root fails the item and records nothing"

echo "=== --state-dir is the record's one address, wherever the launch runs from ==="
ELSEWHERE="$TMP_ROOT/elsewhere"
mkdir -p "$ELSEWHERE"
git -C "$ELSEWHERE" init -q
run_ot STATE_DIR= CWD="$ELSEWHERE" --ghostty --cmd true --state-dir "$TMP_ROOT/named" CC-50
assert_eq "rc=$RC named=$(jq -r '[.lanes[] | select(.item == "CC-50")] | length' "$TMP_ROOT/named/workflow-state-oversee.json" 2>/dev/null || echo none) launch_dir=$([[ -e "$ELSEWHERE/tmp/workflow-state-oversee.json" ]] && echo written || echo none)" \
  "rc=0 named=1 launch_dir=none" \
  "a launch run from another checkout records into the named state directory and not into that checkout's own"

echo "=== a record that cannot be written into a live state fails the item with its window standing ==="
# The oversee workflow has surface 2 hand-append lane records; a non-object entry
# (which the watch's own filter anticipates) makes the update-report filter
# index it and fail, the write path record-write-failed guards. The state is
# created by an ordinary launch first, then broken.
run_ot STATE_DIR="$TMP_ROOT/rwf-state" --ghostty --cmd true CC-80
"$WS" --state-dir "$TMP_ROOT/rwf-state" update oversee '.lanes += [42]' >/dev/null
run_ot STATE_DIR="$TMP_ROOT/rwf-state" --ghostty --cmd true CC-81
assert_eq "rc=$RC opened=$(grep -c '^open-terminal: terminal-opened item=CC-81 ' <<<"$OUT" || true) refused=$(grep -c '^open-terminal: record-write-failed item=CC-81 state=oversee$' <<<"$ERR" || true) summary=$(grep -o 'failed=[0-9]*' <<<"$ERR")" \
  "rc=1 opened=1 refused=1 summary=failed=1" \
  "a launch whose record write fails opens its window, is reported record-write-failed after the cause workflow-state names, and counts failed"

echo "=== launched_at is read before the window opens ==="
# The tmux stub notes when the window opened and then holds the open for two
# seconds, longer than the stamp's resolution: a stamp read before the open is
# not later than that moment, and one read after it is.
OPENED_AT="$TMP_ROOT/opened-at"
STUB_OPENED_AT="$OPENED_AT" STUB_OPEN_DELAY=2 RUN_TMUX=stub,1,0 run_ot --tmux --cmd true CC-95
assert_eq "rc=$RC order=$([[ "$(field "$(record CC-95)" launched_at)" > "$(cat "$OPENED_AT")" ]] && echo later || echo not-later)" "rc=0 order=not-later" \
  "the recorded launched_at is not later than the moment the window opened"

echo "=== a launch with no --state-dir names no fleet: no record, no state ==="
# The handoff workflow's launch-only commands pass no --state-dir; the launcher then
# writes nothing into the launch checkout's own oversee state, which is the
# file an overseer in that project reads.
NOFLEET="$TMP_ROOT/nofleet"
mkdir -p "$NOFLEET"
git -C "$NOFLEET" init -q
run_ot STATE_DIR= CWD="$NOFLEET" --ghostty --cmd true CC-90
assert_eq "rc=$RC opened=$(grep -c '^open-terminal: terminal-opened item=CC-90 ' <<<"$OUT" || true) launch_dir=$([[ -e "$NOFLEET/tmp/workflow-state-oversee.json" ]] && echo written || echo none)" \
  "rc=0 opened=1 launch_dir=none" \
  "a launch with no --state-dir opens its window and writes no record and no state anywhere"

echo "=== a refused item and a wake create no state where none exists ==="
# Both rows share one directory no earlier row wrote: the state is minted only
# past the item refusals, and a wake mints none, so a mistyped id or a wake
# pointed at the wrong address leaves no empty fleet for the watch to read.
EMPTY_STATE="$TMP_ROOT/empty-state"
run_ot STATE_DIR="$EMPTY_STATE" --ghostty --cmd true bad_id
assert_eq "rc=$RC refused=$(grep -c '^open-terminal: issue-invalid item=bad_id$' <<<"$ERR" || true) state=$([[ -e "$EMPTY_STATE/workflow-state-oversee.json" ]] && echo written || echo none)" \
  "rc=1 refused=1 state=none" \
  "an item id matching no pattern is refused, after the line git-context prints, before the state is created"
run_ot STATE_DIR="$EMPTY_STATE" --wake --harness claude CC-40
assert_eq "rc=$RC refused=$(grep -c "^open-terminal: state-absent item=CC-40 state=$EMPTY_STATE/workflow-state-oversee.json\$" <<<"$ERR" || true) woken=$(grep -c '^open-terminal: lane-woken ' <<<"$OUT" || true) state=$([[ -e "$EMPTY_STATE/workflow-state-oversee.json" ]] && echo written || echo none)" \
  "rc=1 refused=1 woken=0 state=none" \
  "a wake against an address holding no state names the file it looked for, wakes nothing and creates nothing"

echo "=== a state that cannot be created refuses the batch before any window opens ==="
: > "$TMP_ROOT/blocker"
run_ot STATE_DIR="$TMP_ROOT/blocker/state" --ghostty --cmd true CC-20 CC-21
assert_eq "rc=$RC opened=$(grep -c '^open-terminal: terminal-opened ' <<<"$OUT" || true) refused=$(grep -c '^open-terminal: state-unwritable state=oversee$' <<<"$ERR" || true) summary=$(grep -c '^open-terminal: summary ' <<<"$ERR$OUT" || true)" \
  "rc=1 opened=0 refused=1 summary=0" \
  "a state directory under a file refuses the whole batch as state-unwritable, with no window opened and no summary"

# fixture_copy NAME — a copy of the launcher beside its helpers under
# $TMP_ROOT/NAME, for a control and for the row that takes a helper away.
fixture_copy() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/scripts/lib"
  cp "$SRC_OT" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" "$SCRIPTS_DIR/lane-marker" "$dir/scripts/"
  cp "$SCRIPTS_DIR/lib"/*.sh "$dir/scripts/lib/"
  orch_fixture_shared_libs "$dir"
  git -C "$dir" init -q
}

echo "=== a launcher with no workflow-state beside it refuses before any window opens ==="
fixture_copy nohelper
rm "$TMP_ROOT/nohelper/scripts/workflow-state"
run_ot SCRIPT="$TMP_ROOT/nohelper/scripts/open-terminal" --ghostty --cmd true CC-70
assert_eq "rc=$RC first=$(sed -n 1p <<<"$ERR") opened=$(grep -c '^open-terminal: terminal-opened ' <<<"$OUT" || true)" \
  "rc=1 first=open-terminal: helper-missing path=$TMP_ROOT/nohelper/scripts/workflow-state opened=0" \
  "the missing helper is named first and no terminal opens"

echo "=== must-fail controls ==="
# The placement control: the creation block hoisted above the item loop and
# ungated, so a refused id and a wake both mint an empty state.
fixture_copy hoisted
python3 - "$TMP_ROOT/hoisted/scripts/open-terminal" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
block_start = s.index('  if [[ "$FLEET" == true && "$state_ready" != true ]]; then\n')
block_end = s.index('    state_ready=true\n  fi\n', block_start) + len('    state_ready=true\n  fi\n')
block = s[block_start:block_end]
s = s[:block_start] + s[block_end:]
hoisted = ('if ! "$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} exists oversee; then\n'
           '  "$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} init oversee >/dev/null || exit 1\n'
           'fi\n')
anchor = 'repo="$(resolve_repo)"\n'
assert s.count(anchor) == 1
s = s.replace(anchor, hoisted + anchor)
open(p, "w").write(s)
PY
assert_eq "$(grep -c 'state_ready' "$TMP_ROOT/hoisted/scripts/open-terminal")" "1" "control hoisted removed the gated block"
HOISTED_STATE="$TMP_ROOT/hoisted-state"
run_ot SCRIPT="$TMP_ROOT/hoisted/scripts/open-terminal" STATE_DIR="$HOISTED_STATE" --ghostty --cmd true bad_id
assert_eq "rc=$RC state=$([[ -e "$HOISTED_STATE/workflow-state-oversee.json" ]] && echo written || echo none)" "rc=1 state=written" \
  "control: hoisted and ungated, a refused id mints an empty state"
rm -f "$HOISTED_STATE/workflow-state-oversee.json"
run_ot SCRIPT="$TMP_ROOT/hoisted/scripts/open-terminal" STATE_DIR="$HOISTED_STATE" --wake --harness claude CC-40
assert_eq "rc=$RC state=$([[ -e "$HOISTED_STATE/workflow-state-oversee.json" ]] && echo written || echo none)" "rc=1 state=written" \
  "control: hoisted and ungated, a wake mints an empty state and then reads as record-missing"
# One defect per copy: the write call gone, the in-place match gone, the
# state address dropped, and each hosted field written as a local lane's.
mutant() { # NAME OLD NEW
  local dir="$TMP_ROOT/$1"
  fixture_copy "$1"
  assert_eq "$(grep -cF -- "$2" "$dir/scripts/open-terminal")" "1" "control $1 finds one line to mutate"
  python3 - "$dir/scripts/open-terminal" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new))
PY
  assert_eq "$(grep -cF -- "$2" "$dir/scripts/open-terminal")" "0" "control $1 applied its mutation"
}
mutant unwritten '    lane_record_write "$RECORD_MODE" "$wt_id" "$record_window" "$record_root" "$record_session" "$launched_at" || record_rc=$?' '    :'
run_ot SCRIPT="$TMP_ROOT/unwritten/scripts/open-terminal" STATE_DIR="$TMP_ROOT/unwritten-state" --ghostty --cmd true CC-30
assert_eq "rc=$RC records=$("$WS" --state-dir "$TMP_ROOT/unwritten-state" get oversee '(.lanes // []) | length')" "rc=0 records=0" \
  "control: without the write a launch leaves the created state with no record and reports success"
mutant appended 'if any($l[]; .item == $rec.item)' 'if false'
run_ot SCRIPT="$TMP_ROOT/appended/scripts/open-terminal" --relaunch --ghostty --harness claude CC-1
assert_eq "rc=$RC records=$(records CC-1)" "rc=0 records=2" \
  "control: without the in-place match a relaunch appends a second record for the item"
mutant unguarded '  elif [[ "$record_rc" -ne 0 ]]; then' '  elif false; then'
run_ot SCRIPT="$TMP_ROOT/unguarded/scripts/open-terminal" STATE_DIR="$TMP_ROOT/unguarded-state" --ghostty --cmd true CC-82
"$WS" --state-dir "$TMP_ROOT/unguarded-state" update oversee '.lanes += [42]' >/dev/null
run_ot SCRIPT="$TMP_ROOT/unguarded/scripts/open-terminal" STATE_DIR="$TMP_ROOT/unguarded-state" --ghostty --cmd true CC-83
assert_eq "rc=$RC refused=$(grep -c '^open-terminal: record-write-failed item=CC-83 ' <<<"$ERR" || true) summary=$(grep -o 'launched=[0-9]* skipped=[0-9]* failed=[0-9]*' <<<"$OUT$ERR")" \
  "rc=0 refused=0 summary=launched=1 skipped=0 failed=0" \
  "control: with the record-write-failed branch gone a failed write counts launched with no diagnostic"
mutant stateless '[[ -z "$STATE_DIR" ]] || { FLEET=true; WORKFLOW_STATE_ARGS=(--state-dir "$STATE_DIR"); }' '[[ -z "$STATE_DIR" ]] || FLEET=true'
run_ot SCRIPT="$TMP_ROOT/stateless/scripts/open-terminal" STATE_DIR= CWD="$ELSEWHERE" --ghostty --cmd true --state-dir "$TMP_ROOT/named-control" CC-51
assert_eq "rc=$RC named=$([[ -e "$TMP_ROOT/named-control/workflow-state-oversee.json" ]] && echo written || echo none) launch_dir=$([[ -e "$ELSEWHERE/tmp/workflow-state-oversee.json" ]] && echo written || echo none)" \
  "rc=0 named=none launch_dir=written" \
  "control: with --state-dir dropped the record lands in the launch directory's checkout and reports success"
mutant restamped '    lane_record_write "$RECORD_MODE" "$wt_id" "$record_window" "$record_root" "$record_session" "$launched_at" || record_rc=$?' '    lane_record_write "$RECORD_MODE" "$wt_id" "$record_window" "$record_root" "$record_session" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || record_rc=$?'
STUB_OPENED_AT="$OPENED_AT" STUB_OPEN_DELAY=2 RUN_TMUX=stub,1,0 run_ot SCRIPT="$TMP_ROOT/restamped/scripts/open-terminal" --tmux --cmd true CC-96
assert_eq "rc=$RC order=$([[ "$(field "$(record CC-96)" launched_at)" > "$(cat "$OPENED_AT")" ]] && echo later || echo not-later)" "rc=0 order=later" \
  "control: stamped after the open, launched_at is later than the moment the window opened"
mutant fleetless 'FLEET=false' 'FLEET=true'
NOFLEET_CONTROL="$TMP_ROOT/nofleet-control"
mkdir -p "$NOFLEET_CONTROL"
git -C "$NOFLEET_CONTROL" init -q
run_ot SCRIPT="$TMP_ROOT/fleetless/scripts/open-terminal" STATE_DIR= CWD="$NOFLEET_CONTROL" --ghostty --cmd true CC-91
assert_eq "rc=$RC launch_dir=$([[ -e "$NOFLEET_CONTROL/tmp/workflow-state-oversee.json" ]] && echo written || echo none)" "rc=0 launch_dir=written" \
  "control: with every launch a fleet launch a flagless handoff writes the launch checkout's oversee state"
mutant hostless '  [[ "$LANE_HOST" == local ]] || host="$LANE_HOST"' '  [[ "$LANE_HOST" == local ]] || host=""'
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot SCRIPT="$TMP_ROOT/hostless/scripts/open-terminal" --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high" CC-61
assert_eq "rc=$RC host=$(field "$(record CC-61)" host) mail_root=$(field "$(record CC-61)" mail_root)" "rc=0 host=null mail_root=/srv/lane" \
  "control: with the host assignment blanked a hosted lane records a null host and reports success"
mutant rootless '  [[ "$LANE_HOST" == local ]] || record_root="$remote_path"' '  [[ "$LANE_HOST" == local ]] || record_root="$wt"'
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot SCRIPT="$TMP_ROOT/rootless/scripts/open-terminal" CWD="$REPO" --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high" CC-62
assert_eq "rc=$RC host=$(field "$(record CC-62)" host) mail_root=$(field "$(record CC-62)" mail_root)" "rc=0 host=$HOST_STUB mail_root=$REPO" \
  "control: with the remote root dropped a hosted lane records the caller checkout as mail_root and reports success"
mutant hostblind '  if [[ "$WAKE" != true && -d "$wt" ]] && ! write_lane_marker' '  if [[ "$WAKE" != true && "$LANE_HOST" == local && -d "$wt" ]] && ! write_lane_marker'
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot SCRIPT="$TMP_ROOT/hostblind/scripts/open-terminal" --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high" CC-67
assert_eq "rc=$RC marker=$(marker_at cc-67) summary=$(grep -c '^open-terminal: summary launched=1 ' <<<"$OUT" || true)" "rc=0 marker=none summary=1" \
  "control: with the write site naming a local host again a hosted launch reports itself launched and leaves its lane unmarked"
mutant causeless '  LANE_MARKER_REASON=host-gitfile-unread' '  LANE_MARKER_REASON=marker-failed'
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" \
  LANE_HOST_STUB_CAT_STATUS=2 LANE_HOST_STUB_CAT_PATH=/srv/lane/.git RUN_TMUX=stub,1,0 \
  run_ot SCRIPT="$TMP_ROOT/causeless/scripts/open-terminal" --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high" CC-71
assert_eq "rc=$RC unread=$(grep -c '^open-terminal: host-gitfile-unread ' <<<"$ERR" || true) marker_failed=$(grep -c '^open-terminal: marker-failed item=CC-71 ' <<<"$ERR" || true)" \
  "rc=1 unread=0 marker_failed=1" \
  "control: with the read carrying the write's reason a .git the host cannot produce is reported as a failed marker write"
mutant unreadback '  [[ "$read_back" == "$2" ]]' '  [[ -n "$read_back" ]]'
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" \
  LANE_HOST_STUB_PUT_BYTES=/srv/stale RUN_TMUX=stub,1,0 \
  run_ot SCRIPT="$TMP_ROOT/unreadback/scripts/open-terminal" --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high" CC-72
assert_eq "rc=$RC marker=$(marker_at cc-72) records=$(records CC-72) summary=$(grep -c '^open-terminal: summary launched=1 ' <<<"$OUT" || true)" \
  "rc=0 marker=other records=1 summary=1" \
  "control: with the read-back asking only for bytes a marker holding another root is reported as launched"

mutant trackerless '--arg tracker "$TRACKER"' '--arg tracker ""'
run_ot SCRIPT="$TMP_ROOT/trackerless/scripts/open-terminal" --ghostty --cmd true CC-63
assert_eq "rc=$RC tracker=$(field "$(record CC-63)" tracker)" 'rc=0 tracker=null' \
  'control: with tracker output dropped a Linear launch reports success with no tracker identity'

mutant repoless '  [[ "$TRACKER" != github ]] || record_repo="$repo"' '  :'
STUB_GH_REPO=o/resolved run_ot SCRIPT="$TMP_ROOT/repoless/scripts/open-terminal" --ghostty --tracker github --cmd true 2710
assert_eq "rc=$RC repo=$(field "$(record issue-2710)" repo)" 'rc=0 repo=null' \
  'control: with the record back on the raw option a resolved GitHub launch is recorded with no repository'

mutant harnessless '--arg harness "$LAUNCH_HARNESS"' '--arg harness ""'
run_ot SCRIPT="$TMP_ROOT/harnessless/scripts/open-terminal" --ghostty --harness claude --cmd true CC-64
assert_eq "rc=$RC harness=$(field "$(record CC-64)" harness)" 'rc=0 harness=null' \
  'control: with harness output dropped a harness launch reports success with no close-out path'

# One defect per rule of the session resolution: the refusal gone, the
# existence check gone, the first launch's record gone, the target's session
# dropped, and the recorded session ranked above ORCH_TMUX_SESSION.
mutant unrefused '  [[ -n "$session" ]] || { ot_message tmux-session-unresolved "item=$1" "consulted=$consulted" "pane=$pane_read" >&2; return 1; }' '  :'
assert_eq "$(OT="$TMP_ROOT/unrefused/scripts/open-terminal" RUN_SESSION= session_row unrefused-state CC-110)" \
  "rc=1 target= list= pane= window=none recorded=none refused=tmux-failed+operation=has-session+item=CC-110+detail=no+mouse+target" \
  "control: without the refusal a launch from no pane with no session is reported as some other tmux failure"
mutant unchecked '  if ! err="$(tmux has-session -t "=$session" 2>&1)"; then' '  if false; then'
assert_eq "$(OT="$TMP_ROOT/unchecked/scripts/open-terminal" RUN_SESSION=fleetz STUB_DEAD_SESSIONS=fleetz session_row unchecked-state CC-116)" \
  "rc=0 target==fleetz:1 list==fleetz pane= window=fleetz:CC-116 recorded=fleetz refused=" \
  "control: without the existence check a mistyped session is launched into and recorded for every later launch"
mutant unrecorded "'.tmux.session //= \$s'" "'.'"
RUN_SESSION= RUN_PANE=%9 STUB_SESSION_NAME=fleety OT="$TMP_ROOT/unrecorded/scripts/open-terminal" session_row unrecorded-state CC-111 >/dev/null
assert_eq "$(OT="$TMP_ROOT/unrecorded/scripts/open-terminal" RUN_SESSION= session_row unrecorded-state CC-112)" \
  "rc=1 target= list= pane= window=none recorded=none refused=tmux-session-unresolved+item=CC-112+consulted=ORCH_TMUX_SESSION,tmux.session,TMUX_PANE+pane=unset" \
  "control: without the first launch's record a later launch from no pane has no session to open in"
mutant untargeted 'tmux new-window -a -t "=$LAUNCH_SESSION:$last_idx"' 'tmux new-window -a -t ":$last_idx"'
assert_eq "$(OT="$TMP_ROOT/untargeted/scripts/open-terminal" RUN_SESSION=fleetx session_row untargeted-state CC-113)" \
  "rc=0 target=:1 list==fleetx pane= window=fleetx:CC-113 recorded=fleetx refused=" \
  "control: with the session dropped from the target the window opens in the client's session while the record names another"
mutant outranked 'if [[ -z "$session" && -n "$recorded" ]]; then' 'if [[ -n "$recorded" ]]; then'
RUN_SESSION= RUN_PANE=%9 STUB_SESSION_NAME=fleety OT="$TMP_ROOT/outranked/scripts/open-terminal" session_row outranked-state CC-114 >/dev/null
assert_eq "$(OT="$TMP_ROOT/outranked/scripts/open-terminal" RUN_SESSION=fleetx session_row outranked-state CC-115)" \
  "rc=0 target==fleety:1 list==fleety pane= window=fleety:CC-115 recorded=fleety refused=" \
  "control: with the record ranked first ORCH_TMUX_SESSION no longer moves a fleet's windows"
mutant unlisted 'tmux list-windows -t "=$LAUNCH_SESSION" -F' 'tmux list-windows -F'
assert_eq "$(OT="$TMP_ROOT/unlisted/scripts/open-terminal" RUN_SESSION=fleetx session_row unlisted-state CC-119)" \
  "rc=0 target==fleetx:1 list=none pane= window=fleetx:CC-119 recorded=fleetx refused=" \
  "control: without the list-windows target the window index is read from the client's session"
mutant paneless 'tmux display-message -p -t "$TMUX_PANE" '"'"'#{session_name}'"'" 'tmux display-message -p '"'"'#{session_name}'"'"
assert_eq "$(OT="$TMP_ROOT/paneless/scripts/open-terminal" RUN_SESSION= RUN_PANE=%9 STUB_SESSION_NAME=own nofleet_row CC-120)" \
  "rc=0 target==client:1 pane=none" \
  "control: without the pane target the launch opens in the attached client's session"
mutant paneranked '  if [[ -z "$session" ]]; then' '  if [[ -z "$session" || "$FLEET" != true && -n "${TMUX_PANE:-}" ]]; then'
assert_eq "$(OT="$TMP_ROOT/paneranked/scripts/open-terminal" RUN_SESSION=fleetx RUN_PANE=%9 STUB_SESSION_NAME=other nofleet_row CC-121)" \
  "rc=0 target==other:1 pane=%9" \
  "control: with the pane ranked first a launch naming no fleet ignores ORCH_TMUX_SESSION"
mutant silentread '    ot_message session-record-failed "item=$title" "state=oversee" >&2' '    :'
session_row silentread-state CC-122 >/dev/null
"$WS" --state-dir "$TMP_ROOT/silentread-state" update oversee '.tmux = 42' >/dev/null
assert_eq "$(OT="$TMP_ROOT/silentread/scripts/open-terminal" RUN_SESSION=fleetx session_row silentread-state CC-123)" \
  "rc=1 target= list= pane= window=none recorded=none refused=" \
  "control: without the session-record-failed line an unreadable tmux entry fails the launch with no key"
mutant gonefailed '      pane_read=none' '      pane_read=read-failed'
assert_eq "$(OT="$TMP_ROOT/gonefailed/scripts/open-terminal" RUN_SESSION= RUN_PANE=%9 STUB_PANE_GONE=1 session_row gonefailed-state CC-126)" \
  "rc=1 target= list= pane=%9 window=none recorded=none refused=tmux-session-unresolved+item=CC-126+consulted=ORCH_TMUX_SESSION,tmux.session,TMUX_PANE+pane=read-failed" \
  "control: with the empty answer read as a failure a pane tmux does not hold is reported as a failed read with no tmux line above"
mutant silentcheck '      ot_message tmux-failed "operation=has-session" "item=$1" "detail=$err" >&2' '      :'
assert_eq "$(OT="$TMP_ROOT/silentcheck/scripts/open-terminal" RUN_SESSION=fleetx STUB_HAS_SESSION_ERR='no server running on /tmp/tmux-1000/default' session_row silentcheck-state CC-129)" \
  "rc=1 target= list= pane= window=none recorded=none refused=" \
  "control: without the has-session tmux-failed line a failed check refuses with no key"

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
  run_ot ${args[@]+"${args[@]}"} --tmux --harness "${HAND_OFF_HARNESS:-claude}" --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "${HAND_OFF_CMD:-true --model opus --effort high}" "$item"
  for kv in ${envs[@]+"${envs[@]}"}; do unset "${kv%%=*}"; done
  unset STUB_TMUX_LOG STUB_PANE_CMD STUB_PANE_TEXT LANE_HOST_STUB_LOG LANE_HOST_STUB_DIR LANE_HOST_STUB_CREATE_LINE RUN_TMUX
}

hand_off CC-73 LANE_HOST_STUB_WAIT_GATE="$TMP_ROOT/gate-73"
assert_eq "rc=$RC summary=$(grep -c '^open-terminal: summary launched=0 preparing=1 skipped=0 failed=0 ' <<<"$OUT" || true) handed=$(grep -c "^open-terminal: lane-preparing item=CC-73 log=$STATE/lane-prepare-CC-73.log$" <<<"$OUT" || true) record=$(prepared CC-73) pid=$("$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "CC-73") | .prepare.pid | type') window=$(grep -c '^new-window =stub:1$' "$TMUX_LOG" || true) claims=$(claims_for CC-73) marker=$(marker_at cc-73)" \
  "rc=0 summary=1 handed=1 record=preparing prepare none pid=number window=1 claims=1 marker=none" \
  "a launch whose host is still preparing returns at once with its window and claim open, the lane recorded preparing under its job's pid, and nothing launched on the host"
touch "$TMP_ROOT/gate-73"
assert_eq "record=$(settled CC-73) marker=$(marker_at cc-73) window=$(field "$(record CC-73)" window) root=$(field "$(record CC-73)" mail_root)" \
  "record=running prepare none marker=root window=stub:CC-73 root=/srv/lane" \
  "once the host is ready the job launches the lane in its window and records it running"
# A later launch that is not handed off drops the preparation it replaces, or
# the watch would read that stale record of a live lane.
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$HOSTED_DISK" RUN_TMUX=stub,1,0 \
  run_ot --relaunch --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd "true --model opus --effort high" CC-73
assert_eq "rc=$RC record=$(prepared CC-73)" "rc=0 record=running none none" \
  "a relaunch whose host answers at once drops the earlier preparation from the record"

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
run_ot STATE_DIR="$TMP_ROOT/pu-state" --ghostty --cmd true CC-80
"$WS" --state-dir "$TMP_ROOT/pu-state" update oversee '.lanes += [42]' >/dev/null
hand_off CC-78 -- STATE_DIR="$TMP_ROOT/pu-state"
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

# A hosted codex relaunch resumes with no continuation line; resume-lineless
# must reach the caller, so that relaunch waits in the foreground even in a fleet.
HAND_OFF_HARNESS=codex HAND_OFF_CMD="true --model gpt-5 -c model_reasoning_effort=high" hand_off CC-83 -- --relaunch
assert_eq "rc=$RC waited=$(grep -c '^wait --item CC-83 $' "$TMP_ROOT/host.log" || true) handed=$(grep -c '^open-terminal: lane-preparing ' <<<"$OUT" || true) lineless=$(grep -c '^open-terminal: resume-lineless item=CC-83 harness=codex$' <<<"$ERR" || true) record=$(prepared CC-83)" \
  "rc=0 waited=1 handed=0 lineless=1 record=running none none" \
  "a hosted codex relaunch waits for its host in the foreground and reports resume-lineless to the caller"

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

# The must-fail inverses. With the hand-off gone the launch waits for the host
# itself, returning only once a gate a background writer opens a second later
# has let the preparation finish, with the lane already running. With the job
# left in the caller's group, the group kill ends it and the lane never leaves
# preparing.
mutant waiting '  if [[ "$host_state" == preparing && "$FLEET" == true && "$RESUME_LINELESS" != true ]]; then' '  if false; then'
(sleep 1; touch "$TMP_ROOT/gate-76") &
hand_off CC-76 LANE_HOST_STUB_WAIT_GATE="$TMP_ROOT/gate-76" -- SCRIPT="$TMP_ROOT/waiting/scripts/open-terminal"
wait
assert_eq "rc=$RC record=$(prepared CC-76) marker=$(marker_at cc-76)" \
  "rc=0 record=running none none marker=root" \
  "control: without the hand-off the launch blocks until the host is prepared"
mutant grouped '  set -m' '  :'
assert_eq "record=$(group_killed "$TMP_ROOT/grouped/scripts/open-terminal" CC-85)" "record=preparing prepare none" \
  "control: a job left in the caller's process group dies with it and its lane stays preparing"
mutant swallowed "  panes=\"\$(tmux list-panes -a -F '#{pane_id}')\" || { ot_message tmux-failed \"operation=list-panes\" \"item=\$2\" >&2; return 1; }" "  panes=\"\$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)\" || return 0"
hand_off CC-90 LANE_HOST_STUB_WAIT_STATUS=1 STUB_LIST_PANES_FAIL=1 -- SCRIPT="$TMP_ROOT/swallowed/scripts/open-terminal"
assert_eq "logged=$(log_line "$STATE/lane-prepare-CC-90.log" 'open-terminal: lane-prepare-failed item=CC-90 reason=wait-failed') read=$(grep -c '^open-terminal: tmux-failed operation=list-panes ' "$STATE/lane-prepare-CC-90.log" || true)" \
  "logged=1 read=0" "control: a pane read failure taken as a closed window reports nothing"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
