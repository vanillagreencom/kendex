#!/usr/bin/env bash
# Parity guard for CANONICAL_TAGS between bash daemon and TS daemon.
#
# The daemon's stable-wake allowlist must match exactly between
# `scripts/flightdeck-daemon.bash` and
# `lib/flightdeck-core/src/daemon/events.ts`. If a new classifier tag is
# added to prompt-classify and only registered on one side, the daemon
# silently records the hash as notified and never wakes master — the
# tag is delivered to no handler. This script extracts both lists and
# fails on any asymmetric diff.
#
# Also asserts that the issue #18 cleanup-scope defensive tags are
# present on BOTH sides, so a future refactor cannot silently drop them.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
BASH_SRC="$SKILL_DIR/scripts/flightdeck-daemon.bash"
TS_SRC="$SKILL_DIR/lib/flightdeck-core/src/daemon/events.ts"
TS_BG_TASK_SRC="$SKILL_DIR/lib/flightdeck-core/src/events/bg-task-exit.ts"

PASS=0; FAIL=0
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then PASS=$((PASS+1)); printf '  ok    %s\n' "$name"
  else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

extract_bash_tags() {
  # Pull the lines between the `CANONICAL_TAGS=(` opening and the
  # matching `)` (the first one at column 0). Strip whitespace and
  # trailing comments. One tag per line, sorted.
  awk '
    /^CANONICAL_TAGS=\(/ { inside=1; next }
    inside && /^\)/      { inside=0; next }
    inside {
      gsub(/#.*/, "");          # drop trailing comments
      gsub(/^[[:space:]]+/, ""); # strip leading WS
      gsub(/[[:space:]]+$/, ""); # strip trailing WS
      if (length($0) > 0) print $0
    }
  ' "$BASH_SRC" | sort -u
}

extract_ts_tags() {
  # Pull the lines between `new Set<string>([` and `])`, strip quotes
  # and commas, drop blank lines and comments. Tags only. Also resolve
  # the shared BG_TASK_EXIT_CLASSIFIER_TAG constant when the allowlist uses
  # it instead of duplicating the literal string.
  awk '
    /new Set<string>\(\[/ { inside=1; next }
    inside && /^]\);/     { inside=0; next }
    inside {
      sub(/\/\/.*/, "");           # drop trailing line comment
      gsub(/^[[:space:]]+/, "");
      gsub(/[[:space:]]+$/, "");
      if (substr($0, 1, 1) == "\"") {
        # "tag",
        gsub(/^"/, ""); gsub(/",$/, ""); gsub(/"$/, "");
        print $0
      } else if ($0 == "BG_TASK_EXIT_CLASSIFIER_TAG,") {
        print "__BG_TASK_EXIT_CLASSIFIER_TAG__"
      }
    }
  ' "$TS_SRC" | while IFS= read -r tag; do
    if [[ "$tag" == "__BG_TASK_EXIT_CLASSIFIER_TAG__" ]]; then
      awk -F'"' '/export const BG_TASK_EXIT_CLASSIFIER_TAG/ { print $2; exit }' "$TS_BG_TASK_SRC"
    else
      printf '%s\n' "$tag"
    fi
  done | sort -u
}

BASH_TAGS=$(extract_bash_tags)
TS_TAGS=$(extract_ts_tags)

echo "=== canonical-tags parity ==="

bash_count=$(printf '%s\n' "$BASH_TAGS" | wc -l)
ts_count=$(printf '%s\n' "$TS_TAGS"   | wc -l)
assert_eq "$bash_count" "$ts_count" "tag count matches ($bash_count == $ts_count)"

only_bash=$(comm -23 <(printf '%s\n' "$BASH_TAGS") <(printf '%s\n' "$TS_TAGS"))
only_ts=$(comm -13 <(printf '%s\n' "$BASH_TAGS") <(printf '%s\n' "$TS_TAGS"))
assert_eq "${only_bash:-}" "" "no tags present only in bash"
assert_eq "${only_ts:-}"   "" "no tags present only in TS"

# Issue #18 defensive tags must be in BOTH lists.
for tag in stale-no-pr-branch stale-orphan-worktree; do
  bash_has=0; ts_has=0
  grep -qx "$tag" <<<"$BASH_TAGS" && bash_has=1
  grep -qx "$tag" <<<"$TS_TAGS"   && ts_has=1
  if (( bash_has == 1 && ts_has == 1 )); then
    PASS=$((PASS+1)); printf '  ok    %s present in both allowlists (issue #18)\n' "$tag"
  else
    FAIL=$((FAIL+1)); printf '  FAIL  %s missing from %s (issue #18)\n' "$tag" \
      "$([[ $bash_has == 0 && $ts_has == 0 ]] && echo "BOTH" || ([[ $bash_has == 0 ]] && echo "bash" || echo "TS"))"
  fi
done

# Smoke-test the bash function: extract just CANONICAL_TAGS + the
# function and source the snippet into the current shell, then call it.
# This catches array-vs-string regressions in the function body itself,
# not just the allowlist contents.
SNIPPET=$(awk '
  /^CANONICAL_TAGS=\(/,/^\)$/ { print; next }
  /^is_canonical_tag\(\) {/,/^}/ { print }
' "$BASH_SRC")
# shellcheck disable=SC1090
eval "$SNIPPET"
if is_canonical_tag stale-no-pr-branch; then
  PASS=$((PASS+1)); printf '  ok    bash is_canonical_tag stale-no-pr-branch -> true\n'
else
  FAIL=$((FAIL+1)); printf '  FAIL  bash is_canonical_tag stale-no-pr-branch returned false\n'
fi
if is_canonical_tag stale-orphan-worktree; then
  PASS=$((PASS+1)); printf '  ok    bash is_canonical_tag stale-orphan-worktree -> true\n'
else
  FAIL=$((FAIL+1)); printf '  FAIL  bash is_canonical_tag stale-orphan-worktree returned false\n'
fi
if is_canonical_tag rendering; then
  FAIL=$((FAIL+1)); printf '  FAIL  bash is_canonical_tag rendering wrongly returned true\n'
else
  PASS=$((PASS+1)); printf '  ok    bash is_canonical_tag rendering -> false (sanity)\n'
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
