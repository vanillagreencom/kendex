#!/usr/bin/env bash
# Pins for scripts/install-git-hooks and the shims it writes: the chain
# blocks a real `git commit` from any tool, every "cannot run" lane blocks
# too, existing hooks survive the install, and re-installing is a no-op.
# Every blocking pin is paired with the passing control that proves the
# commit was blocked by the guard and not by the fixture.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TMP, TMPDIR and the git isolation come from the harness. This suite carried
# its own HOME/XDG_CONFIG_HOME/GIT_CONFIG_NOSYSTEM and was still not hermetic:
# GIT_CONFIG_GLOBAL, GIT_TEMPLATE_DIR, GIT_DIR and the environment-borne
# GIT_CONFIG_* channels all reached its fixtures.
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
INSTALL="$SKILL_DIR/scripts/install-git-hooks"

unset GROWTH_GUARDS_CHECKS GROWTH_GUARDS_PRE_COMMIT_LOCAL GROWTH_GUARDS_SETTINGS_FILE \
  GROWTH_GUARDS_COMMIT_TYPES SIZE_RATCHET_THRESHOLD 2>/dev/null || true

# Marker words are assembled from split tokens so this file never contains a
# marker shape itself — the vstack repo runs todo-ban over its own tree.
TD="TO""DO"
FX="FIX""ME"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

# A consumer project carries its skills under .agents/skills, and the
# installer it runs is the one installed THERE — so the tests exercise the
# same path resolution a consumer gets, and can take the tree away again.
new_repo() { # NAME -> repo path on stdout
  local r="$TMP/$1"
  mkdir -p "$r/.agents/skills"
  git -C "$r" -c init.defaultBranch=main init -q
  git -C "$r" config user.email test@example.com
  git -C "$r" config user.name test
  # A real directory, the shape a project install has: path resolution and
  # the shared-worktree check both key on where the copy physically is.
  cp -R "$SKILL_DIR" "$r/.agents/skills/growth-guards"
  ln -s "$SKILL_DIR/../size-ratchet" "$r/.agents/skills/size-ratchet"
  printf '%s' "$r"
}

install_in() { # REPO — sets OUT and RC
  local installer="$1/.agents/skills/growth-guards/scripts/install-git-hooks"
  [ -x "$installer" ] || installer="$INSTALL"
  OUT=""
  RC=0
  OUT="$("$installer" --repo "$1" 2>&1)" || RC=$?
}

commit_in() { # REPO MSG — sets OUT and RC
  OUT=""
  RC=0
  OUT="$(git -C "$1" commit -m "$2" 2>&1)" || RC=$?
}

echo "=== install lands both shims and the helper ==="
R="$(new_repo basic)"
install_in "$R"
[ "$RC" -eq 0 ] && ok "installer exits 0" || bad "installer exits 0" "rc=$RC out=$OUT"
case "$OUT" in
  *"pre-commit and commit-msg armed"*) ok "summary line names both shims" ;;
  *) bad "summary line names both shims" "out=$OUT" ;;
esac
for f in vstack-guards pre-commit commit-msg; do
  [ -x "$R/.git/hooks/$f" ] && ok "$f is executable" || bad "$f is executable" "missing or not +x"
done
sh -n "$R/.git/hooks/vstack-guards" 2>/dev/null && ok "the helper is POSIX-sh clean" || bad "helper is POSIX-sh clean"
grep -qF "installed_scripts='$R/.agents/skills/growth-guards/scripts'" "$R/.git/hooks/vstack-guards" \
  && ok "the helper names the scripts directory it was installed from" || bad "helper names its scripts dir"
grep -qF 'vstack-guards' "$R/.git/hooks/pre-commit" && ok "pre-commit carries the marked delegating line" \
  || bad "pre-commit carries the marked line"
[ -z "$(git -C "$R" config --get core.hooksPath || true)" ] && ok "core.hooksPath is left unset" \
  || bad "core.hooksPath is left unset"

echo "=== a clean commit passes (control for every blocking pin below) ==="
printf 'hello\n' >"$R/a.txt"
git -C "$R" add a.txt
commit_in "$R" "feat: add a"
[ "$RC" -eq 0 ] && ok "clean staged content + conventional message commits" || bad "clean commit passes" "rc=$RC out=$OUT"

echo "=== growth-guards violations block the commit ==="
printf '# %s: finish this\n' "$TD" >"$R/b.py"
git -C "$R" add b.py
commit_in "$R" "feat: add b"
[ "$RC" -ne 0 ] && ok "a staged work marker blocks" || bad "staged work marker blocks" "rc=$RC out=$OUT"
case "$OUT" in
  *"do the work now, or move it to the tracker"*) ok "the check's own remediation text reaches the committer" ;;
  *) bad "remediation text reaches the committer" "out=$OUT" ;;
esac
git -C "$R" rm -q --cached b.py
rm -f "$R/b.py"

echo "=== commit-msg blocks a non-conventional header ==="
printf 'ok\n' >"$R/c.txt"
git -C "$R" add c.txt
commit_in "$R" "just some words"
[ "$RC" -ne 0 ] && ok "a non-conventional message blocks" || bad "non-conventional message blocks" "rc=$RC out=$OUT"
case "$OUT" in
  *"expected: type(scope)"*) ok "commit-msg remediation text reaches the committer" ;;
  *) bad "commit-msg remediation reaches the committer" "out=$OUT" ;;
esac
commit_in "$R" "feat: add c"
[ "$RC" -eq 0 ] && ok "control: the same staged content commits with a conventional message" \
  || bad "control: conventional message commits" "rc=$RC out=$OUT"

echo "=== size-ratchet is in the chain ==="
printf '[env]\nSIZE_RATCHET_THRESHOLD = "5"\n' >"$R/vstack.settings.toml"
git -C "$R" add vstack.settings.toml
commit_in "$R" "chore: settings"
[ "$RC" -eq 0 ] && ok "control: a small file passes under the lowered threshold" || bad "control: small file passes" "rc=$RC out=$OUT"
seq 1 20 >"$R/big.txt"
git -C "$R" add big.txt
commit_in "$R" "feat: add big"
[ "$RC" -ne 0 ] && ok "an unbaselined over-threshold file blocks" || bad "size-ratchet blocks" "rc=$RC out=$OUT"
case "$OUT" in
  *size-ratchet*) ok "size-ratchet names itself in the blocked output" ;;
  *) bad "size-ratchet names itself" "out=$OUT" ;;
esac
git -C "$R" rm -q --cached big.txt
rm -f "$R/big.txt" "$R/vstack.settings.toml"
git -C "$R" rm -q --cached vstack.settings.toml
commit_in "$R" "chore: drop settings"
[ "$RC" -eq 0 ] && ok "control: the repo commits again once the offender is gone" || bad "control: repo commits again" "rc=$RC out=$OUT"

echo "=== a broken size-ratchet install blocks, never skips ==="
R21="$(new_repo brokenratchet)"
install_in "$R21"
printf 'hello\n' >"$R21/a.txt"
git -C "$R21" add a.txt
rm "$R21/.agents/skills/size-ratchet"
ln -s "$TMP/no-such-skill" "$R21/.agents/skills/size-ratchet"
commit_in "$R21" "feat: add a"
[ "$RC" -ne 0 ] && ok "a dangling size-ratchet install blocks" || bad "dangling size-ratchet blocks" "rc=$RC out=$OUT"
case "$OUT" in
  *"size-ratchet skill is installed"*) ok "the broken size-ratchet install is named" ;;
  *) bad "broken size-ratchet named" "out=$OUT" ;;
esac
rm "$R21/.agents/skills/size-ratchet"
commit_in "$R21" "feat: add a"
[ "$RC" -eq 0 ] && ok "control: an absent size-ratchet is a stated skip" || bad "absent size-ratchet skips" "rc=$RC out=$OUT"
case "$OUT" in
  *"size-ratchet not installed — skipped"*) ok "the skip says the skill is not installed" ;;
  *) bad "skip states not installed" "out=$OUT" ;;
esac

echo "=== the chain reads its own configuration from the commit ==="
R27="$(new_repo stagedsettings)"
printf '.agents/\n' >"$R27/.gitignore"
printf '[env]\nGROWTH_GUARDS_CHECKS = "todo-ban"\n' >"$R27/vstack.settings.toml"
printf 'hello\n' >"$R27/a.txt"
git -C "$R27" add -A
install_in "$R27"
commit_in "$R27" "feat: seed"
[ "$RC" -eq 0 ] && ok "control: the seed commit lands" || bad "staged-settings seed" "rc=$RC out=$OUT"
printf '# %s: nope\n' "$TD" >"$R27/b.py"
git -C "$R27" add b.py
# Switched off on disk only: the commit keeps todo-ban enabled.
printf '[env]\nGROWTH_GUARDS_CHECKS = "byte-ceiling"\n' >"$R27/vstack.settings.toml"
commit_in "$R27" "feat: add b"
[ "$RC" -ne 0 ] && ok "an unstaged settings edit cannot switch a check off" \
  || bad "unstaged settings edit ignored" "rc=$RC out=$OUT"
git -C "$R27" add vstack.settings.toml
commit_in "$R27" "feat: add b"
[ "$RC" -eq 0 ] && ok "control: staging that edit applies it" || bad "staged settings edit applies" "rc=$RC out=$OUT"

R27B="$(new_repo stagedtypes)"
printf '.agents/\n' >"$R27B/.gitignore"
printf '[env]\nGROWTH_GUARDS_COMMIT_TYPES = "feat"\n' >"$R27B/vstack.settings.toml"
printf 'hello\n' >"$R27B/a.txt"
git -C "$R27B" add -A
install_in "$R27B"
commit_in "$R27B" "feat: seed"
[ "$RC" -eq 0 ] && ok "control: the committed type list admits its own type" || bad "staged-types seed" "rc=$RC out=$OUT"
printf 'more\n' >"$R27B/b.txt"
git -C "$R27B" add b.txt
# Widened on disk only: the commit still permits only feat.
printf '[env]\nGROWTH_GUARDS_COMMIT_TYPES = "hack"\n' >"$R27B/vstack.settings.toml"
commit_in "$R27B" "hack: sneak a type in"
[ "$RC" -ne 0 ] && ok "an unstaged commit-type edit does not widen the message gate" \
  || bad "unstaged commit types ignored" "rc=$RC out=$OUT"
git -C "$R27B" add vstack.settings.toml
commit_in "$R27B" "hack: sneak a type in"
[ "$RC" -eq 0 ] && ok "control: staging that edit applies it" || bad "staged commit types apply" "rc=$RC out=$OUT"

echo "=== the size gate judges the staged blob, not the worktree copy ==="
R23="$(new_repo stagedsize)"
printf '.agents/\n' >"$R23/.gitignore"
printf '[env]\nSIZE_RATCHET_THRESHOLD = "5"\n' >"$R23/vstack.settings.toml"
seq 1 4 >"$R23/f.txt"
git -C "$R23" add -A
install_in "$R23"
commit_in "$R23" "feat: seed"
[ "$RC" -eq 0 ] && ok "control: the seed commit lands" || bad "staged-size seed commits" "rc=$RC out=$OUT"
seq 1 20 >"$R23/f.txt"
git -C "$R23" add f.txt
seq 1 4 >"$R23/f.txt"
commit_in "$R23" "feat: staged growth"
[ "$RC" -ne 0 ] && ok "staged growth hidden by a reverted worktree copy still blocks" \
  || bad "hidden staged growth blocks" "rc=$RC out=$OUT"
case "$OUT" in
  *"new offender: f.txt"*) ok "the blocked commit names the staged blob" ;;
  *) bad "blocked commit names the blob" "out=$OUT" ;;
esac

echo "=== the repo-local entry runs last and blocks ==="
mkdir -p "$R/tools"
printf '#!/bin/sh\necho "repo-local check ran"\nexit 0\n' >"$R/tools/local-check"
chmod +x "$R/tools/local-check"
printf '[env]\nGROWTH_GUARDS_PRE_COMMIT_LOCAL = "tools/local-check"\n' >"$R/vstack.settings.toml"
git -C "$R" add tools/local-check vstack.settings.toml
commit_in "$R" "chore: add the repo-local check"
[ "$RC" -eq 0 ] && ok "control: a passing repo-local entry lets the commit through" || bad "control: passing local entry" "rc=$RC out=$OUT"
case "$OUT" in
  *"repo-local check ran"*) ok "the repo-local entry actually ran" ;;
  *) bad "repo-local entry ran" "out=$OUT" ;;
esac
printf '#!/bin/sh\necho "repo-local: nope" >&2\nexit 1\n' >"$R/tools/local-check"
printf 'x\n' >"$R/d.txt"
git -C "$R" add tools/local-check d.txt
commit_in "$R" "chore: local check now fails"
[ "$RC" -ne 0 ] && ok "a failing repo-local entry blocks" || bad "failing local entry blocks" "rc=$RC out=$OUT"
case "$OUT" in
  *"repo-local: nope"*) ok "the repo-local entry's own output reaches the committer" ;;
  *) bad "repo-local output reaches the committer" "out=$OUT" ;;
esac
rm -f "$R/tools/local-check"
commit_in "$R" "chore: local check now missing"
[ "$RC" -ne 0 ] && ok "a configured-but-missing repo-local entry blocks (fail closed)" \
  || bad "missing local entry blocks" "rc=$RC out=$OUT"
case "$OUT" in
  *GROWTH_GUARDS_PRE_COMMIT_LOCAL*) ok "the missing repo-local entry is named" ;;
  *) bad "missing local entry is named" "out=$OUT" ;;
esac
printf '[env]\nGROWTH_GUARDS_PRE_COMMIT_LOCAL = "../escape"\n' >"$R/vstack.settings.toml"
commit_in "$R" "chore: escaping local entry"
[ "$RC" -ne 0 ] && ok "a repo-local entry escaping the repo root blocks" || bad "escaping local entry blocks" "rc=$RC out=$OUT"
rm -f "$R/vstack.settings.toml"
git -C "$R" checkout -q -- . 2>/dev/null || true
git -C "$R" reset -q --hard HEAD

