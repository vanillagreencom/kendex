#!/usr/bin/env bash
# Tests for the task-completed-check hook.
#
# The hook gates task completion on `cargo clippy` whenever the working tree
# carries a changed Rust file. Two halves are pinned here: what counts as
# changed — worktree, index, and untracked non-ignored paths, so a task whose
# only work is a new file still reaches the gate — and the verdict, which is
# clippy's exit status alone, so a run that dies without printing a
# diagnostic blocks rather than passes.
#
# Fixtures are throwaway git repositories built under a HOME of their own;
# clippy is a fake `cargo` on PATH replaying a scripted exit code and output.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-block hook) can be run against these same
# assertions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/task-completed-check.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"
ARGS_LOG="$TMP_ROOT/cargo.args"

# Fake cargo: records its argv, prints $FAKE_OUT, exits $FAKE_RC.
cat >"$BIN_DIR/cargo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_ARGS_LOG"
if [ -n "${FAKE_OUT:-}" ]; then
  printf '%s\n' "$FAKE_OUT"
fi
exit "${FAKE_RC:-0}"
EOF
chmod +x "$BIN_DIR/cargo"

# Fixture git runs under the throwaway HOME so the caller's own git
# configuration cannot decide what a fixture repository does.
fgit() {
  env HOME="$TMP_ROOT" git "$@"
}

# A fresh repository with one committed Rust file, so every case starts from
# a clean tree and states its own change.
new_repo() {
  local repo="$TMP_ROOT/repo.$1"
  mkdir -p "$repo/src"
  fgit init -q "$repo"
  fgit -C "$repo" config user.email t@example.com
  fgit -C "$repo" config user.name t
  printf '[package]\nname = "f"\nversion = "0.1.0"\n' >"$repo/Cargo.toml"
  printf 'fn main() {}\n' >"$repo/src/main.rs"
  fgit -C "$repo" add -A
  fgit -C "$repo" commit -q -m init
  printf '%s' "$repo"
}

