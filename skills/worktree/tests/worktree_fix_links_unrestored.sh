#!/usr/bin/env bash
# KEN-464: `fix-links` printed "Restored symlinks" and exited 0 for paths it had
# not restored. The sync errors that name fix-links as their remediation are
# re-triggered by exactly those paths, so the operator looped on a command that
# reported success and changed nothing.
#
# Two ways a path survives a pass unrestored, both silent before this:
#   1. no such path in the MAIN checkout — setup skips the entry outright;
#   2. a materialized child holding data git does not track — the quarantine
#      refuses to destroy it and leaves the real path in place.
# Both must now name the path and exit non-zero, and a healthy worktree must
# still report success (the must-fail control for the check itself).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$SKILL_DIR/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then ok "$name"; else bad "$name" "wanted: $needle"; fi
}
assert_lacks() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then bad "$name" "unexpected: $needle"; else ok "$name"; fi
}

mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/bin/gh"
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

ROOT="$TMP_ROOT/repo"
MAIN="$ROOT/main"
mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name Test
git -C "$MAIN" config commit.gpgsign false
printf 'base\n' >"$MAIN/base.txt"
git -C "$MAIN" add base.txt
git -C "$MAIN" commit -q -m base
git init -q --bare "$ROOT/origin.git"
git -C "$MAIN" remote add origin "$ROOT/origin.git"
git -C "$MAIN" push -q -u origin main

# harness/ mixes untracked kendex-installed content with a tracked file, so it
# is provisioned as a real directory with per-child links (VST-37); runtime/ is
# untracked-only, a plain parent symlink. absent-here is configured further
# down but never created in the main checkout.
mkdir -p "$MAIN/harness/skills" "$MAIN/runtime"
printf 'harness/**\n!harness/tracked.md\nruntime/\n' >"$MAIN/.gitignore"
printf 'installed\n' >"$MAIN/harness/skills/installed.txt"
printf 'tracked\n' >"$MAIN/harness/tracked.md"
printf 'state\n' >"$MAIN/runtime/state.json"
printf 'WORKTREE_SYMLINKS="harness runtime"\n' >"$MAIN/.env"
git -C "$MAIN" add .gitignore harness/tracked.md
git -C "$MAIN" commit -q -m harness
git -C "$MAIN" push -q origin main

WT="$(cd "$MAIN" && "$WORKTREE_SCRIPT" create fix-links-check 2>/dev/null | tail -1)"

run_fix_links() {
  set +e
  OUT="$( (cd "$MAIN" && "$WORKTREE_SCRIPT" fix-links "$WT") 2>&1 )"
  RC=$?
  set -e
}

echo "=== a healthy worktree still reports success ==="
run_fix_links
if [[ "$RC" == 0 ]]; then ok "exit 0 when every entry is healthy"; else bad "exit 0 when every entry is healthy" "rc=$RC: $OUT"; fi
assert_contains "$OUT" "Restored symlinks in $WT" "success message on a healthy worktree"

echo "=== an entry with no source in the main checkout is named, not skipped ==="
printf 'WORKTREE_SYMLINKS="harness runtime absent-here"\n' >"$MAIN/.env"
run_fix_links
if [[ "$RC" != 0 ]]; then ok "nonzero exit for an entry missing from the main checkout"; else bad "nonzero exit for an entry missing from the main checkout" "rc=0: $OUT"; fi
assert_contains "$OUT" "absent-here" "names the skipped entry"
assert_contains "$OUT" "no such path in the main checkout" "explains why it was skipped"
assert_lacks "$OUT" "Restored symlinks" "no success message when an entry was skipped"
printf 'WORKTREE_SYMLINKS="harness runtime"\n' >"$MAIN/.env"

echo "=== a child left materialized by the quarantine is named ==="
# Replace the per-child link with a real directory holding a file git does not
# track: the quarantine refuses to destroy it and leaves the path real.
rm -f "$WT/harness/skills"
mkdir -p "$WT/harness/skills"
printf 'work in progress\n' >"$WT/harness/skills/untracked-work.txt"
run_fix_links
if [[ "$RC" != 0 ]]; then ok "nonzero exit for a quarantine-blocked child"; else bad "nonzero exit for a quarantine-blocked child" "rc=0: $OUT"; fi
assert_contains "$OUT" "harness/skills" "names the blocked child"
assert_lacks "$OUT" "Restored symlinks" "no success message while a path stays materialized"
if [[ -f "$WT/harness/skills/untracked-work.txt" ]]; then ok "untracked data is left intact"; else bad "untracked data is left intact"; fi

echo "=== clearing the blocker makes the same command succeed ==="
rm -rf "$WT/harness/skills"
run_fix_links
if [[ "$RC" == 0 ]]; then ok "exit 0 once the blocker is cleared"; else bad "exit 0 once the blocker is cleared" "rc=$RC: $OUT"; fi
assert_contains "$OUT" "Restored symlinks in $WT" "success message once every entry is healthy"
if [[ -L "$WT/harness/skills" ]]; then ok "the child link is restored"; else bad "the child link is restored"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
