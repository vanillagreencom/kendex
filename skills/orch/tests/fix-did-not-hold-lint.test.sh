#!/usr/bin/env bash
# Regression lint for KEN-632. Every re-review prompt suppressed anything the
# delegation listed as Fixed, with no exception. A reviewer that obeyed stayed
# silent about a finding whose recorded fix failed, so the machinery that
# supersedes the stale `fixed_items` entry never got the input it needs and § 8
# kept publishing a live blocker as fixed against a dead sha. The rule lives at
# three sites — review-pr's re-review delegation, its QA delegation, and the
# reviewer package's own § Re-Review Rounds — and a compliant reviewer obeys
# its own skill whatever a delegation invites, so all three carry the exception
# or the change does not take effect.
#
# The exception's other half matters as much: suppression that becomes optional
# is the failure it exists to prevent. It covers a Fixed item the reviewer
# checked against the current diff; an Escalated item is accepted as blocked
# and stays suppressed.
#
# The re-report has to land on the supersede's key, which is exact equality of
# the RECORDED entry's location and description. So each prompt tells the
# reviewer to copy those two fields verbatim and to put the sha in the
# recommendation, where no key reads it. The sha is named in prose: a
# `[COMMIT_SHA]` token outside a per-item loop binds to nothing, and the
# fill-or-omit rule for delegation blocks would drop the sentence holding it.
#
# EVERY element is required ON THE LINE THAT STATES THE RULE. Tokens scattered
# across a region prove nothing about the sentence a reviewer obeys: a region
# reverted to blanket suppression can still hold a conditional in some
# neighbouring bullet. One line, or the check has not tested the contract.
#
# What this pins are IDENTIFIERS and their relationships, never sentences:
# review-bots.md bans sentence-pinning lints on markdown, and an editorial
# rephrase must not fail a suite while the contract holds. The controls obey
# the same rule — each derives its mutation from the structure the check reads,
# a whole region dropped or one pinned token substituted, so no control carries
# a copy of the prose it guards.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
REVIEW_PR_WF="$SKILL_DIR/workflows/review-pr.md"
DEV_FIX_WF="$SKILL_DIR/workflows/dev-fix.md"
REVIEWER_SKILL="$SKILL_DIR/../reviewer/SKILL.md"
STATE_SCHEMA="$SKILL_DIR/schemas/workflow-state.md"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== re-report a fix that did not hold lint (KEN-632) ==="

# HTML comment regions are stripped from EVERY line before any region gate, so
# a comment opened above a marker blanks the marker too and the region never
# opens: a commented-out instruction is not an instruction, wherever the
# comment starts.
strip_comments() {
  awk '
    {
      line = $0; out = ""
      while (length(line) > 0) {
        if (incomment) {
          p = index(line, "-->")
          if (p == 0) { line = ""; break }
          incomment = 0
          line = substr(line, p + 3)
        } else {
          p = index(line, "<!--")
          if (p == 0) { out = out line; line = ""; break }
          out = out substr(line, 1, p - 1)
          incomment = 1
          line = substr(line, p + 4)
        }
      }
      print out
    }
  ' "$1"
}

# Every grep reads a herestring, never a pipe: `grep -q` exits at the first
# match, SIGPIPE would kill the extractor, and `pipefail` would promote its 141
# into a false failure. `|| true` on every extractor: a control that removes
# the text leaves grep with no match, and an unguarded failure inside a command
# substitution ends the run before the control can be judged.
has() { grep -qE -e "$2" <<<"$1"; }

# --- the three sites --------------------------------------------------------
# Each is a region of a file, opened and closed by structural markers. The
# reviewer rule closes on ANY later heading: closing on a heading that merely
# starts with some other letter widens the region silently the day a heading
# starting with R is added below it.
site_file() {
  case "$1" in
    reviewer) printf '%s' "$REVIEWER_SKILL" ;;
    *)        printf '%s' "$REVIEW_PR_WF" ;;
  esac
}
site_head() {
  case "$1" in
    rereview) printf '%s' '^<if re-review cycle>$' ;;
    qa)       printf '%s' 'Previous review cycle context' ;;
    reviewer) printf '%s' '^## Re-Review Rounds$' ;;
  esac
}
site_tail() {
  case "$1" in
    rereview) printf '%s' '^</if>$' ;;
    qa)       printf '%s' '^</delegation_format>$' ;;
    reviewer) printf '%s' '^## ' ;;
  esac
}
site_label() {
  case "$1" in
    rereview) printf '%s' 'the re-review delegation' ;;
    qa)       printf '%s' 'the QA delegation' ;;
    reviewer) printf '%s' 'reviewer § Re-Review Rounds' ;;
  esac
}

