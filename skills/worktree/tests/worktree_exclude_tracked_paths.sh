#!/usr/bin/env bash
# `worktree create` writes the configured symlink path into the COMMON git
# dir's info/exclude, which EVERY checkout of the repo reads — including main,
# where that path is a real directory rather than the worktree's symlink.
#
# A bare entry therefore marked the whole directory ignored in the main
# checkout, so `git add <tracked file under it>` started refusing with "The
# following paths are ignored by one of your .gitignore files" while `git
# status` still listed the file as modified. It also outlived the worktree
# (vstack#878).
#
# Fix: when the path holds tracked content, follow the bare entry with
# `!<path>/`. A trailing-slash pattern matches a real directory but NOT a
# symlink pointing at one, so main regains the directory while the worktree's
# symlink stays ignored. Runtime-only paths must keep the plain blanket entry.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then pass "$name"; else
    fail "$name"; printf '        want: %s\n        got:  %s\n' "$want" "$got"; fi
}

mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/bin/gh"
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

# `rev-parse --git-common-dir` prints a path relative to the repo, so resolve it
# from inside the checkout rather than the caller's cwd.
exclude_of() { ( cd "$1" && cat "$(git rev-parse --git-common-dir)/info/exclude" 2>/dev/null ); }

############################################################
echo "=== a symlinked path WITH tracked files stays stageable in main ==="
############################################################

R="$TMP_ROOT/tracked"
make_repo "$R"
mkdir -p "$R/main/harness/skills"
printf 'harness/state.json\n' >"$R/main/.gitignore"
printf 'runtime\n' >"$R/main/harness/state.json"
printf 'v1\n' >"$R/main/harness/skills/tool.md"
printf 'WORKTREE_SYMLINKS="harness"\n' >"$R/main/.env"
git -C "$R/main" add .gitignore harness/skills/tool.md .env
git -C "$R/main" commit -q -m harness
git -C "$R/main" push -q origin main

WT="$( (cd "$R/main" && "$WORKTREE_SCRIPT" create tracked-check) 2>/dev/null )"
[[ -n "$WT" && -d "$WT" ]] || { echo "FATAL: worktree not created"; exit 1; }

EX="$(exclude_of "$R/main")"
if grep -qxF 'harness' <<<"$EX"; then pass "bare entry is still written"; else fail "bare entry is still written"; fi
if grep -qxF '!harness/' <<<"$EX"; then pass "negation is added for a tracked path"; else fail "negation is added for a tracked path"; fi
# gitignore takes the LAST matching pattern, so order is load-bearing.
if [[ "$(grep -nxF 'harness' <<<"$EX" | tail -1 | cut -d: -f1)" -lt "$(grep -nxF '!harness/' <<<"$EX" | tail -1 | cut -d: -f1)" ]]; then
  pass "negation is ordered after the bare entry"
else
  fail "negation is ordered after the bare entry"
fi

# The reported symptom: staging a tracked file under that path from MAIN.
printf 'v2\n' >"$R/main/harness/skills/tool.md"
set +e
add_out="$(git -C "$R/main" add harness/skills/tool.md 2>&1)"
add_status=$?
set -e
assert_eq "$add_status" "0" "main checkout can stage a tracked file under the path"
if [[ -z "$add_out" ]]; then pass "…with no ignore complaint"; else fail "…with no ignore complaint: $add_out"; fi
assert_eq "$(git -C "$R/main" diff --cached --name-only)" "harness/skills/tool.md" "…and it actually staged"
git -C "$R/main" reset -q

# The worktree side must be unaffected: its symlink stays invisible.
assert_eq "$(git -C "$WT" status --porcelain)" "" "worktree stays clean (symlink still ignored)"
if [[ -L "$WT/harness" ]]; then pass "worktree path is a symlink"; else fail "worktree path is a symlink"; fi

# The whole point of the entry: remove must not need --force.
set +e
rm_out="$( (cd "$R/main" && "$WORKTREE_SCRIPT" remove tracked-check) 2>&1 )"
rm_status=$?
set -e
assert_eq "$rm_status" "0" "worktree remove still succeeds without --force"

############################################################
echo "=== a runtime-only symlinked path keeps the plain blanket entry ==="
############################################################

# Critical: vstack's own .agents mirror is hidden in main by this entry ALONE,
# with no .gitignore rule behind it. Adding a negation there would expose the
# entire runtime mirror as untracked noise.
C="$TMP_ROOT/clean"
make_repo "$C"
mkdir -p "$C/main/runtime/sub"
printf 'state\n' >"$C/main/runtime/state.json"
printf 'more\n' >"$C/main/runtime/sub/x.json"
printf 'WORKTREE_SYMLINKS="runtime"\n' >"$C/main/.env"
git -C "$C/main" add .env
git -C "$C/main" commit -q -m runtime
git -C "$C/main" push -q origin main

CWT="$( (cd "$C/main" && "$WORKTREE_SCRIPT" create clean-check) 2>/dev/null )"
[[ -n "$CWT" ]] || { echo "FATAL: clean worktree not created"; exit 1; }

CEX="$(exclude_of "$C/main")"
if grep -qxF 'runtime' <<<"$CEX"; then pass "bare entry written for a runtime-only path"; else fail "bare entry written for a runtime-only path"; fi
if grep -qxF '!runtime/' <<<"$CEX"; then fail "no negation for a runtime-only path"; else pass "no negation for a runtime-only path"; fi
# And main must NOT start reporting the runtime tree as untracked.
assert_eq "$(git -C "$C/main" status --porcelain)" "" "main stays clean — runtime tree not exposed"

############################################################
echo "=== the shape self-heals when a path gains tracked content ==="
############################################################

# Same repo: commit a file under the previously runtime-only path, then
# re-materialize the links. The negation must appear without a manual edit.
printf 'now-tracked\n' >"$C/main/runtime/sub/keep.md"
git -C "$C/main" add -f runtime/sub/keep.md
git -C "$C/main" commit -q -m 'track a file under the runtime path'
git -C "$C/main" push -q origin main

(cd "$C/main" && "$WORKTREE_SCRIPT" fix-links "$CWT") >/dev/null 2>&1 || true

CEX2="$(exclude_of "$C/main")"
if grep -qxF '!runtime/' <<<"$CEX2"; then pass "negation appears once the path gains tracked files"; else fail "negation appears once the path gains tracked files"; fi
assert_eq "$(grep -cxF '!runtime/' <<<"$CEX2")" "1" "negation is not duplicated on repeat runs"

set +e
add2_status=0
git -C "$C/main" add runtime/sub/keep.md 2>/dev/null || add2_status=$?
set -e
assert_eq "$add2_status" "0" "main can stage the newly tracked file"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
