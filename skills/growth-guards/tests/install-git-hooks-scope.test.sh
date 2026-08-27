#!/usr/bin/env bash
# Which repository an install belongs to, and what the chain composes with:
# shared hooks directories and linked work trees, a copy-method install
# rediscovered, hooks written back byte-for-byte, and the size-ratchet and
# preflight lanes the shim runs beside its own checks — including every way
# one of them can be broken, which blocks rather than skips.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=lib/install-hooks.bash
. "$TEST_DIR/lib/install-hooks.bash"

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
[ -f "$R18/.git/hooks/kendex-guards" ] && ok "the main checkout keeps its guard" || bad "main checkout keeps its guard"

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
grep -qF "installed_scripts='$TMP/wt4/.agents/skills/growth-guards/scripts'" "$R18C/.git/hooks/kendex-guards" \
  && ok "the kept helper is retargeted at the surviving install" || bad "kept helper retargeted" "out=$OUT"
rm -rf -- "$R18C/.agents/skills/growth-guards"
printf 'hello\n' >"$TMP/wt4/w.txt"
git -C "$TMP/wt4" add w.txt
OUT=""; RC=0; OUT="$(git -C "$TMP/wt4" commit -m "feat: from the surviving worktree" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "the surviving work tree still commits through the retargeted helper" \
  || bad "surviving worktree commits" "rc=$RC out=$OUT"

echo "=== a repository that commits its skills is ONE install ==="
# Under the committed posture every work tree checks the package out from
# git, so a sibling always physically carries it. Counting that as a
# separate install would find a survivor in every sibling and keep the shims
# armed forever — a repository nobody could disarm. Tracked content is this
# repository's own, however many places it is checked out.
R18T="$(new_repo shared-tracked)"
# Committed before the shims are armed: the chain would otherwise judge the
# skill's own fixtures, which carry the shapes it bans on purpose.
git -C "$R18T" add -A .agents
commit_in "$R18T" "feat: commit the harness render"
[ "$RC" -eq 0 ] || bad "the render commit landed" "rc=$RC out=$OUT"
install_in "$R18T"
git -C "$R18T" worktree add -q "$TMP/wt-tracked" -b wt-tracked-b
[ -x "$TMP/wt-tracked/.agents/skills/growth-guards/scripts/pre-commit" ] \
  && ok "the linked work tree carries the package from git" \
  || bad "linked work tree carries the tracked package"
OUT=""; RC=0
OUT="$("$R18T/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R18T" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "uninstalling a tracked-package repository exits 0" \
  || bad "tracked uninstall exits 0" "rc=$RC out=$OUT"
case "$OUT" in
  *"kept —"*) bad "a tracked sibling was mistaken for a separate install" "out=$OUT" ;;
  *) ok "the shims are removed rather than retargeted at a sibling work tree" ;;
esac
[ -f "$R18T/.git/hooks/kendex-guards" ] \
  && bad "the helper survived a disarm it should have taken" \
  || ok "the helper is gone, so the repository is disarmed"

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
[ -e "$R18B/.git/hooks/kendex-guards" ] && bad "a work tree linking back to this install does not keep the shims" \
  || ok "a work tree linking back to this install does not keep the shims"

R18D="$(new_repo shared-cursor)"
install_in "$R18D"
printf 'hello\n' >"$R18D/a.txt"
git -C "$R18D" add a.txt
commit_in "$R18D" "feat: add a"
git -C "$R18D" worktree add -q "$TMP/wt5" -b wt5b
# A copy-method install for Cursor: a skills root the survivor check must
# know. `.cursor/skills` is that root — `.cursor/rules` is where Cursor
# keeps rules, holds no skills, and was searched here by mistake.
mkdir -p "$TMP/wt5/.cursor/skills"
cp -R "$SKILL_DIR" "$TMP/wt5/.cursor/skills/growth-guards"
OUT=""; RC=0
OUT="$("$R18D/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R18D" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "uninstall beside a Cursor install exits 0" || bad "cursor survivor uninstall exits 0" "rc=$RC out=$OUT"
[ -f "$R18D/.git/hooks/kendex-guards" ] && ok "a survivor under .cursor/skills keeps the shared shims" \
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
[ -f "$R18F/.git/hooks/kendex-guards" ] && ok "and its shared shims are kept" || bad "newline-path survivor keeps shims" "out=$OUT"

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
[ -f "$R18G/.git/hooks/kendex-guards" ] && ok "and the shims are kept rather than guessed away" \
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
[ -f "$R18H/.git/hooks/kendex-guards" ] && ok "a survivor behind a relative registration keeps the shims" \
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
[ -f "$TMP/sgd/gitdir/hooks/kendex-guards" ] && ok "and the main checkout keeps its guard" \
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
  [ -f "$R18I/.git/hooks/kendex-guards" ] && ok "and the shared shims are kept" \
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
  [ -f "$R18J/.git/hooks/kendex-guards" ] && ok "and those shared shims are kept too" \
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
sed -i.bak "s|^installed_scripts=.*|installed_scripts='$R19/gone/scripts'|" "$R19/.git/hooks/kendex-guards"
rm -f "$R19/.git/hooks/kendex-guards.bak"
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
[ -f "$TMP/sgdparent/external.git/hooks/kendex-guards" ] && ok "and the real main checkout keeps its guard" \
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