# $1 = file, $2 = ERE opening the region (its line is included), $3 = ERE
# closing it (its line is excluded).
slice() {
  strip_comments "$1" | awk -v head="$2" -v tail="$3" '
    !on && $0 ~ head { on = 1 }
    on && printed && $0 ~ tail { on = 0 }
    !on { next }
    { print; printed = 1 }
  '
}

# $1 = site, $2 = file to read (defaults to the site's own).
region_of() {
  local f="${2:-$(site_file "$1")}"
  slice "$f" "$(site_head "$1")" "$(site_tail "$1")"
}

# --- the contract, all of it on one line ------------------------------------
SUPPRESS='[Dd]o NOT re-report|not re-reported'
COND='unless|except'
# Word-bounded, so `shared` and `shape` do not stand in for a sha citation.
SHA='(^|[^[:alnum:]])sha([^[:alnum:]]|$)'

rule_line() { grep -E -- "$SUPPRESS" <<<"$1" || true; }

site_states_rule()      { [[ -n "$(rule_line "$1")" ]]; }
site_is_conditional()   { has "$(rule_line "$1")" "$COND"; }
site_names_sha()        { has "$(rule_line "$1")" "$SHA"; }
site_copies_key()       {
  local l; l="$(rule_line "$1")"
  has "$l" 'verbatim' && has "$l" 'location' && has "$l" 'description'
}
site_keeps_escalated()  {
  local l; l="$(rule_line "$1")"
  has "$l" '[Ee]scalated' && has "$l" 'suppressed'
}
site_binds_its_tokens() { ! has "$(rule_line "$1")" '\[COMMIT_SHA\]'; }

for site in rereview qa reviewer; do
  R="$(region_of "$site")"
  L="$(site_label "$site")"

  if site_states_rule "$R"; then
    pass "$L states a suppression rule"
  else
    fail "$L states no suppression rule at all"
    continue
  fi

  # Blanket suppression is the defect. The conditional is what narrows it.
  if site_is_conditional "$R"; then
    pass "$L suppresses conditionally, on one line"
  else
    fail "$L suppresses every listed item unconditionally"
  fi

  # The sha makes the re-report checkable against what was recorded.
  if site_names_sha "$R"; then
    pass "$L names the recorded sha on that line"
  else
    fail "$L re-reports with no sha to check the claim against"
  fi

  # Copying location and description is what makes the drop match: the
  # supersede keys on exact equality with the recorded entry.
  if site_copies_key "$R"; then
    pass "$L copies location and description verbatim"
  else
    fail "$L lets the reviewer re-author the fields the key reads"
  fi

  # Escalated items are accepted as blocked. Extending the exception to them
  # reopens settled decisions and is the re-report-everything failure.
  if site_keeps_escalated "$R"; then
    pass "$L keeps escalated items suppressed"
  else
    fail "$L widened the exception past the Fixed list"
  fi

  # A per-item token in a sentence no loop fills is unfillable, and the
  # fill-or-omit rule drops the line holding it. The Fixed list line owns the
  # block's bound occurrence; the rule line carries none.
  if site_binds_its_tokens "$R"; then
    pass "$L states the rule with no unbound [COMMIT_SHA]"
  else
    fail "$L carries a [COMMIT_SHA] nothing binds"
  fi
done

# --- dev-fix records each item into exactly one bucket, once ----------------
# An item comes back for a second disposition two ways: a re-reported fix that
# did not hold, and an escalated item a later round fixes. Either way a bucket
# still lists it against a dead sha, so each write clears the item from BOTH
# buckets before appending its own. Clearing only the opposite bucket leaves
# the item printed under FIXED and ESCALATED at once.
devfix_writes() { strip_comments "$1" | grep -E 'workflow-state (append|update) \[ISSUE_ID\]' || true; }
fixed_write()   { grep -F '.fixed_items += '     <<<"$(devfix_writes "$1")" || true; }
escal_write()   { grep -F '.escalated_items += ' <<<"$(devfix_writes "$1")" || true; }

