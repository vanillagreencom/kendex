#!/usr/bin/env bash
# The awaiting verdict's status description. review-predicate.sh calls this on
# its awaiting arm and prints the result as the pending status.
#
# This script decides NOTHING about evidence. Which sources could still open
# the gate at this head is the predicate's judgment — it resolves the trust
# settings, applies each source's policy and filters the PR author — and it
# passes the answer in. All that happens here is fitting that answer into the
# 140 characters GitHub keeps of a commit-status description.
#
# The text names what THIS repo is waiting for rather than asserting who
# reviews: a gate whose trust lists hold only human logins reads those
# people's names, a gate trusting bots reads the bots.
#
# Inputs (environment): HEAD_SHA, and SOURCES as one eligible source per line.
# Output: the description on stdout, no trailing newline.
#
# A real trust list is longer than the whole limit on its own, so the sha
# shortens to its 12-character prefix before any name is dropped, and the
# names that still do not fit are counted rather than cut mid-word.
set -euo pipefail

RG_STATUS_LIMIT=140

HEAD_SHA="${HEAD_SHA:-}"
SOURCES="${SOURCES:-}"

full_form="no review evidence at $HEAD_SHA yet; expected from "
short_form="no review evidence at ${HEAD_SHA:0:12} yet; expected from "

count=0
[ -n "$SOURCES" ] && count="$(printf '%s\n' "$SOURCES" | wc -l | tr -d ' ')"

# No eligible source at all — a repo whose only trusted login is the PR
# author reaches this. Saying "expected from" nothing would read as a
# truncated status, so it names the state instead.
if [ "$count" = "0" ]; then
  detail="no review evidence at $HEAD_SHA yet; no configured source is eligible here"
  if [ "${#detail}" -gt "$RG_STATUS_LIMIT" ]; then
    detail="no review evidence at ${HEAD_SHA:0:12} yet; no configured source is eligible here"
  fi
  printf '%s' "$detail"
  exit 0
fi

joined="$(printf '%s\n' "$SOURCES" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
detail="$full_form$joined"
if [ "${#detail}" -le "$RG_STATUS_LIMIT" ]; then
  printf '%s' "$detail"
  exit 0
fi

# The full sha does not fit beside the names. Shorten it and try the whole
# list again BEFORE reserving room for any remainder clause — reserving first
# would drop a name that the short form has room for.
detail="$short_form$joined"
if [ "${#detail}" -le "$RG_STATUS_LIMIT" ]; then
  printf '%s' "$detail"
  exit 0
fi

# Still over. Fill the remaining budget with whole names and count the rest.
kept=0
shown=""
while IFS= read -r name; do
  if [ -z "$shown" ]; then candidate="$name"; else candidate="$shown, $name"; fi
  # Reserve room for the remainder clause (" and N more") before accepting a
  # name: a clause that no longer fits would be dropped silently, and an
  # absent count reads as a complete list.
  if [ $((${#short_form} + ${#candidate} + 10 + ${#count})) -le "$RG_STATUS_LIMIT" ]; then
    shown="$candidate"
    kept=$((kept + 1))
  else
    break
  fi
done <<EOF
$SOURCES
EOF

if [ "$kept" = "0" ] && [ "$count" = "1" ]; then
  printf '%s' "${short_form}1 configured reviewer"
elif [ "$kept" = "0" ]; then
  printf '%s' "$short_form$count configured reviewers"
elif [ "$kept" = "$count" ]; then
  printf '%s' "$short_form$shown"
else
  printf '%s' "$short_form$shown and $((count - kept)) more"
fi
