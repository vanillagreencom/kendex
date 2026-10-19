#!/usr/bin/env bash
# Surface: open-terminal fleet file-overlap admission. Inputs: open-terminal
# and lib/ (launch-overlap.sh, lane-state.sh), resolve-base-branch,
# workflow-state, git-context, orch-env and
# tests/lib/{assertions,growth-state,shared-skill-libs,open-terminal-stubs,question-off}.sh.
# Fleet consumers parse the refusal header; launch and worktree stubs prove
# admission without starting a harness. An optional argument is main's script
# for the must-fail control: main launches the overlap row.
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
# The tracker answers the safe shape the blocker gate and the overlap judge
# read: no blocker, and the description in FIXTURE/ID.md.
cat > "$REPO/linear/scripts/linear.sh" <<'TRACKER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 ${4:-}" == 'issues get --format=safe' && -r "$FIXTURE/$3.md" ]] || exit 1
jq -cn --arg id "$3" --rawfile body "$FIXTURE/$3.md" '{id:$id, parent_id:"", blocked_by_launch:[], description:$body}'
TRACKER
chmod +x "$REPO/linear/scripts/linear.sh"
orch_fixture_shared_libs "$REPO/orch"
ot_stub_bin "$TMP_ROOT/bin"
# gh: the checkout's repository, FIXTURE/prs.json as the open list (none
# without it, a failure under FIXTURE/pr-list-fail) and FIXTURE/pr-N.txt as
# pull request N's files.
cat > "$TMP_ROOT/bin/gh" <<'STUBEOF'
#!/usr/bin/env bash
case "$1 $2" in
  'repo view') echo o/r ;;
  'pr list') [[ ! -e "$FIXTURE/pr-list-fail" ]] || exit 1; cat "$FIXTURE/prs.json" 2>/dev/null || echo '[]' ;;
  'pr diff') cat "$FIXTURE/pr-$3.txt" ;;
  *) exit 1 ;;
esac
STUBEOF
# The base names old.sh in doc.md; pull request 7's head adds notes.md naming it.
git init -q --bare "$TMP_ROOT/origin.git"
git init -q -b main "$REPO"
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
printf 'run old.sh\n' > "$REPO/doc.md"
git -C "$REPO" add doc.md
git -C "$REPO" commit -qm base
git -C "$REPO" remote add origin "$TMP_ROOT/origin.git"
git -C "$REPO" push -q origin main
printf 'old.sh moved\n' > "$REPO/notes.md"
git -C "$REPO" add notes.md
git -C "$REPO" commit -qm pr
git -C "$REPO" push -q origin HEAD:refs/pull/7/head
git -C "$REPO" reset -q --hard origin/main
git -C "$REPO" fetch -q origin

