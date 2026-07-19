#!/usr/bin/env bash
# Regression tests for the pre-commit-check hook's Rust Clippy lane (vstack#737).
#
# The hook previously hard-coded `cargo clippy --workspace --all-targets`
# with stderr discarded, so commits failed on pre-existing warnings in
# unrelated crates with no actionable output and no way to configure the
# lane. These tests assert the three-tier VSTACK_PRE_COMMIT_RUST_CLIPPY
# semantics (unset -> package-scoped default, "off" -> skip, custom -> run
# verbatim via bash -c), the vstack.settings.toml fallback, the --workspace
# fallback when no package resolves, the nested-manifest --manifest-path
# behavior, and that fmt/clippy diagnostics now reach stderr on failure.
#
# `cargo` is stubbed with a PATH shim that records invocations, so the suite
# needs no Rust toolchain or real workspace.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$TEST_DIR/.." && pwd)/pre-commit-check.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

CARGO_LOG="$TMP_ROOT/cargo.log"
ERR_FILE="$TMP_ROOT/stderr"

# --- cargo PATH shim ---------------------------------------------------------
BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/cargo" <<'EOF'
#!/usr/bin/env bash
echo "cargo $*" >>"$CARGO_LOG"
case "$1" in
  fmt)
    if [ "${CARGO_FMT_EXIT:-0}" != "0" ]; then
      echo "Diff in src/lib.rs at line 1:" >&2
    fi
    exit "${CARGO_FMT_EXIT:-0}"
    ;;
  clippy)
    if [ "${CARGO_CLIPPY_EXIT:-0}" != "0" ]; then
      echo "error: strict comparison of f32 or f64 (clippy::float_cmp)" >&2
      echo " --> src/lib.rs:1:1" >&2
    fi
    exit "${CARGO_CLIPPY_EXIT:-0}"
    ;;
esac
exit 0
EOF
chmod +x "$BIN_DIR/cargo"

# Run the hook from inside a fixture repo with a git-commit tool command on
# stdin. Extra env assignments come as VAR=value args; the override var is
# scrubbed from the parent environment first so only explicit settings apply.
# Captures stdout in $out, stderr in $err, exit code in $rc; truncates the
# shim log before each run.
run_hook() {
  local repo="$1"
  shift
  : >"$CARGO_LOG"
  set +e
  out=$( (cd "$repo" && env -u VSTACK_PRE_COMMIT_RUST_CLIPPY \
    PATH="$BIN_DIR:$PATH" CARGO_LOG="$CARGO_LOG" "$@" \
    bash "$HOOK" <<<'{"command": "git commit -m test"}') 2>"$ERR_FILE")
  rc=$?
  set -e
  err="$(cat "$ERR_FILE")"
  log="$(cat "$CARGO_LOG" 2>/dev/null || true)"
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

assert_not_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected NOT to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
}

# --- Fixture A: workspace root manifest + two member crates ------------------
REPO_A="$TMP_ROOT/workspace-repo"
make_repo "$REPO_A"
cat >"$REPO_A/Cargo.toml" <<'EOF'
[workspace]
members = ["crates/foo", "crates/bar"]
EOF
mkdir -p "$REPO_A/crates/foo/src" "$REPO_A/crates/bar/src"
cat >"$REPO_A/crates/foo/Cargo.toml" <<'EOF'
[package]
name = "foo"
version = "0.1.0"

[[bin]]
name = "foo-bin"
EOF
cat >"$REPO_A/crates/bar/Cargo.toml" <<'EOF'
[package]
name = "bar"
version = "0.1.0"
EOF
echo 'pub fn a() {}' >"$REPO_A/crates/foo/src/lib.rs"
echo 'pub fn b() {}' >"$REPO_A/crates/foo/src/extra.rs"
echo 'pub fn c() {}' >"$REPO_A/crates/bar/src/lib.rs"
git -C "$REPO_A" add -A

echo "=== pre-commit-check Rust clippy lane (vstack#737) ==="

# --- Default: package-scoped clippy ------------------------------------------
run_hook "$REPO_A"
assert_eq "$rc" "0" "default run with clean shims exits 0"
assert_contains "$log" "cargo fmt --check" "fmt lane still runs"
assert_contains "$log" "cargo clippy -p bar -p foo --all-targets -- -D warnings" \
  "default clippy is scoped to staged packages, deduped and sorted"
assert_not_contains "$log" "--workspace" "default clippy does not use --workspace when packages resolve"

