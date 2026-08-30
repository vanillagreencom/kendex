#!/usr/bin/env bash
# Regression lint: a root cause that recurs at a new site ends the patch
# sequence, and the check runs before the round cap.
#
# The spiral it closes: a round meets a new site of one cause, a fix round
# answers it, the next round meets the next site, and the diff outgrows the
# reported symptom while the cap, which counts rounds, sees nothing wrong.
# Derive the shape of a PR that ran that way rather than transcribing counts
# into this header, where nothing rechecks them:
#
#   gh pr view [N] --json commits \
#     --jq '[.commits[].messageHeadline | select(startswith("Address PR review"))] | length'
#   gh api repos/[OWNER]/[REPO]/pulls/[N]/reviews --jq '.[0].commit_id'
#   git diff --shortstat [THAT_COMMIT] HEAD
#
# The rule has one home, `references/finding-disposition.md` § Recurrence, and
# two routers: `workflows/review-pr-comments.md`, pinned below, and
# `workflows/review-pr.md`, pinned in `review-disposition-by-rule-lint.test.sh`
# alongside the rest of that twin's contract. `workflows/oversee.md`
# § End spirals points at the section instead of restating it. Every assertion
# pins a token — a heading, an inline code literal, a state field, a link
# anchor — so a reworded sentence never reddens the suite.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
DISPOSITION="$SKILL_DIR/references/finding-disposition.md"
COMMENTS_WF="$SKILL_DIR/workflows/review-pr-comments.md"
DEV_FIX_WF="$SKILL_DIR/workflows/dev-fix.md"
OVERSEE_WF="$SKILL_DIR/workflows/oversee.md"
STATE_SCHEMA="$SKILL_DIR/schemas/workflow-state.md"
ORCH_SKILL="$SKILL_DIR/SKILL.md"
MERGE_WF="$SKILL_DIR/workflows/merge-pr.md"
DEV_SKILL="$(cd "$SKILL_DIR/../dev" && pwd)/SKILL.md"
PREDICATE="$(cd "$SKILL_DIR/../review-gate/scripts" && pwd)/review-predicate.sh"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== orch recurrence/freeze lint ==="

# HTML comment regions are stripped from EVERY line before any section gate or
# token check, so a rule commented out is a rule deleted as far as this lint is
# concerned. A comment opened above a heading blanks the heading too and the
# section never opens. Same helper as the sibling orch lints.
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

recurrence_section() { strip_comments "$1" | awk '/^## Recurrence$/{on=1;next} /^## /{on=0} on'; }
round_contract() { strip_comments "$1" | awk '/^## Round Contract$/{on=1;next} /^## /{on=0} on'; }
merge_close_step() { strip_comments "$1" | awk '/^2\. \*\*Sync the tracker/{on=1} /^3\. \*\*Sync the main repo/{on=0} on'; }
section_6_head() { strip_comments "$1" | awk '/^## 6\./{on=1} /^### 6\.1/{on=0} on'; }
section_6_1() { strip_comments "$1" | awk '/^### 6\.1/{on=1;next} /^### 6\.2/{on=0} on'; }
section_6_3() { strip_comments "$1" | awk '/^### 6\.3/{on=1;next} /^## 7\./{on=0} on'; }
signals_route() { strip_comments "$1" | grep -E '^\| .+ \| § Recurrence' || true; }

# Every grep reads a herestring, never a pipe: `grep -q` exits at the first
# match, a pipe would deliver SIGPIPE to awk, and `pipefail` would promote its
# 141 into a failed check for a contract that is present.
check_token() {
  # $1 = file, $2 = literal token, $3 = label
  if grep -qF -- "$2" <<<"$(strip_comments "$1")"; then pass "$3"; else fail "$3"; fi
}

check_section_token() {
  # $1 = file, $2 = literal token, $3 = label
  if grep -qF -- "$2" <<<"$(recurrence_section "$1")"; then pass "$3"; else fail "$3"; fi
}

# --- the rule -----------------------------------------------------------
check_token "$DISPOSITION" '## Recurrence' \
  "finding-disposition.md carries the Recurrence section"
check_section_token "$DISPOSITION" '`structural-close`' \
  "Recurrence names the structural-close disposition"
