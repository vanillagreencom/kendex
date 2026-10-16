#!/usr/bin/env bash
# Surface: open-terminal fleet blocker admission. Inputs: open-terminal and
# lib/, workflow-state, git-context, orch-env, Linear's issue formatter and
# tests/lib/{assertions,growth-state,shared-skill-libs,open-terminal-stubs,question-off}.sh.
# Fleet consumers parse the refusal header; launch and worktree stubs prove
# admission without starting a harness. An optional argument is main's script
# for the same blocked-row control.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
source "$TEST_DIR/lib/shared-skill-libs.sh"
source "$TEST_DIR/lib/open-terminal-stubs.sh"
source "$TEST_DIR/lib/question-off.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'open-terminal-blockers: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-blockers: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'open-terminal-blockers: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
SCRIPTS="$(mutant_scripts repo/orch open-terminal)"
REPO="$TMP_ROOT/repo"
orch_fixture_shared_libs "$REPO/orch"
ot_stub_bin "$TMP_ROOT/bin"
git init -q "$REPO"
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
WS="$SCRIPTS/workflow-state"
OT="$SCRIPTS/open-terminal"
# Reuse the production formatter, including its terminal-blocker rule.
cp "$TEST_DIR/../../linear/scripts/lib/formatters.sh" "$REPO/linear/scripts/formatters.sh"
cat > "$REPO/linear/scripts/linear.sh" <<'TRACKER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2" == 'issues get' ]] || exit 2
printf '%s\n' "$3" >> "$FIXTURE/read.log"
[[ -r "$FIXTURE/$3.json" ]] || exit 1
source "$(dirname "${BASH_SOURCE[0]}")/formatters.sh"
raw="$(cat "$FIXTURE/$3.json")" || exit 1
format_issue_single "$raw"
TRACKER
chmod +x "$REPO/linear/scripts/linear.sh"

# fixture ID PARENT BLOCKER_STATE: Linear issues get supplies parent and
# relation nodes. Empty state means no relation; completed and canceled remain
# relation history in the real formatter, with no open blocker.
fixture() {
  jq -cn --arg id "$1" --arg parent "$2" --arg state "$3" '
    {issue:{identifier:$id, title:$id, state:{type:"started"},
      parent:(if $parent == "" then null else {identifier:$parent} end),
      inverseRelations:{nodes:(if $state == "" then [] else
        [{type:"blocks",issue:{identifier:"CC-9",state:{type:$state}}}] end)}}}
  ' > "$FIXTURE/$1.json"
}
run_row() { # NAME MODE LEAF_STATE PARENT_STATE RECORD [SCRIPT]
  local name="$1" mode="$2" record="$5" script="${6:-$OT}" args=() rc=0 creates=0 key=none reads=0
  FIXTURE="$TMP_ROOT/$name"
  mkdir -p "$FIXTURE"
  fixture CC-1 "${4:+CC-2}" "$3"
  [[ -z "$4" ]] || fixture CC-2 CC-3 "$4"
  fixture CC-3 '' ''
  [[ "$3" != unread ]] || rm -- "${FIXTURE:?}/CC-1.json"
  [[ "$4" != unread ]] || rm -- "${FIXTURE:?}/CC-2.json"
  "$WS" --state-dir "$FIXTURE/state" init oversee >/dev/null
  "$WS" --state-dir "$FIXTURE/state" update oversee --arg cwd "$REPO" '.overseer={cwd:$cwd}' >/dev/null
  if [[ "$record" == yes ]]; then
    "$WS" --state-dir "$FIXTURE/state" update oversee '.lanes=[{item:"CC-1",status:"stopped",host:"local",harness:"claude"}]' >/dev/null
  fi
  case "$mode" in
    fresh) args=(--launch-flags '--model opus --effort high') ;;
    cmd|relaunch) args=(--cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL"); [[ "$mode" != relaunch ]] || args+=(--relaunch) ;;
    wake) args=(--wake) ;;
  esac
  (cd "$REPO" && env LINEAR_TEAM= ORCH_LANE_PREFERENCE= ORCH_LANE_HOST=local \
    ORCH_OVERSEER_LANES=1000 ORCH_LANE_DIRS= ORCH_LANE_ALIASES= \
    PATH="$TMP_ROOT/bin:$PATH" WORKTREE_CLI="$TMP_ROOT/bin/worktree" \
    FIXTURE="$FIXTURE" OT_WT_LOG="$FIXTURE/worktree.log" OT_CAPTURE="$FIXTURE/launch" \
    OT_TMUX_LOG="$FIXTURE/tmux.log" OT_TMUX_SERVER_PID="$$" LANES_HOME="$TMP_ROOT/home" \
    OVERSEE_WATCH_STATE_DIR="$FIXTURE/claims" TMUX= TMUX_PANE= TERMINAL=ghostty \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' "$script" --state-dir "$FIXTURE/state" \
    --ghostty --harness claude "${args[@]}" CC-1) > "$FIXTURE/output" 2>&1 || rc=$?
  [[ ! -f "$FIXTURE/worktree.log" ]] || creates="$(grep -c '^create ' "$FIXTURE/worktree.log" || true)"
  [[ ! -f "$FIXTURE/read.log" ]] || reads="$(wc -l < "$FIXTURE/read.log" | tr -d ' ')"
  if grep -q '^open-terminal: launch-blocked ' "$FIXTURE/output"; then key=launch-blocked
  elif grep -q '^open-terminal: launch-blocked-unread ' "$FIXTURE/output"; then key=launch-blocked-unread; fi
  RESULT="rc=$rc creates=$creates key=$key reads=$reads"
}