echo "=== a guard that cannot run blocks (fail closed) ==="
R2="$(new_repo failclosed)"
install_in "$R2"
printf 'hello\n' >"$R2/a.txt"
git -C "$R2" add a.txt
H2="$R2/.git/hooks/vstack-guards"
if [ -e "$H2" ]; then
  mv "$H2" "$H2.away"
  commit_in "$R2" "feat: add a"
  [ "$RC" -ne 0 ] && ok "a missing helper blocks" || bad "missing helper blocks" "rc=$RC out=$OUT"
  case "$OUT" in
    *"commit blocked"*) ok "the missing helper says the commit is blocked" ;;
    *) bad "missing helper message" "out=$OUT" ;;
  esac
  mv "$H2.away" "$H2"
else
  bad "missing helper blocks" "fixture: no helper at $H2 to move aside"
  bad "missing helper message" "fixture: no helper at $H2"
fi
mv "$R2/.agents/skills/growth-guards" "$TMP/gg-away"
commit_in "$R2" "feat: add a"
[ "$RC" -ne 0 ] && ok "an uninstalled skill tree blocks" || bad "uninstalled skill tree blocks" "rc=$RC out=$OUT"
case "$OUT" in
  *"no executable growth-guards pre-commit script"*) ok "the unreachable script is named" ;;
  *) bad "unreachable script is named" "out=$OUT" ;;
esac
mv "$TMP/gg-away" "$R2/.agents/skills/growth-guards"
commit_in "$R2" "feat: add a"
[ "$RC" -eq 0 ] && ok "control: the same commit lands once the guard can run" || bad "control: commit lands again" "rc=$RC out=$OUT"

echo "=== a stale baked path falls back to rediscovery ==="
R2B="$(new_repo rediscover)"
install_in "$R2B"
mv "$R2B/.agents/skills/growth-guards" "$R2B/.agents/skills/growth-guards.moved"
sed -i.bak "s|^installed_scripts=.*|installed_scripts='$R2B/gone/scripts'|" "$R2B/.git/hooks/vstack-guards"
rm -f "$R2B/.git/hooks/vstack-guards.bak"
mv "$R2B/.agents/skills/growth-guards.moved" "$R2B/.agents/skills/growth-guards"
printf 'hello\n' >"$R2B/a.txt"
git -C "$R2B" add a.txt
commit_in "$R2B" "feat: add a"
[ "$RC" -eq 0 ] && ok "a stale baked path is rediscovered under .agents/skills" || bad "stale baked path rediscovered" "rc=$RC out=$OUT"
printf '# %s: nope\n' "$TD" >"$R2B/b.py"
git -C "$R2B" add b.py
commit_in "$R2B" "feat: add b"
[ "$RC" -ne 0 ] && ok "control: the rediscovered chain still blocks" || bad "rediscovered chain blocks" "rc=$RC out=$OUT"

echo "=== a guard that cannot run exits 2, not 1 ==="
R2C="$(new_repo exitcode)"
install_in "$R2C"
mv "$R2C/.git/hooks/vstack-guards" "$R2C/.git/hooks/vstack-guards.away"
RC=0; (cd "$R2C" && .git/hooks/pre-commit >/dev/null 2>&1) || RC=$?
[ "$RC" -eq 2 ] && ok "a missing helper exits 2 (could not complete)" || bad "missing helper exits 2" "rc=$RC"
mv "$R2C/.git/hooks/vstack-guards.away" "$R2C/.git/hooks/vstack-guards"
mv "$R2C/.agents/skills/growth-guards" "$TMP/gg-away2"
RC=0; (cd "$R2C" && .git/hooks/pre-commit >/dev/null 2>&1) || RC=$?
[ "$RC" -eq 2 ] && ok "an unreachable script exits 2 (could not complete)" || bad "unreachable script exits 2" "rc=$RC"
mv "$TMP/gg-away2" "$R2C/.agents/skills/growth-guards"
RC=0; (cd "$R2C" && .git/hooks/pre-commit >/dev/null 2>&1) || RC=$?
[ "$RC" -eq 0 ] && ok "control: the same hook exits 0 once the guard can run" || bad "control: hook exits 0" "rc=$RC"

echo "=== uninstall gives the repo back ==="
R12="$(new_repo uninstall)"
printf '#!/bin/sh\necho mine\nexit 0\n' >"$TMP/foreign-pre-commit"
cp "$TMP/foreign-pre-commit" "$R12/.git/hooks/pre-commit"
chmod +x "$R12/.git/hooks/pre-commit"
install_in "$R12"
OUT=""; RC=0
OUT="$("$R12/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R12" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "uninstall exits 0" || bad "uninstall exits 0" "rc=$RC out=$OUT"
[ -e "$R12/.git/hooks/vstack-guards" ] && bad "the helper is removed" || ok "the helper is removed"
[ -e "$R12/.git/hooks/commit-msg" ] && bad "a hook we created is removed outright" || ok "a hook we created is removed outright"
cmp -s "$TMP/foreign-pre-commit" "$R12/.git/hooks/pre-commit" && ok "a consumer's own hook is restored byte-for-byte" \
  || bad "foreign hook restored" "got: $(cat "$R12/.git/hooks/pre-commit")"
[ -x "$R12/.git/hooks/pre-commit" ] && ok "the restored hook keeps its exec bit" || bad "restored hook keeps exec bit"
printf '# %s: now allowed\n' "$TD" >"$R12/b.py"
git -C "$R12" add b.py
commit_in "$R12" "feat: add b"
[ "$RC" -eq 0 ] && ok "commits are unblocked after uninstall" || bad "commits unblocked after uninstall" "rc=$RC out=$OUT"
OUT=""; RC=0
OUT="$("$R12/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R12" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "a repeat uninstall is a no-op" || bad "repeat uninstall" "rc=$RC out=$OUT"
case "$OUT" in
  *"nothing to remove"*) ok "the repeat uninstall says there was nothing to remove" ;;
  *) bad "repeat uninstall says nothing to remove" "out=$OUT" ;;
esac
R13="$(new_repo uninstall-foreign)"
printf '#!/bin/sh\nexit 0\n' >"$R13/.git/hooks/vstack-guards"
FOREIGN_HELPER="$(cat "$R13/.git/hooks/vstack-guards")"
OUT=""; RC=0
OUT="$("$R13/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R13" --uninstall 2>&1)" || RC=$?
[ "$FOREIGN_HELPER" = "$(cat "$R13/.git/hooks/vstack-guards")" ] && ok "uninstall never deletes a file it did not write" \
  || bad "uninstall leaves foreign helper"

echo "=== existing hooks survive the install ==="
R3="$(new_repo compose)"
printf '#!/bin/sh\ntouch "$(git rev-parse --show-toplevel)/post-checkout-ran"\n' >"$R3/.git/hooks/post-checkout"
chmod +x "$R3/.git/hooks/post-checkout"
POST_BEFORE="$(cat "$R3/.git/hooks/post-checkout")"
printf '#!/bin/sh\ntouch "$(git rev-parse --show-toplevel)/foreign-pre-commit-ran"' >"$R3/.git/hooks/pre-commit"
chmod +x "$R3/.git/hooks/pre-commit"
install_in "$R3"
[ "$RC" -eq 0 ] && ok "installing over existing hooks exits 0" || bad "install over existing hooks" "rc=$RC out=$OUT"
[ "$POST_BEFORE" = "$(cat "$R3/.git/hooks/post-checkout")" ] && ok "an unrelated hook is left byte-identical" \
  || bad "unrelated hook untouched"
grep -qF 'foreign-pre-commit-ran' "$R3/.git/hooks/pre-commit" && ok "foreign pre-commit content is preserved" \
  || bad "foreign pre-commit preserved"
[ "$(grep -cF 'vstack-guards-hook' "$R3/.git/hooks/pre-commit")" -eq 1 ] && ok "our line is added exactly once" \
  || bad "our line added once"
printf 'hello\n' >"$R3/a.txt"
git -C "$R3" add a.txt
commit_in "$R3" "feat: add a"
[ "$RC" -eq 0 ] && ok "control: the composed pre-commit still commits clean content" || bad "composed hook commits" "rc=$RC out=$OUT"
[ -f "$R3/foreign-pre-commit-ran" ] && ok "the foreign pre-commit still ran" || bad "foreign pre-commit still ran"
git -C "$R3" checkout -q -b other
[ -f "$R3/post-checkout-ran" ] && ok "the pre-existing post-checkout hook still fires" || bad "post-checkout still fires"
printf '# %s: nope\n' "$TD" >"$R3/b.py"
git -C "$R3" add b.py
commit_in "$R3" "feat: add b"
[ "$RC" -ne 0 ] && ok "our part still blocks inside a composed hook" || bad "composed hook still blocks" "rc=$RC out=$OUT"
git -C "$R3" reset -q --hard HEAD
rm -f "$R3/b.py"

echo "=== a foreign hook that exits cannot skip the guard ==="
R3B="$(new_repo terminalexit)"
printf '#!/bin/sh\ntouch "$(git rev-parse --show-toplevel)/foreign-ran"\nexit 0\n' >"$R3B/.git/hooks/pre-commit"
chmod +x "$R3B/.git/hooks/pre-commit"
install_in "$R3B"
printf '# %s: nope\n' "$TD" >"$R3B/b.py"
git -C "$R3B" add b.py
commit_in "$R3B" "feat: add b"
[ "$RC" -ne 0 ] && ok "a hook ending in 'exit 0' still runs our guard" || bad "terminal exit 0 still guarded" "rc=$RC out=$OUT"
rm -f "$R3B/b.py"
git -C "$R3B" rm -q --cached b.py
printf 'hello\n' >"$R3B/a.txt"
git -C "$R3B" add a.txt
commit_in "$R3B" "feat: add a"
[ "$RC" -eq 0 ] && ok "control: clean content commits through the same hook" || bad "control: terminal-exit hook commits" "rc=$RC out=$OUT"
[ -f "$R3B/foreign-ran" ] && ok "the foreign hook still ran after ours" || bad "foreign hook still ran"

echo "=== a foreign hook's own nonzero verdict is preserved ==="
R4="$(new_repo transparent)"
printf '#!/bin/sh\necho "foreign says no" >&2\nexit 3\n' >"$R4/.git/hooks/pre-commit"
chmod +x "$R4/.git/hooks/pre-commit"
install_in "$R4"
printf 'hello\n' >"$R4/a.txt"
git -C "$R4" add a.txt
commit_in "$R4" "feat: add a"
[ "$RC" -ne 0 ] && ok "a foreign hook that refuses still refuses after our append" || bad "foreign refusal preserved" "rc=$RC out=$OUT"
case "$OUT" in
  *"foreign says no"*) ok "the foreign hook's own message reaches the committer" ;;
  *) bad "foreign message reaches committer" "out=$OUT" ;;
esac

echo "=== hooks the installer must not touch ==="
R5="$(new_repo refuse)"
mkdir -p "$TMP/elsewhere"
printf '#!/bin/sh\nexit 0\n' >"$TMP/elsewhere/shared-pre-commit"
chmod +x "$TMP/elsewhere/shared-pre-commit"
ln -s "$TMP/elsewhere/shared-pre-commit" "$R5/.git/hooks/pre-commit"
SHARED_BEFORE="$(cat "$TMP/elsewhere/shared-pre-commit")"
install_in "$R5"
[ "$RC" -eq 1 ] && ok "a symlinked hook makes the install incomplete (exit 1)" || bad "symlinked hook exit 1" "rc=$RC out=$OUT"
[ -L "$R5/.git/hooks/pre-commit" ] && ok "the symlink itself is left in place" || bad "symlink left in place"
[ "$SHARED_BEFORE" = "$(cat "$TMP/elsewhere/shared-pre-commit")" ] && ok "the symlink target is not written through" \
  || bad "symlink target untouched"
grep -qF 'vstack-guards' "$R5/.git/hooks/commit-msg" && ok "the other hook is still installed" || bad "other hook installed"

R6="$(new_repo disabled)"
printf '#!/bin/sh\nexit 0\n' >"$R6/.git/hooks/pre-commit"
chmod -x "$R6/.git/hooks/pre-commit"
install_in "$R6"
[ "$RC" -eq 1 ] && ok "a disabled (non-executable) hook is not appended to" || bad "disabled hook not appended" "rc=$RC out=$OUT"
grep -qF 'vstack-guards' "$R6/.git/hooks/pre-commit" && bad "disabled hook left untouched" || ok "disabled hook left untouched"

R6B="$(new_repo mentions)"
printf '#!/bin/sh\n# see .git/hooks/vstack-guards for the shared guard\nexit 0\n' >"$R6B/.git/hooks/pre-commit"
chmod +x "$R6B/.git/hooks/pre-commit"
install_in "$R6B"
grep -qF 'vstack-guards-hook' "$R6B/.git/hooks/pre-commit" \
  && ok "a hook that merely mentions the helper still gets the guard" || bad "hook mentioning the helper is still guarded"

R7="$(new_repo notshell)"
printf '#!/usr/bin/env python3\nraise SystemExit(0)\n' >"$R7/.git/hooks/pre-commit"
chmod +x "$R7/.git/hooks/pre-commit"
install_in "$R7"
[ "$RC" -eq 1 ] && ok "a non-shell hook is not appended to" || bad "non-shell hook not appended" "rc=$RC out=$OUT"
grep -qF 'vstack-guards' "$R7/.git/hooks/pre-commit" && bad "non-shell hook left untouched" || ok "non-shell hook left untouched"

echo "=== core.hooksPath is honoured, never overridden ==="
R8="$(new_repo hookspath)"
mkdir -p "$R8/myhooks"
git -C "$R8" config core.hooksPath myhooks
install_in "$R8"
[ "$RC" -eq 0 ] && ok "core.hooksPath makes the install a stated skip, not a failure" || bad "hooksPath skip exit 0" "rc=$RC out=$OUT"
case "$OUT" in
  *"skipped — core.hooksPath is set"*) ok "the skip says why" ;;
  *) bad "skip says why" "out=$OUT" ;;