check_section_token "$DISPOSITION" '`freeze`' \
  "Recurrence names the freeze disposition"
check_section_token "$DISPOSITION" '`Tracked: <ID>`' \
  "Recurrence binds freeze to a Tracked reply"
check_section_token "$DISPOSITION" '`decline`' \
  "Recurrence declines a later finding on a frozen cause"

# The trigger is a cause a prior round PATCHED, and `patched_causes` is the
# record that says so: its entries carry the normalized cause, which is the
# question the trigger asks and the one `fixed_items` cannot answer. A cause
# merely answered, a decline or a filing, has no patch sequence to end and
# stays with the decision flow, whose heading is the token that names it.
check_section_token "$DISPOSITION" '`patched_causes`' \
  "Recurrence triggers on the cause patched_causes records, not any answered one"
check_section_token "$DISPOSITION" 'decision flow' \
  "Recurrence routes a never-patched cause back to the decision flow"

# The introduced-defect carve-out: freeze cannot answer a defect this diff
# introduced or armed, which is the rule the rest of the stack assumes.
SECTION="$(recurrence_section "$DISPOSITION")"
if grep -qF 'introduces' <<<"$SECTION" && grep -qF 'arms' <<<"$SECTION"; then
  pass "Recurrence carries the introduced-or-armed carve-out"
else
  fail "Recurrence lost the introduced-or-armed carve-out"
fi

if [[ -n "$(signals_route "$DISPOSITION")" ]]; then
  pass "the signals table routes a recurring root cause to § Recurrence"
else
  fail "the signals table lost its route to § Recurrence"
fi

# --- the router, and the order that gives it force ----------------------
check_token "$COMMENTS_WF" '../references/finding-disposition.md#recurrence' \
  "review-pr-comments.md § 5 links the Recurrence section"

# Line numbers come from the STRIPPED stream, so a commented-out line is not a
# line and the comparison stays like for like. No `head`, whose SIGPIPE would
# reach grep and trip pipefail.
first_line() {
  local out
  out=$(grep -nF -- "$2" <<<"$(strip_comments "$1")" || true)
  [[ -n "$out" ]] || return 0
  printf '%s' "${out%%$'\n'*}" | cut -d: -f1
}

check_order() {
  local router cap
  router="$(first_line "$1" 'finding-disposition.md#recurrence')"
  cap="$(first_line "$1" 'REVIEW_MAX_EXTERNAL_ROUNDS')"
  [[ -n "$router" && -n "$cap" ]] || { printf 'missing\n'; return; }
  if [[ "$router" -lt "$cap" ]]; then printf 'before\n'; else printf 'after\n'; fi
}

case "$(check_order "$COMMENTS_WF")" in
  before) pass "the recurrence check is routed ahead of the iterations cap" ;;
  after)  fail "the recurrence check now sits behind the iterations cap" ;;
  *)      fail "review-pr-comments.md lost the recurrence router or the iterations cap" ;;
esac

# --- what consumes the rule ---------------------------------------------
# The auto-fix skip list carries the bucket name as an inline literal, which
# is where the backticked spelling occurs; the table heading below is plain.
check_token "$COMMENTS_WF" '`RECURRENCE`' \
  "a recurrence item is excluded from the auto-fix bucket"
check_token "$COMMENTS_WF" '### ♻️ RECURRENCE' \
  "§ 5's triage report has a RECURRENCE bucket"

# Membership, not branches: what may be fixed is one set, and the gate that
# opens the delegation reads that set rather than the Fixing rows alone.
ELIGIBILITY="$(section_6_head "$COMMENTS_WF")"
for token in '`fix set`' '`structural-close`' '`reply-only`' '`freeze`' '`declined`'; do
  if grep -qF "$token" <<<"$ELIGIBILITY"; then
    pass "§ 6 states eligibility in terms of $token"
  else
    fail "§ 6 no longer states eligibility in terms of $token"
  fi
done
# The three passes the routing used to break, each read off the named set by
# the step that acts on it rather than re-derived there.
SIX_ONE="$(section_6_1 "$COMMENTS_WF")"
if grep -qF '[For each item in the fix set:]' <<<"$SIX_ONE" \
   && ! grep -qF '[For each item marked "Fixing":]' <<<"$SIX_ONE"; then
  pass "a structural-close-only pass delegates the fix set, not the Fixing rows"
