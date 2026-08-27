#!/usr/bin/env bash
# core.hooksPath, in both modes: set at all is a stand-down. The install
# writes nothing into a directory git would not read, and `--check` verifies
# only the directory this package writes rather than grading a redirected
# one. The cost is pinned here as a cost — a hand-wired directory that
# really does gate is answered "could not determine", never "not armed".
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=lib/install-hooks.bash
. "$TEST_DIR/lib/install-hooks.bash"

echo "=== an empty core.hooksPath is hooks off, in this checker too ==="
# The third file this has come up in. Empty switches hooks off, and
# rev-parse reports ./ for it, so measuring that directory answers about the
# repository root — armed, if the root happens to hold the right shapes.
R62="$(new_repo hooks-off)"
install_in "$R62"
check_in "$R62"
[ "$RC" -eq 0 ] && ok "the control: armed before the value is set" \
  || bad "control not armed" "rc=$RC out=$OUT"
git -C "$R62" config core.hooksPath ""
cp "$R62/.git/hooks/kendex-guards" "$R62/kendex-guards"
cp "$R62/.git/hooks/pre-commit" "$R62/pre-commit"
cp "$R62/.git/hooks/commit-msg" "$R62/commit-msg"
check_in "$R62"
[ "$RC" -eq 1 ] && ok "an empty value reads NOT armed, not armed-at-the-root" \
  || bad "empty hooksPath verdict" "rc=$RC out=$OUT"
case "$OUT" in
  *"switches git hooks off"*) ok "and says what is actually wrong" ;;
  *) bad "the verdict does not name the cause" "$OUT" ;;
esac
case "$OUT" in
  *"--unset-all core.hooksPath"*) ok "and leads with the remedy that works" ;;
  *) bad "no unset in the remedy" "$OUT" ;;
esac
install_in "$R62"
case "$OUT" in
  *"switches git hooks off"*) ok "and install says the same rather than writing" ;;
  *) bad "install did not name the empty value" "$OUT" ;;
esac

echo "=== core.hooksPath set at all is a stand-down ==="
# Whether the configured directory is in fact this repository's own used to
# be worked out here — resolved on disk, `..` folded on paper, a relative
# value absolutized against the work tree. Every one of those was another
# way to be subtly wrong, and two of them were. Set is set: the installer
# writes nothing git might not read. It costs an arming; it never costs a
# repository that reads armed and gates nothing.
for spelling in default-relative default-absolute elsewhere empty; do
  R70="$(new_repo "set-$spelling")"
  case "$spelling" in
    default-relative) VALUE=".git/hooks" ;;
    default-absolute) VALUE="$R70/.git/hooks" ;;
    elsewhere) VALUE="$R70/otherhooks" ;;
    empty) VALUE="" ;;
  esac
  git -C "$R70" config core.hooksPath "$VALUE"
  install_in "$R70"
  [ -e "$R70/.git/hooks/kendex-guards" ] \
    && bad "installed under core.hooksPath ($spelling)" "out=$OUT" \
    || ok "core.hooksPath set stands the install down ($spelling)"
  # One remedy, and it is the one that arms. The recipe this used to print —
  # wire that directory's hooks to these scripts yourself — prescribed a
  # shape `--check` has no way to verify, so following it left a repository
  # permanently unable to say whether it was gated.
  case "$OUT" in
    *"To arm this repository, run git -C "*"--unset-all core.hooksPath"*)
      ok "and the remedy printed is the one that arms ($spelling)" ;;
    *) bad "no unset remedy ($spelling)" "$OUT" ;;
  esac
  case "$OUT" in
    *"Have that directory's pre-commit run"*)
      bad "a hand-wiring recipe is still prescribed ($spelling)" "$OUT" ;;
    *) ok "and no hand-wiring recipe ($spelling)" ;;
  esac
  case "$spelling" in
    empty) case "$OUT" in
      *"switches git hooks off"*) ok "and empty is told apart in the message" ;;
      *) bad "empty was not named" "$OUT" ;;
    esac ;;
  esac
done