esac
[ "$(git -C "$R8" config --get core.hooksPath)" = "myhooks" ] && ok "core.hooksPath is left as the repo set it" \
  || bad "core.hooksPath untouched"
R8B="$(new_repo hookspath-empty)"
git -C "$R8B" config core.hooksPath ""
install_in "$R8B"
[ "$RC" -eq 0 ] && ok "an empty core.hooksPath is a stated skip too" || bad "empty hooksPath skip" "rc=$RC out=$OUT"
case "$OUT" in
  *"skipped — core.hooksPath is set"*) ok "and it says why" ;;
  *) bad "empty hooksPath says why" "out=$OUT" ;;
esac
[ -e "$R8B/.git/hooks/pre-commit" ] && bad "no shim is written under an empty core.hooksPath" \
  || ok "no shim is written under an empty core.hooksPath"
[ -e "$R8/.git/hooks/pre-commit" ] && bad "no shim is written when hooks are redirected" \
  || ok "no shim is written when hooks are redirected"

echo "=== the helper is owned, repaired, and never stolen ==="
R9="$(new_repo helper)"
install_in "$R9"
FRESH="$(cat "$R9/.git/hooks/vstack-guards")"
printf '#!/bin/sh\n# vstack growth-guards git hooks\nexit 0\n' >"$R9/.git/hooks/vstack-guards"
install_in "$R9"
[ "$RC" -eq 0 ] && [ "$FRESH" = "$(cat "$R9/.git/hooks/vstack-guards")" ] && ok "a stale helper of ours is rewritten" \
  || bad "stale helper rewritten" "rc=$RC"
printf '#!/bin/sh\nexit 0\n' >"$R9/.git/hooks/vstack-guards"
FOREIGN="$(cat "$R9/.git/hooks/vstack-guards")"
install_in "$R9"
[ "$RC" -eq 1 ] && ok "a foreign file at the helper path aborts the install" || bad "foreign helper aborts" "rc=$RC out=$OUT"
[ "$FOREIGN" = "$(cat "$R9/.git/hooks/vstack-guards")" ] && ok "the foreign file is left untouched" || bad "foreign helper untouched"
rm "$R9/.git/hooks/vstack-guards"
mkdir "$R9/.git/hooks/vstack-guards"
install_in "$R9"
[ "$RC" -eq 1 ] && ok "a non-regular file at the helper path aborts the install" || bad "non-regular helper aborts" "rc=$RC out=$OUT"
rmdir "$R9/.git/hooks/vstack-guards"

echo "=== re-installing is a no-op ==="
R10="$(new_repo idempotent)"
install_in "$R10"
BEFORE_HELPER="$(cat "$R10/.git/hooks/vstack-guards")"
BEFORE_PRE="$(cat "$R10/.git/hooks/pre-commit")"
BEFORE_MSG="$(cat "$R10/.git/hooks/commit-msg")"
install_in "$R10"
install_in "$R10"
[ "$RC" -eq 0 ] && ok "a repeat install exits 0" || bad "repeat install exits 0" "rc=$RC out=$OUT"
[ "$BEFORE_HELPER" = "$(cat "$R10/.git/hooks/vstack-guards")" ] && ok "the helper is unchanged" || bad "helper unchanged"
[ "$BEFORE_PRE" = "$(cat "$R10/.git/hooks/pre-commit")" ] && ok "pre-commit is unchanged" || bad "pre-commit unchanged"
[ "$BEFORE_MSG" = "$(cat "$R10/.git/hooks/commit-msg")" ] && ok "commit-msg is unchanged" || bad "commit-msg unchanged"

echo "=== linked worktrees share the install ==="
R11="$(new_repo worktree)"
install_in "$R11"
printf 'hello\n' >"$R11/a.txt"
git -C "$R11" add a.txt
commit_in "$R11" "feat: add a"
[ "$RC" -eq 0 ] && ok "seed commit lands" || bad "seed commit lands" "rc=$RC out=$OUT"
git -C "$R11" worktree add -q "$TMP/wt" -b wtb
printf 'hello\n' >"$TMP/wt/w.txt"
git -C "$TMP/wt" add w.txt
OUT=""; RC=0; OUT="$(git -C "$TMP/wt" commit -m "feat: from the worktree" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "control: a clean commit from a linked worktree passes" || bad "worktree clean commit" "rc=$RC out=$OUT"
printf '# %s: nope\n' "$FX" >"$TMP/wt/w.py"
git -C "$TMP/wt" add w.py
OUT=""; RC=0; OUT="$(git -C "$TMP/wt" commit -m "feat: from the worktree" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && ok "a linked worktree gets the guard chain too" || bad "worktree commit blocked" "rc=$RC out=$OUT"

echo "=== an armed hook git will not execute is not armed ==="
R14="$(new_repo execbit)"
install_in "$R14"
chmod -x "$R14/.git/hooks/pre-commit"
install_in "$R14"
[ -x "$R14/.git/hooks/pre-commit" ] && ok "a cleared executable bit is repaired by the next install" \
  || bad "cleared exec bit repaired"
[ "$RC" -eq 0 ] && ok "the repair install exits 0" || bad "repair install exits 0" "rc=$RC out=$OUT"

echo "=== a disabled delegate is not an install ==="
R20="$(new_repo tampered)"
install_in "$R20"
ORIGINAL_PRE="$(cat "$R20/.git/hooks/pre-commit")"
sed -i.bak 's|^vstack_gg_h=|#vstack_gg_h=|' "$R20/.git/hooks/pre-commit"
rm -f "$R20/.git/hooks/pre-commit.bak"
grep -qF 'vstack-guards-hook' "$R20/.git/hooks/pre-commit" && ok "the tampered line still carries the sentinel (fixture)" \
  || bad "tampered fixture keeps the sentinel"
install_in "$R20"
[ "$ORIGINAL_PRE" = "$(cat "$R20/.git/hooks/pre-commit")" ] && ok "a commented-out delegate is restored, not trusted" \
  || bad "commented-out delegate restored" "got: $(cat "$R20/.git/hooks/pre-commit")"
printf '# %s: nope\n' "$TD" >"$R20/b.py"
git -C "$R20" add b.py
commit_in "$R20" "feat: add b"
[ "$RC" -ne 0 ] && ok "control: the restored delegate blocks again" || bad "restored delegate blocks" "rc=$RC out=$OUT"
git -C "$R20" reset -q; rm -f "$R20/b.py"
printf '#!/bin/sh\nold_delegate_from_a_previous_version  # vstack-guards-hook\necho mine\n' >"$R20/.git/hooks/commit-msg"
chmod +x "$R20/.git/hooks/commit-msg"
install_in "$R20"
[ "$(grep -cF 'vstack-guards-hook' "$R20/.git/hooks/commit-msg")" -eq 1 ] \
  && ok "a stale delegate is replaced, not duplicated" || bad "stale delegate replaced"
grep -qF 'echo mine' "$R20/.git/hooks/commit-msg" && ok "the rest of that hook survives the replacement" \
  || bad "rest of hook survives replacement"

R28="$(new_repo moveddelegate)"
install_in "$R28"
DELEGATE="$(sed -n '2p' "$R28/.git/hooks/pre-commit")"
# Same line, moved below content that exits: present, but unreachable.
printf '#!/bin/sh\necho mine\nexit 0\n%s\n' "$DELEGATE" >"$R28/.git/hooks/pre-commit"
install_in "$R28"
[ "$(sed -n '2p' "$R28/.git/hooks/pre-commit")" = "$DELEGATE" ] \
  && ok "a delegate moved below a terminal command is repositioned" \
  || bad "moved delegate repositioned" "line2=$(sed -n '2p' "$R28/.git/hooks/pre-commit")"
[ "$(grep -cF 'vstack-guards-hook' "$R28/.git/hooks/pre-commit")" -eq 1 ] \
  && ok "and it is not duplicated" || bad "moved delegate duplicated"
printf '# %s: nope\n' "$TD" >"$R28/b.py"
git -C "$R28" add b.py
commit_in "$R28" "feat: add b"
[ "$RC" -ne 0 ] && ok "control: the repositioned delegate blocks again" || bad "repositioned delegate blocks" "rc=$RC out=$OUT"

echo "=== a non-POSIX-shell hook is left alone ==="
R15="$(new_repo fish)"
printf '#!/usr/bin/fish\necho hi\n' >"$R15/.git/hooks/pre-commit"
chmod +x "$R15/.git/hooks/pre-commit"
install_in "$R15"
[ "$RC" -eq 1 ] && ok "a fish hook is not modified (exit 1)" || bad "fish hook not modified" "rc=$RC out=$OUT"
grep -qF 'vstack-guards-hook' "$R15/.git/hooks/pre-commit" && bad "fish hook left untouched" || ok "fish hook left untouched"

R25="$(new_repo shebang-swapped)"
install_in "$R25"
sed -i.bak '1s|.*|#!/usr/bin/fish|' "$R25/.git/hooks/pre-commit"
rm -f "$R25/.git/hooks/pre-commit.bak"
install_in "$R25"
[ "$RC" -eq 1 ] && ok "our line under an interpreter that cannot run it is not armed" \
  || bad "swapped shebang is not armed" "rc=$RC out=$OUT"
case "$OUT" in
  *"not a POSIX-shell script"*) ok "and the hook is named" ;;
  *) bad "swapped-shebang hook named" "out=$OUT" ;;
esac

echo "=== a bare repository is refused ==="
git -c init.defaultBranch=main init -q --bare "$TMP/bare.git"
OUT=""; RC=0; OUT="$("$INSTALL" --repo "$TMP/bare.git" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && ok "a bare repository is exit 2 (no work tree to guard)" || bad "bare repo is exit 2" "rc=$RC out=$OUT"

echo "=== uninstall still cleans up under core.hooksPath ==="
R16="$(new_repo uninstall-hookspath)"
install_in "$R16"
mkdir -p "$R16/myhooks"
git -C "$R16" config core.hooksPath myhooks
OUT=""; RC=0
OUT="$("$R16/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R16" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "uninstall under core.hooksPath exits 0" || bad "uninstall under hooksPath" "rc=$RC out=$OUT"
[ -e "$R16/.git/hooks/pre-commit" ] && bad "shims are removed even when git is reading elsewhere" \
  || ok "shims are removed even when git is reading elsewhere"

R17B="$(new_repo uninstall-symlink-unreadable)"
install_in "$R17B"
mv "$R17B/.git/hooks/pre-commit" "$TMP/dangling-target"
ln -s "$TMP/dangling-target" "$R17B/.git/hooks/pre-commit"
rm -f "$TMP/dangling-target"
OUT=""; RC=0
OUT="$("$R17B/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R17B" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && ok "a symlinked hook whose target cannot be read fails the uninstall" \
  || bad "unreadable symlink target fails" "rc=$RC out=$OUT"
[ -f "$R17B/.git/hooks/vstack-guards" ] && ok "and the helper is kept" || bad "unreadable symlink keeps helper"

echo "=== uninstall refuses to strand a delegate ==="
R17="$(new_repo uninstall-symlinked)"
install_in "$R17"
mv "$R17/.git/hooks/pre-commit" "$TMP/linked-pre-commit"
ln -s "$TMP/linked-pre-commit" "$R17/.git/hooks/pre-commit"
OUT=""; RC=0
OUT="$("$R17/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R17" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && ok "a symlinked hook carrying our line fails the uninstall" || bad "symlinked uninstall fails" "rc=$RC out=$OUT"
[ -f "$R17/.git/hooks/vstack-guards" ] && ok "the helper is kept while a delegate survives" || bad "helper kept while delegate survives"

R24="$(new_repo unreadable-hook)"
install_in "$R24"
chmod 0300 "$R24/.git/hooks/pre-commit"
OUT=""; RC=0
OUT="$("$R24/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R24" --uninstall 2>&1)" || RC=$?
chmod 0755 "$R24/.git/hooks/pre-commit" 2>/dev/null || true
[ "$RC" -eq 1 ] && ok "an unreadable managed hook fails the uninstall" || bad "unreadable hook fails uninstall" "rc=$RC out=$OUT"
[ -f "$R24/.git/hooks/vstack-guards" ] && ok "and the helper is kept beside it" || bad "unreadable hook keeps helper"

echo "=== a shared hooks directory outlives one work tree ==="
R18="$(new_repo shared)"
install_in "$R18"
printf 'hello\n' >"$R18/a.txt"
git -C "$R18" add a.txt
commit_in "$R18" "feat: add a"
git -C "$R18" worktree add -q "$TMP/wt2" -b wt2b
mkdir -p "$TMP/wt2/.agents/skills"
OUT=""; RC=0
OUT="$("$R18/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$TMP/wt2" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "uninstalling from a work tree without the skill exits 0" || bad "worktree uninstall exits 0" "rc=$RC out=$OUT"
case "$OUT" in
  *"kept —"*) ok "the shared shims are kept while another work tree has the skill" ;;
  *) bad "shared shims kept" "out=$OUT" ;;
esac
[ -f "$R18/.git/hooks/vstack-guards" ] && ok "the main checkout keeps its guard" || bad "main checkout keeps its guard"

R18C="$(new_repo shared-retarget)"
install_in "$R18C"
printf 'hello\n' >"$R18C/a.txt"
git -C "$R18C" add a.txt
commit_in "$R18C" "feat: add a"
git -C "$R18C" worktree add -q "$TMP/wt4" -b wt4b
mkdir -p "$TMP/wt4/.agents/skills"
cp -R "$SKILL_DIR" "$TMP/wt4/.agents/skills/growth-guards"
ln -s "$SKILL_DIR/../size-ratchet" "$TMP/wt4/.agents/skills/size-ratchet"
OUT=""; RC=0
OUT="$("$R18C/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R18C" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "uninstalling the checkout the helper points at exits 0" || bad "retarget uninstall exits 0" "rc=$RC out=$OUT"
grep -qF "installed_scripts='$TMP/wt4/.agents/skills/growth-guards/scripts'" "$R18C/.git/hooks/vstack-guards" \
  && ok "the kept helper is retargeted at the surviving install" || bad "kept helper retargeted" "out=$OUT"