# Both buckets cleared, keyed on both fields — the same key § 8 dedupes on.
drops_stale() {
  has "$1" 'fixed_items = ' && has "$1" 'escalated_items = ' \
    && has "$1" '\.location' && has "$1" '\.description' && has "$1" 'map\(select\('
}

# The entry crosses into jq through a file. Pasted into argv it breaks on the
# text findings actually carry: a double quote makes the JSON argument
# invalid, an apostrophe ends the shell word, and the failed write leaves the
# stale entry standing with nothing recorded.
binds_from_file() { has "$1" '--slurpfile item' && ! has "$1" '--arg'; }

FW="$(fixed_write "$DEV_FIX_WF")"
if [[ -n "$FW" ]] && has "$FW" 'workflow-state update' && drops_stale "$FW"; then
  pass "the fixed_items write clears the item from both buckets"
else
  fail "the fixed_items write leaves a stale entry in one of the buckets"
fi

EW="$(escal_write "$DEV_FIX_WF")"
if [[ -n "$EW" ]] && has "$EW" 'workflow-state update' && drops_stale "$EW"; then
  pass "the escalated_items write clears the item from both buckets"
else
  fail "the escalated_items write leaves a stale entry in one of the buckets"
fi

if [[ -n "$FW" ]] && [[ -n "$EW" ]] && binds_from_file "$FW" && binds_from_file "$EW"; then
  pass "both writes bind the entry from a file and paste no finding text"
else
  fail "a write pastes the finding's own text into a shell word"
fi

if devfix_writes "$DEV_FIX_WF" | grep -qE 'append \[ISSUE_ID\] (fixed|escalated)_items'; then
  fail "dev-fix still appends into a bucket instead of superseding"
else
  pass "dev-fix uses no bare append into either bucket"
fi

# --- the schema states the one-bucket invariant -----------------------------
SCHEMA_RULE='never in both buckets'
if grep -qE "$SCHEMA_RULE" "$STATE_SCHEMA"; then
  pass "workflow-state schema states the one-bucket invariant"
else
  fail "workflow-state schema lost the one-bucket invariant"
fi

# --- the region cannot widen without saying so ------------------------------
# The reviewer rule's region closes on the next heading. If the opening heading
# were gone, or a nested heading crept in, the checks above would read tokens
# from sections that state no rule.
heading_count="$(grep -cE '^## ' <<<"$(region_of reviewer)" || true)"
if [[ "$heading_count" -eq 1 ]]; then
  pass "the reviewer rule's region holds its own heading and no other"
else
  fail "the reviewer rule's region spans $heading_count headings"
fi

# --- planted controls: prove each check can fail ----------------------------
# Every mutation is derived from what the check reads — a whole region dropped,
# one pinned token substituted, or a token appended to the rule line — so a
# contract-preserving rewording of the prose leaves every control working.
echo
echo "--- planted controls ---"

# $1 = file, $2 = head ERE, $3 = tail ERE. Prints the file with the region's
# lines removed.
drop_region() {
  awk -v head="$2" -v tail="$3" '
    !on && $0 ~ head { on = 1; printed = 0 }
    on && printed && $0 ~ tail { on = 0 }
    on { printed = 1; next }
    { print }
  ' "$1"
}

# $1 = file, $2 = head, $3 = tail, $4 = ERE to replace, $5 = replacement.
# Substitutes inside the region only, so one control moves one check.
sub_region() {
  awk -v head="$2" -v tail="$3" -v from="$4" -v to="$5" '
    !on && $0 ~ head { on = 1; printed = 0 }
    on && printed && $0 ~ tail { on = 0 }
    on { printed = 1; gsub(from, to) }
    { print }
  ' "$1"
}

# $1 = file, $2 = head, $3 = tail, $4 = text appended to the rule line.
append_to_rule() {
  awk -v head="$2" -v tail="$3" -v rule="$SUPPRESS" -v add="$4" '
    !on && $0 ~ head { on = 1; printed = 0 }
    on && printed && $0 ~ tail { on = 0 }
    on { printed = 1; if ($0 ~ rule) $0 = $0 " " add }
    { print }
  ' "$1"
}

