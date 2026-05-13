#!/usr/bin/env bash
# Workflow-level regression test for merge-pr.md § 5 step 5.
#
# Drives the same shell expressions the workflow doc instructs the
# orchestration agent to run, against a sandbox repo + workflow-state +
# branch list. Confirms:
#
#   - In FLIGHTDECK_MANAGED=1 (managed) mode, unrelated stale branches
#     and unrelated orphan worktree directories are NOT prompted about
#     and the scoped branch IS the only thing touched.
#   - In FLIGHTDECK_MANAGED=0 (standalone) mode, unrelated branches ARE
#     surfaced for the user prompt path.
#   - In unknown mode (no signals), the workflow fails closed and
#     skips the broad sweep with a warning on stderr.
#
# This test does NOT invoke gh / git remotes; it injects a mock branch
# list and a mock "PR state for branch" lookup, then asserts the
# decision-set the workflow would emit.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
FD_MODE="$REPO_ROOT/skills/orchestration/scripts/flightdeck-mode"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0; FAIL=0
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then PASS=$((PASS+1)); printf '  ok    %s\n' "$name"
  else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# --- Sandbox: a "main repo" with two registered worktrees and three
# extra stale local branches that have no associated PR. PROJ-99 is the
# issue currently finalizing.
MAIN_REPO="$TMP_ROOT/main"
WORKTREE_99="$TMP_ROOT/trees/PROJ-99"
WORKTREE_88="$TMP_ROOT/trees/PROJ-88"
mkdir -p "$(dirname "$WORKTREE_99")"
git -C "$(dirname "$MAIN_REPO")" init -q "$(basename "$MAIN_REPO")"
git -C "$MAIN_REPO" config user.email t@t
git -C "$MAIN_REPO" config user.name t
git -C "$MAIN_REPO" commit -q --allow-empty -m main-init
git -C "$MAIN_REPO" branch -m main 2>/dev/null || true
git -C "$MAIN_REPO" worktree add -b PROJ-99 "$WORKTREE_99" >/dev/null 2>&1
git -C "$MAIN_REPO" worktree add -b PROJ-88 "$WORKTREE_88" >/dev/null 2>&1
# Three unrelated local branches with no PR — the incident scenario.
for stale in orch/method-20260427T141609 random-experiment dropped-spike; do
  git -C "$MAIN_REPO" branch "$stale" >/dev/null 2>&1
done

mkdir -p "$MAIN_REPO/tmp"
cat >"$MAIN_REPO/tmp/workflow-state-PROJ-99.json" <<EOF
{ "issue_id": "PROJ-99", "agent": "rust",
  "worktree": "$WORKTREE_99", "branch": "PROJ-99" }
EOF

# --- Workflow expression mirror.
#
# This is the literal sequence merge-pr.md § 5 step 5 tells the agent to
# run. It must produce the same outcome no matter where the cwd lands,
# precisely the regression from reviewer-arch finding #2.
sweep() {
  # Args: cwd, FLIGHTDECK_MANAGED value (empty for unset), scoped-issue.
  local cwd="$1" managed="$2" scoped_issue="$3"
  local warn=""
  (
    cd "$cwd"
    if [[ -n "$managed" ]]; then export FLIGHTDECK_MANAGED="$managed"; fi
    SCOPE=$("$FD_MODE" --issue "$scoped_issue" scope-json)
    MODE=$(jq -r '.mode' <<<"$SCOPE")
    SCOPED_BRANCH=$(jq -r '.branch' <<<"$SCOPE")
    case "$MODE" in
      managed)   SWEEP=managed ;;
      unmanaged) SWEEP=standalone ;;
      unknown)
        # Fail closed: emit warning and stay managed.
        echo "WARN merge-pr: flightdeck-mode unknown" >&2
        SWEEP=managed
        ;;
    esac

    if [[ "$SWEEP" == "managed" ]]; then
      # Managed sweep: only validate + (would) delete scoped branch.
      # Emit a structured trace the test can assert against.
      if "$FD_MODE" --issue "$scoped_issue" match-branch "$SCOPED_BRANCH" 2>/dev/null; then
        echo "DELETE-CANDIDATE: $SCOPED_BRANCH"
      else
        echo "SKIP-DELETE: $SCOPED_BRANCH (match-branch refused)"
      fi
      # NOTE: must NOT enumerate other branches here.
    else
      # Standalone sweep: enumerate every local branch and emit a
      # prompt directive per branch matching merge-pr.md § 5b.
      while IFS= read -r branch; do
        [[ -z "$branch" || "$branch" == "main" ]] && continue
        # mock "no PR" for the three stale branches and "merged" for
        # PROJ-88, "merged" for PROJ-99 (this finalize run).
        case "$branch" in
          orch/method-*|random-experiment|dropped-spike)
            echo "PROMPT: Local branch $branch has no associated PR. Delete?"
            ;;
          PROJ-99|PROJ-88)
            echo "AUTO-DELETE: $branch (PR merged)"
            ;;
        esac
      done < <(git -C "$MAIN_REPO" branch --format='%(refname:short)' 2>/dev/null)
    fi
  ) 2> >(warn=$(cat); printf '%s' "$warn" >&2) || true
}

