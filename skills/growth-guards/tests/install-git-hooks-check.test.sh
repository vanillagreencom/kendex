#!/usr/bin/env bash
# `--check` over the shims this installer writes: armed, drifted, absent, or
# unverifiable — and never a silent pass. It writes nothing, and install
# refuses to overwrite what it could not vouch for. core.hooksPath stands
# this whole verdict down, which is the -hookspath suite.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=lib/install-hooks.bash
. "$TEST_DIR/lib/install-hooks.bash"

echo "=== --check answers whether the shims are armed, and modifies nothing on disk ==="
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
grep -qF 'kendex-guards' "$R32/.git/hooks/pre-commit" && bad "--check must not repair the hook" || ok "--check did not repair the hook"

install_in "$R32"
chmod -x "$R32/.git/hooks/pre-commit"
check_in "$R32"
[ "$RC" -eq 1 ] && ok "a cleared executable bit checks 1" || bad "cleared exec bit checks 1" "rc=$RC out=$OUT"
case "$OUT" in
  *"not executable"*) ok "and says git ignores it" ;;
  *) bad "exec bit named" "out=$OUT" ;;
esac
chmod +x "$R32/.git/hooks/pre-commit"

printf '#!/bin/sh\nexit 0\n' >"$R32/.git/hooks/kendex-guards"
check_in "$R32"
[ "$RC" -eq 1 ] && ok "a foreign file at the helper path checks 1" || bad "foreign helper checks 1" "rc=$RC out=$OUT"
case "$OUT" in
  *"not written by this installer"*) ok "and the foreign helper is named" ;;
  *) bad "foreign helper named" "out=$OUT" ;;
esac
rm "$R32/.git/hooks/kendex-guards"
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

echo "=== install refuses what --check could not vouch for ==="
# Installing under a shebang the check calls unverifiable would report a
# successful install that the very next `kendex check` contradicts.
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

# The same refusal for a hook THIS INSTALLER wrote: ownership buys no licence
# to rewrite the interpreter someone since chose. An install that reported
# success here would be one `kendex check` calls unverifiable.
R44="$(new_repo installstaleshebang)"
install_in "$R44"
{
  printf '#!/usr/local/bin/bash\n'
  tail -n +2 "$R44/.git/hooks/pre-commit"
} >"$TMP/reshebanged" && mv "$TMP/reshebanged" "$R44/.git/hooks/pre-commit"
chmod +x "$R44/.git/hooks/pre-commit"
grep -qF -- "kendex_gg_h" "$R44/.git/hooks/pre-commit" \
  && ok "control: the fixture is our own shim under an untrusted interpreter" \
  || bad "fixture carries the guard line" "$(sed -n '2p' "$R44/.git/hooks/pre-commit")"
BEFORE44="$(cat "$R44/.git/hooks/pre-commit")"
install_in "$R44"
case "$OUT" in
  *"cannot be verified"*) ok "install refuses a shim of ours under an untrusted interpreter" ;;
  *) bad "install refuses our own untrusted shim" "out=$OUT" ;;
esac
[ "$(cat "$R44/.git/hooks/pre-commit")" = "$BEFORE44" ] \
  && ok "and leaves it byte for byte, shebang included" \
  || bad "our untrusted shim was rewritten" "$(cat "$R44/.git/hooks/pre-commit")"
check_in "$R44"
[ "$RC" -eq 2 ] && ok "and --check calls it unverifiable, not merely not armed" \
  || bad "check calls our untrusted shim unverifiable" "rc=$RC out=$OUT"

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
lines = [l for l in open(p).read().split("\n") if "kendex_gg_h" not in l]
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
printf '#!/bin/sh\n# kendex growth-guards git hooks\nexit 0\n' >"$R40/.git/hooks/kendex-guards"
chmod +x "$R40/.git/hooks/kendex-guards"
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

echo "=== a helper another checkout of this repository armed is armed here ==="
# A linked worktree shares one hooks directory with the checkout that armed
# it, and carries its own render, so the helper it would write names its own
# scripts directory. Compared whole, every worktree reported its own armed
# hooks as unverifiable.
R42="$(new_repo checkotherckout)"
git -C "$R42" add -A >/dev/null 2>&1
commit_in "$R42" "chore: seed"
install_in "$R42"
W42="$TMP/checkotherckout-wt"
git -C "$R42" worktree add -q -b wt "$W42" >/dev/null 2>&1
check_in "$W42"
[ "$RC" -eq 0 ] && ok "a linked worktree recognizes the helper the main checkout armed" \
  || bad "worktree recognizes armed helper" "rc=$RC out=$OUT"

HELPER42="$R42/.git/hooks/kendex-guards"
# Every case below must answer non-zero: each is a helper this installer
# would not have written, and blessing one is what lets something other than
# this repository's own lanes run as its gate.
rebake() { # LINE — put LINE in place of the helper's installed_scripts
  perl -i -pe "BEGIN { \$r = shift } s{^installed_scripts=.*\$}{\$r}" "$1" "$HELPER42"
}

install_in "$R42"
rebake "installed_scripts='/tmp/x'; echo PWNED >&2; :'"
check_in "$R42"
[ "$RC" -ne 0 ] && ok "a payload after the closing quote is not armed" \
  || bad "quote-escape payload refused" "rc=$RC out=$OUT"

