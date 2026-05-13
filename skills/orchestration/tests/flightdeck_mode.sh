#!/usr/bin/env bash
# Regression tests for orchestration/scripts/flightdeck-mode.
#
# Covers the helper's tri-state detection, scope resolution, --issue
# explicit-targeting flag, registry-based detection, and failure-mode
# behaviour. Companion workflow-level test lives in merge_pr_sweep.sh.

set -euo pipefail

# Env isolation: every test must behave identically regardless of any
# FLIGHTDECK_* / ORCH_STATE_DIR / FLIGHTDECK_STATE_DIR pollution in the
# caller's environment. The reviewer's spot check (running with
# FLIGHTDECK_MANAGED=1 or ORCH_STATE_DIR=other set in the shell) must
# not flip outcomes here. The `run` / `run_with` / `run_cwd` helpers
# below also use `env -u`, but the top-level unset is the belt that
# protects assertions like the corrupt-master-state probe that don't
# go through those helpers.
unset FLIGHTDECK_MANAGED FLIGHTDECK_CHILD_PANE FLIGHTDECK_SESSION_ID \
      FLIGHTDECK_STATE_DIR ORCH_STATE_DIR

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/skills/orchestration/scripts/flightdeck-mode"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_exit() {
  local code="$1" want="$2" name="$3"
  if [[ "$code" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected exit: %s\n        got exit:      %s\n' "$name" "$want" "$code"
  fi
}

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/tmp"
git -C "$(dirname "$REPO")" init -q "$(basename "$REPO")"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" checkout -q -b issue-99
git -C "$REPO" commit -q --allow-empty -m init

cat >"$REPO/tmp/workflow-state-PROJ-99.json" <<EOF
{
  "issue_id": "PROJ-99",
  "agent": "rust",
  "worktree": "$REPO",
  "branch": "issue-99",
  "team_name": "proj-99"
}
EOF

# A second workflow-state for a sibling issue at the same tmp/ dir so we
# can exercise the "newest wins" fallback vs the explicit --issue flag.
cat >"$REPO/tmp/workflow-state-PROJ-88.json" <<EOF
{
  "issue_id": "PROJ-88",
  "agent": "rust",
  "worktree": "$REPO",
  "branch": "issue-88",
  "team_name": "proj-88"
}
EOF
# Ensure PROJ-99 is newer than PROJ-88 so the fallback picks PROJ-99.
touch -d '2026-01-01' "$REPO/tmp/workflow-state-PROJ-88.json"
touch -d '2026-02-01' "$REPO/tmp/workflow-state-PROJ-99.json"

# Common runner: clean env, run from REPO.
run() {
  (
    cd "$REPO"
    env -u FLIGHTDECK_CHILD_PANE \
        -u FLIGHTDECK_MANAGED \
        -u FLIGHTDECK_STATE_DIR \
        -u ORCH_STATE_DIR \
        -u TMUX \
        "$SCRIPT" "$@"
  )
}

run_with() {
  local key="$1" val="$2"
  shift 2
  (
    cd "$REPO"
    env -u FLIGHTDECK_CHILD_PANE \
        -u FLIGHTDECK_MANAGED \
        -u FLIGHTDECK_STATE_DIR \
        -u ORCH_STATE_DIR \
        -u TMUX \
        "$key=$val" \
        "$SCRIPT" "$@"
  )
}

run_cwd() {
  # Like run() but from an arbitrary cwd; useful for cd-then-call.
  local cwd="$1"
  shift
  (
    cd "$cwd"
    env -u FLIGHTDECK_CHILD_PANE \
        -u FLIGHTDECK_MANAGED \
        -u FLIGHTDECK_STATE_DIR \
        -u ORCH_STATE_DIR \
        -u TMUX \
        "$SCRIPT" "$@"
  )
}

echo "=== flightdeck-mode tri-state detection ==="

mode=$(run mode); assert_eq "$mode" "unknown" "no signals -> mode=unknown"
mode=$(run_with FLIGHTDECK_MANAGED 1 mode); assert_eq "$mode" "managed" "FLIGHTDECK_MANAGED=1 -> managed"
mode=$(run_with FLIGHTDECK_MANAGED 0 mode); assert_eq "$mode" "unmanaged" "FLIGHTDECK_MANAGED=0 -> unmanaged"
mode=$(run_with FLIGHTDECK_CHILD_PANE 1 mode); assert_eq "$mode" "managed" "legacy FLIGHTDECK_CHILD_PANE=1 -> managed"

# check exits 0 on managed AND unknown (fail-closed), 1 only on unmanaged.
set +e; run check >/dev/null 2>&1; code=$?; set -e
assert_exit "$code" "0" "check fails closed on unknown (exit 0)"
set +e; run_with FLIGHTDECK_MANAGED 0 check >/dev/null 2>&1; code=$?; set -e
assert_exit "$code" "1" "check exits 1 only on explicit unmanaged"
set +e; run_with FLIGHTDECK_MANAGED 1 check >/dev/null 2>&1; code=$?; set -e
assert_exit "$code" "0" "check exits 0 on managed"

echo "=== flightdeck-mode --issue scope resolution ==="

# --issue forces the right state file (this is the issue #2 fix from the
# reviewer-arch finding). Run from REPO with no --issue; newest-wins
# picks PROJ-99. Then ask for PROJ-88 explicitly and confirm we get the
# OLDER (and otherwise hidden) record.
out=$(run current-issue); assert_eq "$out" "PROJ-99" "current-issue (no --issue) picks newest workflow-state"
out=$(run --issue PROJ-88 current-issue); assert_eq "$out" "PROJ-88" "--issue PROJ-88 picks PROJ-88 record"
out=$(run --issue PROJ-88 current-branch); assert_eq "$out" "issue-88" "--issue PROJ-88 resolves its own branch"

# The bug from finding #2: run from a directory OTHER than the worktree
# (simulating `cd [MAIN_REPO_ROOT]` in merge-pr.md). Without --issue the
# helper finds nothing useful; with --issue + walk-up it locates the
# state file under the worktree's main repo root.
MAIN_REPO="$TMP_ROOT/main-repo"
WORKTREE="$TMP_ROOT/main-repo-trees/issue-99"
mkdir -p "$(dirname "$WORKTREE")"
git -C "$(dirname "$MAIN_REPO")" init -q "$(basename "$MAIN_REPO")"
git -C "$MAIN_REPO" config user.email t@t
git -C "$MAIN_REPO" config user.name t
git -C "$MAIN_REPO" commit -q --allow-empty -m main-init
git -C "$MAIN_REPO" worktree add -b issue-99 "$WORKTREE" >/dev/null 2>&1
mkdir -p "$MAIN_REPO/tmp"
cat >"$MAIN_REPO/tmp/workflow-state-PROJ-99.json" <<EOF
{ "issue_id": "PROJ-99", "agent": "rust",
  "worktree": "$WORKTREE", "branch": "issue-99" }
EOF
cat >"$MAIN_REPO/tmp/workflow-state-PROJ-88.json" <<EOF
{ "issue_id": "PROJ-88", "agent": "rust",
  "worktree": "$WORKTREE", "branch": "issue-88" }
EOF

# From inside the WORKTREE, --issue PROJ-99 must locate the file under
# the main repo (this is the merge-pr.md cd order regression).
out=$(run_cwd "$WORKTREE" --issue PROJ-99 current-branch)
assert_eq "$out" "issue-99" "--issue locates state file in main repo when called from worktree"

# From inside the MAIN repo, same query must still find it.
out=$(run_cwd "$MAIN_REPO" --issue PROJ-99 current-branch)
assert_eq "$out" "issue-99" "--issue PROJ-99 from main repo cwd"

echo "=== flightdeck-mode registry-based detection ==="

# Master-state file lists this worktree -> managed even without env.
SESSION_FILE="$MAIN_REPO/tmp/flightdeck-state-FAKE-SESSION.json"
WORKTREE_ABS=$(cd "$WORKTREE" && pwd)
cat >"$SESSION_FILE" <<EOF
{
  "issues": {
    "PROJ-99": { "worktree": "$WORKTREE_ABS", "branch": "issue-99" }
  }
}
EOF

# Fake a tmux session so resolve_master_state_file can match the file.
# Stub tmux into a private bin dir.
STUB_BIN="$TMP_ROOT/stub-bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/tmux" <<'TMUXEOF'
#!/usr/bin/env bash
[[ "$1" == "display-message" && "$2" == "-p" && "$3" == "#S" ]] && { echo "FAKE-SESSION"; exit 0; }
exit 0
TMUXEOF
chmod +x "$STUB_BIN/tmux"

mode=$(cd "$WORKTREE" && env -u FLIGHTDECK_CHILD_PANE -u FLIGHTDECK_MANAGED \
       PATH="$STUB_BIN:$PATH" "$SCRIPT" mode)
assert_eq "$mode" "managed" "master-state lookup elevates unknown -> managed"

# Corrupt master-state must not crash; mode stays unknown (check fails closed).
echo "not json {" >"$SESSION_FILE"
mode=$(cd "$WORKTREE" && env -u FLIGHTDECK_CHILD_PANE -u FLIGHTDECK_MANAGED \
       PATH="$STUB_BIN:$PATH" "$SCRIPT" mode)
assert_eq "$mode" "unknown" "corrupt master-state stays unknown (fail-closed via check)"
rm -f "$SESSION_FILE"

# When jq is unavailable, helper must still emit `unknown`.
NO_JQ_BIN="$TMP_ROOT/no-jq-bin"
mkdir -p "$NO_JQ_BIN"
for tool in bash git find sed awk grep cat tr cut sort head tail uniq wc env tmux date dirname basename id readlink ls cp mv rm mkdir rmdir touch sh; do
  src=$(command -v "$tool" 2>/dev/null || true)
  [[ -n "$src" ]] && ln -sf "$src" "$NO_JQ_BIN/$tool"
done
mode=$(cd "$WORKTREE" && env -i HOME="$HOME" PATH="$NO_JQ_BIN" \
       "$SCRIPT" mode 2>/dev/null || echo "ERR")
assert_eq "$mode" "unknown" "mode without jq -> unknown (no crash)"

echo "=== flightdeck-mode match-* guards ==="

# match-branch with --issue refuses the exact branch name from the
# original incident even when called from MAIN_REPO (the cd-order
# scenario from reviewer finding #2).
set +e; run_cwd "$MAIN_REPO" --issue PROJ-99 match-branch issue-99 >/dev/null 2>&1; code=$?; set -e
assert_exit "$code" "0" "match-branch --issue PROJ-99 accepts scoped branch from main-repo cwd"
set +e; run_cwd "$MAIN_REPO" --issue PROJ-99 match-branch orch/method-20260427T141609 >/dev/null 2>&1; code=$?; set -e
assert_exit "$code" "1" "match-branch --issue PROJ-99 refuses incident branch (issue #18 scenario)"

# Empty target still rejected.
set +e; run match-branch '' >/dev/null 2>&1; code=$?; set -e
assert_exit "$code" "2" "match-branch with empty arg -> exit 2"

# match-worktree with --issue accepts the worktree the state file lists.
set +e; run_cwd "$MAIN_REPO" --issue PROJ-99 match-worktree "$WORKTREE" >/dev/null 2>&1; code=$?; set -e
assert_exit "$code" "0" "match-worktree --issue PROJ-99 accepts scoped worktree from main repo"
set +e; run_cwd "$MAIN_REPO" --issue PROJ-99 match-worktree "$MAIN_REPO" >/dev/null 2>&1; code=$?; set -e
assert_exit "$code" "1" "match-worktree refuses main repo when scoped to worktree"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
