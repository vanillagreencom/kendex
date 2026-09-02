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

# The subject is which scripts the shim reaches and which lanes run beside
# them, never the composition of the batch itself — size-ratchet and preflight
# are chain lanes, not members of it. So the batch runs one check, and each
# check keeps its own suite.
export GROWTH_GUARDS_CHECKS=todo-ban

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
sed -i.bak "s|^installed_scripts=.*|installed_scripts=''|" "$HELPER"
rm -f "$HELPER.bak"

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

echo "=== a package INSIDE the work tree is not the main checkout ==="
# git resolves upward, so the ownership test — does this candidate's common
# git dir match ours — says yes about every directory inside our own work
# tree. A git directory at <checkout>/meta/repo.git makes `${common%/*}`
# name <checkout>/meta, which passes ownership and is not a checkout root at
# all; a growth-guards under it would run as this repository's gate. Being
# the root is the second test: git's top level from there has to be there.
IN_DIR="$TMP/inside"
mkdir -p "$IN_DIR/meta"
git init -q --separate-git-dir "$IN_DIR/meta/repo.git" "$IN_DIR"
git -C "$IN_DIR" config user.email t@t
git -C "$IN_DIR" config user.name t
printf 'meta/\n.agents/\n' >"$IN_DIR/.gitignore"

# The decoy sits where `${common%/*}` points: inside our own work tree.
DECOY2="$IN_DIR/meta/.agents/skills/growth-guards/scripts"
mkdir -p "$DECOY2"
for lane in pre-commit commit-msg; do
  printf '#!/bin/sh\ntouch %s\nexit 0\n' "$TMP/inside-decoy-ran" >"$DECOY2/$lane"
  chmod +x "$DECOY2/$lane"
done

mkdir -p "$IN_DIR/.agents/skills"
cp -R "$SKILL_DIR" "$IN_DIR/.agents/skills/growth-guards"
OUT=""; RC=0
OUT="$("$IN_DIR/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$IN_DIR" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "a git dir inside its own work tree installs" \
  || bad "inside-git-dir install" "rc=$RC out=$OUT"

# The baked path is blanked so the helper has to rediscover, which is the
# search under test.
HELPER2="$IN_DIR/meta/repo.git/hooks/kendex-guards"
[ -f "$HELPER2" ] || HELPER2="$IN_DIR/.git/hooks/kendex-guards"
sed -i.bak "s|^installed_scripts=.*|installed_scripts=''|" "$HELPER2"
rm -f "$HELPER2.bak"

MARK2="TO""DO"
printf '# %s: nope\n' "$MARK2" >"$IN_DIR/b.py"
git -C "$IN_DIR" add -A
OUT=""; RC=0
OUT="$(cd "$IN_DIR" && git commit -m "feat: inside" 2>&1)" || RC=$?
[ -e "$TMP/inside-decoy-ran" ] \
  && bad "a package under the git dir's parent ran as the gate" "out=$OUT" \
  || ok "a directory inside the work tree is not its main checkout"
[ "$RC" != "0" ] && ok "and the real package gated the commit" \
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
sed -i.bak "s|^installed_scripts=.*|installed_scripts=''|" "$R90/.git/hooks/kendex-guards"
rm -f "$R90/.git/hooks/kendex-guards.bak"
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

echo "=== a project name survives every byte it may hold ==="
# The project the helper was armed from is baked into it as a shell
# assignment. A name carrying a quote ends that assignment and the rest of
# the name becomes script: a directory called `kid'"'"'; exit 0; #` once baked
# a helper that exited 0 before running anything, so both hooks passed every
# commit. A name carrying a newline spans lines instead.
#
# So the pin uses a name holding one of each awkward class at once: tab,
# newline, space, a quote, glob characters and a percent sign.
TAB="$(printf '\t')"
SQ="'"
NASTY="p${TAB}q r${SQ}s*?[x]%25"
NLR="$TMP/alphabet"
mkdir -p "$NLR"
git -C "$NLR" init -q
git -C "$NLR" config user.email t@t
git -C "$NLR" config user.name t
PROJ="$NLR/$NASTY
"
mkdir -p "$PROJ/.agents/skills"
cp -R "$SKILL_DIR" "$PROJ/.agents/skills/growth-guards"
INST="$PROJ/.agents/skills/growth-guards/scripts/install-git-hooks"

OUT=""; RC=0
OUT="$("$INST" --repo "$NLR" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "a project named with every awkward class arms" \
  || bad "awkward-name arm" "rc=$RC out=$OUT"

# --check regenerates the helper and compares bytes, so a name that did not
# survive the trip reports the helper as not ours.
OUT=""; RC=0
OUT="$("$INST" --repo "$NLR" --check 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "and --check still recognises its own helper" \
  || bad "the record did not round-trip" "rc=$RC out=$OUT"

OUT=""; RC=0
OUT="$("$INST" --repo "$NLR" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "and the project can disarm again" \
  || bad "awkward-name uninstall" "rc=$RC out=$OUT"
[ -e "$NLR/.git/hooks/kendex-guards" ] \
  && bad "the shims survived their own uninstall" "out=$OUT" \
  || ok "with the shims gone"


printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