else
  fail "the delegation re-derives its own membership instead of reading the fix set"
fi

GATE="$(grep -F '`fix set` is empty' <<<"$SIX_ONE" || true)"
if [[ -n "$GATE" ]] && grep -qF '`reply step`' <<<"$GATE"; then
  pass "a declined-only pass reaches the reply step"
else
  fail "an empty fix set no longer routes the pass to the reply step"
fi

if grep -qF '**Reply step.**' <<<"$(section_6_3 "$COMMENTS_WF")"; then
  pass "the reply step closes the pass, downstream of the section that files"
else
  fail "the reply step is no longer where the pass closes"
fi

# One ordered obligation set, stated once in § 6's preamble and performed by
# the order the subsections appear in. The routing it replaced named a jump
# target per call site and leaked at whichever site the next pass took.
HEAD="$(section_6_head "$COMMENTS_WF")"
while IFS='|' read -r token label; do
  if grep -qF -- "$token" <<<"$HEAD"; then
    pass "§ 6 states as an obligation that $label"
  else
    fail "§ 6 no longer states that $label"
  fi
done <<'OBLIGATIONS'
`reply step`|every pass reaches one reply step
mixed|a mixed pass owes what every other pass owes
§ 6.2|a class issue is filed before the reply naming it
frozen_causes|a frozen cause is recorded before the reply closing its thread
patched_causes|a patched cause is recorded before the reply closing its thread
OBLIGATIONS

# Document order is what performs obligation 1: a `Tracked:` body names an id
# the pass has already filed only while the section that files precedes the one
# reply step. Stated in prose and contradicted by the layout, it read as an
# order the document did not execute, and a freeze or mixed pass replied first.
doc_order() {
  # $1 = file — `before` when issue creation precedes the reply step
  local create reply
  create="$(first_line "$1" '### 6.2 Create Issues')"
  reply="$(first_line "$1" '**Reply step.**')"
  [[ -n "$create" && -n "$reply" ]] || { printf 'missing\n'; return; }
  if [[ "$create" -lt "$reply" ]]; then printf 'before\n'; else printf 'after\n'; fi
}

case "$(doc_order "$COMMENTS_WF")" in
  before) pass "issue creation precedes the reply step in document order" ;;
  after)  fail "the reply step sits ahead of the section that files the class issue" ;;
  *)      fail "review-pr-comments.md lost its issue-creation section or its reply step" ;;
esac

# The two records the recurrence check reads. A resolved thread is invisible to
# the next pass, so a cause is recurrence only if a pass wrote it down.
check_token "$COMMENTS_WF" "--slurpfile entry [WORKTREE_PATH]/tmp/patched-cause-[ISSUE_ID].json" \
  "§ 6 records a patched cause in workflow state"
check_token "$COMMENTS_WF" "--slurpfile entry [WORKTREE_PATH]/tmp/frozen-cause-[ISSUE_ID].json" \
  "§ 6 records a frozen cause in workflow state"

# The other writer of the record § 5 reads. The comment loop fills it from its
# own reply step; the pr-review, qa-review, and review rounds reach it through
# `dev-fix.md` § 2, whose write is the only thing standing between those loops
# and a recurrence check reading an empty history. Structural: the command is
# present at that step.
check_token "$DEV_FIX_WF" "--slurpfile cause tmp/patched-cause-[ISSUE_ID].json" \
  "dev-fix.md § 2 records a patched cause in workflow state"

# Reviewer text never crosses argv: no cause is appended as an inline literal.
if grep -qE 'append \[ISSUE_ID\] pr_comment_review\.(patched|frozen)_causes' <<<"$(strip_comments "$COMMENTS_WF")"; then
  fail "a cause write puts reviewer text back on the command line"
else
  pass "neither cause write puts reviewer text on the command line"
fi