# One admission contract: fresh and custom launch, ancestor traversal, tracker
# failures, satisfied relation history, and recorded recovery.
while IFS='|' read -r name mode leaf parent record expected; do
  run_row "$name" "$mode" "$leaf" "$parent" "$record"
  assert_eq "$RESULT" "$expected" "$name"
  if [[ "$expected" == *'key=launch-blocked '* ]]; then
    assert_eq "$(sed -n 's/^open-terminal: launch-blocked item=CC-1 blockers=\([^ ]*\) fix=.*CC-9.*/\1/p' "$FIXTURE/output")" CC-9 "$name blocker and repair ids"
    assert_eq "$([[ -e "$FIXTURE/launch" ]] && echo yes || echo no)" no "$name starts no terminal"
  fi
done <<'ROWS'
open|fresh|started||no|rc=1 creates=0 key=launch-blocked reads=1
custom-open|cmd|started||no|rc=1 creates=0 key=launch-blocked reads=1
ancestor-open|cmd||started|no|rc=1 creates=0 key=launch-blocked reads=3
completed|fresh|completed||no|rc=0 creates=1 key=none reads=1
canceled|cmd|canceled||no|rc=0 creates=1 key=none reads=1
clear|cmd|||no|rc=0 creates=1 key=none reads=1
unread|cmd|unread||no|rc=1 creates=0 key=launch-blocked-unread reads=1
ancestor-unread|cmd||unread|no|rc=1 creates=0 key=launch-blocked-unread reads=2
recorded-relaunch|relaunch|unread||yes|rc=0 creates=1 key=none reads=0
new-relaunch|relaunch|started||no|rc=1 creates=0 key=launch-blocked reads=1
ROWS
# A wake needs a saved session beyond this gate. Its lack of one does not
# change admission: the recorded lane must make no tracker read.
run_row recorded-wake wake unread '' yes
assert_eq "${RESULT#* key=}" 'none reads=0' 'recorded wake bypasses blocker read'

# Keep the call and its matched text. Bypassing it must admit the blocked row.
mutate_file "$OT" 'if ! launch_blockers_gate "$item"; then' 'if false && ! launch_blockers_gate "$item"; then'
run_row control cmd started '' no
assert_eq "$RESULT" 'rc=0 creates=1 key=none reads=0' 'must-fail control admits blocked item'
if [[ -n "${1:-}" ]]; then
  cp -- "$1" "$OT"
  run_row main-control cmd started '' no
  assert_eq "$RESULT" 'rc=0 creates=1 key=none reads=0' 'current main admits blocked item'
  cat "$FIXTURE/output"
fi
printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
