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
# skills and runtime state are kendex-installed.
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
[[ "$merge_status" -eq 0 ]] || printf 'merge output:\n%s\n' "$merge_out" >&2
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

echo "=== a tracked leaf name containing a quote is not turned into a link (#875) ==="

# git's default (non -z) ls-files output quotes names with special bytes, so
# comparing that display form against the raw filesystem name misclassifies
# a tracked leaf as untracked and replaces it with a symlink.
QUOTE_ROOT="$TMP_ROOT/quote"
make_repo "$QUOTE_ROOT"
mkdir -p "$QUOTE_ROOT/main/.agents"
printf 'a\n' >"$QUOTE_ROOT/main/.agents/normal.md"
printf 'q\n' >"$QUOTE_ROOT/main/.agents/weird\"quote.md"
printf 'WORKTREE_SYMLINKS=".agents"\n' >"$QUOTE_ROOT/main/.env"
git -C "$QUOTE_ROOT/main" add .agents
git -C "$QUOTE_ROOT/main" commit -q -m quoted
push_main "$QUOTE_ROOT"

set +e
QUOTE_WT="$( (cd "$QUOTE_ROOT/main" && "$WORKTREE_SCRIPT" create quote-check) 2>"$QUOTE_ROOT/err" )"
quote_status=$?
set -e

assert_eq "$quote_status" "0" "create succeeds for the quoted-name entry"
assert_real "$QUOTE_WT/.agents/weird\"quote.md" "the quoted tracked leaf stays a real file, not a link"
assert_eq "$(cat "$QUOTE_WT/.agents/weird\"quote.md")" "q" "the quoted tracked leaf has the branch's content"

echo "=== a child tracked only on main (branch predates it) is not linked over (#964) ==="

# Top-level provisioning already checks both indexes for the parent's shape;
# this proves the per-child walk inside a shadowed entry does the same, so a
# path that only main tracks so far is left to the eventual merge instead of
# being symlinked out from under it.
PREDATE_ROOT="$TMP_ROOT/predate"
make_repo "$PREDATE_ROOT"
mkdir -p "$PREDATE_ROOT/main/.agents/skills"
printf 'anchor\n' >"$PREDATE_ROOT/main/.agents/skills/anchor.md"
printf 'WORKTREE_SYMLINKS=".agents"\n' >"$PREDATE_ROOT/main/.env"
git -C "$PREDATE_ROOT/main" add .agents/skills/anchor.md
git -C "$PREDATE_ROOT/main" commit -q -m anchor
push_main "$PREDATE_ROOT"

set +e
PREDATE_WT="$( (cd "$PREDATE_ROOT/main" && "$WORKTREE_SCRIPT" create predate-check) 2>"$PREDATE_ROOT/err" )"
predate_status=$?
set -e
assert_eq "$predate_status" "0" "create succeeds before the new child is tracked"

# Advance MAIN only: a new file lands under the shadowed entry and becomes
# tracked there, but the worktree branch does not have it yet.
printf 'late\n' >"$PREDATE_ROOT/main/.agents/skills/late.md"
git -C "$PREDATE_ROOT/main" add .agents/skills/late.md
git -C "$PREDATE_ROOT/main" commit -q -m late
push_main "$PREDATE_ROOT"

set +e
(cd "$PREDATE_ROOT/main" && "$WORKTREE_SCRIPT" repair-links "$PREDATE_WT") >/dev/null 2>"$PREDATE_ROOT/err2"
predate_repair_status=$?
set -e
assert_eq "$predate_repair_status" "0" "repair-links succeeds while the child is main-only"

if [[ ! -e "$PREDATE_WT/.agents/skills/late.md" && ! -L "$PREDATE_WT/.agents/skills/late.md" ]]; then
  assert_ok "a child tracked only on main is left absent, not symlinked"
else
  assert_fail "a child tracked only on main is left absent, not symlinked" \
    "found: $(ls -la "$PREDATE_WT/.agents/skills/late.md" 2>&1)"
fi

