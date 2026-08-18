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
#   3. a plain npm package.json still gets the historical install;
#   4. a failed install leaves its log in the worktree's own gitdir, and a
#      clean one leaves none behind.
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

# Stubs: gh quiet; npm records every invocation to a per-run marker file and
# fails loudly in the one fixture whose worktree is named for it.
mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/bin/gh"
cat >"$TMP_ROOT/bin/npm" <<'STUB'
#!/usr/bin/env bash
echo "npm $* in $PWD" >>"$NPM_CALL_LOG"
case "$PWD" in
  *issue-fail*)
    echo "npm ERR! stub install failure"
    exit 1
    ;;
esac
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

install_log_path() { # WT — the install log inside that worktree's own gitdir
  printf '%s/npm-install.log\n' "$(git -C "$1" rev-parse --absolute-git-dir)"
}

wait_for_install_log() { # WT — the backgrounded install has written its log
  local log deadline=$((SECONDS + 10))
  log="$(install_log_path "$1")"
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -s "$log" ] && return 0
    sleep 0.2
  done
  return 1
}

wait_for_install_log_removal() { # WT — a clean install cleared its log
  local log deadline=$((SECONDS + 10))
  log="$(install_log_path "$1")"
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -e "$log" ] || return 0
    sleep 0.2
  done
  return 1
}

assert_log_stays_empty() { # NAME — watch 2s and fail the moment npm logs
  local name="$1" deadline=$((SECONDS + 2))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -s "$NPM_CALL_LOG" ]; then
      bad "$name" "$(cat "$NPM_CALL_LOG")"
      return 1
    fi
    sleep 0.2
  done
  ok "$name"
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
assert_log_stays_empty "pnpm worktree skipped npm" || true
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
assert_log_stays_empty "packageManager pin skipped npm" || true

echo "=== a pin formatted across lines is still a pin ==="
ROOT="$TMP_ROOT/multiline"
make_repo "$ROOT" repo
printf '{\n  "name": "app",\n  "packageManager":\n    "pnpm@10.33.2"\n}\n' >"$ROOT/repo/package.json"
git -C "$ROOT/repo" add package.json
git -C "$ROOT/repo" commit -q -m "js: multiline pin"
git -C "$ROOT/repo" push -q origin main
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-multiline >/dev/null)
assert_log_stays_empty "a multiline packageManager pin skips npm" || true

echo "=== a nested config.packageManager is not a pin ==="
ROOT="$TMP_ROOT/nested"
make_repo "$ROOT" repo
printf '{ "name": "app", "config": { "packageManager": "pnpm@10.33.2" } }\n' >"$ROOT/repo/package.json"
git -C "$ROOT/repo" add package.json
git -C "$ROOT/repo" commit -q -m "js: nested lookalike"
git -C "$ROOT/repo" push -q origin main
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-nested >/dev/null)
wait_for_installs
sleep 1
if grep -q "issue-nested" "$NPM_CALL_LOG" 2>/dev/null; then
  ok "a nested config.packageManager still gets the npm install"
else
  bad "nested lookalike not a pin" "log: $(cat "$NPM_CALL_LOG" 2>/dev/null)"
fi
: >"$NPM_CALL_LOG"

echo "=== npm-shrinkwrap.json is explicit npm evidence ==="
ROOT="$TMP_ROOT/shrinkwrap"
make_repo "$ROOT" repo
printf '{ "name": "app" }\n' >"$ROOT/repo/package.json"
printf '{}\n' >"$ROOT/repo/npm-shrinkwrap.json"
printf '# incidental\n' >"$ROOT/repo/yarn.lock"
git -C "$ROOT/repo" add package.json npm-shrinkwrap.json yarn.lock
git -C "$ROOT/repo" commit -q -m "js: shrinkwrap npm"
git -C "$ROOT/repo" push -q origin main
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-shrink >/dev/null)
wait_for_installs
sleep 1
if grep -q "issue-shrink" "$NPM_CALL_LOG" 2>/dev/null; then
  ok "npm-shrinkwrap.json keeps the install despite a foreign lockfile"
else
  bad "shrinkwrap evidence wins" "log: $(cat "$NPM_CALL_LOG" 2>/dev/null)"
fi
: >"$NPM_CALL_LOG"

echo "=== a pnpm workspace manifest alone is foreign evidence ==="
ROOT="$TMP_ROOT/wsmanifest"
make_repo "$ROOT" repo
printf '{ "name": "app" }\n' >"$ROOT/repo/package.json"
printf 'packages:\n  - "apps/*"\n' >"$ROOT/repo/pnpm-workspace.yaml"
git -C "$ROOT/repo" add package.json pnpm-workspace.yaml
git -C "$ROOT/repo" commit -q -m "js: workspace manifest only"
git -C "$ROOT/repo" push -q origin main
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-wsmani >/dev/null)
assert_log_stays_empty "pnpm-workspace.yaml alone skips npm" || true