# The documented channel, executed rather than described: a cause carrying an
# apostrophe and one carrying a double quote must reach the store intact. The
# write lands after the thread is resolved, so a write that dies on the text
# leaves a closed thread and nothing remembered.
WFS="$SKILL_DIR/scripts/workflow-state"
STATE_DIR="$TMP_ROOT/state"
if [[ -x "$WFS" ]]; then
  mkdir -p "$STATE_DIR"
  "$WFS" --state-dir "$STATE_DIR" init KEN-0 --agent generalist --worktree "$TMP_ROOT" >/dev/null
  for probe in "don't patch it twice" 'the "same" cause again'; do
    jq -nc --arg c "$probe" '{cause: $c, commit: "abc123f"}' > "$TMP_ROOT/entry.json"
    "$WFS" --state-dir "$STATE_DIR" update KEN-0 --slurpfile entry "$TMP_ROOT/entry.json" \
      '$entry[0] as $e | .pr_comment_review.patched_causes = ((.pr_comment_review.patched_causes // []) + [$e])' >/dev/null
  done
  STORED="$("$WFS" --state-dir "$STATE_DIR" get KEN-0 '[.pr_comment_review.patched_causes[].cause] | join("|")')"
  if [[ "$STORED" == *"don't patch it twice"* && "$STORED" == *'the "same" cause again'* ]]; then
    pass "a cause carrying an apostrophe and one carrying a double quote survive the write"
  else
    fail "the file channel lost a quoted cause: $STORED"
  fi
else
  fail "workflow-state is not executable at $WFS — the channel check cannot run"
fi
check_token "$COMMENTS_WF" ".pr_comment_review.patched_causes // []" \
  "§ 5 reads the patched causes before triaging a pass"
check_token "$COMMENTS_WF" ".pr_comment_review.frozen_causes // []" \
  "§ 5 reads the frozen causes before triaging a pass"
for token in patched_causes frozen_causes; do
  check_token "$STATE_SCHEMA" "$token" "the workflow-state schema documents $token"
done

# One home: oversee.md points at the section instead of restating the rule.
# A second statement names its branches, whatever words carry it.
check_token "$OVERSEE_WF" '../references/finding-disposition.md#recurrence' \
  "oversee.md § End spirals points at the Recurrence section"
if grep -qE 'structural-close|`freeze`|Tracked:' <<<"$(strip_comments "$OVERSEE_WF")"; then
  fail "oversee.md states the dispositions itself instead of pointing at them"
else
  pass "oversee.md keeps no second statement of the rule"
fi

# --- a freeze never covers what the diff did (KEN-890) -------------------
# The rule the freeze audit found stated twice and applied nowhere. Three
# documents say it and one step enforces it, so all four are pinned here.
# The load-bearing literal is the phrase that IS the rule — rewording it
# away is rewording the rule away, which is the whole failure mode: the
# restriction existed under the name `freeze` while the declines that
# shipped the defects were written `Declined:`.
ADDED_LINE='a line this diff added'

check_region_token() {
  # $1 = extractor, $2 = file, $3 = literal token, $4 = label
  if grep -qF -- "$3" <<<"$("$1" "$2")"; then pass "$4"; else fail "$4"; fi
}

check_region_token recurrence_section "$DISPOSITION" "$ADDED_LINE" \
  "Recurrence states the rule as the diff's own added line"
check_section_token "$DISPOSITION" '`Declined:`' \
  "Recurrence names Declined: as the second carrier of a freeze"
check_section_token "$DISPOSITION" 'merge-pr.md' \
  "Recurrence names the step that enforces the rule"

check_region_token round_contract "$DEV_SKILL" "$ADDED_LINE" \
  "the dev round contract carries the rule"
check_region_token round_contract "$DEV_SKILL" '`Declined:`' \
  "the dev round contract names the reply form it forbids"
check_region_token round_contract "$DEV_SKILL" 'finding-disposition.md#recurrence' \
  "the dev round contract points at the one home of the rule"

check_token "$ORCH_SKILL" "$ADDED_LINE" \
  "orch SKILL.md's reply-form rule carries the same line"
check_region_token section_6_3 "$COMMENTS_WF" "$ADDED_LINE" \
  "the reply step carries the same line where the reply is written"

