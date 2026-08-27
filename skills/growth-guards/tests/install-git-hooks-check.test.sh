#!/usr/bin/env bash
# `--check` over the shims this installer writes: armed, drifted, absent,
# dormant behind core.hooksPath, or unverifiable — and never a silent pass.
# It writes nothing, and install refuses to overwrite what it could not
# vouch for. Hand-wired core.hooksPath directories are the -hookspath suite.
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

echo "=== install corrects a stale shebang in a hook IT wrote ==="
# Older versions of this installer emitted `#!/usr/bin/env bash`. Refusing
# there strands a working install reporting NOT installed forever, so a file
# carrying the created-marker is corrected rather than refused.
R44="$(new_repo installstaleshebang)"
install_in "$R44"
# Exactly the drovr shape: the file this installer wrote, with only its
# shebang reverted to what an older version emitted.
{
  printf '#!/usr/bin/env bash\n'
  tail -n +2 "$R44/.git/hooks/pre-commit"
} >"$TMP/stale" && mv "$TMP/stale" "$R44/.git/hooks/pre-commit"
chmod +x "$R44/.git/hooks/pre-commit"
grep -qF -- "kendex_gg_h" "$R44/.git/hooks/pre-commit" \
  && ok "the fixture really carries the guard line under the stale shebang" \
  || bad "stale fixture carries the guard line" "$(sed -n '2p' "$R44/.git/hooks/pre-commit")"
check_in "$R44"
[ "$RC" -eq 2 ] && ok "and it reads as unverifiable before the fix" \
  || bad "stale fixture unverifiable first" "rc=$RC out=$OUT"
install_in "$R44"
[ "$(head -n 1 "$R44/.git/hooks/pre-commit")" = "#!/bin/sh" ] \
  && ok "a hook this installer wrote has its stale shebang corrected" \
  || bad "stale shebang corrected" "line1=$(head -n 1 "$R44/.git/hooks/pre-commit")"
check_in "$R44"
[ "$RC" -eq 0 ] && ok "and it checks armed afterwards" \
  || bad "corrected hook checks armed" "rc=$RC out=$OUT"

# Control: a hook the CONSUMER wrote is still refused and left untouched.
printf '#!/usr/bin/env bash\necho mine\n' >"$R44/.git/hooks/commit-msg"
chmod +x "$R44/.git/hooks/commit-msg"
install_in "$R44"
[ "$(sed -n '2p' "$R44/.git/hooks/commit-msg")" = "echo mine" ] \
  && ok "control: a consumer's own hook is refused, not rewritten" \
  || bad "consumer hook untouched" "line2=$(sed -n '2p' "$R44/.git/hooks/commit-msg")"
[ "$(head -n 1 "$R44/.git/hooks/commit-msg")" = "#!/usr/bin/env bash" ] \
  && ok "and its shebang is left alone" \
  || bad "consumer shebang untouched" "line1=$(head -n 1 "$R44/.git/hooks/commit-msg")"

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
