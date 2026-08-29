#!/usr/bin/env bash
# An audit that reads only issue bodies decides duplicates, supersession and
# cancellations without the scope changes and "superseded by" notes that live
# in comments. tpm-audit.md is a markdown contract, so this pins the STRUCTURE
# that carries the read — the section, its commands, and the cross-reference
# § 6.2 makes to it — never the prose around them (review-bots.md).
#
# It also pins the route the step depends on: `cache comments list` must still
# exist in the linear skill that provides it, and the safe formatter it goes
# through must still emit comment bodies. A workflow naming a command the
# provider dropped reads correct and returns nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AUDIT="$SKILL_DIR/workflows/tpm-audit.md"
LINEAR_SKILL="$SKILL_DIR/../linear"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$AUDIT" ]] || fail "workflow not found: $AUDIT"

# --- the step exists as its own section -------------------------------------

grep -Eq '^### 1\.4\.1 Read Comments$' "$AUDIT" \
  || fail 'tpm-audit.md lost the § 1.4.1 Read Comments section'

section="$tmp/read-comments.md"
sed -n '/^### 1\.4\.1 /,/^### 1\.5 /p' "$AUDIT" >"$section"
[[ -s "$section" ]] || fail 'the § 1.4.1 section could not be extracted'

# --- and carries a comment-reading command for each tracker -----------------

grep -Fq -- '.agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID]' "$section" \
  || fail '§ 1.4.1 lost the cached per-issue comment read'

# GitHub has no cached body: `gh issue list` omits it, so a comparison row
# reaches this step with neither. Asking for comments alone would judge a
# Done or Canceled duplicate on its title.
grep -Fq -- '--json body,comments' "$section" \
  || fail '§ 1.4.1 GitHub read no longer fetches the body alongside comments'

# The step reads the cache, never the API: a live `comments list` would work
# around the sync the whole workflow is scoped to.
grep -Eq '^\.agents/skills/linear/scripts/linear\.sh comments list' "$section" \
  && fail '§ 1.4.1 reads comments live instead of from the cache'

# --- the read covers the closed rows the comparison set now carries ---------

# Canceled and Done rows are compared against for duplicates, relations and
# supersession, and a supersession note or cancellation rationale lives in the
# comments. Narrowing the read back to the active rows would judge a closed
# duplicate on its body alone, which is the decision this step exists to stop.
grep -Fq -- '§ 1.5' "$section" \
  || fail '§ 1.4.1 no longer covers the § 1.5 comparison set'
grep -Fq -- 'active rows' "$section" \
  && fail '§ 1.4.1 narrows the comment read back to the active comparison rows'

# --- the section that disposes below-bar issues points at the step ----------

# The rule runs from its bold marker to the next marker or heading. Stopping
# at the first blank line instead would read only the marker whenever the rule
# is written as a list, and the pin would then be looking at nothing.
awk '/^\*\*Below the bar\.\*\*/ { inside = 1; print; next }
     inside && (/^### / || /^\*\*/) { exit }
     inside { print }' "$AUDIT" >"$tmp/below-bar.md"
[[ $(grep -c . "$tmp/below-bar.md") -gt 1 ]] \
  || fail 'the § 6.2 below-the-bar rule came back empty or marker-only'
grep -Fq -- '§ 1.4.1' "$tmp/below-bar.md" \
  || fail '§ 6.2 below-the-bar evidence no longer cites the § 1.4.1 comment read'

# --- the always-loaded rule agrees with what a cached read enforces ---------

# SKILL.md is loaded on every run, so a stale-halt promise there outranks the
# workflows' own wording. A cached read halts on a missing cache; freshness
# comes from the sync-first rule, not from the read.
skill_md="$SKILL_DIR/SKILL.md"
[[ -f "$skill_md" ]] || fail "project-management SKILL.md not found at $skill_md"
grep -Fq -- 'missing or stale' "$skill_md" \
  && fail 'SKILL.md promises a stale cache read halts, which no cached read does'
grep -Fq -- 'sync --if-stale 15' "$skill_md" \
  || fail 'SKILL.md no longer names the read-only sync that keeps the cache fresh'

# --- the provider still routes the command the workflow names ---------------

cache_query="$LINEAR_SKILL/scripts/commands/cache-query.sh"
[[ -f "$cache_query" ]] || fail "linear cache-query.sh not found at $cache_query"
grep -Eq 'list\) cache_list_comments' "$cache_query" \
  || fail 'the linear skill no longer routes `cache comments list`'

formatters="$LINEAR_SKILL/scripts/lib/formatters.sh"
[[ -f "$formatters" ]] || fail "linear formatters.sh not found at $formatters"
grep -Eq '^format_comments_list\(\)' "$formatters" \
  || fail 'the linear skill no longer formats a comment listing'

echo "PASS: audit comment-read contract"