# The enforcement, which is what makes this different from the two earlier
# statements of the rule: a command, its exit routes, and its position ahead
# of the tracker write it gates.
check_region_token merge_close_step "$MERGE_WF" '--declined-on-added-lines' \
  "merge-pr's close step runs the check"
check_region_token merge_close_step "$MERGE_WF" '**Do not close.**' \
  "the close step refuses on the check's refusal"
check_region_token merge_close_step "$MERGE_WF" 'do not claim tracker completion' \
  "the close step refuses on an unreadable read too"

check_gate_order() {
  # $1 = file — `before` when the check precedes the tracker write it gates
  local checked closed
  checked="$(first_line "$1" '--declined-on-added-lines')"
  closed="$(first_line "$1" 'linear.sh issues complete')"
  [[ -n "$checked" && -n "$closed" ]] || { printf 'missing\n'; return; }
  if [[ "$checked" -lt "$closed" ]]; then printf 'before\n'; else printf 'after\n'; fi
}

case "$(check_gate_order "$MERGE_WF")" in
  before) pass "the check runs before the tracker write it gates" ;;
  after)  fail "the check now runs after the issue is already closed" ;;
  *)      fail "merge-pr.md lost the check or the tracker write" ;;
esac

# The check itself, not only its callers: a workflow calling a flag the
# script does not implement is the same hole as no check at all.
if [[ -x "$PREDICATE" ]] && "$PREDICATE" --help 2>/dev/null | grep -qF -- '--declined-on-added-lines'; then
  pass "review-predicate.sh implements and documents the flag the close step runs"
else
  fail "review-predicate.sh does not answer --declined-on-added-lines"
fi

# --- planted controls: prove each check can fail -------------------------
echo
echo "--- planted controls ---"

# Every mutation below is derived from the token or the structure the live
# assertion reads — substitute that token, or delete the region it matches —
# never from a sentence. A control written against prose goes stale on the
# first harmless rewording and then reports a lint miss for an intact rule.
#
# A program that matches nothing leaves the fixture identical to its source,
# which is that same failure. These run inside a command substitution, where an
# increment to FAIL would die with the subshell, so the note goes to a file the
# parent reads back.
UNPLANTED="$TMP_ROOT/unplanted"
: > "$UNPLANTED"
note_unplanted() { printf 'control %s planted nothing — its program matched no text\n' "$1" >> "$UNPLANTED"; }

plant() {
  # $1 = control name, $2 = source file, $3 = sed program, $4 = awk instead
  local scratch="$TMP_ROOT/$1.md"
  if [[ -n "${4:-}" ]]; then awk "$3" "$2" > "$scratch"; else sed "$3" "$2" > "$scratch"; fi
  cmp -s "$scratch" "$2" && note_unplanted "$1"
  printf '%s' "$scratch"
}

gone() {
  # $1 = extractor, $2 = fixture, $3 = token that must be gone, $4 = label
  if grep -qF -- "$3" <<<"$("$1" "$2")"; then fail "lint MISSED $4"; else pass "lint flags $4"; fi
}

drop() {
  # $1 = control name, $2 = source file, $3 = token to substitute away
  plant "$1" "$2" "s/$(sed 's/[][\\.*^$\/&]/\\&/g' <<<"$3")/REDACTED/g"
}

gone strip_comments "$(plant heading "$DISPOSITION" 's/^## Recurrence$/## Repeat findings/')" \
  '## Recurrence' "a renamed Recurrence section"
gone recurrence_section "$(drop freeze "$DISPOSITION" '`freeze`')" \
  '`freeze`' "a dropped freeze disposition"
gone recurrence_section "$(drop tracked "$DISPOSITION" '`Tracked: <ID>`')" \
  '`Tracked: <ID>`' "a dropped Tracked reply form"
gone recurrence_section "$(drop declined "$DISPOSITION" '`decline`')" \
  '`decline`' "a frozen cause that files again instead of declining"
gone recurrence_section "$(drop trigger "$DISPOSITION" '`patched_causes`')" \
  '`patched_causes`' "a trigger cut loose from the record that proves a patch"
gone cat "$(drop devfix-cause "$DEV_FIX_WF" '--slurpfile cause tmp/patched-cause-[ISSUE_ID].json')" \
  '--slurpfile cause tmp/patched-cause-[ISSUE_ID].json' \
  "a dropped dev-fix cause write, which blinds both readers"