echo "=== the helper does not run a package beside an external git dir ==="
# `${common%/*}` is the main checkout only in the ordinary <main>/.git
# layout. Under --separate-git-dir the git directory lives outside the
# checkout, so that is an unrelated directory — and one carrying its own
# growth-guards ran here as the repository's commit gate.
OUT_DIR="$TMP/separate"
mkdir -p "$OUT_DIR"
git init -q --separate-git-dir "$OUT_DIR/elsewhere.git" "$OUT_DIR/checkout"
git -C "$OUT_DIR/checkout" config user.email t@t
git -C "$OUT_DIR/checkout" config user.name t

# A decoy beside the git directory, which is what `${common%/*}` names.
DECOY="$OUT_DIR/.agents/skills/growth-guards/scripts"
mkdir -p "$DECOY"
for lane in pre-commit commit-msg; do
  printf '#!/bin/sh\ntouch %s\nexit 0\n' "$TMP/decoy-ran" >"$DECOY/$lane"
  chmod +x "$DECOY/$lane"
done

# The real package installs from inside the checkout, then the baked path is
# blanked so the helper has to rediscover — which is the search under test.
mkdir -p "$OUT_DIR/checkout/.agents/skills"
cp -R "$SKILL_DIR" "$OUT_DIR/checkout/.agents/skills/growth-guards"
OUT=""; RC=0
OUT="$("$OUT_DIR/checkout/.agents/skills/growth-guards/scripts/install-git-hooks" \
  --repo "$OUT_DIR/checkout" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "install succeeds under a separate git dir" \
  || bad "separate-git-dir install" "rc=$RC out=$OUT"

HELPER="$OUT_DIR/elsewhere.git/hooks/kendex-guards"
[ -f "$HELPER" ] || HELPER="$OUT_DIR/checkout/.git/hooks/kendex-guards"
sed -i "s|^installed_scripts=.*|installed_scripts=''|" "$HELPER"

MARK="TO""DO"
printf '# %s: nope\n' "$MARK" >"$OUT_DIR/checkout/b.py"
git -C "$OUT_DIR/checkout" add -A
OUT=""; RC=0
OUT="$(cd "$OUT_DIR/checkout" && git commit -m "feat: separate" 2>&1)" || RC=$?
[ -e "$TMP/decoy-ran" ] \
  && bad "the decoy beside the git dir ran as the gate" "out=$OUT" \
  || ok "a package beside the external git dir is not this repository's"
[ "$RC" -ne 0 ] && ok "and the commit is blocked rather than passed" \
  || bad "commit passed with no gate" "rc=$RC out=$OUT"

echo "=== a linked worktree is still served by the main checkout ==="
# The ownership check must not cost the ordinary case: git answers
# --git-common-dir relative to where it is asked, so comparing it unresolved
# would drop the real main checkout and strand every linked worktree.
R90="$(new_repo linked-main)"
install_in "$R90"
printf 'hello\n' >"$R90/a.txt"
git -C "$R90" add -A
commit_in "$R90" "feat: base"
git -C "$R90" worktree add -q "$TMP/wt9" -b wt9b
sed -i "s|^installed_scripts=.*|installed_scripts=''|" "$R90/.git/hooks/kendex-guards"
printf '# %s: nope\n' "$MARK" >"$TMP/wt9/c.py"
git -C "$TMP/wt9" add -A
OUT=""; RC=0
OUT="$(cd "$TMP/wt9" && git commit -m "feat: linked" 2>&1)" || RC=$?
case "$OUT" in
  *todo-ban*) ok "the worktree rediscovers the main checkout's package" ;;
  *"no executable growth-guards"*) bad "the ownership check stranded a linked worktree" "$OUT" ;;
  *) bad "the linked worktree commit did not reach the chain" "$OUT" ;;
esac
[ "$RC" -ne 0 ] && ok "and its verdict blocks the commit" \
  || bad "linked worktree commit passed" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
