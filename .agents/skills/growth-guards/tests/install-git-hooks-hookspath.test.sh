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
  *"core.hooksPath is set."*) ok "and states that the value is set" ;;
  *) bad "no stand-down statement" "$OUT" ;;
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
    *"core.hooksPath is set."*"Clear the setting at its source, then run kendex guard install."*)
      ok "and it states the setting, then says to clear it at its source ($spelling)" ;;
    *) bad "no stand-down text ($spelling)" "$OUT" ;;
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
  *"core.hooksPath is set (customhooks)"*) ok "and names the configured value" ;;
  *) bad "the value is not named" "$OUT" ;;
esac
# Where git was sent is not measured, so it is not claimed: the same value
# may name this repository's own hooks directory under another spelling.
case "$OUT" in
  *"sends git"* | *"redirect"*) bad "the verdict claims where git reads hooks from" "$OUT" ;;
  *) ok "and claims nothing about where git reads hooks from" ;;
esac
case "$OUT" in
  *"core.hooksPath is set."*) ok "and states that the value is set" ;;
  *) bad "no stand-down statement" "$OUT" ;;
esac
# Recovery output is data, never a command line to paste
# (docs/ARCHITECTURE.md). Every earlier shape of this remedy was a command
# this file composed, and every one of them was wrong about somebody's
# configuration.
case "$OUT" in
  *"config --unset"* | *"--unset-all"* | *"git -C"*)
    bad "a pasteable command came back in the stand-down" "$OUT" ;;
  *) ok "and offers no command to paste" ;;
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

echo "=== the stand-down is a statement, git's report, and one sentence ==="
# docs/ARCHITECTURE.md: recovery output presents its parameters as data,
# never a command line to paste. Three earlier shapes of this remedy each
# composed a command and each was wrong about a configuration nobody here
# can see. What is printed now is git's own report, unedited, and a sentence
# naming no path and no command.
R90="$(new_repo origin-listing)"
install_in "$R90"
git config --global core.hooksPath "$R90/globalhooks"
[ -z "$(git -C "$R90" config --local --get core.hooksPath || true)" ] \
  && ok "the control: the value is global only, with nothing local" \
  || bad "the fixture set a local value too" "$(git -C "$R90" config --local --get core.hooksPath || true)"

check_in "$R90"
[ "$RC" -eq 2 ] && ok "a global core.hooksPath stands the checker down" \
  || bad "global hooksPath checks 2" "rc=$RC out=$OUT"
case "$OUT" in
  *"core.hooksPath is set."*) ok "and states that the value is set" ;;
  *) bad "no stand-down statement" "$OUT" ;;
esac
# git's own words, unedited: the scope and the origin as git spells them.
case "$OUT" in
  *global*"$HOME/.gitconfig"*) ok "and git's report of the origin reaches the reader as git wrote it" ;;
  *) bad "git's report is not there" "$OUT" ;;
esac
case "$OUT" in
  *"Clear the setting at its source, then run kendex guard install."*)
    ok "and closes with one sentence naming no path and no command" ;;
  *) bad "the closing sentence is missing" "$OUT" ;;
esac
# The rule, as a pin: nothing pasteable, and no path of this file's own.
case "$OUT" in
  *"config --unset"* | *"--unset-all"* | *"git -C"*)
    bad "a pasteable command came back" "$OUT" ;;
  *) ok "and offers no command to paste" ;;
esac

# The install lane prints the same block, from the same function.
install_in "$R90"
case "$OUT" in
  *"core.hooksPath is set."*"Clear the setting at its source, then run kendex guard install."*)
    ok "and the install lane prints the same block" ;;
  *) bad "install printed something else" "$OUT" ;;
esac
git config --global --unset-all core.hooksPath

echo "=== an included file is reported as git reports it ==="
# The case that makes a composed unset wrong even with the scope right:
# include.path pulls the key in from another file, and git names that file
# under the INCLUDING scope. Nothing here has to know that — git says it.
R91="$(new_repo included-origin)"
install_in "$R91"
printf '[core]\n\thooksPath = %s/includedhooks\n' "$R91" >"$R91/extra.cfg"
git -C "$R91" config include.path "$R91/extra.cfg"
[ "$(git -C "$R91" config --get core.hooksPath)" = "$R91/includedhooks" ] \
  && ok "the control: the value really does come from the included file" \
  || bad "the include did not supply the value" "$(git -C "$R91" config --get core.hooksPath || true)"

check_in "$R91"
[ "$RC" -eq 2 ] && ok "an included core.hooksPath stands the checker down" \
  || bad "included hooksPath checks 2" "rc=$RC out=$OUT"
case "$OUT" in
  *"$R91/extra.cfg"*) ok "and git's report names the included file itself" ;;
  *) bad "the included file is not named" "$OUT" ;;
