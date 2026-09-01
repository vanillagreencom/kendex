#!/usr/bin/env bash
# Arming a repository, and the gate the shims then are: a real `git commit`
# from any tool is blocked by each check and passes when clean, existing
# hooks survive and keep their verdict, and uninstall gives the repo back.
# Every blocking pin is paired with the passing control that proves the
# commit was blocked by the guard and not by the fixture.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=lib/install-hooks.bash
. "$TEST_DIR/lib/install-hooks.bash"

echo "=== install lands both shims and the helper ==="
R="$(new_repo basic)"
install_in "$R"
[ "$RC" -eq 0 ] && ok "installer exits 0" || bad "installer exits 0" "rc=$RC out=$OUT"
case "$OUT" in
  *"pre-commit and commit-msg armed"*) ok "summary line names both shims" ;;
  *) bad "summary line names both shims" "out=$OUT" ;;
esac
for f in kendex-guards pre-commit commit-msg; do
  [ -x "$R/.git/hooks/$f" ] && ok "$f is executable" || bad "$f is executable" "missing or not +x"
done
sh -n "$R/.git/hooks/kendex-guards" 2>/dev/null && ok "the helper is POSIX-sh clean" || bad "helper is POSIX-sh clean"
grep -qF "installed_scripts='$R/.agents/skills/growth-guards/scripts'" "$R/.git/hooks/kendex-guards" \
  && ok "the helper names the scripts directory it was installed from" || bad "helper names its scripts dir"
grep -qF 'kendex-guards' "$R/.git/hooks/pre-commit" && ok "pre-commit carries the marked delegating line" \
  || bad "pre-commit carries the marked line"
# On a fresh repo the installer writes the shims itself, so each is exactly
# what it emits and nothing more: the current shebang, the delegate at line 2,
# the created marker. Anything else here is a hook the installer inherited,
# and it emits no shebang but this one — an install that reported success
# under another would be one `--check` calls unverifiable.
for f in pre-commit commit-msg; do
  [ "$(head -n 1 "$R/.git/hooks/$f")" = "#!/bin/sh" ] \
    && ok "$f carries the current shebang" \
    || bad "$f carries the current shebang" "line1=$(head -n 1 "$R/.git/hooks/$f")"
  [ "$(sed -n '3p' "$R/.git/hooks/$f")" = "# kendex-guards-hook created this file" ] \
    && ok "$f records that the installer created it" \
    || bad "$f records that the installer created it" "line3=$(sed -n '3p' "$R/.git/hooks/$f")"
  [ "$(wc -l <"$R/.git/hooks/$f")" -eq 3 ] \
    && ok "$f holds those three lines and nothing else" \
    || bad "$f holds those three lines and nothing else" "$(cat "$R/.git/hooks/$f")"
done
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
printf '[env]\nSIZE_RATCHET_THRESHOLD = "5"\n' >"$R/kendex.settings.toml"
git -C "$R" add kendex.settings.toml
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
rm -f "$R/big.txt" "$R/kendex.settings.toml"
git -C "$R" rm -q --cached kendex.settings.toml
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
printf '[env]\nGROWTH_GUARDS_CHECKS = "todo-ban"\n' >"$R27/kendex.settings.toml"
printf 'hello\n' >"$R27/a.txt"
git -C "$R27" add -A
install_in "$R27"
commit_in "$R27" "feat: seed"
[ "$RC" -eq 0 ] && ok "control: the seed commit lands" || bad "staged-settings seed" "rc=$RC out=$OUT"
printf '# %s: nope\n' "$TD" >"$R27/b.py"
git -C "$R27" add b.py
# Switched off on disk only: the commit keeps todo-ban enabled.
printf '[env]\nGROWTH_GUARDS_CHECKS = "byte-ceiling"\n' >"$R27/kendex.settings.toml"
commit_in "$R27" "feat: add b"
[ "$RC" -ne 0 ] && ok "an unstaged settings edit cannot switch a check off" \
  || bad "unstaged settings edit ignored" "rc=$RC out=$OUT"
git -C "$R27" add kendex.settings.toml
commit_in "$R27" "feat: add b"
[ "$RC" -eq 0 ] && ok "control: staging that edit applies it" || bad "staged settings edit applies" "rc=$RC out=$OUT"

