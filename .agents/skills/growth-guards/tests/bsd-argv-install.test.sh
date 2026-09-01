#!/usr/bin/env bash
# install-git-hooks under BSD argv rules, as a program rather than a lint.
#
# growth-guards installs on macOS, where the utilities are BSD, not GNU. That
# used to be a text scan for the shapes a BSD utility rejects, and it was
# wrong four times running: each spelling missed an argument form the next
# reviewer found, because a lint over shell source has no bottom — the same
# command can be written in more ways than a regex can enumerate.
#
# So it is not read any more, it is RUN. The BSD rule is put in a shim on
# PATH and the real installer executes under it, which cannot be evaded by
# spelling: whatever the scripts call chmod with, the shim judges it the way
# macOS would. The merge-group macOS lane stays the platform proof; this is
# what every Linux run can say on its own.
#
# Bash 4 syntax in the shipped scripts is `tools/bash32-lint`, run over every
# skill's scripts/ and tests/ at once.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
. "$TEST_DIR/lib/harness.bash"
# The BSD argv rule, as a program the installer actually runs.
#
# getopt(3) stops at the first non-option argument. For chmod that argument
# is the mode, so every token after it is a file operand — and a `--` there
# is a file named `--`, which does not exist. BSD chmod fails on it. GNU
# permutes its arguments and accepts the same line, which is why this can
# only be caught by judging the call rather than by reading the source.
shim="$TMP/shim"
mkdir -p "$shim"
cat >"$shim/chmod" <<'SHIM'
#!/bin/sh
# Options first, exactly as getopt(3) takes them.
while [ $# -gt 0 ]; do
  case "$1" in
    # `--` here ends option parsing: the mode follows. This is the one
    # correct shape, and it is passed straight through.
    --)
      shift
      break
      ;;
    -[RfhvHLP]*) shift ;;
    # Anything else is the mode, and option parsing is over.
    *) break ;;
  esac
done
# From here every argument is a file operand. A `--` among them is a file
# nobody has.
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
chmod 0755 "$shim/chmod"

# The shim has teeth, and only on the wrong shape.
: >"$TMP/probe-file"
if PATH="$shim:$PATH" chmod +x -- "$TMP/probe-file" 2>/dev/null; then
  echo "FAIL: the shim accepts a trailing --, so it judges nothing" >&2
  exit 1
fi
if ! PATH="$shim:$PATH" chmod -- +x "$TMP/probe-file" 2>/dev/null; then
  echo "FAIL: the shim rejects the correct order, so it would fail any installer" >&2
  exit 1
fi
[ -x "$TMP/probe-file" ] || {
  echo "FAIL: the shim did not exec the real chmod" >&2
  exit 1
}

# A repository, and the package installed into it the way a consumer has it.
repo="$TMP/bsd-repo"
mkdir -p "$repo/.agents/skills"
git -C "$repo" init -q
git -C "$repo" config user.email t@t
git -C "$repo" config user.name t
cp -R "$SCRIPTS_DIR/.." "$repo/.agents/skills/growth-guards"
installer="$repo/.agents/skills/growth-guards/scripts/install-git-hooks"

out=""
status=0
out="$(PATH="$shim:$PATH" "$installer" --repo "$repo" 2>&1)" || status=$?
if [ "$status" -ne 0 ]; then
  echo "FAIL: the install failed under BSD chmod argv rules (exit $status)" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

# git ignores a hook without the bit, so this is the assertion that matters:
# not that the installer said armed, but that the files it wrote can run.
for lane in pre-commit commit-msg kendex-guards; do
  [ -x "$repo/.git/hooks/$lane" ] || {
    echo "FAIL: $lane is not executable after an install under BSD chmod" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
done

# And the package's own verdict agrees, which is the pair that came apart on
# macOS: two hooks reported armed over a repository that gated nothing.
check=""
check_status=0
check="$(PATH="$shim:$PATH" "$installer" --repo "$repo" --check 2>&1)" || check_status=$?
if [ "$check_status" -ne 0 ]; then
  echo "FAIL: --check does not read the repository as armed (exit $check_status)" >&2
  printf '%s\n' "$check" >&2
  exit 1
fi

# The control: a copy of the package with the wrong order restored must NOT
# come out armed. Without this the pin passes on any installer, including one
# that never calls chmod at all.
broken="$TMP/broken"
mkdir -p "$broken/.agents/skills"
git -C "$broken" init -q
git -C "$broken" config user.email t@t
git -C "$broken" config user.name t
cp -R "$SCRIPTS_DIR/.." "$broken/.agents/skills/growth-guards"
broken_installer="$broken/.agents/skills/growth-guards/scripts/install-git-hooks"
perl -pi -e 's/chmod -- \+x/chmod +x --/; s/chmod -- 0755/chmod 0755 --/' "$broken_installer"
grep -q 'chmod +x --' "$broken_installer" || {
  echo "FAIL: the control could not restore the wrong order; the assertion below proves nothing" >&2
  exit 1
}
PATH="$shim:$PATH" "$broken_installer" --repo "$broken" >/dev/null 2>&1 || true
if [ -x "$broken/.git/hooks/pre-commit" ] && [ -x "$broken/.git/hooks/commit-msg" ]; then
  echo "FAIL: must-fail control armed under BSD chmod with the wrong argv order" >&2
  exit 1
fi

echo "pass: bsd-argv-install"