# run_row NAME BODY LANE_TOUCHED PRS [IN_SCOPE] [SCRIPT]: CC-1's body, CC-2
# running with LANE_TOUCHED as its record's touched (`legacy` records none and
# CC-2.md names src/a.sh), PRS as `number:head:file,...` entries.
run_row() {
  local name="$1" body="$2" touched="$3" prs="$4" scope="${5:-}" script="${6:-$OT}" args=() rc=0 creates=0 key=none entry
  FIXTURE="$TMP_ROOT/$name"
  mkdir -p "$FIXTURE"
  printf '%b\n' "$body" > "$FIXTURE/CC-1.md"
  printf '**Location**: `src/a.sh`\n' > "$FIXTURE/CC-2.md"
  printf '[]' > "$FIXTURE/prs.json"
  if [[ "$prs" == fail ]]; then touch "$FIXTURE/pr-list-fail"; prs=""; fi
  for entry in $prs; do
    IFS=: read -r number head files <<<"$entry"
    jq -c --argjson n "$number" --arg head "$head" '. + [{number: $n, headRefName: $head}]' "$FIXTURE/prs.json" > "$FIXTURE/prs.next"
    mv "$FIXTURE/prs.next" "$FIXTURE/prs.json"
    tr ',' '\n' <<<"$files" > "$FIXTURE/pr-$number.txt"
  done
  "$WS" --state-dir "$FIXTURE/state" init oversee >/dev/null
  "$WS" --state-dir "$FIXTURE/state" update oversee --arg cwd "$REPO" --arg touched "$touched" '
    .overseer={cwd:$cwd}
    | .lanes=[{item:"CC-2", tracker:"linear", status:"running", host:"local", harness:"claude"}
        + (if $touched == "legacy" then {} else {touched: ($touched | split(",") | map(select(. != "")))} end)]' >/dev/null
  [[ -z "$scope" ]] || args=(--in-scope "$scope")
  (cd "$REPO" && env LINEAR_TEAM= ORCH_LANE_PREFERENCE= ORCH_LANE_HOST=local \
    ORCH_OVERSEER_LANES=1000 ORCH_LANE_DIRS= ORCH_LANE_ALIASES= WORKTREE_DEFAULT_BRANCH=main \
    PATH="$TMP_ROOT/bin:$PATH" WORKTREE_CLI="$TMP_ROOT/bin/worktree" \
    FIXTURE="$FIXTURE" OT_WT_LOG="$FIXTURE/worktree.log" OT_CAPTURE="$FIXTURE/launch" \
    OT_TMUX_LOG="$FIXTURE/tmux.log" OT_TMUX_SERVER_PID="$$" LANES_HOME="$TMP_ROOT/home" \
    OVERSEE_WATCH_STATE_DIR="$FIXTURE/claims" TMUX= TMUX_PANE= TERMINAL=ghostty \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' "$script" --state-dir "$FIXTURE/state" \
    --ghostty --harness claude --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" \
    ${args[@]+"${args[@]}"} CC-1) > "$FIXTURE/output" 2>&1 || rc=$?
  [[ ! -f "$FIXTURE/worktree.log" ]] || creates="$(grep -c '^create ' "$FIXTURE/worktree.log" || true)"
  key="$(sed -n 's/^open-terminal: \(launch-overlap[^ ]*\) item=CC-1 \(.*\)/\1 \2/p' "$FIXTURE/output" | sed 's/ fix=.*//')"
  RESULT="rc=$rc creates=$creates ${key:-none}"
}

# One admission contract: a lane or pull request holder, directory and moved
# paths, changelog.d/, the item's own branch, the in-scope flag, a legacy
# record and a failed read.
while IFS='|' read -r name body touched prs scope expected; do
  [[ "$scope" != - ]] || scope=""
  run_row "$name" "$body" "$touched" "$prs" "$scope"
  assert_eq "$RESULT" "$expected" "$name" "$FIXTURE/output"
  if [[ "$expected" == *' launch-overlap '* ]]; then
    assert_eq "$([[ -e "$FIXTURE/launch" ]] && echo yes || echo no)" no "$name starts no terminal"
  fi
done <<'ROWS'
lane|**Location**: `src/a.sh`|src/a.sh,x.md||-|rc=1 creates=0 launch-overlap file=src/a.sh holder=CC-2
lane-dir|* **Location**: `src/a.sh` (the gate)|src/||-|rc=1 creates=0 launch-overlap file=src/a.sh holder=CC-2
pr|**Location**: `src/a.sh`|x.md|7:cc-9:y.md,src/a.sh|-|rc=1 creates=0 launch-overlap file=src/a.sh holder=#7
own-pr|**Location**: `src/a.sh`|x.md|7:cc-1:src/a.sh|-|rc=0 creates=1 none
moved-base|**Location**: `new.sh`\nThis deletes `old.sh`.|doc.md||-|rc=1 creates=0 launch-overlap file=doc.md holder=CC-2
moved-pr|**Location**: `new.sh`\nRenames `old.sh`.|notes.md|7:cc-9:z.md|-|rc=1 creates=0 launch-overlap file=notes.md holder=CC-2
changelog|**Location**: `changelog.d/orch/`, `src/b.sh`|changelog.d/orch/x.md|7:cc-9:changelog.d/orch/y.md|-|rc=0 creates=1 none
legacy|**Location**: `src/a.sh`|legacy||-|rc=1 creates=0 launch-overlap file=src/a.sh holder=CC-2
unread|**Location**: `src/a.sh`|x.md|fail|-|rc=1 creates=0 launch-overlap-unread read=pr-list:o/r
no-location|No location line.|src/a.sh|fail|-|rc=0 creates=1 none
ROWS

run_row in-scope '**Location**: `src/a.sh`, `src/c.sh`' src/a.sh '' src/a.sh
assert_eq "$RESULT" 'rc=0 creates=1 none' 'in-scope file launches' "$FIXTURE/output"
assert_eq "$("$WS" --state-dir "$FIXTURE/state" get oversee '.lanes[] | select(.item == "CC-1") | [.touched, .in_scope] | tojson')" \
  '[["src/a.sh","src/c.sh"],["src/a.sh"]]' 'in-scope record keeps the touched set and the flag'

# Keep the call and its matched text. Bypassing it must admit the overlap row.
mutate_file "$OT" 'if ! launch_overlap_gate "$item" "$wt_id"; then' 'if false && ! launch_overlap_gate "$item" "$wt_id"; then'
run_row control '**Location**: `src/a.sh`' src/a.sh '' ''
assert_eq "$RESULT" 'rc=0 creates=1 none' 'must-fail control admits the overlap row'
if [[ -n "${1:-}" ]]; then
  cp -- "$1" "$OT"
  run_row main-control '**Location**: `src/a.sh`' src/a.sh '' ''
  assert_eq "$RESULT" 'rc=0 creates=1 none' 'main launches the overlap row'
fi
printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
