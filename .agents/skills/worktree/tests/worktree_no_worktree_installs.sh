#!/usr/bin/env bash
# No worktree command runs a package-manager install: installs run only in the
# main checkout, and only when the lockfile changed. A worktree gets its
# dependencies through a WORKTREE_SYMLINKS entry for node_modules; when a JS
# repo has nothing linked, create warns and names the main checkout as the
# place to run the install.
#
# Asserted here:
#   1. no package manager (npm, pnpm, yarn, bun) is ever invoked by create;
#   2. a JS worktree with no node_modules gets the warning, and the warning
#      names the main checkout;
#   3. a WORKTREE_SYMLINKS node_modules entry satisfies the check silently;
#   4. a repo without a root package.json gets no warning.
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

# Stubs: gh quiet; every package manager records its invocation — any entry in
# the call log is a failure.
mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/bin/gh"
for pm in npm pnpm yarn bun; do
  printf '#!/usr/bin/env bash\necho "%s $* in $PWD" >>"$PM_CALL_LOG"\nexit 0\n' "$pm" \
    >"$TMP_ROOT/bin/$pm"
done
chmod +x "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/npm" "$TMP_ROOT/bin/pnpm" \
  "$TMP_ROOT/bin/yarn" "$TMP_ROOT/bin/bun"
export PATH="$TMP_ROOT/bin:$PATH"
export PM_CALL_LOG="$TMP_ROOT/pm-calls.log"
: >"$PM_CALL_LOG"

make_repo() { # ROOT NAME — main checkout with a bare origin
  local root="$1" name="$2"
  mkdir -p "$root/$name"
  git -C "$root/$name" init -q -b main
  git -C "$root/$name" config user.email test@example.com
  git -C "$root/$name" config user.name Test
  git -C "$root/$name" config commit.gpgsign false
  printf 'base\n' >"$root/$name/base.txt"
  git -C "$root/$name" add base.txt
  git -C "$root/$name" commit -q -m base
  git init -q --bare "$root/origin-$name.git"
  git -C "$root/$name" remote add origin "$root/origin-$name.git"
  git -C "$root/$name" push -q -u origin main
}

assert_no_pm_calls() { # NAME — watch 2s and fail the moment any manager runs
  local name="$1" deadline=$((SECONDS + 2))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -s "$PM_CALL_LOG" ]; then
      bad "$name" "$(cat "$PM_CALL_LOG")"
      return 1
    fi
    sleep 0.2
  done
  ok "$name"
}

echo "=== an npm repo gets no install and a warning naming the main checkout ==="
ROOT="$TMP_ROOT/npm"
make_repo "$ROOT" repo
printf '{ "name": "app", "devDependencies": {} }\n' >"$ROOT/repo/package.json"
printf '{}\n' >"$ROOT/repo/package-lock.json"
git -C "$ROOT/repo" add package.json package-lock.json
git -C "$ROOT/repo" commit -q -m "js: npm app"
git -C "$ROOT/repo" push -q origin main
STDERR_NPM="$TMP_ROOT/npm-stderr.log"
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-npm >/dev/null 2>"$STDERR_NPM")
assert_no_pm_calls "npm repo: create invoked no package manager" || true
if grep -q "dependencies were not installed" "$STDERR_NPM" &&
  grep -qF "$ROOT/repo" "$STDERR_NPM"; then
  ok "warning names the main checkout as the place to run the install"
else
  bad "missing-dependency warning" "stderr: $(cat "$STDERR_NPM")"
fi

echo "=== a pnpm workspace gets no install and stays clean ==="
ROOT="$TMP_ROOT/pnpm"
make_repo "$ROOT" repo
printf '{ "name": "app", "packageManager": "pnpm@10.33.2" }\n' >"$ROOT/repo/package.json"
printf 'lockfileVersion: "9.0"\n' >"$ROOT/repo/pnpm-lock.yaml"
git -C "$ROOT/repo" add package.json pnpm-lock.yaml
git -C "$ROOT/repo" commit -q -m "js: pnpm workspace"
git -C "$ROOT/repo" push -q origin main
STDERR_PNPM="$TMP_ROOT/pnpm-stderr.log"
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-pnpm >/dev/null 2>"$STDERR_PNPM")
assert_no_pm_calls "pnpm repo: create invoked no package manager" || true
WT_PNPM="$ROOT/.worktrees/repo/issue-pnpm"
[ ! -e "$WT_PNPM/package-lock.json" ] && ok "no stray package-lock.json in the pnpm worktree" \
  || bad "no stray package-lock.json" "package-lock.json exists"
if grep -q "dependencies were not installed" "$STDERR_PNPM"; then
  ok "unlinked pnpm worktree gets the warning"
else
  bad "pnpm warning" "stderr: $(cat "$STDERR_PNPM")"
fi

echo "=== a WORKTREE_SYMLINKS node_modules entry satisfies the check silently ==="
ROOT="$TMP_ROOT/linked"
make_repo "$ROOT" repo
printf '{ "name": "app", "devDependencies": {} }\n' >"$ROOT/repo/package.json"
git -C "$ROOT/repo" add package.json
git -C "$ROOT/repo" commit -q -m "js: linked deps"
git -C "$ROOT/repo" push -q origin main
mkdir -p "$ROOT/repo/node_modules/dep"
printf 'WORKTREE_SYMLINKS="node_modules"\n' >"$ROOT/repo/.env"
STDERR_LINKED="$TMP_ROOT/linked-stderr.log"
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-linked >/dev/null 2>"$STDERR_LINKED")
WT_LINKED="$ROOT/.worktrees/repo/issue-linked"
[ -L "$WT_LINKED/node_modules" ] && ok "node_modules is linked from the main checkout" \
  || bad "node_modules link" "no symlink at $WT_LINKED/node_modules"
if grep -q "dependencies were not installed" "$STDERR_LINKED"; then
  bad "linked worktree stays silent" "stderr: $(cat "$STDERR_LINKED")"
else
  ok "linked worktree gets no warning"
fi
assert_no_pm_calls "linked repo: create invoked no package manager" || true

echo "=== a repo without package.json gets no warning ==="
ROOT="$TMP_ROOT/plain"
make_repo "$ROOT" repo
STDERR_PLAIN="$TMP_ROOT/plain-stderr.log"
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-plain >/dev/null 2>"$STDERR_PLAIN")
if grep -q "dependencies were not installed" "$STDERR_PLAIN"; then
  bad "non-JS repo stays silent" "stderr: $(cat "$STDERR_PLAIN")"
else
  ok "non-JS repo gets no warning"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
