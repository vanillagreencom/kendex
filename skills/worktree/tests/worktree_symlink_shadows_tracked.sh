#!/usr/bin/env bash
# A WORKTREE_SYMLINKS directory entry that contains tracked files must not be
# linked wholesale: that shadowed the tracked files behind assume-unchanged, so
# git could not write them (cherry-pick/checkout/merge failed while status
# looked clean). Setup now ACTS on its detection (VST-37): the entry stays a
# real directory, tracked paths stay real files git owns, and only the
# UNTRACKED children are symlinked — recursing through children that mix
# tracked and untracked content. A fully untracked entry keeps the plain
# parent symlink.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_ok() {
  local name="$1"
  PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
}

assert_fail() {
  local name="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$name"
  [[ -n "$detail" ]] && printf '        %s\n' "$detail"
}

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    assert_ok "$name"
  else
    assert_fail "$name" "want: $want | got: $got"
  fi
}

assert_lacks() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    assert_fail "$name" "unexpected substring: $needle"
  else
    assert_ok "$name"
  fi
}

assert_symlink() {
  local path="$1" name="$2"
  if [[ -L "$path" ]]; then assert_ok "$name"; else assert_fail "$name" "not a symlink: $path"; fi
}

assert_real() {
  local path="$1" name="$2"
  if [[ -e "$path" && ! -L "$path" ]]; then assert_ok "$name"; else assert_fail "$name" "not a real path: $path"; fi
}

# No open PRs in this file; ownership signals are local/remote refs only.
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

push_main() {
  git -C "$1/main" push -q origin main
}

echo "=== an entry shadowing a tracked subtree gets per-child links, not assume-unchanged ==="

SHADOW_ROOT="$TMP_ROOT/shadow"
make_repo "$SHADOW_ROOT"
# .agents mixes runtime (ignored) content with a tracked subtree — the vendored
# review-gate shape: `.agents/skills/review-gate` is committed while the other
# skills and runtime state are vstack-installed.
mkdir -p "$SHADOW_ROOT/main/.agents/skills/review-gate"
mkdir -p "$SHADOW_ROOT/main/.agents/skills/deep-research"
printf '.agents/**\n!.agents/skills/\n!.agents/skills/review-gate/\n!.agents/skills/review-gate/**\n' >"$SHADOW_ROOT/main/.gitignore"
printf 'runtime\n' >"$SHADOW_ROOT/main/.agents/state.json"
printf 'engine v1\n' >"$SHADOW_ROOT/main/.agents/skills/review-gate/engine.md"
printf 'installed skill\n' >"$SHADOW_ROOT/main/.agents/skills/deep-research/SKILL.md"
printf 'WORKTREE_SYMLINKS=".agents"\n' >"$SHADOW_ROOT/main/.env"
git -C "$SHADOW_ROOT/main" add .gitignore .agents/skills/review-gate/engine.md
git -C "$SHADOW_ROOT/main" commit -q -m 'vendor review-gate'
push_main "$SHADOW_ROOT"

set +e
WT="$( (cd "$SHADOW_ROOT/main" && "$WORKTREE_SCRIPT" create shadow-check) 2>"$SHADOW_ROOT/err" )"
create_status=$?
set -e
shadow_err="$(cat "$SHADOW_ROOT/err")"

assert_eq "$create_status" "0" "create succeeds"
[[ -n "$WT" && -d "$WT" ]] || { echo "FATAL: worktree not created: $shadow_err"; exit 1; }

# The entry and the tracked subtree are real directories git can write through;
# the tracked file is git's own copy, not a link into main.
assert_real "$WT/.agents" "the entry is a real directory"
assert_real "$WT/.agents/skills" "the mixed subtree is a real directory"
assert_real "$WT/.agents/skills/review-gate/engine.md" "the tracked file is a real file"
assert_eq "$(cat "$WT/.agents/skills/review-gate/engine.md")" "engine v1" "the tracked file has the branch's content"

# The untracked children still arrive, as individual links.
assert_symlink "$WT/.agents/state.json" "an untracked child of the entry is symlinked"
assert_symlink "$WT/.agents/skills/deep-research" "an untracked child of the mixed subtree is symlinked"
assert_eq "$(cat "$WT/.agents/skills/deep-research/SKILL.md")" "installed skill" "the linked child resolves to main's content"

# No assume-unchanged bits: git owns the tracked paths outright.
assert_lacks "$(git -C "$WT" ls-files -v -- .agents/ | grep '^[a-z]' || true)" "engine.md" \
  "no tracked file under the entry is assume-unchanged"