set +e
git -C "$PREDATE_WT" fetch -q origin
merge_out2="$(git -C "$PREDATE_WT" merge --no-edit origin/main 2>&1)"
merge_status2=$?
[[ "$merge_status2" -eq 0 ]] || printf 'merge output:\n%s\n' "$merge_out2" >&2
set -e
assert_eq "$merge_status2" "0" "the merge that introduces the tracked child succeeds"
assert_real "$PREDATE_WT/.agents/skills/late.md" "the merge wrote the newly-tracked child as a real file"

echo "=== an untracked .gitignore under a tracked-content entry is copied, not linked (KEN-685) ==="

# Git refuses to read .gitignore through a symlink, so a linked one applies
# none of its rules in the worktree and prints "unable to access" on every
# command. drovr's shape: `.opencode/agents` is tracked, `.opencode/.gitignore`
# is untracked and ignores bun.lock. It does NOT ignore itself: the copy in the
# worktree is kept out of `git status` only by the info/exclude entry setup
# writes for it, so the status assertions below prove that entry too.
IGN_ROOT="$TMP_ROOT/ignore"
make_repo "$IGN_ROOT"
mkdir -p "$IGN_ROOT/main/.opencode/agents"
printf 'agent\n' >"$IGN_ROOT/main/.opencode/agents/dev.md"
printf 'bun.lock\n' >"$IGN_ROOT/main/.opencode/.gitignore"
printf 'lock\n' >"$IGN_ROOT/main/.opencode/bun.lock"
printf 'WORKTREE_SYMLINKS=".opencode"\n' >"$IGN_ROOT/main/.env"
git -C "$IGN_ROOT/main" add .opencode/agents/dev.md
git -C "$IGN_ROOT/main" commit -q -m 'track opencode agents'
push_main "$IGN_ROOT"
assert_eq "$(git -C "$IGN_ROOT/main" status --porcelain -- .opencode/bun.lock)" "" "main ignores bun.lock through the untracked .gitignore"
assert_eq "$(git -C "$IGN_ROOT/main" status --porcelain -- .opencode)" "?? .opencode/.gitignore" "main's .gitignore is untracked and does not hide itself"

set +e
IGN_WT="$( (cd "$IGN_ROOT/main" && "$WORKTREE_SCRIPT" create ignore-check) 2>"$IGN_ROOT/err" )"
ign_status=$?
set -e
assert_eq "$ign_status" "0" "create succeeds for the entry holding an untracked .gitignore"
[[ -n "$IGN_WT" && -d "$IGN_WT" ]] || { echo "FATAL: worktree not created: $(cat "$IGN_ROOT/err")"; exit 1; }

assert_real "$IGN_WT/.opencode/.gitignore" "the .gitignore is a real file in the worktree, not a link"
assert_eq "$(cat "$IGN_WT/.opencode/.gitignore")" "$(cat "$IGN_ROOT/main/.opencode/.gitignore")" "the copy has main's content"
assert_real "$IGN_WT/.opencode/agents/dev.md" "the tracked file beside it stays a real file"

# The proof: the worktree ignores what main ignores, and git stops complaining.
printf 'lock\n' >"$IGN_WT/.opencode/bun.lock"
assert_eq "$(git -C "$IGN_WT" status --porcelain 2>&1)" "" "bun.lock is ignored in the worktree"
assert_lacks "$(git -C "$IGN_WT" status 2>&1)" "unable to access" "git prints no ignore-file access warning"

# push is the one command that runs the materialization detector; the copy
# must read as the expected shape there, not as a real path where a link belongs.
set +e
(cd "$IGN_ROOT/main" && "$WORKTREE_SCRIPT" push ignore-check --no-rebase -u) >/dev/null 2>"$IGN_ROOT/perr"
ign_push_status=$?
set -e
assert_eq "$ign_push_status" "0" "push succeeds from the worktree holding the copy"
assert_lacks "$(cat "$IGN_ROOT/perr")" "harness paths in this worktree" "push does not report the copy as a materialized link"

echo "=== the .gitignore copy follows main on the next pass, and a legacy link heals to a copy ==="

