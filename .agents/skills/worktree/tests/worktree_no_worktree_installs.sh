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
#      names the main checkout — on fix-links as well as on create, since the
#      check lives in setup_worktree_links and every caller reaches it;
#   3. a WORKTREE_SYMLINKS node_modules entry satisfies the check silently;
#   4. a repo without a root package.json gets no warning;
#   5. a nested node_modules entry (ui-style) with no main-checkout source
#      warns on create, and fix-links links it once the install exists;
#   6. a root node_modules entry with no source warns exactly once, and that
#      one warning is the configured-entry message, not the generic fallback;
#   7. repair-links, the git-hook path, warns too when the main-checkout
#      source disappears after the worktree was created;
#   8. a configured node_modules entry with no package.json beside it in the
#      worktree stays silent.
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

# The log is cumulative and every caller checks it after the worktree command
# has already returned, so one read covers everything that ran: a manager the
# command forked and did not wait for is a defect this suite is not the place
# to catch — `create` has no such path, and if it grew one the install would
# be unsequenced against the caller regardless.
assert_no_pm_calls() { # NAME — fail if any package manager has been invoked
  local name="$1"
  if [ -s "$PM_CALL_LOG" ]; then
    bad "$name" "$(cat "$PM_CALL_LOG")"
    return 1
  fi
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
# The fallback lives in setup_worktree_links, so every caller reaches it, not
# just create. fix-links pins one of the other invocation modes.
STDERR_PNPM_FIX="$TMP_ROOT/pnpm-fixlinks-stderr.log"
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" fix-links "$WT_PNPM" >/dev/null 2>"$STDERR_PNPM_FIX")
if grep -q "dependencies were not installed" "$STDERR_PNPM_FIX"; then
  ok "fix-links warns on an unlinked JS worktree too, not only create"
else
  bad "fix-links fallback warning" "stderr: $(cat "$STDERR_PNPM_FIX")"
fi

echo "=== a WORKTREE_SYMLINKS node_modules entry satisfies the check silently ==="
ROOT="$TMP_ROOT/linked"
make_repo "$ROOT" repo
printf '{ "name": "app", "devDependencies": {} }\n' >"$ROOT/repo/package.json"
git -C "$ROOT/repo" add package.json
git -C "$ROOT/repo" commit -q -m "js: linked deps"
git -C "$ROOT/repo" push -q origin main
mkdir -p "$ROOT/repo/node_modules/dep"
printf 'WORKTREE_SYMLINKS="node_modules"\n' >"$ROOT/repo/.env.local"
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

echo "=== a nested node_modules entry with no source warns, then fix-links links it ==="
ROOT="$TMP_ROOT/nested"
make_repo "$ROOT" repo
mkdir -p "$ROOT/repo/ui"
printf '{ "name": "ui", "devDependencies": {} }\n' >"$ROOT/repo/ui/package.json"
git -C "$ROOT/repo" add ui/package.json
git -C "$ROOT/repo" commit -q -m "js: nested ui package"
git -C "$ROOT/repo" push -q origin main
printf 'WORKTREE_SYMLINKS="ui/node_modules"\n' >"$ROOT/repo/.env.local"
STDERR_NESTED="$TMP_ROOT/nested-stderr.log"
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-nested >/dev/null 2>"$STDERR_NESTED")
WT_NESTED="$ROOT/.worktrees/repo/issue-nested"
if grep -q "dependencies were not installed" "$STDERR_NESTED" &&
  grep -qF "$ROOT/repo/ui/node_modules" "$STDERR_NESTED"; then
  ok "missing nested source warns and names the main-checkout path"
else
  bad "nested missing-source warning" "stderr: $(cat "$STDERR_NESTED")"
fi
mkdir -p "$ROOT/repo/ui/node_modules/dep"
STDERR_FIXLINKS="$TMP_ROOT/nested-fixlinks-stderr.log"
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" fix-links "$WT_NESTED" >/dev/null 2>"$STDERR_FIXLINKS")
[ -L "$WT_NESTED/ui/node_modules" ] && ok "fix-links links the source once it exists" \
  || bad "fix-links links nested node_modules" "no symlink at $WT_NESTED/ui/node_modules"
