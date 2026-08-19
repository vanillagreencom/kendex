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
