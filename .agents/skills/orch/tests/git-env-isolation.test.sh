#!/usr/bin/env bash
# The orch suites build git fixtures, and git's environment variables outrank
# `git -C <path>`. A suite that inherits GIT_DIR, GIT_COMMON_DIR, GIT_WORK_TREE
# or GIT_INDEX_FILE from its caller commits into the caller's repository and
# leaves its index carrying deletions of paths that never existed there, while
# still reporting a clean pass. lib/git-env.sh clears all four at load and
# every suite sources it.
#
# Two surfaces, each with the mutation that must break it:
#   1. the clearing works — a real suite run with all four exported at a
#      sandbox repository leaves that repository's log and index untouched;
#      neutralize lib/git-env.sh in a copied tree and the same run writes to it
#   2. the lint holds — every suite under tests/ carries the source line
#      directly under its `set -...o pipefail`. Presence alone is not the rule:
#      the line at the end of the file, inside a dead branch, or inside a
#      heredoc body that writes a stub all leave the fixture work unprotected,
#      so the lint pins the position and the probe carries one of each.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SOURCE_LINE='source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"'
# Small, git-heavy, and reaches nothing outside skills/orch/scripts, so the
# mutant tree below is a scripts+tests copy rather than a whole checkout.
SUBJECT=dev_round_gate.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# --- A sandbox repository, and a fingerprint of what must not move ----------
# The log AND the index: an inherited GIT_DIR writes commits, an inherited
# GIT_INDEX_FILE leaves staged deletions behind without touching the log.
new_sandbox() { # new_sandbox <dir>
  mkdir -p "$1"
  git -C "$1" init -q -b main
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
check "the subject suite still passes under an inherited git environment" \
  "0" "$subject_status"
check "the sandbox repository's log and index are untouched" \
  "$before" "$(fingerprint "$sandbox")"

# --- 1b. Must-fail: the same run with lib/git-env.sh neutralized -----------
# Only the lib changes, so a difference here is the clearing and nothing else.
# The writes are all this arm asserts. An inherited GIT_WORK_TREE makes the
# suite abort partway with a wrong-cause diagnostic, so the run's exit status
# is not the clean pass the silent shape has, and pinning it would pin the
# abort. The silent shape wants GIT_DIR and GIT_INDEX_FILE without
# GIT_WORK_TREE, which is a second environment rather than one control.
mutant="$TMP/mutant/skills/orch"
mkdir -p "$mutant"
cp -R "$REPO_ROOT/skills/orch/scripts" "$mutant/"
mkdir -p "$mutant/tests"
cp -R "$REPO_ROOT/skills/orch/tests/lib" "$mutant/tests/"
cp "$REPO_ROOT/skills/orch/tests/$SUBJECT" "$mutant/tests/"
printf '#!/usr/bin/env bash\n: # mutation: the four variables are left standing\n' \
  > "$mutant/tests/lib/git-env.sh"

mutant_sandbox="$TMP/mutant-sandbox"
new_sandbox "$mutant_sandbox"
mutant_before="$(fingerprint "$mutant_sandbox")"
set +e
run_suite "$mutant/tests/$SUBJECT" "$mutant_sandbox"
set -e
if [[ "$mutant_before" != "$(fingerprint "$mutant_sandbox")" ]]; then
  ok "must-fail: without the lib the same run writes into the sandbox"
else
  bad "must-fail: the sandbox survived a run with the lib neutralized, so the control proves nothing"
fi

# --- 2. Lint: the source line sits directly under the `set` line -----------
# Position, not presence. A line that runs after the fixture was built, or does
# not run at all, protects nothing, so the only accepted place is the line
# under the file's first `set -...o pipefail`.
misplaced() { # misplaced <dir> ; names every *.sh in it that is not compliant
  local file set_line src_line
  for file in "$1"/*.sh; do
    [[ -f "$file" ]] || continue
    set_line="$(grep -n -m1 -E '^set -[a-z]*o pipefail$' "$file" | cut -d: -f1)"
    src_line="$(grep -n -m1 -xF "$SOURCE_LINE" "$file" | cut -d: -f1)"
    [[ -n "$set_line" && -n "$src_line" && "$src_line" -eq $((set_line + 1)) ]] \
      || basename "$file"
  done
}

check "the lib clears all four variables together" \
  "unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE" \
  "$(grep '^unset ' "$TEST_DIR/lib/git-env.sh")"
check "every suite under tests/ sources the lib under its set line" \
  "" "$(misplaced "$TEST_DIR")"

# --- 2b. Must-fail: an absent line and three present-but-inert ones --------
probe="$TMP/probe"
mkdir -p "$probe"
printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$SOURCE_LINE" \
  > "$probe/compliant.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\ngit -C . log\n' \
  > "$probe/bare.sh"
# Runs, but after the fixture already landed in the caller's repository.
printf '#!/usr/bin/env bash\nset -euo pipefail\ngit init -q sandbox\n%s\n' \
  "$SOURCE_LINE" > "$probe/after-fixture.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nif false; then\n%s\nfi\ngit init -q sandbox\n' \
  "$SOURCE_LINE" > "$probe/dead-branch.sh"
{ printf '#!/usr/bin/env bash\nset -euo pipefail\ncat > stub.sh <<%s\n' "'EOF'"
  printf '%s\n' "$SOURCE_LINE"
  printf 'EOF\ngit init -q sandbox\n'
} > "$probe/heredoc-body.sh"
check "must-fail: the lint names the absent line and every inert placement" \
  "$(printf 'after-fixture.sh\nbare.sh\ndead-branch.sh\nheredoc-body.sh')" \
  "$(misplaced "$probe")"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
