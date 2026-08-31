#!/usr/bin/env bash
# The reviewer package told a re-review to scope the pass to the fix diff, and
# no delegation carried that diff. review.md resolved an absent Diff-range by
# diffing origin/<base>...HEAD, so every re-review round read the whole branch
# while believing itself scoped.
#
# What is pinned here is RENDERED, not grepped. A first cut of the fix put the
# sentinel in a placeholder INSIDE the value, leaving `...HEAD` outside it: the
# missing-boundary render was `unavailable...HEAD`, which review.md never
# matches, so the pass took the scoped route and ran
# `git diff unavailable...HEAD`. Every token a token check would look for was
# present. A token being present is not the path being reachable, so the
# checks below resolve the field's two branches and the external lane's flag
# and assert what comes out. Other suites use `check` for a count or a
# containment; this is the only one that RENDERS a template and asserts the
# resulting string.
#
# NOT covered: that review.md § 1's two routing sentences and its unscoped
# declaration enumerate the same cases. That is prose on both ends with no
# token separating a faithful statement from a narrowed one.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

REVIEW_PR_WF="$SKILL_DIR/workflows/review-pr.md"
REVIEW_WF="$SKILLS_ROOT/reviewer/workflows/review.md"
LAUNCH="### 2.2 Launch And Delegate"
ABSENT='unavailable'

echo "=== re-review scope boundary lint ==="

launch="$(section "$REVIEW_PR_WF" "$LAUNCH")"
diff_sec="$(section "$REVIEW_WF" "## 1. Diff")"
range_line="$(grep -E -e '^Diff-range:' <<<"$launch" || true)"

# Everything outside the field's bracketed instruction is emitted whatever the
# condition resolves to. The value is safe only when its first `[` closes on
# the last character: anything after that matching `]` rides on both branches,
# and the missing-boundary render stops being the bare sentinel.
wholly_conditional() {
  awk -v line="$1" 'BEGIN {
    sub(/^Diff-range:[ \t]*/, "", line)
    if (substr(line, 1, 1) != "[") exit 1
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (c == "[") d++
      else if (c == "]" && --d == 0) exit (i == length(line)) ? 0 : 1
    }
    exit 1
  }'
}

# What a reviewer is handed when the read returned no sha, and what a real sha
# renders to. Each is printed only when the value is wholly conditional, since
# otherwise there is no single rendered line to hand anyone.
render_missing() {
  wholly_conditional "$range_line" || return 1
  grep -qE -e "(^|[^[:alnum:]])$ABSENT([^[:alnum:]]|$)" <<<"$range_line" || return 1
  printf 'Diff-range: %s' "$ABSENT"
}
render_sha() {
  local tpl
  wholly_conditional "$range_line" || return 1
  tpl="$(grep -oE -e '`[^`]*\[PRE_SHA\][^`]*`' <<<"$range_line" | tr -d '`' | head -1)"
  [ -n "$tpl" ] || return 1
  printf '%s' "${tpl//\[PRE_SHA\]/deadbee}"
}

check "the re-review delegation carries a Diff-range" test -n "$range_line"
check "the missing-boundary render is the line review.md § 1 routes on" \
  grep -qF -e "$(render_missing || echo '<unrenderable>')" <<<"$diff_sec"
check "the sha path renders [PRE_SHA]...HEAD with the sha in it" \
  test "$(render_sha || true)" = 'deadbee...HEAD'

# § 4 declares external review part of the scoped panel. It is a shell command,
# not a delegation, so the range reaches it as a flag or not at all — and the
# script's own default is the whole branch, so omitting the flag silently reads
# exactly the surface the scoped pass excludes. The flag therefore lives wholly
# inside the token: spelled in the command it cannot be withdrawn, and the
# empty branch leaves it dangling over a broken value. Both branches are
# rendered and each is asserted to be a command that runs.
external_lane_resolves() {
  local cmd bind tok val
  cmd="$(grep -F -e 'second-opinion review' <<<"$launch" || true)"
  bind="$(grep -oE -e '`\[[A-Z_]+\]` is `--range [^`]*`' <<<"$launch" | head -1)"
  [ -n "$cmd" ] && [ -n "$bind" ] || return 1
  tok="$(sed -E 's/^`(\[[A-Z_]+\])`.*/\1/' <<<"$bind")"
  val="$(sed -E 's/^.* is `(--range [^`]*)`.*/\1/' <<<"$bind")"
  grep -qF -e '--range' <<<"$cmd" && return 1
  grep -qF -e "$tok" <<<"$cmd" || return 1
  grep -qE -e '(--range|\.\.\.HEAD)' <<<"${cmd//"$tok"/}" && return 1
  local filled="${cmd//"$tok"/$val}"
  grep -qE -e '--range deadbee\.\.\.HEAD' <<<"${filled//\[PRE_SHA\]/deadbee}"
}
check "the external lane renders the panel's boundary, and no flag without one" \
  external_lane_resolves

# Teeth: the shape the fix was reverted from. `...HEAD` outside the bracket
# leaves every token in place and breaks both renders.
range_line='Diff-range: [`[PRE_SHA]` when the read returned a sha, `unavailable` otherwise]...HEAD'
check "a value with text outside the bracket renders no sentinel" \
  test -z "$(render_missing || true)"
check "a value with text outside the bracket renders no usable range" \
  test "$(render_sha || true)" != 'deadbee...HEAD'

md_report
