#!/usr/bin/env bash
# Exit 75 (queued / auto-merge armed) is volatile: an ejection disarms it
# silently. The script says so on every 75 exit and the SKILL.md outcome table
# names the watcher a caller must keep running; these pins keep the two from
# drifting apart.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SKILL_MD="$REPO_ROOT/skills/github/SKILL.md"
PR_MERGE="$REPO_ROOT/skills/github/scripts/commands/pr-merge.sh"

PASS=0
FAIL=0

assert_matches() {
  local got="$1" pattern="$2" name="$3"
  if grep -qE -- "$pattern" <<<"$got"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to match: %s\n' "$name" "$pattern"
  fi
}

assert_count() { # GOT PATTERN EXPECTED NAME
  local got="$1" pattern="$2" expected="$3" name="$4" n
  n=$(grep -cE -- "$pattern" <<<"$got" || true)
  if [ "$n" -eq "$expected" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected %s match(es) of: %s (got %s)\n' "$name" "$expected" "$pattern" "$n"
  fi
}

echo "=== pr-merge exit 75 is documented as volatile, in the script and the SKILL ==="

script_src=$(cat "$PR_MERGE")
# Both 75 exits route through the one note (queued and classic auto-merge).
assert_count "$script_src" '^[[:space:]]*volatile_note "\$pr_num"$' 2 \
  "both exit-75 paths emit the volatility note"
assert_matches "$script_src" 'VOLATILE.*an ejection or a failed protection check disarms it silently' \
  "the note states an ejection or a failed protection check disarms silently"
assert_matches "$script_src" '\.agents/skills/orch/scripts/queue-wait \$pr_num' \
  "the note names queue-wait by its runnable path"
assert_matches "$script_src" 'reducer="GH_REPO=\$repo \.agents/skills/review-gate/scripts/pr-watch\.sh' \
  "the note names the pr-watch reducer by its runnable path, with the GH_REPO it requires"
assert_matches "$script_src" 'with GH_REPO set to the repository \(not resolvable locally here\)' \
  "an unresolvable repository yields a plain instruction, never a pasteable placeholder"
assert_matches "$script_src" 'git config --get "remote\.\$remote_name\.url"' \
  "the repository is resolved locally (the resolved remote), never by a network read on the exit path"
assert_matches "$script_src" 'gh-resolved' \
  "gh's configured default repository (a fork's upstream) wins over origin"
assert_matches "$script_src" '\*\[!A-Za-z0-9\._/-\]\*\) repo=""' \
  "only an OWNER/REPO-shaped value is printed into the pasteable command"
assert_matches "$script_src" '^[[:space:]]*\*\) repo="" ;;' \
  "a slash-less value is refused too"
if grep -qE 'repo view|gh api|gh pr' <<<"$(sed -n '/^volatile_note() {/,/^}/p' "$PR_MERGE")"; then
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "volatile_note makes no gh request"
else
  PASS=$((PASS + 1)); printf '  ok    %s\n' "volatile_note makes no gh request"
fi

table=$(sed -n '/^### PR Merge Outcomes$/,/^### /p' "$SKILL_MD")
assert_count "$table" '^\| `75` \| MERGE PENDING \(volatile\)' 2 \
  "both 75 rows of the outcomes table are marked volatile"
assert_matches "$table" 'keep watching until MERGED' \
  "the 75 rows say the caller keeps watching until MERGED"
assert_matches "$table" '— neither' \
  "the outcomes section states no watcher is durable"
assert_matches "$script_src" 're-running until MERGED' \
  "the note says to re-run the watcher until MERGED"
assert_matches "$table" 'queue-wait <N>' \
  "the outcomes section names queue-wait as the required follow-up"
assert_matches "$(tr '\n' ' ' <<<"$table")" 'github\.sh pr-merge <N> --auto' \
  "the outcomes section names the re-arm by its installed entry point"
assert_matches "$table" 'README\.md § Exit 75 recovery' \
  "the outcomes section points at the README recovery section (progressive disclosure)"
readme_src=$(sed -n '/^## Exit 75 recovery$/,/^## /p' "$REPO_ROOT/skills/github/README.md")
assert_matches "$readme_src" 'exits 75 when the PR is queued or auto-merge is armed' \
  "README states the volatile 75 contract"
assert_matches "$readme_src" 're-arm on `ejected`, `disarmed` and' \
  "README routes only genuine disarm verdicts to re-arm"
assert_matches "$readme_src" '`dequeued` means late review findings' \
  "README routes dequeued to findings triage, not re-arm"
assert_matches "$readme_src" 'is a CI repair first' \
  "README requires the CI repair before re-arming an ejected head"
assert_matches "$table" 'await-mergeable` is not that' \
  "the outcomes section states await-mergeable is not the ejection watcher"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