# The must-fail control: with nothing set, the same repository arms.
R71="$(new_repo unset-arms)"
install_in "$R71"
[ -x "$R71/.git/hooks/kendex-guards" ] \
  && ok "must-fail: with core.hooksPath unset the install arms" \
  || bad "unset did not arm" "out=$OUT"

echo "=== --check stands down the same way the install does ==="
# What a redirected directory does is a question about somebody else's
# files, and answering it took a whole-file grammar over shell text —
# reachability, which no reader settles. Every construct nobody had thought
# of was another chance to report `armed` about a repository that gated
# nothing. So the checker answers what the installer answers: not this
# package's directory, not this package's verdict.
R80="$(new_repo checkstanddown)"
install_in "$R80"
check_in "$R80"
[ "$RC" -eq 0 ] && ok "the control: armed before any value is set" \
  || bad "control not armed" "rc=$RC out=$OUT"

# Wired exactly as the retired stand-down message prescribed, and really
# gating: this is the arming the change costs, so it is pinned as a cost.
wire_hooks_dir "$R80" "$R80/customhooks"
git -C "$R80" config core.hooksPath customhooks
check_in "$R80"
[ "$RC" -eq 2 ] && ok "a hand-wired core.hooksPath directory is 'could not determine'" \
  || bad "hand-wired redirect checks 2" "rc=$RC out=$OUT"
case "$OUT" in
  *armed*) bad "the stand-down claims a verdict either way" "$OUT" ;;
  *) ok "and it claims nothing about arming, in either direction" ;;
esac
case "$OUT" in
  *"core.hooksPath is set ('customhooks')"*) ok "and names the configured value" ;;
  *) bad "the value is not named" "$OUT" ;;
esac
# Where git was sent is not measured, so it is not claimed: the same value
# may name this repository's own hooks directory under another spelling.
case "$OUT" in
  *"sends git"* | *"redirect"*) bad "the verdict claims where git reads hooks from" "$OUT" ;;
  *) ok "and claims nothing about where git reads hooks from" ;;
esac
case "$OUT" in
  *"--unset-all core.hooksPath"*) ok "and carries the remedy that arms" ;;
  *) bad "no unset remedy" "$OUT" ;;
esac
case "$OUT" in
  *"wire that directory"* | *"Have that directory's pre-commit run"*)
    bad "a hand-wiring recipe is still prescribed" "$OUT" ;;
  *) ok "and prescribes no hand-wiring" ;;
esac

# The verdict is honest only because such a repository really can be gated —
# this one is, and the checker still declines to say so.
printf '# %s: finish this\n' "$TD" >"$R80/sd.py"
git -C "$R80" add sd.py
commit_in "$R80" "feat: add sd"
[ "$RC" -ne 0 ] && ok "and the wiring it will not judge really does gate" \
  || bad "hand-wired directory blocks" "rc=$RC out=$OUT"
git -C "$R80" rm -q --cached sd.py
rm -f "$R80/sd.py"

# The shims in .git/hooks are intact and git reads elsewhere. There is no
# `dormant` verdict any more: whether commits are gated over there is
# exactly the question this package stopped answering.
mkdir -p "$R80/barehooks"
git -C "$R80" config core.hooksPath barehooks
check_in "$R80"
[ "$RC" -eq 2 ] && ok "intact shims behind a redirect are 'could not determine' too" \
  || bad "dormant redirect checks 2" "rc=$RC out=$OUT"
case "$OUT" in
  *dormant*) bad "a redirect is still called dormant" "$OUT" ;;
  *) ok "and nothing is called dormant" ;;
esac

# A value naming the repository's own hooks directory is still a value. One
# rule beats a taxonomy of spellings — resolving them is what kept being
# subtly wrong.
git -C "$R80" config core.hooksPath .git/hooks
check_in "$R80"
[ "$RC" -eq 2 ] && ok "a value naming the default hooks directory stands down too" \
  || bad "default-spelling redirect checks 2" "rc=$RC out=$OUT"
