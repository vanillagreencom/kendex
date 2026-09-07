#!/usr/bin/env bash
# Pins for scripts/install-git-hooks under BSD argv rules, as a program
# rather than a lint: commit-guards installs on macOS, where chmod and sed
# are BSD, and getopt(3) there stops at the first non-option argument, so a
# `--` after chmod's mode or after sed's script is a file operand nobody
# has. A lint over the shell source has no bottom (the same call can be
# spelled more ways than a regex enumerates), so the rule is put in two
# shims on PATH and the real installer runs under them. The merge-group
# macOS lane stays the platform proof; this is what a Linux run says on its
# own. Bash 4 syntax in the shipped scripts is `tools/bash32-lint`.
#
# One table: PACKAGE is the shipped skill or a copy with one wrong order
# restored; the installer runs with ARGS in a fresh repository, and the row
# pins the exit status with every line printed and the mode of each of the
# three hook files, so the installer's verdict and the bits git will read
# are one pin. Every row runs under both shims; a package that calls
# neither utility with a `--` operand never meets them.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
umask 022

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

# The BSD rules, as programs. chmod: options first, exactly as getopt(3)
# takes them; the first non-option is the mode and everything after it is a
# file operand, so a `--` there is a file named `--`. GNU permutes its
# arguments and accepts the same line. sed: the same rule with the script in
# the mode's place; BSD sed reports the `--` operand and exits 1 while still
# processing the real file, so a caller reading the exit status sees a
# failure over content it actually got.
shim="$TMP/shim"
mkdir -p "$shim"
cat >"$shim/chmod" <<'SHIM'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    -[RfhvHLP]*) shift ;;
    *) break ;;
  esac
done
mode="${1-}"
[ $# -gt 0 ] && shift
for arg in "$@"; do
  if [ "$arg" = "--" ]; then
    echo "chmod: --: No such file or directory" >&2
    exit 1
  fi
done
exec /bin/chmod "$mode" "$@"
SHIM
REAL_SED="$(command -v sed)"
cat >"$shim/sed" <<SHIM
#!/bin/sh
seen_script=0
for arg in "\$@"; do
  case "\$seen_script\$arg" in
    0-*) continue ;;
  esac
  if [ "\$seen_script" -eq 1 ] && [ "\$arg" = "--" ]; then
    echo "sed: --: No such file or directory" >&2
    exit 1
  fi
  seen_script=1
done
exec $REAL_SED "\$@"
SHIM
chmod 0755 "$shim/chmod" "$shim/sed"
mode() { if [ -e "$1" ]; then ls -ld "$1" | cut -c1-10; else echo absent; fi; } # PATH — the permission string, or absent
probe() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "rc=$rc"; } # CMD... — the exit status under the shims

echo "=== premise: each shim refuses only the shape BSD refuses, and hands the rest to the real utility ==="
: >"$TMP/probe-file"
printf 'a\nb\nc\n' >"$TMP/sed-probe"
PATH="$shim:$PATH"
assert_eq "chmod with -- after the mode is refused" "rc=1" "$(probe chmod +x -- "$TMP/probe-file")"
assert_eq "control: chmod with -- before the mode runs the real chmod and sets the bit" "rc=0 -rwxr-xr-x" "$(probe chmod -- +x "$TMP/probe-file") $(mode "$TMP/probe-file")"
assert_eq "sed with a -- operand after the script is refused" "rc=1" "$(probe sed -n '3p' -- "$TMP/sed-probe")"
assert_eq "control: sed over stdin runs the real sed" "c" "$(sed -n '3p' <"$TMP/sed-probe")"

# One line for a run: the exit status, every line printed with the
# repository path aliased (the installer prints it resolved, so a symlinked
# TMPDIR is aliased under both spellings), then the three hook files' modes.
R=""
run() { # ARGS...
  local rc=0 out="" real
  real="$(cd "$R" && pwd -P)"
  out="$("$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" "$@" 2>&1)" || rc=$?
  printf 'rc=%s%s modes=%s,%s,%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C sed "s#$real#<repo>#g; s#$R#<repo>#g" | LC_ALL=C paste -sd ';' -)}" \
    "$(mode "$R/.git/hooks/pre-commit")" "$(mode "$R/.git/hooks/commit-msg")" "$(mode "$R/.git/hooks/kendex-guards")"
}

