#!/usr/bin/env bash
# #857: replacing a configured symlink must not leave the destination absent,
# so the swap goes through a pre-built temp link and a rename. The hazard that
# introduces is following a symlinked-to-directory destination — a plain `mv`
# deposits the temp link INSIDE the target instead of replacing it, which is
# why the swap needs `mv -T` (GNU) / `mv -h` (BSD). These assertions fail on a
# naive rename just as loudly as on a regression to the old rm+ln pair.
#
# #860: `claude-setup` / `claude-cleanup` must provide the same provisioning
# and teardown semantics as the Codex pair, for worktrees Claude Code creates
# itself via its WorktreeCreate hook.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

assert_symlink() {
  local path="$1" name="$2"
  if [[ -L "$path" ]]; then ok "$name"; else bad "$name" "not a symlink: $path"; fi
}

assert_missing() {
  local path="$1" name="$2"
  if [[ -e "$path" || -L "$path" ]]; then bad "$name" "unexpectedly exists: $path"; else ok "$name"; fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then ok "$name"; else bad "$name" "wanted: $needle"; fi
}

mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

make_repo() {
  local root="$1"
  mkdir -p "$root/main"
  git -C "$root/main" init -q -b main
  git -C "$root/main" config user.email test@example.com
  git -C "$root/main" config user.name Test
  git -C "$root/main" config commit.gpgsign false
  printf 'base\n' >"$root/main/base.txt"
  git -C "$root/main" add base.txt
  git -C "$root/main" commit -q -m base
  git init -q --bare "$root/origin.git"
  git -C "$root/main" remote add origin "$root/origin.git"
  git -C "$root/main" push -q -u origin main
}

ROOT="$TMP_ROOT/repo"
make_repo "$ROOT"
MAIN="$ROOT/main"
mkdir -p "$MAIN/runtime"
printf 'runtime/\nharnessrc\n' >"$MAIN/.gitignore"
printf 'state\n' >"$MAIN/runtime/state.json"
printf 'rc\n' >"$MAIN/harnessrc"
printf 'WORKTREE_SYMLINKS="runtime harnessrc"\n' >"$MAIN/.env"
git -C "$MAIN" add .gitignore
git -C "$MAIN" commit -q -m ignore
git -C "$MAIN" push -q origin main

WT="$(cd "$MAIN" && "$WORKTREE_SCRIPT" create swap-check 2>/dev/null | tail -1)"

echo "=== baseline: create links both a directory and a file entry ==="
# Power check for everything below: if these are not symlinks to begin with,
# the replacement assertions would pass trivially on a broken implementation.
assert_symlink "$WT/runtime" "directory entry is a symlink"
assert_symlink "$WT/harnessrc" "file entry is a symlink"

echo "=== replacing an existing symlink-to-dir must not nest inside the target ==="
(cd "$MAIN" && "$WORKTREE_SCRIPT" fix-links "$WT" >/dev/null 2>&1)
assert_symlink "$WT/runtime" "directory entry is still a symlink after re-link"
# The naive-`mv` failure mode, and the whole reason the swap needs -T/-h: a
# `mv` that follows the symlinked destination deposits the temp link INSIDE the
# target directory (as runtime.wt-tmp.NNN, not as "runtime" — checking for the
# latter is an assertion that can never fire).
nested="$(find "$MAIN/runtime" -maxdepth 1 -type l 2>/dev/null || true)"
if [[ -z "$nested" ]]; then
  ok "no link deposited inside the symlink target"
else
  bad "no link deposited inside the symlink target" "$nested"
fi
assert_symlink "$WT/harnessrc" "file entry survives re-link"

echo "=== the swap leaves no temp artifacts behind ==="
leftovers="$(find "$WT" "$MAIN" -maxdepth 2 -name '*.wt-tmp.*' 2>/dev/null || true)"
if [[ -z "$leftovers" ]]; then ok "no .wt-tmp.* residue"; else bad "no .wt-tmp.* residue" "$leftovers"; fi

echo "=== a materialized real directory is reconciled back to a symlink ==="
# What a rebase does when tracked files exist under the symlinked path: the
# symlink becomes a real directory holding only the tracked subset.
rm -f "$WT/runtime"
mkdir -p "$WT/runtime"
printf 'partial\n' >"$WT/runtime/leftover.txt"
(cd "$MAIN" && "$WORKTREE_SCRIPT" fix-links "$WT" >/dev/null 2>&1)
assert_symlink "$WT/runtime" "real directory replaced by a symlink"
assert_missing "$MAIN/runtime/leftover.txt" "materialized content was not copied into the source"

echo "=== #860: claude-setup restores provisioning like codex-setup ==="
rm -f "$WT/runtime" "$WT/harnessrc"
set +e
claude_out="$(cd "$MAIN" && "$WORKTREE_SCRIPT" claude-setup "$WT" 2>&1)"
claude_rc=$?
set -e
if [[ "$claude_rc" -eq 0 ]]; then ok "claude-setup exits 0"; else bad "claude-setup exits 0" "rc=$claude_rc: $claude_out"; fi
assert_contains "$claude_out" "Configured Claude worktree" "claude-setup reports what it configured"
assert_symlink "$WT/runtime" "claude-setup restored the directory symlink"
assert_symlink "$WT/harnessrc" "claude-setup restored the file symlink"

echo "=== #860: claude-setup refuses the main checkout ==="
set +e
main_out="$(cd "$MAIN" && "$WORKTREE_SCRIPT" claude-setup "$MAIN" 2>&1)"
main_rc=$?
set -e
if [[ "$main_rc" -ne 0 ]]; then ok "claude-setup refuses the main checkout"; else bad "claude-setup refuses the main checkout" "exited 0: $main_out"; fi

echo "=== #860: claude-cleanup is non-destructive ==="
set +e
cleanup_out="$(cd "$MAIN" && "$WORKTREE_SCRIPT" claude-cleanup "$WT" 2>&1)"
cleanup_rc=$?
set -e
if [[ "$cleanup_rc" -eq 0 ]]; then ok "claude-cleanup exits 0"; else bad "claude-cleanup exits 0" "rc=$cleanup_rc: $cleanup_out"; fi
assert_symlink "$WT/runtime" "claude-cleanup left the symlink in place"

echo "=== usage lists the new entry points ==="
set +e
usage_out="$(cd "$MAIN" && "$WORKTREE_SCRIPT" definitely-not-a-command 2>&1)"
set -e
assert_contains "$usage_out" "claude-setup" "usage names claude-setup"
assert_contains "$usage_out" "claude-cleanup" "usage names claude-cleanup"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