printf 'bun.lock\nnode_modules/\n' >"$IGN_ROOT/main/.opencode/.gitignore"
set +e
(cd "$IGN_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$IGN_WT") >/dev/null 2>"$IGN_ROOT/err2"
ign_fix_status=$?
set -e
assert_eq "$ign_fix_status" "0" "fix-links succeeds after main's .gitignore changed"
assert_lacks "$(cat "$IGN_ROOT/err2")" "Warning" "fix-links stays quiet while re-copying"
assert_eq "$(cat "$IGN_WT/.opencode/.gitignore")" "$(cat "$IGN_ROOT/main/.opencode/.gitignore")" "the copy picked up main's change"

# A worktree provisioned by the older skill holds a link where the copy belongs.
rm -f "$IGN_WT/.opencode/.gitignore"
ln -s "$IGN_ROOT/main/.opencode/.gitignore" "$IGN_WT/.opencode/.gitignore"
set +e
(cd "$IGN_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$IGN_WT") >/dev/null 2>"$IGN_ROOT/err3"
ign_legacy_status=$?
set -e
assert_eq "$ign_legacy_status" "0" "fix-links succeeds on a legacy linked .gitignore"
assert_real "$IGN_WT/.opencode/.gitignore" "the legacy link became a copy"
assert_eq "$(git -C "$IGN_WT" status --porcelain 2>&1)" "" "the healed worktree ignores bun.lock again"

# fix-links judges the copy's content: a worktree edit is drift it closes.
printf 'edited\n' >"$IGN_WT/.opencode/.gitignore"
set +e
(cd "$IGN_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$IGN_WT") >/dev/null 2>&1
set -e
assert_eq "$(cat "$IGN_WT/.opencode/.gitignore")" "$(cat "$IGN_ROOT/main/.opencode/.gitignore")" "a worktree edit to the copy is overwritten by main's file"

echo "=== a locked index during legacy heal reports failure, not a swallowed success (#850) ==="

# The old code discarded failures from --no-assume-unchanged and the missing-
# file checkout with `|| true`, so a locked index or unwritable destination
# left tracked paths missing/unwritable while the heal still reported success.
LOCK_ROOT="$TMP_ROOT/lock"
make_repo "$LOCK_ROOT"
mkdir -p "$LOCK_ROOT/main/.agents"
printf 'engine\n' >"$LOCK_ROOT/main/.agents/engine.md"
printf 'WORKTREE_SYMLINKS=".agents"\n' >"$LOCK_ROOT/main/.env"
git -C "$LOCK_ROOT/main" add .agents/engine.md
git -C "$LOCK_ROOT/main" commit -q -m engine
push_main "$LOCK_ROOT"

set +e
LOCK_WT="$( (cd "$LOCK_ROOT/main" && "$WORKTREE_SCRIPT" create lock-check) 2>"$LOCK_ROOT/err" )"
lock_status=$?
set -e
assert_eq "$lock_status" "0" "create succeeds for the lock scenario"

# Model the legacy parent-link state once more so the shadowed-restore path
# (clear assume-unchanged, checkout missing tracked files) actually runs.
rm -rf "$LOCK_WT/.agents"
ln -s "$LOCK_ROOT/main/.agents" "$LOCK_WT/.agents"
git -C "$LOCK_WT" update-index --assume-unchanged .agents/engine.md

LOCKFILE="$(git -C "$LOCK_WT" rev-parse --git-path index.lock)"
: >"$LOCKFILE"

set +e
lock_out="$(cd "$LOCK_ROOT/main" && "$WORKTREE_SCRIPT" repair-links "$LOCK_WT" 2>&1)"
lock_repair_status=$?
set -e
rm -f "$LOCKFILE"

if [[ "$lock_repair_status" -ne 0 ]]; then
  assert_ok "a locked index makes the heal report failure instead of success"
else
  assert_fail "a locked index makes the heal report failure instead of success" "exit status was 0: $lock_out"
fi
if grep -qF -- "could not" <<<"$lock_out"; then
  assert_ok "the failure names what could not be healed"
else
  assert_fail "the failure names what could not be healed" "output: $lock_out"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