R27B="$(new_repo stagedtypes)"
printf '.agents/\n' >"$R27B/.gitignore"
printf '[env]\nGROWTH_GUARDS_COMMIT_TYPES = "feat"\n' >"$R27B/kendex.settings.toml"
printf 'hello\n' >"$R27B/a.txt"
git -C "$R27B" add -A
install_in "$R27B"
commit_in "$R27B" "feat: seed"
[ "$RC" -eq 0 ] && ok "control: the committed type list admits its own type" || bad "staged-types seed" "rc=$RC out=$OUT"
printf 'more\n' >"$R27B/b.txt"
git -C "$R27B" add b.txt
# Widened on disk only: the commit still permits only feat.
printf '[env]\nGROWTH_GUARDS_COMMIT_TYPES = "hack"\n' >"$R27B/kendex.settings.toml"
commit_in "$R27B" "hack: sneak a type in"
[ "$RC" -ne 0 ] && ok "an unstaged commit-type edit does not widen the message gate" \
  || bad "unstaged commit types ignored" "rc=$RC out=$OUT"
git -C "$R27B" add kendex.settings.toml
commit_in "$R27B" "hack: sneak a type in"
[ "$RC" -eq 0 ] && ok "control: staging that edit applies it" || bad "staged commit types apply" "rc=$RC out=$OUT"

echo "=== the size gate judges the staged blob, not the worktree copy ==="
R23="$(new_repo stagedsize)"
printf '.agents/\n' >"$R23/.gitignore"
printf '[env]\nSIZE_RATCHET_THRESHOLD = "5"\n' >"$R23/kendex.settings.toml"
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
printf '[env]\nGROWTH_GUARDS_PRE_COMMIT_LOCAL = "tools/local-check"\n' >"$R/kendex.settings.toml"
git -C "$R" add tools/local-check kendex.settings.toml
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
printf '[env]\nGROWTH_GUARDS_PRE_COMMIT_LOCAL = "../escape"\n' >"$R/kendex.settings.toml"
commit_in "$R" "chore: escaping local entry"
[ "$RC" -ne 0 ] && ok "a repo-local entry escaping the repo root blocks" || bad "escaping local entry blocks" "rc=$RC out=$OUT"
rm -f "$R/kendex.settings.toml"
git -C "$R" checkout -q -- . 2>/dev/null || true
git -C "$R" reset -q --hard HEAD

echo "=== a guard that cannot run blocks (fail closed) ==="
R2="$(new_repo failclosed)"
install_in "$R2"
printf 'hello\n' >"$R2/a.txt"
git -C "$R2" add a.txt
H2="$R2/.git/hooks/kendex-guards"
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
sed -i.bak "s|^installed_scripts=.*|installed_scripts='$R2B/gone/scripts'|" "$R2B/.git/hooks/kendex-guards"
rm -f "$R2B/.git/hooks/kendex-guards.bak"
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
mv "$R2C/.git/hooks/kendex-guards" "$R2C/.git/hooks/kendex-guards.away"
RC=0; (cd "$R2C" && .git/hooks/pre-commit >/dev/null 2>&1) || RC=$?
[ "$RC" -eq 2 ] && ok "a missing helper exits 2 (could not complete)" || bad "missing helper exits 2" "rc=$RC"
mv "$R2C/.git/hooks/kendex-guards.away" "$R2C/.git/hooks/kendex-guards"
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
[ -e "$R12/.git/hooks/kendex-guards" ] && bad "the helper is removed" || ok "the helper is removed"
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
printf '#!/bin/sh\nexit 0\n' >"$R13/.git/hooks/kendex-guards"
FOREIGN_HELPER="$(cat "$R13/.git/hooks/kendex-guards")"
OUT=""; RC=0
OUT="$("$R13/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R13" --uninstall 2>&1)" || RC=$?
[ "$FOREIGN_HELPER" = "$(cat "$R13/.git/hooks/kendex-guards")" ] && ok "uninstall never deletes a file it did not write" \
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
[ "$(grep -cF 'kendex-guards-hook' "$R3/.git/hooks/pre-commit")" -eq 1 ] && ok "our line is added exactly once" \
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
grep -qF 'kendex-guards' "$R5/.git/hooks/commit-msg" && ok "the other hook is still installed" || bad "other hook installed"

