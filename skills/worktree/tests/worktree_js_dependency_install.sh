#!/usr/bin/env bash
# create runs npm install only where npm is genuinely the package manager.
# In a pnpm/yarn/bun workspace the historical unconditional `npm install`
# resolved the wrong tree and wrote a stray package-lock.json into the fresh
# checkout — dirty from birth, and `git add -A` would commit an npm lockfile
# into a pnpm monorepo.
#
# Asserted here:
#   1. a pnpm-lock.yaml beside package.json skips the npm install entirely;
#   2. a packageManager pin naming pnpm skips it too, lockfile or not;
#   3. a plain npm package.json still gets the historical install.
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

# Stubs: gh quiet; npm records every invocation to a per-run marker file.
mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/bin/gh"
cat >"$TMP_ROOT/bin/npm" <<'STUB'
#!/usr/bin/env bash
echo "npm $* in $PWD" >>"$NPM_CALL_LOG"
exit 0
STUB
chmod +x "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/npm"
export PATH="$TMP_ROOT/bin:$PATH"
export NPM_CALL_LOG="$TMP_ROOT/npm-calls.log"
: >"$NPM_CALL_LOG"

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

wait_for_installs() {
  # The npm path is backgrounded; give it a moment to land.
  local deadline=$((SECONDS + 5))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -s "$NPM_CALL_LOG" ] && return 0
    sleep 0.2
  done
  return 0
}

echo "=== a pnpm workspace never gets an npm install ==="
ROOT="$TMP_ROOT/pnpm"
make_repo "$ROOT" repo
printf '{ "name": "app", "devDependencies": {} }\n' >"$ROOT/repo/package.json"
printf 'lockfileVersion: "9.0"\n' >"$ROOT/repo/pnpm-lock.yaml"
git -C "$ROOT/repo" add package.json pnpm-lock.yaml
git -C "$ROOT/repo" commit -q -m "js: pnpm workspace"
git -C "$ROOT/repo" push -q origin main
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-pnpm >/dev/null)
sleep 1
if grep -q "pnpm/.worktrees" "$NPM_CALL_LOG" 2>/dev/null || grep -q "issue-pnpm" "$NPM_CALL_LOG" 2>/dev/null; then
  bad "pnpm worktree skipped npm" "$(cat "$NPM_CALL_LOG")"
else
  ok "pnpm worktree skipped npm"
fi
WT_PNPM="$ROOT/.worktrees/repo/issue-pnpm"
[ ! -e "$WT_PNPM/package-lock.json" ] && ok "no stray package-lock.json in the pnpm worktree" \
  || bad "no stray package-lock.json" "package-lock.json exists"

echo "=== a packageManager pin skips npm even without a lockfile ==="
ROOT="$TMP_ROOT/pin"
make_repo "$ROOT" repo
printf '{ "name": "app", "packageManager": "pnpm@10.33.2" }\n' >"$ROOT/repo/package.json"
git -C "$ROOT/repo" add package.json
git -C "$ROOT/repo" commit -q -m "js: pinned manager"
git -C "$ROOT/repo" push -q origin main
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-pin >/dev/null)
sleep 1
if grep -q "issue-pin" "$NPM_CALL_LOG" 2>/dev/null; then
  bad "packageManager pin skipped npm" "$(cat "$NPM_CALL_LOG")"
else
  ok "packageManager pin skipped npm"
fi

echo "=== a plain npm repo keeps the historical install ==="
ROOT="$TMP_ROOT/npm"
make_repo "$ROOT" repo
printf '{ "name": "app", "devDependencies": {} }\n' >"$ROOT/repo/package.json"
git -C "$ROOT/repo" add package.json
git -C "$ROOT/repo" commit -q -m "js: npm app"
git -C "$ROOT/repo" push -q origin main
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-npm >/dev/null)
wait_for_installs
sleep 1
if grep -q "issue-npm" "$NPM_CALL_LOG" 2>/dev/null; then
  ok "npm repo still gets its install"
else
  bad "npm repo still installs" "log: $(cat "$NPM_CALL_LOG" 2>/dev/null)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