# Two tokens, so two fixtures: dropping either must redden the carve-out.
for token in introduces arms; do
  CTRL="$(drop "carveout-$token" "$DISPOSITION" "$token")"
  SECTION="$(recurrence_section "$CTRL")"
  if grep -qF 'introduces' <<<"$SECTION" && grep -qF 'arms' <<<"$SECTION"; then
    fail "lint MISSED a carve-out with $token dropped"
  else
    pass "lint flags a carve-out with $token dropped"
  fi
done

# Scoping control: the tokens must be pinned INSIDE § Recurrence. A `freeze`
# elsewhere in the file must not stand in for the rule.
CTRL="$(plant scope "$DISPOSITION" 's/^## Recurrence$/## Recurrence\n\nSee below.\n\n## Elsewhere\n\nUse `freeze` and `structural-close` when it suits./')"
if grep -qF '`freeze`' <<<"$(recurrence_section "$CTRL")"; then
  fail "lint false-passed on a freeze token outside § Recurrence"
else
  pass "lint scopes its disposition tokens to § Recurrence"
fi

# Blanket control: delete the whole region the assertion matches.
CTRL="$(plant row "$DISPOSITION" '/^| .* | § Recurrence/d')"
if [[ -n "$(signals_route "$CTRL")" ]]; then
  fail "lint MISSED a signals row that answers recurrence with another fix"
else
  pass "lint flags a signals row that answers recurrence with another fix"
fi

# The inert form: the rule left in place but commented out. The section
# assertions must go red on their own, not through an unplanted note.
CTRL="$(plant inert "$DISPOSITION" '/^## Recurrence$/ && !opened { print "<!--"; opened = 1 } /^## Filing bar$/ && opened && !closed { print "-->"; closed = 1 } { print }' awk)"
if grep -qF '<!--' "$CTRL" && grep -qF -- '-->' "$CTRL"; then
  gone recurrence_section "$CTRL" '`freeze`' "a commented-out Recurrence section"
else
  fail "control inert planted no comment markers"
fi

gone strip_comments "$(plant router "$COMMENTS_WF" 's|/finding-disposition.md#recurrence|/finding-disposition.md|g')" \
  '../references/finding-disposition.md#recurrence' "a dropped Recurrence router link"

# EVERY router line, not the first: § 6.3 carries a second one, and one
# router left live is a router — the control has to remove the route, not a
# copy of it.
CTRL="$(plant inertrouter "$COMMENTS_WF" '/finding-disposition\.md#recurrence/ { print "<!--"; print; print "-->"; next } { print }' awk)"
if grep -qF '<!--' "$CTRL"; then
  gone strip_comments "$CTRL" '../references/finding-disposition.md#recurrence' "a commented-out router paragraph"
else
  fail "control inertrouter planted no comment markers"
fi

# Order control: the line carrying the router token, moved behind the cap line.
CTRL="$(plant order "$COMMENTS_WF" '/finding-disposition\.md#recurrence/ && !moved { saved = $0; moved = 1; next } { print } /REVIEW_MAX_EXTERNAL_ROUNDS/ && moved && !placed { print ""; print saved; placed = 1 }' awk)"
case "$(check_order "$CTRL")" in
  after) pass "lint flags a recurrence check moved behind the iterations cap" ;;
  *)     fail "lint MISSED a recurrence check moved behind the iterations cap" ;;
esac

gone strip_comments "$(drop autofix "$COMMENTS_WF" '`RECURRENCE`')" \
  '`RECURRENCE`' "an auto-fix bucket that swallows recurrence items again"
gone section_6_head "$(drop fixset "$COMMENTS_WF" '`fix set`')" \
  '`fix set`' "an eligibility rule with no fix set"
gone section_6_1 "$(drop gate "$COMMENTS_WF" '`fix set`')" \
  '`fix set`' "a § 6.1 gate that stopped reading the fix set"
gone section_6_head "$(drop replyonly "$COMMENTS_WF" '`reply-only`')" \
  '`reply-only`' "a freeze or decline let into the push path"