R6="$(new_repo disabled)"
printf '#!/bin/sh\nexit 0\n' >"$R6/.git/hooks/pre-commit"
chmod -x "$R6/.git/hooks/pre-commit"
install_in "$R6"
[ "$RC" -eq 1 ] && ok "a disabled (non-executable) hook is not appended to" || bad "disabled hook not appended" "rc=$RC out=$OUT"
grep -qF 'kendex-guards' "$R6/.git/hooks/pre-commit" && bad "disabled hook left untouched" || ok "disabled hook left untouched"

R6B="$(new_repo mentions)"
printf '#!/bin/sh\n# see .git/hooks/kendex-guards for the shared guard\nexit 0\n' >"$R6B/.git/hooks/pre-commit"
chmod +x "$R6B/.git/hooks/pre-commit"
install_in "$R6B"
grep -qF 'kendex-guards-hook' "$R6B/.git/hooks/pre-commit" \
  && ok "a hook that merely mentions the helper still gets the guard" || bad "hook mentioning the helper is still guarded"

R7="$(new_repo notshell)"
printf '#!/usr/bin/env python3\nraise SystemExit(0)\n' >"$R7/.git/hooks/pre-commit"
chmod +x "$R7/.git/hooks/pre-commit"
install_in "$R7"
[ "$RC" -eq 1 ] && ok "a non-shell hook is not appended to" || bad "non-shell hook not appended" "rc=$RC out=$OUT"
grep -qF 'kendex-guards' "$R7/.git/hooks/pre-commit" && bad "non-shell hook left untouched" || ok "non-shell hook left untouched"

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
FRESH="$(cat "$R9/.git/hooks/kendex-guards")"
printf '#!/bin/sh\n# kendex growth-guards git hooks\nexit 0\n' >"$R9/.git/hooks/kendex-guards"
install_in "$R9"
[ "$RC" -eq 0 ] && [ "$FRESH" = "$(cat "$R9/.git/hooks/kendex-guards")" ] && ok "a stale helper of ours is rewritten" \
  || bad "stale helper rewritten" "rc=$RC"
printf '#!/bin/sh\nexit 0\n' >"$R9/.git/hooks/kendex-guards"
FOREIGN="$(cat "$R9/.git/hooks/kendex-guards")"
install_in "$R9"
[ "$RC" -eq 1 ] && ok "a foreign file at the helper path aborts the install" || bad "foreign helper aborts" "rc=$RC out=$OUT"
[ "$FOREIGN" = "$(cat "$R9/.git/hooks/kendex-guards")" ] && ok "the foreign file is left untouched" || bad "foreign helper untouched"
rm "$R9/.git/hooks/kendex-guards"
mkdir "$R9/.git/hooks/kendex-guards"
install_in "$R9"
[ "$RC" -eq 1 ] && ok "a non-regular file at the helper path aborts the install" || bad "non-regular helper aborts" "rc=$RC out=$OUT"
rmdir "$R9/.git/hooks/kendex-guards"

echo "=== re-installing is a no-op ==="
R10="$(new_repo idempotent)"
install_in "$R10"
BEFORE_HELPER="$(cat "$R10/.git/hooks/kendex-guards")"
BEFORE_PRE="$(cat "$R10/.git/hooks/pre-commit")"
BEFORE_MSG="$(cat "$R10/.git/hooks/commit-msg")"
install_in "$R10"
install_in "$R10"
[ "$RC" -eq 0 ] && ok "a repeat install exits 0" || bad "repeat install exits 0" "rc=$RC out=$OUT"
[ "$BEFORE_HELPER" = "$(cat "$R10/.git/hooks/kendex-guards")" ] && ok "the helper is unchanged" || bad "helper unchanged"
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

echo "=== a line that only mentions the marker is not ours ==="
# Ownership is the marker CLOSING a line. A consumer's own line that merely
# mentions it mid-sentence is theirs, and neither a repair nor a removal may
# eat it — the failure that costs somebody their hook is worse than the one
# that leaves a stale line of ours behind.
R21M="$(new_repo mentions-marker)"
printf '#!/bin/sh\necho "see # %s for details"\necho mine\n' "kendex-guards-hook" \
  >"$R21M/.git/hooks/pre-commit"
