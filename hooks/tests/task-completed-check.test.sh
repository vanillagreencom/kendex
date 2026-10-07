#!/usr/bin/env bash
# Tests for the task-completed-check hook.
#
# The hook gates task completion on `cargo clippy` whenever the working tree
# carries a changed Rust file. Pinned here: what counts as changed — worktree,
# index, and untracked non-ignored paths, so a task whose only work is an
# untracked file reaches the gate; which crates are linted — the workspace
# members owning a changed file, never the whole workspace; and the verdict,
# which is clippy's exit status alone, so a run that dies without printing a
# diagnostic blocks rather than passes, while warnings complete the task with
# a notice. A host that cannot run the check — no cargo, no jq, a git that
# cannot list the changed set — completes the task with a notice, never a
# silent pass.
#
# Fixtures are throwaway git repositories built under a HOME of their own;
# cargo is a fake on PATH: `cargo metadata` prints $FAKE_METADATA, else one
# member `f` at the repository root, and `cargo clippy` replays a scripted exit
# code and output.
#
# Every refusal and notice opens with `task-completed-check: <key>=<value>`, and
# that line is the contract: the status clippy left, the warning count, the
# missing tools, or the git subcommand that could not answer, is the value. The
# diagnostics under it are git's and cargo's own words, pinned as themselves.
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
ERR_FILE="$TMP_ROOT/stderr"

BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"
ARGS_LOG="$TMP_ROOT/cargo.args"

# Fake cargo: records its argv; `metadata` prints $FAKE_METADATA (or one member
# `f` at the repository root) and exits $FAKE_METADATA_RC; anything else prints
# $FAKE_OUT and exits $FAKE_RC.
cat >"$BIN_DIR/cargo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_ARGS_LOG"
if [ "$1" = metadata ]; then
  if [ "${FAKE_METADATA_RC:-0}" -ne 0 ]; then
    echo "error: failed to parse manifest" >&2
    exit "$FAKE_METADATA_RC"
  fi
  if [ -n "${FAKE_METADATA:-}" ]; then
    printf '%s\n' "$FAKE_METADATA"
  else
    printf '{"packages":[{"name":"f","manifest_path":"%s/Cargo.toml"}]}\n' "$(git rev-parse --show-toplevel)"
  fi
  exit 0
fi
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

# The first-line reader. This suite's runs vary the repository and the fake
# cargo rather than one command, which the shared table's modes do not express,
# so `first_line` is the half of that library it uses.
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

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
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=task-completed-check: clippy=101" \
  "a new file alone can still block the task, clippy's status the value"
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
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=task-completed-check: clippy=1" \
  "a failure printing nothing at all still blocks, its status the value"
run_hook "$REPO" FAKE_RC=0 FAKE_OUT="error: this line is not a verdict"
assert_eq "$rc" 0 "a successful run is not blocked by the word error in its output"

echo "task-completed-check: only the crates that own a change are linted"
REPO="$(new_repo members)"
mkdir -p "$REPO/crates/a/src" "$REPO/crates/b/src" "$REPO/scratch"
printf 'pub fn a() {}\n' >"$REPO/crates/a/src/lib.rs"
printf 'pub fn b() {}\n' >"$REPO/crates/b/src/lib.rs"
fgit -C "$REPO" add -A
fgit -C "$REPO" commit -q -m members
MEMBERS_META=$(printf '{"packages":[{"name":"f","manifest_path":"%s/Cargo.toml"},{"name":"a","manifest_path":"%s/crates/a/Cargo.toml"},{"name":"b","manifest_path":"%s/crates/b/Cargo.toml"}]}' "$REPO" "$REPO" "$REPO")
printf 'pub fn b() { }\n' >"$REPO/crates/b/src/lib.rs"
run_hook "$REPO" FAKE_RC=0 FAKE_METADATA="$MEMBERS_META"
assert_eq "$(sed -n '/^clippy/p' "$ARGS_LOG")" "clippy -p b --all-targets" \
  "a change to crate b lints b alone: not the workspace, not the root member above it"
printf 'pub fn a() { }\n' >"$REPO/crates/a/src/lib.rs"
run_hook "$REPO" FAKE_RC=0 FAKE_METADATA="$MEMBERS_META"
assert_eq "$(sed -n '/^clippy/p' "$ARGS_LOG")" "clippy -p a -p b --all-targets" \
  "changes to two crates lint each once"