gone section_6_1 "$(plant delegation "$COMMENTS_WF" 's/\[For each item in the fix set:\]/[For each item marked "Fixing":]/')" \
  '[For each item in the fix set:]' "a delegation that re-derives membership from Fixing rows"
# The obligation controls: each precondition of the reply, planted back out of
# § 6's preamble. Dropping § 6.2 is the mixed pass the routing lost — a fix set
# and a freeze row together, reaching the reply owing a `Tracked:` id nothing
# filed. Dropping either cause field is a thread closed with nothing remembered.
gone section_6_head "$(drop obligationfile "$COMMENTS_WF" '§ 6.2')" \
  '§ 6.2' "a mixed pass that replies with a class issue nothing filed"
for token in frozen_causes patched_causes; do
  gone section_6_head "$(drop "obligation-$token" "$COMMENTS_WF" "$token")" \
    "$token" "a reply that closes its thread before $token is written"
done

# Order control: the reply step's own label, lifted back above the section that
# files. That layout is what a freeze or mixed pass read as reply-then-file.
CTRL="$(plant replyorder "$COMMENTS_WF" '{ line[NR] = $0 } END { for (i = 1; i <= NR; i++) { if (!r && line[i] ~ /[*][*]Reply step[.][*][*]/) r = i; if (!c && line[i] ~ /^### 6[.]2 Create Issues/) c = i } for (i = 1; i <= NR; i++) { if (i == r) continue; if (i == c) { print line[r]; print "" } print line[i] } }' awk)"
case "$(doc_order "$CTRL")" in
  after) pass "lint flags a reply step lifted ahead of issue creation" ;;
  *)     fail "lint MISSED a reply step lifted ahead of issue creation" ;;
esac

# One token, two readers: dropping `reply step` must redden the obligation set
# and the § 6.1 gate alike.
CTRL="$(drop replystep "$COMMENTS_WF" '`reply step`')"
if grep -qF '`reply step`' <<<"$(section_6_head "$CTRL")" || grep -qF '`reply step`' <<<"$(section_6_1 "$CTRL")"; then
  fail "lint MISSED a reply step nothing names"
else
  pass "lint flags a reply step nothing names"
fi

gone section_6_3 "$(drop replylabel "$COMMENTS_WF" '**Reply step.**')" \
  '**Reply step.**' "an obligation set naming a reply step the pass never reaches"
gone section_6_head "$(drop obligationmix "$COMMENTS_WF" 'mixed')" \
  'mixed' "an obligation set that leaves the mixed pass out of its row mixes"
gone strip_comments "$(drop patched "$COMMENTS_WF" '/tmp/patched-cause-[ISSUE_ID].json')" \
  '--slurpfile entry [WORKTREE_PATH]/tmp/patched-cause-[ISSUE_ID].json' "a patched cause nothing records"
gone strip_comments "$(drop frozen "$COMMENTS_WF" '/tmp/frozen-cause-[ISSUE_ID].json')" \
  '--slurpfile entry [WORKTREE_PATH]/tmp/frozen-cause-[ISSUE_ID].json' "a freeze that records no cause"

# The inline shape the workflow used to carry, with a real cause substituted:
# bash cannot even parse it, which is the failure the file channel removes.
INLINE="$(printf 'wfs append KEN-0 pr_comment_review.patched_causes '"'"'{"cause":"%s"}'"'"'' "don't patch it twice")"
FILED="$(printf 'wfs update KEN-0 --slurpfile entry %s '"'"'$entry[0] as $e | .x += [$e]'"'"'' "$TMP_ROOT/entry.json")"
if bash -n <<<"$INLINE" 2>/dev/null; then
  fail "control inline parsed — the apostrophe no longer breaks the argv shape"
elif bash -n <<<"$FILED" 2>/dev/null; then
  pass "lint flags the argv shape an apostrophe breaks, and the file shape it replaces parses"
else
  fail "control filed did not parse — the channel comparison is not like for like"
fi

CTRL="$(plant argv "$COMMENTS_WF" '{ print } END { print "`workflow-state append [ISSUE_ID] pr_comment_review.patched_causes ...`" }' awk)"
if grep -qE 'append \[ISSUE_ID\] pr_comment_review\.(patched|frozen)_causes' <<<"$(strip_comments "$CTRL")"; then
  pass "lint flags a cause write moved back onto the command line"