echo "=== merge-pr § 5 -- managed mode (FLIGHTDECK_MANAGED=1) ==="
out=$(sweep "$MAIN_REPO" 1 PROJ-99 2>/dev/null)
assert_eq "$out" "DELETE-CANDIDATE: PROJ-99" "managed mode emits ONLY scoped branch deletion"

# The exact incident: confirm the unrelated branch name from the bug
# report does NOT appear anywhere in the output.
if grep -q 'orch/method-20260427T141609' <<<"$out"; then
  FAIL=$((FAIL+1)); printf '  FAIL  managed mode leaked unrelated branch into output:\n%s\n' "$out"
else
  PASS=$((PASS+1)); printf '  ok    managed mode does NOT mention orch/method-20260427T141609 (issue #18)\n'
fi

# Same in managed mode but cwd is the worktree (not main repo). Must
# still resolve scope and refuse unrelated branches.
out=$(sweep "$WORKTREE_99" 1 PROJ-99 2>/dev/null)
assert_eq "$out" "DELETE-CANDIDATE: PROJ-99" "managed mode from worktree cwd still scopes correctly"

echo "=== merge-pr § 5 -- standalone mode (FLIGHTDECK_MANAGED=0) ==="
out=$(sweep "$MAIN_REPO" 0 PROJ-99 2>/dev/null)
# Each stale branch must appear as a prompt.
for stale in orch/method-20260427T141609 random-experiment dropped-spike; do
  if grep -qE "PROMPT: Local branch $stale has no associated PR" <<<"$out"; then
    PASS=$((PASS+1)); printf '  ok    standalone mode prompts for stale branch %s\n' "$stale"
  else
    FAIL=$((FAIL+1)); printf '  FAIL  standalone mode missing prompt for %s\n        out: %s\n' "$stale" "$out"
  fi
done
# Merged PR branches are auto-deleted, not prompted.
if grep -qE 'AUTO-DELETE: PROJ-99 \(PR merged\)' <<<"$out"; then
  PASS=$((PASS+1)); printf '  ok    standalone mode auto-deletes scoped issue branch\n'
else
  FAIL=$((FAIL+1)); printf '  FAIL  standalone mode did not auto-delete PROJ-99\n        out: %s\n' "$out"
fi

echo "=== merge-pr § 5 -- unknown mode (no env signal) fails closed ==="
stderr_file="$TMP_ROOT/sweep.err"
out=$(sweep "$MAIN_REPO" "" PROJ-99 2>"$stderr_file")
assert_eq "$out" "DELETE-CANDIDATE: PROJ-99" "unknown mode fails closed: only scoped branch (no broad sweep)"
if grep -q 'flightdeck-mode unknown' "$stderr_file"; then
  PASS=$((PASS+1)); printf '  ok    unknown mode emits stderr warning\n'
else
  FAIL=$((FAIL+1)); printf '  FAIL  unknown mode did not warn on stderr\n        stderr: %s\n' "$(cat "$stderr_file")"
fi

echo "=== merge-pr § 5 -- cd-order regression (reviewer finding #2) ==="
# Specifically: capture scope from worktree, then run match-branch from
# main-repo cwd. Without --issue this would re-resolve to the wrong
# state file. With --issue it must succeed for the scoped branch and
# refuse the unrelated one.
scoped_issue=PROJ-99
scoped_branch=$(cd "$WORKTREE_99" && FLIGHTDECK_MANAGED=1 "$FD_MODE" --issue "$scoped_issue" current-branch)
assert_eq "$scoped_branch" "PROJ-99" "scope captured from worktree pre-cd"

set +e
(cd "$MAIN_REPO" && FLIGHTDECK_MANAGED=1 "$FD_MODE" --issue "$scoped_issue" match-branch "$scoped_branch") >/dev/null 2>&1
code=$?
set -e
assert_eq "$code" "0" "match-branch from main-repo cwd with --issue accepts scoped branch"

set +e
(cd "$MAIN_REPO" && FLIGHTDECK_MANAGED=1 "$FD_MODE" --issue "$scoped_issue" match-branch orch/method-20260427T141609) >/dev/null 2>&1
code=$?
set -e
assert_eq "$code" "1" "match-branch from main-repo cwd refuses incident branch"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
