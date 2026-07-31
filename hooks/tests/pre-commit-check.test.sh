#!/usr/bin/env bash
# Regression tests for the pre-commit-check hook's Rust Clippy lane
# (vstack#737, vstack#742).
#
# The hook previously hard-coded `cargo clippy --workspace --all-targets`
# with stderr discarded, so commits failed on pre-existing warnings in
# unrelated crates with no actionable output and no way to configure the
# lane. These tests assert the three-tier VSTACK_PRE_COMMIT_RUST_CLIPPY
# semantics (unset -> per-owning-manifest default, "off" -> skip, custom ->
# run verbatim via bash -c), the vstack.settings.toml fallback, the
# --workspace fallback when no owning manifest resolves, the
# nested-manifest behavior, that workspace-excluded crates lint against
# their own manifest instead of failing `-p` resolution (vstack#742), and
# that fmt/clippy diagnostics reach stderr on failure.
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

# --- biome PATH shim ---------------------------------------------------------
# Mimics the real binary's exit-non-zero-when-every-path-is-ignored behavior, so
# the suite needs no Node install. It fails exactly as biome does UNLESS
# --no-errors-on-unmatched is passed, which is the whole point of the flag.
cat >"$BIN_DIR/biome" <<'EOF'
#!/usr/bin/env bash
echo "biome $*" >>"$CARGO_LOG"
unmatched_ok=0
for arg in "$@"; do
  [ "$arg" = "--no-errors-on-unmatched" ] && unmatched_ok=1
done
# The flag suppresses ONLY the every-path-ignored exit, never a real finding.
if [ "${BIOME_ALL_PATHS_IGNORED:-0}" != "0" ]; then
  [ "$unmatched_ok" = "1" ] && exit 0
  echo "No files were processed in the specified paths." >&2
  exit 1
fi
if [ "${BIOME_EXIT:-0}" != "0" ]; then
  echo "lint error: noUnusedVariables at vendor/bundle.js:1:1" >&2
fi
exit "${BIOME_EXIT:-0}"
EOF
chmod +x "$BIN_DIR/biome"

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
REPO_A_PHYS="$(cd "$REPO_A" && pwd -P)"

echo "=== pre-commit-check Rust clippy lane (vstack#737, vstack#742) ==="

# --- Default: one clippy run per owning manifest ------------------------------
run_hook "$REPO_A"
assert_eq "$rc" "0" "default run with clean shims exits 0"
assert_contains "$log" "cargo fmt --check" "fmt lane still runs"
assert_contains "$log" "cargo clippy --manifest-path $REPO_A_PHYS/crates/bar/Cargo.toml --all-targets -- -D warnings" \
  "default clippy runs against bar's manifest"
assert_contains "$log" "cargo clippy --manifest-path $REPO_A_PHYS/crates/foo/Cargo.toml --all-targets -- -D warnings" \
  "default clippy runs against foo's manifest (deduped across its staged files)"
assert_not_contains "$log" " -p " "default clippy no longer passes -p package args"
assert_not_contains "$log" "--workspace" "default clippy does not use --workspace when manifests resolve"

# --- Workspace fallback when no owning manifest resolves ----------------------
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
  "clippy falls back to --workspace when no owning manifest resolves"

# --- Nested manifest: clippy targets the nested crate's own manifest ----------
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
assert_contains "$log" "cargo clippy --manifest-path $REPO_C_PHYS/cli/Cargo.toml --all-targets -- -D warnings" \
  "clippy targets the nested crate's own manifest"
assert_not_contains "$log" " -p " "nested-manifest clippy passes no -p args"

# --- Workspace-excluded crate lints against its own manifest (vstack#742) -----
REPO_D="$TMP_ROOT/excluded-repo"
make_repo "$REPO_D"
cat >"$REPO_D/Cargo.toml" <<'EOF'
[workspace]
members = ["crates/member"]
exclude = ["standalone"]
EOF
mkdir -p "$REPO_D/crates/member/src" "$REPO_D/standalone/src"
cat >"$REPO_D/crates/member/Cargo.toml" <<'EOF'
[package]
name = "member"
version = "0.1.0"
EOF
cat >"$REPO_D/standalone/Cargo.toml" <<'EOF'
[package]
name = "fixture-generator"
version = "0.1.0"
EOF
echo 'pub fn m() {}' >"$REPO_D/crates/member/src/lib.rs"
echo 'pub fn s() {}' >"$REPO_D/standalone/src/lib.rs"
git -C "$REPO_D" add -A

REPO_D_PHYS="$(cd "$REPO_D" && pwd -P)"
run_hook "$REPO_D"
assert_eq "$rc" "0" "excluded-crate commit is not blocked"
assert_contains "$log" "cargo clippy --manifest-path $REPO_D_PHYS/standalone/Cargo.toml --all-targets -- -D warnings" \
  "excluded crate lints against its own manifest"
assert_contains "$log" "cargo clippy --manifest-path $REPO_D_PHYS/crates/member/Cargo.toml --all-targets -- -D warnings" \
  "member crate staged alongside still gets its own run"
assert_not_contains "$log" " -p " "excluded-crate run passes no -p args"
assert_not_contains "$log" "--workspace" "excluded-crate run does not fall back to --workspace"

# --- Env override: run verbatim via bash -c ----------------------------------
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
assert_contains "$err" "cargo clippy found warnings in $REPO_A_PHYS/crates/bar/Cargo.toml" \
  "clippy guidance names the failing manifest"

run_hook "$REPO_A" CARGO_FMT_EXIT=1
assert_eq "$rc" "2" "fmt failure exits 2"
assert_contains "$err" "Diff in src/lib.rs" "fmt diagnostics are no longer swallowed"
assert_contains "$err" "cargo fmt --check failed" "fmt guidance line still present"

# --- Biome: a commit touching only IGNORED paths is not blocked ---------------
# Real biome exits non-zero when every path it was handed is excluded by
# biome.json ("No files were processed"). Re-vendoring a bundled dependency
# stages exactly that shape, and the files are ignored precisely because they
# must not be linted — so no `biome check --write` can ever clear it.
REPO_E="$TMP_ROOT/biome-repo"
make_repo "$REPO_E"
REPO_E_PHYS="$(cd "$REPO_E" && pwd -P)"
printf '{}\n' >"$REPO_E/biome.json"
mkdir -p "$REPO_E/vendor"
printf 'export const x = 1\n' >"$REPO_E/vendor/bundle.js"
git -C "$REPO_E" add -A
run_hook "$REPO_E" BIOME_ALL_PATHS_IGNORED=1
assert_eq "$rc" "0" "vendor-only commit is not blocked when every staged path is biome-ignored"
assert_contains "$log" "--no-errors-on-unmatched" "biome is invoked with --no-errors-on-unmatched"

# The flag must not turn biome into a rubber stamp: a real finding still blocks.
run_hook "$REPO_E" BIOME_EXIT=1
assert_eq "$rc" "2" "a real biome finding still blocks the commit"
assert_contains "$err" "biome check failed on staged files" "biome guidance line still present"
assert_contains "$err" "noUnusedVariables" "biome diagnostics reach stderr"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
