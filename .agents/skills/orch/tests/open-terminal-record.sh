#!/usr/bin/env bash
# open-terminal's lane record: the `lanes[]` entry every launch writes to the
# caller checkout's oversee workflow state, which `oversee-watch --state` reads
# the live fleet from. A launch appends one record under the item's
# workflow-state id; a relaunch rewrites the fields a relaunch can move and
# keeps launched_at; a wake rewrites the session it resumed; a record that
# cannot be written fails the item with the window standing.
#
# The suite runs a copy of open-terminal beside a copy of workflow-state in a
# temp git repo, with the worktree CLI, gh, the GUI terminal, tmux and the
# harness binaries stubbed, and an absolute ORCH_STATE_DIR so no record lands
# in a real checkout. One row per behaviour; shaped input (the model flag
# spellings) is one table.
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
# few reads a --cmd launch and a wake make.
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
  new-window) echo "$$ %1" ;;
  display-message) echo 0 ;;
  capture-pane) echo "" ;;
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

# A claude transcript naming CC-1, for the relaunch and wake rows.
SESSION_HOME="$TMP_ROOT/session-home"
CLAUDE222=22222222-2222-2222-2222-222222222222
mkdir -p "$SESSION_HOME/.claude-shared/projects/repo"
printf '%s\n' '{"type":"user","message":{"content":"start cc-1"}}' > "$SESSION_HOME/.claude-shared/projects/repo/$CLAUDE222.jsonl"

# run_ot [SCRIPT=PATH] [STATE_DIR=PATH] ARGS... — one launch; sets OUT (stdout),
# ERR and RC.
run_ot() {
  local script="$OT" state_dir="$STATE"
  while [[ "${1:-}" == SCRIPT=* || "${1:-}" == STATE_DIR=* ]]; do
    case "$1" in SCRIPT=*) script="${1#SCRIPT=}" ;; STATE_DIR=*) state_dir="${1#STATE_DIR=}" ;; esac
    shift
  done
  set +e
  OUT="$(PATH="$BIN:$PROC_BIN:$PATH" ORCH_STATE_DIR="$state_dir" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/claims" \
    WORKTREE_CLI="$STUB" LANES_CLI="$BIN/lanes" LANES_HOME="$SESSION_HOME" EXISTS_DIR="$EXISTS_DIR" \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' TMUX="${RUN_TMUX:-}" "$script" "$@" 2>"$TMP_ROOT/err")"
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
touch "$EXISTS_DIR/CC-1"
"$WS" --state-dir "$STATE" update oversee '(.lanes[] | select(.item == "CC-1") | .status) = "done"' >/dev/null
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

echo "=== a record that cannot be written fails the item with the window standing ==="
: > "$TMP_ROOT/blocker"
run_ot STATE_DIR="$TMP_ROOT/blocker/state" --ghostty --cmd true CC-20
assert_eq "rc=$RC opened=$(grep -c '^open-terminal: terminal-opened item=CC-20 ' <<<"$OUT" || true) refused=$(grep -c '^open-terminal: record-write-failed item=CC-20 state=oversee$' <<<"$ERR" || true) summary=$(grep -o 'failed=[0-9]*' <<<"$ERR")" \
  "rc=1 opened=1 refused=1 summary=failed=1" \
  "an unwritable state fails the item as record-write-failed after its window opened"

echo "=== must-fail controls ==="
# One defect per copy: the write call gone, and the in-place match gone.
mutant() { # NAME OLD NEW
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/scripts/lib"
  cp "$SRC_OT" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" "$dir/scripts/"
  cp "$SCRIPTS_DIR/lib"/*.sh "$dir/scripts/lib/"
  orch_fixture_shared_libs "$dir"
  git -C "$dir" init -q
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
mutant unwritten '  if ! lane_record_write "$record_mode" "$wt_id" "$record_window" "$record_root" "$record_session"; then' '  if false; then'
run_ot SCRIPT="$TMP_ROOT/unwritten/scripts/open-terminal" STATE_DIR="$TMP_ROOT/unwritten-state" --ghostty --cmd true CC-30
assert_eq "rc=$RC state=$([[ -e "$TMP_ROOT/unwritten-state/workflow-state-oversee.json" ]] && echo written || echo none)" "rc=0 state=none" \
  "control: without the write a launch leaves no record and reports success"
mutant appended 'if any($l[]; .item == $rec.item)' 'if false'
run_ot SCRIPT="$TMP_ROOT/appended/scripts/open-terminal" --relaunch --ghostty --harness claude CC-1
assert_eq "rc=$RC records=$(records CC-1)" "rc=0 records=2" \
  "control: without the in-place match a relaunch appends a second record for the item"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