chmod +x "$R21M/.git/hooks/pre-commit"
MENTION_BEFORE="$(cat "$R21M/.git/hooks/pre-commit")"
install_in "$R21M"
grep -qF 'for details' "$R21M/.git/hooks/pre-commit" \
  && ok "a repair keeps a line that only mentions the marker" \
  || bad "repair kept the mention" "got: $(cat "$R21M/.git/hooks/pre-commit")"
OUT=""; RC=0
OUT="$("$R21M/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R21M" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "the removal exits 0" || bad "mention uninstall exits 0" "rc=$RC out=$OUT"
[ "$MENTION_BEFORE" = "$(cat "$R21M/.git/hooks/pre-commit")" ] \
  && ok "and it restores that hook byte-for-byte" \
  || bad "removal kept the mention" "got: $(cat "$R21M/.git/hooks/pre-commit")"

echo "=== a hook that only quotes a marker is not ours ==="
# The ownership question and the shape question fail in opposite directions,
# and this is the ownership one: ours is the marker CLOSING a line, so a
# consumer hook that mentions it in a sentence is somebody else's file.
QUOTE_SENTINEL="# kendex-guards-hook"

# The symlink branch asks that question of a target it must not edit.
R53="$(new_repo quoter-symlink)"
install_in "$R53"
printf '#!/bin/sh\n# ours end in %s, this one does not\necho mine\n' \
  "$QUOTE_SENTINEL" >"$TMP/foreign-target"
chmod +x "$TMP/foreign-target"
rm -f "$R53/.git/hooks/commit-msg"
ln -s "$TMP/foreign-target" "$R53/.git/hooks/commit-msg"
OUT=""; RC=0
OUT="$("$R53/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R53" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "uninstall succeeds beside a symlink to a hook that quotes the marker" \
  || bad "uninstall failed" "rc=$RC out=$OUT"
case "$OUT" in
  *"symlink carrying the guard line"*)
    bad "a quoting symlink target was claimed as ours" "$OUT" ;;
  *) ok "and does not claim the quoting target as ours" ;;
esac
[ -L "$R53/.git/hooks/commit-msg" ] && ok "and the symlink is left in place" \
  || bad "the symlink went" "out=$OUT"

# The must-fail control: a symlink to a target that really carries our line
# IS claimed, so the pins above are not passing on a predicate that never
# matches anything.
R54="$(new_repo real-symlink)"
install_in "$R54"
cp "$R54/.git/hooks/pre-commit" "$TMP/real-target"
rm -f "$R54/.git/hooks/commit-msg"
ln -s "$TMP/real-target" "$R54/.git/hooks/commit-msg"
OUT=""; RC=0
OUT="$("$R54/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R54" --uninstall 2>&1)" || RC=$?
case "$OUT" in
  *"symlink carrying the guard line"*)
    ok "must-fail: a symlink to a target that does carry our line is claimed" ;;
  *) bad "a real guard line in a symlink target was missed" "$OUT" ;;
esac

echo "=== a disabled delegate is not an install ==="
R20="$(new_repo tampered)"
install_in "$R20"
ORIGINAL_PRE="$(cat "$R20/.git/hooks/pre-commit")"
sed -i.bak 's|^kendex_gg_h=|#kendex_gg_h=|' "$R20/.git/hooks/pre-commit"
rm -f "$R20/.git/hooks/pre-commit.bak"
grep -qF 'kendex-guards-hook' "$R20/.git/hooks/pre-commit" && ok "the tampered line still carries the sentinel (fixture)" \
  || bad "tampered fixture keeps the sentinel"
install_in "$R20"
[ "$ORIGINAL_PRE" = "$(cat "$R20/.git/hooks/pre-commit")" ] && ok "a commented-out delegate is restored, not trusted" \
  || bad "commented-out delegate restored" "got: $(cat "$R20/.git/hooks/pre-commit")"