# Run the hook inside $1 with a TaskCompleted payload on stdin. Extra
# VAR=value args are passed through the environment. Captures stderr in $err
# and the exit code in $rc.
run_hook() {
  local dir="$1"
  shift
  : >"$ARGS_LOG"
  set +e
  ( cd "$dir" && env HOME="$TMP_ROOT" PATH="$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" "$@" \
    bash "$HOOK" <<<'{"hook_event_name":"TaskCompleted"}' ) \
    >/dev/null 2>"$TMP_ROOT/stderr"
  rc=$?
  set -e
  err="$(cat "$TMP_ROOT/stderr")"
}

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
  local got="$1" needle="$2" name="$3"
  if [[ "$got" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

echo "task-completed-check: nothing changed"
REPO="$(new_repo clean)"
run_hook "$REPO" FAKE_RC=0
assert_eq "$rc" 0 "a clean tree exits 0"
assert_eq "$(cat "$ARGS_LOG")" "" "a clean tree never invokes cargo"

echo "task-completed-check: an untracked new file is a change"
REPO="$(new_repo untracked)"
printf 'pub fn added() {}\n' >"$REPO/src/added.rs"
run_hook "$REPO" FAKE_RC=0
assert_eq "$rc" 0 "a passing clippy exits 0"
assert_contains "$(cat "$ARGS_LOG")" "clippy" "a new file alone still runs clippy"
run_hook "$REPO" FAKE_RC=101 FAKE_OUT="error: unused variable"
assert_eq "$rc" 2 "a new file alone can still block the task"
assert_contains "$err" "error: unused variable" "carries clippy's own diagnostic"

echo "task-completed-check: an untracked file seen from a subdirectory"
run_hook "$REPO/src" FAKE_RC=0
assert_contains "$(cat "$ARGS_LOG")" "clippy" "the whole repository is scanned from a subdirectory"

echo "task-completed-check: a non-ASCII path is still a Rust file"
REPO="$(new_repo unicode)"
printf 'pub fn added() {}\n' >"$REPO/src/über.rs"
run_hook "$REPO" FAKE_RC=0
assert_contains "$(cat "$ARGS_LOG")" "clippy" "an untracked src/über.rs reaches the gate"
fgit -C "$REPO" add -A
run_hook "$REPO" FAKE_RC=0
assert_contains "$(cat "$ARGS_LOG")" "clippy" "a staged src/über.rs reaches the gate"

echo "task-completed-check: ignored paths stay out of the changed set"
REPO="$(new_repo ignored)"
printf 'target/\n' >"$REPO/.gitignore"
fgit -C "$REPO" add .gitignore
fgit -C "$REPO" commit -q -m ignore
mkdir -p "$REPO/target"
printf 'fn generated() {}\n' >"$REPO/target/generated.rs"
run_hook "$REPO" FAKE_RC=0
assert_eq "$(cat "$ARGS_LOG")" "" "an ignored Rust file is not a change"

echo "task-completed-check: tracked edits still gate"
REPO="$(new_repo tracked)"
printf 'fn main() { let x = 1; }\n' >"$REPO/src/main.rs"
run_hook "$REPO" FAKE_RC=101 FAKE_OUT="error: unused variable"
assert_eq "$rc" 2 "an unstaged edit blocks on a failing clippy"
fgit -C "$REPO" add -A
run_hook "$REPO" FAKE_RC=101 FAKE_OUT="error: unused variable"
assert_eq "$rc" 2 "a staged edit blocks on a failing clippy"

echo "task-completed-check: the exit status is the verdict"
REPO="$(new_repo status)"
printf 'pub fn added() {}\n' >"$REPO/src/added.rs"
run_hook "$REPO" FAKE_RC=101 FAKE_OUT="warning: build failed, waiting for other jobs"
assert_eq "$rc" 2 "a failure printing no error: line still blocks"
assert_contains "$err" "waiting for other jobs" "reports what the failed run did print"
run_hook "$REPO" FAKE_RC=1 FAKE_OUT=""
assert_eq "$rc" 2 "a failure printing nothing at all still blocks"
assert_contains "$err" "Clippy failed" "names the failure when there is no output to quote"
run_hook "$REPO" FAKE_RC=0 FAKE_OUT="error: this line is not a verdict"
assert_eq "$rc" 0 "a successful run is not blocked by the word error in its output"

echo "task-completed-check: outside a repository"
NOREPO="$TMP_ROOT/norepo"
mkdir -p "$NOREPO"
printf 'pub fn added() {}\n' >"$NOREPO/added.rs"
run_hook "$NOREPO" FAKE_RC=0
assert_eq "$rc" 0 "no repository to ask means nothing to gate"
assert_eq "$(cat "$ARGS_LOG")" "" "no repository never invokes cargo"

echo "task-completed-check: git cannot answer what changed"
REPO="$(new_repo brokengit)"
printf 'pub fn added() {}\n' >"$REPO/src/added.rs"
BROKEN_BIN="$TMP_ROOT/brokengit"
mkdir -p "$BROKEN_BIN"
REAL_GIT="$(command -v git)"
# Passes every subcommand through except the untracked listing, which dies
# the way a git too old for the flags or a broken index would.
cat >"$BROKEN_BIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "ls-files" ]; then
    echo "fatal: unable to read index" >&2
    exit 128
  fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$BROKEN_BIN/git"
set +e
( cd "$REPO" && env HOME="$TMP_ROOT" PATH="$BROKEN_BIN:$BIN_DIR:$PATH" \
  FAKE_ARGS_LOG="$ARGS_LOG" FAKE_RC=0 bash "$HOOK" <<<'{}' ) \
  >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "$rc" 2 "an unreadable changed set blocks rather than passing"
assert_contains "$(cat "$TMP_ROOT/stderr")" "unable to read index" "carries git's own failure"

echo "task-completed-check: no cargo on PATH"
REPO="$(new_repo nocargo)"
printf 'pub fn added() {}\n' >"$REPO/src/added.rs"
NOCARGO_BIN="$TMP_ROOT/nocargo"
mkdir -p "$NOCARGO_BIN"
for tool in bash cat git grep sed sort head tail tr dirname; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -f "$real" ] && ln -sf "$real" "$NOCARGO_BIN/$tool"
done
set +e
( cd "$REPO" && env -i HOME="$TMP_ROOT" PATH="$NOCARGO_BIN" "$NOCARGO_BIN/bash" "$HOOK" <<<'{}' ) \
  >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "$rc" 2 "a missing cargo blocks rather than passing"
assert_contains "$(cat "$TMP_ROOT/stderr")" "Clippy failed" "says the lint run failed"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