esac
# The must-fail control for the whole design: unsetting only what the scope
# names leaves the value in force, which is why no scoped command is offered.
git -C "$R91" config --local --unset-all core.hooksPath 2>/dev/null || true
[ "$(git -C "$R91" config --get core.hooksPath || true)" = "$R91/includedhooks" ] \
  && ok "must-fail: a scoped local unset leaves the included value in force" \
  || bad "the scoped unset cleared the included value" "$(git -C "$R91" config --get core.hooksPath || true)"

echo "=== an origin that is not a file is reported as that ==="
# git answers `command line:` for a value carried in the environment or on
# the command line. There is no file to clear and nothing here claims there
# is: git's word for it goes through unedited.
R92="$(new_repo command-origin)"
install_in "$R92"
OUT=""; RC=0
OUT="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$R92/envhooks" \
  "$R92/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R92" --check 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && ok "a command-line core.hooksPath stands the checker down" \
  || bad "command-line hooksPath checks 2" "rc=$RC out=$OUT"
case "$OUT" in
  *"command line:"*) ok "and git's report says command line, not a file" ;;
  *) bad "the command-line origin is not reported" "$OUT" ;;
esac
case "$OUT" in
  *file:*) bad "an origin that is not a file was reported as one" "$OUT" ;;
  *) ok "and nothing calls that origin a file" ;;
esac

echo "=== a report git will not produce is said to be missing ==="
# The verdict does not depend on the listing: a git that cannot produce it
# still stands the checker down, and the text says the origin is missing
# rather than inventing one.
R93="$(new_repo origin-unlistable)"
install_in "$R93"
git -C "$R93" config core.hooksPath "$R93/somehooks"
mkdir -p "$TMP/gitshim"
REAL_GIT="$(command -v git)"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "--show-origin" ] && exit 1; done\nexec %s "$@"\n' "$REAL_GIT" >"$TMP/gitshim/git"
chmod +x "$TMP/gitshim/git"
OUT=""; RC=0
OUT="$(PATH="$TMP/gitshim:$PATH" "$R93/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R93" --check 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && ok "the verdict is unchanged when the origin cannot be listed" \
  || bad "unlistable origin changed the verdict" "rc=$RC out=$OUT"
case "$OUT" in
  *"Its origin could not be listed."*) ok "and it says the origin could not be listed" ;;
  *) bad "the missing listing is not stated" "$OUT" ;;
esac
case "$OUT" in
  *"Clear the setting at its source, then run kendex guard install."*)
    ok "and still closes with the same sentence" ;;
  *) bad "the closing sentence is missing" "$OUT" ;;
esac
# The must-fail control: the same shim with a working --show-origin reports
# an origin, so the case above is the shim's refusal and not a dead branch.
OUT=""; RC=0
OUT="$("$R93/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R93" --check 2>&1)" || RC=$?
case "$OUT" in
  *"Its origin could not be listed."*) bad "must-fail: a working git still reported no origin" "$OUT" ;;
  *file:*) ok "must-fail: the same repository with a working git reports an origin" ;;
  *) bad "no origin from a working git" "$OUT" ;;
esac

echo "=== the configured value reaches the reader escaped, on one line ==="
# The value is bytes git handed back, and the summary and the origin listing
# both repeat them. It arrives from a cloned repository's own config, so an
# ESC in it is somebody else's data reaching a screen as control codes, and a
# newline in it ends the one line --check promises before the verdict is on
# it. One case per boundary; gg_shown is what both lanes render through.
R95="$(new_repo escaped-value)"
install_in "$R95"
ESC="$(printf '\033')"
git -C "$R95" config core.hooksPath "ev${ESC}[31mil"
[ "$(git -C "$R95" config --get core.hooksPath)" = "ev${ESC}[31mil" ] \
  && ok "the control: the configured value really does carry an ESC byte" \
  || bad "the fixture value has no ESC" "$(git -C "$R95" config --get core.hooksPath || true)"
check_in "$R95"
[ "$RC" -eq 2 ] && ok "an ESC-valued hooks path stands the checker down" \
  || bad "ESC-valued hooks path checks 2" "rc=$RC out=$OUT"
case "$OUT" in
  *"$ESC"*) bad "a raw ESC byte reached the output" "$(printf '%s' "$OUT" | cat -v)" ;;
  *) ok "and no raw ESC byte reaches the reader" ;;
esac
# Escaped, not dropped: a value the reader cannot see is a value they cannot
# clear, and clearing it is the whole remedy.
case "$OUT" in
  *'31mil'*) ok "and the value is still named, escaped rather than removed" ;;
  *) bad "the value went missing instead of being escaped" "$(printf '%s' "$OUT" | cat -v)" ;;
esac