assert_lacks "$shadow_err" "assume-unchanged" "no assume-unchanged advice is printed"
assert_eq "$(git -C "$WT" status --porcelain)" "" "git status is clean"

# The proof of the fix: git can WRITE the tracked subtree in this worktree.
# Advance the vendored file on main and merge it into the worktree branch —
# exactly the flow assume-unchanged used to break.
printf 'engine v2\n' >"$SHADOW_ROOT/main/.agents/skills/review-gate/engine.md"
git -C "$SHADOW_ROOT/main" add -f .agents/skills/review-gate/engine.md
git -C "$SHADOW_ROOT/main" commit -q -m 'refresh vendored engine'
push_main "$SHADOW_ROOT"

set +e
git -C "$WT" fetch -q origin
merge_out="$(git -C "$WT" merge --no-edit origin/main 2>&1)"
merge_status=$?
set -e
assert_eq "$merge_status" "0" "a merge updating the tracked subtree succeeds"
assert_eq "$(cat "$WT/.agents/skills/review-gate/engine.md")" "engine v2" "the merge wrote the tracked file"
assert_symlink "$WT/.agents/state.json" "the per-child link survives the merge"

echo "=== re-running setup on the per-child layout is idempotent ==="

set +e
(cd "$SHADOW_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$WT") >/dev/null 2>"$SHADOW_ROOT/err2"
fixlinks_status=$?
set -e
assert_eq "$fixlinks_status" "0" "fix-links succeeds on the per-child layout"
assert_lacks "$(cat "$SHADOW_ROOT/err2")" "Warning" "fix-links stays quiet on the healthy per-child layout"
assert_real "$WT/.agents/skills/review-gate/engine.md" "the tracked file is still a real file"
assert_eq "$(cat "$WT/.agents/skills/review-gate/engine.md")" "engine v2" "the tracked content survives fix-links"
assert_symlink "$WT/.agents/state.json" "the per-child link survives fix-links"
assert_eq "$(git -C "$WT" status --porcelain)" "" "git status is clean after fix-links"

echo "=== a legacy parent link over tracked files heals to the per-child layout ==="

# Model a worktree provisioned by the OLD behavior: parent symlink over the
# entry, tracked files assume-unchanged and unwritable.
rm -rf "$WT/.agents"
ln -s "$SHADOW_ROOT/main/.agents" "$WT/.agents"
git -C "$WT" update-index --assume-unchanged .agents/skills/review-gate/engine.md

set +e
(cd "$SHADOW_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$WT") >/dev/null 2>&1
legacy_status=$?
set -e
assert_eq "$legacy_status" "0" "fix-links succeeds on the legacy parent-link layout"
assert_real "$WT/.agents" "the legacy parent link became a real directory"
assert_real "$WT/.agents/skills/review-gate/engine.md" "the shadowed tracked file was restored as a real file"
assert_lacks "$(git -C "$WT" ls-files -v -- .agents/ | grep '^[a-z]' || true)" "engine.md" \
  "the stale assume-unchanged bit was cleared"
assert_symlink "$WT/.agents/state.json" "untracked children are linked after the heal"

echo "=== a fully untracked entry keeps the plain parent symlink ==="

CLEAN_ROOT="$TMP_ROOT/clean"
make_repo "$CLEAN_ROOT"
mkdir -p "$CLEAN_ROOT/main/runtime"
printf 'runtime/\n' >"$CLEAN_ROOT/main/.gitignore"
printf 'state\n' >"$CLEAN_ROOT/main/runtime/state.json"
printf 'WORKTREE_SYMLINKS="runtime"\n' >"$CLEAN_ROOT/main/.env"
git -C "$CLEAN_ROOT/main" add .gitignore
git -C "$CLEAN_ROOT/main" commit -q -m runtime
push_main "$CLEAN_ROOT"

set +e
CLEAN_WT="$( (cd "$CLEAN_ROOT/main" && "$WORKTREE_SCRIPT" create clean-check) 2>"$CLEAN_ROOT/err" )"
clean_status=$?
set -e

assert_eq "$clean_status" "0" "create succeeds for the untracked entry"
assert_symlink "$CLEAN_WT/runtime" "an entry with no tracked files is still one parent symlink"
assert_lacks "$(cat "$CLEAN_ROOT/err")" "shadows" "no warning when the entry tracks nothing"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
