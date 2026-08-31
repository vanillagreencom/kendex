#!/usr/bin/env bash
# The external review-round cap: `pr_comment_review.iterations` counts the
# triage passes orch runs against an open PR's bot review, and
# `REVIEW_MAX_EXTERNAL_ROUNDS` (default 4) bounds it. Past the cap a finding
# gets a disposition and no fix push, except a defect the diff itself
# introduces or arms, which is fixed whatever the round count.
#
# The runtime half of this contract is not re-proved here. The cap's row —
# its default of 4 and the `pr_comment_review.iterations` field it is measured
# against — is pinned in `workflow-state-cycle-cap.sh`, which reads it from a
# settings-free checkout so the number can only come from the table; the
# precedence ladder above that row is `orch-env`'s, and `orch_env.sh` drives it
# variable-agnostically. That pointer is pinned at the foot of this file, so it
# cannot rot in silence the way a prose pointer does. What is here is the
# document side — the identifiers each site must carry, and the two counting
# invariants a token check cannot state.
#
# NOT covered, and left uncovered on purpose:
#
#   * That § 6.1 states the cap as which ACTIONS are allowed rather than where
#     to jump — the disposition unconditional at the cap, only the fix stopping.
#     One sentence, carrying no token the reply-form pins do not already read.
#   * The at-cap step order (file, then delegate the exception, then reply) and
#     the fix set's single definition. Both are orderings inside one markdown
#     paragraph, which `order` reads by line and cannot resolve.
#   * That no downstream carrier re-derives the fix set. The predecessor read
#     it by counting the phrase `fix set` in a prose region; a count of a
#     phrase is a sentence pin wearing a number.
#   * That § 6.1 reads the cap before it delegates. `order` compares first
#     matches across a whole file, and `<delegation_format>` first appears far
#     ahead of § 6.1 in the same file, so the comparison would answer about the
#     wrong pair.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

CM="$SKILL_DIR/workflows/review-pr-comments.md"
SUBMIT="$SKILL_DIR/workflows/submit-pr.md"
DISP="$SKILL_DIR/references/finding-disposition.md"
CAP="### 6.1 Delegate Fixes"
LOOP="### 6.3 Re-Triage Or Exit"
COUNTER='increment [ISSUE_ID] pr_comment_review.iterations'
# `iterations >= 5`, `max 5` — the hardcoded shape the setting replaced.
LITERAL_BOUND='(iterations?[^A-Za-z0-9_]*(>=|<=|==|>|<)[[:space:]]*[0-9]|max[-[:space:]]+[0-9])'

echo "=== orch external review-round cap lint ==="

# Where the cap is declared to whoever has to set it.
# The default is named in this file's own header, so it is pinned here rather
# than transcribed: changing the README row reddens the header that states it.
rule "the README table documents the cap and its default" \
  "$SKILL_DIR/README.md" "" '`REVIEW_MAX_EXTERNAL_ROUNDS`' '| `4` |'
rule "the settings example seeds the cap" \
  "$SKILL_DIR/kendex.settings.toml.example" "" 'REVIEW_MAX_EXTERNAL_ROUNDS ='
rule "finding-disposition names the counter and the cap that bounds it" \
  "$DISP" "" '`pr_comment_review.iterations`' '`REVIEW_MAX_EXTERNAL_ROUNDS`'

# The cap is a setting, read once, in the section that decides the fix, and
# resolved through the `workflow-state cap` table beside REVIEW_MAX_CYCLES
# rather than written into two workflows as a literal. A literal bound put back
# is the shape the setting replaced, and it is the earlier site that silently
# wins when two disagree. Reading it through `cap` is also what makes the two
# sites share one comparison: the verdict is the table's, not each caller's.
rule_fenced "§ 6.1 resolves the cap through the cap table" "$CM" "$CAP" \
  'workflow-state cap REVIEW_MAX_EXTERNAL_ROUNDS'
rule_fenced "submit-pr's Restart check resolves the same setting" "$SUBMIT" "" \
  'workflow-state cap REVIEW_MAX_EXTERNAL_ROUNDS'
rule "the cap's three reply forms are named where it is stated" "$CM" "$CAP" \
  '`Tracked: [ISSUE_ID]`' '`Fixed in [SHA]`' '`Declined: [REASON]`'
rule "the rule's home states the introduced-or-armed exception" \
  "$DISP" "" 'introduces or arms' '`REVIEW_MAX_EXTERNAL_ROUNDS`'
absent "§ 6.1 carries no literal bound on iterations" "$CM" "$CAP" \
  "$LITERAL_BOUND" 'Stop once `iterations >= 5`.'
absent "submit-pr carries no literal bound on iterations" "$SUBMIT" "" \
  "$LITERAL_BOUND" 'The triage pass stops at `iterations >= 5`.'