rm -rf -- "$R18C/.agents/skills/growth-guards"
printf 'hello\n' >"$TMP/wt4/w.txt"
git -C "$TMP/wt4" add w.txt
OUT=""; RC=0; OUT="$(git -C "$TMP/wt4" commit -m "feat: from the surviving worktree" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "the surviving work tree still commits through the retargeted helper" \
  || bad "surviving worktree commits" "rc=$RC out=$OUT"

R18B="$(new_repo shared-linked)"
install_in "$R18B"
printf 'hello\n' >"$R18B/a.txt"
git -C "$R18B" add a.txt
commit_in "$R18B" "feat: add a"
git -C "$R18B" worktree add -q "$TMP/wt3" -b wt3b
# The worktree layout this repo uses: .agents links back into the checkout
# being uninstalled from, so its copy is the one going away.
ln -s "$R18B/.agents" "$TMP/wt3/.agents"
OUT=""; RC=0
OUT="$("$R18B/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R18B" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "uninstall from the checkout that owns the install exits 0" || bad "owning uninstall exits 0" "rc=$RC out=$OUT"
[ -e "$R18B/.git/hooks/vstack-guards" ] && bad "a work tree linking back to this install does not keep the shims" \
  || ok "a work tree linking back to this install does not keep the shims"

R18D="$(new_repo shared-cursor)"
install_in "$R18D"
printf 'hello\n' >"$R18D/a.txt"
git -C "$R18D" add a.txt
commit_in "$R18D" "feat: add a"
git -C "$R18D" worktree add -q "$TMP/wt5" -b wt5b
# A copy-method install for Cursor: a skills root the survivor check must know.
mkdir -p "$TMP/wt5/.cursor/rules"
cp -R "$SKILL_DIR" "$TMP/wt5/.cursor/rules/growth-guards"
OUT=""; RC=0
OUT="$("$R18D/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R18D" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "uninstall beside a Cursor install exits 0" || bad "cursor survivor uninstall exits 0" "rc=$RC out=$OUT"
[ -f "$R18D/.git/hooks/vstack-guards" ] && ok "a survivor under .cursor/rules keeps the shared shims" \
  || bad "cursor survivor keeps shims" "out=$OUT"

R18E="$(new_repo shared-partial)"
install_in "$R18E"
printf 'hello\n' >"$R18E/a.txt"
git -C "$R18E" add a.txt
commit_in "$R18E" "feat: add a"
git -C "$R18E" worktree add -q "$TMP/wt6" -b wt6b
mkdir -p "$TMP/wt6/.agents/skills"
cp -R "$SKILL_DIR" "$TMP/wt6/.agents/skills/growth-guards"
# Half a survivor: it could serve pre-commit but not commit-msg, and both
# hooks would be retained.
rm -f "$TMP/wt6/.agents/skills/growth-guards/scripts/commit-msg"
OUT=""; RC=0
OUT="$("$R18E/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R18E" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "uninstall beside an incomplete install exits 0" || bad "incomplete survivor uninstall" "rc=$RC out=$OUT"
[ -e "$R18E/.git/hooks/commit-msg" ] && bad "an incomplete survivor does not retain the hooks" \
  || ok "an incomplete survivor does not retain the hooks"

R18F="$(new_repo shared-newline)"
install_in "$R18F"
printf 'hello\n' >"$R18F/a.txt"
git -C "$R18F" add a.txt
commit_in "$R18F" "feat: add a"
# A work-tree path git's line-oriented listing cannot represent.
NLDIR="$TMP/odd
name"
git -C "$R18F" worktree add -q "$NLDIR" -b nlb
mkdir -p "$NLDIR/.agents/skills"
cp -R "$SKILL_DIR" "$NLDIR/.agents/skills/growth-guards"
OUT=""; RC=0
OUT="$("$R18F/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R18F" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "a survivor at a newline path is still seen" || bad "newline-path survivor seen" "rc=$RC out=$OUT"
[ -f "$R18F/.git/hooks/vstack-guards" ] && ok "and its shared shims are kept" || bad "newline-path survivor keeps shims" "out=$OUT"

R18G="$(new_repo shared-unreadable)"
install_in "$R18G"
printf 'hello\n' >"$R18G/a.txt"
git -C "$R18G" add a.txt
commit_in "$R18G" "feat: add a"
git -C "$R18G" worktree add -q "$TMP/wt7" -b wt7b
rm -f "$R18G/.git/worktrees/wt7/gitdir"
OUT=""; RC=0
OUT="$("$R18G/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R18G" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && ok "an unreadable work-tree list fails the uninstall" || bad "unreadable worktree list fails" "rc=$RC out=$OUT"
[ -f "$R18G/.git/hooks/vstack-guards" ] && ok "and the shims are kept rather than guessed away" \
  || bad "unreadable list keeps shims"

R18H="$(new_repo shared-relative)"
install_in "$R18H"
printf 'hello\n' >"$R18H/a.txt"
git -C "$R18H" add a.txt
commit_in "$R18H" "feat: add a"
git -C "$R18H" worktree add -q "$TMP/wt8" -b wt8b
mkdir -p "$TMP/wt8/.agents/skills"
cp -R "$SKILL_DIR" "$TMP/wt8/.agents/skills/growth-guards"
ln -s "$SKILL_DIR/../size-ratchet" "$TMP/wt8/.agents/skills/size-ratchet"
# The relocatable-worktree shape: the registration records a RELATIVE path.
printf '../../../../wt8/.git\n' >"$R18H/.git/worktrees/wt8/gitdir"
OUT=""; RC=0
OUT="$("$R18H/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R18H" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "a relatively-registered worktree exits 0" || bad "relative registration exits 0" "rc=$RC out=$OUT"
[ -f "$R18H/.git/hooks/vstack-guards" ] && ok "a survivor behind a relative registration keeps the shims" \
  || bad "relative registration survivor" "out=$OUT"

echo "=== a main work tree that cannot be identified is not ruled out ==="
mkdir -p "$TMP/sgd/main" "$TMP/sgd/gitdir" "$TMP/sgd/main/.agents/skills"
git -c init.defaultBranch=main init -q --separate-git-dir "$TMP/sgd/gitdir" "$TMP/sgd/main"
git -C "$TMP/sgd/main" config user.email test@example.com
git -C "$TMP/sgd/main" config user.name test
cp -R "$SKILL_DIR" "$TMP/sgd/main/.agents/skills/growth-guards"
ln -s "$SKILL_DIR/../size-ratchet" "$TMP/sgd/main/.agents/skills/size-ratchet"
OUT=""; RC=0
OUT="$("$TMP/sgd/main/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$TMP/sgd/main" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "a --separate-git-dir main checkout installs" || bad "separate-git-dir install" "rc=$RC out=$OUT"
git -C "$TMP/sgd/main" commit -q --allow-empty -m "feat: seed"
git -C "$TMP/sgd/main" worktree add -q "$TMP/sgd/wt" -b sgdb
mkdir -p "$TMP/sgd/wt/.agents/skills"
OUT=""; RC=0
OUT="$("$TMP/sgd/main/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$TMP/sgd/wt" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && ok "uninstalling from a linked worktree refuses when the main checkout cannot be located" \
  || bad "separate-git-dir uninstall refuses" "rc=$RC out=$OUT"
[ -f "$TMP/sgd/gitdir/hooks/vstack-guards" ] && ok "and the main checkout keeps its guard" \
  || bad "separate-git-dir main keeps guard" "out=$OUT"
OUT=""; RC=0
OUT="$("$TMP/sgd/main/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$TMP/sgd/main" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "control: uninstalling from the main checkout itself still works" \
  || bad "separate-git-dir main uninstall" "rc=$RC out=$OUT"

if [ "$(id -u)" != "0" ]; then
  R18I="$(new_repo shared-unsearchable)"
  install_in "$R18I"
  printf 'hello\n' >"$R18I/a.txt"
  git -C "$R18I" add a.txt
  commit_in "$R18I" "feat: add a"
  mkdir -p "$TMP/locked"
  git -C "$R18I" worktree add -q "$TMP/locked/wt9" -b wt9b
  mkdir -p "$TMP/locked/wt9/.agents/skills"
  cp -R "$SKILL_DIR" "$TMP/locked/wt9/.agents/skills/growth-guards"
  chmod 000 "$TMP/locked"
  OUT=""; RC=0
  OUT="$("$R18I/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R18I" --uninstall 2>&1)" || RC=$?
  chmod 755 "$TMP/locked"
  [ "$RC" -eq 1 ] && ok "a registered work tree that cannot be inspected fails the uninstall" \
    || bad "unsearchable worktree fails" "rc=$RC out=$OUT"
  [ -f "$R18I/.git/hooks/vstack-guards" ] && ok "and the shared shims are kept" \
    || bad "unsearchable worktree keeps shims"

  R18J="$(new_repo shared-deep-unsearchable)"
  install_in "$R18J"
  printf 'hello\n' >"$R18J/a.txt"
  git -C "$R18J" add a.txt
  commit_in "$R18J" "feat: add a"
  mkdir -p "$TMP/deeplocked/user"
  git -C "$R18J" worktree add -q "$TMP/deeplocked/user/wt10" -b wt10b
  mkdir -p "$TMP/deeplocked/user/wt10/.agents/skills"
  cp -R "$SKILL_DIR" "$TMP/deeplocked/user/wt10/.agents/skills/growth-guards"
  chmod 000 "$TMP/deeplocked"
  OUT=""; RC=0
  OUT="$("$R18J/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R18J" --uninstall 2>&1)" || RC=$?
  chmod 755 "$TMP/deeplocked"
  [ "$RC" -eq 1 ] && ok "an unsearchable GRANDparent also fails the uninstall" \
    || bad "deep unsearchable worktree fails" "rc=$RC out=$OUT"
  [ -f "$R18J/.git/hooks/vstack-guards" ] && ok "and those shared shims are kept too" \
    || bad "deep unsearchable keeps shims"
else
  ok "unsearchable-work-tree case skipped (running as root)"
  ok "unsearchable-work-tree keep skipped (running as root)"
  ok "deep unsearchable-work-tree case skipped (running as root)"
  ok "deep unsearchable-work-tree keep skipped (running as root)"
fi

echo "=== a copy-method install is rediscovered ==="
R19="$(new_repo copymethod)"
install_in "$R19"
mkdir -p "$R19/.claude/skills"
mv "$R19/.agents/skills/growth-guards" "$R19/.claude/skills/growth-guards"
sed -i.bak "s|^installed_scripts=.*|installed_scripts='$R19/gone/scripts'|" "$R19/.git/hooks/vstack-guards"
rm -f "$R19/.git/hooks/vstack-guards.bak"
printf 'hello\n' >"$R19/a.txt"
git -C "$R19" add a.txt
commit_in "$R19" "feat: add a"
[ "$RC" -eq 0 ] && ok "a skill under .claude/skills is rediscovered" || bad ".claude/skills rediscovered" "rc=$RC out=$OUT"
printf '# %s: nope\n' "$TD" >"$R19/b.py"
git -C "$R19" add b.py
commit_in "$R19" "feat: add b"
[ "$RC" -ne 0 ] && ok "control: the rediscovered chain still blocks" || bad "copy-method chain blocks" "rc=$RC out=$OUT"

echo "=== a hook with no final newline round-trips byte-for-byte ==="
R26="$(new_repo nonewline)"
printf '#!/bin/sh\necho mine' >"$TMP/foreign-no-newline"
cp "$TMP/foreign-no-newline" "$R26/.git/hooks/pre-commit"
chmod +x "$R26/.git/hooks/pre-commit"
install_in "$R26"
[ "$RC" -eq 0 ] && ok "installing into a hook with no final newline exits 0" || bad "no-newline install" "rc=$RC out=$OUT"
OUT=""; RC=0
OUT="$("$R26/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R26" --uninstall 2>&1)" || RC=$?
cmp -s "$TMP/foreign-no-newline" "$R26/.git/hooks/pre-commit" \
  && ok "and uninstall restores it byte-for-byte, missing newline included" \
  || bad "no-newline restore" "got: $(cat -A "$R26/.git/hooks/pre-commit" 2>/dev/null)"

R26B="$(new_repo shebangonly)"
printf '#!/bin/sh' >"$R26B/.git/hooks/pre-commit"
chmod +x "$R26B/.git/hooks/pre-commit"
install_in "$R26B"
[ "$RC" -eq 0 ] && ok "a hook that is only a newline-less shebang installs" || bad "shebang-only install" "rc=$RC out=$OUT"
head -n 1 "$R26B/.git/hooks/pre-commit" | grep -qx '#!/bin/sh' \
  && ok "and the delegate does not run onto the interpreter line" \
  || bad "shebang-only separator" "got: $(head -n 1 "$R26B/.git/hooks/pre-commit")"
printf 'hello\n' >"$R26B/a.txt"
git -C "$R26B" add a.txt
commit_in "$R26B" "feat: add a"
[ "$RC" -eq 0 ] && ok "control: the resulting hook actually runs" || bad "shebang-only hook runs" "rc=$RC out=$OUT"

R26C="$(new_repo shebangonly-foreign)"
printf '#!/bin/sh\n' >"$TMP/foreign-shebang-only"
cp "$TMP/foreign-shebang-only" "$R26C/.git/hooks/pre-commit"
chmod +x "$R26C/.git/hooks/pre-commit"
install_in "$R26C"
OUT=""; RC=0
OUT="$("$R26C/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R26C" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "uninstalling beside a shebang-only foreign hook exits 0" || bad "shebang-only foreign uninstall" "rc=$RC out=$OUT"
cmp -s "$TMP/foreign-shebang-only" "$R26C/.git/hooks/pre-commit" \
  && ok "a consumer's shebang-only hook is restored, not deleted" \
  || bad "shebang-only foreign restored" "exists=$([ -e "$R26C/.git/hooks/pre-commit" ] && echo yes || echo no)"
