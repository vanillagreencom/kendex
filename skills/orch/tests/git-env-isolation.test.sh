#!/usr/bin/env bash
# The orch suites build git fixtures, and git's environment variables outrank
# `git -C <path>`. A suite that inherits GIT_DIR, GIT_COMMON_DIR, GIT_WORK_TREE
# or GIT_INDEX_FILE from its caller commits into the caller's repository and
# leaves its index carrying deletions of paths that never existed there, while
# still reporting a clean pass. lib/git-env.sh clears all four at load and
# every suite sources it.
#
# A real suite run with all four exported at a sandbox repository leaves
# that repository's log and index untouched. Neutralize lib/git-env.sh beside
# links to the rest and the same run writes to it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
# Small, git-heavy, and reaches nothing outside skills/orch/scripts, so the
# mutant tree below is skills/orch/{scripts,tests} rather than a whole
# checkout.
SUBJECT=dev_round_gate.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# --- A sandbox repository, and a fingerprint of what must not move ----------
# The log AND the index: an inherited GIT_DIR writes commits, an inherited
# GIT_INDEX_FILE leaves staged deletions behind without touching the log.
new_sandbox() { # new_sandbox <dir>
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config gc.auto 0
  git -C "$1" config maintenance.auto false
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
}

fingerprint() { # fingerprint <dir>
  git -C "$1" log --format=%H
  echo '--'
  git -C "$1" ls-files --stage
}

run_suite() { # run_suite <suite path> <sandbox> ; all four exported at it
  env GIT_DIR="$2/.git" GIT_COMMON_DIR="$2/.git" GIT_WORK_TREE="$2" \
      GIT_INDEX_FILE="$2/.git/index" \
      bash "$1" >/dev/null 2>&1
}

# --- 1. Control: the real suite leaves the caller's repository alone --------
sandbox="$TMP/sandbox"
new_sandbox "$sandbox"
before="$(fingerprint "$sandbox")"
set +e
run_suite "$TEST_DIR/$SUBJECT" "$sandbox"
subject_status=$?
set -e
assert_eq "$subject_status" \
  "0" "the subject suite still passes under an inherited git environment"
assert_eq "$(fingerprint "$sandbox")" \
  "$before" "the sandbox repository's log and index are untouched"

# --- 1b. Must-fail: the same run with lib/git-env.sh neutralized -----------
# Only the lib changes, so a difference here is the clearing and nothing else.
# The writes are all this arm asserts. An inherited GIT_WORK_TREE makes the
# suite abort partway with a wrong-cause diagnostic, so the run's exit status
# is not the clean pass the silent shape has, and pinning it would pin the
# abort. The silent shape wants GIT_DIR and GIT_INDEX_FILE without
# GIT_WORK_TREE, which is a second environment rather than one control.
# Every file but the neutralized lib is a link: the subject and each lib find
# their siblings through their own directory without resolving a symlink.
mutant="$TMP/mutant/skills/orch"
mkdir -p "$mutant/tests/lib"
ln -s "$REPO_ROOT/skills/orch/scripts" "$mutant/scripts"
ln -s "$TEST_DIR/$SUBJECT" "$mutant/tests/$SUBJECT"
for lib in "$TEST_DIR"/lib/*; do
  [[ "${lib##*/}" == git-env.sh ]] || ln -s "$lib" "$mutant/tests/lib/${lib##*/}"
done
printf '#!/usr/bin/env bash\n: # mutation: the four variables are left standing\n' \
  > "$mutant/tests/lib/git-env.sh"

mutant_sandbox="$TMP/mutant-sandbox"
new_sandbox "$mutant_sandbox"
mutant_before="$(fingerprint "$mutant_sandbox")"
set +e
run_suite "$mutant/tests/$SUBJECT" "$mutant_sandbox"
set -e
if [[ "$mutant_before" != "$(fingerprint "$mutant_sandbox")" ]]; then
  pass "must-fail: without the lib the same run writes into the sandbox"
else
  fail "must-fail: the sandbox survived a run with the lib neutralized, so the control proves nothing"
fi

# --- 2. Scratch below a linked worktree does not discover its checkout ----
# The prune suite writes fleet state before it can fail. That write must stay
# in its fixture, never in the main checkout shared by linked worktrees.
ceiling_sandbox="$TMP/ceiling-sandbox"
new_sandbox "$ceiling_sandbox"
linked="$TMP/linked"
git -C "$ceiling_sandbox" worktree add -q -b fixture "$linked"
mkdir -p "$linked/tmp"
shared_state="$ceiling_sandbox/tmp/workflow-state-oversee.json"

run_prune_suite() { # SUITE ; no git redirects, scratch inside a worktree
  env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    -u ORCH_STATE_DIR TMPDIR="$linked/tmp" \
    bash "$1" > "$TMP/prune.out" 2>&1
}

prune_status=0
run_prune_suite "$TEST_DIR/workflow-state-prune.sh" || prune_status=$?
assert_eq "$prune_status" "0" "the prune suite passes with scratch inside a linked worktree"
if [[ ! -e "$shared_state" ]]; then
  pass "scratch fixtures leave the main checkout's fleet state absent"
else
  fail "scratch fixtures wrote fleet state in the main checkout"
fi

ln -s "$TEST_DIR/workflow-state-prune.sh" "$mutant/tests/workflow-state-prune.sh"
run_prune_suite "$mutant/tests/workflow-state-prune.sh" || true
if [[ -f "$shared_state" ]]; then
  pass "must-fail: without the lib scratch fixtures write shared fleet state"
else
  fail "must-fail: the neutralized lib did not expose the shared fleet state write"
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
