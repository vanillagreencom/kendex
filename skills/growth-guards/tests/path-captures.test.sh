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
# The `$(` the producers follow, spelled once: the scan below is the only
# reader of it.
PATTERN='\$\('"($PRODUCERS)"

# One scan, run over whatever directory it is given: the package's scripts,
# and the planted probe below. Two spellings of the detector would be two
# things to keep in step, and the control's whole job is to prove that THIS
# detector reports what it finds.
#
# grep's status is part of the answer — 0 found something, 1 found nothing,
# anything above that is a scan that did not run. `|| true` swallowed the
# third case, so an unreadable directory or a broken pattern reported a clean
# tree: the exact fail-open this file exists to refuse.
SCAN_FOUND=""
SCAN_WHY=""
scan() { # DIR -> 0 scanned (SCAN_FOUND holds the hits), 2 could not scan
  local dir="$1" raw="$TMP/scan-hits" status=0
  local hit="" file="" rest="" line="" from=0
  SCAN_FOUND=""
  SCAN_WHY=""
  grep -rnE "$PATTERN" "$dir" >"$raw" 2>"$raw.err" || status=$?
  if [ "$status" -gt 1 ]; then
    SCAN_WHY="$(head -1 "$raw.err" 2>/dev/null)"
    return 2
  fi
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
    SCAN_FOUND="$SCAN_FOUND$hit
"
  done <"$raw"
  return 0
}

echo "=== every path capture carries the sentinel ==="
STATUS=0
scan "$SCRIPTS" || STATUS=$?
if [ "$STATUS" != "0" ]; then
  bad "the scan over the package's scripts could not run" "grep status $STATUS: $SCAN_WHY"
elif [ -z "$SCAN_FOUND" ]; then
  ok "no unguarded path capture in the package's scripts"
else
  bad "a path capture without the sentinel idiom" "$(printf '%s' "$SCAN_FOUND" | head -5)"
fi

# The control: the check has to be able to see one. A capture planted in a
# scratch copy of the tree must be found — through the same scan, not a
# separate grep, because what can pass by looking at nothing is the FILTER
# below the grep, and a bare grep never reaches it.
echo "=== the check finds one when there is one ==="
PROBE="$TMP/probe"
mkdir -p "$PROBE"
printf '%s\n' 'root="$(git -C "$PWD" rev-parse --show-toplevel)"' >"$PROBE/planted.sh"
STATUS=0
scan "$PROBE" || STATUS=$?
if [ "$STATUS" != "0" ]; then
  bad "the scan over the probe could not run" "grep status $STATUS: $SCAN_WHY"
elif [ -n "$SCAN_FOUND" ]; then
  ok "must-fail: a planted capture is reported by the same detector"
else
  bad "the detector reports nothing" "the rule above proves nothing"
fi

# And a scan that could not run is not a clean tree. Without the status
# check, an unreadable directory reads exactly like a package with no
# unguarded capture in it.
echo "=== a scan that could not run is not a pass ==="
BLIND="$TMP/blind"
mkdir -p "$BLIND/sub"
printf '%s\n' 'root="$(git -C "$PWD" rev-parse --show-toplevel)"' >"$BLIND/sub/planted.sh"
chmod 000 "$BLIND/sub"
STATUS=0
scan "$BLIND" || STATUS=$?
chmod 755 "$BLIND/sub"
if [ "$(id -u)" = "0" ]; then
  ok "skipped as root, where the mode bits do not apply"
elif [ "$STATUS" = "2" ]; then
  ok "must-fail: an unreadable directory is a refusal, not a clean tree"
else
  bad "a scan that could not run reported success" "status=$STATUS"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
