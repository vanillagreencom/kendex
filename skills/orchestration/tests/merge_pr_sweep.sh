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

# Env isolation. The reviewer's spot check ran this file with
# FLIGHTDECK_MANAGED=1 / ORCH_STATE_DIR=other in the shell and observed
# scenario-specific failures (unknown-mode case no longer saw unknown;
# scope-json resolved against the wrong state dir and led to a SWEEP=
# unbound variable). Unsetting every relevant FLIGHTDECK_* /
# ORCH_STATE_DIR / FLIGHTDECK_STATE_DIR var at the top makes every
# subsequent assertion independent of the caller's environment.
unset FLIGHTDECK_MANAGED FLIGHTDECK_CHILD_PANE FLIGHTDECK_SESSION_ID \
      FLIGHTDECK_STATE_DIR ORCH_STATE_DIR

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

# --- Sandbox: a "main repo" with two registered worktrees, three extra
# stale local branches with no associated PR, and TWO orphan worktree
# directories on disk (no live `git worktree list` entry). PROJ-99 is
# the issue currently finalizing.
MAIN_REPO="$TMP_ROOT/main"
TREES_DIR="$TMP_ROOT/trees"
WORKTREE_99="$TREES_DIR/PROJ-99"
WORKTREE_88="$TREES_DIR/PROJ-88"
ORPHAN_DIR_A="$TREES_DIR/orphan-old-experiment"
ORPHAN_DIR_B="$TREES_DIR/orphan-leftover"
mkdir -p "$TREES_DIR"
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
# Two orphan worktree directories: filesystem-only, no `git worktree`
# linkage. These are exactly the entries merge-pr.md § 5b would surface
# via `ls [TREES_DIR]/ | ... grep -v "git worktree list ..."`.
mkdir -p "$ORPHAN_DIR_A" "$ORPHAN_DIR_B"

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
  (
    # Belt-and-braces env scrub inside the subshell so the function
    # behaves identically when called from a parent that had any
    # FLIGHTDECK_* / ORCH_STATE_DIR var set.
    unset FLIGHTDECK_MANAGED FLIGHTDECK_CHILD_PANE FLIGHTDECK_SESSION_ID \
          FLIGHTDECK_STATE_DIR ORCH_STATE_DIR
    cd "$cwd"
    if [[ -n "$managed" ]]; then export FLIGHTDECK_MANAGED="$managed"; fi
    SCOPE=$("$FD_MODE" --issue "$scoped_issue" scope-json)
    MODE=$(jq -r '.mode' <<<"$SCOPE")
    SCOPED_BRANCH=$(jq -r '.branch' <<<"$SCOPE")
    SWEEP=managed  # default to the safe path; case may override
    case "$MODE" in
      managed)   SWEEP=managed ;;
      unmanaged) SWEEP=standalone ;;
      unknown)
        # Fail closed: emit warning and stay managed.
        echo "WARN merge-pr: flightdeck-mode unknown" >&2
        SWEEP=managed
        ;;
      *)
        # Defensive: any other value (jq error, future addition) also
        # fails closed with a warning.
        echo "WARN merge-pr: flightdeck-mode returned unexpected mode='$MODE'" >&2
        SWEEP=managed
        ;;
    esac

    if [[ "$SWEEP" == "managed" ]]; then
      # Managed sweep: only validate + (would) delete scoped branch,
      # and do NOT enumerate orphan worktree directories. Emit a
      # structured trace the test can assert against.
      if "$FD_MODE" --issue "$scoped_issue" match-branch "$SCOPED_BRANCH" 2>/dev/null; then
        echo "DELETE-CANDIDATE: $SCOPED_BRANCH"
      else
        echo "SKIP-DELETE: $SCOPED_BRANCH (match-branch refused)"
      fi
      # NOTE: must NOT enumerate other branches or orphan dirs here.
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

      # Orphan worktree enumeration (merge-pr.md § 5b second block):
      # any directory under [TREES_DIR] that is NOT in `git worktree
      # list --porcelain` surfaces as `"Stale worktree for X. Remove?"`.
      live_wts=$(git -C "$MAIN_REPO" worktree list --porcelain 2>/dev/null \
                 | awk '/^worktree /{print $2}')
      for d in "$TREES_DIR"/*; do
        [[ -d "$d" ]] || continue
        if ! grep -qxF "$d" <<<"$live_wts"; then
          base=$(basename "$d")
          echo "PROMPT: Stale worktree for $base (PR already merged). Remove?"
        fi
      done
    fi
  )
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

# Orphan worktree suppression in managed mode: the two orphan dirs we
# put on disk MUST NOT appear in the output (this is the
# stale-orphan-worktree scope-violation that prompted issue #18's
# defensive prompt tag).
for orphan in orphan-old-experiment orphan-leftover; do
  if grep -q "Stale worktree for $orphan" <<<"$out"; then
    FAIL=$((FAIL+1)); printf '  FAIL  managed mode prompted about orphan worktree %s\n        out: %s\n' "$orphan" "$out"
  else
    PASS=$((PASS+1)); printf '  ok    managed mode does NOT prompt about orphan worktree %s\n' "$orphan"
  fi
done

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

# Orphan worktree dirs MUST appear as prompts in standalone mode — this
# is the maintenance behavior we want to preserve outside Flightdeck.
for orphan in orphan-old-experiment orphan-leftover; do
  if grep -qE "Stale worktree for $orphan" <<<"$out"; then
    PASS=$((PASS+1)); printf '  ok    standalone mode prompts about orphan worktree %s\n' "$orphan"
  else
    FAIL=$((FAIL+1)); printf '  FAIL  standalone mode missing orphan prompt for %s\n        out: %s\n' "$orphan" "$out"
  fi
done
# The live worktrees (PROJ-99, PROJ-88) must NOT show up as orphan
# prompts — they're tracked by `git worktree list`.
for live in PROJ-99 PROJ-88; do
  if grep -q "Stale worktree for $live" <<<"$out"; then
    FAIL=$((FAIL+1)); printf '  FAIL  standalone mode misreported live worktree %s as orphan\n' "$live"
  else
    PASS=$((PASS+1)); printf '  ok    standalone mode does NOT report live worktree %s as orphan\n' "$live"
  fi
done

echo "=== merge-pr § 5 -- unknown mode (no env signal) fails closed ==="
stderr_file="$TMP_ROOT/sweep.err"
out=$(sweep "$MAIN_REPO" "" PROJ-99 2>"$stderr_file")
assert_eq "$out" "DELETE-CANDIDATE: PROJ-99" "unknown mode fails closed: only scoped branch (no broad sweep)"
# And no orphan prompts under unknown either.
if grep -q 'Stale worktree for' <<<"$out"; then
  FAIL=$((FAIL+1)); printf '  FAIL  unknown mode leaked orphan prompts:\n%s\n' "$out"
else
  PASS=$((PASS+1)); printf '  ok    unknown mode does NOT enumerate orphan worktrees\n'
fi
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