else
  fail "lint MISSED a cause write moved back onto the command line"
fi

for token in patched_causes frozen_causes; do
  gone strip_comments "$(drop "schema-$token" "$STATE_SCHEMA" "$token")" \
    "$token" "an undocumented $token field"
done

gone strip_comments "$(plant oversee "$OVERSEE_WF" 's|/finding-disposition.md#recurrence|/SKILL.md|g')" \
  '../references/finding-disposition.md#recurrence' "an oversee.md pointer that stopped pointing here"

CTRL="$(plant restate "$OVERSEE_WF" '{ print } END { print "- Use `structural-close`, else `freeze`." }' awk)"
if grep -qE 'structural-close|`freeze`|Tracked:' <<<"$(strip_comments "$CTRL")"; then
  pass "lint flags a rule restated in oversee.md"
else
  fail "lint MISSED a rule restated in oversee.md"
fi

# --- controls for the freeze/added-line rule -----------------------------
gone recurrence_section "$(drop rule-disposition "$DISPOSITION" "$ADDED_LINE")" \
  "$ADDED_LINE" "a Recurrence section that stopped naming the diff's own added line"
gone recurrence_section "$(drop rule-declined "$DISPOSITION" '`Declined:`')" \
  '`Declined:`' "a rule that covers freeze but not the Declined: spelling of it"
gone recurrence_section "$(drop rule-enforcer "$DISPOSITION" 'merge-pr.md')" \
  'merge-pr.md' "a rule with no step named as its enforcer"
gone round_contract "$(drop rule-dev "$DEV_SKILL" "$ADDED_LINE")" \
  "$ADDED_LINE" "a dev round contract that dropped the rule"
gone round_contract "$(drop rule-dev-anchor "$DEV_SKILL" 'finding-disposition.md#recurrence')" \
  'finding-disposition.md#recurrence' "a dev round contract cut loose from the rule's one home"
gone strip_comments "$(drop rule-orch "$ORCH_SKILL" "$ADDED_LINE")" \
  "$ADDED_LINE" "an orch reply-form rule that dropped the carve-out"
gone section_6_3 "$(drop rule-reply "$COMMENTS_WF" "$ADDED_LINE")" \
  "$ADDED_LINE" "a reply step that dropped the carve-out where the reply is written"
gone merge_close_step "$(drop rule-check "$MERGE_WF" '--declined-on-added-lines')" \
  '--declined-on-added-lines' "a close step that stopped running the check"
gone merge_close_step "$(drop rule-refuse "$MERGE_WF" '**Do not close.**')" \
  '**Do not close.**' "a close step that runs the check and closes anyway"
gone merge_close_step "$(drop rule-noverdict "$MERGE_WF" 'do not claim tracker completion')" \
  'do not claim tracker completion' "a close step that treats an unreadable read as clean"

# The inert form, the one the two earlier statements of this rule took: the
# step left in place but commented out.
CTRL="$(plant rule-inert "$MERGE_WF" '/--declined-on-added-lines/ && !done { print "<!--"; print; print "-->"; done = 1; next } { print }' awk)"
if grep -qF '<!--' "$CTRL"; then
  gone merge_close_step "$CTRL" '--declined-on-added-lines' "a commented-out close check"
else
  fail "control rule-inert planted no comment markers"
fi

# Order control: the check moved behind the tracker write, which is a check
# that reports on an issue already marked Done.
CTRL="$(plant rule-order "$MERGE_WF" '/--declined-on-added-lines/ && !moved { saved = $0; moved = 1; next } { print } /linear\.sh issues complete/ && moved && !placed { print ""; print saved; placed = 1 }' awk)"
case "$(check_gate_order "$CTRL")" in
  after) pass "lint flags a close check moved behind the tracker write" ;;
  *)     fail "lint MISSED a close check moved behind the tracker write" ;;
esac

while IFS= read -r unplanted_note; do
  [[ -n "$unplanted_note" ]] && fail "$unplanted_note"
done < "$UNPLANTED"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
