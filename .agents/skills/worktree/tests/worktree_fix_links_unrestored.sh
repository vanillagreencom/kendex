#!/usr/bin/env bash
# KEN-464: `fix-links` printed "Restored symlinks" and exited 0 for paths it had
# not restored. The sync errors that name fix-links as their remediation are
# re-triggered by exactly those paths, so the operator looped on a command that
# reported success and changed nothing.
#
# Ways a path survives a pass unrestored, all silent before this:
#   1. no such path in the MAIN checkout — setup skips the entry outright;
#   2. a materialized child holding data git does not track — the safety check
#      refuses to destroy it and leaves the real path in place;
#   3. a WORKTREE_RELATIVE_SYMLINKS entry the pass could not create at all;
#   4. a link that exists but resolves somewhere other than its configured
#      target.
# Each must now name the path and exit non-zero, and a healthy worktree must
# still report success (the must-fail control for the check itself).
#
# 3 and 4 are also the two shapes a materialization detector cannot see: it
# reports an untracked child only when one EXISTS as a non-symlink, so an
# absent link and a wrong-target link both read healthy through it.
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

write_base_env() {
  printf '%s\n%s\n' \
    'WORKTREE_SYMLINKS="harness runtime"' \
    'WORKTREE_RELATIVE_SYMLINKS=".claude/CLAUDE.md=../AGENTS.md"' >"$MAIN/.env.local"
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
# AGENTS.md is the relative entry's target, resolved from inside the worktree.
# notes.md is a tracked regular FILE, used further down as a parent no link can
# be created under.
printf 'agents\n' >"$MAIN/AGENTS.md"
printf 'notes\n' >"$MAIN/notes.md"
write_base_env
git -C "$MAIN" add .gitignore harness/tracked.md AGENTS.md notes.md
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
if [[ "$(readlink "$WT/.claude/CLAUDE.md" 2>/dev/null || true)" == "../AGENTS.md" ]]; then
  ok "the relative entry is set up, and reads healthy"
else
  bad "the relative entry is set up, and reads healthy" "readlink: $(readlink "$WT/.claude/CLAUDE.md" 2>/dev/null || echo absent)"
fi

echo "=== an entry with no source in the main checkout is named, not skipped ==="
printf '%s\n%s\n' \
  'WORKTREE_SYMLINKS="harness runtime absent-here"' \
  'WORKTREE_RELATIVE_SYMLINKS=".claude/CLAUDE.md=../AGENTS.md"' >"$MAIN/.env.local"
run_fix_links
if [[ "$RC" != 0 ]]; then ok "nonzero exit for an entry missing from the main checkout"; else bad "nonzero exit for an entry missing from the main checkout" "rc=0: $OUT"; fi
assert_contains "$OUT" "absent-here" "names the skipped entry"
assert_contains "$OUT" "no such path in the main checkout" "explains why it was skipped"
assert_lacks "$OUT" "Restored symlinks" "no success message when an entry was skipped"
write_base_env

echo "=== a child left materialized by the safety check is named ==="
# Replace the per-child link with a real directory holding a file git does not
# track: the repair refuses to destroy it and leaves the path real.
rm -f "$WT/harness/skills"
mkdir -p "$WT/harness/skills"
printf 'work in progress\n' >"$WT/harness/skills/untracked-work.txt"
run_fix_links
if [[ "$RC" != 0 ]]; then ok "nonzero exit for an unsafe materialized child"; else bad "nonzero exit for an unsafe materialized child" "rc=0: $OUT"; fi
assert_contains "$OUT" "harness/skills" "names the blocked child"
assert_lacks "$OUT" "Restored symlinks" "no success message while a path stays materialized"
if [[ -f "$WT/harness/skills/untracked-work.txt" ]]; then ok "untracked data is left intact"; else bad "untracked data is left intact"; fi

echo "=== clearing the blocker makes the same command succeed ==="
rm -rf "$WT/harness/skills"
run_fix_links
if [[ "$RC" == 0 ]]; then ok "exit 0 once the blocker is cleared"; else bad "exit 0 once the blocker is cleared" "rc=$RC: $OUT"; fi
assert_contains "$OUT" "Restored symlinks in $WT" "success message once every entry is healthy"
if [[ -L "$WT/harness/skills" ]]; then ok "the child link is restored"; else bad "the child link is restored"; fi

echo "=== a relative entry the pass could not create is named ==="
# notes.md is a tracked regular file, so notes.md/link cannot be created: the
# mkdir and the ln both fail. Those two calls were unchecked, and fix-links
# invokes setup on the left of || — which disables errexit inside it — so the
# exclude update that followed supplied the exit status and the run read as
# clean. The postcondition inspected WORKTREE_SYMLINKS only, so it said nothing
# either.
printf '%s\n%s\n' \
  'WORKTREE_SYMLINKS="harness runtime"' \
  'WORKTREE_RELATIVE_SYMLINKS="notes.md/link=../base.txt"' >"$MAIN/.env.local"
run_fix_links
if [[ "$RC" != 0 ]]; then ok "nonzero exit for a relative entry that could not be created"; else bad "nonzero exit for a relative entry that could not be created" "rc=0: $OUT"; fi
assert_contains "$OUT" "notes.md/link" "names the relative entry"
assert_lacks "$OUT" "Restored symlinks" "no success message for an uncreated relative entry"
write_base_env

echo "=== a link resolving somewhere other than its configured target is named ==="
if [[ "${EUID:-$(id -u)}" == 0 ]]; then
  echo "  skip  wrong-target case needs an unwritable directory (running as root)"
else
  # Point the link at the wrong target and take write permission off its
  # parent so the pass cannot rewrite it. Without the read-only parent setup
  # simply relinks and the state is healthy again — what is being proved is
  # that a wrong-target link is JUDGED unhealthy, not that fix-links fails to
  # repair one.
  rm -f "$WT/.claude/CLAUDE.md"
  ln -s ../notes.md "$WT/.claude/CLAUDE.md"
  chmod a-w "$WT/.claude"
  run_fix_links
  chmod u+w "$WT/.claude"
  if [[ "$RC" != 0 ]]; then ok "nonzero exit for a link with the wrong target"; else bad "nonzero exit for a link with the wrong target" "rc=0: $OUT"; fi
  assert_contains "$OUT" ".claude/CLAUDE.md" "names the wrong-target link"
  assert_contains "$OUT" "expected ../AGENTS.md" "states the target it expected"
  assert_lacks "$OUT" "Restored symlinks" "no success message for a wrong-target link"
  rm -f "$WT/.claude/CLAUDE.md"
fi

echo "=== the worktree is healthy again once nothing blocks the pass ==="
run_fix_links
if [[ "$RC" == 0 ]]; then ok "exit 0 after the blockers are cleared"; else bad "exit 0 after the blockers are cleared" "rc=$RC: $OUT"; fi
assert_contains "$OUT" "Restored symlinks in $WT" "success message once every entry is healthy again"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
