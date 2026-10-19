#!/usr/bin/env bash
# Surface: open-terminal fleet file-overlap admission. Inputs: open-terminal
# and lib/ (launch-overlap.sh, lane-state.sh, lane-claims.sh), resolve-base-branch,
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
# without it, a failure under FIXTURE/pr-list-fail) and FIXTURE/pr-N.json as
# pull request N's files endpoint pages. `pr diff` is not served: the hold
# reads no diff.
cat > "$TMP_ROOT/bin/gh" <<'STUBEOF'
#!/usr/bin/env bash
case "$1 $2" in
  'repo view') echo o/r ;;
  'pr list') [[ ! -e "$FIXTURE/pr-list-fail" ]] || exit 1; cat "$FIXTURE/prs.json" 2>/dev/null || echo '[]' ;;
  api\ repos/o/r/pulls/*/files\?per_page=100)
    [[ "$3 $4" == '--paginate --slurp' ]] || exit 1
    n="${2#repos/o/r/pulls/}"; cat "$FIXTURE/pr-${n%%/*}.json" ;;
  *) exit 1 ;;
esac
STUBEOF
# The base tracks old.sh, names it in doc.md and names the word run alone in
# tools.md; pull request 7's head, pushed from another clone so this
# checkout must fetch it, adds notes.md naming old.sh.
git init -q --bare "$TMP_ROOT/origin.git"
git init -q -b main "$REPO"
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
printf 'run old.sh\n' > "$REPO/doc.md"
printf 'echo\n' > "$REPO/old.sh"
printf 'run tests\n' > "$REPO/tools.md"
git -C "$REPO" add doc.md old.sh tools.md
git -C "$REPO" commit -qm base
git -C "$REPO" remote add origin "$TMP_ROOT/origin.git"
git -C "$REPO" push -q origin main
git clone -q "$TMP_ROOT/origin.git" "$TMP_ROOT/pr-clone"
printf 'old.sh moved\n' > "$TMP_ROOT/pr-clone/notes.md"
git -C "$TMP_ROOT/pr-clone" add notes.md
git -C "$TMP_ROOT/pr-clone" -c user.email=t@t -c user.name=t commit -qm pr
git -C "$TMP_ROOT/pr-clone" push -q origin HEAD:refs/pull/7/head
git -C "$REPO" fetch -q origin
! git -C "$REPO" cat-file -e "$(git -C "$TMP_ROOT/origin.git" rev-parse refs/pull/7/head)" 2>/dev/null \
  || { echo 'open-terminal-overlap: fixture=pr-head-local' >&2; exit 1; }

# run_row NAME BODY STATUS LANE_REPO LANE_TOUCHED PRS [IN_SCOPE] [SCRIPT]:
# CC-1's body, CC-2 at STATUS with LANE_REPO as its record's repo (`-` none)
# and LANE_TOUCHED as its touched (`legacy` records none and CC-2.md names
# src/a.sh), PRS as `number:head:files[:fork|own]` entries, a file `new<old`
# being a rename; fork is another owner's head, own a title naming CC-1.
run_row() {
  local name="$1" body="$2" status="$3" lane_repo="$4" touched="$5" prs="$6" scope="${7:-}" script="${8:-$OT}"
  local args=() rc=0 creates=0 key=none entry number head files flag oid
  FIXTURE="$TMP_ROOT/$name"
  mkdir -p "$FIXTURE"
  printf '%b\n' "$body" > "$FIXTURE/CC-1.md"
  printf '**Location**: `src/a.sh`\n' > "$FIXTURE/CC-2.md"
  printf '[]' > "$FIXTURE/prs.json"
  if [[ "$prs" == fail ]]; then touch "$FIXTURE/pr-list-fail"; prs=""; fi
  for entry in $prs; do
    IFS=: read -r number head files flag <<<"$entry"
    oid="$(git -C "$TMP_ROOT/origin.git" rev-parse -q --verify "refs/pull/$number/head" || echo 0000000000000000000000000000000000000000)"
    tr ',' '\n' <<<"$files" | jq -Rsc '[split("\n")[] | select(. != "") | split("<")
      | {filename: .[0]} + (if length > 1 then {previous_filename: .[1]} else {} end)] | [.]' > "$FIXTURE/pr-$number.json"
    jq -c --argjson n "$number" --arg head "$head" --arg flag "${flag:-}" --arg oid "$oid" --slurpfile pages "$FIXTURE/pr-$number.json" '
      . + [{number: $n, headRefName: $head, headRefOid: $oid, changedFiles: ($pages[0][0] | length),
        isCrossRepository: ($flag == "fork"), headRepositoryOwner: {login: (if $flag == "fork" then "x" else "o" end)},
        title: (if $flag == "own" then "feat(CC-1): change" else "feat(CC-9): change" end), body: ""}]' \
      "$FIXTURE/prs.json" > "$FIXTURE/prs.next"
    mv "$FIXTURE/prs.next" "$FIXTURE/prs.json"
  done
  "$WS" --state-dir "$FIXTURE/state" init oversee >/dev/null
  "$WS" --state-dir "$FIXTURE/state" update oversee --arg cwd "$REPO" --arg touched "$touched" --arg status "$status" --arg repo "$lane_repo" '
    .overseer={cwd:$cwd}
    | .lanes=[{item:"CC-2", tracker:"linear", status:$status, host:"local", harness:"claude"}
        + (if $repo == "-" then {} else {repo: $repo} end)
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

# One admission contract: a lane or pull request holder, its status and
# repository, directory, line-suffixed and moved paths, changelog.d/, the
# item's own and a fork's pull request, the in-scope flag, a legacy record
# and failed reads.
while IFS='|' read -r name body status lane_repo touched prs scope expected; do
  [[ "$scope" != - ]] || scope=""
  run_row "$name" "$body" "$status" "$lane_repo" "$touched" "$prs" "$scope"
  assert_eq "$RESULT" "$expected" "$name" "$FIXTURE/output"
  if [[ "$expected" == *' launch-overlap'* ]]; then
    assert_eq "$([[ -e "$FIXTURE/launch" ]] && echo yes || echo no)" no "$name starts no terminal"
  fi
done <<'ROWS'
lane|**Location**: `src/a.sh`|running|-|src/a.sh,x.md||-|rc=1 creates=0 launch-overlap file=src/a.sh holder=CC-2
lane-done|**Location**: `src/a.sh`|done|-|src/a.sh||-|rc=0 creates=1 none
lane-named-repo|**Location**: `src/a.sh`|parked|O/R|src/a.sh||-|rc=1 creates=0 launch-overlap file=src/a.sh holder=CC-2
lane-other-repo|**Location**: `src/a.sh`|running|o/other|src/a.sh||-|rc=0 creates=1 none
lane-dir|* **Location**: `src/a.sh` (the gate)|running|-|src/||-|rc=1 creates=0 launch-overlap file=src/a.sh holder=CC-2
line-suffix|**Location**: `src/a.sh:19-24`|running|-|src/a.sh||-|rc=1 creates=0 launch-overlap file=src/a.sh holder=CC-2
location-unticked|**Location**: src/a.sh (the gate)|running|-|src/a.sh||-|rc=1 creates=0 launch-overlap-unread read=location
pr|**Location**: `src/a.sh`|running|-|x.md|7:cc-9:y.md,src/a.sh|-|rc=1 creates=0 launch-overlap file=src/a.sh holder=#7
pr-rename|**Location**: `src/a.sh`|running|-|x.md|7:cc-9:src/z.sh<src/a.sh|-|rc=1 creates=0 launch-overlap file=src/a.sh holder=#7
pr-fork|**Location**: `src/a.sh`|running|-|x.md|7:cc-9:src/a.sh:fork|-|rc=0 creates=1 none
own-pr|**Location**: `src/a.sh`|running|-|x.md|7:claude/x:src/a.sh:own|-|rc=0 creates=1 none
moved-base|**Location**: `new.sh`\nThis deletes `old.sh`.|running|-|doc.md||-|rc=1 creates=0 launch-overlap file=doc.md holder=CC-2
moved-symbol|**Location**: `new.sh`\nThis deletes `old.sh` and the `run` helper.|running|-|tools.md||-|rc=0 creates=1 none
moved-pr|**Location**: `new.sh`\nRenames `old.sh`.|running|-|notes.md|7:cc-9:z.md|-|rc=1 creates=0 launch-overlap file=notes.md holder=CC-2
changelog|**Location**: `changelog.d/orch/`, `src/b.sh`|running|-|changelog.d/orch/x.md|7:cc-9:changelog.d/orch/y.md|-|rc=0 creates=1 none
legacy|**Location**: `src/a.sh`|running|-|legacy||-|rc=1 creates=0 launch-overlap file=src/a.sh holder=CC-2
unread|**Location**: `src/a.sh`|running|-|x.md|fail|-|rc=1 creates=0 launch-overlap-unread read=pr-list:o/r
no-location|No location line.|running|-|src/a.sh|fail|-|rc=0 creates=1 none
in-scope-dir|**Location**: `src/a.sh`|running|-|src/a.sh||src/|rc=0 creates=1 none
in-scope-other-dir|**Location**: `src/a.sh`|running|-|src/a.sh||docs/|rc=1 creates=0 launch-overlap file=src/a.sh holder=CC-2
in-scope-partial|**Location**: `src/a.sh`, `src/c.sh`|running|-|src/a.sh,src/c.sh||src/a.sh|rc=1 creates=0 launch-overlap file=src/c.sh holder=CC-2
ROWS

run_row in-scope '**Location**: `src/a.sh`, `src/c.sh`' running - src/a.sh '' src/a.sh
assert_eq "$RESULT" 'rc=0 creates=1 none' 'in-scope file launches' "$FIXTURE/output"
assert_eq "$("$WS" --state-dir "$FIXTURE/state" get oversee '.lanes[] | select(.item == "CC-1") | [.touched, .in_scope] | tojson')" \
  '[["src/a.sh","src/c.sh"],["src/a.sh"]]' 'in-scope record keeps the touched set and the flag'

# Keep the call and its matched text. Bypassing it must admit the overlap row.
mutate_file "$OT" 'if ! launch_overlap_gate "$item" "$wt_id"; then' 'if false && ! launch_overlap_gate "$item" "$wt_id"; then'
run_row control '**Location**: `src/a.sh`' running - src/a.sh '' ''
assert_eq "$RESULT" 'rc=0 creates=1 none' 'must-fail control admits the overlap row'
if [[ -n "${1:-}" ]]; then
  cp -- "$1" "$OT"
  run_row main-control '**Location**: `src/a.sh`' running - src/a.sh '' ''
  assert_eq "$RESULT" 'rc=0 creates=1 none' 'main launches the overlap row'
fi
printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