[ -e "$R26C/.git/hooks/commit-msg" ] && bad "the hook we created is still deleted" \
  || ok "the hook we created is still deleted"

R29="$(new_repo sgd-unrelated-parent)"
mkdir -p "$TMP/sgdparent/inner"
git -c init.defaultBranch=main init -q "$TMP/sgdparent"
git -C "$TMP/sgdparent" config user.email test@example.com
git -C "$TMP/sgdparent" config user.name test
git -c init.defaultBranch=main init -q --separate-git-dir "$TMP/sgdparent/external.git" "$TMP/sgdparent/inner"
git -C "$TMP/sgdparent/inner" config user.email test@example.com
git -C "$TMP/sgdparent/inner" config user.name test
mkdir -p "$TMP/sgdparent/inner/.agents/skills"
cp -R "$SKILL_DIR" "$TMP/sgdparent/inner/.agents/skills/growth-guards"
ln -s "$SKILL_DIR/../size-ratchet" "$TMP/sgdparent/inner/.agents/skills/size-ratchet"
OUT=""; RC=0
OUT="$("$TMP/sgdparent/inner/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$TMP/sgdparent/inner" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "an external git dir under an unrelated checkout installs" || bad "sgd-unrelated install" "rc=$RC out=$OUT"
git -C "$TMP/sgdparent/inner" commit -q --allow-empty -m "feat: seed"
git -C "$TMP/sgdparent/inner" worktree add -q "$TMP/sgdwt" -b sgdwtb
mkdir -p "$TMP/sgdwt/.agents/skills"
OUT=""; RC=0
OUT="$("$TMP/sgdparent/inner/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$TMP/sgdwt" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && ok "an unrelated parent is not accepted as the main work tree" \
  || bad "unrelated parent rejected" "rc=$RC out=$OUT"
[ -f "$TMP/sgdparent/external.git/hooks/vstack-guards" ] && ok "and the real main checkout keeps its guard" \
  || bad "sgd-unrelated main keeps guard" "out=$OUT"

echo "=== a hook is never half-written ==="
R22="$(new_repo atomic)"
printf '#!/bin/sh\necho mine\n' >"$R22/.git/hooks/pre-commit"
chmod 0700 "$R22/.git/hooks/pre-commit"
install_in "$R22"
[ "$(stat -c '%a' "$R22/.git/hooks/pre-commit" 2>/dev/null || stat -f '%Lp' "$R22/.git/hooks/pre-commit")" = "700" ] \
  && ok "the rewritten hook keeps its own mode" || bad "rewritten hook keeps its mode"
grep -qF 'echo mine' "$R22/.git/hooks/pre-commit" && ok "and its own content" || bad "rewritten hook keeps content"

echo "=== usage lanes ==="
OUT=""; RC=0; OUT="$("$INSTALL" --repo "$TMP/nope" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && ok "a missing --repo path is exit 2" || bad "missing repo is exit 2" "rc=$RC out=$OUT"
mkdir -p "$TMP/notgit"
OUT=""; RC=0; OUT="$("$INSTALL" --repo "$TMP/notgit" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && ok "a non-git directory is exit 2" || bad "non-git dir is exit 2" "rc=$RC out=$OUT"
OUT=""; RC=0; OUT="$("$INSTALL" --bogus 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && ok "an unknown flag is exit 2" || bad "unknown flag is exit 2" "rc=$RC out=$OUT"
OUT=""; RC=0; OUT="$("$INSTALL" --help 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "--help is exit 0" || bad "--help is exit 0" "rc=$RC out=$OUT"

echo "=== preflight is in the chain ==="
R30="$(new_repo preflightchain)"
ln -s "$SKILL_DIR/../preflight" "$R30/.agents/skills/preflight"
install_in "$R30"
printf 'hello\n' >"$R30/ok.txt"
git -C "$R30" add ok.txt
commit_in "$R30" "feat: add ok"
[ "$RC" -eq 0 ] && ok "control: clean staged content commits with preflight installed" || bad "control: preflight clean commit" "rc=$RC out=$OUT"
case "$OUT" in
  *"first commit — preflight --staged has no base"*) ok "the first commit states the preflight skip instead of blocking" ;;
  *) bad "first-commit skip stated" "out=$OUT" ;;
esac
printf '#!/usr/bin/env bash\necho hi\n' >"$R30/loose.sh"
git -C "$R30" add loose.sh
commit_in "$R30" "feat: add loose"
[ "$RC" -ne 0 ] && ok "a staged fail-open script blocks through preflight" || bad "preflight blocks" "rc=$RC out=$OUT"
case "$OUT" in
  *preflight*) ok "preflight names itself in the blocked output" ;;
  *) bad "preflight names itself" "out=$OUT" ;;
esac
git -C "$R30" rm -q --cached loose.sh
rm -f "$R30/loose.sh"

echo "=== a broken preflight install blocks, never skips ==="
printf 'more\n' >"$R30/d.txt"
git -C "$R30" add d.txt
rm "$R30/.agents/skills/preflight"
ln -s "$TMP/no-such-skill" "$R30/.agents/skills/preflight"
commit_in "$R30" "feat: add d"
[ "$RC" -ne 0 ] && ok "a dangling preflight install blocks" || bad "dangling preflight blocks" "rc=$RC out=$OUT"
case "$OUT" in
  *"preflight skill is installed"*) ok "the broken preflight install is named" ;;
  *) bad "broken preflight named" "out=$OUT" ;;
esac
rm "$R30/.agents/skills/preflight"
commit_in "$R30" "feat: add d"
[ "$RC" -eq 0 ] && ok "control: an absent preflight is a stated skip" || bad "absent preflight skips" "rc=$RC out=$OUT"
case "$OUT" in
  *"preflight not installed — skipped"*) ok "the skip says preflight is not installed" ;;
  *) bad "skip states preflight not installed" "out=$OUT" ;;
esac


echo "=== a repo-local size-ratchet replacement without --staged is a stated skip ==="
R31="$(new_repo forkchain)"
# new_repo links size-ratchet to the REAL skill; replace the link with a real
# directory so the fork fixture cannot write through it.
rm "$R31/.agents/skills/size-ratchet"
mkdir -p "$R31/.agents/skills/size-ratchet/scripts"
cat >"$R31/.agents/skills/size-ratchet/scripts/size-ratchet" <<'FORK'
#!/usr/bin/env bash
# A consumer's own gate: usage text names size-ratchet, no --staged mode.
case "${1:-}" in
  --help) echo "size-ratchet — repo-local gate. Usage: size-ratchet [--update]"; exit 0 ;;
  --staged) echo "::error::size-ratchet: unknown argument '--staged' (see --help)" >&2; exit 2 ;;
esac
exit 0
FORK
chmod 0755 "$R31/.agents/skills/size-ratchet/scripts/size-ratchet"
install_in "$R31"
printf 'hello\n' >"$R31/ok.txt"
git -C "$R31" add ok.txt
commit_in "$R31" "feat: add ok"
[ "$RC" -eq 0 ] && ok "a fork without --staged does not block the commit" || bad "fork commit proceeds" "rc=$RC out=$OUT"
case "$OUT" in
  *"rejects --staged"*"repo-local replacement"*) ok "the skip states the fork and its ownership" ;;
  *) bad "fork skip stated" "out=$OUT" ;;
esac

echo "=== a fork whose --help NAMES --staged but rejects it still skips ==="
cat >"$R31/.agents/skills/size-ratchet/scripts/size-ratchet" <<'NEGHELP'
#!/usr/bin/env bash
case "${1:-}" in
  --help) echo "size-ratchet — repo-local gate. Usage: size-ratchet [--update]. This build does not support --staged."; exit 0 ;;
  --staged) echo "::error::size-ratchet: unknown argument '--staged' (see --help)" >&2; exit 2 ;;
esac
exit 0
NEGHELP
chmod 0755 "$R31/.agents/skills/size-ratchet/scripts/size-ratchet"
printf 'neg\n' >"$R31/b.txt"
git -C "$R31" add b.txt
commit_in "$R31" "feat: add b"
[ "$RC" -eq 0 ] && ok "a help-names-it-but-rejects-it fork does not block" || bad "negative-phrase fork proceeds" "rc=$RC out=$OUT"
case "$OUT" in
  *"rejects --staged"*"repo-local replacement"*) ok "the runtime rejection is stated as the skip" ;;
  *) bad "runtime rejection stated" "out=$OUT" ;;
esac

echo "=== a config-error diagnostic that mentions --staged is not a rejection ==="
cat >"$R31/.agents/skills/size-ratchet/scripts/size-ratchet" <<'CFGERR'
#!/usr/bin/env bash
case "${1:-}" in
  --help) echo "size-ratchet — gate. Usage: size-ratchet [--staged] [--update]"; exit 0 ;;
esac
echo "::error::size-ratchet: SIZE_RATCHET_THRESHOLD must be a positive integer (see --help; applies to --staged runs too)" >&2
exit 2
CFGERR
chmod 0755 "$R31/.agents/skills/size-ratchet/scripts/size-ratchet"
printf 'cfg\n' >"$R31/e.txt"
git -C "$R31" add e.txt
commit_in "$R31" "feat: add e"
[ "$RC" -ne 0 ] && ok "a config error mentioning --staged still blocks" || bad "config error blocks" "rc=$RC out=$OUT"
case "$OUT" in
  *"did not complete"*) ok "the block is the did-not-complete error, never the replacement skip" ;;
  *) bad "config error named" "out=$OUT" ;;
esac
git -C "$R31" rm -q --cached e.txt 2>/dev/null; rm -f "$R31/e.txt"

echo "=== an echoed rejection phrase inside a config diagnostic is not a rejection ==="
cat >"$R31/.agents/skills/size-ratchet/scripts/size-ratchet" <<'ECHOED'
#!/usr/bin/env bash
case "${1:-}" in
  --help) echo "size-ratchet — gate. Usage: size-ratchet [--staged] [--update]"; exit 0 ;;
esac
echo "::error::size-ratchet: SIZE_RATCHET_THRESHOLD must be a positive integer, got 'unknown argument '--staged''" >&2
exit 2
ECHOED
chmod 0755 "$R31/.agents/skills/size-ratchet/scripts/size-ratchet"
printf 'echoed\n' >"$R31/f.txt"
git -C "$R31" add f.txt
commit_in "$R31" "feat: add f"
[ "$RC" -ne 0 ] && ok "an echoed phrase in a config diagnostic still blocks" || bad "echoed phrase blocks" "rc=$RC out=$OUT"
case "$OUT" in
  *"did not complete"*) ok "the echoed-phrase block is did-not-complete, never the replacement skip" ;;
  *) bad "echoed phrase named" "out=$OUT" ;;
esac
git -C "$R31" rm -q --cached f.txt 2>/dev/null; rm -f "$R31/f.txt"

echo "=== a broken script erroring at run time blocks, never skips ==="
cat >"$R31/.agents/skills/size-ratchet/scripts/size-ratchet" <<'BROKEN'
#!/usr/bin/env bash
echo "size-ratchet: cannot source lib/settings.sh" >&2
exit 2
BROKEN
chmod 0755 "$R31/.agents/skills/size-ratchet/scripts/size-ratchet"
printf 'more\n' >"$R31/d.txt"
git -C "$R31" add d.txt
commit_in "$R31" "feat: add d"
[ "$RC" -ne 0 ] && ok "a broken script blocks the commit" || bad "broken script blocks" "rc=$RC out=$OUT"
case "$OUT" in
  *"did not complete"*) ok "the block is did-not-complete, never a replacement skip" ;;
  *) bad "broken install named" "out=$OUT" ;;
esac

echo "=== --check answers whether the shims are armed, and modifies nothing on disk ==="
check_in() { # REPO — sets OUT and RC
  local installer="$1/.agents/skills/growth-guards/scripts/install-git-hooks"
  [ -x "$installer" ] || installer="$INSTALL"
  OUT=""
  RC=0
  OUT="$("$installer" --repo "$1" --check 2>&1)" || RC=$?
}
R32="$(new_repo checkmode)"
install_in "$R32"
check_in "$R32"
[ "$RC" -eq 0 ] && ok "an armed install checks 0" || bad "armed checks 0" "rc=$RC out=$OUT"
case "$OUT" in
  *"armed — pre-commit and commit-msg"*) ok "and the verdict line says armed" ;;
  *) bad "verdict says armed" "out=$OUT" ;;
esac

rm "$R32/.git/hooks/pre-commit"
check_in "$R32"
[ "$RC" -eq 1 ] && ok "an absent hook file checks 1" || bad "absent hook checks 1" "rc=$RC out=$OUT"
case "$OUT" in
  *"pre-commit is missing"*) ok "and the missing hook is named" ;;
  *) bad "missing hook named" "out=$OUT" ;;
esac
[ -e "$R32/.git/hooks/pre-commit" ] && bad "--check must not write the hook back" || ok "--check did not write the hook back"

install_in "$R32"
printf '#!/bin/sh\nexit 0\n' >"$R32/.git/hooks/pre-commit"
chmod +x "$R32/.git/hooks/pre-commit"
check_in "$R32"
[ "$RC" -eq 1 ] && ok "a hook without the marked line checks 1" || bad "stripped line checks 1" "rc=$RC out=$OUT"
case "$OUT" in
  *"does not carry the guard line"*) ok "and the dropped guard line is named" ;;
  *) bad "dropped guard line named" "out=$OUT" ;;
esac
grep -qF 'vstack-guards' "$R32/.git/hooks/pre-commit" && bad "--check must not repair the hook" || ok "--check did not repair the hook"

install_in "$R32"
chmod -x "$R32/.git/hooks/pre-commit"
check_in "$R32"
[ "$RC" -eq 1 ] && ok "a cleared executable bit checks 1" || bad "cleared exec bit checks 1" "rc=$RC out=$OUT"
case "$OUT" in
  *"not executable"*) ok "and says git ignores it" ;;
  *) bad "exec bit named" "out=$OUT" ;;
