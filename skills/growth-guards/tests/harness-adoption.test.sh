#!/usr/bin/env bash
# Pins what a tenth suite must not be able to forget: no suite may run git
# against a fixture while inheriting the caller's configuration, and the
# shared harness must stay outside the tests/*.sh glob that runners execute.
# Each pin is paired with the control that proves it can fail.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/lib/harness.bash"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

# A suite is neutralized either by sourcing the harness or, like
# install-git-hooks, by exporting the isolation itself.
neutralized() { # FILE
  grep -q 'lib/harness\.bash' "$1" || grep -q 'GIT_CONFIG_NOSYSTEM' "$1"
}

echo "=== every suite is isolated from the caller's git configuration ==="
seen=0
for f in "$TEST_DIR"/*.test.sh; do
  [ -f "$f" ] || continue
  seen=$((seen + 1))
  if neutralized "$f"; then
    ok "${f##*/} does not inherit the caller's git configuration"
  else
    bad "${f##*/} does not inherit the caller's git configuration" \
      "neither sources lib/harness.bash nor exports GIT_CONFIG_NOSYSTEM"
  fi
done
[ "$seen" -gt 1 ] && ok "the scan found the suite directory" \
  || bad "the scan found the suite directory" "only $seen file(s) matched"

printf '#!/usr/bin/env bash\ngit init -q fixture\n' >"$TMP/forgot.test.sh"
neutralized "$TMP/forgot.test.sh" \
  && bad "control: a suite that neutralizes nothing is rejected" "the predicate accepted it" \
  || ok "control: a suite that neutralizes nothing is rejected"

echo "=== the harness neutralizes configuration carried in the ENVIRONMENT ==="
# A private HOME and GIT_CONFIG_NOSYSTEM do not stop these: git reads
# configuration out of the environment too, and exports GIT_CONFIG_PARAMETERS
# into every hook whenever the caller used `git -c`.
HARNESS="$TEST_DIR/lib/harness.bash"
hostile_hooks="$TMP/hostilehooks"
mkdir -p "$hostile_hooks"
printf '#!/bin/sh\necho HOSTILE-HOOK-RAN >&2\nexit 1\n' >"$hostile_hooks/pre-commit"
chmod +x "$hostile_hooks/pre-commit"

commit_under() { # ENVNAME=VALUE... — runs a fixture commit with the harness on
  env "$@" bash -c '
    set -euo pipefail
    . "$1"
    cd "$TMP"
    git init -q -b main fixture
    cd fixture
    git config user.email t@t
    git config user.name t
    echo x >a.txt
    git add a.txt
    git commit -qm probe
  ' _ "$HARNESS" 2>&1
}

for shape in "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hostile_hooks" \
             "GIT_CONFIG_PARAMETERS='core.hooksPath=$hostile_hooks'"; do
  name="${shape%%=*}"
  # shellcheck disable=SC2086
  OUT="$(commit_under $shape)" && RC=0 || RC=$?
  [ "$RC" -eq 0 ] && ok "$name from the caller does not reach a fixture commit" \
    || bad "$name from the caller does not reach a fixture commit" "rc=$RC out=$OUT"
  case "$OUT" in
    *HOSTILE-HOOK-RAN*) bad "$name does not run a foreign hook" "out=$OUT" ;;
    *) ok "$name does not run a foreign hook" ;;
  esac
done

# Control: the same injection with the harness NOT sourced really does fire,
# so the assertions above are measuring the scrub and not a broken fixture.
CTL="$(env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath \
  GIT_CONFIG_VALUE_0="$hostile_hooks" HOME="$TMP/ctlhome" bash -c '
    set -uo pipefail
    mkdir -p "$HOME" "$1/ctl"
    cd "$1/ctl"
    git init -q -b main .
    git config user.email t@t
    git config user.name t
    echo x >a.txt
    git add a.txt
    git commit -qm probe
  ' _ "$TMP" 2>&1)" || true
case "$CTL" in
  *HOSTILE-HOOK-RAN*) ok "control: without the scrub the same injection does fire" ;;
  *) bad "control: without the scrub the same injection does fire" "out=$CTL" ;;
esac

echo "=== the shared harness stays out of the runner glob ==="
stray=""
for f in "$TEST_DIR"/lib/*.sh; do
  [ -f "$f" ] && stray="$stray ${f##*/}"
done
[ -z "$stray" ] && ok "no .sh file under tests/lib — runners glob tests/*.sh" \
  || bad "no .sh file under tests/lib" "runners would execute:$stray"
[ -f "$TEST_DIR/lib/harness.bash" ] && ok "control: the harness is where suites source it from" \
  || bad "control: the harness is where suites source it from" "$TEST_DIR/lib/harness.bash is missing"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
