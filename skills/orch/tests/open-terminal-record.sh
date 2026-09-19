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
# and STUB_PANE_TEXT so the pane reads as an ssh session at its prompt.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/ghostty"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
printf '#!/usr/bin/env bash\ncase "${1:-}" in check) exit 0 ;; list) echo "[]" ;; esac\nexit 0\n' > "$BIN/lanes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) echo 1 ;;
  new-window) [[ -z "${STUB_OPENED_AT:-}" ]] || { date -u +%Y-%m-%dT%H:%M:%SZ > "$STUB_OPENED_AT"; sleep "${STUB_OPEN_DELAY:-0}"; }; echo "$$ %1" ;;
  display-message) if [[ "$*" == *pane_current_command* ]]; then echo "${STUB_PANE_CMD:-0}"; else echo 0; fi ;;
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
cp "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" "$REPO/scripts/"
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
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' TMUX="${RUN_TMUX:-}" "$script" ${state_args[@]+"${state_args[@]}"} "$@" 2>"$TMP_ROOT/err")"
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
  "item=CC-1 window=null account=null host=null mail_root=$TMP_ROOT/wt/CC-1 surface=gui model=opus session_id=null status=running" \
  "the record carries the item, no window off tmux, the worktree as mail_root, the flags' model and status running"
assert_eq "$(stamped "$(field "$REC" launched_at)")" "iso" "launched_at is a UTC timestamp"
LAUNCHED_AT="$(field "$REC" launched_at)"

RUN_TMUX=stub,1,0 run_ot --tmux --harness claude --lane "$LANE_DIR" --cmd true CC-2
assert_eq "rc=$RC $(sed "s/ launched_at=[^ ]*//" <<<"$(record CC-2)")" \
  "rc=0 item=CC-2 window=CC-2 account=$LANE_DIR host=null mail_root=$TMP_ROOT/wt/CC-2 surface=tmux model=null session_id=null status=running" \
  "a tmux launch under a lane records its window, its account dir and the tmux surface"
RUN_TMUX=stub,1,0 run_ot --tmux --tracker github --repo o/r --cmd true 2709
assert_eq "rc=$RC $(record issue-2709 | sed -E 's/ (account|host|mail_root|surface|model|session_id|launched_at)=[^ ]*//g')" \
  "rc=0 item=issue-2709 window=gh-2709 status=running" \
  "a GitHub item is recorded under its workflow-state id with the window the watch reads it through"

echo "=== the model is read from the launch flags as the harness reads them ==="
for row in "--model=sonnet|CC-10|sonnet" "-m haiku|CC-11|haiku" "|CC-12|null" "--verbose|CC-13|null"; do
  IFS='|' read -r flags item want <<<"$row"
  if [[ -n "$flags" ]]; then run_ot --ghostty --cmd true --launch-flags "$flags" "$item"; else run_ot --ghostty --cmd true "$item"; fi
  assert_eq "rc=$RC model=$(field "$(record "$item")" model)" "rc=0 model=$want" "flags '$flags' record model $want"
done

echo "=== a relaunch rewrites the moved fields in place and keeps launched_at ==="
# launched_at is moved to a fixed past value first: a stamp of this second
# would separate a kept value from a rewritten one only by the runner's speed.
touch "$EXISTS_DIR/CC-1"
LAUNCHED_AT=2026-01-01T00:00:00Z
"$WS" --state-dir "$STATE" update oversee '(.lanes[] | select(.item == "CC-1")) |= (.status = "done" | .launched_at = "'"$LAUNCHED_AT"'")' >/dev/null
run_ot --relaunch --ghostty --harness claude --lane "$LANE_DIR" CC-1
assert_eq "rc=$RC records=$(records CC-1) $(record CC-1)" \
  "rc=0 records=1 item=CC-1 window=null account=$LANE_DIR host=null mail_root=$TMP_ROOT/wt/CC-1 surface=gui model=null session_id=$CLAUDE222 launched_at=$LAUNCHED_AT status=running" \
  "a relaunch keeps one record: the resumed session id and the new account land, launched_at stands, and a done lane runs again"

echo "=== a wake rewrites the session it resumed and nothing else ==="
"$WS" --state-dir "$STATE" update oversee '(.lanes[] | select(.item == "CC-1")) |= (.session_id = null | .status = "done")' >/dev/null
run_ot --wake --harness claude CC-1
assert_eq "rc=$RC woken=$(grep -c '^open-terminal: lane-woken item=CC-1 ' <<<"$OUT" || true) $(record CC-1)" \
  "rc=0 woken=1 item=CC-1 window=null account=$LANE_DIR host=null mail_root=$TMP_ROOT/wt/CC-1 surface=gui model=null session_id=$CLAUDE222 launched_at=$LAUNCHED_AT status=running" \
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
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" RUN_TMUX=stub,1,0 \
  run_ot --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd true CC-60
assert_eq "rc=$RC $(sed "s/ launched_at=[^ ]*//" <<<"$(record CC-60)")" \
  "rc=0 item=CC-60 window=CC-60 account=$LANE_DIR host=$HOST_STUB mail_root=/srv/lane surface=tmux model=null session_id=null status=running" \
  "a hosted record carries the host spec and the remote path create named, never the local tree"

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
  cp "$SRC_OT" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" "$dir/scripts/"
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
mutant unwritten '    lane_record_write "$record_mode" "$wt_id" "$record_window" "$record_root" "$record_session" "$launched_at" || record_rc=$?' '    :'
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
mutant restamped '    lane_record_write "$record_mode" "$wt_id" "$record_window" "$record_root" "$record_session" "$launched_at" || record_rc=$?' '    lane_record_write "$record_mode" "$wt_id" "$record_window" "$record_root" "$record_session" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || record_rc=$?'
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
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" RUN_TMUX=stub,1,0 \
  run_ot SCRIPT="$TMP_ROOT/hostless/scripts/open-terminal" --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd true CC-61
assert_eq "rc=$RC host=$(field "$(record CC-61)" host) mail_root=$(field "$(record CC-61)" mail_root)" "rc=0 host=null mail_root=/srv/lane" \
  "control: with the host assignment blanked a hosted lane records a null host and reports success"
mutant rootless '  [[ "$LANE_HOST" == local ]] || record_root="$remote_path"' '  [[ "$LANE_HOST" == local ]] || record_root="$wt"'
STUB_PANE_CMD=ssh STUB_PANE_TEXT='dev@lane:~$' LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" RUN_TMUX=stub,1,0 \
  run_ot SCRIPT="$TMP_ROOT/rootless/scripts/open-terminal" CWD="$REPO" --tmux --harness claude --lane "$LANE_DIR" --host "$HOST_STUB" --repo o/r --cmd true CC-62
assert_eq "rc=$RC host=$(field "$(record CC-62)" host) mail_root=$(field "$(record CC-62)" mail_root)" "rc=0 host=$HOST_STUB mail_root=$REPO" \
  "control: with the remote root dropped a hosted lane records the caller checkout as mail_root and reports success"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