esac
chmod +x "$R32/.git/hooks/pre-commit"

printf '#!/bin/sh\nexit 0\n' >"$R32/.git/hooks/vstack-guards"
check_in "$R32"
[ "$RC" -eq 1 ] && ok "a foreign file at the helper path checks 1" || bad "foreign helper checks 1" "rc=$RC out=$OUT"
case "$OUT" in
  *"not written by this installer"*) ok "and the foreign helper is named" ;;
  *) bad "foreign helper named" "out=$OUT" ;;
esac
rm "$R32/.git/hooks/vstack-guards"
install_in "$R32"

if [ "$(id -u)" != "0" ]; then
  chmod 000 "$R32/.git/hooks"
  check_in "$R32"
  chmod 755 "$R32/.git/hooks"
  [ "$RC" -eq 2 ] && ok "an unreadable hooks directory checks 2, never a pass" \
    || bad "unreadable hooks dir checks 2" "rc=$RC out=$OUT"
  case "$OUT" in
    *"could not determine"*) ok "and the verdict says it could not determine" ;;
    *) bad "could-not-determine stated" "out=$OUT" ;;
  esac
else
  ok "unreadable hooks dir case skipped (running as root)"
  ok "unreadable hooks dir wording skipped (running as root)"
fi

echo "=== --check reports dormant-behind-core.hooksPath distinctly ==="
R33="$(new_repo checkdormant)"
install_in "$R33"
mkdir -p "$R33/myhooks"
git -C "$R33" config core.hooksPath myhooks
check_in "$R33"
[ "$RC" -eq 1 ] && ok "intact shims behind core.hooksPath check 1 (no commit runs them)" \
  || bad "dormant checks 1" "rc=$RC out=$OUT"
case "$OUT" in
  *dormant*core.hooksPath*) ok "the verdict names the dormant state and its cause" ;;
  *) bad "dormant state named" "out=$OUT" ;;
esac
case "$OUT" in
  *"NOT armed —"*) bad "dormant is not conflated with drifted" "out=$OUT" ;;
  *) ok "dormant is not conflated with drifted" ;;
esac

R34="$(new_repo checkhookspathempty)"
mkdir -p "$R34/myhooks"
git -C "$R34" config core.hooksPath myhooks
check_in "$R34"
[ "$RC" -eq 1 ] && ok "core.hooksPath with no shims installed checks 1" \
  || bad "hooksPath-no-shims checks 1" "rc=$RC out=$OUT"
case "$OUT" in
  *"NOT armed"*core.hooksPath*) ok "and states both the redirect and the missing shims" ;;
  *) bad "redirect and missing shims stated" "out=$OUT" ;;
esac

echo "=== --check probes the directory core.hooksPath redirects to ==="
# The wiring the installer's own stand-down message prescribes.
wire_hooks_dir() { # REPO DIR
  local scripts="$1/.agents/skills/growth-guards/scripts"
  mkdir -p "$2"
  printf '#!/bin/sh\nexec %s/pre-commit "$@"\n' "$scripts" >"$2/pre-commit"
  printf '#!/bin/sh\nexec %s/commit-msg "$1"\n' "$scripts" >"$2/commit-msg"
  chmod +x "$2/pre-commit" "$2/commit-msg"
}
check_from() { # REPO CWD — --check with no --repo, run from CWD
  local installer="$1/.agents/skills/growth-guards/scripts/install-git-hooks"
  [ -x "$installer" ] || installer="$INSTALL"
  OUT=""
  RC=0
  OUT="$(cd "$2" && "$installer" --check 2>&1)" || RC=$?
}

R35="$(new_repo checkhookspathwired)"
install_in "$R35"
wire_hooks_dir "$R35" "$R35/customhooks"
git -C "$R35" config core.hooksPath customhooks
check_in "$R35"
[ "$RC" -eq 0 ] && ok "a hand-wired core.hooksPath directory checks 0" \
  || bad "hand-wired hooksPath checks 0" "rc=$RC out=$OUT"
case "$OUT" in
  *"NOT gated"* | *"NOT armed"* | *dormant*) bad "a wired redirect is never called ungated" "out=$OUT" ;;
  *) ok "a wired redirect is never called ungated" ;;
esac
case "$OUT" in
  *armed*"$R35/customhooks"*core.hooksPath*) ok "and the verdict names the directory the gating comes from" ;;
  *) bad "wired redirect names its directory" "out=$OUT" ;;
esac

# The verdict is only true if commits really are gated there.
printf 'ok\n' >"$R35/w.txt"
git -C "$R35" add w.txt
commit_in "$R35" "feat: add w"
[ "$RC" -eq 0 ] && ok "control: a clean commit passes through the hand-wired directory" \
  || bad "hand-wired clean commit passes" "rc=$RC out=$OUT"
printf '# %s: finish this\n' "$TD" >"$R35/w.py"
git -C "$R35" add w.py
commit_in "$R35" "feat: add w.py"
[ "$RC" -ne 0 ] && ok "and a violation is really blocked through the hand-wired directory" \
  || bad "hand-wired directory blocks" "rc=$RC out=$OUT"
git -C "$R35" rm -q --cached w.py
rm -f "$R35/w.py"

git -C "$R35" config core.hooksPath nosuchdir
check_in "$R35"
[ "$RC" -eq 1 ] && ok "a core.hooksPath directory that does not exist checks 1" \
  || bad "absent hooksPath dir checks 1" "rc=$RC out=$OUT"
case "$OUT" in
  *"wire that directory's hooks"*) ok "and the hand-wiring remedy is still stated" ;;
  *) bad "remedy stated for absent hooksPath dir" "out=$OUT" ;;
esac

mkdir -p "$R35/barehooks"
git -C "$R35" config core.hooksPath barehooks
check_in "$R35"
[ "$RC" -eq 1 ] && ok "a core.hooksPath directory with no shims checks 1" \
  || bad "unwired hooksPath dir checks 1" "rc=$RC out=$OUT"

mkdir -p "$R35/foreignhooks"
printf '#!/bin/sh\nexec "$(git rev-parse --show-toplevel)/tools/other-tool" "$@"\n' >"$R35/foreignhooks/pre-commit"
printf '#!/bin/sh\nexec "$(git rev-parse --show-toplevel)/tools/other-tool" "$1"\n' >"$R35/foreignhooks/commit-msg"
chmod +x "$R35/foreignhooks/pre-commit" "$R35/foreignhooks/commit-msg"
git -C "$R35" config core.hooksPath foreignhooks
check_in "$R35"
# The command is a substitution, so what it runs is not knowable from the
# text — including the claim that it is another tool. Unverifiable, not a
# verdict either way; both are non-zero and both fail a verify command.
[ "$RC" -eq 2 ] && ok "a core.hooksPath directory wired through a substitution checks 2" \
  || bad "foreign hooksPath dir checks 2" "rc=$RC out=$OUT"
case "$OUT" in
  *"could not determine"*) ok "and it is called unverifiable rather than judged" ;;
  *) bad "foreign hooksPath dir called unverifiable" "out=$OUT" ;;
esac

wire_hooks_dir "$R35" "$R35/halfhooks"
rm -f "$R35/halfhooks/commit-msg"
git -C "$R35" config core.hooksPath halfhooks
check_in "$R35"
[ "$RC" -eq 1 ] && ok "a core.hooksPath directory with only pre-commit wired checks 1" \
  || bad "half-wired hooksPath dir checks 1" "rc=$RC out=$OUT"
wire_hooks_dir "$R35" "$R35/halfhooks"
rm -f "$R35/halfhooks/pre-commit"
check_in "$R35"
[ "$RC" -eq 1 ] && ok "a core.hooksPath directory with only commit-msg wired checks 1" \
  || bad "half-wired hooksPath dir checks 1 (other half)" "rc=$RC out=$OUT"

wire_hooks_dir "$R35" "$R35/nonexechooks"
chmod -x "$R35/nonexechooks/pre-commit"
git -C "$R35" config core.hooksPath nonexechooks
check_in "$R35"
[ "$RC" -eq 1 ] && ok "a wired core.hooksPath hook git cannot execute checks 1" \
  || bad "non-executable hooksPath hook checks 1" "rc=$RC out=$OUT"
chmod +x "$R35/nonexechooks/pre-commit"
check_in "$R35"
[ "$RC" -eq 0 ] && ok "control: restoring the executable bit checks 0 again" \
  || bad "control: exec bit restored checks 0" "rc=$RC out=$OUT"

echo "=== --check reads only EXECUTABLE wiring in a core.hooksPath directory ==="
# A mention of the entry point that no commit ever runs — a comment, a heredoc
# body, an argument, anything past an unconditional exit — must never read as
# gated: a verification tool that fails open is worse than one that fails shut.
R38="$(new_repo checkhookspathshapes)"
install_in "$R38"
SC38="$R38/.agents/skills/growth-guards/scripts"
mkdir -p "$R38/shapehooks"
git -C "$R38" config core.hooksPath shapehooks
arm_pair() { # PRE_FORMAT MSG_FORMAT — printf formats taking the scripts dir
  printf "$1" "$SC38" >"$R38/shapehooks/pre-commit"
  printf "$2" "$SC38" >"$R38/shapehooks/commit-msg"
  chmod +x "$R38/shapehooks/pre-commit" "$R38/shapehooks/commit-msg"
}
# The invariant every shape below is judged against: exit 0 is claimed ONLY
# where a commit is really gated. A shape the grammar does not recognize is
# exit 2 — "could not determine" — never exit 0, and never exit 1 either,
# because calling a hook that does gate "NOT gated" is the same tool telling
# the same lie in the other direction.
must_fail_shape() { # LABEL — recognizably not ours: exit 1, stated as ungated
  check_in "$R38"
  [ "$RC" -eq 1 ] && ok "must-fail: $1 is not armed" || bad "must-fail: $1 is not armed" "rc=$RC out=$OUT"
  case "$OUT" in
    *"NOT gated"* | *"NOT armed"*) ok "and $1 is stated as ungated" ;;
    *) bad "$1 stated as ungated" "out=$OUT" ;;
  esac
}
unverifiable_shape() { # LABEL — outside the grammar: exit 2, never a verdict
  check_in "$R38"
  [ "$RC" -eq 2 ] && ok "must-fail: $1 is not armed (unverifiable)" \
    || bad "must-fail: $1 is not armed (unverifiable)" "rc=$RC out=$OUT"
  case "$OUT" in
    *"could not determine"*) ok "and $1 is stated as unverifiable, not as a verdict" ;;
    *) bad "$1 stated as unverifiable" "out=$OUT" ;;
  esac
}

arm_pair '#!/bin/sh\n# see %s/pre-commit for what this used to do\nexit 0\n' \
  '#!/bin/sh\n# see %s/commit-msg\nexit 0\n'
must_fail_shape "the entry point named only in a line-2 comment"

arm_pair '#!/bin/sh\nexit 0\nexec %s/pre-commit "$@"\n' \
  '#!/bin/sh\nexit 0\nexec %s/commit-msg "$1"\n'
unverifiable_shape "wiring left unreachable after an unconditional exit"

arm_pair '#!/bin/sh\ncat <<EOF\nexec %s/pre-commit "$@"\nEOF\nexit 0\n' \
  '#!/bin/sh\ncat <<EOF\nexec %s/commit-msg "$1"\nEOF\nexit 0\n'
unverifiable_shape "the entry point inside a heredoc body"

arm_pair '#!/bin/sh\necho "%s/pre-commit"\nexit 0\n' \
  '#!/bin/sh\necho "%s/commit-msg"\nexit 0\n'
unverifiable_shape "the entry point as a quoted argument to another command"

arm_pair '#!/bin/sh\n#%s/pre-commit\n' '#!/bin/sh\n#%s/commit-msg\n'
must_fail_shape "a hook whose only content is the commented entry point"

# The command word being the entry point is not enough: the TAIL decides
# whether running it can still fail the commit. Each of these names the entry
# point in command position and gates nothing.
arm_pair '#!/bin/sh\nexec "%s/pre-commit" --help\n' '#!/bin/sh\nexec "%s/commit-msg" --help\n'
unverifiable_shape "the entry point invoked with --help"

arm_pair '#!/bin/sh\n%s/pre-commit "$@" || true\n' '#!/bin/sh\n%s/commit-msg "$1" || true\n'
unverifiable_shape "the entry point with its status thrown away by || true"

arm_pair '#!/bin/sh\n%s/pre-commit "$@" &\n' '#!/bin/sh\n%s/commit-msg "$1" &\n'
unverifiable_shape "the entry point backgrounded, so its status never lands"

# The two hooks do not take the same arguments, and swapping them breaks the
# gate rather than loosening it: pre-commit exits 2 on any argument, and a
# bare commit-msg reads inherited stdin and calls every message empty. Both
# reject valid commits while validating nothing, so "armed" describes neither.
arm_pair '#!/bin/sh\nexec %s/pre-commit "$1"\n' '#!/bin/sh\nexec %s/commit-msg "$1"\n'
unverifiable_shape "pre-commit handed an argument it refuses"

arm_pair '#!/bin/sh\nexec %s/pre-commit "$@"\n' '#!/bin/sh\nexec %s/commit-msg\n'
unverifiable_shape "commit-msg without git's message-file argument"

# A path SHAPE is not an entry point. A moved or removed install leaves a
# hook whose command resolves to nothing: git answers every commit, clean
# ones included, with command-not-found instead of a verdict.
mkdir -p "$R38/gone/growth-guards/scripts"
arm_pair "#!/bin/sh\nexec $R38/gone/growth-guards/scripts/pre-commit \"\$@\"\n" \
  "#!/bin/sh\nexec $R38/gone/growth-guards/scripts/commit-msg \"\$1\"\n"
must_fail_shape "an entry-point path with nothing at it"

: >"$R38/gone/growth-guards/scripts/pre-commit"
: >"$R38/gone/growth-guards/scripts/commit-msg"
arm_pair "#!/bin/sh\nexec $R38/gone/growth-guards/scripts/pre-commit \"\$@\"\n" \
  "#!/bin/sh\nexec $R38/gone/growth-guards/scripts/commit-msg \"\$1\"\n"