fgit -C "$REPO" checkout -q -- crates
# c depends on b and d on c, through path dependencies; e depends on a crate
# from a registry that shares b's name, and g on a path crate outside the
# workspace that shares it, neither of which is b.
DEPS_META=$(printf '{"packages":[{"name":"a","manifest_path":"%s/crates/a/Cargo.toml","dependencies":[]},{"name":"b","manifest_path":"%s/crates/b/Cargo.toml","dependencies":[]},{"name":"c","manifest_path":"%s/crates/c/Cargo.toml","dependencies":[{"name":"b","source":null,"path":"%s/crates/b"}]},{"name":"d","manifest_path":"%s/crates/d/Cargo.toml","dependencies":[{"name":"c","source":null,"kind":"dev","path":"%s/crates/c"}]},{"name":"e","manifest_path":"%s/crates/e/Cargo.toml","dependencies":[{"name":"b","source":"registry+https://github.com/rust-lang/crates.io-index"}]},{"name":"g","manifest_path":"%s/crates/g/Cargo.toml","dependencies":[{"name":"b","source":null,"path":"%s/vendor/b"}]}]}' "$REPO" "$REPO" "$REPO" "$REPO" "$REPO" "$REPO" "$REPO" "$REPO" "$REPO")
mkdir -p "$REPO/crates/c" "$REPO/crates/d" "$REPO/crates/e" "$REPO/crates/g" "$REPO/vendor/b"
printf 'pub fn b() { }\n' >"$REPO/crates/b/src/lib.rs"
run_hook "$REPO" FAKE_RC=0 FAKE_METADATA="$DEPS_META"
assert_eq "$(sed -n '/^clippy/p' "$ARGS_LOG")" "clippy -p b -p c -p d --all-targets" \
  "a change to b also lints every member depending on it, however indirectly, and no registry or outside path namesake"
# cargo on Windows writes native backslash separators in both path fields.
WIN_META=$(jq -cn --arg r "$REPO" '{packages: [
  {name: "b", manifest_path: ($r + "\\crates\\b\\Cargo.toml"), dependencies: []},
  {name: "c", manifest_path: ($r + "\\crates\\c\\Cargo.toml"),
   dependencies: [{name: "b", source: null, path: ($r + "\\crates\\b")}]}]}')
run_hook "$REPO" FAKE_RC=0 FAKE_METADATA="$WIN_META"
assert_eq "$(sed -n '/^clippy/p' "$ARGS_LOG")" "clippy -p b -p c --all-targets" \
  "backslash-separated cargo paths still map files and dependencies to members"
fgit -C "$REPO" checkout -q -- crates
fgit -C "$REPO" mv crates/a/src/lib.rs crates/b/src/moved.rs
run_hook "$REPO" FAKE_RC=0 FAKE_METADATA="$MEMBERS_META"
assert_eq "$(sed -n '/^clippy/p' "$ARGS_LOG")" "clippy -p a -p b --all-targets" \
  "a staged move between members lints the crate it left as well as the one it joined"
fgit -C "$REPO" reset -q --hard
printf 'fn loose() {}\n' >"$REPO/scratch/loose.rs"
run_hook "$REPO" FAKE_RC=0 \
  FAKE_METADATA="$(printf '{"packages":[{"name":"a","manifest_path":"%s/crates/a/Cargo.toml"}]}' "$REPO")"
assert_eq "rc=$rc clippy=$(sed -n '/^clippy/p' "$ARGS_LOG")" "rc=0 clippy=clippy --workspace --all-targets" \
  "a Rust file no member's directory holds, which any member may include by #[path], lints the whole workspace"
run_hook "$REPO" FAKE_RC=0 FAKE_METADATA_RC=101
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=task-completed-check: metadata=failed" \
  "a manifest cargo cannot read refuses"
assert_contains "$err" "failed to parse manifest" "carries cargo's own failure"

echo "task-completed-check: warnings are advice, errors refuse"
REPO="$(new_repo warnings)"
printf 'pub fn added() { let x = 1; }\n' >"$REPO/src/added.rs"
run_hook "$REPO" FAKE_RC=0 \
  FAKE_OUT="$(printf 'warning: unused variable: `x`\n --> src/added.rs:1:22\nwarning: `f` (bin "f") generated 1 warning')"
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=task-completed-check: warnings=1" \
  "a lint warning completes the task under a notice counting it"
assert_contains "$err" "unused variable" "shows the warning itself"
assert_eq "$(sed -n '/^clippy.*-D warnings/p' "$ARGS_LOG")" "" "warnings are not denied"
run_hook "$REPO" FAKE_RC=101 \
  FAKE_OUT="$(printf 'error[E0425]: cannot find value `y`\nwarning: unused variable: `x`')"