# § 6.2's audit returns where it is told, and its usual target is § 6.3. On the
# cap path that skips the exception's delegation entirely: the pass files the
# issue, lands in § 6.3, counts the round and exits, and the introduced defect
# the exception requires it to fix is never delegated.
rule "the cap path records the audit's return to § 6.1" "$CM" "$CAP" '`→ § 6.1`'

# § 6.3 counts the round and decides the loop; the cap is § 6.1's. Re-applying
# it here is what let the at-cap path exit ahead of the late-thread fetch, and
# a late thread nobody fetches is never analyzed, replied to, or resolved.
absent "§ 6.3 leaves the cap to § 6.1" "$CM" "$LOOP" \
  'REVIEW_MAX_EXTERNAL_ROUNDS' 'At `REVIEW_MAX_EXTERNAL_ROUNDS` exit here.'
rule_fenced "§ 6.3 fetches late threads on every path out of the round" \
  "$CM" "$LOOP" 'github.sh pr-threads [PR_NUMBER] --unresolved'

# submit-pr's two named structures. The Restart check is the single decision
# point every path that would restart the wait passes through; the re-submit
# set is what keeps the cap's denied fix from landing anyway through the issue
# path one step later.
rule "submit-pr carries the Restart check" "$SUBMIT" "## 4. Review Gate" '**Restart check.**'
rule "submit-pr defines the re-submit set against the cap" \
  "$SUBMIT" "## 3. Async Comment Triage" '**re-submit set**' '`REVIEW_MAX_EXTERNAL_ROUNDS`'
rule "the Restart check bounds the restart on the cap" \
  "$SUBMIT" "## 4. Review Gate" '`REVIEW_MAX_EXTERNAL_ROUNDS`' 'restart step 1'
rule "the Restart check presents its three options at the cap" \
  "$SUBMIT" "## 4. Review Gate" '`Triage again`' '`Force merge`' '`Stop here`'

# --- the two counting invariants ------------------------------------------
# Neither is a token: one is a count across a directory, the other a
# containment. `check` carries no automatic control, so each gets its own
# probe below.

# counter_writers FILE... — "basename:count" per file holding the increment,
# counting OCCURRENCES rather than matching lines. `grep -c` counts lines, so
# two increments written on one line reported as one writer and the counter
# advanced twice per pass behind a green guard — which is the whole of what
# this invariant exists to catch.
counter_writers() {
  grep -oF -- "$COUNTER" "$@" 2>/dev/null \
    | sed 's|.*/||' | cut -d: -f1 | LC_ALL=C sort | uniq -c \
    | awk '{ print $2 ":" $1 }' || true
}
# Two callers incrementing the counter spend two units per round, and the
# documented four-round budget is silently halved.
check "the round counter has exactly one writer" \
  test "$(counter_writers "$SKILL_DIR"/workflows/*.md)" = 'review-pr-comments.md:1'

# restart_region FILE — submit-pr's Restart check, from its bold label to the
# next bold label or heading at the same indent.
restart_region() {
  awk '/^   \*\*Restart check\.\*\*/ { on = 1; print; next } on && (/^   \*\*/ || /^#/) { on = 0 } on' "$1"
}
# occurrences PATTERN FILE — every occurrence, not every matching line. This
# invariant is a containment, which line counting answers correctly since a
# line sits either inside the region or outside it; occurrences are used anyway
# so both counting invariants in this file read the same way and neither
# invites the question again.
occurrences() { grep -oF -- "$1" | wc -l | tr -d ' '; }
# A standing changes_requested verdict outlives a disposition, so a restart arm
# that goes around the check returns that same verdict and triages past the cap
# forever.
restarts_all_checked() {
  local total inside
  total="$(occurrences 'restart step 1' <"$1" || true)"
  inside="$(restart_region "$1" | occurrences 'restart step 1' || true)"
  [ "$total" -ge 1 ] && [ "$total" -eq "$inside" ]
}
check "every restart of the wait is the Restart check's own" \
  restarts_all_checked "$SUBMIT"

