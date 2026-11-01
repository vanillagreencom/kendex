#!/usr/bin/env bash
# Surface: open-terminal's fleet admission through the orch runtime. Inputs:
# open-terminal and lib/ (lane-state.sh, lane-claims.sh, open-terminal-text.sh),
# workflow-state, git-context, orch-env and tests/lib/{assertions,growth-state,
# shared-skill-libs,open-terminal-stubs,question-off}.sh. The judgement itself
# is the runtime's (tests/rust/admission.rs, ops/admission.rs); these rows pin
# what stays the launcher's: the request it asks with, the refusal header
# fleet consumers parse from each runtime answer, that a refusal opens no
# terminal and creates no worktree, and the record fields it writes from the
# answer. An optional argument is main's script for the must-fail control:
# main launches the overlap row.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
source "$TEST_DIR/lib/shared-skill-libs.sh"
source "$TEST_DIR/lib/open-terminal-stubs.sh"
source "$TEST_DIR/lib/question-off.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'open-terminal-overlap: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-overlap: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'open-terminal-overlap: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
SCRIPTS="$(mutant_scripts repo/orch open-terminal)"
REPO="$TMP_ROOT/repo"
OT="$SCRIPTS/open-terminal"
WS="$SCRIPTS/workflow-state"
mkdir -p "$REPO/linear/scripts"
# The tracker answers the blocker gate's safe shape: no blocker.
cat > "$REPO/linear/scripts/linear.sh" <<'TRACKER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 ${4:-}" == 'issues get --format=safe' ]] || exit 1
jq -cn --arg id "$3" '{id:$id, parent_id:"", blocked_by_launch:[], description:""}'
TRACKER
chmod +x "$REPO/linear/scripts/linear.sh"
orch_fixture_shared_libs "$REPO/orch"
ot_stub_bin "$TMP_ROOT/bin"
git init -q -b main "$REPO"
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m root
git -C "$REPO" remote add origin https://github.com/o/r.git
BRIEF="$TMP_ROOT/brief.md"
printf 'Change `src/a.sh`.\n' > "$BRIEF"