R94="$(new_repo newline-value)"
install_in "$R94"
git -C "$R94" config core.hooksPath "$(printf 'two\nlines')"
[ "$(git -C "$R94" config --get core.hooksPath | wc -l)" -eq 2 ] \
  && ok "the control: the configured value really does carry a newline" \
  || bad "the fixture value has no newline" "$(git -C "$R94" config --get core.hooksPath || true)"
# stdout alone, because one line on stdout is the promise being measured.
SUMMARY=""; RC=0
SUMMARY="$("$R94/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R94" --check 2>/dev/null)" || RC=$?
[ "$RC" -eq 2 ] && ok "a newline-valued hooks path stands the checker down" \
  || bad "newline-valued hooks path checks 2" "rc=$RC out=$SUMMARY"
[ "$(printf '%s' "$SUMMARY" | wc -l)" -eq 0 ] \
  && ok "and the summary is still exactly one line" \
  || bad "the summary broke into several lines" "$SUMMARY"
case "$SUMMARY" in
  *"could not determine"*) ok "and that one line still carries the whole verdict" ;;
  *) bad "the verdict did not survive on the first line" "$SUMMARY" ;;
esac

echo "=== the repository's own path cannot break the summary either ==="
# The value was escaped first; the hooks directory is the same class of
# bytes and reaches the same one-line summary. A repository whose path
# carries a newline ends that line early, and one carrying ESC hands the
# terminal control codes — from the name of the directory being reported.
# $'\n' rather than a capture: $(...) strips the newline, which would leave
# this fixture testing an ordinary path — the very class being pinned.
NL=$'\n'
ESCB=$'\033'
WILD="$TMP/re${NL}po${ESCB}x"
mkdir -p "$WILD/.agents/skills"
git -C "$WILD" -c init.defaultBranch=main init -q
git -C "$WILD" config user.email test@example.com
git -C "$WILD" config user.name test
cp -R "$SKILL_DIR" "$WILD/.agents/skills/growth-guards"
ln -s "$SKILL_DIR/../size-ratchet" "$WILD/.agents/skills/size-ratchet"
[ -d "$WILD/.git" ] && ok "the control: a repository really does live at a newline-and-ESC path" \
  || bad "the wild-path repository was not created" ""

SUMMARY=""; RC=0
SUMMARY="$("$WILD/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$WILD" 2>/dev/null)" || RC=$?
[ "$RC" -eq 0 ] && ok "an install under that path succeeds" \
  || bad "install under a wild path" "rc=$RC out=$SUMMARY"
[ "$(printf '%s' "$SUMMARY" | wc -l)" -eq 0 ] \
  && ok "and its summary is one line, though the path it names is two" \
  || bad "the install summary broke into several lines" "$(printf '%s' "$SUMMARY" | cat -v)"

# The armed verdict names the hooks directory, so it carries the path too.
SUMMARY=""; RC=0
SUMMARY="$("$WILD/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$WILD" --check 2>/dev/null)" || RC=$?
[ "$RC" -eq 0 ] && ok "the check reports it armed" || bad "wild-path check armed" "rc=$RC out=$SUMMARY"
[ "$(printf '%s' "$SUMMARY" | wc -l)" -eq 0 ] \
  && ok "and that verdict is one line as well" \
  || bad "the armed verdict broke into several lines" "$(printf '%s' "$SUMMARY" | cat -v)"
case "$SUMMARY" in
  *"$ESCB"*) bad "a raw ESC byte from the repository path reached the summary" "$(printf '%s' "$SUMMARY" | cat -v)" ;;
  *) ok "and no raw ESC byte from the path reaches the reader" ;;
esac

# The drifted lane folds its reasons into that same line, and those name the
# directory as well.
rm -f "$WILD/.git/hooks/pre-commit"
SUMMARY=""; RC=0
SUMMARY="$("$WILD/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$WILD" --check 2>/dev/null)" || RC=$?
[ "$RC" -eq 1 ] && ok "a drifted install under that path checks 1" \
  || bad "wild-path drift checks 1" "rc=$RC out=$SUMMARY"
[ "$(printf '%s' "$SUMMARY" | wc -l)" -eq 0 ] \
  && ok "and the drift verdict is one line too" \
  || bad "the drift verdict broke into several lines" "$(printf '%s' "$SUMMARY" | cat -v)"
case "$SUMMARY" in
  *"pre-commit is missing"*) ok "and it still says what drifted" ;;
  *) bad "the reason did not survive on the line" "$(printf '%s' "$SUMMARY" | cat -v)" ;;
esac

# The must-fail control: the path really does span two lines, so the pins
# above are not passing on a directory name with nothing to lose.
[ "$(printf '%s' "$WILD" | wc -l)" -eq 1 ] \
  && ok "must-fail: the repository path itself spans two lines" \
  || bad "the wild path is one line after all" "$(printf '%s' "$WILD" | cat -v)"

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
