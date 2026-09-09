# shellcheck shell=bash
# The private API shim refuses invalid fixture cursors before behavior cases
# rely on it. These checks establish fixture integrity, not gate coverage.
shimcheck="$work/shimcheck"
mkdir -p "$shimcheck" || exit 1
while IFS='|' read -r cursor expected; do
  rc=0
  GH_SHIM_FIXTURES="$shimcheck" "$shim/gh" api graphql -f query=q -f "after=$cursor" >/dev/null 2>&1 || rc=$?
  if [ "$rc" != "$expected" ]; then
    rg_message error selftest-fixture-cursor "$cursor" "Fixture cursor returned $rc; expected $expected." >&2
    exit 1
  fi
done <<'CASES'
bad/value|92
|92
C9|93
CASES