# run_row NAME REPLY EXIT [IN_SCOPE] [SCRIPT]: a launch of CC-1 under the
# fleet state, the runtime answering `admit` with REPLY (JSON) and EXIT.
run_row() {
  local name="$1" reply="$2" exit_code="$3" scope="${4:-}" script="${5:-$OT}"
  local args=() rc=0 creates=0 key=none
  FIXTURE="$TMP_ROOT/$name"
  mkdir -p "$FIXTURE"
  printf '%s\n' "$reply" > "$FIXTURE/admit.json"
  "$WS" --state-dir "$FIXTURE/state" init oversee >/dev/null
  "$WS" --state-dir "$FIXTURE/state" update oversee --arg cwd "$REPO" '
    .overseer={cwd:$cwd}
    | .lanes=[{item:"CC-2", tracker:"linear", status:"running", host:"local", harness:"claude", touched:["src/a.sh"]}]' >/dev/null
  [[ -z "$scope" ]] || args=(--in-scope "$scope")
  (cd "$REPO" && env LINEAR_TEAM= ORCH_LANE_PREFERENCE= ORCH_LANE_HOST=local \
    ORCH_OVERSEER_LANES=1000 ORCH_LANE_DIRS= ORCH_LANE_ALIASES= WORKTREE_DEFAULT_BRANCH=main \
    PATH="$TMP_ROOT/bin:$PATH" WORKTREE_CLI="$TMP_ROOT/bin/worktree" \
    OT_RUNTIME_ADMIT="$FIXTURE/admit.json" OT_RUNTIME_ADMIT_EXIT="$exit_code" OT_RUNTIME_LOG="$FIXTURE/requests" \
    FIXTURE="$FIXTURE" OT_WT_LOG="$FIXTURE/worktree.log" OT_CAPTURE="$FIXTURE/launch" \
    OT_TMUX_LOG="$FIXTURE/tmux.log" OT_TMUX_SERVER_PID="$$" LANES_HOME="$TMP_ROOT/home" \
    OVERSEE_WATCH_STATE_DIR="$FIXTURE/claims" TMUX= TMUX_PANE= TERMINAL=ghostty \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' "$script" --state-dir "$FIXTURE/state" \
    --ghostty --harness claude --brief-file "$BRIEF" --cmd "true --model opus {brief} $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" \
    ${args[@]+"${args[@]}"} CC-1) > "$FIXTURE/output" 2>&1 || rc=$?
  [[ ! -f "$FIXTURE/worktree.log" ]] || creates="$(grep -c '^create ' "$FIXTURE/worktree.log" || true)"
  key="$(sed -n 's/^open-terminal: \(launch-overlap[^ ]*\|item-ineligible\) item=CC-1 \(.*\)/\1 \2/p' "$FIXTURE/output" | sed 's/ fix=.*//')"
  RESULT="rc=$rc creates=$creates ${key:-none}"
}

ADMITTED='{"ok":true,"result":{"touched":["src/a.sh","src/c.sh"],"in_scope":[],"rebase":[{"holder":"CC-3","branch":"cc-3","paths":["src/c.sh"],"at":"2026-01-01T00:00:00Z"}],"recorded":false}}'

echo "=== the launcher asks the runtime with the item, its tracker, repository, brief and in-scope paths ==="
run_row request "$ADMITTED" 0 src/
assert_eq "$RESULT" 'rc=0 creates=1 none' 'an admitted judgement launches' "$FIXTURE/output"
# A Linear launch of the overseer's own repository names none, as its lane
# record names none: the runtime reads both as the fleet's own.
assert_eq "$(jq -c '{item, tracker, repo: (.repo // "none"), in_scope, brief_file: (.brief_file == $brief), repo_dir: (.repo_dir == $repo)}' --arg brief "$BRIEF" --arg repo "$REPO" "$FIXTURE/requests")" \
  '{"item":"CC-1","tracker":"linear","repo":"none","in_scope":["src/"],"brief_file":true,"repo_dir":true}' \
  'the request names the item, its tracker and repository, the brief, the checkout and the in-scope paths'
assert_eq "$("$WS" --state-dir "$FIXTURE/state" get oversee '.lanes[] | select(.item == "CC-1") | .repo // "none"')" none \
  'the record names the repository the request named'
assert_eq "$("$WS" --state-dir "$FIXTURE/state" get oversee '.lanes[] | select(.item == "CC-1") | [.touched, .in_scope, .rebase] | tojson')" \
  '[["src/a.sh","src/c.sh"],["src/"],[{"holder":"CC-3","branch":"cc-3","paths":["src/c.sh"],"at":"2026-01-01T00:00:00Z"}]]' \
  'the record carries the touched set the runtime minted, the in-scope paths and the rebase obligations'

echo "=== each refusal of the runtime is the launcher's own header, and launches nothing ==="
while IFS='|' read -r name reply expected; do
  run_row "$name" "$reply" 1
  assert_eq "$RESULT" "$expected" "$name" "$FIXTURE/output"
  assert_eq "$([[ -e "$FIXTURE/launch" ]] && echo yes || echo no)" no "$name starts no terminal"
  assert_eq "$("$WS" --state-dir "$FIXTURE/state" get oversee '[.lanes[] | .item] | tojson')" '["CC-2"]' "$name records no lane"
done <<'ROWS'
overlap|{"ok":false,"refusal":{"key":"launch-overlap","fields":[["item","CC-1"],["file","src/a.sh"],["holder","CC-2"]],"text":"held"}}|rc=1 creates=0 launch-overlap file=src/a.sh holder=CC-2
ineligible|{"ok":false,"refusal":{"key":"item-ineligible","fields":[["item","CC-1"],["cause","parent-with-children"]],"text":"container"}}|rc=1 creates=0 item-ineligible cause=parent-with-children
holder-unreadable|{"ok":false,"refusal":{"key":"holder-unreadable","fields":[["item","CC-1"],["holder","CC-2"],["read","identity"]],"text":"unread"}}|rc=1 creates=0 launch-overlap-unread read=holder:CC-2:identity
touched-unreadable|{"ok":false,"refusal":{"key":"touched-unreadable","fields":[["item","CC-1"],["read","location"]],"text":"unread"}}|rc=1 creates=0 launch-overlap-unread read=location
other-refusal|{"ok":false,"refusal":{"key":"cap-unreadable","fields":[["source","claims"]],"text":"unread"}}|rc=1 creates=0 launch-overlap-unread read=runtime:cap-unreadable
no-reply|orch-runtime: setup-required key=none|rc=1 creates=0 launch-overlap-unread read=runtime
ROWS

echo "=== a relaunch of a recorded lane is not judged again and keeps its record's sets ==="
FIXTURE="$TMP_ROOT/relaunch"
mkdir -p "$FIXTURE"
"$WS" --state-dir "$FIXTURE/state" init oversee >/dev/null
"$WS" --state-dir "$FIXTURE/state" update oversee --arg cwd "$REPO" '
  .overseer={cwd:$cwd}
  | .lanes=[{item:"CC-1", tracker:"linear", status:"stopped", host:"local", harness:"claude", mail_root:"/w/cc-1",
             touched:["src/a.sh"], in_scope:["src/"], rebase:[{holder:"CC-3", branch:"cc-3", paths:["src/a.sh"], at:"2026-01-01T00:00:00Z"}]}]' >/dev/null
rc=0
(cd "$REPO" && env LINEAR_TEAM= ORCH_LANE_PREFERENCE= ORCH_LANE_HOST=local \
  ORCH_OVERSEER_LANES=1000 ORCH_LANE_DIRS= ORCH_LANE_ALIASES= WORKTREE_DEFAULT_BRANCH=main \
  PATH="$TMP_ROOT/bin:$PATH" WORKTREE_CLI="$TMP_ROOT/bin/worktree" OT_RUNTIME_LOG="$FIXTURE/requests" \
  FIXTURE="$FIXTURE" OT_WT_LOG="$FIXTURE/worktree.log" OT_CAPTURE="$FIXTURE/launch" \
  OT_TMUX_LOG="$FIXTURE/tmux.log" OT_TMUX_SERVER_PID="$$" LANES_HOME="$TMP_ROOT/home" \
  OVERSEE_WATCH_STATE_DIR="$FIXTURE/claims" TMUX= TMUX_PANE= TERMINAL=ghostty \
  GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' "$OT" --state-dir "$FIXTURE/state" --relaunch \
  --ghostty --harness claude --cmd "true --model opus $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" CC-1) > "$FIXTURE/output" 2>&1 || rc=$?
assert_eq "$rc" 0 'the relaunch runs' "$FIXTURE/output"
assert_eq "$([[ -e "$FIXTURE/requests" ]] && echo asked || echo unasked)" unasked 'no admission is asked for a recorded lane'
assert_eq "$("$WS" --state-dir "$FIXTURE/state" get oversee '.lanes[] | select(.item == "CC-1") | [.touched, .in_scope, (.rebase | length)] | tojson')" \
  '[["src/a.sh"],["src/"],1]' 'the relaunch keeps the recorded sets'

# Keep the call and its matched text. Bypassing it must admit the overlap row.
mutate_file "$OT" 'if ! launch_overlap_gate "$item" "$wt_id"; then' 'if false && ! launch_overlap_gate "$item" "$wt_id"; then'
run_row control '{"ok":false,"refusal":{"key":"launch-overlap","fields":[["item","CC-1"],["file","src/a.sh"],["holder","CC-2"]],"text":"held"}}' 1
assert_eq "$RESULT" 'rc=0 creates=1 none' 'must-fail control admits the overlap row'
if [[ -n "${1:-}" ]]; then
  cp -- "$1" "$OT"
  run_row main-control '{"ok":false,"refusal":{"key":"launch-overlap","fields":[["item","CC-1"],["file","src/a.sh"],["holder","CC-2"]],"text":"held"}}' 1
  assert_eq "$RESULT" 'rc=0 creates=1 none' 'main launches the overlap row'
fi
printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