if grep -q "dependencies were not installed" "$STDERR_FIXLINKS"; then
  bad "linked nested worktree stays silent" "stderr: $(cat "$STDERR_FIXLINKS")"
else
  ok "no warning once the nested source is linked"
fi
assert_no_pm_calls "nested repo: no package manager invoked" || true

echo "=== a root node_modules entry with no source warns exactly once ==="
ROOT="$TMP_ROOT/rootentry"
make_repo "$ROOT" repo
printf '{ "name": "app", "devDependencies": {} }\n' >"$ROOT/repo/package.json"
git -C "$ROOT/repo" add package.json
git -C "$ROOT/repo" commit -q -m "js: root entry"
git -C "$ROOT/repo" push -q origin main
printf 'WORKTREE_SYMLINKS="node_modules"\n' >"$ROOT/repo/.env.local"
STDERR_ROOT="$TMP_ROOT/rootentry-stderr.log"
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-rootentry >/dev/null 2>"$STDERR_ROOT")
WARN_COUNT="$(grep -c "dependencies were not installed" "$STDERR_ROOT" || true)"
if [ "$WARN_COUNT" = "1" ]; then
  ok "configured root entry with no source warns exactly once"
else
  bad "single warning for a configured root entry" "count=$WARN_COUNT stderr: $(cat "$STDERR_ROOT")"
fi
# Both messages contain the counted substring, so the count alone cannot tell
# them apart: name the one that must be there and the one that must not.
if grep -qF "WORKTREE_SYMLINKS entry 'node_modules' has no source at $ROOT/repo/node_modules" "$STDERR_ROOT" &&
  ! grep -qF "installs run only in the main checkout" "$STDERR_ROOT"; then
  ok "that one warning is the configured-entry message, not the generic fallback"
else
  bad "configured-entry message identity" "stderr: $(cat "$STDERR_ROOT")"
fi

echo "=== repair-links warns when the main-checkout source disappears ==="
ROOT="$TMP_ROOT/repair"
make_repo "$ROOT" repo
mkdir -p "$ROOT/repo/ui/node_modules/dep"
printf '{ "name": "ui", "devDependencies": {} }\n' >"$ROOT/repo/ui/package.json"
git -C "$ROOT/repo" add ui/package.json
git -C "$ROOT/repo" commit -q -m "js: nested ui package"
git -C "$ROOT/repo" push -q origin main
printf 'WORKTREE_SYMLINKS="ui/node_modules"\n' >"$ROOT/repo/.env.local"
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-repair >/dev/null 2>&1)
WT_REPAIR="$ROOT/.worktrees/repo/issue-repair"
[ -L "$WT_REPAIR/ui/node_modules" ] && ok "repair case starts from a linked worktree" \
  || bad "repair case starts linked" "no symlink at $WT_REPAIR/ui/node_modules"
rm -rf "$ROOT/repo/ui/node_modules"
STDERR_REPAIR="$TMP_ROOT/repair-stderr.log"
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" repair-links "$WT_REPAIR" >/dev/null 2>"$STDERR_REPAIR")
if grep -q "dependencies were not installed" "$STDERR_REPAIR" &&
  grep -qF "$ROOT/repo/ui/node_modules" "$STDERR_REPAIR"; then
  ok "repair-links warns instead of skipping the vanished source in silence"
else
  bad "repair-links missing-source warning" "stderr: $(cat "$STDERR_REPAIR")"
fi
assert_no_pm_calls "repair repo: no package manager invoked" || true

echo "=== a configured entry with no package.json beside it stays silent ==="
ROOT="$TMP_ROOT/nopkg"
make_repo "$ROOT" repo
printf 'WORKTREE_SYMLINKS="ui/node_modules"\n' >"$ROOT/repo/.env.local"
STDERR_NOPKG="$TMP_ROOT/nopkg-stderr.log"
(cd "$ROOT/repo" && "$WORKTREE_SCRIPT" create issue-nopkg >/dev/null 2>"$STDERR_NOPKG")
if grep -q "dependencies were not installed" "$STDERR_NOPKG"; then
  bad "no package.json means no dependency warning" "stderr: $(cat "$STDERR_NOPKG")"
else
  ok "a configured node_modules entry with no ui/package.json stays silent"
fi

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