must_fail_shape "an entry-point path that is not executable"

# A shebang option can stop the body running at all: `sh -n` syntax-checks
# and exits 0, so the hook executes no guard and passes every commit.
arm_pair '#!/bin/sh -n\nexec %s/pre-commit "$@"\n' '#!/bin/sh -n\nexec %s/commit-msg "$1"\n'
unverifiable_shape "a shebang whose option stops the body running"

# The tail rule cuts both ways, and this is the case that proves `2` is not a
# synonym for ungated: a trailing comment leaves the tail outside the
# allowlist, but the hook runs the entry point and really does gate.
arm_pair '#!/bin/sh\nexec %s/pre-commit "$@" # run the guard\n' \
  '#!/bin/sh\nexec %s/commit-msg "$1" # run the guard\n'
unverifiable_shape "a gating hook whose tail carries a trailing comment"
printf '# %s: finish this\n' "$TD" >"$R38/t.py"
git -C "$R38" add t.py
commit_in "$R38" "feat: add t"
[ "$RC" -ne 0 ] && ok "and that unverifiable hook really does gate, so 2 is not 'ungated'" \
  || bad "trailing-comment hook gates" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached t.py
rm -f "$R38/t.py"

# The accepted-tail comparison is a shell PATTERN, so its metacharacters have
# to be escaped or it matches more than it names: an unescaped `?` made
# `|| exit $#` pass for `|| exit $?`, and git gives pre-commit no arguments,
# so `$#` is 0 and the wrapper swallowed every pre-commit failure.
arm_pair '#!/bin/sh\n%s/pre-commit "$@" || exit $#\n' '#!/bin/sh\n%s/commit-msg "$1" || exit $#\n'
unverifiable_shape "a tail that only resembles || exit \$? under globbing"

arm_pair '#!/bin/sh\n%s/pre-commit "$@" || exit 0\n' '#!/bin/sh\n%s/commit-msg "$1" || exit 0\n'
unverifiable_shape "a tail that exits 0 on failure"

# A path ending in growth-guards/scripts/<hook> identifies the guard only
# while that last component IS the guard: a symlink there passes -f and -x
# while running anything at all.
mkdir -p "$R38/fake/growth-guards/scripts"
ln -sf /bin/true "$R38/fake/growth-guards/scripts/pre-commit"
ln -sf /bin/true "$R38/fake/growth-guards/scripts/commit-msg"
arm_pair "#!/bin/sh\nexec $R38/fake/growth-guards/scripts/pre-commit \"\$@\"\n" \
  "#!/bin/sh\nexec $R38/fake/growth-guards/scripts/commit-msg \"\$1\"\n"
unverifiable_shape "an entry-point path that is a symlink to another program"

# And the same name worn by a REGULAR executable. A path is a name, not an
# identity: this one passes every file test and is not a symlink either.
rm -f "$R38/fake/growth-guards/scripts/pre-commit" "$R38/fake/growth-guards/scripts/commit-msg"
cp /bin/true "$R38/fake/growth-guards/scripts/pre-commit"
cp /bin/true "$R38/fake/growth-guards/scripts/commit-msg"
chmod +x "$R38/fake/growth-guards/scripts/pre-commit" "$R38/fake/growth-guards/scripts/commit-msg"
arm_pair "#!/bin/sh\nexec $R38/fake/growth-guards/scripts/pre-commit \"\$@\"\n" \
  "#!/bin/sh\nexec $R38/fake/growth-guards/scripts/commit-msg \"\$1\"\n"
must_fail_shape "another program wearing the entry point's name"
printf '# %s: finish this\n' "$TD" >"$R38/im.py"
git -C "$R38" add im.py
commit_in "$R38" "feat: add im"
[ "$RC" -eq 0 ] && ok "and that impostor really does let a violation through" \
  || bad "impostor bypasses" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached im.py
rm -f "$R38/im.py"
printf '# %s: finish this\n' "$TD" >"$R38/sl.py"
git -C "$R38" add sl.py
commit_in "$R38" "feat: add sl"
[ "$RC" -eq 0 ] && ok "and that wiring really does bypass the guard, which is why it is never armed" \
  || bad "symlinked entry point bypasses" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached sl.py
rm -f "$R38/sl.py"

# A tail must be SEPARATED from the command by a real blank. The shell
# concatenates `"…/commit-msg""$1"` into one word, so reading it as
# command-plus-tail describes a hook git cannot run at all.
arm_pair '#!/bin/sh\nexec "%s/pre-commit""$@"\n' '#!/bin/sh\nexec "%s/commit-msg""$1"\n'
must_fail_shape "a quoted command with no separator before its tail"

# Only blanks are trimmed. `[[:space:]]` would eat a trailing CR that the
# shell keeps as part of the word, so a CRLF hook would be accepted for a
# tail the shell never sees.
arm_pair '#!/bin/sh\nexec %s/pre-commit "$@"\r\n' '#!/bin/sh\nexec %s/commit-msg "$1"\r\n'
unverifiable_shape "a hook whose command line ends in a carriage return"

# `exec -a NAME cmd` runs cmd under another argv[0]: the command word is two
# tokens further along, and reading the option as the command would report a
# hook that gates perfectly well as NOT gated — the false negative this
# grammar reserves exit 2 for.
arm_pair '#!/bin/sh\nexec -a guard %s/pre-commit "$@"\n' '#!/bin/sh\nexec -a guard %s/commit-msg "$1"\n'
unverifiable_shape "wiring behind an exec option"
printf 'clean\n' >"$R38/ea.txt"
git -C "$R38" add ea.txt
commit_in "$R38" "feat: add ea"
[ "$RC" -eq 0 ] && ok "and that hook really does gate, so it is not called ungated" \
  || bad "exec -a hook gates" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached ea.txt
rm -f "$R38/ea.txt"

# A carriage return in the SHEBANG is not trailing whitespace: the kernel
# looks for an interpreter named `/bin/sh\r`, and git cannot run the hook at
# all — a clean commit dies with "cannot exec".
arm_pair '#!/bin/sh\r\nexec %s/pre-commit "$@"\n' '#!/bin/sh\r\nexec %s/commit-msg "$1"\n'
must_fail_shape "a shebang line ending in a carriage return"

# The interpreter is identified by FULL PATH, not by basename: an executable
# named `sh` anywhere at all can be a copy of /bin/true, and then git runs
# true, ignores the hook body, and nothing is gated.
mkdir -p "$R38/fakebin"
cp /bin/true "$R38/fakebin/sh"
chmod +x "$R38/fakebin/sh"
arm_pair "#!$R38/fakebin/sh\nexec %s/pre-commit \"\$@\"\n" \
  "#!$R38/fakebin/sh\nexec %s/commit-msg \"\$1\"\n"
unverifiable_shape "a shebang naming an untrusted interpreter"
printf '# %s: finish this\n' "$TD" >"$R38/fi.py"
git -C "$R38" add fi.py
commit_in "$R38" "feat: add fi"
[ "$RC" -eq 0 ] && ok "and that interpreter really does swallow the hook body" \
  || bad "fake interpreter bypasses" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached fi.py
rm -f "$R38/fi.py"

# `env` resolves the interpreter through PATH, which is no more knowable than
# a custom path — unverifiable, even though such a hook usually does gate.
arm_pair '#!/usr/bin/env bash\nexec %s/pre-commit "$@"\n' '#!/usr/bin/env bash\nexec %s/commit-msg "$1"\n'
unverifiable_shape "a shebang resolving its interpreter through env"

# The delegating shape resolves its helper in the redirected directory, and
# outside the installer-owned hooks directory that helper is a copy someone
# made. The marker is a comment anyone can type.
cp "$R38/.git/hooks/pre-commit" "$R38/.git/hooks/commit-msg" "$R38/shapehooks/"
printf '#!/bin/sh\n# vstack growth-guards git hooks\nexit 0\n' >"$R38/shapehooks/vstack-guards"
chmod +x "$R38/shapehooks/vstack-guards"
unverifiable_shape "a helper carrying the marker but none of the behaviour"
printf '# %s: finish this\n' "$TD" >"$R38/fh.py"
git -C "$R38" add fh.py
commit_in "$R38" "feat: add fh"
[ "$RC" -eq 0 ] && ok "and that helper really does bypass every guard" \
  || bad "fake helper bypasses" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached fh.py
rm -f "$R38/fh.py"
# Control: the helper this installer actually wrote, copied across, is armed.
cp "$R38/.git/hooks/vstack-guards" "$R38/shapehooks/"
check_in "$R38"
[ "$RC" -eq 0 ] && ok "control: the installer's own helper, copied across, is armed" \
  || bad "copied real helper armed" "rc=$RC out=$OUT"
rm -f "$R38/shapehooks/vstack-guards" "$R38/shapehooks/pre-commit" "$R38/shapehooks/commit-msg"

# On the trusted list is not on the disk. Pick whichever listed shell this
# host lacks; if it has all of them the case cannot arise here and is
# reported as skipped rather than silently dropped.
GG_ABSENT_SH=""
for gg_c in /bin/dash /bin/ksh /bin/zsh /usr/bin/dash /usr/bin/ksh; do
  if [ ! -x "$gg_c" ]; then GG_ABSENT_SH="$gg_c"; break; fi
done
if [ -n "$GG_ABSENT_SH" ]; then
  arm_pair "#!$GG_ABSENT_SH\nexec %s/pre-commit \"\$@\"\n" "#!$GG_ABSENT_SH\nexec %s/commit-msg \"\$1\"\n"
  unverifiable_shape "a trusted interpreter path that is absent on this host"
  printf 'clean\n' >"$R38/ai.txt"
  git -C "$R38" add ai.txt
  commit_in "$R38" "feat: add ai"
  [ "$RC" -ne 0 ] && ok "and git really cannot exec that hook, so even a clean commit fails" \
    || bad "absent interpreter blocks" "rc=$RC out=$OUT"
  git -C "$R38" rm -q --cached ai.txt
  rm -f "$R38/ai.txt"
else
  printf '  skip  a trusted interpreter path that is absent on this host (all are installed)\n'
fi

# The word the SHELL runs, not the one written down. A checkout path that
# literally contains `$slot` passes every file test while /bin/sh expands it
# at commit time — so the same bytes name a different program.
mkdir -p "$R38/dollar/\$slot"
# A LINK to the real install, so the physical-location test still resolves
# and the only thing under examination is the spelling.
ln -s "$SC38" "$R38/dollar/\$slot/scripts"
arm_pair "#!/bin/sh\nexec \"$R38/dollar/\$slot/scripts/pre-commit\" \"\$@\"\n" \
  "#!/bin/sh\nexec \"$R38/dollar/\$slot/scripts/commit-msg\" \"\$1\"\n"
unverifiable_shape "a double-quoted command that the shell would expand"

# Control: the SAME literal path, single-quoted, survives evaluation
# unchanged — so it is verifiable and stays armed.
arm_pair "#!/bin/sh\nexec '$R38/dollar/\$slot/scripts/pre-commit' \"\$@\"\n" \
  "#!/bin/sh\nexec '$R38/dollar/\$slot/scripts/commit-msg' \"\$1\"\n"
check_in "$R38"
[ "$RC" -eq 0 ] && ok "control: single-quoting the same path keeps it verifiable" \
  || bad "single-quoted dollar path armed" "rc=$RC out=$OUT"

# An unquoted word globs as well, so a glob character is unverifiable too.
arm_pair '#!/bin/sh\nexec %s/pre-comm?t "$@"\n' '#!/bin/sh\nexec %s/commit-ms? "$1"\n'
unverifiable_shape "an unquoted command carrying a glob character"

# Indentation is BLANKS. A line starting with CR runs a command named
# `\rexec`, so normalizing it away would accept a hook that git cannot run.
arm_pair '#!/bin/sh\n\rexec %s/pre-commit "$@"\n' '#!/bin/sh\n\rexec %s/commit-msg "$1"\n'
unverifiable_shape "a command line beginning with a carriage return"

# One passing control per shape the check does accept.
arm_pair '#!/bin/sh\n%s/pre-commit "$@" || exit $?\n' \
  '#!/bin/sh\n%s/commit-msg "$1" || exit $?\n'
check_in "$R38"
[ "$RC" -eq 0 ] && ok "control: a bare invocation of the entry point is armed" \
  || bad "bare invocation armed" "rc=$RC out=$OUT"

arm_pair '#!/bin/sh\nexec "%s/pre-commit" "$@"\n' '#!/bin/sh\nexec "%s/commit-msg" "$1"\n'
check_in "$R38"
[ "$RC" -eq 0 ] && ok "control: a quoted exec of the entry point is armed" \
  || bad "quoted exec armed" "rc=$RC out=$OUT"

# Reachability is the line this tool does not cross. These three all run the
# entry point in a shell, and a lexical reader cannot separate the two that
# never execute from the one that does — so none of them is answered.
arm_pair '#!/bin/sh\nif false; then\nexec %s/pre-commit "$@"\nfi\nexit 0\n' \
  '#!/bin/sh\nif false; then\nexec %s/commit-msg "$1"\nfi\nexit 0\n'
unverifiable_shape "wiring guarded by a condition that is never true"

arm_pair '#!/bin/sh\nunused() {\nexec %s/pre-commit "$@"\n}\nexit 0\n' \
  '#!/bin/sh\nunused() {\nexec %s/commit-msg "$1"\n}\nexit 0\n'
unverifiable_shape "wiring inside a function nothing calls"

arm_pair '#!/bin/sh\ncat <<-EOF\n\t%s/pre-commit\n\tEOF\nexit 0\n' \
  '#!/bin/sh\ncat <<-EOF\n\t%s/commit-msg\n\tEOF\nexit 0\n'
unverifiable_shape "the entry point in a <<- heredoc with an indented terminator"

# And the same answer for a hook that DOES gate but says more than the one
# command: unverifiable is not a synonym for ungated.
arm_pair '#!/bin/sh\nset -e\nexec %s/pre-commit "$@"\n' \
  '#!/bin/sh\nset -e\nexec %s/commit-msg "$1"\n'
