#!/usr/bin/env bash
# Every worktree command's --help is answered, at any argv position, and the
# top-level help states the settings loader's real precedence. check takes no
# target: it inspects only the main checkout, and an argument is a usage
# error rather than a silently ignored one.
#
# No form sources the project's .env.local, held here across every command
# the dispatcher routes. tools/tests/help-inert.test.sh holds the same
# contract for the top-level forms, alongside the other CLIs that each
# carried their own copy of it.
#
# The same boundary from the other side: a command that is not help does
# reach the repository lookup, and outside a repository it refuses with a
# diagnostic naming the cwd rather than dying at git's bare 128 (KEN-1166).
set -euo pipefail

# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call in this file back at the real repository: the fixtures below would be
# built in it, and the no-repository fixture would look like a repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
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

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n' "$name" "$needle"
  fi
}

echo "=== worktree help dispatch runs before repository and env initialization ==="

# A repo whose .env.local records that it was sourced. Any help invocation
# that loads project config trips the marker.
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
printf 'touch "%s/env-executed"\n' "$TMP_ROOT" >"$REPO/.env.local"

for form in "--help" "-h" "help"; do
  out=$(cd "$REPO" && "$WORKTREE_SCRIPT" "$form")
  assert_eq "$?" 0 "worktree $form exits 0"
  assert_contains "$out" "Usage: worktree <command>" "worktree $form prints the command index"
done

for cmd in restack create remove cleanup check list path exists push \
  fix-links repair-links \
  codex-setup codex-branch codex-cleanup claude-setup claude-cleanup; do
  out=$(cd "$REPO" && "$WORKTREE_SCRIPT" "$cmd" --help)
  assert_eq "$?" 0 "worktree $cmd --help exits 0"
  [[ -n "$out" ]] || { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "worktree $cmd --help prints something"; }
done

out=$(cd "$REPO" && "$WORKTREE_SCRIPT" claude-setup --help)
assert_contains "$out" "App-created worktree hooks" "hook commands share the app-hook help"

# Help at ANY argv position, not only right after the command: enumerating
# positions is how this class leaks.
out=$(cd "$REPO" && "$WORKTREE_SCRIPT" remove CC-1 --help)
assert_eq "$?" 0 "worktree remove CC-1 --help exits 0"
assert_contains "$out" "Usage: worktree remove" "late --help prints the remove help"
out=$(cd "$REPO" && "$WORKTREE_SCRIPT" cleanup --stale --help)
assert_eq "$?" 0 "worktree cleanup --stale --help exits 0"
assert_contains "$out" "Usage: worktree cleanup" "late --help prints the cleanup help"
out=$(cd "$REPO" && "$WORKTREE_SCRIPT" push some-id -h)
assert_eq "$?" 0 "worktree push some-id -h exits 0"
assert_contains "$out" "Usage: worktree push" "late -h prints the push help"

out=$(cd "$REPO" && "$WORKTREE_SCRIPT" list --help)
assert_contains "$out" "Usage: worktree list" "list --help prints the list help"
out=$(cd "$REPO" && "$WORKTREE_SCRIPT" path --help)
assert_contains "$out" "Usage: worktree path" "path --help prints help, not an issue lookup"
out=$(cd "$REPO" && "$WORKTREE_SCRIPT" exists -h)
assert_contains "$out" "worktree exists" "exists -h prints help, not an issue lookup"

# Every help form run inside $REPO is above this line except `check --help`,
# which the 16-command loop already ran here — so the marker answers for all
# of them at once.
if [[ -e "$TMP_ROOT/env-executed" ]]; then
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "help sourced the project .env.local"
else
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "no help form sourced the project .env.local"
fi

# Per-command help needs no repository at all. The top-level form is
# tools/tests/help-inert.test.sh's; these three resolve a worktree when they
# run, so their help is the one that could reach for a repository.
NOREPO="$TMP_ROOT/norepo"
mkdir -p "$NOREPO"
export GIT_CEILING_DIRECTORIES="$TMP_ROOT"
norepo_status=0
norepo_probe=$(LC_ALL=C git -C "$NOREPO" rev-parse --show-toplevel 2>&1) || norepo_status=$?
if [[ "$norepo_status" -eq 0 ]]; then
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        got:      %s\n' \
    "the no-repository fixture is outside a git repository" "$norepo_probe"
