#!/usr/bin/env bash
# The awaiting verdict's status description, composed from the evidence
# sources a repo's resolved settings actually enable. review-predicate.sh
# calls this on its awaiting arm and prints the result as the pending status.
#
# The gate is configuration-driven, so the text names what THIS repo is
# waiting for instead of asserting who reviews: a repo whose trust lists hold
# only human logins reads those people's names, a repo trusting bots reads the
# bots. Nothing is resolved here — the caller passes its already-resolved
# values, and lib/settings.sh stays the one resolver.
#
# Inputs (environment): HEAD_SHA, TRUSTED_LOGINS, TRUSTED_CONTEXTS,
# COMMENT_REVIEWERS. Output: the description on stdout, no trailing newline.
#
# GitHub truncates a commit-status description at 140 characters, and a real
# trust list is longer than that on its own. So the sha shortens to its
# 12-character prefix before any name is dropped, and the names that still do
# not fit are counted rather than cut mid-word.
set -euo pipefail

RG_STATUS_LIMIT=140

HEAD_SHA="${HEAD_SHA:-}"
TRUSTED_LOGINS="${TRUSTED_LOGINS:-}"
TRUSTED_CONTEXTS="${TRUSTED_CONTEXTS:-}"
COMMENT_REVIEWERS="${COMMENT_REVIEWERS:-}"

# A packed list -> one name per line, whitespace trimmed, blanks dropped.
# SEPARATORS is the tr set for that setting's own packing.
names_of() { # LIST SEPARATORS
  local item
  # printf '%s\n', never '%s': an unterminated last line is not read at all,
  # which would drop the only entry of a single-name list.
  printf '%s\n' "$1" | tr "$2" '\n' | while IFS= read -r item; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ -n "$item" ] && printf '%s\n' "$item"
  done
  return 0
}

# Every evidence source the settings name, in the decision table's order:
# trusted review-object logins, trusted status/check contexts, then the
# comment-form reviewers — their login half only, since the binding pattern is
# not a name a reader can act on.
sources() { # -> one name per line, duplicates collapsed
  {
    names_of "$TRUSTED_LOGINS" ';,'
    names_of "$TRUSTED_CONTEXTS" ';'
    names_of "$COMMENT_REVIEWERS" ';' | sed 's/:.*$//'
  } | awk '!seen[$0]++'
}

full_form="no review evidence at $HEAD_SHA yet; expected from "
short_form="no review evidence at ${HEAD_SHA:0:12} yet; expected from "

names="$(sources)"
count=0
[ -n "$names" ] && count="$(printf '%s\n' "$names" | wc -l | tr -d ' ')"

# Empty trust lists mean any non-author review is evidence. That is a source
# too, so it is named rather than leaving the clause blank.
if [ "$count" = "0" ]; then
  detail="${full_form}any non-author review"
  [ "${#detail}" -le "$RG_STATUS_LIMIT" ] || detail="${short_form}any non-author review"
  printf '%s' "$detail"
  exit 0
fi

joined="$(printf '%s\n' "$names" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
detail="$full_form$joined"
if [ "${#detail}" -le "$RG_STATUS_LIMIT" ]; then
  printf '%s' "$detail"
  exit 0
fi

# The full sha does not fit beside the names. Shorten it once, then fill the
# remaining budget with whole names and count whatever is left over.
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
$names
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