# $1 = site, $2 = control name, $3 = predicate the control must turn false,
# $4 = what the mutation removed. CTRL_FILE holds the mutated copy.
judge() {
  local site="$1" name="$2" predicate="$3" what="$4" src
  src="$(site_file "$site")"
  if cmp -s "$CTRL_FILE" "$src"; then
    fail "$name control planted nothing — the mutation matched no text"
  elif "$predicate" "$(region_of "$site" "$CTRL_FILE")"; then
    fail "lint MISSED $what at $(site_label "$site")"
  else
    pass "lint flags $what at $(site_label "$site")"
  fi
}

for site in rereview qa reviewer; do
  head="$(site_head "$site")"
  tail="$(site_tail "$site")"
  src="$(site_file "$site")"

  # The rule gone entirely: the region a reader obeys is no longer there.
  CTRL_FILE="$TMP_ROOT/$site-dropped.md"
  drop_region "$src" "$head" "$tail" > "$CTRL_FILE"
  judge "$site" "dropped-region" site_states_rule "a region that states no rule"

  # Blanket suppression: the conditional gone, everything else intact.
  CTRL_FILE="$TMP_ROOT/$site-blanket.md"
  sub_region "$src" "$head" "$tail" "$COND" "when" > "$CTRL_FILE"
  judge "$site" "blanket" site_is_conditional "suppression reverted to blanket"

  # The exception kept with nothing to check the re-report against.
  CTRL_FILE="$TMP_ROOT/$site-nosha.md"
  sub_region "$src" "$head" "$tail" "sha" "identifier" > "$CTRL_FILE"
  judge "$site" "no-sha" site_names_sha "a re-report citing no recorded sha"

  # The two fields the key reads left to the reviewer's own wording.
  CTRL_FILE="$TMP_ROOT/$site-reauthored.md"
  sub_region "$src" "$head" "$tail" "verbatim" "as you see fit" > "$CTRL_FILE"
  judge "$site" "re-authored" site_copies_key "key fields left to re-authoring"

  # The exception widened over escalated items too.
  CTRL_FILE="$TMP_ROOT/$site-widened.md"
  sub_region "$src" "$head" "$tail" "suppressed" "reported" > "$CTRL_FILE"
  judge "$site" "widened" site_keeps_escalated "an exception widened past the Fixed list"

  # The sha carried as a per-item token in a sentence no loop fills.
  CTRL_FILE="$TMP_ROOT/$site-placeholder.md"
  append_to_rule "$src" "$head" "$tail" "[COMMIT_SHA]" > "$CTRL_FILE"
  judge "$site" "placeholder" site_binds_its_tokens "an unbound [COMMIT_SHA] in the rule"
done

# The sha match is word-bounded, so a rule that merely says "shared" or "shape"
# does not read as a sha citation. Run against the predicate, not a file.
if site_names_sha 'do NOT re-report a shared shape' ; then
  fail "the sha match is satisfied by a word that merely contains sha"
else
  pass "the sha match rejects shared and shape"
fi

if site_names_sha 'do NOT re-report; name the sha it is listed against'; then
  pass "the sha match still reads a real sha citation"
else
  fail "the sha match rejects a real sha citation"
fi

# Inert-text control: the reviewer rule preserved word for word but commented
# out. Anchored on headings, so it survives any rewrite of the rule itself.
INERT="$TMP_ROOT/reviewer-inert.md"
awk '
  /^## Re-Review Rounds/ && !opened { print "<!--"; opened = 1 }
  opened && !closed && /^## / && !/^## Re-Review Rounds/ { print "-->"; closed = 1 }
  { print }
' "$REVIEWER_SKILL" > "$INERT"
if ! grep -qF '<!--' "$INERT"; then
  fail "inert-rule control planted nothing — no comment region was opened"
elif site_states_rule "$(region_of reviewer "$INERT")"; then
  fail "lint credits a rule that sits inside an HTML comment"
else
  pass "lint flags a re-review rule commented out from above its heading"
fi

# A heading inside the region: the slice must not swallow what follows it.
WIDENED="$TMP_ROOT/reviewer-widened.md"
awk '
  /^## Re-Review Rounds/ && !done { print; print ""; print "## Rounds, continued"; done = 1; next }
  { print }
' "$REVIEWER_SKILL" > "$WIDENED"
w_headings="$(grep -cE '^## ' <<<"$(region_of reviewer "$WIDENED")" || true)"
if cmp -s "$WIDENED" "$REVIEWER_SKILL"; then
  fail "widening control planted nothing — no heading was inserted"
