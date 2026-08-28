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
# one router, `workflows/review-pr-comments.md`; `workflows/oversee.md`
# § End spirals points at the section instead of restating it. Every assertion
# pins a token — a heading, an inline code literal, a state field, a link
# anchor — so a reworded sentence never reddens the suite.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
DISPOSITION="$SKILL_DIR/references/finding-disposition.md"
COMMENTS_WF="$SKILL_DIR/workflows/review-pr-comments.md"
OVERSEE_WF="$SKILL_DIR/workflows/oversee.md"
STATE_SCHEMA="$SKILL_DIR/schemas/workflow-state.md"
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
branch_table() { strip_comments "$1" | awk '/^## 6\./{on=1} /^### 6\.1/{on=0} on'; }
signals_route() { strip_comments "$1" | grep -E '^\| .+ \| § Recurrence' || true; }

# Every grep reads a herestring, never a pipe: `grep -q` exits at the first
# match, a pipe would deliver SIGPIPE to awk, and `pipefail` would promote its
# 141 into a failed check for a contract that is present.
check_token() {
  # $1 = file, $2 = literal token, $3 = label
  if grep -qF "$2" <<<"$(strip_comments "$1")"; then pass "$3"; else fail "$3"; fi
}

check_section_token() {
  # $1 = file, $2 = literal token, $3 = label
  if grep -qF "$2" <<<"$(recurrence_section "$1")"; then pass "$3"; else fail "$3"; fi
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

# The trigger is a cause a prior round PATCHED, and `fixed_items` is the record
# that says so — every dev-fix round writes its applied items there. A cause
# merely answered, a decline or a filing, has no patch sequence to end and
# stays with the decision flow, whose heading is the token that names it.
check_section_token "$DISPOSITION" '`fixed_items`' \
  "Recurrence triggers on the cause fixed_items records, not any answered one"
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
  out=$(grep -nF "$2" <<<"$(strip_comments "$1")" || true)
  [[ -n "$out" ]] || return 0
  printf '%s' "${out%%$'\n'*}" | cut -d: -f1
}

check_order() {
  local router cap
  router="$(first_line "$1" 'finding-disposition.md#recurrence')"
  cap="$(first_line "$1" 'iterations >= 5')"
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

# Each disposition reaches a branch in § 6.
# A row, not a mention: the § 6 preamble names `freeze` in prose too, and a
# bare token check would survive the row's deletion.
branch_row() { grep -F "| $2 |" <<<"$(branch_table "$1")" || true; }

for token in '`structural-close`' '`freeze`' '`declined`'; do
  if [[ -n "$(branch_row "$COMMENTS_WF" "$token")" ]]; then
    pass "§ 6 branches on $token"
  else
    fail "§ 6 has no branch for $token"
  fi
done

# Freeze's defining property survives the loop only if the cause is on disk.
check_token "$COMMENTS_WF" "workflow-state append [ISSUE_ID] pr_comment_review.frozen_causes" \
  "§ 6 records a frozen cause in workflow state"
check_token "$COMMENTS_WF" ".pr_comment_review.frozen_causes // []" \
  "§ 5 reads the frozen causes before triaging a pass"
check_token "$STATE_SCHEMA" 'frozen_causes' \
  "the workflow-state schema documents frozen_causes"

# One home: oversee.md points at the section instead of restating the rule.
# A second statement names its branches, whatever words carry it.
check_token "$OVERSEE_WF" '../references/finding-disposition.md#recurrence' \
  "oversee.md § End spirals points at the Recurrence section"
if grep -qE 'structural-close|`freeze`|Tracked:' <<<"$(strip_comments "$OVERSEE_WF")"; then
  fail "oversee.md states the dispositions itself instead of pointing at them"
else
  pass "oversee.md keeps no second statement of the rule"
fi

# --- planted controls: prove each check can fail -------------------------
echo
echo "--- planted controls ---"

# A program that matches nothing leaves the fixture identical to its source,
# and the control then reports a lint miss for a guard that works. These run
# inside a command substitution, where an increment to FAIL would die with the
# subshell, so the note goes to a file the parent reads back.
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
  if grep -qF "$3" <<<"$("$1" "$2")"; then fail "lint MISSED $4"; else pass "lint flags $4"; fi
}

gone strip_comments "$(plant heading "$DISPOSITION" 's/^## Recurrence$/## Repeat findings/')" \
  '## Recurrence' "a renamed Recurrence section"
gone recurrence_section "$(plant freeze "$DISPOSITION" 's/`freeze`/another fix round/g')" \
  '`freeze`' "a dropped freeze disposition"
gone recurrence_section "$(plant tracked "$DISPOSITION" 's/`Tracked: <ID>`/a note on the thread/')" \
  '`Tracked: <ID>`' "a dropped Tracked reply form"
gone recurrence_section "$(plant declined "$DISPOSITION" 's/`decline`d with its reason, never a second filing/filed as its own issue/')" \
  '`decline`' "a frozen cause that files again instead of declining"
