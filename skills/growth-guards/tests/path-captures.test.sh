#!/usr/bin/env bash
# Every command substitution that produces a PATH uses the sentinel idiom.
#
# Three rounds of review found this one site at a time: `$(...)` strips
# trailing newlines, a directory name may end in one, and the truncated path
# names a directory that is not there. Each time, the sites left behind were
# the ones nobody had thought to look at — and each time the reasoning for
# why the rest were safe turned out to be about the code as it was that day.
#
# So the rule is checked rather than remembered. A capture either carries the
# sentinel (`printf x`, the idiom in lib/paths.sh), or delegates to something
# that does (`gg_path`, `gg_git_path`), or is marked `# not-a-path:` with the
# reason it produces something other than a filename. Anything else fails
# here, before it can fail in somebody's repository.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
SCRIPTS="$(cd -- "$TEST_DIR/../scripts" && pwd)"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

# The commands whose output is a filename. `--is-inside-work-tree` answers a
# word rather than a path and is the one rev-parse flag excluded by name.
PRODUCERS='git [^)]*rev-parse (--git-dir|--git-common-dir|--show-toplevel|--git-path)'
PRODUCERS="$PRODUCERS"'|git [^)]*config --get core\.hooksPath'
PRODUCERS="$PRODUCERS"'|cd --? |pwd|dirname |cat -- '

echo "=== every path capture carries the sentinel ==="
found=""
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  # The idiom itself, a delegation, or a stated exemption on the line above.
  case "$hit" in
    *'printf x'*) continue ;;
  esac
  file="${hit%%:*}"
  rest="${hit#*:}"
  line="${rest%%:*}"
  # The exemption sits in the comment block above, which may be several
  # lines: a reason worth stating is rarely one line long.
  from=$((line - 4))
  [ "$from" -ge 1 ] || from=1
  if [ "$line" -gt 1 ] \
    && sed -n "${from},$((line - 1))p" "$file" | grep -q 'not-a-path:'; then
    continue
  fi
  # A comment describing the rule is not a use of it.
  case "$rest" in
    *:[[:space:]]#*) continue ;;
  esac
  found="$found$hit
"
done <<EOF
$(grep -rnE "\\\$\\(($PRODUCERS)" "$SCRIPTS" || true)
EOF

if [ -z "$found" ]; then
  ok "no unguarded path capture in the package's scripts"
else
  bad "a path capture without the sentinel idiom" "$(printf '%s' "$found" | head -5)"
fi

# The control: the check has to be able to see one. A capture planted in a
# scratch copy of the tree must be found, or this file passes by looking at
# nothing.
echo "=== the check finds one when there is one ==="
PROBE="$TMP/probe"
mkdir -p "$PROBE"
printf '%s\n' 'root="$(git -C "$PWD" rev-parse --show-toplevel)"' >"$PROBE/planted.sh"
if grep -rnE "\\\$\\(($PRODUCERS)" "$PROBE" >/dev/null 2>&1; then
  ok "must-fail: a planted capture is detected"
else
  bad "the detector matches nothing" "the rule above proves nothing"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
