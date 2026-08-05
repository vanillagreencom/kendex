#!/usr/bin/env bash
# #856: a rebase replaces a configured symlink with a real directory holding
# only the tracked files underneath, dropping every vstack-installed path there.
# git sees nothing (the surviving files are the tracked ones), so the damage
# surfaces much later as scripts failing exit 127 on files they used to source.
#
# Two detections are asserted here:
#   1. the support-library guard, which is where the live incident actually
#      presented — a bare 127 naming neither cause nor recovery;
#   2. the use-time check on `push`, the usual first command after a MANUAL
#      rebase (the case the script never sees and therefore never repairs).
#
# Both messages must send the operator to the MAIN CHECKOUT: in the observed
# incident the worktree's own copy of the script was among the missing files.
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
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
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

# Two entries cover both provisioning modes: harness/ mixes untracked
# vstack-installed content with a tracked file (per-child links since VST-37),
# runtime/ is untracked-only (plain parent symlink — the shape a rebase can
# still materialize).
mkdir -p "$MAIN/harness/skills" "$MAIN/runtime"
printf 'harness/**\n!harness/tracked.md\nruntime/\n' >"$MAIN/.gitignore"
printf 'installed\n' >"$MAIN/harness/skills/installed.txt"
printf 'tracked\n' >"$MAIN/harness/tracked.md"
printf 'state\n' >"$MAIN/runtime/state.json"
printf 'WORKTREE_SYMLINKS="harness runtime"\n' >"$MAIN/.env"
git -C "$MAIN" add .gitignore harness/tracked.md
git -C "$MAIN" commit -q -m harness
git -C "$MAIN" push -q origin main

WT="$(cd "$MAIN" && "$WORKTREE_SCRIPT" create mat-check 2>/dev/null | tail -1)"

echo "=== baseline: links exist and push does not cry wolf ==="
if [[ -L "$WT/runtime" ]]; then ok "runtime is a symlink after create"; else bad "runtime is a symlink after create"; fi
# The tracked-content entry is a real directory with per-child links (VST-37),
# and must NOT read as materialization damage.
if [[ -d "$WT/harness" && ! -L "$WT/harness" && -L "$WT/harness/skills" ]]; then
  ok "harness is a real dir with per-child links after create"
else
  bad "harness is a real dir with per-child links after create"
fi
set +e
clean_out="$(cd "$MAIN" && "$WORKTREE_SCRIPT" push mat-check --no-rebase 2>&1)"
set -e
assert_lacks "$clean_out" "not symlinks" "no materialization warning on a healthy worktree"

echo "=== push warns when a link has been materialized ==="
# Exactly what a rebase leaves behind: a real directory where the parent
# symlink belongs, with the installed content gone.
rm -f "$WT/runtime"
mkdir -p "$WT/runtime"
set +e
warn_out="$(cd "$MAIN" && "$WORKTREE_SCRIPT" push mat-check --no-rebase 2>&1)"
set -e
assert_contains "$warn_out" "not symlinks" "push reports materialized harness paths"
assert_contains "$warn_out" "runtime" "the warning names the affected path"
assert_contains "$warn_out" "FROM THE MAIN CHECKOUT" "the warning sends the operator to the main checkout"
assert_contains "$warn_out" "fix-links" "the warning names the recovery command"

echo "=== fix-links from the main checkout restores it ==="
(cd "$MAIN" && "$WORKTREE_SCRIPT" fix-links "$WT" >/dev/null 2>&1)
if [[ -L "$WT/runtime" ]]; then ok "fix-links restores the symlink"; else bad "fix-links restores the symlink"; fi

echo "=== a deleted per-child link is restored by fix-links ==="
rm -f "$WT/harness/skills"
(cd "$MAIN" && "$WORKTREE_SCRIPT" fix-links "$WT" >/dev/null 2>&1)
if [[ -L "$WT/harness/skills" && -f "$WT/harness/skills/installed.txt" ]]; then
  ok "fix-links restores the per-child link"
else
  bad "fix-links restores the per-child link"
fi

echo "=== a missing support library fails loudly, not with a bare 127 ==="
# The live incident's actual shape: the script's own lib vanished with the rest
# of the installed tree, so it died before it could diagnose anything.
BROKEN="$TMP_ROOT/broken"
mkdir -p "$BROKEN/scripts/lib"
cp "$SKILL_DIR/scripts/worktree" "$BROKEN/scripts/worktree"
chmod +x "$BROKEN/scripts/worktree"
set +e
lib_out="$(cd "$MAIN" && "$BROKEN/scripts/worktree" list 2>&1)"
lib_rc=$?
set -e
if [[ "$lib_rc" -ne 0 ]]; then ok "missing library exits non-zero"; else bad "missing library exits non-zero" "rc=0"; fi
assert_contains "$lib_out" "support library is missing" "names the missing library"
assert_contains "$lib_out" "materialized" "explains the cause"
assert_contains "$lib_out" "FROM THE MAIN CHECKOUT" "sends the operator to the main checkout"
assert_lacks "$lib_out" "No such file or directory" "does not surface bash's bare sourcing error"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