gone recurrence_section "$(plant trigger "$DISPOSITION" 's/, the record `fixed_items` keeps,/,/; s/A cause `fixed_items` does not name/A cause no prior round answered/')" \
  '`fixed_items`' "a trigger cut loose from the record that proves a patch"

CTRL="$(plant carveout "$DISPOSITION" 's/`freeze` is available only for a cause this diff neither introduces nor arms\. An introduced or armed cause takes `structural-close`, since a round count never answers a defect the diff armed\./Either branch answers any cause./')"
SECTION="$(recurrence_section "$CTRL")"
if grep -qF 'introduces' <<<"$SECTION" && grep -qF 'arms' <<<"$SECTION"; then
  fail "lint MISSED a dropped introduced-or-armed carve-out"
else
  pass "lint flags a dropped introduced-or-armed carve-out"
fi

# Scoping control: the tokens must be pinned INSIDE § Recurrence. A `freeze`
# elsewhere in the file must not stand in for the rule.
CTRL="$(plant scope "$DISPOSITION" 's/^## Recurrence$/## Recurrence\n\nSee below.\n\n## Elsewhere\n\nUse `freeze` and `structural-close` when it suits./')"
if grep -qF '`freeze`' <<<"$(recurrence_section "$CTRL")"; then
  fail "lint false-passed on a freeze token outside § Recurrence"
else
  pass "lint scopes its disposition tokens to § Recurrence"
fi

CTRL="$(plant row "$DISPOSITION" 's/| § Recurrence, which allows `structural-close` or `freeze` and no further patch |/| `fix` as a structural close |/')"
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

gone strip_comments "$(plant router "$COMMENTS_WF" 's#\.\./references/finding-disposition\.md\#recurrence#../references/finding-disposition.md#')" \
  '../references/finding-disposition.md#recurrence' "a dropped Recurrence router link"

CTRL="$(plant inertrouter "$COMMENTS_WF" '/^\*\*Recurrence before the cap\.\*\*/ { print "<!--"; print; print "-->"; next } { print }' awk)"
if grep -qF '<!--' "$CTRL"; then
  gone strip_comments "$CTRL" '../references/finding-disposition.md#recurrence' "a commented-out router paragraph"
else
  fail "control inertrouter planted no comment markers"
fi

# Order control: the same router text, moved behind the cap, must fail.
CTRL="$(plant order "$COMMENTS_WF" '/^\*\*Recurrence before the cap\.\*\*/d')"
MOVED="$TMP_ROOT/order-moved.md"
awk '{print} /^`iterations >= 5` /{print ""; print "**Recurrence before the cap.** See [finding-disposition.md § Recurrence](../references/finding-disposition.md#recurrence)."}' "$CTRL" > "$MOVED"
cmp -s "$MOVED" "$CTRL" && note_unplanted "order"
case "$(check_order "$MOVED")" in
  after) pass "lint flags a recurrence check moved behind the iterations cap" ;;
  *)     fail "lint MISSED a recurrence check moved behind the iterations cap" ;;
esac

gone strip_comments "$(plant autofix "$COMMENTS_WF" 's/carries a root cause § Recurrence dispositions (→ `RECURRENCE`, never an auto-fix), //')" \
  '`RECURRENCE`' "an auto-fix bucket that swallows recurrence items again"

CTRL="$(plant branch "$COMMENTS_WF" '/^| `freeze` | § 6.2 files the class issue FIRST/d')"
if [[ -n "$(branch_row "$CTRL" '`freeze`')" ]]; then
  fail "lint MISSED a deleted freeze branch"
else
  pass "lint flags a deleted freeze branch"
fi

gone strip_comments "$(plant frozen "$COMMENTS_WF" 's/pr_comment_review\.frozen_causes/pr_comment_review.skipped/g')" \
  'pr_comment_review.frozen_causes' "a freeze that records no cause"
gone strip_comments "$(plant schema "$STATE_SCHEMA" 's/frozen_causes/scratch_field/g')" \
  'frozen_causes' "an undocumented frozen_causes field"
gone strip_comments "$(plant oversee "$OVERSEE_WF" 's#\.\./references/finding-disposition\.md\#recurrence#SKILL.md#')" \
  '../references/finding-disposition.md#recurrence' "an oversee.md pointer that stopped pointing here"

CTRL="$(plant restate "$OVERSEE_WF" 's/which states the branches and their limits/which allows `structural-close` or `freeze`/')"
if grep -qE 'structural-close|`freeze`|Tracked:' <<<"$(strip_comments "$CTRL")"; then
  pass "lint flags a rule restated in oversee.md"
else
  fail "lint MISSED a rule restated in oversee.md"
fi

while IFS= read -r unplanted_note; do
  [[ -n "$unplanted_note" ]] && fail "$unplanted_note"
done < "$UNPLANTED"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