echo "=== an explicit foreign pin outranks a stale npm lockfile ==="
ROOT="$TMP_ROOT/migration"
make_repo "$ROOT" repo
printf '{ "name": "app", "packageManager": "pnpm@10.33.2" }\n' >"$ROOT/repo/package.json"
printf '{}\n' >"$ROOT/repo/package-lock.json"
git -C "$ROOT/repo" add package.json package-lock.json
git -C "$ROOT/repo" commit -q -m "js: mid-migration"
git -C "$ROOT/repo" push -q origin main
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-migrate >/dev/null)
assert_log_stays_empty "a pnpm pin beats the stale package-lock.json" || true

echo "=== explicit npm evidence beats an incidental foreign lockfile ==="
ROOT="$TMP_ROOT/mixed"
make_repo "$ROOT" repo
printf '{ "name": "app", "devDependencies": {} }\n' >"$ROOT/repo/package.json"
printf '{}\n' >"$ROOT/repo/package-lock.json"
printf '# incidental\n' >"$ROOT/repo/yarn.lock"
git -C "$ROOT/repo" add package.json package-lock.json yarn.lock
git -C "$ROOT/repo" commit -q -m "js: npm with incidental yarn.lock"
git -C "$ROOT/repo" push -q origin main
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-mixed >/dev/null)
wait_for_installs
sleep 1
if grep -q "issue-mixed" "$NPM_CALL_LOG" 2>/dev/null; then
  ok "package-lock.json keeps the npm install despite a foreign lockfile"
else
  bad "npm evidence wins" "log: $(cat "$NPM_CALL_LOG" 2>/dev/null)"
fi
: >"$NPM_CALL_LOG"

echo "=== a BOM'd pin is still a pin ==="
ROOT="$TMP_ROOT/bom"
make_repo "$ROOT" repo
printf '\xEF\xBB\xBF{ "name": "app", "packageManager": "pnpm@10.33.2" }\n' >"$ROOT/repo/package.json"
printf '{}\n' >"$ROOT/repo/package-lock.json"
git -C "$ROOT/repo" add package.json package-lock.json
git -C "$ROOT/repo" commit -q -m "js: BOM pin with stale lockfile"
git -C "$ROOT/repo" push -q origin main
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-bom >/dev/null)
assert_log_stays_empty "a BOM'd pnpm pin beats the stale package-lock.json" || true

echo "=== an unparseable manifest with foreign evidence skips ==="
ROOT="$TMP_ROOT/unparseable"
make_repo "$ROOT" repo
printf '{ "name": "app", trailing garbage\n' >"$ROOT/repo/package.json"
printf 'lockfileVersion: "9.0"\n' >"$ROOT/repo/pnpm-lock.yaml"
printf '{}\n' >"$ROOT/repo/package-lock.json"
git -C "$ROOT/repo" add package.json pnpm-lock.yaml package-lock.json
git -C "$ROOT/repo" commit -q -m "js: unparseable manifest mid-migration"
git -C "$ROOT/repo" push -q origin main
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-unparse >/dev/null)
assert_log_stays_empty "an unreadable manifest with foreign evidence skips npm" || true

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
WT_NPM="$ROOT/.worktrees/repo/issue-npm"
if wait_for_install_log_removal "$WT_NPM"; then
  ok "a clean install leaves no npm-install.log behind"
else
  bad "clean install clears its log" "$(install_log_path "$WT_NPM") still exists"
fi

echo "=== a failed install leaves its log in the worktree's own gitdir ==="
ROOT="$TMP_ROOT/faillog"
make_repo "$ROOT" repo
printf '{ "name": "app", "devDependencies": {} }\n' >"$ROOT/repo/package.json"
git -C "$ROOT/repo" add package.json
git -C "$ROOT/repo" commit -q -m "js: npm app whose install fails"
git -C "$ROOT/repo" push -q origin main
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-fail >/dev/null)
WT_FAIL="$ROOT/.worktrees/repo/issue-fail"
if wait_for_install_log "$WT_FAIL" &&
  grep -q "stub install failure" "$(install_log_path "$WT_FAIL")"; then
  ok "a failed install keeps its full output at <gitdir>/npm-install.log"
else
  bad "failed install log" "$(install_log_path "$WT_FAIL") missing, empty, or truncated"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
