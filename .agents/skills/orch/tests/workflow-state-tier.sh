#!/usr/bin/env bash
# `workflow-state` under a recorded tier: a small item's review bounds.
#
# ../workflows/small.md § 3 Review and § 4 Submit bound the review to three
# reviewers, the external lane counted, one re-review after one fix round,
# and two bot rounds.
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

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

ws() { (cd "$NO_SETTINGS" && env -u REVIEW_MAX_CYCLES -u REVIEW_MAX_EXTERNAL_ROUNDS "$WS" --state-dir "$SD" "$@"); }

# The first stderr line's key and exit status of a set.
set_verdict() { # ISSUE FIELD VALUE
  local err rc=0
  err="$(ws set "$@" 2>&1 >/dev/null)" || rc=$?
  printf '%s rc=%s' "$(sed -n '1s/^workflow-state: \([a-z-]*\).*/\1/p' <<<"$err")" "$rc"
}

panel() { # N [EXTERNAL] — a panel of N reviewers, the external lane's marker
  # false unless given, and absent for `-`
  local agents="" i external=', "external": '"${2:-false}"
  for ((i = 1; i <= $1; i++)); do agents="$agents${agents:+,}\"rev-$i\""; done
  [[ "${2:-}" == - ]] && external=""
  printf '{"agents": [%s], "reason": "test"%s}' "$agents" "$external"
}

echo
echo "--- workflow-state tier bounds ---"

# The bounds, one row per tier history: the tiers written in order, where
# `small standard` is a small run relaunched at standard. Each row reads both
# caps fresh, the third review-wait take on one head, panels of four on each
# bounded field, a first panel of three with the external lane and one with
# no external marker, the re-review count after a refused or accepted panel
# of four, and a later single-reviewer re-review.
# tiers|re-review cap|bot-round cap|third review-wait|first four|verification four|three and external|no marker|re-review four|count after|next re-review
ROWS=(
  "small|below 0/1|below 0/2|at-cap 2/2|panel-bound rc=1|panel-bound rc=1|panel-bound rc=1|panel-external rc=1|panel-bound rc=1|0| rc=0"
  "standard|below 0/4|below 0/4|continue 3/4| rc=0| rc=0| rc=0| rc=0| rc=0|1| rc=0"
  "small standard|below 0/4|below 0/4|continue 3/4| rc=0| rc=0| rc=0| rc=0| rc=0|1| rc=0"
  "-|below 0/4|below 0/4|continue 3/4| rc=0| rc=0| rc=0| rc=0| rc=0|1| rc=0"
)
for row in "${ROWS[@]}"; do
  IFS='|' read -r tiers want_cycles want_rounds want_wait want_first want_verify want_external want_unmarked want_rereview want_count want_next <<<"$row"
  issue="KEN-TIER-${tiers// /-}"
  ws init "$issue" --worktree "$NO_SETTINGS" --branch "b-$issue" >/dev/null
  for tier in $tiers; do
    [[ "$tier" == - ]] || ws set "$issue" tier "$tier"
  done
  assert_eq "$(ws cap REVIEW_MAX_CYCLES --issue "$issue")" "$want_cycles" "tiers $tiers: the re-review cap"
  assert_eq "$(ws cap REVIEW_MAX_EXTERNAL_ROUNDS --issue "$issue")" "$want_rounds" "tiers $tiers: the bot-round cap"
  ws head-budget take "$issue" review-wait h1 >/dev/null
  ws head-budget take "$issue" review-wait h1 >/dev/null
  assert_eq "$(ws head-budget take "$issue" review-wait h1)" "$want_wait" "tiers $tiers: the third review-wait take"
  assert_eq "$(set_verdict "$issue" first_panel "$(panel 4)")" "$want_first" "tiers $tiers: a first panel of four"
  assert_eq "$(set_verdict "$issue" verification_panel "$(panel 4)")" "$want_verify" "tiers $tiers: a verification panel of four"
  assert_eq "$(set_verdict "$issue" first_panel "$(panel 3)")" " rc=0" "tiers $tiers: a first panel of three"
  assert_eq "$(set_verdict "$issue" first_panel "$(panel 2 true)")" " rc=0" "tiers $tiers: two reviewers and the external lane"
  assert_eq "$(set_verdict "$issue" first_panel "$(panel 3 true)")" "$want_external" "tiers $tiers: three reviewers and the external lane"
  assert_eq "$(set_verdict "$issue" first_panel "$(panel 1 -)")" "$want_unmarked" "tiers $tiers: a panel with no external marker"
  assert_eq "$(set_verdict "$issue" rereview_panel "$(panel 4)")" "$want_rereview" "tiers $tiers: a re-review panel of four"
  assert_eq "$(ws get "$issue" '.rereview_cycles // 0')" "$want_count" "tiers $tiers: the re-review count after it"
  assert_eq "$(set_verdict "$issue" rereview_panel "$(panel 1)")" "$want_next" "tiers $tiers: the next re-review"
done

# The small cap after both re-reviews above: the one entry it allows is taken.
assert_eq "$(set_verdict KEN-TIER-small rereview_panel "$(panel 1)")" "cycle-cap rc=1" "tiers small: a second re-review entry"

# The tier ceiling lowers a cap and never raises one: a setting under it wins.
got="$(cd "$NO_SETTINGS" && REVIEW_MAX_CYCLES=0 "$WS" --state-dir "$SD" cap REVIEW_MAX_CYCLES --issue KEN-TIER-small)"
assert_eq "$got" "at-cap 1/0" "tiers small: a setting below the ceiling holds"

# A bare cap names no item, so no tier bounds it.
assert_eq "$(ws cap REVIEW_MAX_CYCLES)" "4" "a bare cap reads the setting"

assert_eq "$(set_verdict KEN-TIER-small tier Small)" "tier-value rc=2" "a tier outside the three is refused"

printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
