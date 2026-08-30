#!/usr/bin/env bash
# Exit 75 is volatile. The script and its help name the durable lifecycle a
# caller must launch.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PR_MERGE="$REPO_ROOT/skills/github/scripts/commands/pr-merge.sh"
GITHUB_SH="$REPO_ROOT/skills/github/scripts/github.sh"

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

echo "=== pr-merge exit 75 contract matches script and help ==="

script_src=$(cat "$PR_MERGE")
# Both 75 exits route through the one note (queued and classic auto-merge).
assert_count "$script_src" '^[[:space:]]*volatile_note "\$pr_num"$' 2 \
  "both exit-75 paths emit the volatility note"
assert_matches "$script_src" 'VOLATILE.*an ejection or a failed protection check disarms it silently' \
  "the note states an ejection or a failed protection check disarms silently"
assert_matches "$script_src" '\.agents/skills/orch/scripts/merge-queue-watch' \
  "the note names the durable lifecycle by its installed path"
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

merge_help=$($GITHUB_SH pr-merge --help)
volatile_help=$(sed -n '/^Exit 75 is volatile:$/,/^Terminal and mutation rules:$/p' <<<"$merge_help")
assert_matches "$volatile_help" '^Exit 75 is volatile:$' \
  "pr-merge help carries the exit-75 contract"
assert_matches "$volatile_help" 'merge-queue-watch' \
  "pr-merge help names the durable lifecycle"
assert_matches "$volatile_help" 'durable verdict' \
  "pr-merge help states the lifecycle durability boundary"
assert_matches "$script_src" 'Launch the prepared .*merge-queue-watch once' \
  "the note says to launch one durable lifecycle generation"
assert_matches "$volatile_help" 'github\.sh pr-merge <N> --auto' \
  "pr-merge help names the re-arm command"
assert_matches "$volatile_help" 'README\.md "Exit 75 recovery"' \
  "pr-merge help links the recovery section"
readme_src=$(sed -n '/^## Exit 75 recovery$/,/^## /p' "$REPO_ROOT/skills/github/README.md")
assert_matches "$readme_src" 'exits 75 when the PR is queued or auto-merge is armed' \
  "README states the volatile 75 contract"
# The verdict set grows, so queue-wait owns its meanings and the lifecycle
# maps them to merge-pr's action table instead of either document restating it.
assert_matches "$readme_src" 'merge-pr\.md` § 5 step 1' \
  "README routes lifecycle actions by the workflow table rather than restating verdicts"
assert_matches "$readme_src" 'queue-wait --help` § Verdicts owns' \
  "README keeps queue-wait --help as the reference for what a verdict means"
assert_matches "$readme_src" 'An unrecognized verdict' \
  "README refuses to re-arm a verdict the lifecycle does not recognize"
assert_matches "$script_src" 'route its claimed action by orch merge-pr\.md § 5 step 1' \
  "the script's own note routes by the same action table the README names"
assert_matches "$script_src" 'never re-arm an unrecognized verdict' \
  "the script's own note carries the same refusal"
assert_matches "$script_src" 'repair what the cause names before re-arming' \
  "the script's own note requires the repair before a re-arm, as the README does"

# A pointer is worth what its target is. Each is anchored on the row or the
# heading itself, so prose elsewhere in either file naming a verdict cannot
# stand in for the section going missing.
queue_wait_src=$(cat "$REPO_ROOT/skills/orch/scripts/queue-wait")
assert_matches "$queue_wait_src" "^Verdicts \(the semantics behind merge-pr § 5 step 1's routing table\):\$" \
  "queue-wait --help still carries the § Verdicts heading the README names"
merge_pr_src=$(cat "$REPO_ROOT/skills/orch/workflows/merge-pr.md")
assert_matches "$merge_pr_src" '^   \| `action` \| Route \|$' \
  "merge-pr § 5 step 1 still carries the action table the README routes to"
assert_matches "$merge_pr_src" '^   \| `restack`, `resume_restack` \| Run or resume the guarded Restack cycle below \|$' \
  "that table routes the conflicting lifecycle action to the restack cycle"
watch_src=$(cat "$REPO_ROOT/skills/orch/scripts/merge-queue-watch")
assert_matches "$watch_src" 'conflicting:\*\) action=restack' \
  "the lifecycle maps the conflicting producer verdict to that restack action"
assert_matches "$watch_src" 'malformed_artifact' \
  "an artifact outside the accepted verdict set fails closed"
assert_matches "$volatile_help" 'await-mergeable' \
  "pr-merge help names await-mergeable"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