printf '# %s: nope\n' "$TD" >"$R20/b.py"
git -C "$R20" add b.py
commit_in "$R20" "feat: add b"
[ "$RC" -ne 0 ] && ok "control: the restored delegate blocks again" || bad "restored delegate blocks" "rc=$RC out=$OUT"
git -C "$R20" reset -q; rm -f "$R20/b.py"
printf '#!/bin/sh\nold_delegate_from_a_previous_version  # kendex-guards-hook\necho mine\n' >"$R20/.git/hooks/commit-msg"
chmod +x "$R20/.git/hooks/commit-msg"
install_in "$R20"
[ "$(grep -cF 'kendex-guards-hook' "$R20/.git/hooks/commit-msg")" -eq 1 ] \
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
[ "$(grep -cF 'kendex-guards-hook' "$R28/.git/hooks/pre-commit")" -eq 1 ] \
  && ok "and it is not duplicated" || bad "moved delegate duplicated"
printf '# %s: nope\n' "$TD" >"$R28/b.py"
git -C "$R28" add b.py
commit_in "$R28" "feat: add b"
[ "$RC" -ne 0 ] && ok "control: the repositioned delegate blocks again" || bad "repositioned delegate blocks" "rc=$RC out=$OUT"

echo "=== a consumer's own trusted shebang survives the rewrite ==="
# The rewrite re-emits line 1 as it found it. Hardcoding #!/bin/sh there would
# be invisible on every other fixture, which all carry that spelling, and would
# hand a bash-only body to a shell that cannot parse it.
R56="$(new_repo bash-consumer)"
FOREIGN_BASH="$R56/.git/hooks/pre-commit"
printf '#!/bin/bash
m=(state)
echo "consumer ${m[0]}"
' >"$FOREIGN_BASH"
chmod +x "$FOREIGN_BASH"
install_in "$R56"
[ "$(head -n 1 "$FOREIGN_BASH")" = "#!/bin/bash" ] \
  && ok "a trusted shebang that is not /bin/sh is left as written" \
  || bad "the consumer's shebang was rewritten" "$(cat "$FOREIGN_BASH")"
case "$(sed -n '2p' "$FOREIGN_BASH")" in
  *"# kendex-guards-hook") ok "and the delegate is installed at line 2 above it" ;;
  *) bad "delegate not at line 2" "$(cat "$FOREIGN_BASH")" ;;
esac
[ "$(tail -n +3 "$FOREIGN_BASH")" = "$(printf 'm=(state)\necho "consumer ${m[0]}"')" ] \
  && ok "and the bash-only body below it is byte for byte what it was" \
  || bad "consumer body altered" "$(cat "$FOREIGN_BASH")"

echo "=== a non-POSIX-shell hook is left alone ==="
R15="$(new_repo fish)"
printf '#!/usr/bin/fish\necho hi\n' >"$R15/.git/hooks/pre-commit"
chmod +x "$R15/.git/hooks/pre-commit"
install_in "$R15"
[ "$RC" -eq 1 ] && ok "a fish hook is not modified (exit 1)" || bad "fish hook not modified" "rc=$RC out=$OUT"
grep -qF 'kendex-guards-hook' "$R15/.git/hooks/pre-commit" && bad "fish hook left untouched" || ok "fish hook left untouched"

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
[ -f "$R17B/.git/hooks/kendex-guards" ] && ok "and the helper is kept" || bad "unreadable symlink keeps helper"

echo "=== uninstall refuses to strand a delegate ==="
R17="$(new_repo uninstall-symlinked)"
install_in "$R17"
mv "$R17/.git/hooks/pre-commit" "$TMP/linked-pre-commit"
ln -s "$TMP/linked-pre-commit" "$R17/.git/hooks/pre-commit"
OUT=""; RC=0
OUT="$("$R17/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R17" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && ok "a symlinked hook carrying our line fails the uninstall" || bad "symlinked uninstall fails" "rc=$RC out=$OUT"
[ -f "$R17/.git/hooks/kendex-guards" ] && ok "the helper is kept while a delegate survives" || bad "helper kept while delegate survives"

R24="$(new_repo unreadable-hook)"
install_in "$R24"
chmod 0300 "$R24/.git/hooks/pre-commit"
OUT=""; RC=0
OUT="$("$R24/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R24" --uninstall 2>&1)" || RC=$?
chmod 0755 "$R24/.git/hooks/pre-commit" 2>/dev/null || true
[ "$RC" -eq 1 ] && ok "an unreadable managed hook fails the uninstall" || bad "unreadable hook fails uninstall" "rc=$RC out=$OUT"
[ -f "$R24/.git/hooks/kendex-guards" ] && ok "and the helper is kept beside it" || bad "unreadable hook keeps helper"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