install_in "$R42"
rebake "installed_scripts='/nope'; touch \"\$TMPDIR/PWNED-\$\$\" 2>/dev/null; installed_scripts='/nope'"
check_in "$R42"
[ "$RC" -ne 0 ] && ok "a value that closes and reopens its quoting is not armed" \
  || bad "reopened quote refused" "rc=$RC out=$OUT"

install_in "$R42"
perl -i -pe "s{^project_rel='.*'\$}{project_rel='x'; echo PWNED >&2; :'}" "$HELPER42"
check_in "$R42"
[ "$RC" -ne 0 ] && ok "a payload on project_rel is not armed" \
  || bad "project_rel payload refused" "rc=$RC out=$OUT"

install_in "$R42"
# Another repository, with this project's own layout inside it: it stands at
# the same place its checkout, so only the repository tells the two apart.
NOTOURS="$(new_repo checknotours)"
rebake "installed_scripts='$NOTOURS/.agents/skills/growth-guards/scripts'"
check_in "$R42"
[ "$RC" -ne 0 ] && ok "the same layout in another repository is not armed" \
  || bad "foreign repo scripts dir refused" "rc=$RC out=$OUT"

# The exclusion is that one value and nothing else: the program is still
# compared byte for byte, and so is every value this package bakes.
install_in "$R42"
perl -i -pe "s{^skill_roots='.*'\$}{skill_roots='.somewhere'}" "$HELPER42"
check_in "$R42"
[ "$RC" -eq 2 ] && ok "a changed skill_roots is still unverifiable" \
  || bad "changed roots unverifiable" "rc=$RC out=$OUT"

install_in "$R42"
perl -i -pe 's{^mode=.\$\{1-\}.$}{mode=pre-commit}' "$HELPER42"
check_in "$R42"
[ "$RC" -eq 2 ] && ok "and so is a changed line of the program itself" \
  || bad "changed program unverifiable" "rc=$RC out=$OUT"

install_in "$R42"
perl -i -ne "print unless /^installed_scripts='/" "$HELPER42"
check_in "$R42"
[ "$RC" -eq 2 ] && ok "a helper missing a baked line is unverifiable" \
  || bad "missing baked line unverifiable" "rc=$RC out=$OUT"

echo "=== two projects in one repository share one helper, and it licenses one ==="
# The helper is what says a session may run a checkout-supplied installer.
# One repository holds one helper, so a second project finding it would read
# it as consent it was never given and run its OWN lanes as this
# repository's gate. What tells them apart is project_rel.
R43="$(new_repo checktwoproj)"
mkdir -p "$R43/sub"
cp -R "$R43/.agents" "$R43/sub/.agents"
[ -x "$R43/sub/.agents/skills/growth-guards/scripts/install-git-hooks" ] \
  || bad "two-project fixture has B's own installer" "missing"
install_in "$R43"
[ "$RC" -eq 0 ] && ok "control: project A arms the repository" \
  || bad "two-project A armed" "rc=$RC out=$OUT"
check_in "$R43"
[ "$RC" -eq 0 ] && ok "control: and A reads its own helper as armed" \
  || bad "two-project A checks armed" "rc=$RC out=$OUT"
check_in "$R43/sub"
[ "$RC" -ne 0 ] && ok "project B does not read A's helper as its own consent" \
  || bad "two-project B refused" "rc=$RC out=$OUT"

echo "=== a checkout path carrying an apostrophe installs and checks ==="
# The value goes through the POSIX escape, so the check has to read that
# escape as the quoter writes it and not as some other tool's.
R44="$(new_repo "check o'brien")"
install_in "$R44"
[ "$RC" -eq 0 ] && ok "control: an apostrophe in the path installs" \
  || bad "apostrophe installs" "rc=$RC out=$OUT"
check_in "$R44"
[ "$RC" -eq 0 ] && ok "and the helper it wrote is recognized as armed" \
  || bad "apostrophe checks armed" "rc=$RC out=$OUT"

# The same directory, spelled with a bare apostrophe instead of the POSIX
# escape. The value reads back as the real scripts directory, so every test
# about WHERE it points passes; what refuses it is that the quoter would
# never have written the line, which is the shape a shell reads as an
# unterminated quote and a checker must not bless.
perl -i -pe "BEGIN { \$r = shift } s{^installed_scripts=.*\$}{\$r}" \
  "installed_scripts='$R44/.agents/skills/growth-guards/scripts'" \
  "$R44/.git/hooks/kendex-guards"
check_in "$R44"
[ "$RC" -ne 0 ] && ok "but a bare apostrophe where the escape belongs is not armed" \
  || bad "unescaped apostrophe refused" "rc=$RC out=$OUT"

echo "=== --check usage lanes ==="
OUT=""; RC=0; OUT="$("$INSTALL" --check --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && ok "--check with --uninstall is exit 2" || bad "check+uninstall is exit 2" "rc=$RC out=$OUT"
mkdir -p "$TMP/checknotgit"
OUT=""; RC=0; OUT="$("$INSTALL" --repo "$TMP/checknotgit" --check 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && ok "--check outside a git work tree is exit 2" || bad "check outside work tree" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
