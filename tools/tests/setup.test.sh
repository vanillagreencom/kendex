#!/usr/bin/env bash
# Pins what tools/setup arms: the growth-guards installer writes both shims,
# and this repo's own commit-msg rule is appended below the line the
# installer writes, once. Then it commits through the armed hooks in both
# directions — the package's conventional-header verdict and this repo's
# changelog verdict have to be reachable from a real commit, or the chain is
# wired to nothing. The refusing direction runs first in every pair.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "$TEST_DIR/.." && pwd)"
REPO="$(cd "$TOOLS/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

R="$TMP/repo"
mkdir -p "$R/.agents/skills/growth-guards" "$R/tools" "$R/crates"
cp -R "$REPO/.agents/skills/growth-guards/scripts" "$R/.agents/skills/growth-guards/scripts"
cp "$TOOLS/setup" "$TOOLS/commit-msg" "$R/tools/"
printf '#!/usr/bin/env bash\necho "repo-local lane ran"\n' >"$R/tools/guard"
chmod +x "$R/tools/guard"
printf '[env]\nGROWTH_GUARDS_PRE_COMMIT_LOCAL = "tools/guard"\n' >"$R/kendex.settings.toml"
printf '# fixture\n' >"$R/README.md"
git -C "$R" init -q
git -C "$R" symbolic-ref HEAD refs/heads/main
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test

HOOKS="$R/.git/hooks"
SENTINEL="# kendex-guards-hook"
LANE='exec "$(git rev-parse --show-toplevel)/tools/commit-msg" "$@"'

echo "=== a fresh clone is not armed until setup runs ==="
{ [ ! -e "$HOOKS/pre-commit" ] && [ ! -e "$HOOKS/commit-msg" ]; } \
  && ok "neither shim exists before setup" \
  || bad "neither shim exists before setup" "$(ls -1 "$HOOKS" 2>&1)"

RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "setup exits clean" || bad "setup exits clean" "rc=$RC out=$OUT"
{ [ -x "$HOOKS/pre-commit" ] && grep -qF "$SENTINEL" "$HOOKS/pre-commit"; } \
  && ok "pre-commit carries the installer's line and is executable" \
  || bad "pre-commit carries the installer's line and is executable" "$(cat "$HOOKS/pre-commit" 2>&1)"
{ [ -x "$HOOKS/commit-msg" ] && grep -qF "$SENTINEL" "$HOOKS/commit-msg"; } \
  && ok "commit-msg carries the installer's line and is executable" \
  || bad "commit-msg carries the installer's line and is executable" "$(cat "$HOOKS/commit-msg" 2>&1)"
grep -qxF "$LANE" "$HOOKS/commit-msg" \
  && ok "the repo's commit-msg lane is wired below it" \
  || bad "the repo's commit-msg lane is wired below it" "$(cat "$HOOKS/commit-msg" 2>&1)"

echo "=== re-running setup repairs, it does not stack ==="
(cd "$R" && ./tools/setup >/dev/null 2>&1)
(cd "$R" && ./tools/setup >/dev/null 2>&1)
LANES="$(grep -cxF "$LANE" "$HOOKS/commit-msg" || true)"
[ "$LANES" = "1" ] && ok "three runs leave one repo lane" \
  || bad "three runs leave one repo lane" "count=$LANES"

echo "=== the chain runs at commit time, local lane last ==="
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "chore: fixture" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"repo-local lane ran"*) true ;; *) false ;; esac \
  && ok "the first commit passes and reaches tools/guard last" \
  || bad "the first commit passes and reaches tools/guard last" "rc=$RC out=$OUT"

echo "=== the package judges the header ==="
printf 'x\n' >>"$R/README.md"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "not conventional at all" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"non-conventional header"*) true ;; *) false ;; esac \
  && ok "a non-conventional subject is refused by the package's check" \
  || bad "a non-conventional subject is refused by the package's check" "rc=$RC out=$OUT"
RC=0
OUT="$(git -C "$R" commit -m "docs: a conventional subject" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "a conventional subject passes" \
  || bad "a conventional subject passes" "rc=$RC out=$OUT"

echo "=== this repo judges the changelog ==="
printf 'fn main() {}\n' >"$R/crates/a.rs"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "feat: a crate change" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"without a CHANGELOG.md entry"*) true ;; *) false ;; esac \
  && ok "a crates/ change with no changelog entry is refused by the repo lane" \
  || bad "a crates/ change with no changelog entry is refused by the repo lane" "rc=$RC out=$OUT"
RC=0
OUT="$(git -C "$R" commit -m "feat: a crate change [no-changelog]" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "[no-changelog] in the subject releases it" \
  || bad "[no-changelog] in the subject releases it" "rc=$RC out=$OUT"

echo "=== setup never claims armed where git reads hooks elsewhere ==="
E="$TMP/elsewhere"
mkdir -p "$E/tools" "$E/other-hooks" "$E/.agents/skills"
cp -R "$R/.agents/skills/growth-guards" "$E/.agents/skills/growth-guards"
cp "$TOOLS/setup" "$TOOLS/commit-msg" "$E/tools/"
git -C "$E" init -q
git -C "$E" config core.hooksPath "$E/other-hooks"
# A leftover file at the path the installer writes, which git no longer reads.
mkdir -p "$E/.git/hooks"
printf '#!/bin/sh\n' >"$E/.git/hooks/commit-msg"
RC=0
OUT="$(cd "$E" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"not armed"*) true ;; *) false ;; esac \
  && ok "a configured hooks path stops setup instead of wiring a hook git ignores" \
  || bad "a configured hooks path stops setup instead of wiring a hook git ignores" "rc=$RC out=$OUT"
grep -qxF "$LANE" "$E/.git/hooks/commit-msg" \
  && bad "the stale hook is left alone" "$(cat "$E/.git/hooks/commit-msg")" \
  || ok "the stale hook is left alone"

echo "=== the repo lane fails closed when it cannot read the message ==="
RC=0
OUT="$(cd "$R" && ./tools/commit-msg 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"no readable message file"*) true ;; *) false ;; esac \
  && ok "no message file is exit 2, not a pass" \
  || bad "no message file is exit 2, not a pass" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