unverifiable_shape "a hook that gates but runs another command first"
check_in "$R38"
printf '# %s: finish this\n' "$TD" >"$R38/s.py"
git -C "$R38" add s.py
commit_in "$R38" "feat: add s"
[ "$RC" -ne 0 ] && ok "and that unverifiable hook really does gate, which is why it is not called ungated" \
  || bad "unverifiable-but-gating hook blocks" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached s.py
rm -f "$R38/s.py"

# A second install elsewhere on disk: the generic entry-point shape, wired to
# scripts that really run, so "armed" is proved against an actual commit.
mkdir -p "$TMP/elsewhere/growth-guards"
ln -s "$SC38" "$TMP/elsewhere/growth-guards/scripts"
printf '#!/bin/sh\nexec %s/elsewhere/growth-guards/scripts/pre-commit "$@"\n' "$TMP" >"$R38/shapehooks/pre-commit"
printf '#!/bin/sh\nexec %s/elsewhere/growth-guards/scripts/commit-msg "$1"\n' "$TMP" >"$R38/shapehooks/commit-msg"
chmod +x "$R38/shapehooks/pre-commit" "$R38/shapehooks/commit-msg"
check_in "$R38"
[ "$RC" -eq 0 ] && ok "control: an entry point from another install on disk is armed" \
  || bad "other-install entry point armed" "rc=$RC out=$OUT"
printf '# %s: finish this\n' "$TD" >"$R38/s.py"
git -C "$R38" add s.py
commit_in "$R38" "feat: add s"
[ "$RC" -ne 0 ] && ok "and a violation is really blocked through it" || bad "other-install wiring blocks" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached s.py
rm -f "$R38/s.py"
# Armed has to mean the gate JUDGES, not that it refuses everything: a
# mis-wired hook blocks a clean commit too, and only this half tells them
# apart.
printf 'clean\n' >"$R38/clean.txt"
git -C "$R38" add clean.txt
commit_in "$R38" "feat: add a clean file"
[ "$RC" -eq 0 ] && ok "and a clean commit still passes through it" \
  || bad "clean commit passes armed wiring" "rc=$RC out=$OUT"

# The delegating line resolves its helper with `git rev-parse --git-path
# hooks`, which under core.hooksPath is this directory — so the helper has to
# be here, and a copy without it is not gated.
cp "$R38/.git/hooks/pre-commit" "$R38/.git/hooks/commit-msg" "$R38/.git/hooks/vstack-guards" "$R38/shapehooks/"
check_in "$R38"
[ "$RC" -eq 0 ] && ok "control: the delegating line beside its helper is armed" \
  || bad "delegating line with helper armed" "rc=$RC out=$OUT"
rm -f "$R38/shapehooks/vstack-guards"
check_in "$R38"
[ "$RC" -eq 1 ] && ok "must-fail: the delegating line without its helper is not armed" \
  || bad "delegating line without helper" "rc=$RC out=$OUT"

echo "=== install refuses what --check could not vouch for ==="
# Installing under a shebang the check calls unverifiable would report a
# successful install that the very next `vstack check` contradicts.
R43="$(new_repo installshebangparity)"
mkdir -p "$R43/.git/hooks"
printf '#!/usr/bin/env bash\necho existing\n' >"$R43/.git/hooks/pre-commit"
chmod +x "$R43/.git/hooks/pre-commit"
install_in "$R43"
case "$OUT" in
  *"cannot be verified"*) ok "install says why it did not wire the hook" ;;
  *) bad "install refuses unverifiable shebang" "out=$OUT" ;;
esac
[ "$(sed -n '2p' "$R43/.git/hooks/pre-commit")" = "echo existing" ] \
  && ok "and it left the consumer's hook untouched" \
  || bad "install left the hook untouched" "line2=$(sed -n '2p' "$R43/.git/hooks/pre-commit")"
check_in "$R43"
[ "$RC" -ne 0 ] && ok "and --check agrees rather than contradicting the install" \
  || bad "check agrees with install" "rc=$RC out=$OUT"

echo "=== a shim carrying the guard line elsewhere is unverifiable, not ungated ==="
# --check writes nothing, so it does not get to assume the shim in front of
# it is the one the installer last wrote. A shim that still gates must never
# be reported as NOT gated — the same false answer, pointing the other way.
R42="$(new_repo checkshimguardline)"
install_in "$R42"
python3 - "$R42/.git/hooks/pre-commit" <<'PYMOVE'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
lines.insert(1, "# a comment someone added")
open(p, "w").write("\n".join(lines))
PYMOVE
check_in "$R42"
[ "$RC" -eq 2 ] && ok "a shim whose guard line moved is unverifiable" \
  || bad "moved guard line unverifiable" "rc=$RC out=$OUT"
printf '# %s: finish this\n' "$TD" >"$R42/gl.py"
git -C "$R42" add gl.py
commit_in "$R42" "feat: add gl"
[ "$RC" -ne 0 ] && ok "and that shim really does still gate, so 2 is not 'ungated'" \
  || bad "moved guard line still gates" "rc=$RC out=$OUT"
git -C "$R42" rm -q --cached gl.py
rm -f "$R42/gl.py"
# Control: with the guard line gone entirely, it is a verdict again.
python3 - "$R42/.git/hooks/pre-commit" <<'PYDEL'
import sys
p = sys.argv[1]
lines = [l for l in open(p).read().split("\n") if "vstack_gg_h" not in l]
open(p, "w").write("\n".join(lines))
PYDEL
check_in "$R42"
[ "$RC" -eq 1 ] && ok "control: with the guard line gone it is not armed" \
  || bad "absent guard line not armed" "rc=$RC out=$OUT"

echo "=== a tampered shebang in the DEFAULT hooks directory is not armed ==="
# The interpreter decides whether the guard line runs at all, and --check
# writes nothing, so the shim it is reading is not assumed to be the one the
# installer last wrote.
R41="$(new_repo checkshimshebang)"
install_in "$R41"
tail -n +2 "$R41/.git/hooks/pre-commit" >"$TMP/shimbody"
reshebang() { # LINE1
  { printf '%s\n' "$1"; cat "$TMP/shimbody"; } >"$R41/.git/hooks/pre-commit"
  chmod +x "$R41/.git/hooks/pre-commit"
}
check_in "$R41"
[ "$RC" -eq 0 ] && ok "control: the intact shim is armed" || bad "intact shim armed" "rc=$RC out=$OUT"

reshebang '#!/bin/sh -n'
check_in "$R41"
[ "$RC" -eq 2 ] && ok "a shim whose shebang stops the body running is not armed" \
  || bad "shim -n not armed" "rc=$RC out=$OUT"
printf '# %s: finish this\n' "$TD" >"$R41/sn.py"
git -C "$R41" add sn.py
commit_in "$R41" "feat: add sn"
[ "$RC" -eq 0 ] && ok "and that shim really does let a violation through" \
  || bad "shim -n bypasses" "rc=$RC out=$OUT"
git -C "$R41" rm -q --cached sn.py
rm -f "$R41/sn.py"

reshebang '#!/nonexistent/sh'
check_in "$R41"
[ "$RC" -eq 2 ] && ok "a shim naming an interpreter that is not here is not armed" \
  || bad "shim absent interpreter" "rc=$RC out=$OUT"

reshebang "$(printf '#!/bin/sh\r')"
check_in "$R41"
[ "$RC" -eq 1 ] && ok "a shim with a CR shebang is not armed" \
  || bad "shim CR shebang" "rc=$RC out=$OUT"

reshebang '#!/bin/sh'
check_in "$R41"
[ "$RC" -eq 0 ] && ok "control: restoring the shebang makes it armed again" \
  || bad "shim restored armed" "rc=$RC out=$OUT"

echo "=== a tampered helper in the DEFAULT hooks directory is not armed ==="
# --check is read-only, so "the installer rewrites this file" says nothing
# about the copy sitting there now. The marker is a comment anything can
# carry, and this is the ordinary, non-redirected install.
R40="$(new_repo checkhelperbytes)"
install_in "$R40"
check_in "$R40"
[ "$RC" -eq 0 ] && ok "control: the intact install is armed" \
  || bad "intact install armed" "rc=$RC out=$OUT"
printf '#!/bin/sh\n# vstack growth-guards git hooks\nexit 0\n' >"$R40/.git/hooks/vstack-guards"
chmod +x "$R40/.git/hooks/vstack-guards"
check_in "$R40"
[ "$RC" -eq 2 ] && ok "a helper replaced by a marker-carrying stub is not armed" \
  || bad "tampered helper not armed" "rc=$RC out=$OUT"
case "$OUT" in
  *"not the one this installer generates"*) ok "and the verdict names what it could not verify" ;;
  *) bad "tampered helper verdict names the cause" "out=$OUT" ;;
esac
printf '# %s: finish this\n' "$TD" >"$R40/th.py"
git -C "$R40" add th.py
commit_in "$R40" "feat: add th"
[ "$RC" -eq 0 ] && ok "and that stub really does bypass every guard" \
  || bad "tampered helper bypasses" "rc=$RC out=$OUT"

echo "=== a core.hooksPath directory that cannot be read is 'could not determine' ==="
R39="$(new_repo checkhookspathunreadable)"
install_in "$R39"
wire_hooks_dir "$R39" "$R39/customhooks"
git -C "$R39" config core.hooksPath customhooks
if [ "$(id -u)" != "0" ]; then
  chmod 000 "$R39/customhooks"
  check_in "$R39"
  chmod 755 "$R39/customhooks"
  [ "$RC" -eq 2 ] && ok "an unreadable core.hooksPath directory checks 2, never a verdict" \
    || bad "unreadable redirect checks 2" "rc=$RC out=$OUT"
  case "$OUT" in
    *"could not determine"*"$R39/customhooks"*) ok "and the verdict names the directory it could not read" ;;
    *) bad "unreadable redirect named" "out=$OUT" ;;
  esac
  case "$OUT" in
    *"wire that directory's hooks"*) bad "an unreadable redirect is not given the hand-wiring remedy" "out=$OUT" ;;
    *) ok "an unreadable redirect is not given the hand-wiring remedy" ;;
  esac
else
  ok "unreadable redirect case skipped (running as root)"
  ok "unreadable redirect wording skipped (running as root)"
  ok "unreadable redirect remedy skipped (running as root)"
fi
check_in "$R39"
[ "$RC" -eq 0 ] && ok "control: the same directory readable again checks 0" \
  || bad "control: readable redirect checks 0" "rc=$RC out=$OUT"

echo "=== --check resolves core.hooksPath the way git does ==="
R36="$(new_repo checkhookspathabs)"
install_in "$R36"
ABS_HOOKS="$TMP/abs-hooks"
wire_hooks_dir "$R36" "$ABS_HOOKS"
git -C "$R36" config core.hooksPath "$ABS_HOOKS"
check_in "$R36"
[ "$RC" -eq 0 ] && ok "an absolute core.hooksPath resolves and checks 0" \
  || bad "absolute hooksPath checks 0" "rc=$RC out=$OUT"
case "$OUT" in
  *armed*"$ABS_HOOKS"*) ok "and the verdict names the absolute directory" ;;
  *) bad "absolute hooksPath named" "out=$OUT" ;;
esac
rm -f "$ABS_HOOKS/pre-commit"
check_in "$R36"
[ "$RC" -eq 1 ] && ok "control: unwiring the absolute directory checks 1" \
  || bad "control: unwired absolute hooksPath checks 1" "rc=$RC out=$OUT"

# git resolves a relative core.hooksPath against the work-tree root, where it
# runs hooks — never against the caller's directory.
R37="$(new_repo checkhookspathsubdir)"
install_in "$R37"
wire_hooks_dir "$R37" "$R37/customhooks"
git -C "$R37" config core.hooksPath customhooks
mkdir -p "$R37/deep/nested"
check_from "$R37" "$R37/deep/nested"
[ "$RC" -eq 0 ] && ok "a relative core.hooksPath resolves from a subdirectory too" \
  || bad "relative hooksPath from subdir checks 0" "rc=$RC out=$OUT"
case "$OUT" in
  *"$R37/customhooks"*) ok "and it names the work-tree-rooted directory, not one under the subdirectory" ;;
  *) bad "subdir resolution names the work-tree-rooted directory" "out=$OUT" ;;
esac
# A decoy at the naive resolution the caller's directory would produce.
mkdir -p "$R37/deep/nested/customhooks"
printf '#!/bin/sh\nexit 0\n' >"$R37/deep/nested/customhooks/pre-commit"
printf '#!/bin/sh\nexit 0\n' >"$R37/deep/nested/customhooks/commit-msg"
chmod +x "$R37/deep/nested/customhooks/pre-commit" "$R37/deep/nested/customhooks/commit-msg"
rm -f "$R37/customhooks/pre-commit"
check_from "$R37" "$R37/deep/nested"
[ "$RC" -eq 1 ] && ok "must-fail: a decoy directory beside the caller cannot answer for the redirect" \
  || bad "decoy directory answers the redirect" "rc=$RC out=$OUT"
ABS_SUB="$TMP/abs-hooks-sub"
wire_hooks_dir "$R37" "$ABS_SUB"
git -C "$R37" config core.hooksPath "$ABS_SUB"
check_from "$R37" "$R37/deep/nested"
[ "$RC" -eq 0 ] && ok "an absolute core.hooksPath resolves from a subdirectory too" \
  || bad "absolute hooksPath from subdir checks 0" "rc=$RC out=$OUT"

echo "=== --check usage lanes ==="
OUT=""; RC=0; OUT="$("$INSTALL" --check --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && ok "--check with --uninstall is exit 2" || bad "check+uninstall is exit 2" "rc=$RC out=$OUT"
mkdir -p "$TMP/checknotgit"
OUT=""; RC=0; OUT="$("$INSTALL" --repo "$TMP/checknotgit" --check 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && ok "--check outside a git work tree is exit 2" || bad "check outside work tree" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