# Teeth for both, each planting the shape its invariant forbids. The writer
# duplicate is planted on ONE LINE, in the file that legitimately holds the
# only writer: a control planting it in a second file would be killed by the
# line-counting method this rule just replaced, and would certify the method
# rather than the contract.
PROBE="$MD_TMP/probe"
mkdir -p "$PROBE"
cp "$SKILL_DIR"/workflows/*.md "$PROBE/"
# awk with index(), not sed: the counter carries `[ISSUE_ID]`, which a BRE
# reads as a character class rather than as the literal it is.
md_tok="$COUNTER" awk '
  BEGIN { tok = ENVIRON["md_tok"] }
  !done_ && index($0, tok) { print $0 "; ws " tok; done_ = 1; next }
  { print }
' "$SKILL_DIR/workflows/review-pr-comments.md" >"$PROBE/review-pr-comments.md"
check "the writer probe planted a same-line duplicate" \
  test "$(occurrences "$COUNTER" <"$PROBE/review-pr-comments.md")" \
     -eq "$(( $(occurrences "$COUNTER" <"$SKILL_DIR/workflows/review-pr-comments.md") + 1 ))"
check "the writer count flags a second writer on one line" \
  test "$(counter_writers "$PROBE"/*.md)" != 'review-pr-comments.md:1'

cp "$SUBMIT" "$PROBE/restart-arm.md"
printf '\n   Verdict cleared, then restart step 1.\n' >>"$PROBE/restart-arm.md"
check "the containment check flags a restart arm outside the check" \
  test -z "$(restarts_all_checked "$PROBE/restart-arm.md" && echo held)"

# --- the header's runtime pointer -------------------------------------------
# The header sends a reader to `workflow-state-cycle-cap.sh` for the cap's row
# and says that suite resolves it from a settings-free checkout. Both halves rot
# without a symptom, and dropping the checkout is the quiet one: this repo's
# `kendex.settings.toml` names the setting at the table's own number, so a
# resolution run here passes over a default the table never supplied. What is
# pinned is the pointer and nothing else — what the row must BE is that suite's
# assertion, and re-deriving it here would put back the duplication this file
# just shed.
CYCLE_CAP="$SKILL_DIR/tests/workflow-state-cycle-cap.sh"

# resolution_root FILE — the directory a `cap REVIEW_MAX_EXTERNAL_ROUNDS`
# resolution runs in, read off the `cd` on that same line, or empty. The name is
# read rather than spelled, so renaming that suite's local variable does not
# redden this check. awk with index() taking the FIRST `cd "`: a greedy regex
# would answer about the last one on the line.
resolution_root() {
  awk '
    index($0, "cap REVIEW_MAX_EXTERNAL_ROUNDS") {
      p = index($0, "cd \"")
      if (p == 0) next
      rest = substr($0, p + 4)
      q = index(rest, "\"")
      if (q == 0) next
      print substr(rest, 1, q - 1)
      exit
    }
  ' "$1"
}
# The pointer holds when that root is one the suite makes itself with `git init`.
pointer_holds() {
  local file="$1" root
  [ -f "$file" ] || return 1
  root="$(resolution_root "$file")"
  [ -n "$root" ] || return 1
  line_has "$(cat "$file")" 'git init' "$root"
}
check "the header's pointer names a suite resolving the cap outside this repo's settings" \
  pointer_holds "$CYCLE_CAP"

# Teeth, one per claim the pointer makes. `check` carries no automatic control.
PTR="$MD_TMP/pointer"
mkdir -p "$PTR"

# The named suite renamed out from under the header, or deleted.
check "the rename control names a path that is not there" test ! -f "$PTR/renamed.sh"
check "the pointer check flags a suite the header can no longer reach" \
  test -z "$(pointer_holds "$PTR/renamed.sh" && echo held)"

# The external-cap block deleted, the rest of the suite intact.
awk '/^# --- the external round cap/ { skip = 1 }
     skip && /^# One table, one default/ { skip = 0 }
     !skip' "$CYCLE_CAP" >"$PTR/no-block.sh"
check "the block control planted a deletion" \
  test "$(grep -cF 'cap REVIEW_MAX_EXTERNAL_ROUNDS' "$PTR/no-block.sh")" -lt \
       "$(grep -cF 'cap REVIEW_MAX_EXTERNAL_ROUNDS' "$CYCLE_CAP")"
check "the pointer check flags the named suite losing its external-cap block" \
  test -z "$(pointer_holds "$PTR/no-block.sh" && echo held)"

# The settings-free root dropped, the assertion left standing: the regression
# that keeps both that suite and this header green over a proof of nothing. The
# `cd` is stripped by the root's own name, so a rename does not stop the plant.
md_root="$(resolution_root "$CYCLE_CAP")" awk '
  BEGIN { tok = "cd \"" ENVIRON["md_root"] "\" && " }
  !done_ && index($0, "cap REVIEW_MAX_EXTERNAL_ROUNDS") && index($0, tok) {
    p = index($0, tok)
    print substr($0, 1, p - 1) substr($0, p + length(tok))
    done_ = 1
    next
  }
  { print }
' "$CYCLE_CAP" >"$PTR/no-root.sh"
check "the root control planted a stripped cd" \
  test -n "$(cmp -s "$PTR/no-root.sh" "$CYCLE_CAP" || echo planted)"
check "the pointer check flags a resolution run in this checkout" \
  test -z "$(pointer_holds "$PTR/no-root.sh" && echo held)"

md_report