elif [[ "$norepo_status" -eq 128 && "$norepo_probe" == *"not a git repository"* ]]; then
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "the no-repository fixture is outside a git repository"
  for cmd in list path exists; do
    status=0
    out=$(cd "$NOREPO" && "$WORKTREE_SCRIPT" "$cmd" --help) || status=$?
    assert_eq "$status" 0 "worktree $cmd --help exits 0 outside a git repository"
  done

  # Past help, the repository lookup runs and has nothing to find. It refuses
  # once, naming the cwd and the checkout to run from; `remove` is the form
  # that gets run from the worktrees' parent, so it is held here too.
  for cmd in "list" "remove ISSUE-GONE"; do
    status=0
    # shellcheck disable=SC2086
    out=$(cd "$NOREPO" && "$WORKTREE_SCRIPT" $cmd 2>"$TMP_ROOT/norepo.err") || status=$?
    err=$(cat "$TMP_ROOT/norepo.err")
    assert_eq "$status" 1 "worktree $cmd exits 1 outside a git repository"
    assert_contains "$err" "could not resolve a git repository from: $NOREPO" \
      "worktree $cmd names the cwd it could not resolve a repository from"
    assert_contains "$err" "Run it from a checkout of the repository you mean" \
      "worktree $cmd names what to do instead"
    # One refusal serves every non-help command, so its example names none: a
    # subcommand baked in here is the wrong next step for the other callers,
    # and `remove` deletes a worktree and a branch.
    assert_contains "$err" "scripts/worktree <command>" \
      "worktree $cmd offers a recovery example with no subcommand of its own"
    assert_eq "$out" "" "worktree $cmd prints nothing on stdout outside a git repository"
  done

  # The cause is git's, not the script's guess at it. A repository with no git
  # to read it is the case that separates the two: the cwd IS a checkout, and
  # a message asserting otherwise sends the operator to a second one.
  # LC_ALL=C like the probe above: the message under test is translated, so an
  # unpinned locale reddens this on a workstation and nowhere else.
  mkdir -p "$TMP_ROOT/empty-bin"
  status=0
  out=$(cd "$TEST_DIR" && LC_ALL=C PATH="$TMP_ROOT/empty-bin" "$WORKTREE_SCRIPT" list 2>"$TMP_ROOT/nogit.err") || status=$?
  # Read the quoted line, not the whole stream: without the anchor the needle
  # also matches the shell's own unredirected message, which is what stderr
  # carries when the refusal quotes nothing at all.
  said=""
  if ! said=$(grep -F '  git said: ' "$TMP_ROOT/nogit.err"); then said=""; fi
  assert_eq "$status" 1 "worktree list exits 1 when git is not on PATH"
  assert_contains "$said" "git: command not found" \
    "the refusal quotes git's own account rather than asserting a cause"
  assert_eq "$out" "" "worktree list prints nothing on stdout when git is not on PATH"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        status:   %s\n        diagnostic: %s\n' \
    "the no-repository fixture probe returns Git's expected result" "$norepo_status" "$norepo_probe"
fi

# The top-level help states the loader's real precedence, lowest to highest.
out=$(cd "$NOREPO" && "$WORKTREE_SCRIPT" --help)
assert_contains "$out" "kendex.settings.toml [env], then" "help orders the root settings file below the rest"
assert_contains "$out" ".kendex/settings.toml" "help names the .kendex settings file"
assert_contains "$out" "parent environment beats every project file" "help states parent env outranks project files"

echo
echo "=== check takes no target ==="

out=$(cd "$REPO" && "$WORKTREE_SCRIPT" check --help)
assert_contains "$out" "MAIN checkout" "check --help says it inspects the main checkout"

set +e
err=$(cd "$REPO" && "$WORKTREE_SCRIPT" check some-id 2>&1)
code=$?
set -e
assert_eq "$code" 1 "check with an argument exits 1"
assert_contains "$err" "check takes no arguments" "check names the rejection"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
