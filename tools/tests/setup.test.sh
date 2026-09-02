#!/usr/bin/env bash
# Pins what tools/setup arms: the growth-guards installer writes both shims,
# nothing is spliced in beside them, and the clone then commits through the
# armed hooks in both directions — one package verdict has to be reachable
# from a real commit, or the chain is wired to nothing. The refusing direction
# runs first in every pair.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "$TEST_DIR/.." && pwd)"
REPO="$(cd "$TOOLS/.." && pwd)"
REQUIRED_PATHS="$(sed -n 's/^GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS = "\(.*\)"$/\1/p' "$REPO/kendex.settings.toml")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

[ -n "$REQUIRED_PATHS" ] \
  && ok "kendex.settings.toml names the paths that oblige a changelog entry" \
  || bad "kendex.settings.toml names the paths that oblige a changelog entry" "GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS is empty"

new_fixture() { # NAME — a clone-shaped repo carrying the package and these tools
  R="$TMP/$1"
  mkdir -p "$R/.agents/skills/growth-guards" "$R/tools" "$R/crates"
  cp -R "$REPO/.agents/skills/growth-guards/scripts" "$R/.agents/skills/growth-guards/scripts"
  cp "$TOOLS/setup" "$R/tools/"
  printf '#!/usr/bin/env bash\necho "repo-local lane ran"\n' >"$R/tools/guard"
  chmod +x "$R/tools/guard"
  printf '[env]\nGROWTH_GUARDS_PRE_COMMIT_LOCAL = "tools/guard"\nGROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS = "%s"\n' \
    "$REQUIRED_PATHS" >"$R/kendex.settings.toml"
  printf '# fixture\n' >"$R/README.md"
  git -C "$R" init -q
  git -C "$R" symbolic-ref HEAD refs/heads/main
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  HOOKS="$R/.git/hooks"
}

new_fixture repo
SENTINEL="# kendex-guards-hook"

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
grep -qF "tools/commit-msg" "$HOOKS/commit-msg" \
  && bad "no repo-local lane is spliced in beside it" "$(cat "$HOOKS/commit-msg")" \
  || ok "no repo-local lane is spliced in beside it"

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

echo "=== the installed hook still obliges the changelog this repo's paths ask for ==="
# One arm, and it is here for the render, not for the rule. commit-msg.test.sh
# proves the whole changelog matrix against skills/; what it cannot see is the
# render losing a rule its source keeps, and the render is the hook
# `tools/setup` installs.
printf 'fn main() {}\n' >"$R/crates/a.rs"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "feat: a crate change" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"without a changelog entry"*) true ;; *) false ;; esac \
  && ok "a crates/ change with no changelog entry is refused by the installed hook" \
  || bad "a crates/ change with no changelog entry is refused by the installed hook" "rc=$RC out=$OUT"

echo "=== hooks the installer will not vouch for are each named ==="
# It refuses an interpreter it cannot verify rather than rewriting somebody
# else's hook. setup's remedy points back at that report rather than naming a
# cause of its own, so the report has to name every hook in the way and why —
# the first one it tripped over is not the whole answer.
new_fixture foreign
for hook in pre-commit commit-msg; do
  printf '#!/usr/bin/env bash\necho "%s ran"\n' "$hook" >"$HOOKS/$hook"
  chmod +x "$HOOKS/$hook"
done
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && ok "setup stops instead of reporting the clone armed" \
  || bad "setup stops instead of reporting the clone armed" "rc=$RC out=$OUT"
# Cause and remedy are asserted apart: the remedy prints for every refusal, so
# matching it alone would pass on a message naming the wrong cause.
for hook in pre-commit commit-msg; do
  case "$OUT" in
    *"hooks/$hook runs under an interpreter that cannot be verified"*)
      ok "the report names $hook and why it was refused" ;;
    *) bad "the report names $hook and why it was refused" "out=$OUT" ;;
  esac
done

