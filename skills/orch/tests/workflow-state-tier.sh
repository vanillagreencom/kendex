#!/usr/bin/env bash
# `workflow-state` under a recorded tier: a small item's review bounds.
#
# ../workflows/small.md § 3 Review and § 4 Submit bound the review to three
# reviewers, one re-review after one fix round, and two bot rounds.
# workflow-state holds each bound once the item's state records tier small,
# and holds none without it. Every
# row resolves from a settings-free checkout with the caps stripped from the
# process environment, so the numbers are the table's.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$TEST_DIR/../scripts/workflow-state"
SD="$TMP_ROOT/state"
NO_SETTINGS="$TMP_ROOT/no-settings"
git init -q "$NO_SETTINGS"

PASS=0
FAIL=0
assert_eq() { # GOT WANT NAME
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"
  fi
}

ws() { (cd "$NO_SETTINGS" && env -u REVIEW_MAX_CYCLES -u REVIEW_MAX_EXTERNAL_ROUNDS "$WS" --state-dir "$SD" "$@"); }

# The first stderr line's key and exit status of a set.
set_verdict() { # ISSUE FIELD VALUE
  local err rc=0
  err="$(ws set "$@" 2>&1 >/dev/null)" || rc=$?
  printf '%s rc=%s' "$(sed -n '1s/^workflow-state: \([a-z-]*\).*/\1/p' <<<"$err")" "$rc"
}

panel() { # N — a panel of N reviewers
  local agents="" i
  for ((i = 1; i <= $1; i++)); do agents="$agents${agents:+,}\"rev-$i\""; done
  printf '{"agents": [%s], "reason": "test"}' "$agents"
}

echo
echo "--- workflow-state tier bounds ---"

# The bounds, one row per tier: each cap's fresh reading, a panel of four,
# and the second re-review entry.
# tier|re-review cap|bot-round cap|panel of four|second re-review
ROWS=(
  "small|below 0/1|below 0/2|panel-bound rc=1|cycle-cap rc=1"
  "standard|below 0/4|below 0/4| rc=0| rc=0"
  "-|below 0/4|below 0/4| rc=0| rc=0"
)
for row in "${ROWS[@]}"; do
  IFS='|' read -r tier want_cycles want_rounds want_panel want_second <<<"$row"
  issue="KEN-TIER-$tier"
  ws init "$issue" --worktree "$NO_SETTINGS" --branch "b-$tier" >/dev/null
  [[ "$tier" == - ]] || ws set "$issue" tier "$tier"
  assert_eq "$(ws cap REVIEW_MAX_CYCLES --issue "$issue")" "$want_cycles" "tier $tier: the re-review cap"
  assert_eq "$(ws cap REVIEW_MAX_EXTERNAL_ROUNDS --issue "$issue")" "$want_rounds" "tier $tier: the bot-round cap"
  assert_eq "$(set_verdict "$issue" first_panel "$(panel 4)")" "$want_panel" "tier $tier: a first panel of four"
  assert_eq "$(set_verdict "$issue" first_panel "$(panel 3)")" " rc=0" "tier $tier: a first panel of three"
  assert_eq "$(set_verdict "$issue" rereview_panel "$(panel 1)")" " rc=0" "tier $tier: the first re-review"
  assert_eq "$(set_verdict "$issue" rereview_panel "$(panel 1)")" "$want_second" "tier $tier: the second re-review"
done

# A bare cap names no item, so no tier bounds it.
assert_eq "$(ws cap REVIEW_MAX_CYCLES)" "4" "a bare cap reads the setting"

assert_eq "$(set_verdict KEN-TIER-small tier Small)" "tier-value rc=2" "a tier outside the three is refused"

printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