# And this is the case that makes "git is sent away from .git/hooks" a false
# sentence: git reads hooks from exactly the directory this package writes.
case "$OUT" in
  *"away from"* | *"sends git"*) bad "the verdict claims git was sent elsewhere" "$OUT" ;;
  *) ok "and the verdict says nothing that this spelling makes false" ;;
esac

# The must-fail control: unsetting it arms the same repository again, so the
# pins above are not passing on a checker that answers 2 for everything.
git -C "$R80" config --unset core.hooksPath
check_in "$R80"
[ "$RC" -eq 0 ] && ok "must-fail: unsetting the value arms the same repository again" \
  || bad "unset re-arms" "rc=$RC out=$OUT"

echo "=== the remedy names the scope that actually holds the value ==="
# `git config --unset` writes the LOCAL file. Told that for a value set
# globally, the person runs it, git exits 5 because the local file has no
# such key, and the next install stands down for the reason they were told
# to fix. The scope git reports is the scope the remedy names.
R90="$(new_repo scoped-remedy)"
install_in "$R90"
git config --global core.hooksPath "$R90/globalhooks"
[ -z "$(git -C "$R90" config --local --get core.hooksPath || true)" ] \
  && ok "the control: the value is global only, with nothing local" \
  || bad "the fixture set a local value too" "$(git -C "$R90" config --local --get core.hooksPath || true)"

check_in "$R90"
[ "$RC" -eq 2 ] && ok "a global core.hooksPath stands the checker down" \
  || bad "global hooksPath checks 2" "rc=$RC out=$OUT"
case "$OUT" in
  *"config --global --unset-all core.hooksPath"*) ok "and the remedy unsets it in the global scope" ;;
  *) bad "the remedy does not name the global scope" "$OUT" ;;
esac
case "$OUT" in
  *"git -C '$R90' config --global"*) ok "and names the repository, so it works from anywhere" ;;
  *) bad "the remedy does not name the repository" "$OUT" ;;
esac

# The install lane derives it the same way, from the same one definition.
install_in "$R90"
case "$OUT" in
  *"config --global --unset-all core.hooksPath"*) ok "and the install prints the same scoped remedy" ;;
  *) bad "install printed an unscoped remedy" "$OUT" ;;
esac

# The remedy has to be a command that WORKS: run it, and the repository arms.
eval "git -C '$R90' config --global --unset-all core.hooksPath"
install_in "$R90"
[ -x "$R90/.git/hooks/kendex-guards" ] \
  && ok "and running that remedy really does let the install arm" \
  || bad "the printed remedy did not arm the repository" "out=$OUT"

# The must-fail control: the unscoped remedy this replaced — spelled exactly
# as it used to print — fails on the same repository, which is the defect the
# scope lookup exists for.
git config --global core.hooksPath "$R90/globalhooks"
UNSCOPED_RC=0
git -C "$R90" config --unset core.hooksPath 2>/dev/null || UNSCOPED_RC=$?
[ "$UNSCOPED_RC" -eq 5 ] \
  && ok "must-fail: the unscoped unset exits 5 against a global value" \
  || bad "unscoped unset against a global value" "rc=$UNSCOPED_RC"
git config --global --unset core.hooksPath

echo "=== a repository path that begins with a dash is a path ==="
# `cd "$REPO"` reads a leading dash as an option: `--repo -P` became `cd -P`,
# which succeeds in the WRONG directory rather than failing. `--` ends the
# option list, and a directory named `-P` is a directory somebody can make.
DASHED="$TMP/-P"
mkdir -p "$DASHED/.agents/skills"
git -C "$DASHED" init -q
git -C "$DASHED" config user.email t@t
git -C "$DASHED" config user.name t
cp -R "$SKILL_DIR" "$DASHED/.agents/skills/growth-guards"
OUT=""; RC=0
OUT="$(cd "$TMP" && "$DASHED/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "-P" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "an install under a dash-named repository succeeds" \
  || bad "dash-named repo install" "rc=$RC out=$OUT"
[ -x "$DASHED/.git/hooks/kendex-guards" ] \
  && ok "and the shims land in that repository, not the caller's directory" \
  || bad "shims did not land in the dash-named repo" "out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