echo "=== following the printed remedy through arms the clone ==="
# The remedy is keyed on what a hook still HOLDS, not on who wrote it, and
# only walking it end to end proves that: --uninstall reports success over a
# hook this installer created that carries a lane of the consumer's, and
# leaves the file exactly where it was. A message keyed on authorship stops
# there and sends the operator round the same refusal with nothing to try.
new_fixture remedy
(cd "$R" && ./tools/setup >/dev/null 2>&1)
# The shipped case: a hook this installer wrote, its shebang swapped for one
# the installer will not vouch for, with a lane of the consumer's below it.
{
  printf '#!/usr/bin/env bash\n'
  tail -n +2 "$HOOKS/commit-msg"
  printf 'echo "my own lane"\n'
} >"$HOOKS/commit-msg.new"
mv "$HOOKS/commit-msg.new" "$HOOKS/commit-msg"
chmod +x "$HOOKS/commit-msg"
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"--uninstall"*) true ;; *) false ;; esac \
  && ok "control: setup refuses that clone and prints the remedy" \
  || bad "control: setup refuses that clone and prints the remedy" "rc=$RC out=$OUT"
# Step one, exactly as the message spells it.
(cd "$R" && ./.agents/skills/growth-guards/scripts/install-git-hooks --uninstall >/dev/null 2>&1) || true
[ -e "$HOOKS/commit-msg" ] && grep -qF 'my own lane' "$HOOKS/commit-msg" \
  && ok "--uninstall leaves a hook still holding the consumer's lane" \
  || bad "--uninstall leaves that hook" "$(cat "$HOOKS/commit-msg" 2>&1)"
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] \
  && ok "must-fail: step one alone does not clear the refusal" \
  || bad "must-fail: step one alone does not clear the refusal" "rc=$RC out=$OUT"
# Step two, which the message keys on that hook still being there.
rm -f "$HOOKS/commit-msg"
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"hooks armed"*) true ;; *) false ;; esac \
  && ok "and the remedy walked through leaves the clone armed" \
  || bad "the remedy walked through arms the clone" "rc=$RC out=$OUT"
{ grep -qF "$SENTINEL" "$HOOKS/commit-msg" && grep -qF "$SENTINEL" "$HOOKS/pre-commit"; } \
  && ok "with both shims back in place" \
  || bad "both shims back in place" "$(ls -1 "$HOOKS" 2>&1)"

echo "=== the refused clone, hook by hook, resolves one at a time ==="
new_fixture foreign2
for hook in pre-commit commit-msg; do
  printf '#!/usr/bin/env bash\necho "%s ran"\n' "$hook" >"$HOOKS/$hook"
  chmod +x "$HOOKS/$hook"
done
rm -f "$HOOKS/pre-commit"
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && ok "deleting pre-commit alone is not enough" \
  || bad "deleting pre-commit alone is not enough" "rc=$RC out=$OUT"
rm -f "$HOOKS/commit-msg"
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && grep -qF "$SENTINEL" "$HOOKS/commit-msg" \
  && ok "deleting both arms the clone" \
  || bad "deleting both arms the clone" "rc=$RC out=$OUT"

echo "=== setup never claims armed where git reads hooks elsewhere ==="
E="$TMP/elsewhere"
mkdir -p "$E/tools" "$E/other-hooks" "$E/.agents/skills"
cp -R "$R/.agents/skills/growth-guards" "$E/.agents/skills/growth-guards"
cp "$TOOLS/setup" "$E/tools/"
git -C "$E" init -q
git -C "$E" config core.hooksPath "$E/other-hooks"
RC=0
OUT="$(cd "$E" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"not armed"*) true ;; *) false ;; esac \
  && ok "a configured hooks path stops setup instead of wiring a hook git ignores" \
  || bad "a configured hooks path stops setup instead of wiring a hook git ignores" "rc=$RC out=$OUT"
[ ! -e "$E/.git/hooks/pre-commit" ] && [ ! -e "$E/.git/hooks/commit-msg" ] \
  && ok "and writes no shim at the path git has stopped reading" \
  || bad "setup wrote a shim git ignores" "$(ls -1 "$E/.git/hooks" 2>&1)"

echo "=== setup outside a work tree says so, rather than working somewhere else ==="
# The first probe of all. Unread, its empty answer is a change of directory
# that stays put, and the run would go on to blame the installer for a
# verdict it never reached.
NOREPO="$TMP/no-repo"
mkdir -p "$NOREPO"
RC=0
OUT="$(cd "$NOREPO" && "$R/tools/setup" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"hooks armed"*) false ;; *"not inside a git work tree"*) true ;; *) false ;; esac \
  && ok "setup run outside a work tree names that, not the installer" \
  || bad "setup run outside a work tree names that, not the installer" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