assert_eq "rc=$rc first=$(first_line)" "rc=2 first=task-completed-check: clippy=101" \
  "a compile error refuses even beside a warning"
run_hook "$REPO" FAKE_RC=0 FAKE_OUT=""
assert_eq "rc=$rc err=$err" "rc=0 err=" "a clean clippy says nothing"

echo "task-completed-check: a failed repository probe is unchecked, not passed"
NOREPO="$TMP_ROOT/norepo"
mkdir -p "$NOREPO"
printf 'pub fn added() {}\n' >"$NOREPO/added.rs"
run_hook "$NOREPO" FAKE_RC=0
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=task-completed-check: git=rev-parse" \
  "a directory that is not a repository completes under the unchecked notice"
assert_eq "$(cat "$ARGS_LOG")" "" "a failed probe never invokes cargo"
# The same 128 from inside a checkout git cannot read. Nothing in the status
# or the message separates the two, so neither may read as a clean pass.
REPO="$(new_repo badconfig)"
printf 'pub fn added() {}\n' >"$REPO/src/added.rs"
printf 'this is not a config line\n' >"$REPO/.git/config"
run_hook "$REPO" FAKE_RC=0
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=task-completed-check: git=rev-parse" \
  "an unreadable .git/config completes unchecked, naming the probe that could not answer"

echo "task-completed-check: a changed set larger than the pipe buffer"
REPO="$(new_repo bigset)"
printf 'pub fn added() {}\n' >"$REPO/src/added.rs"
# The padding sorts after src/, and is long enough that the changed-set filter
# cannot have read it all before an early-exiting reader would have quit on the
# .rs file: without it a filter that stops at its first match reaches the same
# verdict, and this case would establish nothing.
mkdir -p "$REPO/zpad"
i=0
while [ "$i" -lt 1200 ]; do
  : >"$REPO/zpad/padding-$i-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  i=$((i + 1))
done
run_hook "$REPO" FAKE_RC=0
assert_contains "$(cat "$ARGS_LOG")" "clippy" "an early .rs path is still found past the pipe buffer"

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
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=task-completed-check: git=ls-files" \
  "an unreadable changed set completes unchecked rather than passing silently, naming the probe"
assert_contains "$(cat "$TMP_ROOT/stderr")" "unable to read index" "carries git's own failure"

echo "task-completed-check: no git on PATH"
REPO="$(new_repo nogit)"
printf 'pub fn added() {}\n' >"$REPO/src/added.rs"
NOGIT_BIN="$TMP_ROOT/nogit"
mkdir -p "$NOGIT_BIN"
for tool in bash cat sed sort head tail tr dirname; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -f "$real" ] && ln -sf "$real" "$NOGIT_BIN/$tool"
done
set +e
( cd "$REPO" && env -i HOME="$TMP_ROOT" PATH="$NOGIT_BIN" "$NOGIT_BIN/bash" "$HOOK" <<<'{}' ) \
  >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=task-completed-check: git=rev-parse" \
  "a git that will not run completes unchecked too"

echo "task-completed-check: no cargo on PATH"
REPO="$(new_repo nocargo)"
printf 'pub fn added() {}\n' >"$REPO/src/added.rs"
NOCARGO_BIN="$TMP_ROOT/nocargo"
mkdir -p "$NOCARGO_BIN"
for tool in bash cat git grep jq sed sort head tail tr dirname wc; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -f "$real" ] && ln -sf "$real" "$NOCARGO_BIN/$tool"
done
set +e
( cd "$REPO" && env -i HOME="$TMP_ROOT" PATH="$NOCARGO_BIN" "$NOCARGO_BIN/bash" "$HOOK" <<<'{}' ) \
  >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "rc=$rc first=$(first_line)" "rc=0 first=task-completed-check: missing-tools=cargo" \
  "a missing cargo completes unchecked under a notice naming it"

echo "task-completed-check: no jq on PATH"
rm "$NOCARGO_BIN/jq"
ln -sf "$BIN_DIR/cargo" "$NOCARGO_BIN/cargo"
: >"$ARGS_LOG"
set +e
( cd "$REPO" && env -i HOME="$TMP_ROOT" PATH="$NOCARGO_BIN" FAKE_ARGS_LOG="$ARGS_LOG" \
  "$NOCARGO_BIN/bash" "$HOOK" <<<'{}' ) >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "rc=$rc first=$(first_line) cargo=$(cat "$ARGS_LOG")" \
  "rc=0 first=task-completed-check: missing-tools=jq cargo=" \
  "a missing jq completes unchecked under a notice naming it, before cargo runs"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