elif [[ "$w_headings" -gt 1 ]]; then
  fail "lint credits a region that spans a second heading"
else
  pass "lint flags a region widened past its own heading"
fi

# $1 = source file, $2 = control name, $3 = sed program. Sets CTRL and reports
# whether the program changed anything: one matching nothing leaves the source
# untouched and the control proves nothing. Runs in the parent shell, never a
# command substitution, so its verdict reaches the counters.
plant() {
  CTRL="$TMP_ROOT/$2"
  sed "$3" "$1" > "$CTRL"
  ! cmp -s "$CTRL" "$1"
}

# The append shape: the entry recorded beside whatever already stands.
if ! plant "$DEV_FIX_WF" df-append.md "s|workflow-state update \[ISSUE_ID\] --slurpfile item \(.*\) '.*escalated_items += .*'|workflow-state append [ISSUE_ID] escalated_items \\1|"; then
  fail "escalate control planted nothing — its sed program matched no text"
else
  C="$(escal_write "$CTRL")"
  if [[ -n "$C" ]] && drops_stale "$C"; then
    fail "lint MISSED an escalate that records without clearing the buckets"
  elif ! devfix_writes "$CTRL" | grep -qE 'append \[ISSUE_ID\] escalated_items'; then
    fail "escalate control planted no append — control is vacuous"
  else
    pass "lint flags an escalate that records without clearing the buckets"
  fi
fi

if ! plant "$DEV_FIX_WF" df-fixed-append.md "s|workflow-state update \[ISSUE_ID\] --slurpfile item \(.*\) '.*fixed_items += .*'|workflow-state append [ISSUE_ID] fixed_items \\1|"; then
  fail "fixed control planted nothing — its sed program matched no text"
else
  C="$(fixed_write "$CTRL")"
  if [[ -n "$C" ]] && drops_stale "$C"; then
    fail "lint MISSED a fixed_items append beside a stale entry"
  else
    pass "lint flags a fixed_items append beside a stale entry"
  fi
fi

# The one-directional shape: the fixed write clears its own bucket and leaves
# a matching escalated entry standing. § 8 then prints the item under both.
if ! plant "$DEV_FIX_WF" df-oneway.md 's/ | .escalated_items = ((.escalated_items \/\/ \[\]) | map(select(.location != $e.location or .description != $e.description))) | .fixed_items += \[$e\]/ | .fixed_items += [$e]/'; then
  fail "one-way control planted nothing — its sed program matched no text"
elif drops_stale "$(fixed_write "$CTRL")"; then
  fail "lint MISSED a fixed write that never clears escalated_items"
else
  pass "lint flags a fixed write that never clears escalated_items"
fi

# The drop present but keyed on one field: two findings at the same location
# collide, or the same finding re-worded survives as a duplicate.
if ! plant "$DEV_FIX_WF" df-halfkey.md 's/select(\.location != $e\.location or \.description != $e\.description)/select(.location != $e.location)/g'; then
  fail "half-key control planted nothing — its sed program matched no text"
elif drops_stale "$(escal_write "$CTRL")"; then
  fail "lint MISSED a drop keyed on one field"
else
  pass "lint flags a drop keyed on one field"
fi

# The entry pasted into argv instead of bound from its file.
if ! plant "$DEV_FIX_WF" df-pasted.md "s|--slurpfile item tmp/state-item-\[ISSUE_ID\].json|--arg desc '[DESC]' --arg loc '[LOC]'|g"; then
  fail "pasted-entry control planted nothing — its sed program matched no text"
elif binds_from_file "$(escal_write "$CTRL")"; then
  fail "lint MISSED an entry pasted into a shell word"
else
  pass "lint flags an entry pasted into a shell word"
fi

# The invariant's own words replaced: the check reads the token, so the control
# moves the token and nothing else.
SCRATCH_SCHEMA="$TMP_ROOT/schema.md"
sed "s/$SCHEMA_RULE/held apart/" "$STATE_SCHEMA" > "$SCRATCH_SCHEMA"
if cmp -s "$SCRATCH_SCHEMA" "$STATE_SCHEMA"; then
  fail "schema control planted nothing — its sed program matched no text"
elif grep -qE "$SCHEMA_RULE" "$SCRATCH_SCHEMA"; then
  fail "lint MISSED a schema that lost the one-bucket invariant"
else
  pass "lint flags a schema that lost the one-bucket invariant"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