# Fixture vocabulary: a fresh repository with the package copied in as a
# consumer has it, under one of three packagings.
repo() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R/.agents/skills"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  cp -R "$SKILL_DIR" "$R/.agents/skills/commit-guards"
}
INSTALLER=".agents/skills/commit-guards/scripts/install-git-hooks"
real() { repo "$1"; } # NAME — the shipped package
broken_chmod() { # NAME — the package with chmod's wrong order restored
  repo "$1"
  perl -pi -e 's/chmod -- \+x/chmod +x --/; s/chmod -- 0755/chmod 0755 --/' "$R/$INSTALLER"
}
broken_sed() { # NAME — the package reading a helper's line 3 with a -- operand
  repo "$1"
  perl -pi -e "s/sed -n '3p' <\"\\\$1\"/sed -n '3p' -- \"\\\$1\"/" "$R/$INSTALLER"
}
installed() { real "$1"; "$R/$INSTALLER" --repo "$R" >/dev/null 2>&1; } # NAME — the shipped package, already armed
dangling() { # NAME — a helper an install that no longer exists wrote; line 3 names its scripts directory
  printf '#!/bin/sh\n# Scripts directory of the install that wrote this file.\ninstalled_scripts=%s\n# kendex earlier-package git hooks. Managed by an earlier install.\nexit 0\n' \
    "'$TMP/install-that-moved/scripts'" >"$R/.git/hooks/kendex-guards"
}
dangling_real() { real "$1"; dangling; }
dangling_broken_sed() { broken_sed "$1"; dangling; }

echo "=== premise: each broken package holds exactly the shape it restores ==="
broken_chmod shape-chmod
assert_eq "the chmod control restores the wrong order at both call sites" "1 1" "$(grep -c 'chmod +x --' "$R/$INSTALLER") $(grep -c 'chmod 0755 --' "$R/$INSTALLER")"
broken_sed shape-sed
assert_eq "the sed control restores the -- operand at its one call site" "1" "$(grep -c "sed -n '3p' -- " "$R/$INSTALLER")"

run_rows() { # label | fixture | args | expect
  local row label fx args expect words
  for row in "$@"; do
    IFS='|' read -r label fx args expect <<<"$row"
    R=""
    read -ra words <<<"$fx"
    "${words[@]}"
    # shellcheck disable=SC2086
    assert_eq "$label" "$expect" "$(run $args)"
  done
}

echo "=== the installer under BSD chmod and sed: its verdict and the bits git reads are one pin ==="
X="-rwxr-xr-x"
ARMED="commit-guards git hooks: pre-commit and commit-msg armed in <repo>/.git/hooks"
NOT_INSTALLED="commit-guards git hooks: NOT installed — could not write <repo>/.git/hooks/kendex-guards"
run_rows \
  "the shipped package arms both hooks and the helper, every file executable|real install||rc=0 $ARMED modes=$X,$X,$X" \
  "--check reads the same repository as armed|installed check|--check|rc=0 commit-guards git hooks: armed — pre-commit and commit-msg gate commits in <repo>/.git/hooks modes=$X,$X,$X" \
  "control: chmod's wrong order writes nothing under BSD rules, and the installer says so|broken_chmod broken-install||rc=1 $NOT_INSTALLED modes=absent,absent,absent" \
  "control: --check over that repository reads it as not armed|broken_chmod broken-check|--check|rc=1 commit-guards git hooks: NOT armed — helper kendex-guards is missing; pre-commit is missing; commit-msg is missing (<repo>/.git/hooks); run 'kendex guard install' (or this installer) to re-arm modes=absent,absent,absent" \
  "a helper whose scripts directory is gone is recognised from its line 3 and replaced|dangling_real dangling||rc=0 ::warning::install-git-hooks: <repo>/.git/hooks/kendex-guards was written by an install whose scripts directory is gone; replacing it;$ARMED modes=$X,$X,$X" \
  "control: reading line 3 with a -- operand fails under BSD sed, so the helper reads as somebody else's and the install stops|dangling_broken_sed dangling-broken||rc=1 ::warning::install-git-hooks: <repo>/.git/hooks/kendex-guards exists but was not written by this installer; refusing to overwrite it;$NOT_INSTALLED modes=absent,absent,-rw-r--r--"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