# --- Workspace fallback when no package name resolves ------------------------
REPO_B="$TMP_ROOT/virtual-repo"
make_repo "$REPO_B"
cat >"$REPO_B/Cargo.toml" <<'EOF'
[workspace]
members = []
EOF
mkdir -p "$REPO_B/src"
echo 'fn main() {}' >"$REPO_B/src/main.rs"
git -C "$REPO_B" add -A

run_hook "$REPO_B"
assert_eq "$rc" "0" "virtual-manifest run exits 0"
assert_contains "$log" "cargo clippy --workspace --all-targets -- -D warnings" \
  "clippy falls back to --workspace when no package resolves"

# --- Nested manifest keeps --manifest-path and gains -p scoping --------------
REPO_C="$TMP_ROOT/nested-repo"
make_repo "$REPO_C"
mkdir -p "$REPO_C/cli/src"
cat >"$REPO_C/cli/Cargo.toml" <<'EOF'
[package]
name = "nested-cli"
version = "0.1.0"
EOF
echo 'fn main() {}' >"$REPO_C/cli/src/main.rs"
git -C "$REPO_C" add -A

REPO_C_PHYS="$(cd "$REPO_C" && pwd -P)"
run_hook "$REPO_C"
assert_eq "$rc" "0" "nested-manifest run exits 0"
assert_contains "$log" "cargo fmt --manifest-path $REPO_C_PHYS/cli/Cargo.toml --check" \
  "fmt uses the nested manifest path"
assert_contains "$log" "cargo clippy --manifest-path $REPO_C_PHYS/cli/Cargo.toml -p nested-cli --all-targets -- -D warnings" \
  "clippy combines nested manifest path with package scoping"

# --- Env override: run verbatim via bash -c ----------------------------------
REPO_A_PHYS="$(cd "$REPO_A" && pwd -P)"
run_hook "$REPO_A" VSTACK_PRE_COMMIT_RUST_CLIPPY='echo "override-ran $PWD" >>"$CARGO_LOG"'
assert_eq "$rc" "0" "passing env override exits 0"
assert_contains "$log" "override-ran $REPO_A_PHYS" "override command runs verbatim from the repo root"
assert_not_contains "$log" "cargo clippy" "override replaces the default clippy invocation"

run_hook "$REPO_A" VSTACK_PRE_COMMIT_RUST_CLIPPY='false'
assert_eq "$rc" "2" "failing env override exits 2"
assert_contains "$err" "configured Clippy check failed" "failing override reports the configured command"

# --- off: skip the clippy lane entirely --------------------------------------
run_hook "$REPO_A" VSTACK_PRE_COMMIT_RUST_CLIPPY=off
assert_eq "$rc" "0" "off exits 0"
assert_contains "$log" "cargo fmt --check" "off still runs the fmt lane"
assert_not_contains "$log" "clippy" "off skips clippy entirely"

# --- Settings-file fallback ---------------------------------------------------
cat >"$REPO_A/vstack.settings.toml" <<EOF
[env]
VSTACK_PRE_COMMIT_RUST_CLIPPY = "echo settings-ran >>\$CARGO_LOG"
EOF
run_hook "$REPO_A"
assert_eq "$rc" "0" "settings-file override exits 0"
assert_contains "$log" "settings-ran" "settings-file [env] value is parsed and run"
assert_not_contains "$log" "cargo clippy" "settings-file override replaces the default clippy invocation"

# Env var wins over the settings file.
run_hook "$REPO_A" VSTACK_PRE_COMMIT_RUST_CLIPPY='echo env-wins >>"$CARGO_LOG"'
assert_contains "$log" "env-wins" "env override takes precedence over settings file"
assert_not_contains "$log" "settings-ran" "settings value ignored when env override is set"

printf '[env]\nVSTACK_PRE_COMMIT_RUST_CLIPPY = "off"\n' >"$REPO_A/vstack.settings.toml"
run_hook "$REPO_A"
assert_eq "$rc" "0" "settings-file off exits 0"
assert_not_contains "$log" "clippy" "settings-file off skips clippy"
rm "$REPO_A/vstack.settings.toml"

# --- Diagnostics reach stderr on failure -------------------------------------
run_hook "$REPO_A" CARGO_CLIPPY_EXIT=1
assert_eq "$rc" "2" "clippy failure exits 2"
assert_contains "$err" "clippy::float_cmp" "clippy diagnostics are no longer swallowed"
assert_contains "$err" "cargo clippy found warnings" "clippy guidance line still present"

run_hook "$REPO_A" CARGO_FMT_EXIT=1
assert_eq "$rc" "2" "fmt failure exits 2"
assert_contains "$err" "Diff in src/lib.rs" "fmt diagnostics are no longer swallowed"
assert_contains "$err" "cargo fmt --check failed" "fmt guidance line still present"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
